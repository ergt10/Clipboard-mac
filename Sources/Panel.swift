import AppKit
import SwiftUI
import Carbon.HIToolbox

final class FloatingPanel: NSPanel {
    var onResign: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

func roundedMask(_ radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { r in
        NSColor.black.set()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    img.resizingMode = .stretch
    return img
}

final class PanelController {
    let store: ClipStore
    let watcher: PasteboardWatcher
    let model: PanelModel
    private let panel: FloatingPanel
    private var monitor: Any?

    init(store: ClipStore, watcher: PasteboardWatcher) {
        self.store = store
        self.watcher = watcher
        model = PanelModel(store: store)
        let size = NSSize(width: 800, height: 520)
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(16)

        let host = NSHostingView(rootView: ContentView(model: model, store: store))
        host.sizingOptions = []
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect

        panel.onResign = { [weak self] in self?.hide() }
        model.onActivate = { [weak self] item, paste in self?.activate(item, paste: paste) }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        model.query = ""
        model.filter = .all
        model.selection = 0
        model.axTrusted = Paster.isTrusted

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let s = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.midX - s.width / 2,
                                         y: vf.midY - s.height / 2 + vf.height * 0.08))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        model.focusRequest += 1
        installMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            return self.handle(e) ? nil : e
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        switch Int(e.keyCode) {
        case kVK_Escape:
            if !model.query.isEmpty { model.query = "" } else { hide() }
            return true
        case kVK_DownArrow: model.move(1); return true
        case kVK_UpArrow: model.move(-1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.activate(index: model.selection, paste: !cmd)
            return true
        case kVK_Tab:
            model.cycleFilter(flags.contains(.shift) ? -1 : 1)
            return true
        case kVK_Delete where cmd:
            if let it = model.selected(in: model.visible) { model.delete(it) }
            return true
        default:
            break
        }
        guard cmd, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        if ch == "p" {
            if let it = model.selected(in: model.visible) { model.togglePin(it) }
            return true
        }
        if let n = Int(ch), (1...9).contains(n) {
            model.activate(index: n - 1, paste: true)
            return true
        }
        return false
    }

    private func activate(_ item: ClipItem, paste: Bool) {
        hide()
        Paster.write(item, store: store)
        watcher.syncChangeCount()
        store.bump(item.id)
        guard paste else { return }
        if Paster.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.sendCmdV() }
        } else {
            Paster.requestTrust()
        }
    }
}
