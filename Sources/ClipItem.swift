import AppKit
import ImageIO

/// One clipboard history entry. Its data lives in memory only.
struct ClipItem {
    enum Kind { case text, file, image, other }

    /// One dictionary per pasteboard item (e.g. one per file when several files are copied).
    typealias Contents = [[NSPasteboard.PasteboardType: Data]]

    let id = UUID()
    let date = Date()
    let contents: Contents
    let kind: Kind
    /// Single-line label for lists and menus.
    let title: String
    /// Used for searching and for joining several items into one paste.
    let plainText: String?
    let icon: NSImage?
    let sourceApp: String?
    let byteSize: Int
    let fingerprint: Int

    init?(contents: Contents, sourceApp: String?) {
        guard !contents.isEmpty else { return nil }
        self.contents = contents
        self.sourceApp = sourceApp
        byteSize = contents.reduce(0) { total, entry in total + entry.values.reduce(0) { $0 + $1.count } }

        var hasher = Hasher()
        for entry in contents {
            for (type, data) in entry.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                hasher.combine(type.rawValue)
                data.withUnsafeBytes { hasher.combine(bytes: $0) }
            }
        }
        fingerprint = hasher.finalize()

        let fileURLs = contents.compactMap { $0[.fileURL].flatMap { URL(dataRepresentation: $0, relativeTo: nil) } }
        let strings = contents.compactMap { $0[.string].flatMap { String(data: $0, encoding: .utf8) } }

        if !fileURLs.isEmpty {
            kind = .file
            let first = fileURLs[0].lastPathComponent
            title = fileURLs.count == 1 ? first : "\(first) + \(fileURLs.count - 1) more"
            plainText = fileURLs.map(\.path).joined(separator: "\n")
            icon = NSWorkspace.shared.icon(forFile: fileURLs[0].path)
        } else if !strings.isEmpty {
            kind = .text
            let text = strings.joined(separator: "\n")
            title = Self.singleLine(text)
            plainText = text
            let isLink = text.hasPrefix("http") && text.contains("://") && !text.contains(where: \.isWhitespace)
            icon = Self.symbol(isLink ? "link" : "doc.plaintext")
        } else if let imageData = contents.lazy.compactMap({ $0[.png] ?? $0[.tiff] }).first {
            kind = .image
            let info = Self.describeImage(imageData)
            title = info.title
            icon = info.thumbnail
            plainText = nil
        } else {
            kind = .other
            title = "Rich content"
            plainText = nil
            icon = Self.symbol("doc.richtext")
        }
    }

    func matches(_ query: String) -> Bool {
        (plainText ?? title).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Tooltip text: a longer preview plus where and when it was copied.
    var preview: String {
        let body = kind == .image ? title : String((plainText ?? title).prefix(800))
        var details = [ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .memory),
                       Self.relativeFormatter.localizedString(for: date, relativeTo: Date())]
        if let sourceApp { details.insert(sourceApp, at: 0) }
        return body + "\n\n" + details.joined(separator: " · ")
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()

    private static func singleLine(_ text: String) -> String {
        let line = text.prefix(1_000).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if line.isEmpty { return "(whitespace)" }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Reads pixel size and a small thumbnail without decoding the full image.
    private static func describeImage(_ data: Data) -> (title: String, thumbnail: NSImage?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return ("Image", symbol("photo"))
        }
        var title = "Image"
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            title = "Image  \(width) × \(height)"
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            .map { NSImage(cgImage: $0, size: .zero) }
        return (title, thumbnail ?? symbol("photo"))
    }
}
