import SwiftUI
import Combine
#if os(macOS)
import Network
#endif
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor final class AgentController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var running = false
    @Published private(set) var allowWrites: Bool
    @Published private(set) var status = "尚未开启"
    @Published private(set) var recent: [String] = []
    @Published private(set) var port: UInt16
    private(set) var token: String
    let service: AgentDocumentService
    private let defaults: UserDefaults
    private var generation = UUID()
    #if os(macOS)
    private var server: AgentHTTPServer?
    #endif
    var endpoint: String { "http://127.0.0.1:\(port)" }
    init(store: AppStore, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey:"LibereAgentEnabled")
        allowWrites = defaults.object(forKey:"LibereAgentWrites") as? Bool ?? true
        let savedPort = defaults.integer(forKey:"LibereAgentPort")
        port = (1024...65535).contains(savedPort) ? UInt16(savedPort) : 19876
        token = defaults.string(forKey:"LibereAgentToken") ?? Self.makeToken()
        defaults.set(token,forKey:"LibereAgentToken")
        service = AgentDocumentService(store:store); service.allowWrites = allowWrites
        service.didWrite = { [weak self] line in
            guard let self else { return }
            self.recent.insert(Date().formatted(date:.omitted,time:.shortened) + " · " + line,at:0)
            self.recent = Array(self.recent.prefix(12))
        }
    }
    private static func makeToken() -> String { (0..<32).map { _ in String(format:"%02x", UInt8.random(in:0...255)) }.joined() }
    func resume() { if enabled { start() } }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value,forKey:"LibereAgentEnabled")
        if value { start() } else { stop(); status = "已关闭" }
    }
    func setWrites(_ value: Bool) { allowWrites = value; service.allowWrites = value; defaults.set(value,forKey:"LibereAgentWrites") }
    func setPort(_ value: String) {
        guard let number = UInt16(value), number >= 1024 else { status = "端口需为 1024–65535。"; return }
        port = number; defaults.set(Int(number),forKey:"LibereAgentPort")
        if enabled { start() }
    }
    func rotateToken() {
        token = Self.makeToken(); defaults.set(token,forKey:"LibereAgentToken")
        if enabled { start() }
    }
    func stop() {
        generation = UUID(); running = false
        #if os(macOS)
        server?.stop(); server = nil
        #endif
    }
    private func start() {
        stop()
        #if os(macOS)
        status = "正在开启…"
        let activeGeneration = generation
        do {
            let server = try AgentHTTPServer(port:port,token:token,handler: { [weak self] request in
                guard let self, self.enabled, self.generation == activeGeneration else {
                    return .failure(AgentFailure(503,"connection_changed","Agent 接入已关闭或资料库已切换。"))
                }
                return self.service.handle(request)
            }, state: { [weak self] status, ready in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == activeGeneration else { return }
                    self.status = status; self.running = ready
                }
            })
            self.server = server; server.start()
        } catch { status = "开启失败：" + error.localizedDescription }
        #else
        status = "请在 Mac 端开启 Agent API。"
        #endif
    }
    func mcpConfiguration() -> String {
        let path = AppBrand.resources.url(forResource:"libere_agent",withExtension:"py")?.path ?? "libere_agent.py"
        let object: [String:Any] = ["mcpServers":["libere":["command":"python3","args":[path],
            "env":["LIBERE_AGENT_URL":endpoint,"LIBERE_AGENT_TOKEN":token]]]]
        return String(data:try! JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]),encoding:.utf8)!
    }
}

struct AgentSettings: View {
    @ObservedObject var controller: AgentController
    @ViewState private var portText = ""
    @ViewState private var copied = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { AppLogo().frame(width:32,height:32); Text("Agent 接入").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            #if os(macOS)
            Toggle("开启本机 Agent API",isOn:Binding(get:{controller.enabled},set:controller.setEnabled))
            HStack {
                Circle().fill(controller.running ? Palette.accent : Color.secondary).frame(width:7,height:7)
                Text(controller.status).font(.callout).foregroundStyle(.secondary)
            }
            Text(controller.endpoint).font(.system(.body,design:.monospaced)).textSelection(.enabled)
            HStack {
                Text("端口"); TextField("19876",text:$portText).frame(width:100)
                Button("应用") { controller.setPort(portText) }
                Spacer(); Button("复制地址") { copy(controller.endpoint,label:"地址") }
            }
            Toggle("允许 agent 保存资料与调整排版",isOn:Binding(get:{controller.allowWrites},set:controller.setWrites))
            Text("连接当前打开的资料库。写入会出现在页面中，并可通过画布撤销恢复。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("复制 MCP 配置") { copy(controller.mcpConfiguration(),label:"MCP 配置") }
                Button("复制访问令牌") { copy(controller.token,label:"访问令牌") }
                Button("重新生成令牌") { controller.rotateToken(); copied = "令牌已更新，请重新复制客户端配置。" }
            }
            HStack {
                Button("复制排版与操作规范") {
                    if let text = try? String(contentsOf:controller.service.resources.appendingPathComponent("agent_rules.md"),encoding:.utf8) { copy(text,label:"操作规范") }
                }
                Button("复制 HTTP 示例") {
                    copy("curl -H 'Authorization: Bearer \(controller.token)' '\(controller.endpoint)/v1/status'",label:"HTTP 示例")
                }
            }
            Text(copied.isEmpty ? "访问令牌只用于此本机接口；关闭接口或重新生成令牌可断开接入。" : copied)
                .font(.caption).foregroundStyle(.secondary)
            if !controller.recent.isEmpty {
                Divider(); Text("最近写入").font(.headline)
                ForEach(Array(controller.recent.enumerated()),id:\.offset) { _, value in Text(value).font(.caption).lineLimit(1) }
            }
            #else
            Text("请在 Mac 版 Libere 中开启 Agent API，并将 MCP 配置加入你使用的 agent。这里仍可阅读、编辑和收起附件。")
            #endif
        }.padding(24).frame(minWidth:540,idealWidth:640).onAppear { portText = String(controller.port) }
    }
    private func copy(_ value: String,label: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string)
        #else
        UIPasteboard.general.string = value
        #endif
        copied = "已复制" + label
    }
}

#if os(macOS)
final class AgentHTTPServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (AgentHTTPRequest) -> AgentHTTPResponse
    private let listener: NWListener
    private let queue = DispatchQueue(label:"libere.agent.http")
    private var peers: [UUID: AgentHTTPPeer] = [:]
    private let port: UInt16
    private let token: String
    private let handler: Handler
    private let state: @Sendable (String,Bool) -> Void
    init(port: UInt16,token: String,handler: @escaping Handler,state: @escaping @Sendable (String,Bool)->Void) throws {
        self.port = port; self.token = token; self.handler = handler; self.state = state
        let parameters = NWParameters.tcp
        guard let endpointPort = NWEndpoint.Port(rawValue:port), port >= 1024 else {
            throw AgentFailure(422,"invalid_port","端口需为 1024–65535。")
        }
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:endpointPort)
        // requiredLocalEndpoint supplies both address and port. Passing on: as well
        // is a conflicting binding request (EINVAL), not a second loopback restriction.
        listener = try NWListener(using:parameters)
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] value in
            guard let self else { return }
            switch value {
            case .ready: self.state("已开启 · 仅本机访问",true)
            case .failed(let error): self.state("开启失败（端口可能被占用）：" + error.localizedDescription,false)
            case .cancelled: break
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.peers.count < 4 else {
                connection.start(queue:self.queue)
                connection.send(content:AgentHTTPResponse.failure(AgentFailure(503,"busy","接口正在处理其他请求，请稍后重试。")).encoded,completion:.contentProcessed { _ in connection.cancel() })
                return
            }
            let id = UUID()
            let peer = AgentHTTPPeer(connection:connection,queue:self.queue,token:self.token,port:self.port,handler:self.handler) { [weak self] in self?.peers.removeValue(forKey:id) }
            self.peers[id] = peer; peer.start()
        }
        listener.start(queue:queue)
    }
    func stop() {
        listener.cancel()
        queue.async { [self] in
            let active = Array(peers.values); peers.removeAll()
            for peer in active { peer.close() }
        }
    }
    deinit { listener.cancel() }
}

private final class AgentHTTPPeer: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let token: String
    let port: UInt16
    let handler: AgentHTTPServer.Handler
    let didClose: () -> Void
    var buffer = Data()
    var authorized = false
    var closed = false
    var timeout: DispatchWorkItem?
    var task: Task<Void,Never>?
    init(connection:NWConnection,queue:DispatchQueue,token:String,port:UInt16,handler:@escaping AgentHTTPServer.Handler,didClose:@escaping ()->Void) {
        self.connection = connection; self.queue = queue; self.token = token; self.port = port; self.handler = handler; self.didClose = didClose
    }
    func start() {
        connection.start(queue:queue)
        let timeout = DispatchWorkItem { [weak self] in self?.close() }; self.timeout = timeout
        queue.asyncAfter(deadline:.now()+45,execute:timeout); receive()
    }
    func receive() {
        connection.receive(minimumIncompleteLength:1,maximumLength:authorized ? 65536 : 16384) { [weak self] data,_,complete,error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            do {
                guard self.buffer.count <= AgentLimits.bodyBytes + AgentLimits.headerBytes else { throw AgentFailure(413,"body_too_large","请求过大。") }
                if !self.authorized, let head = try AgentHTTPRequest.head(in:self.buffer) {
                    try head.authorize(token:self.token,port:self.port); self.authorized = true
                }
                if let request = try AgentHTTPRequest.parse(self.buffer) {
                    self.buffer = Data()
                    self.task = Task { @MainActor [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        let response = self.handler(request)
                        self.queue.async { [weak self] in self?.finish(response) }
                    }
                } else if complete || error != nil { self.close() }
                else { self.receive() }
            } catch let failure as AgentFailure { self.finish(.failure(failure)) }
            catch { self.finish(.failure(AgentFailure(400,"bad_request","请求无效。"))) }
        }
    }
    func finish(_ response:AgentHTTPResponse) {
        guard !closed else { return }
        connection.send(content:response.encoded,completion:.contentProcessed { [weak self] _ in self?.close() })
    }
    func close() {
        guard !closed else { return }; closed = true
        timeout?.cancel(); task?.cancel(); connection.cancel(); didClose()
    }
}
#endif
