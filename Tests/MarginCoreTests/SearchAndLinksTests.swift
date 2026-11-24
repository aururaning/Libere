import XCTest
@testable import MarginCore

final class SearchAndLinksTests: XCTestCase {
    func testSearchFindsEachMetadataFieldAndRetainsPreciseDestination() {
        var folder = Note(title: "物理资料", folder: true); folder.folderOverview = "课程介绍与分类"
        var note = Note(title: "量子力学", parent: folder.id); note.tags = ["研究", "Physics"]
        let text = Block(.text, frame: Rect(0,0,300,200), text: "波函数与测量")
        let formula = Block(.formula, frame: Rect(0,240,300,200), text: #"\Psi_{special}"#)
        var file = Block(.pdf, frame: Rect(400,0,300,500)); file.assetName = "实验讲义.pdf"; file.relativeFilePath = "offline/实验讲义.pdf"; file.sourceURL = "https://example.org/paper-origin"
        var annotation = AttachmentPageAnnotations(); let mark = PageTextAnnotation(frame: Rect(0,0,100,100), text: "这是第七页的积分批注")
        annotation.texts = [mark]; file.pageAnnotations = ["6": annotation]
        var link = Block(.link, frame: Rect(0,500,300,200)); link.linkURL = "https://example.org/resource-link"
        note.blocks = [text, formula, file, link]
        let workspace = Workspace(notes: [folder, note]), index = WorkspaceSearch(workspace: workspace)
        let examples: [(String, SearchContentKind, UUID?)] = [("量子力学", .title, nil), ("课程介绍", .overview, nil), ("波函数", .text, text.id), ("special", .formula, formula.id), ("实验讲义", .file, file.id), ("paper-origin", .link, file.id), ("resource-link", .link, link.id)]
        for (query, kind, id) in examples {
            let found = index.results(query: query)
            XCTAssertEqual(found.first?.kind, kind); XCTAssertEqual(found.first?.blockID, id)
        }
        let found = index.results(query: "积分批注").first
        XCTAssertEqual(found?.noteID, note.id); XCTAssertEqual(found?.blockID, file.id)
        XCTAssertEqual(found?.annotationID, mark.id); XCTAssertEqual(found?.annotationPage, 6)
        XCTAssertEqual(found?.path, "物理资料 / 量子力学")
        XCTAssertTrue(index.results(query: "未提供给索引的原文件内容").isEmpty)
    }
    func testSearchUsesANDTermsTagFiltersAndUnicodeFolding() {
        var a = Note(title: "Résumé 研究"); a.tags = ["Physics", "Quantum Mechanics"]
        a.blocks = [Block(.text, frame: Rect(0,0,300,200), text: "测量结果 ＡＢＣ 波函数")]
        var b = Note(title: "别的页面"); b.tags = ["其他"]; b.blocks = a.blocks
        var deleted = a; deleted.id = UUID(); deleted.deleted = true
        let index = WorkspaceSearch(workspace: Workspace(notes: [a,b,deleted]))
        XCTAssertEqual(index.results(query: "resume 测量").map(\.noteID), [a.id])
        XCTAssertEqual(index.results(query: "#physics abc").map(\.noteID), [a.id])
        XCTAssertEqual(index.results(query: "\"#Quantum Mechanics\" 波函数").map(\.noteID), [a.id])
        XCTAssertTrue(index.results(query: "#physics 不存在").isEmpty)
        XCTAssertEqual(index.results(query: "#physics").count, 1)
    }
    func testEmptyQueryShowsRecentPagesAndBoundedResults() {
        var a = Note(title: "旧页面"), b = Note(title: "新页面")
        a.modifiedAt = Date(timeIntervalSince1970: 1); b.modifiedAt = Date(timeIntervalSince1970: 2)
        a.blocks = [Block(.text, frame: Rect(0,0,300,200), text: "旧页面的正文")]
        let index = WorkspaceSearch(workspace: Workspace(notes: [a,b]))
        XCTAssertEqual(index.results(query: "").map(\.noteID), [b.id,a.id])
        XCTAssertEqual(index.results(query: "页面", limit: 1).count, 1)
        XCTAssertTrue(index.results(query: "页面", limit: 0).isEmpty)
        XCTAssertEqual(index.results(query: "旧页面").filter { $0.kind == .title }.count, 1)
    }
    func testSnippetRetainsUnicodeAndTheDistantMatch() {
        var note = Note(title: "长正文")
        note.blocks = [Block(.text, frame: Rect(0,0,300,200), text: String(repeating: "👨‍👩‍👧‍👦", count: 300) + "关键证据" + String(repeating: "后文", count: 300))]
        let result = WorkspaceSearch.results(in: Workspace(notes: [note]), query: "关键证据").first!
        XCTAssertTrue(result.snippet.contains("关键证据")); XCTAssertLessThanOrEqual(result.snippet.count, 162)
        XCTAssertFalse(result.snippet.contains("�"))
    }
    func testTagNormalizationDeduplicatesAndPreservesLabels() {
        XCTAssertEqual(WorkspaceSearch.normalizedTags("#研究, Physics，physics; , ##第二个\n研究"), ["研究","Physics","第二个"])
    }
    func testAnnotationResultIdentityIncludesItsPage() {
        var note = Note(title: "批注")
        var block = Block(.pdf, frame: Rect(0,0,300,400)), page = AttachmentPageAnnotations()
        page.texts = [PageTextAnnotation(frame: Rect(0,0,100,50), text: "重复批注")]
        block.pageAnnotations = ["0": page, "1": page]; note.blocks = [block]
        let found = WorkspaceSearch.results(in: Workspace(notes: [note]), query: "重复批注")
        XCTAssertEqual(found.count, 2); XCTAssertEqual(Set(found.map(\.id)).count, 2)
        XCTAssertEqual(Set(found.compactMap(\.annotationPage)), [0,1])
    }
    func testWikiResolutionNeverChoosesAnArbitraryDuplicateTitle() {
        let a = Note(title: "笔记"), b = Note(title: "笔记")
        var deleted = Note(title: "唯一"); deleted.deleted = true
        let one = Note(title: "Unique")
        let workspace = Workspace(notes: [a,b,deleted,one])
        guard case .ambiguous(let ids) = WikiLinks.resolve(title: "笔记", in: workspace) else { return XCTFail("Expected duplicate title ambiguity") }
        XCTAssertEqual(Set(ids), [a.id,b.id])
        XCTAssertEqual(WikiLinks.resolve(title: " unique ", in: workspace), .unique(one.id))
        XCTAssertEqual(WikiLinks.resolve(title: "唯一", in: workspace), .missing)
        XCTAssertEqual(WikiLinks.renderingSource("[[笔记]]", in: workspace), "[[笔记]]")
        XCTAssertEqual(WikiLinks.renderingSource("[[Unique|说明]]", in: workspace), PageLink.markdown(title: "说明", id: one.id))
    }
    func testCompletionUsesUTF16RangesAndReplacesClosingBrackets() {
        let source = "👩🏽‍💻 开始 [[研]] 之后"
        let caret = ("👩🏽‍💻 开始 [[研" as NSString).length
        let completion = WikiLinks.completion(in: source, caretUTF16: caret)!
        XCTAssertEqual(completion.query, "研")
        XCTAssertEqual((source as NSString).substring(with: completion.range), "[[研]]")
        XCTAssertNil(WikiLinks.completion(in: "[[完成]]", caretUTF16: 6))
        XCTAssertNil(WikiLinks.completion(in: #"\[[研"#, caretUTF16: 4))
        XCTAssertNil(WikiLinks.completion(in: "```\n[[研", caretUTF16: 7))
        XCTAssertNil(WikiLinks.completion(in: "[[跨\n行", caretUTF16: 5))
    }
    func testWikiCandidatesShowHierarchyAndStableLinkIdentity() {
        let parent = Note(title: "课程", folder: true)
        let one = Note(title: "笔记", parent: parent.id), two = Note(title: "笔记")
        let workspace = Workspace(notes: [parent,one,two])
        let choices = WikiLinks.candidates(in: workspace, query: "笔记")
        XCTAssertEqual(choices.count, 2); XCTAssertEqual(choices.first { $0.id == one.id }?.path, "课程 / 笔记")
        XCTAssertEqual(choices.first { $0.id == two.id }?.markdown, PageLink.markdown(title: two.title, id: two.id))
        XCTAssertEqual(WikiLinks.candidates(in: workspace, query: "笔记", excluding: one.id).map(\.id), [two.id])
    }
    func testBacklinksIncludeMarkdownIDsWikiAndAnnotationsButNotCodeOrAmbiguity() {
        let target = Note(title: "目标")
        var source = Note(title: "来源", folder: true)
        source.folderOverview = "[[目标]] 和 " + PageLink.markdown(title: "另一个名字", id: target.id)
        var text = Block(.text, frame: Rect(0,0,300,200), text: "`[[目标]]`\n```md\n[[目标]]\n```\n真实 [[目标]]")
        var annotation = AttachmentPageAnnotations(); annotation.texts = [PageTextAnnotation(frame: Rect(0,0,100,50), text: "批注 [[目标]]")]
        text.pageAnnotations = ["2": annotation]; source.blocks = [text]
        let workspace = Workspace(notes: [target,source])
        let found = WikiLinks.backlinks(to: target.id, in: workspace)
        XCTAssertEqual(found.count, 3); XCTAssertEqual(found.first { $0.sourceBlockID == nil }?.count, 2)
        XCTAssertEqual(found.first { $0.sourceBlockID == text.id && $0.annotationPage == nil }?.count, 1)
        XCTAssertEqual(found.first { $0.annotationPage == 2 }?.sourceNoteID, source.id)
        let duplicate = Note(title: "目标")
        XCTAssertEqual(WikiLinks.backlinks(to: target.id, in: Workspace(notes: [target,duplicate,source])).map(\.count), [1])
    }
    func testLinkScannerProtectsCodeMathEscapesAndInvalidPageAddresses() {
        let id = UUID(), url = PageLink.url(for: id).absoluteString
        let source = #"\[[literal]] `[[code]]` $\text{[[math]]}$ \([[math2]]\) [[real]] "# + url + "?bad=1 " + url
        let tokens = WikiLinks.references(in: source)
        XCTAssertEqual(tokens.count, 2); XCTAssertEqual(tokens.first?.title, "real"); XCTAssertEqual(tokens.last?.pageID, id)
        XCTAssertEqual(WikiLinks.references(in: "```md\n[[code]]\n````\n[[after]]").compactMap(\.title), ["after"])
        XCTAssertEqual(WikiLinks.references(in: "`` code ` [[hidden]] `` [[shown]]").compactMap(\.title), ["shown"])
        XCTAssertEqual(WikiLinks.references(in: "价格 $5 和 [[资料]] 为 $10").compactMap(\.title), ["资料"])
    }
}
