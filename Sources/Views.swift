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

struct ContentView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: ClipStore
    var staticLayout = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let list = model.visible
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                listPane(list).frame(width: 340)
                Divider().opacity(0.6)
                PreviewPane(item: model.selected(in: list), store: store, staticLayout: staticLayout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 800, height: 520)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            if staticLayout {
                Text("搜索剪贴板历史")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("搜索剪贴板历史", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($searchFocused)
            }
            HStack(spacing: 4) {
                ForEach(Filter.allCases) { f in
                    let on = model.filter == f
                    Text(f.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.06)))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .contentShape(Capsule())
                        .onTapGesture { model.filter = f }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private func listPane(_ list: [ClipItem]) -> some View {
        if list.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.query.isEmpty ? "list.clipboard" : "magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "还没有记录" : "没有匹配的内容")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if model.query.isEmpty {
                    Text("复制任何内容，它就会出现在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if staticLayout {
            VStack(spacing: 2) { rows(list) }
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) { rows(list) }
                        .padding(8)
                }
                .onChange(of: model.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func rows(_ list: [ClipItem]) -> some View {
        let selectedID = model.selected(in: list)?.id
        return ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
            RowView(item: item, index: idx, selected: item.id == selectedID, model: model, store: store)
                .id(item.id)
                .onTapGesture(count: 2) { model.onActivate(item, true) }
                .simultaneousGesture(TapGesture().onEnded { model.selectedID = item.id })
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if !staticLayout {
                Menu {
                    Button("清空历史（保留已固定）…") { Entry.delegate.clearHistory() }
                    Divider()
                    Button("卸载 Clip…") { Entry.delegate.uninstall() }
                    Button("退出 Clip") { Entry.delegate.quit() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多：清空、卸载、退出")
            }
            if model.axTrusted {
                Text("\(store.items.count) 条记录")
            } else {
                Button {
                    Paster.requestTrust()
                    Paster.openAccessibilitySettings()
                } label: {
                    Label("开启辅助功能权限后，回车可直接粘贴", systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
            Spacer()
            KeyHint(key: "↩", label: model.axTrusted ? "粘贴" : "复制")
            KeyHint(key: "⌘↩", label: "复制")
            KeyHint(key: "⌘P", label: "固定")
            KeyHint(key: "⌘⌫", label: "删除")
            KeyHint(key: "⇥", label: "分类")
            KeyHint(key: "⌘Q", label: "退出")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }
}

// MARK: - Row

struct RowView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    @ObservedObject var model: PanelModel
    let store: ClipStore
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Thumb(item: item, store: store, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? " " : item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22)
                      : (hover ? Color.primary.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("粘贴") { model.onActivate(item, true) }
            Button("仅复制") { model.onActivate(item, false) }
            Divider()
            Button(item.pinned ? "取消固定" : "固定") { model.togglePin(item) }
            Button("删除") { model.delete(item) }
        }
    }

    private var subtitle: String {
        var parts = [relativeTime(item.date)]
        if let app = item.sourceApp { parts.insert(app, at: 0) }
        if item.kind == .text, item.lineCount > 1 { parts.append("\(item.lineCount) 行") }
        return parts.joined(separator: " · ")
    }
}

struct Thumb: View {
    let item: ClipItem
    let store: ClipStore
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            base
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            if item.kind == .text, let icon = store.appIcon(item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size * 0.5, height: size * 0.5)
                    .offset(x: size * 0.14, y: size * 0.14)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var base: some View {
        switch item.kind {
        case .image:
            if let img = store.thumbnail(item, maxPixels: 96) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                tile("photo", .purple)
            }
        case .file:
            if let url = item.fileURLs.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().padding(1)
            } else {
                tile("doc", .gray)
            }
        case .text:
            if let c = item.color {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color(nsColor: c))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15)))
            } else if item.linkURL != nil {
                tile("link", .blue)
            } else if item.looksLikeCode {
                tile("chevron.left.forwardslash.chevron.right", .green)
            } else {
                tile("text.alignleft", .gray)
            }
        }
    }

    private func tile(_ symbol: String, _ tint: Color) -> some View {
        ZStack {
            Rectangle().fill(tint.opacity(0.16))
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Preview

struct PreviewPane: View {
    let item: ClipItem?
    let store: ClipStore
    var staticLayout = false

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                content(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.6)
                info(item)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            if let c = item.color {
                VStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: c))
                        .frame(width: 140, height: 140)
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    Text(item.trimmedText.uppercased())
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                let full = item.text ?? ""
                let limit = 30_000
                let body = VStack(alignment: .leading, spacing: 10) {
                    Text(String(full.prefix(limit)))
                        .font(item.looksLikeCode ? .system(size: 12, design: .monospaced) : .system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                    if full.count > limit {
                        Text("预览只显示前 3 万个字符，粘贴的是完整内容。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                if staticLayout {
                    body.frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView { body }
                }
            }
        case .image:
            if let img = store.thumbnail(item, maxPixels: 1400) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(20)
            } else {
                Text("图片文件已丢失").foregroundStyle(.secondary)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(item.fileURLs, id: \.self) { url in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).font(.system(size: 13, weight: .medium))
                                Text(url.deletingLastPathComponent().path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func info(_ item: ClipItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            row("类型", item.kindLabel)
            row("来源", item.sourceApp ?? "未知")
            row("时间", absoluteTime(item.date))
            switch item.kind {
            case .text: row("字符", "\((item.text ?? "").count) 个，\(max(item.lineCount, 1)) 行")
            case .image: row("尺寸", "\(item.pixelWidth ?? 0) × \(item.pixelHeight ?? 0) 像素")
            case .file: row("数量", "\(item.fileURLs.count) 个")
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).lineLimit(1).truncationMode(.middle)
        }
    }
}
