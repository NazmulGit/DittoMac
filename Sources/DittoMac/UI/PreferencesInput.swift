import AppKit
import SwiftUI
import DittoCore

// MARK: - Keyboard

struct KeyboardPrefs: View {
    @ObservedObject var m: PrefsModel
    @LState private var clipShortcuts: [Clip] = []

    private static let rows: [(name: String, title: String)] =
        [("activate", "Activate DittoMac"), ("activate2", "Activate DittoMac (alternate 2)"), ("activate3", "Activate DittoMac (alternate 3)"),
         ("textOnlyPaste", "Text-only paste"), ("saveClipboard", "Save current clipboard"), ("copyAndSave", "Copy & save current clipboard")]
        + (1...10).map { ("lastTen\($0)", "Paste last-ten position \($0)") }

    var body: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(Self.rows, id: \.name) { r in
                    LabeledContent(r.title) { KeyRecorder(binding: m.hotkey(r.name)).frame(width: 170) }
                }
                if let n = m.notice { Text(n).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button("Reset to Defaults…") { reset() }
                }
            }
            Section("Clip and group shortcuts (edit in each clip’s Properties)") {
                if clipShortcuts.isEmpty {
                    Text("No clip or group shortcuts assigned.").foregroundStyle(.secondary)
                }
                ForEach(clipShortcuts) { c in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(c.text.prefix(60)).replacingOccurrences(of: "\n", with: " ") + (c.isGroup ? "  (group)" : "")).lineLimit(1)
                        if c.shortcut != 0 {
                            Text("\(KeyCombo(encoded: c.shortcut).displayString)\(c.globalShortcut ? " (Global)" : " (in popup)")").font(.caption).foregroundStyle(.secondary)
                        }
                        if c.moveToGroupShortcut != 0 {
                            Text("Move to group: \(KeyCombo(encoded: c.moveToGroupShortcut).displayString)\(c.globalMoveToGroupShortcut ? " (Global)" : "")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { clipShortcuts = (try? m.state.store.clipsWithShortcuts()) ?? [] }
    }

    private func reset() {
        guard m.confirm("Reset keyboard shortcuts?", "All global shortcuts above return to their defaults.", button: "Reset") else { return }
        for r in Self.rows { m.s.setHotkey(r.name, DittoCore.Settings.defaultHotkeys[r.name] ?? 0) }
        m.notice = nil
        m.hotkeysChanged()
    }
}

// MARK: - Copy buffers

struct CopyBuffersPrefs: View {
    @ObservedObject var m: PrefsModel
    private static let sounds = ["Tink", "Pop", "Glass", "Ping", "Purr", "Morse", "Funk"]

    private var soundOn: Binding<Bool> {
        Binding(get: { !m.s.playSoundOnCopy.isEmpty },
                set: { m.s.playSoundOnCopy = $0 ? (m.s.playSoundOnCopy.isEmpty ? "Tink" : m.s.playSoundOnCopy) : ""; m.changed() })
    }
    private var soundName: Binding<String> {
        Binding(get: { m.s.playSoundOnCopy.isEmpty ? "Tink" : m.s.playSoundOnCopy },
                set: { m.s.playSoundOnCopy = $0; m.changed(); NSSound(named: NSSound.Name($0))?.play() })
    }

    var body: some View {
        Form {
            Section("Copy buffers: global copy / paste / cut shortcuts for five slots") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("Copy").font(.caption.bold()); Text("Paste").font(.caption.bold()); Text("Cut").font(.caption.bold())
                    }
                    ForEach(1...5, id: \.self) { i in
                        GridRow {
                            Text("Buffer \(i)")
                            KeyRecorder(binding: m.hotkey("buffer\(i).copy")).frame(width: 150)
                            KeyRecorder(binding: m.hotkey("buffer\(i).paste")).frame(width: 150)
                            KeyRecorder(binding: m.hotkey("buffer\(i).cut")).frame(width: 150)
                        }
                    }
                }
                if let n = m.notice { Text(n).font(.caption).foregroundStyle(.orange) }
            }
            Section("Feedback") {
                Toggle("Play sound when a copy buffer is filled", isOn: soundOn)
                if soundOn.wrappedValue {
                    Picker("Sound", selection: soundName) { ForEach(Self.sounds, id: \.self) { Text($0).tag($0) } }
                }
            }
            Section {
                Text("Copy buffers need Accessibility permission to send ⌘C / ⌘V to the frontmost app. Your regular clipboard is restored afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Types

struct TypesPrefs: View {
    @ObservedObject var m: PrefsModel
    @LState private var selected: String?
    @LState private var custom = ""
    @LState private var showClipboardTypes = false
    @LState private var clipboardTypes: [String] = []

    private static let presets: [(String, String)] = [
        ("Plain text", "public.utf8-plain-text"), ("Rich text (RTF)", "public.rtf"), ("HTML", "public.html"),
        ("PNG image", "public.png"), ("TIFF image", "public.tiff"), ("File URLs", "public.file-url"), ("PDF", "com.adobe.pdf"),
        ("Web archive (Safari)", "com.apple.webarchive"), ("Rich text with images (RTFD)", "com.apple.flat-rtfd"),
        ("RTFD package", "public.rtfd"), ("JPEG image", "public.jpeg"), ("GIF image", "com.compuserve.gif"),
        ("HEIC image", "public.heic"), ("Link (URL)", "public.url"), ("Link title", "public.url-name"),
    ]

    private var runningApps: [(name: String, bundle: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { (a.localizedName ?? $0, $0) } }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func add(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 200, !m.s.enabledTypes.contains(t) else { return }
        m.s.enabledTypes = m.s.enabledTypes + [t]; m.changed()
    }

    private func append(_ kp: ReferenceWritableKeyPath<DittoCore.Settings, String>, _ bundle: String) {
        let cur = m.s[keyPath: kp].trimmingCharacters(in: .whitespaces)
        let items = cur.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        if items.contains(bundle) { return }
        m.s[keyPath: kp] = (cur.isEmpty || cur == "*" && kp == \DittoCore.Settings.copyAppInclude ? "" : cur + ";") + bundle
        m.changed()
    }

    var body: some View {
        Form {
            Section("Formatting") {
                Toggle("Keep full formatting (headings, styles, images, web archives)", isOn: m.b(\.keepFullFormatting))
                Text("Also saves web archives (a web page’s HTML with its embedded images), rich text with inline images (RTFD), JPEG/GIF/HEIC images, PDF and links — exactly as copied, so pasting into Notes, Pages or Mail brings back the headings, styles and pictures. Each format is limited to 64 MB. Use Paste As › Plain Text (⇧Return) or Markdown (⌥⇧Return) when you don’t want the formatting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clipboard formats to save") {
                Toggle("Support all types (save every format on the clipboard)", isOn: m.b(\.supportAllTypes))
                if m.s.supportAllTypes {
                    Text("Saving all types can use a lot of disk space and may keep data you did not intend to store.").font(.caption).foregroundStyle(.orange)
                }
                List(selection: $selected) {
                    ForEach(m.s.enabledTypes, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).tag($0) }
                }
                .frame(height: 110)
                .disabled(m.s.supportAllTypes)
                HStack {
                    TextField("Add type identifier (e.g. public.json)", text: $custom).onSubmit { add(custom); custom = "" }
                    Button("Add") { add(custom); custom = "" }.disabled(custom.isEmpty)
                    Button("Remove") {
                        if let s = selected { m.s.enabledTypes = m.s.enabledTypes.filter { $0 != s }; selected = nil; m.changed() }
                    }.disabled(selected == nil)
                }
                HStack {
                    Menu("Add preset") { ForEach(Self.presets, id: \.1) { p in Button(p.0) { add(p.1) } } }
                    Button("Add type from current clipboard…") {
                        clipboardTypes = (NSPasteboard.general.types ?? []).map(\.rawValue).filter { !$0.hasPrefix("org.dittomac") }
                        showClipboardTypes = true
                    }
                    .popover(isPresented: $showClipboardTypes) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Types on the clipboard now").font(.headline)
                            if clipboardTypes.isEmpty { Text("The clipboard is empty.").foregroundStyle(.secondary) }
                            ScrollView {
                                VStack(alignment: .leading) {
                                    ForEach(clipboardTypes, id: \.self) { t in
                                        HStack {
                                            Text(t).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            if m.s.enabledTypes.contains(t) { Text("added").foregroundStyle(.secondary) }
                                            else { Button("Add") { add(t) } }
                                        }
                                    }
                                }
                            }.frame(width: 360, height: 180)
                        }.padding(12)
                    }
                    Spacer()
                    Button("Defaults") { m.s.enabledTypes = DittoCore.Settings.defaultEnabledTypes; m.changed() }
                }
            }
            Section("Applications") {
                TextField("Include apps (bundle ID or name; use ; between, * wildcard)", text: m.b(\.copyAppInclude))
                TextField("Exclude apps", text: m.b(\.copyAppExclude))
                HStack {
                    Menu("Add running app to include…") { ForEach(runningApps, id: \.bundle) { a in Button(a.name) { append(\.copyAppInclude, a.bundle) } } }
                    Menu("Add running app to exclude…") { ForEach(runningApps, id: \.bundle) { a in Button(a.name) { append(\.copyAppExclude, a.bundle) } } }
                }
                Text("Example: com.apple.Terminal;*Notes*. An empty include list or * means all apps.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Clips marked by password managers as concealed or transient are never saved. This protection is always on and cannot be disabled.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
