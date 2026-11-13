import Foundation
import RingCore

final class TelegramMessageStyleTests {
    func testFormattingPreservesUntrustedTextAndReadableHierarchy() {
        let taskList = "Active tasks · 1\n\na1b2c3d4 · Q2 · Personal\nPack <b>Bilbo's</b> lunch & tea\n\n/task ID for details"
        let result = TelegramMessageStyle.html(taskList)
        XCTAssertTrue(result.hasPrefix("📋 <b>Active tasks · 1</b>"))
        XCTAssertTrue(result.contains("<code>a1b2c3d4</code> · Q2 · Personal"))
        XCTAssertTrue(result.contains("<b>Pack &lt;b&gt;Bilbo's&lt;/b&gt; lunch &amp; tea</b>"))
        XCTAssertFalse(result.contains("<b>Bilbo's</b>"))
        XCTAssertTrue(TelegramMessageStyle.html("2026-11-12 · Plan\n\n09:00–09:30 · Review the map").contains("<b>09:00–09:30</b> · Review the map"))
        XCTAssertTrue(TelegramMessageStyle.html(TelegramCommands.help).contains("🧭 <b>Commands</b>"))
        XCTAssertTrue(TelegramMessageStyle.html(TelegramCommands.help).contains("<code>/today</code>"))
        XCTAssertEqual(TelegramMessageStyle.html("Saved to Inbox · <map>"),"📥 <b>Saved to Inbox</b>\n&lt;map&gt;")
        XCTAssertTrue(TelegramMessageStyle.html("Transcribed · saved in Inbox.").hasPrefix("🎙"))
    }
    func testFormattingClipsWholeUnicodeCharactersAndClosesMarkup() {
        let long = String(repeating:"👨‍👩‍👧‍👦 & <tag> ",count:1000)
        let result = TelegramMessageStyle.html(long)
        XCTAssertTrue(result.hasSuffix("</b>\n…") || result.hasSuffix("…</b>"))
        XCTAssertFalse(result.contains("\u{fffd}"))
        XCTAssertFalse(result.contains("<tag>"))
        let decoded = result.replacingOccurrences(of:"<b>",with:"").replacingOccurrences(of:"</b>",with:"").replacingOccurrences(of:"&amp;",with:"&").replacingOccurrences(of:"&lt;",with:"<").replacingOccurrences(of:"&gt;",with:">")
        XCTAssertLessThanOrEqual(decoded.utf16.count,4096)
        XCTAssertEqual(TelegramMessageStyle.html(""),"💍 <b></b>")
    }
}
