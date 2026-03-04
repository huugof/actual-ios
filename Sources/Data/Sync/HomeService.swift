import Foundation

actor HomeService {
    struct PendingSyncState: Sendable {
        let pendingCount: Int
        let nextAttemptAt: Date?
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
        let state = try await database.pendingMutationRetryState()
        return PendingSyncState(
            pendingCount: state.pendingCount,
            nextAttemptAt: state.nextAttemptAt
        )
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

    func loadCurrentMonthTransactions(categoryID: String, limit: Int = 120) async throws -> [RecentTransactionItem] {
        try await database.fetchTransactionsForCategory(
            categoryID,
            monthPrefix: Self.currentMonthPrefix(),
            limit: limit
        )
    }

    private static func currentMonthPrefix(calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: .now)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }
}
