import Foundation

public struct AgentReceipt: Codable, Equatable, Sendable {
    public var requestID: String
    public var fingerprint: String
    public var tool: String
    public var result: Data
    public var createdAt: Date
    public init(requestID: String, fingerprint: String, tool: String, result: Data) {
        self.requestID = requestID; self.fingerprint = fingerprint; self.tool = tool
        self.result = result; createdAt = Date()
    }
}

public struct AgentFailure: LocalizedError, Sendable {
    public let status: Int
    public let code: String
    public let message: String
    public init(_ status: Int = 400, _ code: String, _ message: String) {
        self.status = status; self.code = code; self.message = message
    }
    public var errorDescription: String? { message }
}

public enum AgentLimits {
    public static let bodyBytes = 96 * 1024 * 1024
    public static let attachmentBytes = 64 * 1024 * 1024
    public static let headerBytes = 16 * 1024
    public static let blocksPerCall = 50
    public static let textCharacters = 100_000
}

public struct AgentHTTPHead: Sendable {
    public var method: String
    public var target: String
    public var headers: [String: String]
    public var bodyLength: Int
    public var bodyOffset: Int
    public func authorize(token: String, port: UInt16) throws {
        guard headers["host"] == "127.0.0.1:\(port)" || headers["host"] == "localhost:\(port)" else {
            throw AgentFailure(403, "invalid_host", "仅接受本机地址。")
        }
        guard headers["origin"] == nil else { throw AgentFailure(403, "browser_origin", "请使用 agent 客户端连接。") }
        let supplied = headers["authorization"] ?? ""
        let expected = "Bearer " + token
        let a = Array(supplied.utf8), b = Array(expected.utf8)
        var difference = a.count ^ b.count
        for index in b.indices { difference |= Int((index < a.count ? a[index] : 0) ^ b[index]) }
        guard token.count >= 32, difference == 0 else { throw AgentFailure(401, "unauthorized", "Agent 访问令牌无效。") }
    }
}

public struct AgentHTTPRequest: Sendable {
    public var head: AgentHTTPHead
    public var body: Data
    public static func head(in data: Data) throws -> AgentHTTPHead? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > AgentLimits.headerBytes { throw AgentFailure(431, "headers_too_large", "请求头过大。") }
            return nil
        }
        guard range.upperBound <= AgentLimits.headerBytes,
              let text = String(data: data.prefix(range.lowerBound), encoding: .utf8) else {
            throw AgentFailure(400, "invalid_headers", "请求头无效。")
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(first[0]),
              first[1].hasPrefix("/v1/"), !first[1].contains("#") else {
            throw AgentFailure(400, "invalid_request", "需要 HTTP/1.1 GET/POST 和 /v1/ 路径。")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                throw AgentFailure(400, "invalid_headers", "请求头无效。")
            }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }), headers[name] == nil else {
                throw AgentFailure(400, "duplicate_header", "不接受重复或无效的请求头。")
            }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw AgentFailure(400, "unsupported_encoding", "请使用 Content-Length。") }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let length = Int(lengthText), length <= AgentLimits.bodyBytes else {
            throw AgentFailure(413, "body_too_large", "请求大小超过 96 MiB。")
        }
        if first[0] == "POST" {
            guard headers["content-length"] != nil else { throw AgentFailure(411, "length_required", "需要 Content-Length。") }
            guard headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else {
                throw AgentFailure(415, "json_required", "请求内容必须是 application/json。")
            }
        } else if length != 0 { throw AgentFailure(400, "unexpected_body", "GET 请求不携带正文。") }
        return AgentHTTPHead(method: String(first[0]), target: String(first[1]), headers: headers, bodyLength: length, bodyOffset: range.upperBound)
    }
    public static func parse(_ data: Data) throws -> Self? {
        guard let head = try head(in: data), data.count >= head.bodyOffset + head.bodyLength else { return nil }
        guard data.count == head.bodyOffset + head.bodyLength else { throw AgentFailure(400, "multiple_requests", "每个连接仅接受一个请求。") }
        return Self(head: head, body: Data(data.dropFirst(head.bodyOffset)))
    }
}

public struct AgentHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String
    public init(_ status: Int = 200, body: Data, contentType: String = "application/json; charset=utf-8") {
        self.status = status; self.body = body; self.contentType = contentType
    }
    public static func failure(_ failure: AgentFailure) -> Self {
        let data = try! JSONSerialization.data(withJSONObject: ["error": ["code": failure.code, "message": failure.message]], options: [.sortedKeys])
        return Self(failure.status, body: data)
    }
    public var encoded: Data {
        let reason = status == 200 ? "OK" : status == 201 ? "Created" : "Request Failed"
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8)
        data.append(body); return data
    }
}

public struct AgentBlockInput: Decodable {
    public var kind: String
    public var text: String?
    public var filename: String?
    public var dataBase64: String?
    public var url: String?
    public var sourceURL: String?
    public var sourcePageID: UUID?
    public var sourceBlockID: UUID?
    public var collapsed: Bool?
    public var height: Double?
}

public enum AgentLayoutStyle: String, Codable, CaseIterable, Sendable { case reading, column, grid }

public enum AgentLayout {
    public static func protectExisting(_ blocks: [Block], in note: Note) throws {
        guard note.ink == nil || note.ink?.isEmpty == true else {
            throw AgentFailure(409, "handwriting_present", "已有画布手写，保留其对应位置；请在后面追加资料。")
        }
        let attached = Set(note.anchors.map(\.ownerID))
        guard !blocks.contains(where: { $0.locked || $0.anchorID != nil || attached.contains($0.id)
            || ($0.pageAnnotations?.values.contains { $0.ink != nil || !$0.texts.isEmpty } ?? false) }) else {
            throw AgentFailure(409, "protected_layout", "锁定或关联批注的块不参与 agent 自动排版。")
        }
    }
    /// Stable reading order; existing content and ink are obstacles, never layout participants.
    public static func arrange(_ blocks: [Block], in note: Note, style: AgentLayoutStyle, replacing: Set<UUID> = []) throws -> [Block] {
        let margin = 28.0, gap = 24.0, available = note.width - 2 * margin
        guard available >= 100, available.isFinite, blocks.count <= AgentLimits.blocksPerCall else {
            throw AgentFailure(422, "invalid_layout", "页面宽度或块数量无效。")
        }
        let fixed = note.blocks.filter { !replacing.contains($0.id) }.map(\.visibleFrame)
        let inkBottom = note.inkBounds?.maxY ?? (note.ink == nil ? 0 : note.height)
        let bottom = max(fixed.map(\.maxY).max() ?? 0, inkBottom)
        let start = bottom > 0 ? bottom + gap : margin
        let twoColumns = style == .reading && available >= 900
        let count = style == .grid ? max(1, min(3, Int((available + gap) / (280 + gap)))) : 1
        let gridWidth = (available - Double(count - 1) * gap) / Double(count)
        let textWidth = min(760, (available - gap) * 0.66)
        let fileWidth = available - textWidth - gap
        var nextTextY = start, nextFileY = start, rowY = start, rowBottom = start
        var output: [Block] = []
        for (index, original) in blocks.enumerated() {
            var block = original
            let isFile = block.isFilePlugin
            let width = twoColumns ? (isFile ? fileWidth : textWidth) : style == .grid ? gridWidth : min(860, available)
            let height: Double
            if isFile && block.collapsed == true { height = Block.collapsedHeight }
            else if block.kind == .text {
                let columns = max(12, Int(width / max(10, block.fontSize)))
                let lines = block.text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / Double(columns)))) }
                height = min(1600, max(140, Double(lines) * block.fontSize * 1.5 + 48))
            } else { height = min(1200, max(140, block.frame.height)) }
            let x: Double, y: Double
            if twoColumns {
                x = isFile ? margin + textWidth + gap : margin
                y = isFile ? nextFileY : nextTextY
                if isFile { nextFileY += height + 16 } else { nextTextY += height + gap }
            } else if style == .grid {
                if index % count == 0 { rowY = index == 0 ? start : rowBottom + gap }
                x = margin + Double(index % count) * (width + gap); y = rowY
                rowBottom = max(rowBottom, y + height)
            } else { x = margin; y = nextTextY; nextTextY += height + (isFile && block.collapsed == true ? 12 : gap) }
            let frame = Rect(x, y, width, height)
            guard CanvasLayout.fits(frame, paper: note.paper, canvasWidth: note.width), frame.maxY < 10_000_000 else {
                throw AgentFailure(422, "page_full", "当前纸张容不下这些资料，请使用长页或拆分为子页面。")
            }
            block.frame = frame; output.append(block)
        }
        return output
    }
}
