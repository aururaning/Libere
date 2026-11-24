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
    @Published var focusedCellID: String?
    @Published var focusRequest = UUID()
    @Published private(set) var structureGeneration = UUID()
    @Published private(set) var cellUndoAvailable = false
    private var cellUndo: [Data] = []
    private var advanceAfterRun: String?
    @Published var workingDirectory: URL
    private let write: (Data) throws -> Void
    var hasUnsavedChanges: Bool { (try? document.serialized()) != saved }
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
        guard !busy, document.cells.indices.contains(index) else { return }
        document.setSource(source, at: index)
        saveTask?.cancel(); saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self?.save() }
        }
    }
    /// UI callbacks own a cell identity and a structural generation, never an
    /// index that can point to another cell after a move, deletion or undo.
    @discardableResult func edit(_ source: String, cellID: String, generation: UUID) -> Bool {
        guard !busy, generation == structureGeneration,
              let index = document.index(ofCellID: cellID) else { return false }
        edit(source, at: index); return true
    }
    @discardableResult func save() -> Bool {
        saveTask?.cancel(); saveTask = nil
        do {
            let data = try document.serialized()
            if saved != data { try write(data); saved = data }
            return true
        } catch { status = "保存失败：" + error.localizedDescription; return false }
    }
    static func commitInput() {
        #if os(macOS)
        if let text = NSApp?.keyWindow?.firstResponder as? NSTextView { text.unmarkText(); text.didChangeText() }
        #endif
    }
    private func changeCells(_ change: (inout NotebookDocument) -> Void) {
        guard !busy else { return }; Self.commitInput()
        guard save(), let before = try? document.serialized() else { return }
        change(&document)
        if (try? document.serialized()) != before {
            structureGeneration = UUID()
            cellUndo.append(before)
            while cellUndo.count > 1 && (cellUndo.count > 30 || cellUndo.reduce(0, { $0 + $1.count }) > 16 * 1024 * 1024) { cellUndo.removeFirst() }
            cellUndoAvailable = true; save()
        }
    }
    func focusCell(_ index: Int) {
        guard document.cells.indices.contains(index) else { return }
        focusedCellID = document.cells[index].id; focusRequest = UUID()
    }
    func addCell() { insertCell(at: document.cells.count) }
    func insertCell(at index: Int, kind: String = "code") { changeCells { $0.insertCell(at: index, kind: kind) }; if !busy { focusCell(min(index, document.cells.count - 1)) } }
    func deleteCell(_ index: Int) { changeCells { $0.removeCell(at: index) }; if !busy { focusCell(min(index, document.cells.count - 1)) } }
    func moveCell(_ index: Int, by delta: Int) { changeCells { $0.moveCell(at: index, by: delta) }; if !busy { focusCell(index + delta) } }
    func convertCell(_ index: Int, to kind: String) { changeCells { $0.convertCell(at: index, to: kind) }; if !busy { focusCell(index) } }
    func clearOutputs(_ index: Int? = nil) { changeCells { $0.clearOutputs(at: index) } }
    func undoCellChange() {
        guard !busy, let bytes = cellUndo.last, let restored = try? NotebookDocument(data: bytes) else { return }
        Self.commitInput(); structureGeneration = UUID(); document = restored
        cellUndo.removeLast(); cellUndoAvailable = !cellUndo.isEmpty; save()
    }
    func runAndAdvance(_ index: Int) {
        guard !busy, document.cells.indices.contains(index) else { return }; Self.commitInput()
        let code = document.cells[index].kind == "code"
        guard !code || ready else { status = "请先启动内核。"; return }
        if index + 1 == document.cells.count { changeCells { $0.insertCell(at: index + 1) } }
        guard document.cells.indices.contains(index + 1) else { return }
        if code { advanceAfterRun = document.cells[index + 1].id; run(index) }
        else { focusCell(index + 1) }
    }
    func discover() {
        #if os(macOS)
        do { try ensureBridge(); try send(["op": "list"]) }
        catch { status = error.localizedDescription }
        #else
        status = "在 Mac 上选择内核运行；iPad 可查看、编辑和同步 Notebook。"
        #endif
    }
    func start() {
        guard !busy else { return }; Self.commitInput()
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
        guard ready, !busy, document.cells.indices.contains(index), document.cells[index].kind == "code" else { return }
        Self.commitInput(); guard save() else { return }
        #if os(macOS)
        document.beginExecution(at: index); runningCell = index; busy = true; status = "正在运行单元格 \(index + 1)…"
        request = UUID().uuidString
        do { try send(["op": "execute", "id": request!, "code": document.cells[index].source]) }
        catch { busy = false; runningCell = nil; advanceAfterRun = nil; status = error.localizedDescription }
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
        save(); queue = []; advanceAfterRun = nil
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
            if !save() || !success { queue = [] }
            if let id = advanceAfterRun, let index = document.cells.firstIndex(where: { $0.id == id }) { focusCell(index) }
            advanceAfterRun = nil; runNext()
        case "error": busy = false; runningCell = nil; queue = []; advanceAfterRun = nil; status = value["message"] as? String ?? "内核错误"; save()
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
    var documentZoom: Binding<Double>? = nil
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
                Button("撤销单元格操作") { session.undoCellChange() }.disabled(session.busy || !session.cellUndoAvailable)
                Button("清除所有输出") { session.clearOutputs() }.disabled(session.busy)
                Button("导出 Notebook") { if let data = try? session.document.serialized() { exportDocument = AttachmentExport(data); export = true } }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            ReaderDocumentViewport(zoom: documentZoom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(session.document.cells) { cell in NotebookCellView(session: session, cell: cell, focus: focus).id(cell.id) }
                        }.padding(14)
                    }.onChange(of: session.focusRequest) { _, _ in if let id = session.focusedCellID { proxy.scrollTo(id, anchor: .center) } }
                }
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
    private func withCell(_ generation: UUID, action: (Int) -> Void) {
        guard generation == session.structureGeneration, let index = session.document.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        action(index)
    }
    var body: some View {
        let editGeneration = session.structureGeneration
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Menu("单元格") {
                    Button("在上方插入代码") { withCell(editGeneration) { session.insertCell(at: $0) } }
                    Button("在下方插入代码") { withCell(editGeneration) { session.insertCell(at: $0 + 1) } }
                    Button("在下方插入 Markdown") { withCell(editGeneration) { session.insertCell(at: $0 + 1, kind: "markdown") } }
                    Button("上移") { withCell(editGeneration) { session.moveCell($0, by: -1) } }.disabled(cell.index == 0)
                    Button("下移") { withCell(editGeneration) { session.moveCell($0, by: 1) } }.disabled(cell.index + 1 == session.document.cells.count)
                    Button(cell.kind == "code" ? "转换为 Markdown" : "转换为代码") { withCell(editGeneration) { session.convertCell($0, to: cell.kind == "code" ? "markdown" : "code") } }
                    if cell.kind == "code" { Button("清除输出") { withCell(editGeneration) { session.clearOutputs($0) } } }
                    Button("删除单元格", role: .destructive) { withCell(editGeneration) { session.deleteCell($0) } }
                }.disabled(session.busy)
                Spacer()
                Text("Shift↵ 运行并前进").font(.caption2).foregroundStyle(.secondary)
            }
            if cell.kind == "code" {
                HStack {
                    Button { withCell(editGeneration) { session.run($0) } } label: { Image(systemName: "play.fill") }.disabled(!session.ready || session.busy)
                    Text(session.runningCell == cell.index ? "In [*]" : "In [\(cell.executionCount.map(String.init) ?? " ")]").font(.caption.monospaced())
                    Spacer()
                }
                SourceEditor(text: Binding(get: { cell.source }, set: { _ = session.edit($0, cellID: cell.id, generation: editGeneration) }), focus: focus,
                             editable: !session.busy, wantsFocus: session.focusedCellID == cell.id, focusRequest: session.focusRequest,
                             runAndAdvance: { withCell(editGeneration) { session.runAndAdvance($0) } })
                    .id(editGeneration)
                    .font(.system(size: 14, design: .monospaced)).frame(height: min(420, max(84, CGFloat(cell.source.components(separatedBy: "\n").count * 20 + 24))))
                    .disabled(session.busy)
                if !cell.outputs.isEmpty {
                    AttachmentWebView(html: AttachmentFormat.outputsDocument(cell.outputs), heightChanged: { outputHeight = $0 })
                        .frame(height: outputHeight)
                }
            } else {
                HStack { Text(cell.kind == "markdown" ? "Markdown" : "文本").font(.caption); Spacer(); Button(editing ? "预览" : "编辑") { editing.toggle() } }
                if editing {
                    SourceEditor(text: Binding(get: { cell.source }, set: { _ = session.edit($0, cellID: cell.id, generation: editGeneration) }), focus: focus,
                             editable: !session.busy, wantsFocus: session.focusedCellID == cell.id, focusRequest: session.focusRequest,
                             runAndAdvance: { withCell(editGeneration) { session.runAndAdvance($0) } })
                    .id(editGeneration)
                        .font(.system(size: 14, design: .monospaced)).frame(minHeight: 100).disabled(session.busy)
                } else if cell.kind == "markdown" {
                    AttachmentWebView(html: Markdown.document(cell.source), heightChanged: { outputHeight = $0 }).frame(height: outputHeight)
                } else { Text(cell.source).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            }
        }.padding(12).background(Palette.desk, in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: session.focusRequest) { _, _ in if session.focusedCellID == cell.id && cell.kind != "code" { editing = true } }
    }
}
