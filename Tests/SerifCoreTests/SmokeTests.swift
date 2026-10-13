import XCTest
@testable import SerifCore

final class SmokeTests: XCTestCase {
    func testFixturesArePresent() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/hooks", withExtension: "jsonl"))
        XCTAssertGreaterThan(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 100)
    }
}
