import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices

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
    /// The app that was frontmost when the panel opened; ⌘V is only sent if it is still frontmost.
    private var targetApp: NSRunningApplication?
    private var showCount = 0

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
        targetApp = NSWorkspace.shared.frontmostApplication
        model.query = ""
        model.filter = .all
        model.selectFirst()
        model.lastHoverMouse = NSEvent.mouseLocation
        model.axTrusted = Paster.isTrusted

        if let app = targetApp { Caret.prepare(app) }
        let caret = Caret.caretRect()
        panel.setFrameOrigin(Caret.panelOrigin(for: panel.frame.size, anchor: caret))
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        model.focusRequest += 1
        installMonitor()

        // An app that only just started exposing its text fields (see Caret.prepare) may answer
        // a moment later: retry briefly and move the panel under the caret if it shows up.
        showCount += 1
        if caret == nil { retryCaret(show: showCount, delays: [0.15, 0.4]) }
    }

    private func retryCaret(show: Int, delays: [Double]) {
        guard let delay = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.panel.isVisible, self.showCount == show else { return }
            if let caret = Caret.caretRect() {
                self.panel.setFrameOrigin(Caret.panelOrigin(for: self.panel.frame.size, anchor: caret))
            } else {
                self.retryCaret(show: show, delays: Array(delays.dropFirst()))
            }
        }
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
        // While an input method is composing (e.g. Pinyin), keys belong to the search field:
        // Return confirms the candidate, arrows move between candidates.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        switch Int(e.keyCode) {
        case kVK_Escape:
            if !model.query.isEmpty { model.query = "" } else { hide() }
            return true
        case kVK_DownArrow: model.move(1); return true
        case kVK_UpArrow: model.move(-1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.activateSelected(paste: !cmd)
            return true
        case kVK_Tab:
            model.cycleFilter(flags.contains(.shift) ? -1 : 1)
            return true
        case kVK_Delete where cmd && !e.isARepeat:
            if let it = model.selected(in: model.visible) { model.delete(it) }
            return true
        default:
            break
        }
        guard cmd, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        if ch == "q" {
            Entry.delegate.quit()
            return true
        }
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
        guard Paster.write(item, store: store) else {
            NSSound.beep()
            return
        }
        watcher.syncChangeCount()
        let written = NSPasteboard.general.changeCount
        store.bump(item.id)
        guard paste else { return }
        guard Paster.isTrusted else {
            Paster.requestTrust()
            return
        }
        let target = targetApp?.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            // Only paste if nothing changed in between: same app in front, same pasteboard contents.
            guard NSPasteboard.general.changeCount == written,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { return }
            Paster.sendCmdV()
        }
    }
}

/// Finds where the user is typing, so the panel can open right below it.
enum Caret {
    /// Panel origin (Cocoa coordinates): below the text caret if the focused app reports it,
    /// otherwise below the focused text field, otherwise below the mouse pointer.
    static func panelOrigin(for size: NSSize, anchor caret: NSRect?) -> NSPoint {
        let gap: CGFloat = 6
        let anchor = caret ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let probe = NSPoint(x: anchor.minX, y: anchor.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(probe, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return anchor.origin }

        var x = anchor.minX - 12
        var y = anchor.minY - gap - size.height              // below the caret
        if y < vf.minY { y = anchor.maxY + gap }             // no room below: open above it
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    /// The caret (or focused text field) rectangle in Cocoa screen coordinates, via the
    /// Accessibility API. Returns nil without Accessibility permission or if the app reports nothing.
    /// Chromium browsers (Chrome, Edge, Arc, Brave…) and Electron apps only expose their text
    /// fields and caret to the Accessibility API after a client asks for it. Ask once per process.
    private static var prepared = Set<pid_t>()
    private static let chromiumBundlePrefixes = [
        "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    static func prepare(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard AXIsProcessTrusted(), pid != getpid(), !prepared.contains(pid) else { return }
        prepared.insert(pid)
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.1)
        // Electron and recent Chromium: turns on accessibility without other side effects.
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Chromium browsers also listen to the attribute VoiceOver sets. Only sent to them,
        // because some other apps change their window behaviour when it is set.
        if let id = app.bundleIdentifier, chromiumBundlePrefixes.contains(where: { id.hasPrefix($0) }) {
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    static func caretRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        // At most ~0.3 s in total, even if the frontmost app is slow to answer.
        let deadline = Date().addingTimeInterval(0.3)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let focused: AXUIElement = copy(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.1)

        if let range: CFRange = rangeValue(copy(focused, kAXSelectedTextRangeAttribute)) {
            var candidates = [CFRange(location: range.location, length: 0)]
            if range.location > 0 { candidates.append(CFRange(location: range.location - 1, length: 1)) }
            for var r in candidates where Date() < deadline {
                guard let axRange = AXValueCreate(.cfRange, &r) else { continue }
                var out: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(
                        focused, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &out) == .success,
                      let rect = rectValue(out), rect.height > 0, rect.origin != .zero else { continue }
                // The character before the caret: the caret sits at its right edge.
                let caret = r.length == 1 ? CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height) : rect
                return toCocoa(caret)
            }
        }

        // No caret bounds: use the focused element itself if it is a single-line-sized field.
        if Date() < deadline, let pos: CGPoint = pointValue(copy(focused, kAXPositionAttribute)),
           let size: CGSize = sizeValue(copy(focused, kAXSizeAttribute)),
           size.height > 0, size.height < 120 {
            return toCocoa(CGRect(origin: pos, size: size))
        }
        return nil
    }

    /// Accessibility uses top-left-origin coordinates measured from the primary screen.
    private static func toCocoa(_ r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private static func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! T)
        }
        return v as? T
    }

    private static func axValue(_ v: CFTypeRef?, _ type: AXValueType) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        return AXValueGetType(ax) == type ? ax : nil
    }

    private static func rangeValue(_ v: CFTypeRef?) -> CFRange? {
        guard let ax = axValue(v, .cfRange) else { return nil }
        var r = CFRange(); return AXValueGetValue(ax, .cfRange, &r) ? r : nil
    }

    private static func rectValue(_ v: CFTypeRef?) -> CGRect? {
        guard let ax = axValue(v, .cgRect) else { return nil }
        var r = CGRect.zero; return AXValueGetValue(ax, .cgRect, &r) ? r : nil
    }

    private static func pointValue(_ v: CFTypeRef?) -> CGPoint? {
        guard let ax = axValue(v, .cgPoint) else { return nil }
        var p = CGPoint.zero; return AXValueGetValue(ax, .cgPoint, &p) ? p : nil
    }

    private static func sizeValue(_ v: CFTypeRef?) -> CGSize? {
        guard let ax = axValue(v, .cgSize) else { return nil }
        var s = CGSize.zero; return AXValueGetValue(ax, .cgSize, &s) ? s : nil
    }
}
