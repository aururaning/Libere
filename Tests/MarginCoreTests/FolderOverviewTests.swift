import Foundation
import XCTest
@testable import MarginCore

final class FolderOverviewTests: XCTestCase {
    func testLegacyFolderAndExplicitEmptyOverviewDecodeDifferently() throws {
        let original = Note(title: "课程资料", folder: true)
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "folderOverview")
        let legacy = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.folderOverview)
        object["folderOverview"] = ""
        let cleared = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(cleared.folderOverview, "")
        XCTAssertNotEqual(legacy, cleared)
        XCTAssertEqual(try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(cleared)).folderOverview, "")
    }

    func testFolderOverviewSurvivesCodingAndIsSearchable() throws {
        var folder = Note(title: "研究", folder: true)
        folder.folderOverview = "# 阅读分类\n\n## 方法\n- 算法笔记\n\n## 实验\n- 对比记录"
        folder.blocks = [Block(.text, frame: Rect(0, 0, 200, 100), text: "原有文字")]
        let restored = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(folder))
        XCTAssertEqual(restored, folder)
        XCTAssertTrue(restored.summary.contains("算法笔记"))
        XCTAssertTrue(restored.summary.contains("原有文字"))
        var ordinary = folder; ordinary.isFolder = false
        XCTAssertEqual(ordinary.summary, "原有文字")
    }
}
