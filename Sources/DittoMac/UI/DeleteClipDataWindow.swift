import AppKit
import SwiftUI
import DittoCore

@MainActor
final class DeleteClipDataWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    init(state: AppState) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Delete Clip Data"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 480)
        super.init(window: w)
        w.delegate = self
        w.contentViewController = NSHostingController(rootView: DeleteClipDataView(model: DeleteClipDataModel(state: state)))
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

struct DataRow: Identifiable, Hashable {
    let id: Int64
    let text: String
    let created: Date
    let used: Date
    let bytes: Int
}

@MainActor
final class DeleteClipDataModel: ObservableObject {
    let state: AppState
    @Published var title = ""
    @Published var useCreatedFrom = false
    @Published var useCreatedTo = false
    @Published var useUsedFrom = false
    @Published var useUsedTo = false
    @Published var createdFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var createdTo = Date()
    @Published var usedFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var usedTo = Date()
    @Published var formatType = ""          // "" = any
    @Published var types: [String] = []
    @Published var rows: [DataRow] = []
    @Published var selection = Set<Int64>()
    @Published var message: String?
    @Published var busy = false

    init(state: AppState) {
        self.state = state
        types = Array(Set(DittoCore.Settings.defaultEnabledTypes + [ClipUTI.tiff])).sorted()
        search()
        discoverTypes()
    }

    private func discoverTypes() {
        let store = state.store
        Task.detached {
            var found = Set<String>()
            if let all = try? store.clipsMatching(dataFilter: ClipDataFilter()) {
                for r in all.prefix(3000) { for t in (try? store.formatTypes(clipID: r.clip.id)) ?? [] { found.insert(t.type) } }
            }
            let result = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.types = Array(Set(self.types).union(result)).sorted()
            }
        }
    }

    func search() {
        var f = ClipDataFilter()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        f.titleContains = t.isEmpty ? nil : t
        let cal = Calendar.current
        if useCreatedFrom { f.createdFrom = cal.startOfDay(for: createdFrom) }
        if useCreatedTo { f.createdTo = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: createdTo)) }
        if useUsedFrom { f.usedFrom = cal.startOfDay(for: usedFrom) }
        if useUsedTo { f.usedTo = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: usedTo)) }
        f.formatType = formatType.isEmpty ? nil : formatType
        do {
            rows = try state.store.clipsMatching(dataFilter: f).map {
                DataRow(id: $0.clip.id, text: String($0.clip.text.prefix(120)).replacingOccurrences(of: "\n", with: " "),
                        created: $0.clip.date, used: $0.clip.lastPasteDate, bytes: $0.bytes)
            }
            selection = selection.intersection(Set(rows.map(\.id)))
            message = nil
        } catch { message = error.localizedDescription }
    }

    var totalBytes: Int { rows.reduce(0) { $0 + $1.bytes } }
    var selectedRows: [DataRow] { rows.filter { selection.contains($0.id) } }
    var selectedBytes: Int { selectedRows.reduce(0) { $0 + $1.bytes } }

    private func confirm(_ title: String, _ info: String, button: String) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title; a.informativeText = info
        a.addButton(withTitle: button); a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        return a.runModal() == .alertFirstButtonReturn
    }

    func deleteClips() {
        let ids = Array(selection)
        guard !ids.isEmpty,
              confirm("Delete \(ids.count) clip(s)?", "The selected clips and all of their data will be permanently deleted. This cannot be undone.", button: "Delete") else { return }
        do { try state.store.deleteData(clipIDs: ids, types: nil); ClipThumbnailCache.shared.invalidate(); state.clipsChanged(); NotificationCenter.default.post(name: .dittoHotkeysChanged, object: nil); message = "Deleted \(ids.count) clip(s)."; search() }
        catch { message = error.localizedDescription }
    }

    func deleteFormatOnly() {
        let ids = Array(selection)
        guard !ids.isEmpty, !formatType.isEmpty,
              confirm("Delete \(formatType) data?", "Only the \(formatType) format will be removed from \(ids.count) clip(s). This cannot be undone.", button: "Delete Format") else { return }
        do { try state.store.deleteData(clipIDs: ids, types: [formatType]); ClipThumbnailCache.shared.invalidate(); state.clipsChanged(); NotificationCenter.default.post(name: .dittoHotkeysChanged, object: nil); message = "Deleted \(formatType) data from \(ids.count) clip(s)."; search() }
        catch { message = error.localizedDescription }
    }

    func compact() {
        busy = true
        let store = state.store
        Task.detached {
            let err: String? = { do { try store.vacuum(); return nil } catch { return error.localizedDescription } }()
            await MainActor.run { [weak self] in
                self?.busy = false
                self?.message = err ?? "Database compacted."
            }
        }
    }
}

struct DeleteClipDataView: View {
    @ObservedObject var model: DeleteClipDataModel
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .short; d.timeStyle = .short; return d }()
    private func size(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Filters") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Title contains")
                        TextField("", text: $model.title).gridCellColumns(3).onSubmit { model.search() }
                    }
                    GridRow {
                        Toggle("Created from", isOn: $model.useCreatedFrom)
                        DatePicker("", selection: $model.createdFrom, displayedComponents: .date).labelsHidden().disabled(!model.useCreatedFrom)
                        Toggle("to", isOn: $model.useCreatedTo)
                        DatePicker("", selection: $model.createdTo, displayedComponents: .date).labelsHidden().disabled(!model.useCreatedTo)
                    }
                    GridRow {
                        Toggle("Last used from", isOn: $model.useUsedFrom)
                        DatePicker("", selection: $model.usedFrom, displayedComponents: .date).labelsHidden().disabled(!model.useUsedFrom)
                        Toggle("to", isOn: $model.useUsedTo)
                        DatePicker("", selection: $model.usedTo, displayedComponents: .date).labelsHidden().disabled(!model.useUsedTo)
                    }
                    GridRow {
                        Text("Format type")
                        Picker("", selection: $model.formatType) {
                            Text("Any").tag("")
                            ForEach(model.types, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().gridCellColumns(2)
                        Button("Search") { model.search() }.keyboardShortcut(.defaultAction)
                    }
                }.padding(6)
            }
            Table(model.rows, selection: $model.selection) {
                TableColumn("Description", value: \.text)
                TableColumn("Created") { Text(Self.df.string(from: $0.created)) }.width(130)
                TableColumn("Last used") { Text(Self.df.string(from: $0.used)) }.width(130)
                TableColumn("Size") { Text(size($0.bytes)) }.width(80)
            }
            HStack {
                Text("\(model.rows.count) clip(s), \(size(model.totalBytes)) — selected: \(model.selection.count), \(size(model.selectedBytes))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select All") { model.selection = Set(model.rows.map(\.id)) }.disabled(model.rows.isEmpty)
            }
            if let m = model.message { Text(m).foregroundStyle(.secondary) }
            HStack {
                Button("Compact Database") { model.compact() }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Delete Selected Format Only") { model.deleteFormatOnly() }
                    .disabled(model.selection.isEmpty || model.formatType.isEmpty)
                    .help(model.formatType.isEmpty ? "Choose a format type first" : "Remove only this format from the selected clips")
                Button("Delete Selected") { model.deleteClips() }.disabled(model.selection.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
    }
}
