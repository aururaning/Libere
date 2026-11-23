import XCTest
@testable import MarginCore

final class PageLinkTests: XCTestCase {
    func testDirectoryLinksKeepStableIDsAndEscapeLabels() {
        let id = UUID()
        let url = PageLink.url(for: id)
        XCTAssertEqual(PageLink.noteID(in: url), id)
        let link = PageLink.markdown(title: "资料 [初稿] **重要**\n第二行", id: id)
        let rendered = Markdown.body("## 论文\n\n- " + link)
        XCTAssertTrue(rendered.contains("<h2>论文</h2>"))
        XCTAssertTrue(rendered.contains("href=\"\(url.absoluteString)\""))
        XCTAssertTrue(rendered.contains("资料 [初稿] **重要** 第二行"))
        XCTAssertFalse(rendered.contains("<strong>"))
    }
    func testEscapedPageTitlesDoNotTurnIntoMath() {
        let id = UUID()
        let title = #"资料 [x_i] (a+b) $5 **重要** `代码` \路径"#
        let html = Markdown.body(PageLink.markdown(title: title, id: id))
        XCTAssertTrue(html.contains(Formula.escape(title)))
        XCTAssertFalse(html.contains("<math "))
        XCTAssertFalse(html.contains("math-error"))
        XCTAssertTrue(html.contains("href=\"\(PageLink.url(for: id).absoluteString)\""))
        let mixed = Markdown.body(PageLink.markdown(title: title, id: id) + #" 和 \(x_i\)"#)
        XCTAssertEqual(mixed.components(separatedBy: "<math ").count - 1, 1)
    }
    func testOnlyExactLocalPageAddressesBecomeInternalLinks() {
        let id = UUID().uuidString
        for value in ["libere://page/not-a-uuid", "libere://page/\(id)/extra", "libere://other/\(id)",
                      "libere://user@page/\(id)", "libere://page:80/\(id)", "libere://page/\(id)?action=delete",
                      "libere://page/\(id)#fragment", "file:///\(id)", "javascript:evil"] {
            XCTAssertNil(PageLink.noteID(in: URL(string: value)!))
            XCTAssertFalse(Markdown.body("[目录](\(value))").contains("href="))
        }
    }
}
