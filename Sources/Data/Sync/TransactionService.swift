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

    func fetchAllCategories() async throws -> [Category] {
        try await database.fetchAllCategories()
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

        let previousDraft: TransactionDraft?
        if let localID = draft.localID {
            previousDraft = try await database.loadDraft(localID: localID)
        } else {
            previousDraft = nil
        }

        let categoryIDs = extractCategoryIDs(mode: draft.categoryMode)
        let categoryNames = try await database.categoryNames(ids: categoryIDs)
        let categorySummary = buildCategorySummary(mode: draft.categoryMode, names: categoryNames)

        let payeeName = switch draft.payee {
        case .existing(let id):
            (try await database.payeeName(id: id)) ?? id
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

        let previousImpact = previousDraft.map(Self.currentMonthSpentImpact) ?? [:]
        let nextImpact = Self.currentMonthSpentImpact(for: draft)
        let impactDelta = Self.delta(from: previousImpact, to: nextImpact)
        try await database.applyCategorySpentDeltas(impactDelta)

        let mutation = try buildMutation(for: draft, localID: localID)
        try await database.enqueueMutation(mutation)
        try await database.touchPayeeLastUsed(payeeID: existingPayeeID(from: draft.payee))

        return localID
    }

    func deleteTransaction(_ item: RecentTransactionItem) async throws {
        let existingDraft = try await database.loadDraft(localID: item.id)
        let existingImpact = existingDraft.map(Self.currentMonthSpentImpact) ?? [:]
        try await database.deleteTransaction(localID: item.id)

        let payload = DeleteTransactionMutation(
            localTransactionID: item.id,
            remoteTransactionID: item.remoteID,
            accountID: item.accountID
        )
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

        let reversed = Dictionary(uniqueKeysWithValues: existingImpact.map { ($0.key, -$0.value) })
        try await database.applyCategorySpentDeltas(reversed)
    }

    private func existingPayeeID(from selection: PayeeSelection?) -> String? {
        if case .existing(let id) = selection {
            return id
        }
        return nil
    }

    static func normalizedOutflowMinor(_ amountMinor: Int64) -> Int64 {
        guard amountMinor != 0 else { return 0 }
        return -abs(amountMinor)
    }

    static func normalizedOutflowSplits(_ splits: [TransactionSplit]) -> [APISplitPayload] {
        splits.map { split in
            APISplitPayload(
                categoryID: split.categoryID,
                amountMinor: normalizedOutflowMinor(split.amountMinor)
            )
        }
    }

    private func buildMutation(for draft: TransactionDraft, localID: UUID) throws -> PendingMutation {
        let now = Date.now
        let payloadEncoder = JSONEncoder()

        switch draft.categoryMode {
        case .single(let categoryID):
            let normalizedAmount = Self.normalizedOutflowMinor(draft.amountMinor)
            let payload = APICreateTransactionPayload(
                accountID: draft.accountID,
                date: draft.date.value,
                amountMinor: normalizedAmount,
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
            let splitPayload = Self.normalizedOutflowSplits(splits)
            let normalizedTotal = splitPayload.reduce(Int64(0)) { $0 + $1.amountMinor }
            let payload = APICreateTransactionPayload(
                accountID: draft.accountID,
                date: draft.date.value,
                amountMinor: normalizedTotal,
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
            return names[categoryID] ?? categoryID
        case .split(let splits):
            let nameList = splits.compactMap { names[$0.categoryID] }
            if !nameList.isEmpty {
                return "Split: " + nameList.prefix(2).joined(separator: ", ")
            }
            let ids = splits.map(\.categoryID).filter { !$0.isEmpty }
            return ids.isEmpty ? "Split" : "Split: " + ids.prefix(2).joined(separator: ", ")
        }
    }

    private static func delta(from old: [String: Int64], to new: [String: Int64]) -> [String: Int64] {
        let keys = Set(old.keys).union(new.keys)
        var merged: [String: Int64] = [:]
        for id in keys {
            let value = new[id, default: 0] - old[id, default: 0]
            if value != 0 {
                merged[id] = value
            }
        }
        return merged
    }

    private static func currentMonthSpentImpact(for draft: TransactionDraft, calendar: Calendar = .current) -> [String: Int64] {
        guard monthPrefix(from: draft.date.value) == currentMonthPrefix(calendar: calendar) else {
            return [:]
        }
        switch draft.categoryMode {
        case .single(let categoryID):
            guard !categoryID.isEmpty else { return [:] }
            return [categoryID: abs(draft.amountMinor)]
        case .split(let splits):
            var impact: [String: Int64] = [:]
            for split in splits where !split.categoryID.isEmpty {
                impact[split.categoryID, default: 0] += abs(split.amountMinor)
            }
            return impact
        }
    }

    private static func monthPrefix(from rawDate: String) -> String? {
        let trimmed = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 7 else { return nil }
        let prefix = String(trimmed.prefix(7))
        guard prefix.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return prefix
    }

    private static func currentMonthPrefix(calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: .now)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }
}
