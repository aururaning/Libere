import Foundation
import PDFKit
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor final class AgentDocumentService {
    weak var store: AppStore?
    let resources: URL
    let workspaceID: String
    var allowWrites = true
    var didWrite: ((String) -> Void)?
    init(store: AppStore, resources: URL? = AppBrand.resources.resourceURL) {
        self.store = store; self.resources = resources ?? URL(fileURLWithPath: "/")
        workspaceID = AssetFingerprint.sha256(Data(store.repository.root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
    }
    private struct Arguments: Decodable {
        var pageID: UUID?; var blockID: UUID?; var parentID: UUID?
        var expectedRevision: UUID?; var title: String?; var isFolder: Bool?
        var query: String?; var limit: Int?; var offset: Int?
        var canvasWidth: Double?; var blocks: [AgentBlockInput]?
        var blockIDs: [UUID]?; var style: AgentLayoutStyle?; var dryRun: Bool?
        var text: String?; var collapsed: Bool?; var sourceURL: String?
        var format: String?
    }
    private let writeTools: Set<String> = ["create_page", "append_blocks", "update_block", "layout_blocks"]
    private func json(_ value: Any, status: Int = 200) throws -> AgentHTTPResponse {
        AgentHTTPResponse(status, body: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
    }
    func handle(_ request: AgentHTTPRequest) -> AgentHTTPResponse {
        do {
            guard let store else { throw AgentFailure(503, "workspace_closed", "资料库已关闭。") }
            if request.head.method == "GET" {
                switch request.head.target {
                case "/v1/status":
                    return try json(["name": AppBrand.name, "apiVersion": "1", "workspaceID": workspaceID,
                                     "workspaceName": store.repository.root.lastPathComponent, "libraryPath": store.repository.root.path, "allowWrites": allowWrites,
                                     "maxAttachmentBytes": AgentLimits.attachmentBytes, "maxBlocksPerCall": AgentLimits.blocksPerCall])
                case "/v1/tools":
                    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("agent_tools.json"))) as? [[String: Any]] ?? []
                    return try json(["tools": object.filter { allowWrites || !writeTools.contains($0["name"] as? String ?? "") }])
                case "/v1/rules":
                    return AgentHTTPResponse(body: try Data(contentsOf: resources.appendingPathComponent("agent_rules.md")), contentType: "text/markdown; charset=utf-8")
                case "/v1/openapi.json":
                    return AgentHTTPResponse(body: try Data(contentsOf: resources.appendingPathComponent("agent_openapi.json")))
                default: throw AgentFailure(404, "not_found", "接口不存在。")
                }
            }
            guard request.head.target == "/v1/call" else { throw AgentFailure(404, "not_found", "接口不存在。") }
            return try call(request.body)
        } catch let error as AgentFailure { return .failure(error) }
        catch is DecodingError { return .failure(AgentFailure(400, "invalid_arguments", "参数类型或必填字段无效。")) }
        catch { return .failure(AgentFailure(500, "storage_error", error.localizedDescription)) }
    }
    private func requirePage(_ id: UUID?, store: AppStore) throws -> Note {
        guard let id, let page = store.workspace.notes.first(where: { $0.id == id && !$0.deleted }) else {
            throw AgentFailure(404, "page_not_found", "找不到目标页面，请先列出页面。")
        }
        return page
    }
    private func pageJSON(_ page: Note, store: AppStore, includeBlocks: Bool = false) -> [String: Any] {
        let path = (page.parentID.map { ReferencePath.title(of: $0, in: store.workspace) } ?? []) + [page.title]
        var value: [String: Any] = ["id": page.id.uuidString, "title": page.title, "isFolder": page.isFolder,
                                   "parentID": page.parentID?.uuidString as Any? ?? NSNull(), "revision": page.revision.uuidString,
                                   "path": path.joined(separator: " / "),
                                   "width": page.width, "height": page.height, "blockCount": page.blocks.count, "hasHandwriting": page.ink != nil]
        if includeBlocks { value["blocks"] = page.blocks.map { blockJSON($0, pageID: page.id, store: store) } }
        return value
    }
    private func blockJSON(_ block: Block, pageID: UUID, store: AppStore) -> [String: Any] {
        let frame = block.visibleFrame
        var value: [String: Any] = ["id": block.id.uuidString, "kind": block.kind.rawValue,
                                   "frame": ["x":frame.x,"y":frame.y,"width":frame.width,"height":frame.height],
                                   "text": block.text, "filename": block.assetName, "collapsed": block.collapsed == true,
                                   "locked": block.locked, "hasAnnotations": block.anchorID != nil || !(block.pageAnnotations ?? [:]).isEmpty,
                                   "displayTitle": store.attachmentTitle(block, on: pageID)]
        if let source = block.sourceURL { value["sourceURL"] = source }
        if let url = block.linkURL { value["url"] = url }
        if let sha = block.assetSHA256 { value["originalSHA256"] = sha }
        if let bytes = block.assetByteCount { value["originalBytes"] = bytes }
        if let ref = block.reference { value["reference"] = ["pageID":ref.noteID.uuidString,"blockID":ref.blockID.uuidString] }
        return value
    }
    private func call(_ data: Data) throws -> AgentHTTPResponse {
        guard let store, let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tool = envelope["tool"] as? String, let raw = envelope["arguments"] as? [String: Any] else {
            throw AgentFailure(400, "invalid_request", "需要 tool 和 arguments。")
        }
        let argsData = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        let args = try JSONDecoder().decode(Arguments.self, from: argsData)
        let writing = writeTools.contains(tool) && !(tool == "layout_blocks" && args.dryRun != false)
        if let id = envelope["workspaceID"] as? String, id != workspaceID {
            throw AgentFailure(409, "workspace_changed", "资料库已切换，请重新连接并确认目标资料库。")
        }
        if writing {
            guard allowWrites else { throw AgentFailure(403, "read_only", "当前 Agent 接口仅允许读取。") }
            guard envelope["workspaceID"] as? String == workspaceID else {
                throw AgentFailure(409, "workspace_required", "写入必须携带 /v1/status 返回的 workspaceID。")
            }
        }
        let requestID = envelope["requestID"] as? String ?? ""
        let fingerprint = AssetFingerprint.sha256(Data(tool.utf8) + argsData)
        if writing {
            guard (8...128).contains(requestID.utf8.count), requestID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:")).contains($0) }) else {
                throw AgentFailure(400, "request_id_required", "每次写入需要 8–128 字符的独立 requestID，重试沿用同一值。")
            }
            if let receipt = store.workspace.agentReceipts?.first(where: { $0.requestID == requestID }) {
                guard receipt.fingerprint == fingerprint else { throw AgentFailure(409, "request_id_conflict", "同一个 requestID 不能用于不同内容。") }
                return AgentHTTPResponse(body: receipt.result)
            }
            guard store.saveEditors() else { throw AgentFailure(409, "editor_unsaved", "当前编辑器有未保存的修改，请先处理。") }
        }
        switch tool {
        case "list_pages":
            let offset = max(0, args.offset ?? 0), limit = min(100, max(1, args.limit ?? 50))
            let pages = store.workspace.notes.filter { !$0.deleted && (args.parentID == nil || $0.parentID == args.parentID)
                && (args.query == nil || ($0.title + " " + $0.summary).localizedCaseInsensitiveContains(args.query!)) }
                .sorted { ReferencePath.title(of: $0.id, in: store.workspace).joined(separator:"/").localizedStandardCompare(ReferencePath.title(of: $1.id, in: store.workspace).joined(separator:"/")) == .orderedAscending }
            let selected = Array(pages.dropFirst(offset).prefix(limit))
            return try json(["workspaceID":workspaceID,"pages":selected.map { pageJSON($0, store:store) },"total":pages.count,
                             "nextOffset": offset + selected.count < pages.count ? offset + selected.count as Any : NSNull()])
        case "read_page":
            return try json(["workspaceID":workspaceID,"page":pageJSON(try requirePage(args.pageID, store:store), store:store, includeBlocks:true)])
        case "read_attachment":
            return try readAttachment(args, store:store)
        case "create_page", "append_blocks", "update_block", "layout_blocks": break
        default: throw AgentFailure(404, "unknown_tool", "未知工具。请先读取 /v1/tools。")
        }
        var candidate = store.workspace
        let previous: Note
        var page: Note
        if tool == "create_page" {
            let title = (args.title ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 200 else { throw AgentFailure(422, "title_required", "标题长度需为 1–200 字。") }
            if args.parentID != nil { _ = try requirePage(args.parentID, store:store) }
            page = Note(title:title, parent:args.parentID, folder:args.isFolder ?? false)
            let width = args.canvasWidth ?? store.note?.width ?? 1200
            guard width.isFinite, (320...6000).contains(width) else { throw AgentFailure(422, "invalid_width", "画布宽度需在 320–6000 点之间。") }
            page.canvasWidth = width
            var tombstone = page; tombstone.deleted = true; previous = tombstone
        } else {
            page = try requirePage(args.pageID, store:store); previous = page
            guard args.expectedRevision == page.revision else {
                throw AgentFailure(409, "revision_conflict", "页面已有新修改，请重新读取并调整方案后再写入。")
            }
        }
        guard !page.isFolder || (tool == "create_page" && (args.blocks ?? []).isEmpty) else {
            throw AgentFailure(422, "folder_has_no_blocks", "文件夹用于组织子页面，请将内容放入页面。")
        }
        if tool == "create_page" || tool == "append_blocks" {
            let inputs = args.blocks ?? []
            guard inputs.count <= AgentLimits.blocksPerCall, tool != "append_blocks" || !inputs.isEmpty else {
                throw AgentFailure(422, "invalid_blocks", "每次可写入 1–50 个内容块。")
            }
            var fresh: [Block] = []
            for input in inputs {
                var block = try makeBlock(input, store: store, page: page)
                if let path = block.relativeFilePath, let original = fresh.first(where: { $0.relativeFilePath == path }) {
                    block.fileID = original.fileIdentity
                    block.reference = original.reference ?? FileReference(noteID: page.id, blockID: original.id)
                }
                fresh.append(block)
            }
            page.blocks += try AgentLayout.arrange(fresh, in:page, style:args.style ?? .reading)
        } else if tool == "update_block" {
            guard let index = page.blocks.firstIndex(where: { $0.id == args.blockID }) else { throw AgentFailure(404, "block_not_found", "找不到内容块。") }
            guard !page.blocks[index].locked else { throw AgentFailure(409, "locked_block", "请在应用内解锁后修改。") }
            guard args.text != nil || args.collapsed != nil || args.sourceURL != nil else { throw AgentFailure(422, "empty_update", "未指定要修改的内容。") }
            if let text = args.text {
                guard [.text,.formula].contains(page.blocks[index].kind), text.count <= AgentLimits.textCharacters else {
                    throw AgentFailure(422, "invalid_text", "这里只修改文字/公式块，最长 100000 字符。")
                }
                page.blocks[index].text = text; page.blocks[index].rtf = nil
                if page.blocks[index].kind == .text { page.blocks[index].textFormat = .markdown }
            }
            if let url = args.sourceURL { page.blocks[index].sourceURL = try validURL(url) }
            if let collapsed = args.collapsed, collapsed != (page.blocks[index].collapsed == true) {
                var block = page.blocks[index]
                guard block.isFilePlugin else { throw AgentFailure(422, "not_attachment", "只有文件与链接块可收起。") }
                try AgentLayout.protectExisting([block], in:page)
                if collapsed { block.expandedHeight = block.frame.height }
                block.collapsed = collapsed
                block.frame.height = collapsed ? Block.collapsedHeight : max(80, block.expandedHeight ?? 500)
                guard CanvasLayout.fits(block.frame, paper:page.paper, canvasWidth:page.width),
                      !page.blocks.contains(where: { $0.id != block.id && block.visibleFrame.intersects($0.visibleFrame) }) else {
                    throw AgentFailure(409, "preview_needs_space", "展开位置与其他内容冲突，请先调整排版或在阅读器中查看。")
                }
                page.blocks[index] = block
            }
        } else {
            let ids = args.blockIDs ?? page.blocks.sorted { $0.frame.y == $1.frame.y ? $0.frame.x < $1.frame.x : $0.frame.y < $1.frame.y }.map(\.id)
            guard !ids.isEmpty, Set(ids).count == ids.count, ids.count <= AgentLimits.blocksPerCall else {
                throw AgentFailure(422, "invalid_order", "排序列表应包含 1–50 个互不重复的块 ID。")
            }
            let blocks = try ids.map { id -> Block in
                guard let block = page.blocks.first(where: { $0.id == id }) else { throw AgentFailure(404, "block_not_found", "排序列表包含不存在的块。") }; return block
            }
            try AgentLayout.protectExisting(blocks, in:page)
            let arranged = try AgentLayout.arrange(blocks, in:page, style:args.style ?? .reading, replacing:Set(ids))
            if args.dryRun != false {
                return try json(["workspaceID":workspaceID,"dryRun":true,"pageID":page.id.uuidString,"revision":page.revision.uuidString,
                                 "blocks":arranged.map { blockJSON($0,pageID:page.id,store:store) }])
            }
            page.blocks = page.blocks.filter { !ids.contains($0.id) } + arranged
        }
        if tool == "create_page", page.blocks.count == 1, let file = page.blocks.first,
           file.reference == nil, let path = file.relativeFilePath { page.managedFilePath = path }
        page.extendCanvasForContent(); page.touch(store.device)
        if let index = candidate.notes.firstIndex(where: { $0.id == page.id }) { candidate.notes[index] = page }
        else { candidate.notes.append(page) }
        candidate.pending.insert("page_" + page.id.uuidString)
        let changed = page.blocks.filter { block in !previous.blocks.contains(block) }.map { block -> [String:Any] in
            var value = blockJSON(block,pageID:page.id,store:store); value.removeValue(forKey:"text"); return value
        }
        let result = try json(["workspaceID":workspaceID,"requestID":requestID,"page":pageJSON(page,store:store),"changedBlocks":changed])
        var receipts = candidate.agentReceipts ?? []
        receipts.append(AgentReceipt(requestID:requestID,fingerprint:fingerprint,tool:tool,result:result.body))
        candidate.agentReceipts = Array(receipts.suffix(256))
        try store.commitAgentWorkspace(candidate,previous:previous)
        store.expandAncestors(of:page.id)
        didWrite?("\(tool) · \(page.title)")
        return result
    }
    private func validURL(_ value: String) throws -> String {
        guard let url = WebLink.url(value) else { throw AgentFailure(422, "invalid_url", "链接必须使用 http 或 https。") }
        return url.absoluteString
    }
    private func makeBlock(_ input: AgentBlockInput, store: AppStore, page: Note) throws -> Block {
        var block: Block
        let height = input.height ?? 480
        guard height.isFinite, (80...1600).contains(height) else { throw AgentFailure(422,"invalid_height","预览高度需在 80–1600 点之间。") }
        switch input.kind {
        case "text", "formula":
            let text = input.text ?? ""
            guard !text.isEmpty, text.count <= AgentLimits.textCharacters else { throw AgentFailure(422,"invalid_text","文字不能为空，最长 100000 字符。") }
            block = Block(input.kind == "text" ? .text : .formula,frame:Rect(0,0,600,input.kind == "formula" ? 160 : 240),text:text)
        case "link":
            let url = try validURL(input.url ?? "")
            block = Block(.link,frame:Rect(0,0,360,height)); block.linkURL = url; block.linkMode = .card
            block.assetName = input.filename ?? URL(string:url)?.host ?? "网页"; block.fileID = block.id
        case "reference":
            let source = try requirePage(input.sourcePageID,store:store)
            guard let original = source.blocks.first(where: { $0.id == input.sourceBlockID && $0.isFilePlugin }) else {
                throw AgentFailure(404,"reference_not_found","找不到引用的文件块。")
            }
            block = original; block.id = UUID(); block.reference = original.reference ?? FileReference(noteID:source.id,blockID:original.id)
            block.fileID = original.fileIdentity; block.anchorID = nil; block.locked = false; block.pageAnnotations = nil
        case "file", "attachment":
            guard input.dataBase64 == nil, let path = input.filePath,
                  let url = ReferencePath.resolve(path, inside: store.repository.root) else {
                throw AgentFailure(422, "index_only", "只接受资料库内已有文件的 filePath 相对路径；请先手动放入原文件，不接受 Base64 附件。")
            }
            do { block = try store.indexedBlock(at: url) }
            catch { throw AgentFailure(422, "invalid_file", error.localizedDescription) }
            block.frame = Rect(0, 0, 360, height)
        default: throw AgentFailure(422,"invalid_kind","内容类型应为 text、formula、file、reference 或 link。")
        }
        if let url = input.sourceURL { block.sourceURL = try validURL(url) }
        if block.isFilePlugin {
            block.expandedHeight = height; block.collapsed = input.collapsed ?? true
            block.frame.height = block.collapsed == true ? Block.collapsedHeight : height
        }
        return block
    }
    private func readAttachment(_ args: Arguments, store: AppStore) throws -> AgentHTTPResponse {
        let page = try requirePage(args.pageID,store:store)
        guard let block = page.blocks.first(where: { $0.id == args.blockID && $0.isFilePlugin }) else { throw AgentFailure(404,"block_not_found","找不到附件。") }
        var result = blockJSON(block,pageID:page.id,store:store)
        result["workspaceID"] = workspaceID; result["revision"] = page.revision.uuidString
        let format = args.format ?? "metadata"
        if format == "metadata" { return try json(result) }
        guard let url = store.attachmentURL(for:block), FileManager.default.fileExists(atPath:url.path) else {
            throw AgentFailure(404,"asset_unavailable","附件还未下载，或该链接尚未保存 HTML。")
        }
        do { try store.iCloudFiles.requireLocal(url) }
        catch { throw AgentFailure(409, "download_required", "请先在 Libere 预览中下载这个 iCloud 文件，再读取内容。") }
        let size = (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size <= AgentLimits.attachmentBytes else { throw AgentFailure(413,"asset_too_large","此附件超过 API 单次读取上限，请在应用中查看。") }
        let data = try Data(contentsOf:url)
        guard data.count <= AgentLimits.attachmentBytes else { throw AgentFailure(413,"asset_too_large","附件已超过单次读取上限。") }
        result["contentSHA256"] = AssetFingerprint.sha256(data); result["contentBytes"] = data.count
        if format == "base64" { result["dataBase64"] = data.base64EncodedString() }
        else if format == "text" {
            guard AttachmentFormat(filename: block.assetName) != .image else {
                throw AgentFailure(422,"image_not_text","图片没有文本源码，请使用 base64 读取原件。")
            }
            let text = block.kind == .pdf ? (PDFDocument(data:data)?.string ?? "") : try EditableText(data:data).text
            let offset = max(0,args.offset ?? 0), limit = min(100_000,max(1,args.limit ?? 20_000))
            let part = String(text.dropFirst(offset).prefix(limit))
            result["text"] = part; result["totalCharacters"] = text.count
            result["nextOffset"] = offset + part.count < text.count ? offset + part.count as Any : NSNull()
        } else { throw AgentFailure(422,"invalid_format","读取格式为 metadata、text 或 base64。") }
        return try json(result)
    }
}
