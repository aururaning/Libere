import Foundation
import XCTest
@testable import MarginCore

final class FolderOverviewTests: XCTestCase {
    func testSummaryMatchesJoinedPrefixWithUnicodeEmptyAndLongSources() {
        for folder in [false, true] {
            for overview in [nil, "", "文件夹介绍\n", String(repeating: "👩🏽‍💻", count: 121)] as [String?] {
                var note = Note(title: "摘要", folder: folder)
                note.folderOverview = overview
                note.blocks = ["", "e\u{301} 中文", "", String(repeating: "👨‍👩‍👦笔记", count: 200), "不应影响摘要的长尾"]
                    .map { Block(.text, frame: Rect(0, 0, 200, 100), text: $0) }
                note.blocks.insert(Block(.formula, frame: Rect(0, 0, 200, 100), text: "忽略公式"), at: 0)
                let introduction = folder ? overview.map { [$0] } ?? [] : []
                let expected = String((introduction + note.blocks.filter { $0.kind == .text }.map(\.text))
                    .filter { !$0.isEmpty }.joined(separator: " ").prefix(120))
                XCTAssertEqual(note.summary, expected)
            }
        }
        var note = Note(title: "边界")
        note.blocks = [String(repeating: "a", count: 119), "b"].map { Block(.text, frame: Rect(0, 0, 200, 100), text: $0) }
        XCTAssertEqual(note.summary, String(repeating: "a", count: 119) + " ")
    }

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
