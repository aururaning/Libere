import SwiftUI
import Combine
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MarginCore
#endif

struct NotebookKernelChoice: Identifiable {
    let id: String
    let title: String
}

#if os(macOS)
private final class KernelLines: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    let receive: (Data) -> Void
    init(receive: @escaping (Data) -> Void) { self.receive = receive }
    func read(_ data: Data) {
        lock.lock(); buffer.append(data); var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) { lines.append(Data(buffer[..<newline])); buffer.removeSubrange(...newline) }
        lock.unlock()
        for line in lines { receive(line) }
    }
}
#endif

@MainActor final class NotebookSession: ObservableObject {
    @Published var document: NotebookDocument
    @Published var kernels: [NotebookKernelChoice] = []
    @Published var kernel = "python3"
    @Published var python: String
    @Published var status = "尚未启动内核"
    @Published var ready = false
    @Published var busy = false
    @Published var runningCell: Int?
    @Published var workingDirectory: URL
    private let write: (Data) throws -> Void
    private var saved: Data
    private var saveTask: Task<Void, Never>?
    private var request: String?
    private var queue: [Int] = []
    private let bridgeOverride: URL?
    #if os(macOS)
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var errorText = ""
    private var generation = UUID()
    #endif

    init(data: Data, directory: URL, bridge: URL? = nil, save: @escaping (Data) throws -> Void) throws {
        let parsed = try NotebookDocument(data: data)
        document = parsed; saved = try parsed.serialized()
        workingDirectory = directory; bridgeOverride = bridge; write = save
        kernel = parsed.kernelName ?? "python3"
        let preferred = UserDefaults.standard.string(forKey: "MarginNotebookPython")
        let candidates = [preferred, "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].compactMap { $0 }
        python = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }
    func edit(_ source: String, at index: Int) {
        document.setSource(source, at: index)
        saveTask?.cancel(); saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self?.save() }
        }
    }
    @discardableResult func save() -> Bool {
        do {
            let data = try document.serialized()
            if saved != data { try write(data); saved = data }
            return true
        } catch { status = "保存失败：" + error.localizedDescription; return false }
    }
    func addCell() { guard !busy else { return }; document.addCodeCell(); save() }
    func discover() {
        #if os(macOS)
        do { try ensureBridge(); try send(["op": "list"]) }
        catch { status = error.localizedDescription }
        #else
        status = "在 Mac 上选择内核运行；iPad 可查看、编辑和同步 Notebook。"
        #endif
    }
    func start() {
        guard !busy else { return }
        #if os(macOS)
        do {
            if ready { stop() }
            try ensureBridge(); UserDefaults.standard.set(python, forKey: "MarginNotebookPython")
            busy = true; ready = false; status = "正在启动内核…"
            try send(["op": "start", "kernel": kernel, "cwd": workingDirectory.path])
        } catch { busy = false; status = error.localizedDescription }
        #endif
    }
    func run(_ index: Int) {
        guard ready, !busy, document.cells.indices.contains(index), save() else { return }
        #if os(macOS)
        document.beginExecution(at: index); runningCell = index; busy = true; status = "正在运行单元格 \(index + 1)…"
        request = UUID().uuidString
        do { try send(["op": "execute", "id": request!, "code": document.cells[index].source]) }
        catch { busy = false; runningCell = nil; status = error.localizedDescription }
        #endif
    }
    func runAll() {
        guard ready, !busy else { return }
        queue = document.cells.filter { $0.kind == "code" }.map(\.index)
        runNext()
    }
    private func runNext() { if !queue.isEmpty { run(queue.removeFirst()) } }
    func interrupt() {
        #if os(macOS)
        queue = []; try? send(["op": "interrupt"])
        #endif
    }
    func stop() {
        save(); queue = []
        #if os(macOS)
        try? send(["op": "shutdown"])
        input?.fileHandleForWriting.closeFile(); input = nil
        generation = UUID(); request = nil
        #endif
        ready = false; busy = false; runningCell = nil; status = "内核已停止"
    }
    #if os(macOS)
    private func ensureBridge() throws {
        if process?.isRunning == true && input != nil { return }
        generation = UUID(); let currentGeneration = generation
        let bundled: URL?
        #if SWIFT_PACKAGE
        bundled = Bundle.module.url(forResource: "notebook_kernel", withExtension: "py")
        #else
        bundled = Bundle.main.url(forResource: "notebook_kernel", withExtension: "py")
        #endif
        guard let script = bridgeOverride ?? bundled else { throw NSError(domain: "Notebook", code: 1, userInfo: [NSLocalizedDescriptionKey: "此构建缺少 Notebook 内核组件。请使用完整应用构建。"]) }
        let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = URL(fileURLWithPath: python); task.arguments = ["-u", script.path]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        let lines = KernelLines { [weak self] data in Task { @MainActor in
            guard self?.generation == currentGeneration else { return }; self?.receive(data)
        } }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { lines.read(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.errorText = String(((self?.errorText ?? "") + String(decoding: data, as: UTF8.self)).suffix(4000)) }
        }
        task.terminationHandler = { [weak self, weak task] _ in Task { @MainActor in
            guard let self, let task, self.process === task else { return }
            self.ready = false; self.busy = false; self.runningCell = nil
            self.save()
            if task.terminationStatus != 0 { self.status = "内核组件退出：" + self.errorText }
        } }
        try task.run(); process = task; input = stdin; output = stdout; errors = stderr
    }
    private func send(_ value: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw NSError(domain: "Notebook", code: 2, userInfo: [NSLocalizedDescriptionKey: "请先连接 Python 环境。该环境需要 jupyter_client 和 ipykernel。"]) }
        var message = value; if message["id"] == nil { message["id"] = UUID().uuidString }
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    #endif
    private func receive(_ data: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let event = value["event"] as? String else { return }
        switch event {
        case "kernels":
            kernels = (value["kernels"] as? [[String: String]] ?? []).compactMap { item in
                guard let name = item["name"], let title = item["title"] else { return nil }; return NotebookKernelChoice(id: name, title: title)
            }
            if !kernels.contains(where: { $0.id == kernel }), let first = kernels.first { kernel = first.id }
            if !ready { status = "已找到 \(kernels.count) 个内核，点击启动。" }
        case "ready": ready = true; busy = false; status = "内核空闲 · \(kernel)"
        case "message":
            guard value["id"] as? String == request, let index = runningCell, let type = value["type"] as? String, let content = value["content"] as? [String: Any] else { return }
            document.apply(type, content: content, at: index)
        case "complete":
            guard value["id"] as? String == request else { return }
            busy = false; runningCell = nil
            let success = value["status"] as? String == "ok"
            status = success ? "运行完成 · 输出已保存" : "单元格已停止，输出和错误已保留"
            if !save() || !success { queue = [] }; runNext()
        case "error": busy = false; runningCell = nil; queue = []; status = value["message"] as? String ?? "内核错误"; save()
        default: break
        }
    }
}

struct AttachmentExport: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { guard let data = configuration.file.regularFileContents else { throw StoreError.corrupt }; self.data = data }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor struct NotebookEditor: View {
    @ObservedObject var session: NotebookSession
    let filename: String
    var compact = false
    var focus: () -> Void = {}
    @ViewState private var export = false
    @ViewState private var exportDocument: AttachmentExport?
    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            ScrollView(.horizontal, showsIndicators: false) { HStack {
                Picker("内核", selection: $session.kernel) { ForEach(session.kernels) { Text($0.title).tag($0.id) } }.frame(maxWidth: 260).disabled(session.busy || session.ready)
                Button(session.ready ? "重启内核" : "启动内核") { session.start() }.disabled(session.busy || session.kernels.isEmpty)
                Button("运行全部") { session.runAll() }.disabled(!session.ready || session.busy)
                Button("中断") { session.interrupt() }.disabled(session.runningCell == nil)
                Button("停止") { session.stop() }.disabled(!session.ready && !session.busy)
            }.padding(10) }
            if !compact {
            HStack {
                Text("Python").font(.caption)
                TextField("Python 可执行文件", text: $session.python).textFieldStyle(.roundedBorder).disabled(session.ready || session.busy)
                Button("刷新内核") { session.stop(); session.discover() }.disabled(session.busy)
                Button("工作目录") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.directoryURL = session.workingDirectory
                    if panel.runModal() == .OK, let url = panel.url { session.workingDirectory = url }
                }.disabled(session.ready || session.busy)
            }.padding(.horizontal, 10).padding(.bottom, 8)
            }
            #endif
            HStack {
                Text(session.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("添加代码单元") { session.addCell() }.disabled(session.busy)
                Button("导出 Notebook") { if let data = try? session.document.serialized() { exportDocument = AttachmentExport(data); export = true } }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.document.cells) { cell in NotebookCellView(session: session, cell: cell, focus: focus) }
                }.padding(14)
            }
        }
        .task { if session.kernels.isEmpty { session.discover() } }
        .onDisappear { session.save() }
        .fileExporter(isPresented: $export, document: exportDocument, contentType: UTType(filenameExtension: "ipynb") ?? .json, defaultFilename: filename) { _ in }
    }
}

@MainActor private struct NotebookCellView: View {
    @ObservedObject var session: NotebookSession
    let cell: NotebookCell
    var focus: () -> Void = {}
    @ViewState private var outputHeight = CGFloat(120)
    @ViewState private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if cell.kind == "code" {
                HStack {
                    Button { session.run(cell.index) } label: { Image(systemName: "play.fill") }.disabled(!session.ready || session.busy)
                    Text(session.runningCell == cell.index ? "In [*]" : "In [\(cell.executionCount.map(String.init) ?? " ")]").font(.caption.monospaced())
                    Spacer()
                }
                SourceEditor(text: Binding(get: { cell.source }, set: { session.edit($0, at: cell.index) }), focus: focus)
                    .font(.system(size: 14, design: .monospaced)).frame(height: min(420, max(84, CGFloat(cell.source.components(separatedBy: "\n").count * 20 + 24))))
                    .disabled(session.busy)
                if !cell.outputs.isEmpty {
                    AttachmentWebView(html: AttachmentFormat.outputsDocument(cell.outputs), heightChanged: { outputHeight = $0 })
                        .frame(height: outputHeight)
                }
            } else {
                HStack { Text(cell.kind == "markdown" ? "Markdown" : "文本").font(.caption); Spacer(); Button(editing ? "预览" : "编辑") { editing.toggle() } }
                if editing {
                    SourceEditor(text: Binding(get: { cell.source }, set: { session.edit($0, at: cell.index) }), focus: focus)
                        .font(.system(size: 14, design: .monospaced)).frame(minHeight: 100).disabled(session.busy)
                } else if cell.kind == "markdown" {
                    AttachmentWebView(html: Markdown.document(cell.source), heightChanged: { outputHeight = $0 }).frame(height: outputHeight)
                } else { Text(cell.source).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            }
        }.padding(12).background(Palette.desk, in: RoundedRectangle(cornerRadius: 10))
    }
}
