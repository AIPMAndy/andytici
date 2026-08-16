import XCTest
@testable import Textream

final class PacingMonitorTests: XCTestCase {
    func testInitialState() {
        let m = PacingMonitor()
        XCTAssertEqual(m.wordsPerMinute, 0)
        XCTAssertEqual(m.status(), .idle)
    }

    func testSlowPacing() {
        let m = PacingMonitor()
        let now = Date()
        // 5 words over 5 seconds → 60 wpm → slow
        for i in 0..<5 {
            m.recordWord(at: now.addingTimeInterval(Double(i)))
        }
        XCTAssertLessThan(m.wordsPerMinute, 150)
        XCTAssertEqual(m.status(), .slow)
    }

    func testFastPacing() {
        let m = PacingMonitor()
        let now = Date()
        // 30 words in 5 seconds → 360 wpm → fast
        for i in 0..<30 {
            m.recordWord(at: now.addingTimeInterval(Double(i) * (5.0 / 30.0)))
        }
        XCTAssertGreaterThan(m.wordsPerMinute, 240)
        XCTAssertEqual(m.status(), .fast)
    }

    func testResetOnSilence() {
        let m = PacingMonitor()
        let now = Date()
        m.recordWord(at: now)
        // > 2 seconds silence → reset
        m.recordWord(at: now.addingTimeInterval(3))
        XCTAssertEqual(m.wordsPerMinute, 0)
        XCTAssertEqual(m.status(), .idle)
    }

    func testReset() {
        let m = PacingMonitor()
        m.recordWord()
        m.recordWord()
        m.reset()
        XCTAssertEqual(m.wordsPerMinute, 0)
    }

    func testPresetThreshold() {
        let m = PacingMonitor()
        let now = Date()
        // 12 words over 5s → 144 wpm
        for i in 0..<12 {
            m.recordWord(at: now.addingTimeInterval(Double(i) * (5.0 / 12.0)))
        }
        // douyin threshold 180-240 → slow
        XCTAssertEqual(m.status(for: .douyin), .slow)
        // xiaohongshu threshold 160-220 → normal
        XCTAssertEqual(m.status(for: .xiaohongshu), .normal)
    }
}