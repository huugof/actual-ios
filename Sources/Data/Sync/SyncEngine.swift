import Foundation
import OSLog

struct SyncOutcome: Sendable {
    let warningMessage: String?
}

enum SyncMode: String, Sendable {
    case full
    case mutationFast
}

struct MutationProcessingReport: Sendable {
    var processedCount: Int = 0
    var processedTransactionMutation = false
    var touchedAccountIDs: Set<String> = []
    var touchedMonths: [String] = []

    mutating func record(_ result: MutationApplyResult) {
        processedCount += 1
        if result.isTransactionMutation {
            processedTransactionMutation = true
        }
        if let accountID = result.touchedAccountID, !accountID.isEmpty {
            touchedAccountIDs.insert(accountID)
        }
        if let touchedMonth = result.touchedMonth, !touchedMonth.isEmpty, !touchedMonths.contains(touchedMonth) {
            touchedMonths.append(touchedMonth)
        }
    }
}

struct MutationApplyResult: Sendable {
    let isTransactionMutation: Bool
    let touchedAccountID: String?
    let touchedMonth: String?
}

actor SyncEngine {
    private let database: DatabaseService
    private let api: ActualAPIClientProtocol
    private let logger = Logger(subsystem: "ActualCompanion", category: "Sync")

    init(database: DatabaseService, api: ActualAPIClientProtocol) {
        self.database = database
        self.api = api
    }

    func sync(mode: SyncMode) async throws -> SyncOutcome {
        let startedAt = Date()
        var warnings: [String] = []

        let report = try await processPendingMutationsDraining()
        switch mode {
        case .full:
            if let warning = try await refreshReferenceDataAndRecents() {
                warnings.append(warning)
            }
        case .mutationFast:
            if report.processedTransactionMutation {
                let accountIDs = report.touchedAccountIDs.isEmpty ? nil : Array(report.touchedAccountIDs)
                async let recentsWarning = refreshRecentTransactionsOnly(
                    limit: 60,
                    daysBack: 62,
                    accountIDs: accountIDs,
                    allowPartialFailures: true,
                    pruneServerMissing: false,
                    pruneMonthPrefixes: []
                )
                async let budgetsWarning = refreshCategoryBudgetsOnly(
                    monthCandidates: Self.budgetMonthCandidates(preferredMonths: report.touchedMonths)
                )

                if let warning = try await recentsWarning {
                    warnings.append(warning)
                }
                if let warning = try await budgetsWarning {
                    warnings.append(warning)
                }
            }
        }

        #if DEBUG
        let durationMS = Int(Date.now.timeIntervalSince(startedAt) * 1000)
        logger.debug(
            "sync mode=\(mode.rawValue, privacy: .public) processed=\(report.processedCount) warnings=\(warnings.count) duration_ms=\(durationMS)"
        )
        #endif

        return SyncOutcome(
            warningMessage: warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        )
    }

    func syncNow() async throws -> SyncOutcome {
        try await sync(mode: .full)
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

        if let warning = try await refreshRecentTransactionsOnly(
            limit: 60,
            daysBack: 62,
            accountIDs: nil,
            allowPartialFailures: false,
            pruneServerMissing: true,
            pruneMonthPrefixes: Self.recentMonthPrefixes()
        ) {
            warnings.append(warning)
        }

        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    func processPendingMutations() async throws {
        _ = try await processPendingMutationsDraining()
    }

    private func processPendingMutationsDraining(
        batchSize: Int = 50,
        maxBatches: Int = 20
    ) async throws -> MutationProcessingReport {
        var report = MutationProcessingReport()
        for _ in 0..<maxBatches {
            let mutations = try await database.fetchReadyMutations(limit: batchSize)
            if mutations.isEmpty {
                break
            }

            for mutation in mutations {
                try await database.markMutationSyncing(mutation.id)
                do {
                    let result = try await applyMutation(mutation)
                    try await database.markMutationCompleted(mutation.id)
                    report.record(result)
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
        return report
    }

    private func refreshRecentTransactionsOnly(
        limit: Int,
        daysBack: Int,
        accountIDs: [String]?,
        allowPartialFailures: Bool,
        pruneServerMissing: Bool,
        pruneMonthPrefixes: [String]
    ) async throws -> String? {
        do {
            async let pendingDeleteIDs = database.fetchPendingDeleteTransactionLocalIDs()
            let fetchedRecents = try await api.fetchRecentTransactions(
                limit: limit,
                daysBack: daysBack,
                accountIDs: accountIDs,
                allowPartialFailures: allowPartialFailures
            )
            let pendingDeletes = try await pendingDeleteIDs
            let filteredRecents = fetchedRecents.filter { !pendingDeletes.contains($0.id) }
            try await database.upsertRecentTransactions(filteredRecents)
            if pruneServerMissing {
                let keepRemoteIDs = Set(filteredRecents.compactMap(\.remoteID))
                let protectedLocalIDs = try await database.fetchPendingMutationTransactionLocalIDs()
                _ = try await database.pruneRemoteTransactions(
                    monthPrefixes: pruneMonthPrefixes,
                    keepRemoteIDs: keepRemoteIDs,
                    protectedLocalIDs: protectedLocalIDs
                )
            }
            return nil
        } catch {
            return Self.softSyncWarning(prefix: "Recent transactions refresh skipped", error: error)
        }
    }

    private func refreshCategoryBudgetsOnly(monthCandidates: [String]) async throws -> String? {
        do {
            let snapshots = try await api.fetchCategoryBudgetSnapshots(monthCandidates: monthCandidates)
            try await database.applyCategoryBudgetSnapshots(snapshots)
            return nil
        } catch let error where Self.shouldIgnoreSoftError(error) {
            return nil
        } catch let snapshotError {
            do {
                let fetchedCategories = try await api.fetchCategories()
                try await database.upsertCategories(fetchedCategories)
                return nil
            } catch let fallbackError {
                var warnings: [String] = []
                if let warning = Self.softSyncWarning(prefix: "Category budget refresh skipped", error: snapshotError) {
                    warnings.append(warning)
                }
                if let warning = Self.softSyncWarning(prefix: "Fallback category refresh failed", error: fallbackError) {
                    warnings.append(warning)
                }
                return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            }
        }
    }

    private func applyMutation(_ mutation: PendingMutation) async throws -> MutationApplyResult {
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
            return MutationApplyResult(
                isTransactionMutation: true,
                touchedAccountID: envelope.data.payload.accountID,
                touchedMonth: Self.monthPrefix(dateString: envelope.data.payload.date)
            )

        case .updateTransaction:
            let envelope = try JSONDecoder().decode(MutationEnvelope<UpdateTransactionMutation>.self, from: mutation.payload)
            _ = try await api.updateTransaction(id: envelope.data.remoteTransactionID, payload: envelope.data.payload)
            return MutationApplyResult(
                isTransactionMutation: true,
                touchedAccountID: envelope.data.payload.accountID,
                touchedMonth: Self.monthPrefix(dateString: envelope.data.payload.date)
            )

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
            return MutationApplyResult(
                isTransactionMutation: true,
                touchedAccountID: envelope.data.accountID,
                touchedMonth: nil
            )

        case .createPayee:
            let envelope = try JSONDecoder().decode(MutationEnvelope<CreatePayeeMutation>.self, from: mutation.payload)
            let payee = try await api.createPayee(name: envelope.data.proposedName)
            try await database.upsertPayee(payee)
            return MutationApplyResult(isTransactionMutation: false, touchedAccountID: nil, touchedMonth: nil)
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
        if shouldIgnoreSoftError(error) {
            return nil
        }
        if let apiError = error as? APIClientError, let message = apiError.errorDescription {
            return "\(prefix): \(message)"
        }
        return "\(prefix): \(error.localizedDescription)"
    }

    private static func shouldIgnoreSoftError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let apiError = error as? APIClientError {
            if case .requestCancelled = apiError {
                return true
            }
        }
        return false
    }

    private static func budgetMonthCandidates(preferredMonths: [String], calendar: Calendar = .current) -> [String] {
        let current = Self.monthString(offset: 0, calendar: calendar)
        let previous = Self.monthString(offset: -1, calendar: calendar)
        return uniquePreservingOrder(preferredMonths + [current, previous])
    }

    private static func monthString(offset: Int, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .month, value: offset, to: .now) ?? .now
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    private static func recentMonthPrefixes(calendar: Calendar = .current) -> [String] {
        [monthString(offset: 0, calendar: calendar), monthString(offset: -1, calendar: calendar)]
    }

    private static func monthPrefix(dateString: String) -> String? {
        let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 7 else { return nil }
        let prefix = String(trimmed.prefix(7))
        guard prefix.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return prefix
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }
}
