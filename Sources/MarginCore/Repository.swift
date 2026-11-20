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
        for url in [root, assets, sync] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    public func load() throws -> Workspace? {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else { return nil }
        let data = try Data(contentsOf: workspaceURL)
        guard let value = try? JSONDecoder().decode(Workspace.self, from: data) else { throw StoreError.corrupt }
        guard value.schemaVersion == 1 else { throw StoreError.unsupported(value.schemaVersion) }
        return value
    }
    public func save(_ value: Workspace) throws {
        let data = try JSONEncoder().encode(value)
        if FileManager.default.fileExists(atPath: workspaceURL.path) {
            let current = try Data(contentsOf: workspaceURL)
            guard (try? JSONDecoder().decode(Workspace.self, from: current)) != nil else { throw StoreError.corrupt }
            try Self.writeAtomically(current, to: root.appendingPathComponent("workspace.previous.json"))
        }
        try Self.writeAtomically(data, to: workspaceURL)
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
        let destination = asset(id)
        if FileManager.default.fileExists(atPath: destination.path) {
            let original = try AssetFingerprint.read(source)
            guard try AssetFingerprint.read(destination) == original else { throw StoreError.attachmentMismatch }
            return original
        }
        let temporary = assets.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        let original = try AssetFingerprint.read(source)
        guard try AssetFingerprint.read(temporary) == original else { throw StoreError.attachmentMismatch }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return original
    }
}
