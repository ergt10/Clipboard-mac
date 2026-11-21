import SwiftUI
import AppKit

enum Filter: String, CaseIterable, Identifiable {
    case all = "全部", text = "文本", image = "图片", file = "文件", pinned = "固定"
    var id: String { rawValue }
}

final class PanelModel: ObservableObject {
    @Published var query = "" { didSet { if oldValue != query { selectFirst() } } }
    @Published var filter: Filter = .all { didSet { if oldValue != filter { selectFirst() } } }
    /// The selected row is tracked by item id, so pinning, deleting or a new copy
    /// arriving while the panel is open never moves the selection to another item.
    @Published var selectedID: UUID?
    /// Mouse position at the last hover-selection. Rows sliding under a still pointer
    /// (keyboard scrolling) must not steal the selection; only real mouse movement selects.
    var lastHoverMouse: NSPoint?

    func hoverSelect(_ item: ClipItem) {
        let p = NSEvent.mouseLocation
        guard p != lastHoverMouse else { return }
        lastHoverMouse = p
        selectedID = item.id
    }
    @Published var axTrusted = true
    @Published var focusRequest = 0

    let store: ClipStore
    var onActivate: (ClipItem, Bool) -> Void = { _, _ in }

    init(store: ClipStore) { self.store = store }

    var visible: [ClipItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var list = store.items.filter { item in
            switch filter {
            case .all: return true
            case .text: return item.kind == .text
            case .image: return item.kind == .image
            case .file: return item.kind == .file
            case .pinned: return item.pinned
            }
        }
        if !terms.isEmpty {
            list = list.filter { item in
                let hay = (item.text ?? "") + " " + (item.sourceApp ?? "") + " " + item.kindLabel
                return terms.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        return list.filter(\.pinned) + list.filter { !$0.pinned }
    }

    func selectFirst() { selectedID = visible.first?.id }

    func selectedIndex(in list: [ClipItem]) -> Int? {
        guard !list.isEmpty else { return nil }
        return selectedID.flatMap { id in list.firstIndex { $0.id == id } } ?? 0
    }

    func selected(in list: [ClipItem]) -> ClipItem? {
        selectedIndex(in: list).map { list[$0] }
    }

    func move(_ delta: Int) {
        let list = visible
        guard let i = selectedIndex(in: list) else { return }
        selectedID = list[min(max(i + delta, 0), list.count - 1)].id
    }

    func cycleFilter(_ step: Int) {
        let all = Filter.allCases
        let i = all.firstIndex(of: filter) ?? 0
        filter = all[(i + step + all.count) % all.count]
    }

    /// ⌘1…⌘9: by visible row number.
    func activate(index: Int, paste: Bool) {
        let list = visible
        guard list.indices.contains(index) else { return }
        onActivate(list[index], paste)
    }

    func activateSelected(paste: Bool) {
        if let item = selected(in: visible) { onActivate(item, paste) }
    }

    func togglePin(_ item: ClipItem) { store.togglePin(item.id) }

    func delete(_ item: ClipItem) {
        let before = visible
        let i = before.firstIndex { $0.id == item.id }
        store.delete(item.id)
        if item.id == selectedID || selectedID == nil, let i {
            let after = visible
            selectedID = after.isEmpty ? nil : after[min(i, after.count - 1)].id
        }
    }
}

// MARK: - Root

enum PanelStyle {
    static let width: CGFloat = 380
    static let height: CGFloat = 420
    static let radius: CGFloat = 12
}

struct ContentView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: ClipStore
    var staticLayout = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let list = model.visible
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            listPane(list)
            if !model.axTrusted { permissionBar }
        }
        .frame(width: PanelStyle.width, height: PanelStyle.height)
        .overlay(RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            if staticLayout {
                Text("搜索")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("搜索", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            // The category only shows once Tab has switched away from "all".
            if model.filter != .all {
                Text(model.filter.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .onTapGesture { model.filter = .all }
            }
            if !staticLayout { moreMenu }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var moreMenu: some View {
        Menu {
            Picker("分类", selection: $model.filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("清空历史（保留已固定）…") { Entry.delegate.clearHistory() }
            Button("卸载 Clip…") { Entry.delegate.uninstall() }
            Button("退出 Clip") { Entry.delegate.quit() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func listPane(_ list: [ClipItem]) -> some View {
        if list.isEmpty {
            Text(model.query.isEmpty ? "复制的内容会出现在这里" : "没有匹配的内容")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if staticLayout {
            VStack(spacing: 0) { rows(list) }
                .padding(6)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) { rows(list) }
                        .padding(6)
                }
                .onChange(of: model.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func rows(_ list: [ClipItem]) -> some View {
        let selectedID = model.selected(in: list)?.id
        return ForEach(list) { item in
            RowView(item: item, selected: item.id == selectedID, model: model, store: store)
                .id(item.id)
                .onTapGesture { model.onActivate(item, true) }
        }
    }

    private var permissionBar: some View {
        Button {
            Paster.requestTrust()
            Paster.openAccessibilitySettings()
        } label: {
            Text("开启辅助功能权限后，点击即可直接粘贴")
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - Row

struct RowView: View {
    let item: ClipItem
    let selected: Bool
    @ObservedObject var model: PanelModel
    let store: ClipStore

    var body: some View {
        HStack(spacing: 9) {
            Leading(item: item, store: store)
            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(item.kind == .image ? .secondary : .primary)
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: item.kind == .image ? 44 : 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hoverSelect(item) }
        }
        .help(tooltip)
        .contextMenu {
            Button("粘贴") { model.onActivate(item, true) }
            Button("仅复制") { model.onActivate(item, false) }
            Divider()
            Button(item.pinned ? "取消固定" : "固定") { model.togglePin(item) }
            Button("删除") { model.delete(item) }
        }
    }

    /// One line: the content itself. Whitespace runs are collapsed so multi-line text reads as one line.
    private var label: String {
        switch item.kind {
        case .text:
            return item.trimmedText.prefix(300)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        case .image:
            return "\(item.pixelWidth ?? 0) × \(item.pixelHeight ?? 0)"
        case .file:
            return item.title
        }
    }

    /// Hovering a row long enough shows more of it.
    private var tooltip: String {
        switch item.kind {
        case .text: return String((item.text ?? "").prefix(1000))
        case .file: return item.fileURLs.map(\.path).joined(separator: "\n")
        case .image: return "图片 \(item.pixelWidth ?? 0) × \(item.pixelHeight ?? 0)"
        }
    }
}

/// A small marker in front of each row: an image thumbnail, a file icon, a color swatch,
/// or a faint glyph for links; plain text gets an empty slot so rows stay aligned.
struct Leading: View {
    let item: ClipItem
    let store: ClipStore

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let img = store.thumbnail(item, maxPixels: 96) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    glyph("photo")
                }
            case .file:
                if let url = item.fileURLs.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 18, height: 18)
                } else {
                    glyph("doc")
                }
            case .text:
                if let c = item.color {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: c))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15)))
                        .frame(width: 14, height: 14)
                } else if item.linkURL != nil {
                    glyph("link")
                } else {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
        }
        .frame(width: item.kind == .image ? 32 : 18)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}
