import AppKit
import SwiftUI

/// Renders the panel with sample data (for the README screenshot) and the app icon.
@MainActor
enum Snapshot {
    static func render(to dir: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clipnest-snapshot-\(UUID().uuidString)")
        let store = ClipStore(baseDir: tmp)
        func app(_ id: String) -> NSRunningApplication? { nil }

        let img = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { r in
            NSGradient(colors: [NSColor.systemTeal, NSColor.systemIndigo])?.draw(in: r, angle: 35)
            return true
        }
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            store.addImage(png: png, width: 1280, height: 800, app: nil)
        }
        store.addFiles([URL(fileURLWithPath: "/Applications/Safari.app")], app: nil)
        store.addText("#5B8CFF", app: nil)
        store.addText("""
        func greet(_ name: String) -> String {
            let hour = Calendar.current.component(.hour, from: Date())
            return hour < 12 ? "早上好，\\(name)" : "你好，\\(name)"
        }
        """, app: nil)
        store.addText("https://github.com/ergt10/Clipboard-mac", app: nil)
        store.addText("会议改到周四下午三点，地点在 3 楼大会议室，记得带上季度报告。", app: nil)

        let model = PanelModel(store: store)
        model.selection = 2
        for scheme in [ColorScheme.light, .dark] {
            let view = ContentView(model: model, store: store, staticLayout: true)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                let name = scheme == .dark ? "screenshot-dark.png" : "screenshot-light.png"
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    static func icon(to path: String) {
        let view = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.38, green: 0.60, blue: 1.0),
                                              Color(red: 0.42, green: 0.30, blue: 0.93)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
            Image(systemName: "list.clipboard.fill")
                .font(.system(size: 430, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 1024, height: 1024)
        let r = ImageRenderer(content: view)
        r.scale = 1
        if let cg = r.cgImage {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }
}
