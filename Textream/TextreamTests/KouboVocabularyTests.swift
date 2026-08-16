import XCTest
@testable import Textream

final class KouboVocabularyTests: XCTestCase {
    func testVocabularyNotEmpty() {
        XCTAssertGreaterThan(KouboVocabulary.words.count, 10)
    }

    func testNoDuplicates() {
        let unique = Set(KouboVocabulary.words)
        XCTAssertEqual(unique.count, KouboVocabulary.words.count)
    }

    func testCommonWordsPresent() {
        XCTAssertTrue(KouboVocabulary.words.contains("点赞"))
        XCTAssertTrue(KouboVocabulary.words.contains("关注"))
        XCTAssertTrue(KouboVocabulary.words.contains("上链接"))
        XCTAssertTrue(KouboVocabulary.words.contains("福利"))
    }

    func testAllWordsShort() {
        for w in KouboVocabulary.words {
            XCTAssertFalse(w.isEmpty)
            XCTAssertLessThan(w.count, 15)
        }
    }
}