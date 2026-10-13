import XCTest
@testable import SerifCore

final class ScreenTextTests: XCTestCase {
    func testScreenSignalsOnProbeScreens() throws {
        XCTAssertTrue(screenSignals(in: try fixture("pty-s0-fiducia.txt")).contains(.trustPrompt))
        XCTAssertTrue(screenSignals(in: try fixture("pty-s4.txt")).contains(.interrupted))
        XCTAssertTrue(screenSignals(in: try fixture("pty-s3c.txt")).contains(.planApproval))
        XCTAssertTrue(screenSignals(in: "hello").isEmpty)
    }

    func testScreenSignalsWithRealSpaces() {
        XCTAssertEqual(screenSignals(in: "Interrupted · What should Claude do instead?"), [.interrupted])
        XCTAssertEqual(screenSignals(in: "Ready to code?\n Would you like to proceed?"), [.planApproval])
    }

    /// A headless terminal reads cells the TUI skipped with cursor moves as NUL, not as spaces (seen live with 2.1.296).
    func testScreenSignalsWithNulGaps() {
        let screen = "Quick safety check: Is this a project you created or one you trust?\n❯ No, exit\n  Yes, I trust this folder"
        XCTAssertEqual(screenSignals(in: screen.replacingOccurrences(of: " ", with: "\0")), [.trustPrompt])
    }

    func testTrustDialogSelection() {
        let dialog = "Is this a project you created or one you trust?\n"
        XCTAssertEqual(screenSignals(in: dialog + "❯ No, exit\n  Yes, I trust this folder"), [.trustPrompt])
        XCTAssertEqual(screenSignals(in: dialog + "  No, exit\n❯ Yes, I trust this folder"), [.trustConfirm])
        XCTAssertTrue(screenSignals(in: "❯ No, exit").isEmpty)    // only inside the trust dialog
    }
}
