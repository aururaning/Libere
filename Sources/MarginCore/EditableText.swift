import Foundation

/// Keep the imported bytes and encoding; editing never overwrites the original asset.
public struct EditableText {
    public var text: String
    private let original: Data
    private let originalText: String
    private let encoding: String.Encoding
    private let prefix: Data
    public init(data: Data) throws {
        let formats: [([UInt8], String.Encoding)] = [([0xFF, 0xFE, 0, 0], .utf32LittleEndian), ([0, 0, 0xFE, 0xFF], .utf32BigEndian),
            ([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian)]
        let format = formats.first { data.starts(with: $0.0) }
        prefix = Data(format?.0 ?? []); encoding = format?.1 ?? .utf8
        guard let decoded = String(data: data.dropFirst(prefix.count), encoding: encoding) else {
            throw NSError(domain: "TextFile", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法识别此文本的编码。原件已完整保留，可先转换为 UTF-8 再编辑。"])
        }
        text = decoded; originalText = decoded; original = data
    }
    public func serialized() throws -> Data {
        if text == originalText { return original }
        guard let data = text.data(using: encoding, allowLossyConversion: false) else { throw StoreError.corrupt }
        return prefix + data
    }
}

public enum WebLink {
    public static func url(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0.isWhitespace }), let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
