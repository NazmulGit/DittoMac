import AppKit
import SwiftUI
import CryptoKit
import DittoCore

@MainActor
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    let clipID: Int64

    init(state: AppState, clipID: Int64) {
        self.clipID = clipID
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Clip Properties"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 520)
        super.init(window: w)
        w.delegate = self
        let model = PropertiesModel(state: state, clipID: clipID)
        model.close = { [weak w] in w?.close() }
        w.contentViewController = NSHostingController(rootView: PropertiesView(model: model))
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

struct FormatRow: Identifiable, Hashable {
    let id: Int64
    let type: String
    let size: Int
}

@MainActor
final class PropertiesModel: ObservableObject {
    struct GroupOption: Identifiable { let id: Int64; let title: String }

    let state: AppState
    let clipID: Int64
    var close: () -> Void = {}

    @Published var found = true
    @Published var text = ""
    @Published var dateAdded = Date()
    @Published var lastUsed = Date()
    @Published var neverAutoDelete = false
    @Published var shortcut = 0
    @Published var globalShortcut = false
    @Published var moveShortcut = 0
    @Published var globalMove = false
    @Published var parentID: Int64 = -1
    @Published var quickPaste = ""
    @Published var sticky = false
    @Published var isGroup = false
    @Published var formats: [FormatRow] = []
    @Published var selectedFormat: Int64?
    @Published var groups: [GroupOption] = []
    @Published var hashes: (sha: String, md5: String)?
    @Published var error: String?
    private var original: Clip?
    private var formatData: [Int64: Data] = [:]

    init(state: AppState, clipID: Int64) {
        self.state = state
        self.clipID = clipID
        load()
    }

    func load() {
        guard let c = (try? state.store.clip(id: clipID)) ?? nil else { found = false; return }
        original = c
        text = c.text; dateAdded = c.date; lastUsed = c.lastPasteDate
        neverAutoDelete = c.dontAutoDelete
        shortcut = c.shortcut; globalShortcut = c.globalShortcut
        moveShortcut = c.moveToGroupShortcut; globalMove = c.globalMoveToGroupShortcut
        parentID = c.parentID; quickPaste = c.quickPasteText; sticky = c.isSticky; isGroup = c.isGroup
        buildGroups(excluding: c.isGroup ? c.id : nil)
        reloadFormats()
    }

    private func buildGroups(excluding: Int64?) {
        let all = (try? state.store.groups()) ?? []
        var byParent: [Int64: [Clip]] = [:]
        for g in all where g.id != excluding { byParent[g.parentID, default: []].append(g) }
        var out = [GroupOption(id: -1, title: "Top level")]
        var visited = Set<Int64>()
        func walk(_ parent: Int64, _ path: String) {
            for g in (byParent[parent] ?? []) where visited.insert(g.id).inserted {
                let p = path.isEmpty ? g.text : path + " ▸ " + g.text
                out.append(GroupOption(id: g.id, title: p))
                walk(g.id, p)
            }
        }
        walk(-1, "")
        if parentID != -1, !out.contains(where: { $0.id == parentID }) { out.append(GroupOption(id: parentID, title: "(group \(parentID))")) }
        groups = out
    }

    func reloadFormats() {
        let f = (try? state.store.formats(clipID: clipID)) ?? []
        formatData = Dictionary(f.map { ($0.id, $0.data) }, uniquingKeysWith: { a, _ in a })
        formats = f.map { FormatRow(id: $0.id, type: $0.type, size: $0.data.count) }
        if let s = selectedFormat, !formats.contains(where: { $0.id == s }) { selectedFormat = nil }
        updateHashes()
    }

    func updateHashes() {
        guard let s = selectedFormat, let d = formatData[s] else { hashes = nil; return }
        let sha = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        let md5 = Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
        hashes = (sha, md5)
    }

    func deleteSelectedFormat() {
        guard let s = selectedFormat else { return }
        if formats.count <= 1 { error = "A clip must keep at least one format. Delete the clip instead."; return }
        let a = NSAlert()
        a.messageText = "Delete this format?"
        a.informativeText = "The data of the selected format will be permanently removed from this clip."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try state.store.deleteFormat(formatID: s); if let cid = original?.id { ClipThumbnailCache.shared.invalidate(cid) }; selectedFormat = nil; reloadFormats(); state.clipsChanged() }
        catch { self.error = error.localizedDescription }
    }

    /// Names of other things using this combo.
    private func conflicts(for combo: Int, ignoringMove: Bool, ignoringMain: Bool) -> [String] {
        guard combo != 0 else { return [] }
        var out: [String] = []
        for c in (try? state.store.clipsWithShortcuts()) ?? [] where c.id != clipID {
            if c.shortcut == combo { out.append("clip “\(String(c.text.prefix(30)))”") }
            if c.moveToGroupShortcut == combo { out.append("group “\(String(c.text.prefix(30)))” (move to group)") }
        }
        for (k, v) in state.settings.hotkeys where v == combo { out.append("application shortcut “\(k)”") }
        if !ignoringMain, combo == shortcut, combo == moveShortcut { out.append("this clip’s own move-to-group shortcut") }
        return out
    }

    func save() {
        guard var c = original else { return }
        var problems: [String] = []
        let a = conflicts(for: shortcut, ignoringMove: false, ignoringMain: false)
        if !a.isEmpty { problems.append("Shortcut \(KeyCombo(encoded: shortcut).displayString) is already used by " + a.joined(separator: ", ") + ".") }
        if moveShortcut != 0 {
            let b = conflicts(for: moveShortcut, ignoringMove: true, ignoringMain: true)
            if !b.isEmpty { problems.append("Move-to-group shortcut \(KeyCombo(encoded: moveShortcut).displayString) is already used by " + b.joined(separator: ", ") + ".") }
        }
        if !problems.isEmpty {
            let al = NSAlert()
            al.alertStyle = .warning
            al.messageText = "Duplicate shortcut"
            al.informativeText = problems.joined(separator: "\n") + "\n\nSave anyway?"
            al.addButton(withTitle: "Save Anyway"); al.addButton(withTitle: "Cancel")
            guard al.runModal() == .alertFirstButtonReturn else { return }
        }
        c.text = text
        c.dontAutoDelete = neverAutoDelete
        c.shortcut = shortcut; c.globalShortcut = globalShortcut
        c.moveToGroupShortcut = moveShortcut; c.globalMoveToGroupShortcut = globalMove
        c.quickPasteText = quickPaste
        c.parentID = parentID
        do {
            if parentID != original?.parentID, !c.isGroup {
                try state.store.update(c)
                try state.store.move(ids: [c.id], toGroup: parentID)
            } else {
                try state.store.update(c)
            }
        } catch { self.error = error.localizedDescription; return }
        NotificationCenter.default.post(name: .dittoHotkeysChanged, object: nil)
        state.clipsChanged()
        close()
    }
}

struct PropertiesView: View {
    @ObservedObject var model: PropertiesModel
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .medium; return d }()

    var body: some View {
        if !model.found {
            VStack { Text("This clip no longer exists.").padding(); Button("Close") { model.close() } }.frame(minWidth: 400, minHeight: 120)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox("Description") {
                            TextEditor(text: $model.text)
                                .font(.body).frame(height: 70)
                                .accessibilityLabel("Description")
                        }
                        HStack(spacing: 24) {
                            LabeledContent("Date added") { Text(Self.df.string(from: model.dateAdded)) }
                            LabeledContent("Last used") { Text(Self.df.string(from: model.lastUsed)) }
                        }
                        HStack {
                            Toggle("Never auto delete", isOn: $model.neverAutoDelete)
                            Spacer()
                            Text(model.sticky ? "Sticky: yes" : "Sticky: no").foregroundStyle(.secondary)
                        }
                        GroupBox("Shortcuts") {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                GridRow {
                                    Text("Hot key")
                                    KeyRecorder(binding: $model.shortcut).frame(width: 170)
                                    Toggle("Global", isOn: $model.globalShortcut)
                                }
                                if model.isGroup {
                                    GridRow {
                                        Text("Move to group hot key")
                                        KeyRecorder(binding: $model.moveShortcut).frame(width: 170)
                                        Toggle("Global", isOn: $model.globalMove)
                                    }
                                }
                            }.padding(6)
                        }
                        HStack {
                            Picker("Group", selection: $model.parentID) {
                                ForEach(model.groups) { Text($0.title).tag($0.id) }
                            }
                        }
                        HStack {
                            Text("Quick paste text")
                            TextField("", text: $model.quickPaste)
                        }
                        GroupBox("Formats") {
                            VStack(alignment: .leading, spacing: 6) {
                                Table(model.formats, selection: $model.selectedFormat) {
                                    TableColumn("Type", value: \.type)
                                    TableColumn("Size") { Text(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)) }.width(90)
                                }
                                .frame(height: 130)
                                .onChange(of: model.selectedFormat) { _ in model.updateHashes() }
                                HStack {
                                    Button("Delete Format") { model.deleteSelectedFormat() }.disabled(model.selectedFormat == nil)
                                    Spacer()
                                }
                                if let h = model.hashes {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("SHA-256: \(h.sha)")
                                        Text("MD5 (legacy): \(h.md5)")
                                    }
                                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                                }
                            }.padding(6)
                        }
                        if let e = model.error { Text(e).foregroundStyle(.red) }
                    }.padding(16)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                    Button("Save") { model.save() }.keyboardShortcut(.defaultAction)
                }.padding(12)
            }
        }
    }
}
