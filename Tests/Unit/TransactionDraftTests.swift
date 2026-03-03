import XCTest
@testable import ActualCompanion

final class TransactionDraftTests: XCTestCase {
    func testSplitValidationRequiresFullAllocation() {
        let splits = [
            TransactionSplit(id: UUID(), categoryID: "food", amountMinor: 500),
            TransactionSplit(id: UUID(), categoryID: "fun", amountMinor: 200)
        ]

        let draft = TransactionDraft(
            localID: nil,
            remoteID: nil,
            amountMinor: 1000,
            payee: .new(name: "Cafe"),
            accountID: "checking",
            date: LocalDate("2026-03-02"),
            note: "",
            categoryMode: .split(splits)
        )

        XCTAssertFalse(draft.isCategoryValid)
        XCTAssertEqual(draft.splitRemainderMinor, 300)
    }

    func testValidSingleCategoryDraftCanSave() {
        let draft = TransactionDraft(
            localID: nil,
            remoteID: nil,
            amountMinor: 1234,
            payee: .new(name: "Target"),
            accountID: "checking",
            date: LocalDate("2026-03-02"),
            note: "",
            categoryMode: .single(categoryID: "clothes")
        )

        XCTAssertTrue(draft.isValidToSave)
    }
}
