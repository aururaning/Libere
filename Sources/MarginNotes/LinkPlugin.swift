import SwiftUI
import WebKit
#if SWIFT_PACKAGE
import MarginCore
#endif

extension AppStore {
    func pasteLink(mode: LinkDisplayMode = .card) {
        #if os(macOS)
        let value = NSPasteboard.general.string(forType: .string) ?? ""
        #else
        let value = UIPasteboard.general.string ?? ""
        #endif
        insertLink(value, mode: mode)
    }
    func insertLink(_ value: String, mode: LinkDisplayMode) {
        guard let url = WebLink.url(value) else { message = "请先复制一个 http 或 https 网页链接。"; return }
        insert(.link, name: url.host ?? "网页")
        guard let id = blockSelection, block?.kind == .link, let noteID = selection else { return }
        editBlock(id) { $0.linkURL = url.absoluteString; $0.linkMode = mode }
        if mode == .html { Task { await fetchHTML(noteID: noteID, blockID: id) } }
    }
    func setLinkMode(_ mode: LinkDisplayMode, noteID: UUID, blockID: UUID) {
        guard let page = workspace.notes.firstIndex(where: { $0.id == noteID }),
              let index = workspace.notes[page].blocks.firstIndex(where: { $0.id == blockID }) else { return }
        workspace.notes[page].blocks[index].linkMode = mode
        workspace.notes[page].touch(device); workspace.pending.insert("page_" + noteID.uuidString); flush()
        if mode == .html && workspace.notes[page].blocks[index].displayAssetID == nil {
            Task { await fetchHTML(noteID: noteID, blockID: blockID) }
        }
    }
    func fetchHTML(noteID: UUID, blockID: UUID, session: URLSession = .shared) async {
        guard let block = workspace.notes.first(where: { $0.id == noteID })?.blocks.first(where: { $0.id == blockID }),
              let url = WebLink.url(block.linkURL ?? ""), !fetchingLinks.contains(blockID) else { return }
        fetchingLinks.insert(blockID); defer { fetchingLinks.remove(blockID) }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 40
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                  let finalURL = response.url, WebLink.url(finalURL.absoluteString) != nil else {
                throw NSError(domain: "WebLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "未能获取网页，请尝试内嵌浏览器。"])
            }
            guard ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else {
                throw NSError(domain: "WebLink", code: 2, userInfo: [NSLocalizedDescriptionKey: "这个地址返回的不是 HTML 页面，可切换到浏览器查看。"])
            }
            guard let page = workspace.notes.firstIndex(where: { $0.id == noteID }),
                  let index = workspace.notes[page].blocks.firstIndex(where: { $0.id == blockID }) else { return }
            let asset = UUID(); try Repository.writeAtomically(data, to: repository.asset(asset))
            for p in workspace.notes.indices {
                var changed = false
                for b in workspace.notes[p].blocks.indices where workspace.notes[p].blocks[b].fileIdentity == block.fileIdentity {
                    workspace.notes[p].blocks[b].fileID = block.fileIdentity
                    if workspace.notes[p].blocks[b].assetID == nil {
                        workspace.notes[p].blocks[b].assetID = asset
                        workspace.notes[p].blocks[b].assetSHA256 = AssetFingerprint.sha256(data)
                        workspace.notes[p].blocks[b].assetByteCount = Int64(data.count)
                    } else { workspace.notes[p].blocks[b].workingAssetID = asset }
                    workspace.notes[p].blocks[b].assetName = (url.host ?? "网页") + ".html"
                    workspace.notes[p].blocks[b].linkHTMLBaseURL = finalURL.absoluteString
                    workspace.notes[p].blocks[b].linkEncoding = response.textEncodingName ?? "utf-8"
                    changed = true
                }
                if changed { workspace.notes[p].touch(device); workspace.pending.insert("page_" + workspace.notes[p].id.uuidString) }
            }
            workspace.notes[page].blocks[index].linkMode = .html
            workspace.notes[page].touch(device); workspace.pending.formUnion(["asset_" + asset.uuidString, "page_" + noteID.uuidString]); flush()
        } catch { message = "获取 HTML 失败：" + error.localizedDescription }
    }
    func openLink(_ block: Block) {
        guard let url = WebLink.url(block.linkURL ?? "") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

@MainActor final class LinkBrowser: ObservableObject {
    @Published var view: WKWebView?
    @Published var error: String?
    @Published var loading = false
}

@MainActor struct LinkBlockContent: View {
    @ObservedObject var store: AppStore
    let noteID: UUID
    let block: Block
    @StateObject private var browser = LinkBrowser()
    @ViewState private var data: Data?
    @ViewState private var exporting = false
    private var mode: LinkDisplayMode { block.linkMode ?? .card }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu(mode.title) { ForEach(LinkDisplayMode.allCases, id: \.self) { item in
                    Button(item.title) { store.setLinkMode(item, noteID: noteID, blockID: block.id) }
                } }.font(.caption)
                Spacer(minLength: 0)
                if mode == .browser {
                    Button { browser.view?.goBack() } label: { Image(systemName: "chevron.left") }.help("后退")
                    Button { browser.view?.goForward() } label: { Image(systemName: "chevron.right") }.help("前进")
                    Button { browser.error = nil; browser.view?.reload() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
                }
                if mode == .html, data != nil { Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }.help("导出 HTML") }
            }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 30)
            if mode == .card {
                VStack(alignment: .leading, spacing: 10) {
                    Label(WebLink.url(block.linkURL ?? "")?.host ?? "网页链接", systemImage: "link").font(.headline)
                    Text(block.linkURL ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    Button("在页面中浏览") { store.setLinkMode(.browser, noteID: noteID, blockID: block.id) }
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if mode == .html && store.fetchingLinks.contains(block.id) { ProgressView("正在获取 HTML…").frame(maxHeight: .infinity) }
            else if let url = WebLink.url(block.linkURL ?? ""), mode == .browser || data != nil {
                WebPageView(url: url, html: mode == .html ? data : nil,
                            baseURL: WebLink.url(block.linkHTMLBaseURL ?? "") ?? url,
                            encoding: block.linkEncoding ?? "utf-8", state: browser)
                    .id(mode)
                    .overlay(alignment: .bottom) {
                        if let error = browser.error { Text(error).font(.caption).padding(8).background(.regularMaterial) }
                    }
            } else {
                Button("获取 HTML 页面") { Task { await store.fetchHTML(noteID: noteID, blockID: block.id) } }.frame(maxHeight: .infinity)
            }
        }
        .task(id: block.displayAssetID) { if let id = block.displayAssetID { data = try? Data(contentsOf: store.repository.asset(id)) } }
        .fileExporter(isPresented: $exporting, document: data.map(AttachmentExport.init), contentType: .html, defaultFilename: block.assetName) { result in
            if case .failure(let error) = result { store.message = error.localizedDescription }
        }
    }
}

@MainActor final class WebPageNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    let state: LinkBrowser
    var loaded = ""
    private var loadingHTML = false
    init(_ state: LinkBrowser) { self.state = state }
    static func configuration(live: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = live
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }
    func makeView(live: Bool) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: Self.configuration(live: live))
        view.navigationDelegate = self; view.uiDelegate = self
        DispatchQueue.main.async { self.state.view = view }
        return view
    }
    func load(_ source: WebPageNativeView, in view: WKWebView) {
        let key = source.html.map(AssetFingerprint.sha256) ?? source.url.absoluteString
        guard key != loaded else { return }; loaded = key
        loadingHTML = source.html != nil
        DispatchQueue.main.async { self.state.error = nil }
        if let html = source.html { view.load(html, mimeType: "text/html", characterEncodingName: source.encoding, baseURL: source.baseURL) }
        else { view.load(URLRequest(url: source.url)) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        // WebKit may use applewebdata for a load(data:) document with a remote base URL.
        let snapshot = loadingHTML && action.navigationType == .other && action.targetFrame?.isMainFrame == true && url?.scheme == "applewebdata"
        decisionHandler(snapshot || url?.absoluteString == "about:blank" || WebLink.url(url?.absoluteString ?? "") != nil ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { state.error = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { state.error = error.localizedDescription }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, WebLink.url(action.request.url?.absoluteString ?? "") != nil { webView.load(action.request) }; return nil
    }
}

@MainActor struct WebPageView: View {
    let url: URL; let html: Data?; let baseURL: URL; let encoding: String; let state: LinkBrowser
    var body: some View {
        VectorWebSurface { WebPageNativeView(url: url, html: html, baseURL: baseURL, encoding: encoding, state: state, pageScale: $0) }
    }
}
#if os(macOS)
@MainActor struct WebPageNativeView: NSViewRepresentable {
    let url: URL; let html: Data?; let baseURL: URL; let encoding: String; let state: LinkBrowser
    var pageScale: CGFloat = 1
    func makeCoordinator() -> WebPageNavigation { WebPageNavigation(state) }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView(live: html == nil) }
    func updateNSView(_ view: WKWebView, context: Context) { WebVectorScale.apply(pageScale, to: view); context.coordinator.load(self, in: view) }
}
#else
@MainActor struct WebPageNativeView: UIViewRepresentable {
    let url: URL; let html: Data?; let baseURL: URL; let encoding: String; let state: LinkBrowser
    var pageScale: CGFloat = 1
    func makeCoordinator() -> WebPageNavigation { WebPageNavigation(state) }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView(live: html == nil) }
    func updateUIView(_ view: WKWebView, context: Context) { WebVectorScale.apply(pageScale, to: view); context.coordinator.load(self, in: view) }
}
#endif
