import XCTest
@testable import Textream

final class ScriptTagTests: XCTestCase {
    func testParsePlainText() {
        let tokens = ScriptTag.tokenize("普通文字")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertNil(tokens[0].tag)
        XCTAssertEqual(tokens[0].text, "普通文字")
    }

    func testParseSingleTag() {
        let tokens = ScriptTag.tokenize("今天 🎯 教你")
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0].text, "今天 ")
        XCTAssertNil(tokens[0].tag)
        XCTAssertEqual(tokens[1].text, "🎯")
        XCTAssertEqual(tokens[1].tag, .emphasis)
    }

    func testParseMultipleTags() {
        let tokens = ScriptTag.tokenize("⚡ 首先 ⏸ 然后 ❗")
        let tags = tokens.compactMap { $0.tag }
        XCTAssertEqual(tags, [.highEnergy, .pause, .exclaim])
    }

    func testParseEmpty() {
        let tokens = ScriptTag.tokenize("")
        XCTAssertTrue(tokens.isEmpty)
    }

    func testParseConsecutiveTags() {
        let tokens = ScriptTag.tokenize("🎯⚡💡")
        XCTAssertEqual(tokens.count, 3)
    }

    func testTagDisplayName() {
        XCTAssertEqual(ScriptTagToken.Tag.emphasis.displayName, "关键词")
        XCTAssertEqual(ScriptTagToken.Tag.pause.displayName, "停顿")
        XCTAssertEqual(ScriptTagToken.Tag.exclaim.displayName, "感叹")
        XCTAssertEqual(ScriptTagToken.Tag.climax.displayName, "情绪高潮")
    }

    func testParseLongText() {
        let longText = String(repeating: "今天我来分享 ", count: 5)
        let tokens = ScriptTag.tokenize(longText)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].text, longText)
    }
}