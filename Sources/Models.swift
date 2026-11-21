import AppKit
import CryptoKit

enum ClipKind: String, Codable { case text, image, file }

struct ClipItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: ClipKind
    var text: String? = nil
    var imageName: String? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var digest: String
    var date: Date = Date()
    var pinned: Bool = false
    var sourceApp: String? = nil
    var sourceBundleID: String? = nil
}

extension ClipItem {
    var trimmedText: String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    var fileURLs: [URL] {
        guard kind == .file, let t = text else { return [] }
        return t.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    var linkURL: URL? {
        guard kind == .text else { return nil }
        let t = trimmedText
        guard t.count < 4096, !t.contains(where: { $0.isWhitespace }),
              let u = URL(string: t), let s = u.scheme?.lowercased(),
              ["http", "https"].contains(s), u.host != nil else { return nil }
        return u
    }

    var color: NSColor? {
        guard kind == .text else { return nil }
        var t = trimmedText
        guard t.hasPrefix("#") else { return nil }
        t.removeFirst()
        guard [3, 6, 8].contains(t.count), let v = UInt64(t, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        switch t.count {
        case 3:
            r = CGFloat((v >> 8) & 0xF) / 15; g = CGFloat((v >> 4) & 0xF) / 15; b = CGFloat(v & 0xF) / 15; a = 1
        case 6:
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255; b = CGFloat(v & 0xFF) / 255; a = 1
        default:
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var lineCount: Int { (text ?? "").split(whereSeparator: \.isNewline).count }

    var title: String {
        switch kind {
        case .text:
            let line = trimmedText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
        case .image:
            return "图片  \(pixelWidth ?? 0) × \(pixelHeight ?? 0)"
        case .file:
            let urls = fileURLs
            if urls.count == 1 { return urls[0].lastPathComponent }
            return "\(urls.first?.lastPathComponent ?? "") 等 \(urls.count) 个文件"
        }
    }

    var kindLabel: String {
        switch kind {
        case .text: return color != nil ? "颜色" : (linkURL != nil ? "链接" : "文本")
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    var looksLikeCode: Bool {
        guard kind == .text, let t = text, t.contains("\n") else { return false }
        let markers = ["{", "}", ";", "=>", "def ", "func ", "import ", "    ", "\t", "</", "$ "]
        return markers.filter { t.contains($0) }.count >= 2
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func relativeTime(_ d: Date) -> String {
    let s = Date().timeIntervalSince(d)
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(Int(s / 60)) 分钟前" }
    if Calendar.current.isDateInToday(d) { return "\(Int(s / 3600)) 小时前" }
    if Calendar.current.isDateInYesterday(d) { f.dateFormat = "HH:mm"; return "昨天 " + f.string(from: d) }
    f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 HH:mm" : "yyyy年M月d日"
    return f.string(from: d)
}

func absoluteTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: d)
}
