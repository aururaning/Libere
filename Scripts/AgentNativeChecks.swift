import Foundation
import PDFKit

@MainActor func runAgentNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ name: String) { precondition(value,name); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("libere-agent-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = try AppStore(root:root)
    let resources = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/MarginNotes/Resources")
    let service = AgentDocumentService(store:store,resources:resources)
    func request(_ method: String, _ path: String, _ bytes: Data = Data()) throws -> AgentHTTPRequest {
        var wire = Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:19879\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\n\r\n".utf8)
        wire.append(bytes); return try AgentHTTPRequest.parse(wire)!
    }
    func call(_ tool: String, _ args: [String:Any], id: String = UUID().uuidString, workspace: String? = nil, status: Int = 200) throws -> [String:Any] {
        let body = try JSONSerialization.data(withJSONObject:["tool":tool,"arguments":args,"requestID":id,"workspaceID":workspace ?? service.workspaceID])
        let response = service.handle(try request("POST","/v1/call",body))
        check(response.status == status,"\(tool) expected \(status), got \(response.status): \(String(data:response.body,encoding:.utf8) ?? "")")
        return try JSONSerialization.jsonObject(with:response.body) as! [String:Any]
    }
    for path in ["status","tools","rules","openapi.json"] {
        check(service.handle(try request("GET","/v1/" + path)).status == 200,"Public API resource " + path)
    }
    let malformed = service.handle(try request("POST","/v1/call",Data("broken".utf8)))
    check(malformed.status == 400,"Malformed JSON is a client error")
    let firstID = UUID().uuidString
    let create: [String:Any] = ["title":"Agent 测试页","canvasWidth":1200,"blocks":[["kind":"text","text":"# 结论\n\n保留 Markdown $x^2$","sourceURL":"https://example.com/source"],["kind":"link","url":"https://example.com","filename":"补充来源"]]]
    let created = try call("create_page",create,id:firstID)
    let pageID = UUID(uuidString:(created["page"] as! [String:Any])["id"] as! String)!
    func current() -> Note { store.workspace.notes.first { $0.id == pageID }! }
    func version(_ extra: [String:Any] = [:]) -> [String:Any] {
        ["pageID":pageID.uuidString,"expectedRevision":current().revision.uuidString].merging(extra) { _,new in new }
    }
    check((created["page"] as! [String:Any])["path"] as? String == "Agent 测试页","New page path includes its title")
    check(current().blocks.count == 2 && current().blocks[1].visibleFrame.height == 36,"Compact attachment is only a title row")
    check(current().blocks[0].sourceURL == "https://example.com/source","Source attribution survives")
    let replay = try call("create_page",create,id:firstID)
    check(NSDictionary(dictionary:created).isEqual(to:replay),"Exact retry returns same receipt")
    check(store.workspace.notes.filter { $0.title == "Agent 测试页" }.count == 1,"Retry does not create another page")
    _ = try call("create_page",["title":"不同内容"],id:firstID,status:409)
    let reload = try AppStore(root:root)
    let reloadedService = AgentDocumentService(store:reload,resources:resources)
    let replayData = try JSONSerialization.data(withJSONObject:["tool":"create_page","arguments":create,"requestID":firstID,"workspaceID":service.workspaceID])
    let afterRestart = reloadedService.handle(try request("POST","/v1/call",replayData))
    check(afterRestart.status == 200 && reload.workspace.notes.filter { $0.title == "Agent 测试页" }.count == 1,"Receipt persists across restart")
    store.undo(); check(current().deleted,"Agent create can be undone")
    store.redo(); check(!current().deleted && current().blocks.count == 2,"Agent create can be redone")
    let originalRevision = current().revision
    let oldBlocks = current().blocks
    _ = try call("append_blocks",version(["blocks":[["kind":"text","text":"追加一段"]]]))
    check(current().blocks.count == 3 && Array(current().blocks.prefix(2)) == oldBlocks,"Append keeps all existing positions")
    _ = try call("append_blocks",["pageID":pageID.uuidString,"expectedRevision":originalRevision.uuidString,"blocks":[["kind":"text","text":"过期"]]],status:409)
    let beforeRejected = store.workspace
    _ = try call("append_blocks",version(["blocks":[["kind":"text","text":"不能误入其他资料库"]]]),workspace:"wrong",status:409)
    service.allowWrites = false
    _ = try call("append_blocks",version(["blocks":[["kind":"text","text":"只读禁止"]]]),status:403)
    check(store.workspace == beforeRejected,"Rejected writes leave workspace unchanged")
    let readOnlyTools = service.handle(try request("GET","/v1/tools"))
    let tools = (try JSONSerialization.jsonObject(with:readOnlyTools.body) as! [String:Any])["tools"] as! [[String:Any]]
    check(tools.count == 3,"Read-only catalog omits mutation tools")
    service.allowWrites = true
    let bytes = Data("# 原文\r\n中文🍎\r\n```python\r\nprint(42)\r\n```\r\n".utf8)
    let file: [String:Any] = ["kind":"attachment","filename":"原文.md","dataBase64":bytes.base64EncodedString()]
    let beforeInvalid = store.workspace
    _ = try call("append_blocks",version(["blocks":[file,["kind":"link","url":"file:///etc/passwd"]]]),status:422)
    check(store.workspace == beforeInvalid,"Invalid batch commits no earlier block or receipt")
    let filesBefore = try FileManager.default.contentsOfDirectory(at:store.repository.asset(UUID()).deletingLastPathComponent(),includingPropertiesForKeys:nil)
    _ = try call("append_blocks",version(["blocks":[file]]))
    let imported = current().blocks.last!
    check(try Data(contentsOf:store.repository.asset(imported.assetID!)) == bytes,"Attachment bytes remain exact")
    _ = try call("append_blocks",version(["blocks":[file]]))
    let duplicate = current().blocks.last!
    check(duplicate.assetID == imported.assetID && duplicate.fileIdentity == imported.fileIdentity && duplicate.reference?.blockID == imported.id,"Duplicate original reuses storage and reference")
    let filesAfter = try FileManager.default.contentsOfDirectory(at:store.repository.asset(UUID()).deletingLastPathComponent(),includingPropertiesForKeys:nil)
    check(filesAfter.count == filesBefore.count + 1,"Exactly one asset stored for duplicate uploads")
    let read = try call("read_attachment",["pageID":pageID.uuidString,"blockID":imported.id.uuidString,"format":"base64"])
    check(read["dataBase64"] as? String == bytes.base64EncodedString(),"Read returns exact bytes")
    let text = try call("read_attachment",["pageID":pageID.uuidString,"blockID":imported.id.uuidString,"format":"text","offset":2,"limit":4])
    check(text["text"] as? String == String(String(data:bytes,encoding:.utf8)!.dropFirst(2).prefix(4)),"Text paging preserves Unicode characters")
    let preview = try call("layout_blocks",version(["style":"column"]))
    let afterPreview = current()
    check(preview["dryRun"] as? Bool == true,"Layout defaults to dry run")
    let order = current().blocks.reversed().map { $0.id.uuidString }
    _ = try call("layout_blocks",version(["blockIDs":order,"style":"column","dryRun":false]))
    check(current().blocks.map { $0.id.uuidString } == order && current().revision != afterPreview.revision,"Explicit ordering applies with new revision")
    let last = current().blocks.last!
    _ = try call("update_block",version(["blockID":last.id.uuidString,"text":"## 新结论"])); check(current().blocks.last?.text == "## 新结论","Markdown update persists")
    store.select(pageID); store.editBlock(imported.id) { $0.locked = true }; store.flush()
    let locked = current().blocks.first { $0.id == imported.id }!
    _ = try call("update_block",version(["blockID":imported.id.uuidString,"collapsed":false]),status:409)
    _ = try call("layout_blocks",version(["blockIDs":[imported.id.uuidString]]),status:409)
    check(current().blocks.first { $0.id == imported.id } == locked,"Locked attachment remains unchanged")
    store.editBlock(imported.id) { $0.locked = false }; store.flush()
    store.saveInk(Data([1,2,3]),bounds:Rect(0,3000,100,100),to:InkDestination(noteID:pageID))
    _ = try call("layout_blocks",version(["blockIDs":[imported.id.uuidString]]),status:409)
    let inkPage = current()
    _ = try call("append_blocks",version(["blocks":[["kind":"text","text":"手写之后"]]]))
    check(current().ink == inkPage.ink && current().blocks.last!.frame.y > 3100,"Appending protects handwriting coordinates")
    let titleOnly = try call("create_page",["title":"展示切换","blocks":[file]])
    let compactPageID = UUID(uuidString:(titleOnly["page"] as! [String:Any])["id"] as! String)!
    store.select(compactPageID); let compactID = store.note!.blocks[0].id
    store.toggleCollapsed(compactID)
    check(store.note!.blocks[0].frame.height == 480 && store.note!.blocks[0].collapsed == false,"Expanding restores preview height")
    store.toggleCollapsed(compactID)
    check(store.note!.blocks[0].frame.height == 36 && store.note!.blocks[0].collapsed == true,"Collapsing persists title-only height")
    let snapshot = store.workspace
    let dry = try call("layout_blocks",["pageID":compactPageID.uuidString,"expectedRevision":store.note!.revision.uuidString])
    check(dry["dryRun"] as? Bool == true && store.workspace == snapshot,"Dry run does not mutate revision, workspace or receipt")
    guard CommandLine.arguments.contains("--test-agent-transport") else {
        print("SKIP: live HTTP/MCP transport requires local network permission; run check-native.sh --test-agent-transport in an authorized Mac environment.")
        print("PASS: \(count) agent service assertions (transport not run)")
        return count
    }
    // Opt in only where local network operations are allowed. No fallback transport.
    let token = String(repeating:"a",count:64)
    let listener = try AgentHTTPServer(port:19879,token:token,handler: { request in service.handle(request) },state: { status,ready in
        if !ready { print("Agent listener status: " + status) }
    })
    listener.start(); defer { listener.stop() }
    try await Task.sleep(nanoseconds:250_000_000)
    let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
    let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
    var http = URLRequest(url:URL(string:"http://127.0.0.1:19879/v1/status")!); http.timeoutInterval = 4
    http.setValue("Bearer " + token,forHTTPHeaderField:"Authorization")
    let (data,response) = try await session.data(for:http)
    check((response as? HTTPURLResponse)?.statusCode == 200,"Live loopback HTTP serves authenticated status")
    let identity = try JSONSerialization.jsonObject(with:data) as! [String:Any]
    check(identity["workspaceID"] as? String == service.workspaceID,"Live listener uses intended workspace")
    http.setValue("Bearer wrong",forHTTPHeaderField:"Authorization")
    let (_,unauthorized) = try await session.data(for:http)
    check((unauthorized as? HTTPURLResponse)?.statusCode == 401,"Live listener rejects wrong token")
    http.setValue("Bearer " + token,forHTTPHeaderField:"Authorization"); http.setValue("https://example.com",forHTTPHeaderField:"Origin")
    let (_,origin) = try await session.data(for:http)
    check((origin as? HTTPURLResponse)?.statusCode == 403,"Live listener rejects browser-origin calls")
    // Run stdio MCP through a child process without blocking the main-actor HTTP service.
    let bridgePath = resources.appendingPathComponent("libere_agent.py").path
    let stdout = try await Task.detached { () throws -> Data in
        let process = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/env"); process.arguments = ["python3",bridgePath]
        var environment = ProcessInfo.processInfo.environment
        environment["LIBERE_AGENT_URL"] = "http://127.0.0.1:19879"; environment["LIBERE_AGENT_TOKEN"] = token
        process.environment = environment; process.standardInput = input; process.standardOutput = output; process.standardError = error
        try process.run()
        let messages: [[String:Any]] = [
            ["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-11-25","capabilities":[:],"clientInfo":["name":"NativeChecks","version":"1"]]],
            ["jsonrpc":"2.0","method":"notifications/initialized"],
            ["jsonrpc":"2.0","id":2,"method":"tools/list"],
            ["jsonrpc":"2.0","id":3,"method":"tools/call","params":["name":"create_page","arguments":["title":"MCP 连通性验证","blocks":[["kind":"text","text":"经 MCP 保存的正文"]]]]],
            ["jsonrpc":"2.0","id":4,"method":"resources/read","params":["uri":"libere://agent-rules"]]]
        for message in messages { input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject:message) + Data([10])) }
        try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        precondition(process.terminationStatus == 0,"MCP process exit"); return bytes
    }.value
    let messages = try String(data:stdout,encoding:.utf8)!.split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
    check(messages.count == 4 && messages.allSatisfy { $0["error"] == nil },"MCP initialize, tools, write and rules work over real stdio")
    check(store.workspace.notes.contains { $0.title == "MCP 连通性验证" && $0.blocks.first?.text == "经 MCP 保存的正文" },"MCP created real durable content")
    print("PASS: \(count) agent service, HTTP and MCP assertions")
    return count
}
