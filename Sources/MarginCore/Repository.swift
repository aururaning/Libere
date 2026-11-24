import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum StoreError: LocalizedError {
    case corrupt, unsupported(Int), attachmentMismatch
    public var errorDescription: String? {
        switch self {
        case .corrupt: return "资料库无法读取。原文件与备份已保留，请从备份恢复。"
        case .unsupported(let version): return "资料库格式为版本 \(version)，请升级应用。"
        case .attachmentMismatch: return "附件校验不一致。原件已保留，请重新导入。"
        }
    }
}
public struct AssetFingerprint: Equatable, Sendable {
    public let sha256: String
    public let bytes: Int64
    public static func read(_ url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk); bytes += Int64(chunk.count) }
        return Self(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes)
    }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
public final class Repository: @unchecked Sendable {
    public let root: URL
    public var workspaceURL: URL { root.appendingPathComponent("workspace.json") }
    public var assets: URL { root.appendingPathComponent("Assets", isDirectory: true) }
    public var sync: URL { root.appendingPathComponent("Sync", isDirectory: true) }
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func load() throws -> Workspace? {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else { return nil }
        let data = try Data(contentsOf: workspaceURL)
        guard var value = try? JSONDecoder().decode(Workspace.self, from: data) else { throw StoreError.corrupt }
        guard (1...3).contains(value.schemaVersion) else { throw StoreError.unsupported(value.schemaVersion) }
        value.enforcePurges()
        return value
    }
    public func save(_ value: Workspace) throws {
        var next = value
        if FileManager.default.fileExists(atPath: workspaceURL.path) {
            let current = try Data(contentsOf: workspaceURL)
            guard var prior = try? JSONDecoder().decode(Workspace.self, from: current) else { throw StoreError.corrupt }
            if prior.schemaVersion >= 3 || next.purgedPages?.isEmpty == false { next.schemaVersion = max(3, next.schemaVersion) }
            // A stale writer or old backup must not remove permanent tombstones.
            for tombstone in (prior.purgedPages ?? [:]).values { next.mergePurge(tombstone, enforce: false) }
            for tombstone in (next.purgedPages ?? [:]).values { prior.mergePurge(tombstone, enforce: false) }
            prior.enforcePurges()
            let previous = next.purgedPages?.isEmpty == false ? try JSONEncoder().encode(prior) : current
            try Self.writeAtomically(previous, to: root.appendingPathComponent("workspace.previous.json"))
        }
        next.enforcePurges()
        try Self.writeAtomically(JSONEncoder().encode(next), to: workspaceURL)
    }
    /// Stage beside the destination so saving only needs access to this directory, including on exFAT.
    public static func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        if rename(temporary.path, destination.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
    public func asset(_ id: UUID) -> URL {
        let legacy = assets.appendingPathComponent(id.uuidString + ".pdf")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return assets.appendingPathComponent(id.uuidString)
    }
    @discardableResult public func copyAsset(_ source: URL, id: UUID) throws -> AssetFingerprint {
        throw FileIndexError.indexOnly
    }
}
