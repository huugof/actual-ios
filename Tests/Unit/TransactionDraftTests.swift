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

    func testShiftedCurrencyInputProgression() {
        XCTAssertEqual(MoneyFormatter.normalizeShiftedCurrencyInput("1"), "0.01")
        XCTAssertEqual(MoneyFormatter.normalizeShiftedCurrencyInput("12"), "0.12")
        XCTAssertEqual(MoneyFormatter.normalizeShiftedCurrencyInput("123"), "1.23")
    }

    func testShiftedCurrencyInputEmptyDefaultsToZero() {
        XCTAssertEqual(MoneyFormatter.normalizeShiftedCurrencyInput(""), "0.00")
        XCTAssertEqual(MoneyFormatter.shiftedInputToMinor(""), 0)
    }

    func testShiftedCurrencyInputHandlesBackspaceLikeFlow() {
        XCTAssertEqual(MoneyFormatter.normalizeShiftedCurrencyInput("1.2"), "0.12")
        XCTAssertEqual(MoneyFormatter.shiftedInputToMinor("1.2"), 12)
    }

    func testLocalDateRoundTripThroughDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let local = LocalDate("2026-03-05")
        let parsed = try XCTUnwrap(local.toDate(calendar: calendar))
        XCTAssertEqual(LocalDate(date: parsed, calendar: calendar).value, "2026-03-05")
    }

    func testLocalDateInvalidStringReturnsNilDate() {
        XCTAssertNil(LocalDate("not-a-date").toDate())
        XCTAssertNil(LocalDate("2026-13-40").toDate())
    }

    @MainActor
    func testAddModeAmountStartsEmptyForImmediateTyping() throws {
        let service = TransactionService(database: try makeDatabase())
        let viewModel = AddEditTransactionViewModel(mode: .add, service: service)
        XCTAssertEqual(viewModel.amountText, "")
    }

    @MainActor
    func testMainAmountTyping2034ProducesShiftedCents() throws {
        let service = TransactionService(database: try makeDatabase())
        let viewModel = AddEditTransactionViewModel(mode: .add, service: service)
        let expected = ["0.02", "0.20", "2.03", "20.34"]
        for (digit, output) in zip(["2", "0", "3", "4"], expected) {
            viewModel.updateAmount(viewModel.amountText + digit)
            XCTAssertEqual(viewModel.amountText, output)
        }
    }

    @MainActor
    func testSplitAmountTyping2034ProducesShiftedCents() throws {
        let service = TransactionService(database: try makeDatabase())
        let viewModel = AddEditTransactionViewModel(mode: .add, service: service)
        let lineID = try XCTUnwrap(viewModel.splitLines.first?.id)
        XCTAssertEqual(viewModel.splitAmountText(for: lineID), "")

        let expected = ["0.02", "0.20", "2.03", "20.34"]
        for (digit, output) in zip(["2", "0", "3", "4"], expected) {
            viewModel.updateSplitAmount(id: lineID, amountText: viewModel.splitAmountText(for: lineID) + digit)
            XCTAssertEqual(viewModel.splitAmountText(for: lineID), output)
        }

        let updatedLine = viewModel.splitLines.first(where: { $0.id == lineID })
        XCTAssertEqual(updatedLine?.amountMinor, 2_034)
    }

    private func makeDatabase() throws -> DatabaseService {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("actual-amount-input-tests-\(UUID().uuidString).sqlite")
        return try DatabaseService(path: url.path(percentEncoded: false))
    }
}
