import XCTest
@testable import ActualCompanion

final class CategoryDetailTransactionTests: XCTestCase {
    func testFetchTransactionsForCategoryUsesMatchedSplitAmount() async throws {
        let database = try makeDatabase()

        try await database.upsertPayees([
            Payee(id: "payee-1", name: "Corner Store", lastUsedAt: nil)
        ])
        try await database.upsertCategories([
            CategorySyncPayload(id: "food", name: "Food", groupName: "Needs", isIncome: false, budgetedMinor: 0, spentMinor: 0),
            CategorySyncPayload(id: "fun", name: "Fun", groupName: "Wants", isIncome: false, budgetedMinor: 0, spentMinor: 0)
        ])

        let splits = [
            TransactionSplit(id: UUID(), categoryID: "food", amountMinor: 20_00),
            TransactionSplit(id: UUID(), categoryID: "fun", amountMinor: 30_00)
        ]

        var draft = TransactionDraft()
        draft.amountMinor = 50_00
        draft.payee = .existing(id: "payee-1")
        draft.accountID = "acct-1"
        draft.date = LocalDate("2026-03-04")
        draft.categoryMode = .split(splits)

        _ = try await database.saveTransaction(
            draft: draft,
            payeeName: "Corner Store",
            categorySummary: "Split: Food, Fun",
            categoryIDs: ["food", "fun"],
            splits: splits
        )

        let items = try await database.fetchTransactionsForCategory("food", monthPrefix: "2026-03", limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.displayAmountMinor, 20_00)
        XCTAssertEqual(items.first?.transaction.amountMinor, 50_00)
    }

    func testFetchTransactionsForCategorySumsDuplicateSplitLines() async throws {
        let database = try makeDatabase()

        try await database.upsertPayees([
            Payee(id: "payee-1", name: "Warehouse", lastUsedAt: nil)
        ])
        try await database.upsertCategories([
            CategorySyncPayload(id: "food", name: "Food", groupName: "Needs", isIncome: false, budgetedMinor: 0, spentMinor: 0),
            CategorySyncPayload(id: "household", name: "Household", groupName: "Needs", isIncome: false, budgetedMinor: 0, spentMinor: 0)
        ])

        let splits = [
            TransactionSplit(id: UUID(), categoryID: "food", amountMinor: 12_00),
            TransactionSplit(id: UUID(), categoryID: "food", amountMinor: 8_00),
            TransactionSplit(id: UUID(), categoryID: "household", amountMinor: 10_00)
        ]

        var draft = TransactionDraft()
        draft.amountMinor = 30_00
        draft.payee = .existing(id: "payee-1")
        draft.accountID = "acct-1"
        draft.date = LocalDate("2026-03-05")
        draft.categoryMode = .split(splits)

        _ = try await database.saveTransaction(
            draft: draft,
            payeeName: "Warehouse",
            categorySummary: "Split: Food, Household",
            categoryIDs: ["food", "food", "household"],
            splits: splits
        )

        let items = try await database.fetchTransactionsForCategory("food", monthPrefix: "2026-03", limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.displayAmountMinor, 20_00)
    }

    func testUpsertRecentTransactionsPersistsAndClearsSplitRows() async throws {
        let database = try makeDatabase()

        let transactionID = UUID()
        let remoteID = "remote-split-1"
        let initial = SyncedRecentTransactionItem(
            transaction: RecentTransactionItem(
                id: transactionID,
                remoteID: remoteID,
                amountMinor: -45_00,
                payeeName: "Coffee Shop",
                payeeID: nil,
                accountID: "acct-1",
                date: LocalDate("2026-03-06"),
                note: "",
                categorySummary: "Split (2)",
                isSplit: true,
                categoryIDs: ["coffee", "fun"],
                updatedAt: .now
            ),
            splits: [
                TransactionSplit(id: UUID(), categoryID: "coffee", amountMinor: -15_00),
                TransactionSplit(id: UUID(), categoryID: "fun", amountMinor: -30_00)
            ]
        )

        try await database.upsertRecentTransactions([initial])
        let savedSplits = try await database.fetchSplits(for: transactionID)
        XCTAssertEqual(savedSplits.map(\.amountMinor), [-15_00, -30_00])

        let updated = SyncedRecentTransactionItem(
            transaction: RecentTransactionItem(
                id: UUID(),
                remoteID: remoteID,
                amountMinor: -45_00,
                payeeName: "Coffee Shop",
                payeeID: nil,
                accountID: "acct-1",
                date: LocalDate("2026-03-06"),
                note: "",
                categorySummary: "Coffee",
                isSplit: false,
                categoryIDs: ["coffee"],
                updatedAt: .now.addingTimeInterval(1)
            ),
            splits: []
        )

        try await database.upsertRecentTransactions([updated])
        let clearedSplits = try await database.fetchSplits(for: transactionID)
        XCTAssertTrue(clearedSplits.isEmpty)
    }

    private func makeDatabase() throws -> DatabaseService {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("actual-category-detail-tests-\(UUID().uuidString).sqlite")
        return try DatabaseService(path: url.path(percentEncoded: false))
    }
}
