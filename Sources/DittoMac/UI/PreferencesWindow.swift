import AppKit
import SwiftUI
import DittoCore

/// Local view state. SwiftUI's `@State` is a macro in newer SDKs whose plugin is absent with Command Line Tools only,
/// so this wrapper provides the same behaviour on top of `@StateObject`.
final class LStateBox<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

@propertyWrapper
struct LState<T>: DynamicProperty {
    @StateObject private var box: LStateBox<T>
    init(wrappedValue: T) { _box = StateObject(wrappedValue: LStateBox(wrappedValue)) }
    var wrappedValue: T { get { box.value } nonmutating set { box.value = newValue } }
    var projectedValue: Binding<T> { Binding(get: { box.value }, set: { box.value = $0 }) }
}

// MARK: - Window controller

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let model: PrefsModel

    init(state: AppState) {
        model = PrefsModel(state: state)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "DittoMac Preferences"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 620, height: 520)
        super.init(window: w)
        w.delegate = self
        w.contentViewController = NSHostingController(rootView: PreferencesRoot(model: model))
        w.setContentSize(NSSize(width: 640, height: 540))
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: PreferencesTab) { model.tab = tab }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

// MARK: - Model

@MainActor
final class PrefsModel: ObservableObject {
    let state: AppState
    @Published var tab: PreferencesTab = .general
    @Published var notice: String?

    var s: DittoCore.Settings { state.settings }

    init(state: AppState) { self.state = state }

    /// Called after any setting write.
    func changed() {
        objectWillChange.send()
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    func hotkeysChanged() {
        objectWillChange.send()
        NotificationCenter.default.post(name: .dittoHotkeysChanged, object: nil)
    }

    /// Two-way binding onto a Settings property; writes post `.dittoSettingsChanged`.
    func b<T>(_ kp: ReferenceWritableKeyPath<DittoCore.Settings, T>) -> Binding<T> {
        Binding(get: { self.s[keyPath: kp] },
                set: { self.s[keyPath: kp] = $0; self.changed() })
    }

    /// Binding onto a named hotkey (encoded KeyCombo); writes post `.dittoHotkeysChanged`.
    func hotkey(_ name: String) -> Binding<Int> {
        Binding(get: { self.s.hotkey(name) },
                set: { v in
                    if v != 0, let clash = self.s.hotkeys.first(where: { $0.key != name && $0.value == v })?.key {
                        self.notice = "\(KeyCombo(encoded: v).displayString) is also assigned to “\(Self.title(forHotkey: clash))”."
                    } else { self.notice = nil }
                    self.s.setHotkey(name, v)
                    self.hotkeysChanged()
                })
    }

    static func title(forHotkey name: String) -> String {
        switch name {
        case "activate": return "Activate DittoMac"
        case "activate2": return "Activate DittoMac (alternate 2)"
        case "activate3": return "Activate DittoMac (alternate 3)"
        case "textOnlyPaste": return "Text-only paste"
        case "saveClipboard": return "Save current clipboard"
        case "copyAndSave": return "Copy & save current clipboard"
        default:
            if name.hasPrefix("lastTen") { return "Paste last-ten position \(name.dropFirst(7))" }
            if name.hasPrefix("buffer") { return "Copy buffer " + name.dropFirst(6).replacingOccurrences(of: ".", with: " ") }
            return name
        }
    }

    // Shared alert helper
    func confirm(_ title: String, _ info: String, button: String, destructive: Bool = true) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = destructive
        return a.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Root

struct PreferencesRoot: View {
    @ObservedObject var model: PrefsModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralPrefs(m: model).tabItem { Label("General", systemImage: "gearshape") }.tag(PreferencesTab.general)
            QuickPastePrefs(m: model).tabItem { Label("Quick Paste", systemImage: "doc.on.clipboard") }.tag(PreferencesTab.quickPaste)
            KeyboardPrefs(m: model).tabItem { Label("Keyboard", systemImage: "keyboard") }.tag(PreferencesTab.keyboard)
            CopyBuffersPrefs(m: model).tabItem { Label("Copy Buffers", systemImage: "square.stack") }.tag(PreferencesTab.copyBuffers)
            TypesPrefs(m: model).tabItem { Label("Types", systemImage: "list.bullet.rectangle") }.tag(PreferencesTab.types)
            FriendsPrefs(m: model).tabItem { Label("Friends", systemImage: "person.2") }.tag(PreferencesTab.friends)
            RulesPrefs(m: model).tabItem { Label("Rules", systemImage: "slider.horizontal.3") }.tag(PreferencesTab.rules)
            StatsPrefs(m: model).tabItem { Label("Stats", systemImage: "chart.bar") }.tag(PreferencesTab.stats)
            AdvancedPrefs(m: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(PreferencesTab.advanced)
        }
        .padding(12)
        .frame(minWidth: 620, minHeight: 520)
    }
}

// MARK: - General

struct GeneralPrefs: View {
    @ObservedObject var m: PrefsModel
    @LState private var loginError: String?
    @LState private var dbMessage: String?
    @LState private var busy = false

    private var loginBinding: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled },
                set: { v in
                    do { try LoginItem.setEnabled(v); loginError = nil } catch { loginError = error.localizedDescription }
                    m.s.launchAtLogin = LoginItem.isEnabled
                    m.changed()
                })
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(get: { m.s.showMenuBarIcon },
                set: { v in
                    m.s.showMenuBarIcon = v
                    if !v && !m.s.showDockIcon { m.s.showDockIcon = true }   // keep the app reachable
                    m.changed()
                })
    }
    private var dockBinding: Binding<Bool> {
        Binding(get: { m.s.showDockIcon },
                set: { v in
                    m.s.showDockIcon = v
                    if !v && !m.s.showMenuBarIcon { m.s.showMenuBarIcon = true }
                    m.changed()
                })
    }
    private var connectedBinding: Binding<Bool> {
        Binding(get: { m.state.monitor?.isConnected ?? m.s.connectedToClipboard },
                set: { v in
                    m.state.monitor?.isConnected = v
                    m.s.connectedToClipboard = v
                    NotificationCenter.default.post(name: .dittoConnectionChanged, object: nil)
                    m.changed()
                })
    }

    private var themes: [String] {
        var n = ThemeData.all.map(\.name)
        if !n.contains("System") { n.insert("System", at: 0) }
        return n
    }
    private static let families: [String] = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch DittoMac at login", isOn: loginBinding)
                if LoginItem.requiresApproval {
                    HStack {
                        Text(LoginItem.statusText).font(.caption).foregroundStyle(.orange)
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                    }
                }
                if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
                Toggle("Show menu bar icon", isOn: menuBarBinding)
                Toggle("Show Dock icon", isOn: dockBinding)
                Toggle("Show startup message", isOn: m.b(\.showStartupMessage))
                Toggle("Connected to clipboard (capture copies)", isOn: connectedBinding)
            }
            Section("Appearance") {
                Picker("Theme", selection: m.b(\.themeName)) {
                    ForEach(themes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Font", selection: m.b(\.fontName)) {
                    Text("System default").tag("")
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                    if !m.s.fontName.isEmpty && !Self.families.contains(m.s.fontName) { Text(m.s.fontName).tag(m.s.fontName) }
                }
                Stepper(value: m.b(\.fontSize), in: 6...72, step: 1) {
                    Text("Font size: \(Int(m.s.fontSize)) pt")
                }
            }
            Section("Updates") {
                Link("Check for updates (opens GitHub Releases)", destination: URL(string: "https://github.com/NazmulGit/DittoMac/releases")!)
            }
            Section("Database") {
                LabeledContent("Location") {
                    Text(m.state.store.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.state.store.path)])
                    }
                    Button("Backup…") { backup() }
                    Button("Restore…") { restore() }
                    Button("Compact") { compact() }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let d = dbMessage { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func backup() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "DittoMac-backup-\(Self.stamp()).\(ImportExport.fileExtension)"
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try m.state.store.backup(to: url); dbMessage = "Backup saved to \(url.lastPathComponent)." }
        catch { dbMessage = "Backup failed: \(error.localizedDescription)" }
    }

    private func restore() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.message = "Choose a DittoMac backup or export. Its clips are merged into your current history."
        guard p.runModal() == .OK, let url = p.url else { return }
        guard m.confirm("Restore from “\(url.lastPathComponent)”?", "Clips from the file are added to your history; existing clips are kept.", button: "Restore", destructive: false) else { return }
        do {
            let r = try ImportExport.importClips(from: url, into: m.state.store)
            m.state.clipsChanged()
            dbMessage = "Restored \(r.clipsImported) clip(s), \(r.groupsCreated) group(s); \(r.duplicates) duplicate(s), \(r.skipped) skipped."
        } catch { dbMessage = "Restore failed: \(error.localizedDescription)" }
    }

    private func compact() {
        busy = true
        let store = m.state.store
        Task.detached {
            let err: String? = { do { try store.vacuum(); return nil } catch { return error.localizedDescription } }()
            await MainActor.run { busy = false; dbMessage = err.map { "Compact failed: \($0)" } ?? "Database compacted." }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date())
    }
}

// MARK: - Quick Paste

struct URLTemplateField: View {
    let title: String
    let m: PrefsModel
    let kp: ReferenceWritableKeyPath<DittoCore.Settings, String>
    @LState private var text = ""
    @LState private var error: String?

    static func validate(_ t: String) -> String? {
        guard t.contains("%s") else { return "Template must contain %s where the text goes." }
        guard let u = URL(string: t.replacingOccurrences(of: "%s", with: "x")), u.scheme?.lowercased() == "https", u.host?.isEmpty == false
        else { return "Template must be a valid https:// URL." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: $text, onCommit: commit)
                .onAppear { text = m.s[keyPath: kp] }
                .onChange(of: text) { v in
                    error = Self.validate(v)
                    if error == nil { m.s[keyPath: kp] = v; m.changed() }
                }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }
    private func commit() { error = Self.validate(text) }
}

struct QuickPastePrefs: View {
    @ObservedObject var m: PrefsModel

    private var runningApps: [(name: String, bundle: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { (a.localizedName ?? $0, $0) } }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func addPlainTextApp(_ bundle: String) {
        let cur = m.s.plainTextApps.trimmingCharacters(in: .whitespaces)
        let items = cur.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !items.contains(bundle) else { return }
        m.s.plainTextApps = cur.isEmpty ? bundle : cur + ";" + bundle
        m.changed()
    }

    var body: some View {
        Form {
            Section("Window") {
                Picker("Popup position", selection: m.b(\.popupPosition)) {
                    Text("At text caret").tag(PopupPosition.caret)
                    Text("At mouse cursor").tag(PopupPosition.cursor)
                    Text("At previous position").tag(PopupPosition.previous)
                }
                Stepper("Lines per row: \(m.s.linesPerRow)", value: m.b(\.linesPerRow), in: 1...5)
                HStack {
                    Text("Transparency: \(m.s.transparencyPercent)%")
                    Slider(value: Binding(get: { Double(m.s.transparencyPercent) }, set: { m.s.transparencyPercent = Int($0.rounded()); m.changed() }), in: 0...40, step: 1)
                }
                Toggle("Always on top", isOn: m.b(\.alwaysOnTop))
            }
            Section("Search") {
                Toggle("Find as you type", isOn: m.b(\.findAsYouType))
                Toggle("Search descriptions", isOn: m.b(\.searchDescription))
                Toggle("Search full text", isOn: m.b(\.searchFullText))
                Toggle("Search quick paste text", isOn: m.b(\.searchQuickPaste))
                Picker("Search mode", selection: m.b(\.searchMode)) {
                    Text("Wildcard (* ?)").tag(SearchMode.wildcard)
                    Text("Contains").tag(SearchMode.contains)
                    Text("Regular expression").tag(SearchMode.regex)
                }
                Toggle("Regex is case-insensitive", isOn: m.b(\.regexCaseInsensitive)).disabled(m.s.searchMode != .regex)
                Toggle("Maintain search view after pasting", isOn: m.b(\.maintainSearchView))
            }
            Section("List & groups") {
                Toggle("Show all clips in main list (including those in groups)", isOn: m.b(\.showAllClipsInMainList))
                Toggle("Show groups in main list", isOn: m.b(\.showGroupsInMainList))
                Toggle("Revert to top-level group when closed", isOn: m.b(\.revertToTopLevelGroup))
                Toggle("Open to group by active application", isOn: m.b(\.openToGroupByActiveApp))
                Toggle("Draw thumbnails", isOn: m.b(\.drawThumbnails))
                Toggle("Draw rich text", isOn: m.b(\.drawRTF))
                Toggle("Colour-code swatch for copied colours", isOn: m.b(\.drawCopiedColorCode))
                Toggle("Show first-ten index", isOn: m.b(\.showFirstTenIndex))
                Stepper("First-ten starts at \(m.s.firstTenHotKeysStart)", value: m.b(\.firstTenHotKeysStart), in: 0...9)
                Toggle("Show pasted indicator", isOn: m.b(\.showIfClipWasPasted))
                Toggle("Prompt when deleting clips", isOn: m.b(\.promptWhenDeletingClips))
                Toggle("Prompt for new group name", isOn: m.b(\.promptForNewGroupName))
            }
            Section("Paste format") {
                Picker("Default paste format", selection: m.b(\.defaultPasteFormat)) {
                    ForEach(PasteFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Used by Return, double-click, ⌘1…⌘0 and the global paste hotkeys. ⇧Return always pastes plain text, ⌥⇧Return Markdown; right-click › Paste As offers every format.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Always paste plain text into these apps", text: m.b(\.plainTextApps))
                HStack {
                    Menu("Add running app…") {
                        ForEach(runningApps, id: \.bundle) { a in Button(a.name) { addPlainTextApp(a.bundle) } }
                    }
                    .fixedSize()
                    Spacer()
                }
                Text("Bundle IDs or app names separated by ; (wildcards * and ?), e.g. com.apple.Terminal;*Code*.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pasting") {
                Toggle("Update order on paste (move pasted clip to top)", isOn: m.b(\.updateTimeOnPaste))
                Toggle("Send paste after selection", isOn: m.b(\.sendPasteAfterSelection))
                Toggle("Move selection on repeated hotkey", isOn: m.b(\.moveSelectionOnOpenHotkey))
                Toggle("Hide on hotkey if already shown", isOn: m.b(\.hideOnHotKeyIfAlreadyShown))
                TextField("Multi-paste separator ([LF] = newline, [TAB] = tab)", text: m.b(\.multiPasteSeparator))
                Toggle("Reverse order when multi-pasting", isOn: m.b(\.multiPasteReverse))
                Toggle("Save the multi-pasted result as a new clip", isOn: m.b(\.saveMultiPaste))
                TextField("Slugify separator", text: m.b(\.slugifySeparator))
            }
            Section("Tools") {
                URLTemplateField(title: "Web search URL", m: m, kp: \.webSearchURL)
                URLTemplateField(title: "Translate URL", m: m, kp: \.translateURL)
                Text("Use %s where the clip text is inserted. Only https:// URLs are allowed.").font(.caption).foregroundStyle(.secondary)
                Stepper("QR code border: \(m.s.qrBorderPixels) px", value: m.b(\.qrBorderPixels), in: 0...500, step: 5)
            }
        }
        .formStyle(.grouped)
    }
}
