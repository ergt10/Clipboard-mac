import AppKit

final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    var maxItems = 500

    let baseDir: URL
    let imagesDir: URL
    private let dbURL: URL
    private let io = DispatchQueue(label: "ClipNest.io", qos: .utility)
    private let imageCache = NSCache<NSString, NSImage>()
    private var iconCache: [String: NSImage] = [:]

    init(baseDir: URL? = nil) {
        let fm = FileManager.default
        let base = baseDir ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipNest", isDirectory: true)
        self.baseDir = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        dbURL = base.appendingPathComponent("history.json")
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: dbURL),
           let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = decoded
        }
    }

    // MARK: adding

    func addText(_ s: String, app: NSRunningApplication?) {
        let text = s.count > 500_000 ? String(s.prefix(500_000)) : s
        upsert(ClipItem(kind: .text, text: text, digest: "t:" + sha256Hex(Data(text.utf8))), app: app)
    }

    func addFiles(_ urls: [URL], app: NSRunningApplication?) {
        let joined = urls.map(\.path).joined(separator: "\n")
        upsert(ClipItem(kind: .file, text: joined, digest: "f:" + sha256Hex(Data(joined.utf8))), app: app)
    }

    func addImage(png: Data, width: Int, height: Int, app: NSRunningApplication?) {
        let digest = "i:" + sha256Hex(png)
        if items.contains(where: { $0.digest == digest }) {
            upsert(ClipItem(kind: .image, digest: digest), app: app)
            return
        }
        let name = UUID().uuidString + ".png"
        do { try png.write(to: imagesDir.appendingPathComponent(name)) } catch { return }
        upsert(ClipItem(kind: .image, imageName: name, pixelWidth: width, pixelHeight: height, digest: digest), app: app)
    }

    private func upsert(_ incoming: ClipItem, app: NSRunningApplication?) {
        var new = incoming
        new.sourceApp = app?.localizedName
        new.sourceBundleID = app?.bundleIdentifier
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
        guard let name = item.imageName else { return }
        imageCache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
    }

    private func save() {
        let snapshot = items
        let url = dbURL
        io.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Waits for pending writes; call before quitting.
    func flush() { io.sync {} }

    // MARK: media

    func imageURL(_ item: ClipItem) -> URL? {
        item.imageName.map { imagesDir.appendingPathComponent($0) }
    }

    func image(_ item: ClipItem) -> NSImage? {
        guard let name = item.imageName else { return nil }
        if let img = imageCache.object(forKey: name as NSString) { return img }
        guard let img = NSImage(contentsOf: imagesDir.appendingPathComponent(name)) else { return nil }
        imageCache.setObject(img, forKey: name as NSString)
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
