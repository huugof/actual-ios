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
        XCTAssertEqual(stats.fetchBudgetSnapshotRequests.count, 1)
        XCTAssertEqual(stats.updateTransactionCount, 1)
        XCTAssertEqual(Set(stats.fetchRecentRequests[0].accountIDs ?? []), Set(["acct-1"]))
        XCTAssertEqual(stats.fetchRecentRequests[0].daysBack, 62)
        XCTAssertTrue(stats.fetchRecentRequests[0].allowPartialFailures)
    }

    func testMutationFastPassesTouchedMonthCandidates() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)

        try await enqueueUpdateMutation(
            database: database,
            accountID: "acct-1",
            date: "2025-12-31"
        )
        _ = try await engine.sync(mode: .mutationFast)

        let stats = await api.snapshot()
        XCTAssertEqual(stats.fetchBudgetSnapshotRequests.count, 1)
        XCTAssertTrue(stats.fetchBudgetSnapshotRequests[0].contains("2025-12"))
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
        XCTAssertEqual(stats.fetchBudgetSnapshotRequests.count, 0)
        XCTAssertFalse(stats.fetchRecentRequests[0].allowPartialFailures)
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
        let pendingCount = try await database.pendingMutationCount()
        XCTAssertEqual(stats.createPayeeCount, 120)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(stats.fetchRecentRequests.count, 0)
        XCTAssertEqual(stats.fetchBudgetSnapshotRequests.count, 0)
    }

    func testRetryBackoffPreventsImmediateRetry() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        await api.setUpdateFailure(true)
        let engine = SyncEngine(database: database, api: api)

        try await enqueueUpdateMutation(database: database, accountID: "acct-2")

        _ = try await engine.sync(mode: .mutationFast)
        let firstStats = await api.snapshot()
        let firstPendingCount = try await database.pendingMutationCount()
        XCTAssertEqual(firstStats.updateTransactionCount, 1)
        XCTAssertEqual(firstPendingCount, 1)

        _ = try await engine.sync(mode: .mutationFast)
        let secondStats = await api.snapshot()
        let secondPendingCount = try await database.pendingMutationCount()
        XCTAssertEqual(secondStats.updateTransactionCount, 1)
        XCTAssertEqual(secondPendingCount, 1)
        XCTAssertEqual(secondStats.fetchBudgetSnapshotRequests.count, 0)
    }

    func testRecoverInterruptedIdempotentCreateTransactionRequeuesAndRetries() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)

        try await enqueueCreateTransactionMutation(
            database: database,
            state: .syncing,
            importedID: "ios:tx-1"
        )

        let recovery = await engine.recoverInterruptedMutations()
        XCTAssertEqual(recovery.requeuedCount, 1)
        XCTAssertEqual(recovery.blockedCount, 0)

        let pending = try await database.pendingMutationSummary()
        XCTAssertEqual(pending.actionableCount, 1)
        XCTAssertEqual(pending.blockedCount, 0)
        XCTAssertNotNil(pending.nextAttemptAt)

        _ = try await engine.sync(mode: .mutationFast)

        let stats = await api.snapshot()
        XCTAssertEqual(stats.createTransactionCount, 1)
        XCTAssertEqual(stats.createdTransactionPayloads.first?.importedID, "ios:tx-1")
    }

    func testRecoverInterruptedLegacyCreateTransactionCompletesWhenServerMatchExists() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)
        let localID = UUID()

        try await saveLocalTransaction(database: database, localID: localID)
        try await enqueueCreateTransactionMutation(
            database: database,
            localID: localID,
            state: .syncing,
            importedID: nil
        )
        await api.setFetchRecentResponse([
            makeRemoteRecentTransaction(
                id: UUID(),
                remoteID: "remote-1",
                accountID: "acct-1",
                date: "2026-03-03",
                amountMinor: -500,
                payeeName: "Coffee Shop",
                payeeID: nil,
                note: "latte",
                categoryIDs: ["food"],
                splits: []
            )
        ])

        let recovery = await engine.recoverInterruptedMutations()
        XCTAssertEqual(recovery.resolvedCount, 1)
        XCTAssertEqual(recovery.blockedCount, 0)

        let pending = try await database.pendingMutationSummary()
        XCTAssertEqual(pending.actionableCount, 0)
        XCTAssertEqual(pending.blockedCount, 0)
        let localTransaction = try await database.fetchRecentTransaction(id: localID)
        XCTAssertNil(localTransaction)

        let snapshot = try await database.fetchHomeSnapshot(filterMode: .all, recentLimit: 10)
        XCTAssertEqual(snapshot.recents.count, 1)
        XCTAssertEqual(snapshot.recents.first?.remoteID, "remote-1")
    }

    func testRecoverInterruptedLegacyCreateTransactionBlocksWhenNotVerified() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)

        try await enqueueCreateTransactionMutation(
            database: database,
            state: .syncing,
            importedID: nil
        )

        let recovery = await engine.recoverInterruptedMutations()
        XCTAssertEqual(recovery.blockedCount, 1)
        XCTAssertEqual(recovery.requeuedCount, 0)

        let pending = try await database.pendingMutationSummary()
        XCTAssertEqual(pending.actionableCount, 0)
        XCTAssertEqual(pending.blockedCount, 1)
        XCTAssertTrue((pending.latestError ?? "").contains("could not be verified"))
    }

    func testPendingMutationSummarySeparatesBlockedFromActionable() async throws {
        let database = try makeDatabase()

        try await enqueueUpdateMutation(database: database, accountID: "acct-1")
        try await enqueueCreateTransactionMutation(
            database: database,
            state: .blocked,
            importedID: nil,
            lastError: "Needs review"
        )

        let pending = try await database.pendingMutationSummary()
        XCTAssertEqual(pending.actionableCount, 1)
        XCTAssertEqual(pending.blockedCount, 1)
        XCTAssertNotNil(pending.nextAttemptAt)
        XCTAssertEqual(pending.latestError, "Needs review")
    }

    func testFetchBlockedMutationReviewItemsIncludesTransactionContext() async throws {
        let database = try makeDatabase()
        let localID = UUID()

        try await saveLocalTransaction(database: database, localID: localID)
        try await enqueueCreateTransactionMutation(
            database: database,
            localID: localID,
            state: .blocked,
            importedID: nil,
            lastError: "Needs review"
        )

        let items = try await database.fetchBlockedMutationReviewItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.transaction?.id, localID)
        XCTAssertEqual(items.first?.transaction?.payeeName, "Coffee Shop")
        XCTAssertNil(items.first?.proposedPayeeName)
    }

    func testFetchBlockedMutationReviewItemsIncludesProposedPayeeName() async throws {
        let database = try makeDatabase()

        try await enqueueCreatePayeeMutation(
            database: database,
            name: "Landlord",
            state: .blocked,
            lastError: "Needs review"
        )

        let items = try await database.fetchBlockedMutationReviewItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.type, .createPayee)
        XCTAssertEqual(items.first?.proposedPayeeName, "Landlord")
    }

    func testRetryBlockedLegacyCreateTransactionCompletesWhenServerMatchExists() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)
        let localID = UUID()

        try await saveLocalTransaction(database: database, localID: localID)
        try await enqueueCreateTransactionMutation(
            database: database,
            localID: localID,
            state: .blocked,
            importedID: nil,
            lastError: "Needs review"
        )
        await api.setFetchRecentResponse([
            makeRemoteRecentTransaction(
                id: UUID(),
                remoteID: "remote-2",
                accountID: "acct-1",
                date: "2026-03-03",
                amountMinor: -500,
                payeeName: "Coffee Shop",
                payeeID: nil,
                note: "latte",
                categoryIDs: ["food"],
                splits: []
            )
        ])

        let reviewItems = try await database.fetchBlockedMutationReviewItems()
        let reviewID = try XCTUnwrap(reviewItems.first?.id)
        await engine.retryBlockedMutation(reviewID)

        let pending = try await database.pendingMutationSummary()
        XCTAssertEqual(pending.blockedCount, 0)
        XCTAssertEqual(pending.actionableCount, 0)
    }

    func testRetryBlockedPayeeCreateCompletesWhenUniquePayeeExists() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)

        try await enqueueCreatePayeeMutation(
            database: database,
            name: "Landlord",
            state: .blocked,
            lastError: "Needs review"
        )
        await api.setFetchPayeesResponse([
            Payee(id: "payee-1", name: "Landlord", lastUsedAt: .now)
        ])

        let reviewItems = try await database.fetchBlockedMutationReviewItems()
        let reviewID = try XCTUnwrap(reviewItems.first?.id)
        await engine.retryBlockedMutation(reviewID)

        let pending = try await database.pendingMutationSummary()
        XCTAssertEqual(pending.blockedCount, 0)
    }

    func testDismissBlockedMutationRemovesBlockedCount() async throws {
        let database = try makeDatabase()

        try await enqueueCreatePayeeMutation(
            database: database,
            name: "Landlord",
            state: .blocked,
            lastError: "Needs review"
        )
        let reviewItems = try await database.fetchBlockedMutationReviewItems()
        let item = try XCTUnwrap(reviewItems.first)

        try await database.dismissBlockedMutation(item.id)

        let pending = try await database.pendingMutationSummary()
        XCTAssertEqual(pending.blockedCount, 0)
    }

    func testMutationFastAppliesBudgetSnapshotsToLocalCategories() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)

        try await database.upsertCategories([
            CategorySyncPayload(
                id: "food",
                name: "Food",
                groupName: "Needs",
                isIncome: false,
                budgetedMinor: 100_00,
                spentMinor: 0
            )
        ])
        try await enqueueUpdateMutation(database: database, accountID: "acct-1")

        _ = try await engine.sync(mode: .mutationFast)

        let snapshot = try await database.fetchHomeSnapshot(filterMode: .all, recentLimit: 10)
        XCTAssertEqual(snapshot.overallBudget.spentMinor, 40_00)
    }

    func testMutationFastFallsBackToFetchCategoriesWhenBudgetSnapshotFails() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        await api.setBudgetSnapshotFailure(true)
        await api.setFetchCategoriesResponse([
            CategorySyncPayload(
                id: "food",
                name: "Food",
                groupName: "Needs",
                isIncome: false,
                budgetedMinor: 100_00,
                spentMinor: 55_00
            )
        ])
        let engine = SyncEngine(database: database, api: api)

        try await database.upsertCategories([
            CategorySyncPayload(
                id: "food",
                name: "Food",
                groupName: "Needs",
                isIncome: false,
                budgetedMinor: 100_00,
                spentMinor: 0
            )
        ])
        try await enqueueUpdateMutation(database: database, accountID: "acct-1")

        _ = try await engine.sync(mode: .mutationFast)

        let stats = await api.snapshot()
        XCTAssertEqual(stats.fetchBudgetSnapshotRequests.count, 1)
        XCTAssertEqual(stats.fetchCategoriesCount, 1)

        let snapshot = try await database.fetchHomeSnapshot(filterMode: .all, recentLimit: 10)
        XCTAssertEqual(snapshot.overallBudget.spentMinor, 55_00)
    }

    func testFullSyncPrunesStaleCategoriesFromOverallBudget() async throws {
        let database = try makeDatabase()
        let api = MockAPIClient()
        let engine = SyncEngine(database: database, api: api)

        try await database.upsertCategories([
            CategorySyncPayload(
                id: "food",
                name: "Food",
                groupName: "Needs",
                isIncome: false,
                budgetedMinor: 100_00,
                spentMinor: 40_00
            ),
            CategorySyncPayload(
                id: "stale",
                name: "Stale",
                groupName: "Needs",
                isIncome: false,
                budgetedMinor: 110_00,
                spentMinor: 110_00
            )
        ])
        await api.setFetchCategoriesResponse([
            CategorySyncPayload(
                id: "food",
                name: "Food",
                groupName: "Needs",
                isIncome: false,
                budgetedMinor: 100_00,
                spentMinor: 40_00
            )
        ])

        _ = try await engine.sync(mode: .full)

        let snapshot = try await database.fetchHomeSnapshot(filterMode: .all, recentLimit: 10)
        XCTAssertEqual(snapshot.overallBudget.budgetedMinor, 100_00)
        XCTAssertEqual(snapshot.overallBudget.spentMinor, 40_00)
    }

    func testHomeSnapshotResolvesStaleRecentPayeeAndCategoryNames() async throws {
        let database = try makeDatabase()

        try await database.upsertPayees([
            Payee(id: "payee-1", name: "Target", lastUsedAt: nil)
        ])
        try await database.upsertCategories([
            CategorySyncPayload(
                id: "clothes",
                name: "Clothes",
                groupName: "Living",
                isIncome: false,
                budgetedMinor: 100_00,
                spentMinor: 0
            )
        ])

        var draft = TransactionDraft()
        draft.amountMinor = 20_00
        draft.payee = .existing(id: "payee-1")
        draft.accountID = "acct-1"
        draft.date = LocalDate("2026-03-03")
        draft.categoryMode = .single(categoryID: "clothes")
        _ = try await database.saveTransaction(
            draft: draft,
            payeeName: "Unknown",
            categorySummary: "Uncategorized",
            categoryIDs: ["clothes"],
            splits: []
        )

        let snapshot = try await database.fetchHomeSnapshot(filterMode: .all, recentLimit: 10)
        XCTAssertEqual(snapshot.recents.first?.payeeName, "Target")
        XCTAssertEqual(snapshot.recents.first?.categorySummary, "Clothes")
    }

    private func makeDatabase() throws -> DatabaseService {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("actual-sync-tests-\(UUID().uuidString).sqlite")
        return try DatabaseService(path: url.path(percentEncoded: false))
    }

    private func enqueueUpdateMutation(
        database: DatabaseService,
        accountID: String,
        date: String = "2026-03-03"
    ) async throws {
        let payload = APIUpdateTransactionPayload(
            accountID: accountID,
            date: date,
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

    private func enqueueCreatePayeeMutation(
        database: DatabaseService,
        name: String,
        state: PendingMutationState = .queued,
        lastError: String? = nil
    ) async throws {
        let envelope = MutationEnvelope(data: CreatePayeeMutation(proposedName: name, localTransactionID: nil))
        let mutation = PendingMutation(
            id: envelope.id,
            type: .createPayee,
            payload: try JSONEncoder().encode(envelope),
            state: state,
            retryCount: 0,
            createdAt: .now,
            nextAttemptAt: .now,
            lastError: lastError,
            transactionLocalID: nil
        )
        try await database.enqueueMutation(mutation)
    }

    private func enqueueCreateTransactionMutation(
        database: DatabaseService,
        localID: UUID = UUID(),
        state: PendingMutationState,
        importedID: String?,
        lastError: String? = nil
    ) async throws {
        let payload = APICreateTransactionPayload(
            accountID: "acct-1",
            date: "2026-03-03",
            amountMinor: -500,
            payeeID: nil,
            payeeName: "Coffee Shop",
            notes: "latte",
            categoryID: "food",
            splits: nil,
            importedID: importedID
        )
        let envelope = MutationEnvelope(
            data: CreateTransactionMutation(
                localTransactionID: localID,
                payload: payload
            )
        )
        let mutation = PendingMutation(
            id: envelope.id,
            type: .createTransaction,
            payload: try JSONEncoder().encode(envelope),
            state: state,
            retryCount: 0,
            createdAt: .now,
            nextAttemptAt: .now,
            lastError: lastError,
            transactionLocalID: localID
        )
        try await database.enqueueMutation(mutation)
    }

    private func saveLocalTransaction(database: DatabaseService, localID: UUID) async throws {
        var draft = TransactionDraft()
        draft.localID = localID
        draft.amountMinor = 500
        draft.payee = .new(name: "Coffee Shop")
        draft.accountID = "acct-1"
        draft.date = LocalDate("2026-03-03")
        draft.note = "latte"
        draft.categoryMode = .single(categoryID: "food")

        _ = try await database.saveTransaction(
            draft: draft,
            payeeName: "Coffee Shop",
            categorySummary: "Food",
            categoryIDs: ["food"],
            splits: []
        )
    }

    private func makeRemoteRecentTransaction(
        id: UUID,
        remoteID: String,
        accountID: String,
        date: String,
        amountMinor: Int64,
        payeeName: String,
        payeeID: String?,
        note: String,
        categoryIDs: [String],
        splits: [TransactionSplit]
    ) -> SyncedRecentTransactionItem {
        SyncedRecentTransactionItem(
            transaction: RecentTransactionItem(
                id: id,
                remoteID: remoteID,
                amountMinor: amountMinor,
                payeeName: payeeName,
                payeeID: payeeID,
                accountID: accountID,
                date: LocalDate(date),
                note: note,
                categorySummary: "Food",
                isSplit: !splits.isEmpty,
                categoryIDs: categoryIDs,
                updatedAt: .now
            ),
            splits: splits
        )
    }
}

private struct RecentRequest: Sendable {
    let limit: Int
    let daysBack: Int
    let accountIDs: [String]?
    let allowPartialFailures: Bool
}

private struct MockStats: Sendable {
    var fetchAccountsCount = 0
    var fetchPayeesCount = 0
    var fetchCategoriesCount = 0
    var fetchRecentRequests: [RecentRequest] = []
    var fetchBudgetSnapshotRequests: [[String]] = []
    var createPayeeCount = 0
    var createTransactionCount = 0
    var createdTransactionPayloads: [APICreateTransactionPayload] = []
    var updateTransactionCount = 0
    var deleteTransactionCount = 0
}

private actor MockAPIClient: ActualAPIClientProtocol {
    private var stats = MockStats()
    private var shouldFailUpdate = false
    private var shouldFailBudgetSnapshot = false
    private var fetchCategoriesResponse: [CategorySyncPayload] = []
    private var fetchRecentResponse: [SyncedRecentTransactionItem] = []
    private var fetchPayeesResponse: [Payee] = []
    private var payeeCounter = 0

    func setUpdateFailure(_ value: Bool) {
        shouldFailUpdate = value
    }

    func setBudgetSnapshotFailure(_ value: Bool) {
        shouldFailBudgetSnapshot = value
    }

    func setFetchCategoriesResponse(_ categories: [CategorySyncPayload]) {
        fetchCategoriesResponse = categories
    }

    func setFetchRecentResponse(_ transactions: [SyncedRecentTransactionItem]) {
        fetchRecentResponse = transactions
    }

    func setFetchPayeesResponse(_ payees: [Payee]) {
        fetchPayeesResponse = payees
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
        return fetchPayeesResponse
    }

    func fetchCategories() async throws -> [CategorySyncPayload] {
        stats.fetchCategoriesCount += 1
        return fetchCategoriesResponse
    }

    func fetchRecentTransactions(
        limit: Int,
        daysBack: Int,
        accountIDs: [String]?,
        allowPartialFailures: Bool
    ) async throws -> [SyncedRecentTransactionItem] {
        stats.fetchRecentRequests.append(
            RecentRequest(
                limit: limit,
                daysBack: daysBack,
                accountIDs: accountIDs,
                allowPartialFailures: allowPartialFailures
            )
        )
        return fetchRecentResponse
    }

    func fetchCategoryBudgetSnapshots(monthCandidates: [String]) async throws -> [CategoryBudgetSnapshot] {
        stats.fetchBudgetSnapshotRequests.append(monthCandidates)
        if shouldFailBudgetSnapshot {
            throw APIClientError.networkError(details: "forced budget snapshot failure")
        }
        return [
            CategoryBudgetSnapshot(id: "food", budgetedMinor: 100_00, spentMinor: 40_00)
        ]
    }

    func createPayee(name: String) async throws -> Payee {
        stats.createPayeeCount += 1
        payeeCounter += 1
        return Payee(id: "payee-\(payeeCounter)", name: name, lastUsedAt: .now)
    }

    func createTransaction(payload: APICreateTransactionPayload) async throws -> APISavedTransaction {
        stats.createTransactionCount += 1
        stats.createdTransactionPayloads.append(payload)
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
