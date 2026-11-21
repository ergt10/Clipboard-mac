import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

@main
enum Entry {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.render(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.icon(to: args[i + 1]) }
            return
        }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = ClipStore()
    lazy var watcher = PasteboardWatcher(store: store)
    lazy var panel = PanelController(store: store, watcher: watcher)
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        watcher.start()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.panel.toggle()
        }
    }

    /// An Edit menu so ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z work in the search field.
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 ClipNest", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "ClipNest")
        img?.isTemplate = true
        statusItem.button?.image = img

        let menu = NSMenu()
        menu.delegate = self
        let open = NSMenuItem(title: "打开剪贴板", action: #selector(openPanel), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        pauseItem = NSMenuItem(title: "暂停记录", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        let clear = NSMenuItem(title: "清空历史（保留已固定）…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ClipNest", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.state = watcher.paused ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openPanel() {
        DispatchQueue.main.async { self.panel.show() }
    }

    @objc private func togglePause() { watcher.paused.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("无法更改登录项", error.localizedDescription)
        }
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "清空剪贴板历史？"
        a.informativeText = "已固定的条目会保留，其余记录将被永久删除。"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { store.clearUnpinned() }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
