import XCTest
@testable import Textream

final class PlatformPresetTests: XCTestCase {
    func testDouyinPreset() {
        let p = PlatformPreset.douyin
        XCTAssertEqual(p.charTarget, 300)
        XCTAssertEqual(p.pacingMin, 180)
        XCTAssertEqual(p.pacingMax, 240)
        XCTAssertEqual(p.locale, "zh-CN")
        XCTAssertEqual(p.displayName, "抖音")
    }

    func testXiaohongshuPreset() {
        let p = PlatformPreset.xiaohongshu
        XCTAssertEqual(p.charTarget, 450)
        XCTAssertEqual(p.pacingMin, 160)
        XCTAssertEqual(p.pacingMax, 220)
        XCTAssertEqual(p.locale, "zh-CN")
    }

    func testShipinhaoPreset() {
        let p = PlatformPreset.shipinhao
        XCTAssertEqual(p.charTarget, 300)
        XCTAssertEqual(p.pacingMin, 180)
        XCTAssertEqual(p.pacingMax, 220)
    }

    func testCustomPreset() {
        let p = PlatformPreset.custom(charTarget: 200, pacingMin: 150, pacingMax: 200, locale: "en-US", overlayWidth: 400)
        XCTAssertEqual(p.charTarget, 200)
        XCTAssertEqual(p.pacingMin, 150)
        XCTAssertEqual(p.pacingMax, 200)
        XCTAssertEqual(p.locale, "en-US")
        XCTAssertEqual(p.overlayWidth, 400)
    }

    func testPersistenceKey() {
        XCTAssertEqual(PlatformPreset.douyin.persistenceKey, "douyin")
        XCTAssertEqual(PlatformPreset.xiaohongshu.persistenceKey, "xiaohongshu")
    }

    func testFromPersistenceKey() {
        XCTAssertEqual(PlatformPreset.from(persistenceKey: "douyin"), .douyin)
        XCTAssertEqual(PlatformPreset.from(persistenceKey: "xiaohongshu"), .xiaohongshu)
        XCTAssertEqual(PlatformPreset.from(persistenceKey: "unknown"), .douyin)  // default fallback
    }

    func testAllPresetsChineseLocale() {
        for p in PlatformPreset.allPresets {
            XCTAssertEqual(p.locale, "zh-CN")
        }
    }
}