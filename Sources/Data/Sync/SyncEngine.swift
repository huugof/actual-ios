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

struct InterruptedMutationRecoverySummary: Sendable {
    var requeuedCount: Int = 0
    var resolvedCount: Int = 0
    var blockedCount: Int = 0
    var latestBlockedError: String?

    var notice: String? {
        guard blockedCount > 0 else { return nil }
        if blockedCount == 1, let latestBlockedError {
            return latestBlockedError
        }
        if let latestBlockedError {
            return "\(blockedCount) sync items need review. \(latestBlockedError)"
        }
        return "\(blockedCount) sync items need review."
    }
}

private enum MutationRecoveryDisposition: Sendable {
    case requeued
    case resolved
    case blocked(String)
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

    func recoverInterruptedMutations() async -> InterruptedMutationRecoverySummary {
        do {
            let interrupted = try await database.fetchInterruptedMutations()
            guard !interrupted.isEmpty else { return InterruptedMutationRecoverySummary() }

            return await summarizeRecovery(interrupted)
        } catch {
            return InterruptedMutationRecoverySummary(
                requeuedCount: 0,
                resolvedCount: 0,
                blockedCount: 1,
                latestBlockedError: "Interrupted sync recovery failed: \(error.localizedDescription)"
            )
        }
    }

    func retryBlockedMutation(_ id: UUID) async {
        guard let mutation = try? await database.fetchPendingMutation(id: id),
              mutation.state == .blocked else {
            return
        }

        _ = await summarizeRecovery([mutation])
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
            let filteredRecents = fetchedRecents.filter { !pendingDeletes.contains($0.transaction.id) }
            try await database.upsertRecentTransactions(filteredRecents)
            if pruneServerMissing {
                let keepRemoteIDs = Set(filteredRecents.compactMap(\.transaction.remoteID))
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

    private func summarizeRecovery(_ mutations: [PendingMutation]) async -> InterruptedMutationRecoverySummary {
        var summary = InterruptedMutationRecoverySummary()

        for mutation in mutations {
            do {
                let disposition = try await recoverMutation(mutation)
                switch disposition {
                case .requeued:
                    summary.requeuedCount += 1
                case .resolved:
                    summary.resolvedCount += 1
                case .blocked(let reason):
                    summary.blockedCount += 1
                    summary.latestBlockedError = reason
                }
            } catch {
                let reason = "Interrupted sync recovery failed: \(error.localizedDescription)"
                try? await database.markMutationBlocked(mutation.id, lastError: reason)
                summary.blockedCount += 1
                summary.latestBlockedError = reason
            }
        }

        return summary
    }

    private func recoverMutation(_ mutation: PendingMutation) async throws -> MutationRecoveryDisposition {
        switch mutation.type {
        case .updateTransaction, .deleteTransaction:
            try await database.requeueMutation(mutation.id, nextAttemptAt: .now)
            return .requeued

        case .createTransaction:
            let envelope = try JSONDecoder().decode(MutationEnvelope<CreateTransactionMutation>.self, from: mutation.payload)
            if let importedID = envelope.data.payload.importedID, !importedID.isEmpty {
                try await database.requeueMutation(mutation.id, nextAttemptAt: .now)
                return .requeued
            }

            do {
                try await refreshRecoveryTransactions(
                    accountID: envelope.data.payload.accountID,
                    dateString: envelope.data.payload.date
                )
                let candidates = try await database.fetchRemoteTransactions(
                    accountID: envelope.data.payload.accountID,
                    date: envelope.data.payload.date
                )
                let matches = candidates.filter { Self.matchesRecoveryCreate(payload: envelope.data.payload, candidate: $0) }

                if matches.count == 1, let match = matches.first {
                    if match.transaction.id != envelope.data.localTransactionID {
                        try await database.deleteTransaction(localID: envelope.data.localTransactionID)
                    } else if let remoteID = match.transaction.remoteID, !remoteID.isEmpty {
                        try await database.setTransactionRemoteID(localID: envelope.data.localTransactionID, remoteID: remoteID)
                    }
                    try await database.markMutationCompleted(mutation.id)
                    return .resolved
                }

                let reason = matches.isEmpty
                    ? "Interrupted transaction create could not be verified against the server. Review the transaction before retrying."
                    : "Interrupted transaction create matched multiple server transactions. Review the transaction before retrying."
                try await database.markMutationBlocked(mutation.id, lastError: reason)
                return .blocked(reason)
            } catch {
                let reason = "Interrupted transaction create could not be verified: \(error.localizedDescription)"
                try await database.markMutationBlocked(mutation.id, lastError: reason)
                return .blocked(reason)
            }

        case .createPayee:
            let envelope = try JSONDecoder().decode(MutationEnvelope<CreatePayeeMutation>.self, from: mutation.payload)
            do {
                let payees = try await api.fetchPayees()
                let matches = payees.filter {
                    Self.normalizedRecoveryText($0.name) == Self.normalizedRecoveryText(envelope.data.proposedName)
                }
                if matches.count == 1, let payee = matches.first {
                    try await database.upsertPayee(payee)
                    try await database.markMutationCompleted(mutation.id)
                    return .resolved
                }

                let reason = "Interrupted payee create could not be safely retried automatically. Review payees before retrying."
                try await database.markMutationBlocked(mutation.id, lastError: reason)
                return .blocked(reason)
            } catch {
                let reason = "Interrupted payee create could not be verified: \(error.localizedDescription)"
                try await database.markMutationBlocked(mutation.id, lastError: reason)
                return .blocked(reason)
            }
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
                touchedMonth: DateHelpers.monthPrefix(from: envelope.data.payload.date)
            )

        case .updateTransaction:
            let envelope = try JSONDecoder().decode(MutationEnvelope<UpdateTransactionMutation>.self, from: mutation.payload)
            _ = try await api.updateTransaction(id: envelope.data.remoteTransactionID, payload: envelope.data.payload)
            return MutationApplyResult(
                isTransactionMutation: true,
                touchedAccountID: envelope.data.payload.accountID,
                touchedMonth: DateHelpers.monthPrefix(from: envelope.data.payload.date)
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
        let current = DateHelpers.monthString(offset: 0, calendar: calendar)
        let previous = DateHelpers.monthString(offset: -1, calendar: calendar)
        return DateHelpers.uniquePreservingOrder(preferredMonths + [current, previous])
    }

    private static func recentMonthPrefixes(calendar: Calendar = .current) -> [String] {
        [DateHelpers.monthString(offset: 0, calendar: calendar),
         DateHelpers.monthString(offset: -1, calendar: calendar)]
    }

    private func refreshRecoveryTransactions(accountID: String, dateString: String) async throws {
        let recents = try await api.fetchRecentTransactions(
            limit: 250,
            daysBack: Self.recoveryDaysBack(dateString: dateString),
            accountIDs: [accountID],
            allowPartialFailures: false
        )
        try await database.upsertRecentTransactions(recents)
    }

    private static func recoveryDaysBack(dateString: String, calendar: Calendar = .current) -> Int {
        guard let date = LocalDate(dateString).toDate(calendar: calendar) else {
            return 62
        }
        let startOfDay = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: .now)
        let rawDays = calendar.dateComponents([.day], from: startOfDay, to: today).day ?? 0
        return max(62, rawDays + 7)
    }

    private static func matchesRecoveryCreate(
        payload: APICreateTransactionPayload,
        candidate: SyncedRecentTransactionItem
    ) -> Bool {
        let transaction = candidate.transaction
        guard transaction.accountID == payload.accountID else { return false }
        guard transaction.date.value == payload.date else { return false }
        guard transaction.amountMinor == payload.amountMinor else { return false }
        guard normalizedRecoveryText(transaction.note) == normalizedRecoveryText(payload.notes) else { return false }

        if let payeeID = payload.payeeID, !payeeID.isEmpty {
            guard transaction.payeeID == payeeID else { return false }
        } else {
            guard normalizedRecoveryText(transaction.payeeName) == normalizedRecoveryText(payload.payeeName) else {
                return false
            }
        }

        if let categoryID = payload.categoryID, !categoryID.isEmpty {
            return !transaction.isSplit && transaction.categoryIDs == [categoryID]
        }

        let payloadSplits = (payload.splits ?? [])
            .map { "\($0.categoryID)|\($0.amountMinor)" }
            .sorted()
        let candidateSplits = candidate.splits
            .map { "\($0.categoryID)|\($0.amountMinor)" }
            .sorted()
        return payloadSplits == candidateSplits
    }

    private static func normalizedRecoveryText(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

}
