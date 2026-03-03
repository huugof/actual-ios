import XCTest
@testable import ActualCompanion

final class LookupRankerTests: XCTestCase {
    func testStartsWithRankedBeforeContains() {
        let results = LookupRanker.rank(
            query: "ca",
            values: ["vacation", "cafe", "snacks", "car wash"]
        )

        XCTAssertEqual(results.first, "cafe")
        XCTAssertEqual(results[1], "car wash")
    }
}
