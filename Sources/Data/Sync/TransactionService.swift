import Foundation

actor TransactionService {
    private let database: DatabaseService

    init(database: DatabaseService) {
        self.database = database
    }

    func fetchAccounts() async throws -> [Account] {
        try await database.fetchAccounts()
    }

    func fetchTrackedCategories() async throws -> [Category] {
        try await database.fetchTrackedCategories()
    }

    func searchPayees(query: String) async throws -> [Payee] {
        try await database.searchPayees(query: query)
    }

    func searchCategories(query: String, trackedOnly: Bool = false) async throws -> [Category] {
        try await database.searchCategories(query: query, trackedOnly: trackedOnly)
    }

    func categoryName(id: String) async throws -> String? {
        try await database.categoryName(id: id)
    }

    func payeeName(id: String) async throws -> String? {
        try await database.payeeName(id: id)
    }

    func loadDraft(localID: UUID) async throws -> TransactionDraft? {
        try await database.loadDraft(localID: localID)
    }

    func createOrUpdateTransaction(_ draft: TransactionDraft) async throws -> UUID {
        guard draft.isValidToSave else {
            throw NSError(domain: "TransactionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Transaction form is incomplete"])
        }

        let categoryIDs = extractCategoryIDs(mode: draft.categoryMode)
        let categoryNames = try await database.categoryNames(ids: categoryIDs)
        let categorySummary = buildCategorySummary(mode: draft.categoryMode, names: categoryNames)

        let payeeName = switch draft.payee {
        case .existing(let id):
            (try await database.payeeName(id: id)) ?? "Unknown"
        case .new(let name):
            name
        case .none:
            "Unknown"
        }

        let splits: [TransactionSplit] = {
            switch draft.categoryMode {
            case .single:
                return []
            case .split(let splits):
                return splits
            }
        }()

        let localID = try await database.saveTransaction(
            draft: draft,
            payeeName: payeeName,
            categorySummary: categorySummary,
            categoryIDs: categoryIDs,
            splits: splits
        )

        let mutation = try buildMutation(for: draft, localID: localID)
        try await database.enqueueMutation(mutation)
        try await database.touchPayeeLastUsed(payeeID: existingPayeeID(from: draft.payee))

        return localID
    }

    func deleteTransaction(_ item: RecentTransactionItem) async throws {
        try await database.deleteTransaction(localID: item.id)

        let payload = DeleteTransactionMutation(localTransactionID: item.id, remoteTransactionID: item.remoteID)
        let envelope = MutationEnvelope(data: payload)
        let encoded = try JSONEncoder().encode(envelope)

        let mutation = PendingMutation(
            id: envelope.id,
            type: .deleteTransaction,
            payload: encoded,
            state: .queued,
            retryCount: 0,
            createdAt: .now,
            nextAttemptAt: .now,
            lastError: nil,
            transactionLocalID: item.id
        )

        try await database.enqueueMutation(mutation)
    }

    private func existingPayeeID(from selection: PayeeSelection?) -> String? {
        if case .existing(let id) = selection {
            return id
        }
        return nil
    }

    private func buildMutation(for draft: TransactionDraft, localID: UUID) throws -> PendingMutation {
        let now = Date.now
        let payloadEncoder = JSONEncoder()

        switch draft.categoryMode {
        case .single(let categoryID):
            let payload = APICreateTransactionPayload(
                accountID: draft.accountID,
                date: draft.date.value,
                amountMinor: draft.amountMinor,
                payeeID: existingPayeeID(from: draft.payee),
                payeeName: {
                    if case .new(let name) = draft.payee { return name }
                    return nil
                }(),
                notes: draft.note.isEmpty ? nil : draft.note,
                categoryID: categoryID,
                splits: nil
            )

            if let remoteID = draft.remoteID {
                let update = APIUpdateTransactionPayload(
                    accountID: payload.accountID,
                    date: payload.date,
                    amountMinor: payload.amountMinor,
                    payeeID: payload.payeeID,
                    payeeName: payload.payeeName,
                    notes: payload.notes,
                    categoryID: payload.categoryID,
                    splits: nil
                )
                let mutationData = try payloadEncoder.encode(MutationEnvelope(data: UpdateTransactionMutation(localTransactionID: localID, remoteTransactionID: remoteID, payload: update)))
                return PendingMutation(
                    id: UUID(),
                    type: .updateTransaction,
                    payload: mutationData,
                    state: .queued,
                    retryCount: 0,
                    createdAt: now,
                    nextAttemptAt: now,
                    lastError: nil,
                    transactionLocalID: localID
                )
            }

            let mutationData = try payloadEncoder.encode(MutationEnvelope(data: CreateTransactionMutation(localTransactionID: localID, payload: payload)))
            return PendingMutation(
                id: UUID(),
                type: .createTransaction,
                payload: mutationData,
                state: .queued,
                retryCount: 0,
                createdAt: now,
                nextAttemptAt: now,
                lastError: nil,
                transactionLocalID: localID
            )

        case .split(let splits):
            let splitPayload = splits.map { APISplitPayload(categoryID: $0.categoryID, amountMinor: $0.amountMinor) }
            let payload = APICreateTransactionPayload(
                accountID: draft.accountID,
                date: draft.date.value,
                amountMinor: draft.amountMinor,
                payeeID: existingPayeeID(from: draft.payee),
                payeeName: {
                    if case .new(let name) = draft.payee { return name }
                    return nil
                }(),
                notes: draft.note.isEmpty ? nil : draft.note,
                categoryID: nil,
                splits: splitPayload
            )

            if let remoteID = draft.remoteID {
                let update = APIUpdateTransactionPayload(
                    accountID: payload.accountID,
                    date: payload.date,
                    amountMinor: payload.amountMinor,
                    payeeID: payload.payeeID,
                    payeeName: payload.payeeName,
                    notes: payload.notes,
                    categoryID: nil,
                    splits: splitPayload
                )
                let mutationData = try payloadEncoder.encode(MutationEnvelope(data: UpdateTransactionMutation(localTransactionID: localID, remoteTransactionID: remoteID, payload: update)))
                return PendingMutation(
                    id: UUID(),
                    type: .updateTransaction,
                    payload: mutationData,
                    state: .queued,
                    retryCount: 0,
                    createdAt: now,
                    nextAttemptAt: now,
                    lastError: nil,
                    transactionLocalID: localID
                )
            }

            let mutationData = try payloadEncoder.encode(MutationEnvelope(data: CreateTransactionMutation(localTransactionID: localID, payload: payload)))
            return PendingMutation(
                id: UUID(),
                type: .createTransaction,
                payload: mutationData,
                state: .queued,
                retryCount: 0,
                createdAt: now,
                nextAttemptAt: now,
                lastError: nil,
                transactionLocalID: localID
            )
        }
    }

    private func extractCategoryIDs(mode: TransactionCategoryMode) -> [String] {
        switch mode {
        case .single(let categoryID):
            return [categoryID]
        case .split(let splits):
            return splits.map(\.categoryID)
        }
    }

    private func buildCategorySummary(mode: TransactionCategoryMode, names: [String: String]) -> String {
        switch mode {
        case .single(let categoryID):
            return names[categoryID] ?? "Uncategorized"
        case .split(let splits):
            let nameList = splits.compactMap { names[$0.categoryID] }
            return nameList.isEmpty ? "Split" : "Split: " + nameList.prefix(2).joined(separator: ", ")
        }
    }
}
