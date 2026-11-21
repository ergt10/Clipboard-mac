import AppKit
import ImageIO

/// The app that put something on the pasteboard.
struct ClipSource {
    var name: String?
    var bundleID: String?
}

final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    var maxItems = 500
    /// Larger texts are not recorded (they are never truncated, so a paste is always complete).
    static let maxTextBytes = 5_000_000

    let baseDir: URL
    let imagesDir: URL
    private let dbURL: URL
    private let io = DispatchQueue(label: "Clip.io", qos: .utility)
    private let thumbCache = NSCache<NSString, NSImage>()
    private var iconCache: [String: NSImage] = [:]
    private var saveScheduled = false
    /// Image files of removed items; deleted only after the history that no longer
    /// references them has been written, so a failed write never leaves dangling items.
    private var pendingDeletes: [String] = []

    init(baseDir: URL? = nil) {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = baseDir ?? support.appendingPathComponent("Clip", isDirectory: true)
        if baseDir == nil {
            // The app was called ClipNest in 1.0.0: carry its history over once.
            let old = support.appendingPathComponent("ClipNest", isDirectory: true)
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: base.path) {
                try? fm.moveItem(at: old, to: base)
            }
        }
        self.baseDir = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        dbURL = base.appendingPathComponent("history.json")
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: loading

    private struct Lossy: Decodable {
        let item: ClipItem?
        init(from decoder: Decoder) throws { item = try? ClipItem(from: decoder) }
    }

    /// Loads the history. Bad entries are skipped one by one; if anything could not be read,
    /// the original file is kept as a backup instead of being overwritten by the next save.
    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbURL.path) else { return }
        guard let data = try? Data(contentsOf: dbURL),
              let raw = try? JSONDecoder().decode([Lossy].self, from: data) else {
            backupDatabase(reason: "unreadable")
            return
        }
        let decoded = raw.compactMap(\.item).filter { item in
            item.kind != .image || Self.isValidImageName(item.imageName)
        }
        if decoded.count != raw.count { backupDatabase(reason: "partial") }
        items = decoded
        removeOrphanImages()
    }

    private func backupDatabase(reason: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let backup = baseDir.appendingPathComponent("history-\(reason)-\(f.string(from: Date())).json")
        try? FileManager.default.copyItem(at: dbURL, to: backup)
        NSLog("Clip: history file could not be fully read; kept a copy at \(backup.path)")
    }

    private func removeOrphanImages() {
        let referenced = Set(items.compactMap(\.imageName))
        let dir = imagesDir
        io.async {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where Self.isValidImageName(name) && !referenced.contains(name) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// Only names the app generates itself (`<UUID>.png`) are ever read or deleted.
    static func isValidImageName(_ name: String?) -> Bool {
        guard let name, name.hasSuffix(".png") else { return false }
        return UUID(uuidString: String(name.dropLast(4))) != nil
    }

    // MARK: adding

    func addText(_ s: String, source: ClipSource) {
        guard s.utf8.count <= Self.maxTextBytes else { return }
        upsert(ClipItem(kind: .text, text: s, digest: "t:" + sha256Hex(Data(s.utf8))), source: source)
    }

    func addFiles(_ urls: [URL], source: ClipSource) {
        let joined = urls.map(\.path).joined(separator: "\n")
        upsert(ClipItem(kind: .file, text: joined, digest: "f:" + sha256Hex(Data(joined.utf8))), source: source)
    }

    func addImage(png: Data, width: Int, height: Int, source: ClipSource) {
        let digest = "i:" + sha256Hex(png)
        if let existing = items.first(where: { $0.digest == digest }),
           let url = imageURL(existing), FileManager.default.fileExists(atPath: url.path) {
            upsert(ClipItem(kind: .image, digest: digest), source: source)
            return
        }
        let name = UUID().uuidString + ".png"
        do { try png.write(to: imagesDir.appendingPathComponent(name)) } catch { return }
        if let i = items.firstIndex(where: { $0.digest == digest }) {
            // Same image as an entry whose file went missing: drop that entry, keep the new one.
            items.remove(at: i)
        }
        upsert(ClipItem(kind: .image, imageName: name, pixelWidth: width, pixelHeight: height, digest: digest),
               source: source)
    }

    private func upsert(_ incoming: ClipItem, source: ClipSource) {
        var new = incoming
        new.sourceApp = source.name
        new.sourceBundleID = source.bundleID
        if let i = items.firstIndex(where: { $0.digest == new.digest }) {
            var old = items.remove(at: i)
            old.date = Date()
            if new.sourceApp != nil { old.sourceApp = new.sourceApp; old.sourceBundleID = new.sourceBundleID }
            items.insert(old, at: 0)
        } else {
            items.insert(new, at: 0)
            trim()
        }
        save()
    }

    // MARK: editing

    func bump(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items.remove(at: i)
        it.date = Date()
        items.insert(it, at: 0)
        save()
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        save()
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        removeFile(of: items.remove(at: i))
        save()
    }

    func clearUnpinned() {
        items.filter { !$0.pinned }.forEach(removeFile)
        items.removeAll { !$0.pinned }
        save()
    }

    private func trim() {
        while items.count > maxItems, let idx = items.lastIndex(where: { !$0.pinned }) {
            removeFile(of: items.remove(at: idx))
        }
    }

    private func removeFile(of item: ClipItem) {
        guard let name = item.imageName, Self.isValidImageName(name) else { return }
        thumbCache.removeObject(forKey: "\(name)@96" as NSString)
        thumbCache.removeObject(forKey: "\(name)@1400" as NSString)
        pendingDeletes.append(name)
    }

    // MARK: saving

    /// Changes are batched: one write at most every 0.4 s, however many edits happen.
    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.writeNow() }
    }

    private func writeNow() {
        guard saveScheduled else { return }
        saveScheduled = false
        let snapshot = items
        let deletes = pendingDeletes
        pendingDeletes = []
        let url = dbURL, dir = imagesDir
        io.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                for name in deletes { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
            } catch {
                NSLog("Clip: could not save history: \(error.localizedDescription)")
            }
        }
    }

    /// Writes pending changes and waits for them; call before quitting.
    func flush() {
        writeNow()
        io.sync {}
    }

    // MARK: media

    func imageURL(_ item: ClipItem) -> URL? {
        guard Self.isValidImageName(item.imageName), let name = item.imageName else { return nil }
        return imagesDir.appendingPathComponent(name)
    }

    /// A downscaled image (decoded at most `maxPixels` on the long side), cached.
    func thumbnail(_ item: ClipItem, maxPixels: Int) -> NSImage? {
        guard let url = imageURL(item), let name = item.imageName else { return nil }
        let key = "\(name)@\(maxPixels)" as NSString
        if let img = thumbCache.object(forKey: key) { return img }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache.setObject(img, forKey: key)
        return img
    }

    func appIcon(_ bundleID: String?) -> NSImage? {
        guard let id = bundleID else { return nil }
        if let i = iconCache[id] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[id] = icon
        return icon
    }
}
