import XCTest
@testable import ActualCompanion

final class TransactionServiceAmountSignTests: XCTestCase {
    func testNormalizedOutflowMinorConvertsPositiveToNegative() {
        XCTAssertEqual(TransactionService.normalizedOutflowMinor(1234), -1234)
    }

    func testNormalizedOutflowMinorKeepsNegativeNegative() {
        XCTAssertEqual(TransactionService.normalizedOutflowMinor(-987), -987)
    }

    func testNormalizedOutflowSplitsConvertsEachLineToNegativeOutflow() {
        let splits = [
            TransactionSplit(id: UUID(), categoryID: "food", amountMinor: 1000),
            TransactionSplit(id: UUID(), categoryID: "fun", amountMinor: 250)
        ]

        let payload = TransactionService.normalizedOutflowSplits(splits)
        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload.map(\.amountMinor), [-1000, -250])
        XCTAssertEqual(payload.reduce(Int64(0)) { $0 + $1.amountMinor }, -1250)
    }

    func testFetchAllCategoriesReturnsAllExpenseCategories() async throws {
        let database = try makeDatabase()
        let service = TransactionService(database: database)
        try await database.upsertCategories([
            CategorySyncPayload(id: "a", name: "Alpha", groupName: "G1", isIncome: false, budgetedMinor: 0, spentMinor: 0),
            CategorySyncPayload(id: "b", name: "Beta", groupName: "G1", isIncome: false, budgetedMinor: 0, spentMinor: 0),
            CategorySyncPayload(id: "income", name: "Income", groupName: "G2", isIncome: true, budgetedMinor: 0, spentMinor: 0)
        ])

        let categories = try await service.fetchAllCategories()
        XCTAssertEqual(Set(categories.map(\.id)), Set(["a", "b"]))
    }

    func testCreateTransactionAppliesImmediateCurrentMonthSpentDelta() async throws {
        let database = try makeDatabase()
        let service = TransactionService(database: database)

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
        draft.date = LocalDate()
        draft.categoryMode = .single(categoryID: "clothes")
        let localID = try await service.createOrUpdateTransaction(draft)

        let created = try await database.fetchRecentTransaction(id: localID)
        XCTAssertEqual(created?.payeeName, "Target")
        XCTAssertEqual(created?.categorySummary, "Clothes")

        let snapshotAfterCreate = try await database.fetchHomeSnapshot(filterMode: .all, recentLimit: 10)
        XCTAssertEqual(snapshotAfterCreate.overallBudget.spentMinor, 20_00)

        if let created {
            try await service.deleteTransaction(created)
        }
        let snapshotAfterDelete = try await database.fetchHomeSnapshot(filterMode: .all, recentLimit: 10)
        XCTAssertEqual(snapshotAfterDelete.overallBudget.spentMinor, 0)
    }

    func testUpsertCategoriesPrunesStaleCategoriesFromOverallBudgetAndTrackedSet() async throws {
        let database = try makeDatabase()
        let service = TransactionService(database: database)

        try await database.upsertCategories([
            CategorySyncPayload(id: "current", name: "Current", groupName: "Needs", isIncome: false, budgetedMinor: 100_00, spentMinor: 50_00),
            CategorySyncPayload(id: "stale", name: "Stale", groupName: "Needs", isIncome: false, budgetedMinor: 110_00, spentMinor: 110_00)
        ])
        try await database.setTrackedCategoryIDs(["current", "stale"])

        try await database.upsertCategories([
            CategorySyncPayload(id: "current", name: "Current", groupName: "Needs", isIncome: false, budgetedMinor: 100_00, spentMinor: 50_00)
        ])

        let snapshot = try await database.fetchHomeSnapshot(filterMode: .all, recentLimit: 10)
        XCTAssertEqual(snapshot.overallBudget.budgetedMinor, 100_00)
        XCTAssertEqual(snapshot.overallBudget.spentMinor, 50_00)

        let trackedIDs = try await database.fetchTrackedCategoryIDs()
        XCTAssertEqual(trackedIDs, ["current"])

        let categories = try await service.fetchAllCategories()
        XCTAssertEqual(categories.map(\.id), ["current"])
    }

    func testPrunedCategoriesDoNotBreakRecentTransactionCategorySummary() async throws {
        let database = try makeDatabase()

        try await database.upsertCategories([
            CategorySyncPayload(id: "legacy", name: "Legacy", groupName: "Old", isIncome: false, budgetedMinor: 110_00, spentMinor: 110_00)
        ])

        var draft = TransactionDraft()
        draft.amountMinor = 11_00
        draft.payee = .new(name: "Coffee")
        draft.accountID = "acct-1"
        draft.date = LocalDate("2026-03-10")
        draft.categoryMode = .single(categoryID: "legacy")

        _ = try await database.saveTransaction(
            draft: draft,
            payeeName: "Coffee",
            categorySummary: "Legacy",
            categoryIDs: ["legacy"],
            splits: []
        )

        try await database.upsertCategories([])

        let snapshot = try await database.fetchHomeSnapshot(filterMode: .all, recentLimit: 10)
        XCTAssertEqual(snapshot.overallBudget.budgetedMinor, 0)
        XCTAssertEqual(snapshot.overallBudget.spentMinor, 0)
        XCTAssertEqual(snapshot.recents.first?.categorySummary, "Legacy")
    }

    private func makeDatabase() throws -> DatabaseService {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("actual-transaction-tests-\(UUID().uuidString).sqlite")
        return try DatabaseService(path: url.path(percentEncoded: false))
    }
}
