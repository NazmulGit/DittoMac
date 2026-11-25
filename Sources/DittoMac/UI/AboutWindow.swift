import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "About DittoMac"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.contentViewController = NSHostingController(rootView: AboutView())
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
}

private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("DittoMac \(version)").font(.title2.bold())
            Text("Unofficial macOS port of Ditto by Scott Brogden — GPL-3.0")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Link("Upstream: github.com/sabrogden/Ditto", destination: URL(string: "https://github.com/sabrogden/Ditto")!)
            Link("DittoMac releases (check for updates)", destination: URL(string: "https://github.com/NazmulGit/DittoMac-Clipboard-Manager/releases")!)
            Text("This program is free software under the GNU General Public License v3.0. It comes with no warranty.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6)
        }
        .padding(24)
        .frame(width: 380)
    }
}
