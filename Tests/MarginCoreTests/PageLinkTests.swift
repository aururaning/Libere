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
