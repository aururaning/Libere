import SwiftUI
import Combine
import UniformTypeIdentifiers

enum WorkspaceLocation {
    static let bookmarkKey = "MarginWorkspaceBookmark"
    static let pathKey = "MarginWorkspacePath"
    static let scopeKey = "MarginWorkspaceUsesSecurityScope"
    static var legacy: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MarginNotes", isDirectory: true) }
    static func restore(from defaults: UserDefaults = .standard) throws -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        #if os(macOS)
        let scoped = defaults.object(forKey: scopeKey) == nil || defaults.bool(forKey: scopeKey)
        let options: URL.BookmarkResolutionOptions = scoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        let url = try URL(resolvingBookmarkData: data, options: options, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale)
        #endif
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw NSError(domain: "Workspace", code: 1, userInfo: [NSLocalizedDescriptionKey: "上次选择的资料库目前不可用。连接原磁盘或等待 iCloud 文件夹可用后重试，也可以在存储设置中更换位置。"])
        }
        if stale { try remember(url, in: defaults) }
        return url
    }
    static func remember(_ url: URL, in defaults: UserDefaults = .standard) throws {
        #if os(macOS)
        #if MARGIN_LOCAL_BUILD
        // The existing standalone Mac build does not adopt App Sandbox; use its normal URL bookmark API.
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let scoped = false
        #else
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let scoped = true
        #endif
        #else
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let scoped = false
        #endif
        defaults.set(data, forKey: bookmarkKey); defaults.set(url.path, forKey: pathKey); defaults.set(scoped, forKey: scopeKey)
    }
}

@MainActor struct WorkspaceSetup: View {
    @ObservedObject var bootstrap: Bootstrap
    var settings = false
    @Environment(\.dismiss) private var dismiss
    @ViewState private var choosing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AppLogo().frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Label(settings ? "资料库存储位置" : "选择你的资料库", systemImage: "folder.badge.gearshape").font(.title2.bold())
            Text("选择一个文件夹保存页面和文件，也可以选择 iCloud Drive 中的文件夹。应用会记住这个位置。").foregroundStyle(.secondary)
            if let store = bootstrap.store { Text(store.repository.root.path).font(.caption.monospaced()).textSelection(.enabled) }
            if let error = bootstrap.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button(settings ? "更换文件夹…" : "选择文件夹…") { choose() }.buttonStyle(.borderedProminent)
                if !settings, FileManager.default.fileExists(atPath: WorkspaceLocation.legacy.appendingPathComponent("workspace.json").path) {
                    Button("继续使用原资料库") { bootstrap.open(WorkspaceLocation.legacy, remember: true) }
                }
                if settings { Spacer(); Button("完成") { dismiss() } }
                else if bootstrap.error != nil { Button("重试原位置") { bootstrap.restore() } }
            }
            if settings { Text("更换位置会打开所选文件夹中的资料库。要搬迁现有内容，可先导出完整备份，再在新位置导入。").font(.caption).foregroundStyle(.secondary) }
        }.padding(32).frame(minWidth: 460, idealWidth: 600, minHeight: 260)
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                switch result { case .success(let url): bootstrap.open(url, remember: true); case .failure(let error): if (error as? CocoaError)?.code != .userCancelled { bootstrap.error = error.localizedDescription } }
            }
    }
    private func choose() {
        #if os(macOS)
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "使用此资料库"; panel.directoryURL = bootstrap.store?.repository.root
        if panel.runModal() == .OK, let url = panel.url { bootstrap.open(url, remember: true) }
        #else
        choosing = true
        #endif
    }
}

@MainActor final class Bootstrap: ObservableObject {
    @Published var store: AppStore?
    @Published var error: String?
    @Published var showingStorage = false
    @Published var showingAgent = false
    @Published var agent: AgentController?
    private var activeURL: URL?
    init() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--data-dir"), index + 1 < args.count {
            open(URL(fileURLWithPath: args[index + 1]), remember: false); return
        }
        #if MARGIN_LOCAL_BUILD
        if let root = MacWindowCheck.fixtureRoot { open(root, remember: false); return }
        #endif
        restore()
    }
    func restore() {
        do {
            if let url = try WorkspaceLocation.restore() { open(url, remember: false) }
        } catch { self.error = error.localizedDescription }
    }
    func open(_ url: URL, remember: Bool) {
        do {
            if let store, !store.saveEditors() { error = "当前有文件未保存成功，请先处理编辑区提示。"; return }
            store?.stopKernels()
            if let store, !store.flush() { error = "当前资料库还未保存成功，请先完成保存。"; return }
            _ = url.startAccessingSecurityScopedResource()
            let next = try AppStore(root: url)
            if remember { try WorkspaceLocation.remember(url) }
            let args = ProcessInfo.processInfo.arguments
            let windowFixture = (args.contains("--verify-window") && args.contains("--data-dir"))
                || Bundle.main.object(forInfoDictionaryKey: "MarginWindowCheck") as? Bool == true
            if !windowFixture {
                do { try next.installShowcaseIfNeeded() }
                catch { next.message = error.localizedDescription }
            }
            agent?.stop()
            activeURL?.stopAccessingSecurityScopedResource(); activeURL = url
            store = next; error = nil; showingStorage = false
            agent = AgentController(store:next); agent?.resume()
        } catch { self.error = error.localizedDescription }
    }
}
