import Foundation

public enum SearchContentKind: String, Sendable, CaseIterable {
    case title, overview, text, formula, file, link, annotation, tag
    public var label: String {
        switch self {
        case .title: return "页面"; case .overview: return "文件夹介绍"; case .text: return "正文"
        case .formula: return "公式"; case .file: return "文件"; case .link: return "链接"
        case .annotation: return "页内批注"; case .tag: return "标签"
        }
    }
}
public struct WorkspaceSearchResult: Identifiable, Hashable, Sendable {
    public let noteID: UUID
    public let blockID: UUID?
    public let annotationPage: Int?
    public let annotationID: UUID?
    public let title: String
    public let path: String
    public let snippet: String
    public let kind: SearchContentKind
    public let score: Int
    public var id: String { [noteID.uuidString, blockID?.uuidString ?? "", annotationPage.map(String.init) ?? "", annotationID?.uuidString ?? "", kind.rawValue].joined(separator: ":") }
}

/// Only strings already stored in Workspace are indexed. This type has no file
/// URL, repository or download dependency, including for attachment contents.
public struct WorkspaceSearch: Sendable {
    private struct Entry: Sendable {
        var noteID: UUID; var blockID: UUID?; var annotationPage: Int?; var annotationID: UUID?
        var title: String; var path: String; var content: String; var folded: String; var context: String
        var tags: Set<String>; var kind: SearchContentKind; var modified: Date
    }
    private var entries: [Entry] = []
    public init(workspace: Workspace) {
        let paths = Self.paths(in: workspace)
        for note in workspace.notes where !note.deleted {
            let path = paths[note.id] ?? note.title, tags = Set((note.tags ?? []).map(Self.fold))
            let context = Self.fold(note.title + " " + path + " " + (note.tags ?? []).joined(separator: " "))
            func entry(_ content: String, _ kind: SearchContentKind, block: UUID? = nil, page: Int? = nil, annotation: UUID? = nil) -> Entry? {
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return Entry(noteID: note.id, blockID: block, annotationPage: page, annotationID: annotation,
                    title: note.title, path: path, content: content, folded: Self.fold(content), context: context,
                    tags: tags, kind: kind, modified: note.modifiedAt)
            }
            if let value = entry(note.title.isEmpty ? "未命名" : note.title, .title) { entries.append(value) }
            if let value = entry(note.folderOverview ?? "", .overview) { entries.append(value) }
            if let value = entry((note.tags ?? []).map { "#" + $0 }.joined(separator: " "), .tag) { entries.append(value) }
            for block in note.blocks {
                if let value = entry(block.text, block.kind == .formula ? .formula : .text, block: block.id) { entries.append(value) }
                if let value = entry([block.assetName, block.relativeFilePath ?? ""].filter { !$0.isEmpty }.joined(separator: " · "), .file, block: block.id) { entries.append(value) }
                if let value = entry([block.linkURL, block.sourceURL].compactMap { $0 }.joined(separator: " · "), .link, block: block.id) { entries.append(value) }
                for (key, annotations) in block.pageAnnotations ?? [:] {
                    guard let page = Int(key), page >= 0 else { continue }
                    for annotation in annotations.texts {
                        if let value = entry(annotation.text, .annotation, block: block.id, page: page, annotation: annotation.id) { entries.append(value) }
                    }
                }
            }
        }
    }
    public static func results(in workspace: Workspace, query: String, limit: Int = 100) -> [WorkspaceSearchResult] {
        Self(workspace: workspace).results(query: query, limit: limit)
    }
    public func results(query: String, limit: Int = 100) -> [WorkspaceSearchResult] {
        guard limit > 0 else { return [] }
        let pieces = Self.queryPieces(query), terms = pieces.filter { !$0.hasPrefix("#") }.map(Self.fold)
        let tags = pieces.filter { $0.hasPrefix("#") }.map { Self.fold(String($0.dropFirst())) }.filter { !$0.isEmpty }
        let phrase = terms.joined(separator: " ")
        var found: [(WorkspaceSearchResult, Date)] = []
        for e in entries {
            guard tags.allSatisfy(e.tags.contains) else { continue }
            if terms.isEmpty {
                guard e.kind == .title else { continue }
            } else {
                // A title hit should not manufacture a hit in every block below it.
                guard terms.contains(where: e.folded.contains), terms.allSatisfy({ e.folded.contains($0) || e.context.contains($0) }) else { continue }
            }
            let base: Int
            switch e.kind {
            case .title: base = 700; case .tag: base = 650; case .file: base = 520
            case .overview: base = 450; case .text, .formula: base = 400; case .annotation: base = 380; case .link: base = 300
            }
            let score = base + (e.folded == phrase ? 250 : e.folded.hasPrefix(phrase) && !phrase.isEmpty ? 100 : 0)
            found.append((WorkspaceSearchResult(noteID: e.noteID, blockID: e.blockID, annotationPage: e.annotationPage,
                annotationID: e.annotationID, title: e.title, path: e.path, snippet: Self.snippet(e.content, query: terms.first(where: e.folded.contains)), kind: e.kind, score: score), e.modified))
        }
        return found.sorted {
            if !terms.isEmpty, $0.0.score != $1.0.score { return $0.0.score > $1.0.score }
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.id < $1.0.id
        }.prefix(min(limit, 500)).map(\.0)
    }
    public static func normalizedTags(_ value: String) -> [String] {
        var seen: Set<String> = []
        return value.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 60 && seen.insert(fold($0)).inserted }.prefix(40).map { $0 }
    }
    static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    static func paths(in workspace: Workspace) -> [UUID: String] {
        let lookup = Dictionary(workspace.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [UUID: String] = [:]
        for note in workspace.notes {
            var pieces = [note.title], next = note.parentID, visited: Set<UUID> = [note.id]
            while let id = next, visited.insert(id).inserted, let parent = lookup[id] { pieces.insert(parent.title, at: 0); next = parent.parentID }
            result[note.id] = pieces.joined(separator: " / ")
        }
        return result
    }
    static func snippet(_ value: String, query: String? = nil) -> String {
        let text = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard text.count > 160 else { return text }
        var start = text.startIndex
        if let query, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) {
            start = text.index(range.lowerBound, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
        }
        let end = text.index(start, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end] + (end == text.endIndex ? "" : "…")
    }
    private static func queryPieces(_ query: String) -> [String] {
        var pieces: [String] = [], current = "", quoted = false
        for c in query {
            if c == "\"" { quoted.toggle() }
            else if c.isWhitespace && !quoted { if !current.isEmpty { pieces.append(current); current = "" } }
            else { current.append(c) }
        }
        if !current.isEmpty { pieces.append(current) }; return pieces
    }
}

public struct WikiLinkCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID; public let title: String; public let path: String
    public var markdown: String { PageLink.markdown(title: title, id: id) }
}
public enum WikiLinkResolution: Equatable, Sendable { case missing, unique(UUID), ambiguous([UUID]) }
public struct WikiLinkCompletion: Equatable, Sendable { public let range: NSRange; public let query: String }
public struct WikiLinkToken: Equatable, Sendable {
    public let range: NSRange; public let title: String?; public let pageID: UUID?; public let label: String?
}
public struct PageBacklink: Identifiable, Equatable, Sendable {
    public let sourceNoteID: UUID; public let sourceBlockID: UUID?; public let annotationPage: Int?
    public let title: String; public let path: String; public let snippet: String; public let count: Int
    public var id: String { sourceNoteID.uuidString + ":" + (sourceBlockID?.uuidString ?? "overview") + ":" + (annotationPage.map(String.init) ?? "") }
}
public enum WikiLinks {
    private static let wikiPattern = try! NSRegularExpression(pattern: #"\[\[([^\[\]\r\n]+)\]\]"#)
    private static let pageURLPattern = try! NSRegularExpression(pattern: #"libere://page/[^\s\)\]\>\"\<]+"#, options: .caseInsensitive)
    private static let mathPattern = try! NSRegularExpression(pattern: #"\$\$[\s\S]*?\$\$|(?<!\$)\$(?![\s$])[^\n$]*\S\$(?![\d$])|\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\]"#)
    public static func completing(in source: String, cursorUTF16: Int) -> (query: String, range: NSRange)? {
        completion(in: source, caretUTF16: cursorUTF16).map { ($0.query, $0.range) }
    }
    public static func candidates(in workspace: Workspace, query: String, excluding: UUID? = nil, limit: Int = 30) -> [WikiLinkCandidate] {
        let term = WorkspaceSearch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines)), paths = WorkspaceSearch.paths(in: workspace)
        return workspace.notes.filter { !$0.deleted && $0.id != excluding && (term.isEmpty || WorkspaceSearch.fold($0.title).contains(term) || WorkspaceSearch.fold(paths[$0.id] ?? "").contains(term)) }
            .sorted { a, b in
                let ap = WorkspaceSearch.fold(a.title).hasPrefix(term), bp = WorkspaceSearch.fold(b.title).hasPrefix(term)
                if ap != bp { return ap }; if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }; return a.id.uuidString < b.id.uuidString
            }.prefix(max(0, min(limit, 100))).map { WikiLinkCandidate(id: $0.id, title: $0.title, path: paths[$0.id] ?? $0.title) }
    }
    public static func resolve(title: String, in workspace: Workspace) -> WikiLinkResolution {
        let key = WorkspaceSearch.fold(title.trimmingCharacters(in: .whitespacesAndNewlines))
        let ids = workspace.notes.filter { !$0.deleted && WorkspaceSearch.fold($0.title.trimmingCharacters(in: .whitespacesAndNewlines)) == key }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        if ids.count == 1 { return .unique(ids[0]) }; return ids.isEmpty ? .missing : .ambiguous(ids)
    }
    public static func completion(in source: String, caretUTF16: Int) -> WikiLinkCompletion? {
        let text = source as NSString
        guard caretUTF16 >= 2, caretUTF16 <= text.length, Range(NSRange(location: caretUTF16, length: 0), in: source) != nil else { return nil }
        let prefix = text.substring(to: caretUTF16) as NSString
        let opening = prefix.range(of: "[[", options: .backwards)
        guard opening.location != NSNotFound, !protectedRanges(in: source).contains(where: { NSLocationInRange(opening.location, $0) }), !escaped(at: opening.location, in: text) else { return nil }
        let query = text.substring(with: NSRange(location: opening.location + 2, length: caretUTF16 - opening.location - 2))
        guard !query.contains(where: { $0 == "[" || $0 == "]" || $0.isNewline }) else { return nil }
        var end = caretUTF16
        if end + 2 <= text.length, text.substring(with: NSRange(location: end, length: 2)) == "]]" { end += 2 }
        return WikiLinkCompletion(range: NSRange(location: opening.location, length: end - opening.location), query: query)
    }
    public static func references(in source: String) -> [WikiLinkToken] {
        guard source.contains("[[") || source.range(of: "libere://", options: .caseInsensitive) != nil else { return [] }
        let text = source as NSString, protected = protectedRanges(in: source)
        var result: [WikiLinkToken] = []
        for match in wikiPattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard !escaped(at: match.range.location, in: text), !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let parts = text.substring(with: match.range(at: 1)).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let title = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            result.append(WikiLinkToken(range: match.range, title: title, pageID: nil, label: parts.count == 2 ? String(parts[1]) : nil))
        }
        for match in pageURLPattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard !escaped(at: match.range.location, in: text),
                  !result.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }),
                  !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let value = text.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            guard let url = URL(string: value), let id = PageLink.noteID(in: url) else { continue }
            result.append(WikiLinkToken(range: match.range, title: nil, pageID: id, label: nil))
        }
        return result.sorted { $0.range.location < $1.range.location }
    }
    public static func renderingSource(_ source: String, in workspace: Workspace) -> String {
        let links = references(in: source).filter { $0.title != nil }
        guard !links.isEmpty else { return source }
        let titles = Dictionary(grouping: workspace.notes.filter { !$0.deleted }, by: { WorkspaceSearch.fold($0.title.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let result = NSMutableString(string: source)
        for token in links.reversed() {
            guard let title = token.title, let matches = titles[WorkspaceSearch.fold(title)], matches.count == 1, let id = matches.first?.id else { continue }
            result.replaceCharacters(in: token.range, with: PageLink.markdown(title: token.label ?? title, id: id))
        }
        return result as String
    }
    public static func backlinks(to target: UUID, in workspace: Workspace) -> [PageBacklink] {
        guard workspace.notes.contains(where: { $0.id == target && !$0.deleted }) else { return [] }
        let paths = WorkspaceSearch.paths(in: workspace)
        let titles = Dictionary(grouping: workspace.notes.filter { !$0.deleted }, by: { WorkspaceSearch.fold($0.title.trimmingCharacters(in: .whitespacesAndNewlines)) })
        var result: [PageBacklink] = []
        for note in workspace.notes where !note.deleted && note.id != target {
            func append(_ source: String, block: UUID? = nil, page: Int? = nil) {
                guard source.contains("[[") || source.localizedCaseInsensitiveContains("libere://page/") else { return }
                let count = references(in: source).filter { token in
                    if let id = token.pageID { return id == target }
                    let matches = titles[WorkspaceSearch.fold(token.title ?? "")] ?? []
                    return matches.count == 1 && matches.first?.id == target
                }.count
                if count > 0 { result.append(PageBacklink(sourceNoteID: note.id, sourceBlockID: block, annotationPage: page,
                    title: note.title, path: paths[note.id] ?? note.title, snippet: WorkspaceSearch.snippet(source), count: count)) }
            }
            append(note.folderOverview ?? "")
            for block in note.blocks {
                if block.kind != .formula { append(block.text, block: block.id) }
                for (key, annotations) in block.pageAnnotations ?? [:] {
                    guard let page = Int(key), page >= 0 else { continue }
                    append(annotations.texts.map(\.text).joined(separator: "\n"), block: block.id, page: page)
                }
            }
        }
        return result.sorted { $0.path == $1.path ? $0.id < $1.id : $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    private static func escaped(at position: Int, in text: NSString) -> Bool {
        var i = position, count = 0
        while i > 0 && text.character(at: i - 1) == 92 { count += 1; i -= 1 }
        return count % 2 == 1
    }
    private static func protectedRanges(in source: String) -> [NSRange] {
        let text = source as NSString
        var ranges: [NSRange] = [], offset = 0
        var fence: (start: Int, marker: Character, count: Int)?
        for line in source.components(separatedBy: "\n") {
            let length = (line as NSString).length, leading = line.prefix { $0 == " " }.count
            let start = line.dropFirst(leading), marker = start.first
            let run = marker.map { m in start.prefix { $0 == m }.count } ?? 0
            if let active = fence {
                if leading <= 3, marker == active.marker, run >= active.count,
                   start.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    ranges.append(NSRange(location: active.start, length: min(text.length, offset + length + 1) - active.start)); fence = nil
                }
            } else if leading <= 3, let marker, marker == "`" || marker == "~", run >= 3 {
                fence = (offset, marker, run)
            }
            offset += length + 1
        }
        if let active = fence { ranges.append(NSRange(location: active.start, length: text.length - active.start)) }
        // Inline code accepts exact-length backtick closers, including embedded
        // shorter runs. Strings and caret offsets stay in UTF-16 coordinates.
        var cursor = 0
        while cursor < text.length {
            if let protected = ranges.first(where: { NSLocationInRange(cursor, $0) }) { cursor = NSMaxRange(protected); continue }
            guard text.character(at: cursor) == 96, !escaped(at: cursor, in: text) else { cursor += 1; continue }
            let start = cursor
            while cursor < text.length && text.character(at: cursor) == 96 { cursor += 1 }
            let length = cursor - start
            var end = cursor, closing: Int?
            while end < text.length {
                guard text.character(at: end) == 96 else { end += 1; continue }
                let runStart = end
                while end < text.length && text.character(at: end) == 96 { end += 1 }
                if end - runStart == length { closing = end; break }
            }
            if let closing { ranges.append(NSRange(location: start, length: closing - start)); cursor = closing }
        }
        for match in mathPattern.matches(in: source, range: NSRange(location: 0, length: text.length)) where !escaped(at: match.range.location, in: text) {
            ranges.append(match.range)
        }
        return ranges
    }
}
