import Foundation
#if SWIFT_PACKAGE
import MarginCore
#endif

/// A reader page is local to its window; the canvas preview page is stored on the block.
struct AttachmentPagination: Equatable {
    let page: Int
    let pageCount: Int
    init(page: Int, pageCount: Int) {
        self.pageCount = max(0, pageCount)
        self.page = pageCount > 0 ? min(max(0, page), pageCount - 1) : 0
    }
    var hasPrevious: Bool { pageCount > 0 && page > 0 }
    var hasNext: Bool { pageCount > 0 && page < pageCount - 1 }
    var label: String { pageCount > 0 ? "第 \(page + 1) / \(pageCount) 页" : "无可用页面" }
    func moved(by delta: Int) -> Int? {
        guard pageCount > 0, delta != 0 else { return nil }
        let (sum, overflow) = page.addingReportingOverflow(delta)
        let next = overflow ? (delta > 0 ? pageCount - 1 : 0) : min(max(0, sum), pageCount - 1)
        return next == page ? nil : next
    }
}

extension Block {
    var attachmentContentIdentity: String {
        "\(id)-\(kind.rawValue)-\(displayAssetID?.uuidString ?? "")-\(relativeFilePath ?? "")-\(contentRevision?.uuidString ?? "")"
    }
}
