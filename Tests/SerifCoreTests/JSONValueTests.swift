import XCTest
@testable import SerifCore

final class JSONValueTests: XCTestCase {
    func testParsesNestedPayload() throws {
        let v = try JSONValue.parse(Data(#"{"a":{"b":[1,true,"x",null]},"n":2.5}"#.utf8))
        XCTAssertEqual(v["a"]?["b"]?.array?.count, 4)
        XCTAssertEqual(v["a"]?["b"]?.array?[1].bool, true)
        XCTAssertEqual(v["n"]?.double, 2.5)
        XCTAssertNil(v["missing"])
    }
    func testIntAccessorAcceptsWholeNumbersOnly() throws {
        XCTAssertEqual(try JSONValue.parse(Data("3".utf8)).int, 3)
        XCTAssertNil(try JSONValue.parse(Data("3.5".utf8)).int)
    }
    func testRoundTrip() throws {
        let v: JSONValue = .object(["k": .array([.string("é"), .number(1), .null])])
        XCTAssertEqual(try JSONValue.parse(v.encoded()), v)
    }
}
