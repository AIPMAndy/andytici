import XCTest
@testable import Textream

final class HookTemplateTests: XCTestCase {
    func testAllTemplatesPresent() {
        XCTAssertGreaterThanOrEqual(HookTemplate.all.count, 11)
    }

    func testCategoriesExist() {
        let categories = Set(HookTemplate.all.map { $0.category })
        XCTAssertTrue(categories.contains(.painPoint))
        XCTAssertTrue(categories.contains(.contrast))
        XCTAssertTrue(categories.contains(.number))
        XCTAssertTrue(categories.contains(.suspense))
    }

    func testFillTemplate() {
        let t = HookTemplate.all.first { $0.template.contains("你是不是也") }!
        let filled = t.fill(with: "刷到这条视频")
        XCTAssertTrue(filled.contains("你是不是也"))
        XCTAssertTrue(filled.contains("刷到这条视频"))
    }

    func testAllTemplatesShort() {
        for t in HookTemplate.all {
            XCTAssertLessThan(t.template.count, 60, "Template too long: \(t.template)")
        }
    }

    func testTemplatesHaveExamples() {
        for t in HookTemplate.all {
            XCTAssertFalse(t.exampleFilled.isEmpty)
        }
    }

    func testTemplatesUnique() {
        let templates = HookTemplate.all.map { $0.template }
        let unique = Set(templates)
        XCTAssertEqual(unique.count, templates.count)
    }
}