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
}
