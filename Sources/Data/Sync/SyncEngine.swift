import Foundation

struct SyncOutcome: Sendable {
    let warningMessage: String?
}

actor SyncEngine {
    private let database: DatabaseService
    private let api: ActualAPIClientProtocol

    init(database: DatabaseService, api: ActualAPIClientProtocol) {
        self.database = database
        self.api = api
    }

    func syncNow() async throws -> SyncOutcome {
        var warnings: [String] = []

        if let warning = try await refreshReferenceDataAndRecents() {
            warnings.append(warning)
        }
        try await processPendingMutations()
        if let warning = try await refreshReferenceDataAndRecents() {
            warnings.append(warning)
        }

        return SyncOutcome(
            warningMessage: warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        )
    }

    func refreshReferenceDataAndRecents() async throws -> String? {
        var warnings: [String] = []

        // Categories are required for home budget tiles.
        let fetchedCategories = try await api.fetchCategories()
        try await database.upsertCategories(fetchedCategories)

        // Accounts and payees improve entry UX but shouldn't block budget refresh.
        do {
            let fetchedAccounts = try await api.fetchAccounts()
            try await database.upsertAccounts(fetchedAccounts)
        } catch {
            if let warning = Self.softSyncWarning(prefix: "Accounts sync skipped", error: error) {
                warnings.append(warning)
            }
        }

        do {
            let fetchedPayees = try await api.fetchPayees()
            try await database.upsertPayees(fetchedPayees)
        } catch {
            if let warning = Self.softSyncWarning(prefix: "Payees sync skipped", error: error) {
                warnings.append(warning)
            }
        }

        do {
            async let pendingDeleteIDs = database.fetchPendingDeleteTransactionLocalIDs()
            let fetchedRecents = try await api.fetchRecentTransactions(limit: 60)
            let pendingDeletes = try await pendingDeleteIDs
            let filteredRecents = fetchedRecents.filter { !pendingDeletes.contains($0.id) }
            try await database.upsertRecentTransactions(filteredRecents)
        } catch {
            if let warning = Self.softSyncWarning(prefix: "Recent transactions refresh skipped", error: error) {
                warnings.append(warning)
            }
        }

        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    func processPendingMutations() async throws {
        let mutations = try await database.fetchReadyMutations(limit: 20)
        for mutation in mutations {
            try await database.markMutationSyncing(mutation.id)
            do {
                try await applyMutation(mutation)
                try await database.markMutationCompleted(mutation.id)
            } catch {
                let retryCount = mutation.retryCount + 1
                if retryCount > 8 {
                    try await database.markMutationPermanentFailure(mutation.id, lastError: error.localizedDescription)
                } else {
                    let delay = retryDelay(for: retryCount)
                    try await database.markMutationFailed(
                        mutation.id,
                        retryCount: retryCount,
                        delay: delay,
                        lastError: error.localizedDescription
                    )
                }
            }
        }
    }

    private func applyMutation(_ mutation: PendingMutation) async throws {
        switch mutation.type {
        case .createTransaction:
            let envelope = try JSONDecoder().decode(MutationEnvelope<CreateTransactionMutation>.self, from: mutation.payload)
            let response = try await api.createTransaction(payload: envelope.data.payload)
            if let remoteID = response.id, !remoteID.isEmpty {
                try await database.setTransactionRemoteID(localID: envelope.data.localTransactionID, remoteID: remoteID)
            } else {
                // actual-http-api commonly returns only \"message: ok\" on create.
                // Remove optimistic row and rely on post-mutation refresh to repopulate authoritative remote records.
                try await database.deleteTransaction(localID: envelope.data.localTransactionID)
            }

        case .updateTransaction:
            let envelope = try JSONDecoder().decode(MutationEnvelope<UpdateTransactionMutation>.self, from: mutation.payload)
            _ = try await api.updateTransaction(id: envelope.data.remoteTransactionID, payload: envelope.data.payload)

        case .deleteTransaction:
            let envelope = try JSONDecoder().decode(MutationEnvelope<DeleteTransactionMutation>.self, from: mutation.payload)
            if let remoteID = envelope.data.remoteTransactionID {
                do {
                    try await api.deleteTransaction(id: remoteID)
                } catch APIClientError.httpError(let status, _) where status == 404 {
                    // Transaction already gone remotely.
                }
            }
            try await database.deleteTransaction(localID: envelope.data.localTransactionID)

        case .createPayee:
            let envelope = try JSONDecoder().decode(MutationEnvelope<CreatePayeeMutation>.self, from: mutation.payload)
            let payee = try await api.createPayee(name: envelope.data.proposedName)
            try await database.upsertPayee(payee)
        }
    }

    private func retryDelay(for retryCount: Int) -> TimeInterval {
        switch retryCount {
        case 1: return 5
        case 2: return 20
        case 3: return 60
        case 4: return 300
        case 5: return 900
        case 6: return 1800
        case 7: return 3600
        default: return 7200
        }
    }

    private static func softSyncWarning(prefix: String, error: Error) -> String? {
        if error is CancellationError {
            return nil
        }
        if let apiError = error as? APIClientError {
            if case .requestCancelled = apiError {
                return nil
            }
        }
        if let apiError = error as? APIClientError, let message = apiError.errorDescription {
            return "\(prefix): \(message)"
        }
        return "\(prefix): \(error.localizedDescription)"
    }
}
