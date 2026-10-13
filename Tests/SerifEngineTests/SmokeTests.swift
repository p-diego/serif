import XCTest

final class SmokeTests: XCTestCase {
    // Checks that the executable dependencies were built next to the test bundle.
    func testHelperBinariesAreBuilt() {
        let dir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        for name in ["serif-hook", "fake-claude"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "\(name) not built")
        }
    }
}
