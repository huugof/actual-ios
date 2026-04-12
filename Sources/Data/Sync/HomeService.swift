import Foundation

actor HomeService {
    struct PendingSyncState: Sendable {
        let queuedCount: Int
        let syncingCount: Int
        let blockedCount: Int
        let nextAttemptAt: Date?
        let latestError: String?

        var actionableCount: Int {
            queuedCount + syncingCount
        }
    }

    private let database: DatabaseService
    private let syncEngine: SyncEngine
    private let transactionService: TransactionService

    init(database: DatabaseService, syncEngine: SyncEngine, transactionService: TransactionService) {
        self.database = database
        self.syncEngine = syncEngine
        self.transactionService = transactionService
    }

    func loadSnapshot() async throws -> HomeSnapshot {
        let filterMode = (try await database.loadConfig()?.filterMode) ?? .trackedOnly
        return try await database.fetchHomeSnapshot(filterMode: filterMode, recentLimit: 20)
    }

    func refreshFull() async throws -> SyncOutcome {
        try await syncEngine.sync(mode: .full)
    }

    func refreshAfterMutation() async throws -> SyncOutcome {
        try await syncEngine.sync(mode: .mutationFast)
    }

    func processQueueOnly() async throws {
        try await syncEngine.processPendingMutations()
    }

    func pendingSyncState() async throws -> PendingSyncState {
        let state = try await database.pendingMutationSummary()
        return PendingSyncState(
            queuedCount: state.queuedCount,
            syncingCount: state.syncingCount,
            blockedCount: state.blockedCount,
            nextAttemptAt: state.nextAttemptAt,
            latestError: state.latestError
        )
    }

    func recoverInterruptedMutations() async -> InterruptedMutationRecoverySummary {
        await syncEngine.recoverInterruptedMutations()
    }

    func fetchBlockedMutationReviewItems() async throws -> [BlockedMutationReviewItem] {
        try await database.fetchBlockedMutationReviewItems()
    }

    func dismissBlockedMutation(_ id: UUID) async throws {
        try await database.dismissBlockedMutation(id)
    }

    func retryBlockedMutation(_ id: UUID) async {
        await syncEngine.retryBlockedMutation(id)
    }

    func deleteTransaction(_ item: RecentTransactionItem) async throws {
        try await transactionService.deleteTransaction(item)
    }

    func loadTrackedCategoryIDs() async throws -> [String] {
        try await database.fetchTrackedCategoryIDs()
    }

    func saveTrackedCategoryIDs(_ ids: [String]) async throws {
        try await database.setTrackedCategoryIDs(ids)
    }

    func fetchAllCategories() async throws -> [Category] {
        try await database.fetchAllCategories()
    }

    func loadCurrentMonthTransactions(categoryID: String, limit: Int = 120) async throws -> [CategoryDetailTransactionItem] {
        try await database.fetchTransactionsForCategory(
            categoryID,
            monthPrefix: DateHelpers.currentMonthPrefix(),
            limit: limit
        )
    }
}
