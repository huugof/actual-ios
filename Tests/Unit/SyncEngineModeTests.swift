import XCTest
@testable import ActualCompanion

final class SyncEngineModeTests: XCTestCase {
    func testMutationFastSkipsFullRefreshEndpoints() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)

        try await enqueueUpdateMutation(database: database, accountID: "acct-1")
        _ = try await engine.sync(mode: .mutationFast)

        let stats = await api.snapshot()
        XCTAssertEqual(stats.fetchCategoriesCount, 0)
        XCTAssertEqual(stats.fetchAccountsCount, 0)
        XCTAssertEqual(stats.fetchPayeesCount, 0)
        XCTAssertEqual(stats.fetchRecentRequests.count, 1)
        XCTAssertEqual(stats.updateTransactionCount, 1)
        XCTAssertEqual(Set(stats.fetchRecentRequests[0].accountIDs ?? []), Set(["acct-1"]))
        XCTAssertEqual(stats.fetchRecentRequests[0].daysBack, 60)
    }

    func testFullSyncRunsSingleFullRefreshPass() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)

        _ = try await engine.sync(mode: .full)

        let stats = await api.snapshot()
        XCTAssertEqual(stats.fetchCategoriesCount, 1)
        XCTAssertEqual(stats.fetchAccountsCount, 1)
        XCTAssertEqual(stats.fetchPayeesCount, 1)
        XCTAssertEqual(stats.fetchRecentRequests.count, 1)
    }

    func testMutationDrainProcessesMoreThanOneBatch() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)

        for index in 0..<120 {
            try await enqueueCreatePayeeMutation(database: database, name: "Payee \(index)")
        }

        _ = try await engine.sync(mode: .mutationFast)

        let stats = await api.snapshot()
        XCTAssertEqual(stats.createPayeeCount, 120)
        XCTAssertEqual(try await database.pendingMutationCount(), 0)
        XCTAssertEqual(stats.fetchRecentRequests.count, 0)
    }

    func testRetryBackoffPreventsImmediateRetry() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        await api.setUpdateFailure(true)
        let engine = SyncEngine(database: database, api: api)

        try await enqueueUpdateMutation(database: database, accountID: "acct-2")

        _ = try await engine.sync(mode: .mutationFast)
        let firstStats = await api.snapshot()
        XCTAssertEqual(firstStats.updateTransactionCount, 1)
        XCTAssertEqual(try await database.pendingMutationCount(), 1)

        _ = try await engine.sync(mode: .mutationFast)
        let secondStats = await api.snapshot()
        XCTAssertEqual(secondStats.updateTransactionCount, 1)
        XCTAssertEqual(try await database.pendingMutationCount(), 1)
    }

    private func makeDatabase() throws -> DatabaseService {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("actual-sync-tests-\(UUID().uuidString).sqlite")
        return try DatabaseService(path: url.path(percentEncoded: false))
    }

    private func enqueueUpdateMutation(database: DatabaseService, accountID: String) async throws {
        let payload = APIUpdateTransactionPayload(
            accountID: accountID,
            date: "2026-03-03",
            amountMinor: -500,
            payeeID: nil,
            payeeName: nil,
            notes: nil,
            categoryID: "food",
            splits: nil
        )
        let localID = UUID()
        let envelope = MutationEnvelope(
            data: UpdateTransactionMutation(
                localTransactionID: localID,
                remoteTransactionID: "remote-\(UUID().uuidString)",
                payload: payload
            )
        )
        let mutation = PendingMutation(
            id: envelope.id,
            type: .updateTransaction,
            payload: try JSONEncoder().encode(envelope),
            state: .queued,
            retryCount: 0,
            createdAt: .now,
            nextAttemptAt: .now,
            lastError: nil,
            transactionLocalID: localID
        )
        try await database.enqueueMutation(mutation)
    }

    private func enqueueCreatePayeeMutation(database: DatabaseService, name: String) async throws {
        let envelope = MutationEnvelope(data: CreatePayeeMutation(proposedName: name, localTransactionID: nil))
        let mutation = PendingMutation(
            id: envelope.id,
            type: .createPayee,
            payload: try JSONEncoder().encode(envelope),
            state: .queued,
            retryCount: 0,
            createdAt: .now,
            nextAttemptAt: .now,
            lastError: nil,
            transactionLocalID: nil
        )
        try await database.enqueueMutation(mutation)
    }
}

private struct RecentRequest: Sendable {
    let limit: Int
    let daysBack: Int
    let accountIDs: [String]?
}

private struct MockStats: Sendable {
    var fetchAccountsCount = 0
    var fetchPayeesCount = 0
    var fetchCategoriesCount = 0
    var fetchRecentRequests: [RecentRequest] = []
    var createPayeeCount = 0
    var createTransactionCount = 0
    var updateTransactionCount = 0
    var deleteTransactionCount = 0
}

private actor MockAPIClient: ActualAPIClientProtocol {
    private var stats = MockStats()
    private var shouldFailUpdate = false
    private var payeeCounter = 0

    func setUpdateFailure(_ value: Bool) {
        shouldFailUpdate = value
    }

    func snapshot() -> MockStats {
        stats
    }

    func fetchAccounts() async throws -> [Account] {
        stats.fetchAccountsCount += 1
        return [Account(id: "acct-1", name: "Checking")]
    }

    func fetchPayees() async throws -> [Payee] {
        stats.fetchPayeesCount += 1
        return []
    }

    func fetchCategories() async throws -> [CategorySyncPayload] {
        stats.fetchCategoriesCount += 1
        return []
    }

    func fetchRecentTransactions(limit: Int, daysBack: Int, accountIDs: [String]?) async throws -> [RecentTransactionItem] {
        stats.fetchRecentRequests.append(
            RecentRequest(limit: limit, daysBack: daysBack, accountIDs: accountIDs)
        )
        return []
    }

    func createPayee(name: String) async throws -> Payee {
        stats.createPayeeCount += 1
        payeeCounter += 1
        return Payee(id: "payee-\(payeeCounter)", name: name, lastUsedAt: .now)
    }

    func createTransaction(payload: APICreateTransactionPayload) async throws -> APISavedTransaction {
        stats.createTransactionCount += 1
        return APISavedTransaction(id: "tx-\(UUID().uuidString)", message: "ok")
    }

    func updateTransaction(id: String, payload: APIUpdateTransactionPayload) async throws -> APISavedTransaction {
        stats.updateTransactionCount += 1
        if shouldFailUpdate {
            throw APIClientError.networkError(details: "forced")
        }
        return APISavedTransaction(id: id, message: "ok")
    }

    func deleteTransaction(id: String) async throws {
        stats.deleteTransactionCount += 1
    }
}
