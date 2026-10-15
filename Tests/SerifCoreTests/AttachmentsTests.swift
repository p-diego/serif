import XCTest
@testable import SerifCore

final class AttachmentsTests: XCTestCase {
    private let rome = TimeZone(identifier: "Europe/Rome")!
    private let day = Date(timeIntervalSince1970: 1_792_013_400)     // 14 Oct 2026, 23:30 in Rome (21:30 UTC)

    func testTheDayFolderFollowsTheLocalDate() {
        XCTAssertEqual(attachmentFolder(day: day, timeZone: rome), "allegati/2026-10-14")
        XCTAssertEqual(attachmentFolder(day: day.addingTimeInterval(3600), timeZone: rome), "allegati/2026-10-15")
    }

    func testNamesAreSafeAndUnique() {
        // Spec §4: `-2`, `-3` before the extension; never a path of the sender's choosing.
        XCTAssertEqual(uniqueFileName("foto.png", taken: []), "foto.png")
        XCTAssertEqual(uniqueFileName("foto.png", taken: ["foto.png"]), "foto-2.png")
        XCTAssertEqual(uniqueFileName("foto.png", taken: ["foto.png", "foto-2.png"]), "foto-3.png")
        XCTAssertEqual(uniqueFileName("notes", taken: ["notes"]), "notes-2")
        XCTAssertEqual(uniqueFileName("a.tar.gz", taken: ["a.tar.gz"]), "a.tar-2.gz")
        XCTAssertEqual(safeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(safeFileName("/Users/x/Desktop/foto.png"), "foto.png")
        XCTAssertEqual(safeFileName(" "), "file")
        XCTAssertEqual(safeFileName(".."), "file")
        XCTAssertEqual(safeFileName("a\nb\tc.png"), "a b c.png")
        let long = safeFileName(String(repeating: "x", count: 300) + ".png")
        XCTAssertEqual(long.utf8.count, 200); XCTAssertTrue(long.hasSuffix("x.png"))
        XCTAssertLessThanOrEqual(safeFileName(String(repeating: "é", count: 300) + ".png").utf8.count, 200)
        // Case-insensitive, as APFS is by default.
        XCTAssertEqual(uniqueFileName("Foto.png", taken: ["foto.png"]), "Foto-2.png")
        XCTAssertEqual(uniqueFileName("Foto.png", taken: ["foto.png", "FOTO-2.png"]), "Foto-3.png")
    }

    func testTheLimits() {
        XCTAssertNil(attachmentProblem([("a.png", 16 << 20)]))
        XCTAssertEqual(attachmentProblem([("a.png", 1), ("big.mov", (16 << 20) + 1)]), "big.mov is larger than 16 MB")
        XCTAssertNil(attachmentProblem((1...10).map { ("f\($0)", 1) }))
        XCTAssertEqual(attachmentProblem((1...11).map { ("f\($0)", 1) }), "at most 10 files per message")
    }

    func testWhatTheBotReads() {
        // Spec §4, verbatim: the list under the text, images marked; files alone when there is no text.
        let paths = ["allegati/2026-10-15/foto.png", "allegati/2026-10-15/note.pdf"]
        XCTAssertEqual(attachmentsText(paths),
                       "Attached files (in the project's shared folder):\n- allegati/2026-10-15/foto.png (image)\n- allegati/2026-10-15/note.pdf")
        XCTAssertEqual(messageText("Look", attachments: paths), "Look\n\n" + attachmentsText(paths))
        XCTAssertEqual(messageText("", attachments: paths), attachmentsText(paths))
        XCTAssertEqual(messageText("Look", attachments: []), "Look")
        XCTAssertTrue(isImage("x/Foto.JPG")); XCTAssertTrue(isImage("a.heic")); XCTAssertFalse(isImage("a.pdf")); XCTAssertFalse(isImage("png"))
    }

    func testCodexGetsImagesAsLocalImageItems() {
        // Spec §4: the text first, then each image by its absolute path; a PDF only in the text.
        let input = codexInput(text: "Look", attachments: ["allegati/2026-10-15/foto.png", "allegati/2026-10-15/note.pdf"],
                               sharedFolder: "/data/projects/p/shared")
        XCTAssertEqual(input, [["type": "text", "text": "Look"],
                               ["type": "localImage", "path": "/data/projects/p/shared/allegati/2026-10-15/foto.png"]])
        // heic, tiff and bmp stay a plain path (no "(image)"), so the bot knows it must convert them first.
        XCTAssertEqual(codexInput(text: "x", attachments: ["a/foto.heic", "a/b.tiff", "a/c.bmp"], sharedFolder: "/s"),
                       [["type": "text", "text": "x"]])
        XCTAssertFalse(attachmentsText(["a/foto.heic"]).contains("(image)"))
        XCTAssertEqual(codexInput(text: "Hi", attachments: [], sharedFolder: "/s"), [["type": "text", "text": "Hi"]])
    }

    func testTheInstructionsNoticeHeadsTheMessage() {
        // Spec §6, verbatim.
        XCTAssertEqual(instructionsNotice("Be brief.", before: "hello"),
                       "Your instructions have changed. From now on follow these:\n\nBe brief.\n\n---\n\nhello")
    }
}
