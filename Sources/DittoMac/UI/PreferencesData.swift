import AppKit
import SwiftUI
import DittoCore

// MARK: - Friends

struct FriendsPrefs: View {
    @ObservedObject var m: PrefsModel
    @LState private var passphrase = ""
    @LState private var passMessage: String?
    @LState private var passIsError = false

    static func strength(_ p: String) -> (text: String, ok: Bool) {
        if p.count < 12 { return ("\(p.count)/12 characters minimum", false) }
        var classes = 0
        if p.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if p.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if p.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if p.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }
        if p.count >= 20 || classes >= 3 { return ("Strong", true) }
        return ("Acceptable — longer or mixed characters are better", true)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { m.s.friendsEnabled },
                set: { v in
                    if v && !(m.state.friends?.hasPassphrase ?? false) {
                        passMessage = "Set a passphrase below before enabling Friends."; passIsError = true
                    }
                    m.s.friendsEnabled = v; m.changed()
                    m.state.friends?.applySettings()
                })
    }

    var body: some View {
        Form {
            Section("Sharing") {
                Toggle("Enable Friends (send clips to other devices on your network)", isOn: enabledBinding)
                TextField("Device name", text: m.b(\.friendsDeviceName))
                LabeledContent("Listen port") { TextField("", value: m.b(\.friendsPort), format: .number.grouping(.never)).frame(width: 80) }
                Toggle("Automatically put received clips on the clipboard", isOn: m.b(\.friendsAutoPutOnClipboard))
                LabeledContent("Status") { Text(m.state.friends?.statusText ?? "Not running").foregroundStyle(.secondary) }
            }
            Section("Shared passphrase") {
                HStack {
                    SecureField("Passphrase (at least 12 characters)", text: $passphrase)
                    Button("Save") { savePassphrase() }.disabled(passphrase.isEmpty)
                }
                if !passphrase.isEmpty { let s = Self.strength(passphrase); Text(s.text).font(.caption).foregroundStyle(s.ok ? Color.secondary : Color.orange) }
                Text(m.state.friends?.hasPassphrase == true ? "A passphrase is stored in your Keychain." : "No passphrase is stored yet.")
                    .font(.caption).foregroundStyle(.secondary)
                if let msg = passMessage { Text(msg).font(.caption).foregroundStyle(passIsError ? .red : .green) }
                Text("All devices must use the same passphrase.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Friends") {
                if m.s.friendsPeers.isEmpty { Text("No friends added.").foregroundStyle(.secondary) }
                ForEach(m.b(\.friendsPeers)) { $peer in
                    HStack {
                        TextField("Name", text: $peer.name).frame(minWidth: 80)
                        TextField("Host or IP", text: $peer.host).frame(minWidth: 100)
                        TextField("Port", value: $peer.port, format: .number.grouping(.never)).frame(width: 60)
                        Toggle("Send all copies", isOn: $peer.sendAllCopies).toggleStyle(.checkbox)
                        Button { remove(peer.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove")
                    }
                }
                Button("Add Friend") {
                    var p = m.s.friendsPeers
                    p.append(FriendPeer(name: "New friend", host: "", port: m.s.friendsPort))
                    m.s.friendsPeers = p; m.changed()
                }
            }
            Section {
                Label("Traffic is end-to-end encrypted with your passphrase and stays on your local network. Friends is off by default; DittoMac never connects to the internet for this feature.",
                      systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in m.objectWillChange.send() }   // refresh status text
        .formStyle(.grouped)
    }

    private func remove(_ id: UUID) {
        m.s.friendsPeers = m.s.friendsPeers.filter { $0.id != id }; m.changed()
    }

    private func savePassphrase() {
        let s = Self.strength(passphrase)
        guard s.ok else { passMessage = "Passphrase must be at least 12 characters."; passIsError = true; return }
        guard let f = m.state.friends else { passMessage = "Friends service is not available."; passIsError = true; return }
        do {
            try f.setPassphrase(passphrase)
            passphrase = ""; passMessage = "Passphrase saved."; passIsError = false
            m.changed()
            f.applySettings()
        } catch { passMessage = "Could not save passphrase: \(error.localizedDescription)"; passIsError = true }
    }
}

// MARK: - Rules

struct RulesPrefs: View {
    @ObservedObject var m: PrefsModel
    @LState private var selection: UUID?
    @LState private var sample = ""
    @LState private var sampleApp = "com.example.App"
    @LState private var testResult = ""

    private var rules: Binding<[CopyRule]> { m.b(\.copyRules) }
    private var selectedIndex: Int? { m.s.copyRules.firstIndex { $0.id == selection } }

    private func regexError(_ r: String) -> String? {
        guard !r.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: r); return nil } catch { return "Invalid regular expression" }
    }

    private func title(for a: CopyRule.Action) -> String {
        switch a {
        case .ignore: return "Ignore (don’t save)"
        case .makeTopSticky: return "Make top sticky"
        case .makeLastSticky: return "Make last sticky"
        case .replaceTopSticky: return "Replace top sticky"
        case .neverAutoDelete: return "Never auto delete"
        case .stripToPlainText: return "Strip to plain text"
        case .replaceRegex: return "Replace text (regex)"
        case .moveToGroup: return "Move to group"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rules run on every copy, in order, before a clip is saved. They replace the upstream regex filters and scripts.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                VStack {
                    List(selection: $selection) {
                        ForEach(rules) { $r in
                            HStack {
                                Toggle("", isOn: $r.enabled).labelsHidden().toggleStyle(.checkbox)
                                Text(r.name.isEmpty ? "(unnamed rule)" : r.name).lineLimit(1)
                            }.tag(r.id)
                        }
                        .onMove { idx, to in var r = m.s.copyRules; r.move(fromOffsets: idx, toOffset: to); m.s.copyRules = r; m.changed() }
                    }
                    HStack {
                        Button { addRule() } label: { Image(systemName: "plus") }
                        Button { removeRule() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                        Spacer()
                    }
                }.frame(width: 190)
                if let i = selectedIndex {
                    editor(index: i)
                } else {
                    Text("Select or add a rule.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder private func editor(index i: Int) -> some View {
        let id = m.s.copyRules[i].id
        let r = Binding<CopyRule>(
            get: { m.s.copyRules.first { $0.id == id } ?? CopyRule() },
            set: { v in var all = m.s.copyRules; if let k = all.firstIndex(where: { $0.id == id }) { all[k] = v; m.s.copyRules = all; m.changed() } })
        Form {
            TextField("Name", text: r.name)
            Toggle("Enabled", isOn: r.enabled)
            TextField("Application (bundle ID or name; ; separated, * wildcard)", text: r.appPattern)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Text regex (empty = any text)", text: r.textRegex)
                if let e = regexError(r.wrappedValue.textRegex) { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Picker("Action", selection: r.action) {
                ForEach(CopyRule.Action.allCases, id: \.self) { Text(title(for: $0)).tag($0) }
            }
            if r.wrappedValue.action == .replaceRegex {
                TextField("Replacement (use $1, $2…)", text: r.replacement)
            }
            if r.wrappedValue.action == .moveToGroup {
                TextField("Group name", text: r.groupName)
            }
            Section("Test") {
                TextField("Sample text", text: $sample, axis: .vertical).lineLimit(2...4)
                TextField("From application (bundle ID)", text: $sampleApp)
                HStack {
                    Button("Run Test") { runTest(r.wrappedValue) }
                    Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addRule() {
        var all = m.s.copyRules
        let r = CopyRule(name: "New rule")
        all.append(r)
        m.s.copyRules = all; m.changed(); selection = r.id
    }
    private func removeRule() {
        guard let s = selection else { return }
        m.s.copyRules = m.s.copyRules.filter { $0.id != s }; selection = nil; m.changed()
    }

    private func runTest(_ rule: CopyRule) {
        var r = rule; r.enabled = true
        let o = CopyRuleEngine.evaluate(rules: [r], text: sample, appBundleID: sampleApp, appName: sampleApp)
        var parts: [String] = []
        if o.ignore { parts.append("Clip would be ignored.") }
        if let t = o.text, t != sample { parts.append("Text becomes: “\(t.prefix(200))”") }
        if o.stripToPlain { parts.append("Stripped to plain text.") }
        if o.makeTopSticky { parts.append("Made top sticky.") }
        if o.makeLastSticky { parts.append("Made last sticky.") }
        if o.replaceTopSticky { parts.append("Replaced top sticky.") }
        if o.neverAutoDelete { parts.append("Never auto delete.") }
        if let g = o.groupName { parts.append("Moved to group “\(g)”.") }
        testResult = parts.isEmpty ? "Rule does not match (no effect)." : parts.joined(separator: " ")
    }
}

// MARK: - Stats

struct StatsPrefs: View {
    @ObservedObject var m: PrefsModel
    @LState private var stats = StoreStats()
    @LState private var message: String?
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .short; return d }()

    var body: some View {
        Form {
            Section("Usage") {
                LabeledContent("Copies (total since \(Self.df.string(from: m.s.totalStartDate)))") { Text("\(m.s.copyCountTotal)") }
                LabeledContent("Pastes (total)") { Text("\(m.s.pasteCountTotal)") }
                LabeledContent("Copies (trip since \(Self.df.string(from: m.s.tripStartDate)))") { Text("\(m.s.copyCountTrip)") }
                LabeledContent("Pastes (trip)") { Text("\(m.s.pasteCountTrip)") }
                Button("Reset Trip") { m.s.resetTrip(); m.objectWillChange.send() }
            }
            Section("Database") {
                LabeledContent("Clips") { Text("\(stats.clips)") }
                LabeledContent("Groups") { Text("\(stats.groups)") }
                LabeledContent("Stored formats") { Text("\(stats.formats)") }
                LabeledContent("Database size") { Text(ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file)) }
                HStack {
                    Button("Refresh") { load() }
                    Button("Delete All Clips…", role: .destructive) { deleteAll() }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
    }

    private func load() { stats = (try? m.state.store.stats()) ?? StoreStats() }

    private func deleteAll() {
        guard m.confirm("Delete ALL clips?", "Every clip and group (\(stats.clips) clips, \(stats.groups) groups) will be permanently deleted. This cannot be undone.", button: "Delete All") else { return }
        do { try m.state.store.deleteAll(); m.state.clipsChanged(); message = "All clips deleted." } catch { message = error.localizedDescription }
        load()
    }
}

// MARK: - Advanced

struct AdvancedPrefs: View {
    @ObservedObject var m: PrefsModel
    @LState private var message: String?

    private var maxClipKB: Binding<Int> {
        Binding(get: { m.s.maxClipSizeBytes / 1024 }, set: { m.s.maxClipSizeBytes = max(0, $0) * 1024; m.changed() })
    }

    var body: some View {
        Form {
            Section("Retention") {
                HStack {
                    Toggle("Keep at most", isOn: m.b(\.checkForMaxEntries))
                    TextField("", value: m.b(\.maxEntries), format: .number.grouping(.never)).frame(width: 80).disabled(!m.s.checkForMaxEntries)
                    Text("clips")
                }
                HStack {
                    Toggle("Delete clips not used for", isOn: m.b(\.checkForExpiredEntries))
                    TextField("", value: m.b(\.expiredEntries), format: .number.grouping(.never)).frame(width: 70).disabled(!m.s.checkForExpiredEntries)
                    Text("days")
                }
                Text("Clips marked Never Auto Delete, sticky clips and groups are kept.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Capture") {
                Toggle("Allow duplicate clips", isOn: m.b(\.allowDuplicates))
                Toggle("Allow back-to-back duplicates", isOn: m.b(\.allowBackToBackDuplicates))
                LabeledContent("Description length (characters)") { TextField("", value: m.b(\.descTextSize), format: .number.grouping(.never)).frame(width: 80) }
                LabeledContent("Max clip size (KB, 0 = unlimited)") { TextField("", value: maxClipKB, format: .number.grouping(.never)).frame(width: 90) }
                LabeledContent("Save clip delay (ms)") { TextField("", value: m.b(\.saveClipDelayMS), format: .number.grouping(.never)).frame(width: 80) }
            }
            Section("Maintenance") {
                HStack {
                    Button("Delete all non-used clips…") { deleteNonUsed() }
                    Button("Delete clip data…") { m.state.windows?.showDeleteClipData() }
                }
                Button("Reset all settings…", role: .destructive) { resetAll() }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func deleteNonUsed() {
        guard m.confirm("Delete all non-used clips?", "Clips that have never been pasted will be permanently deleted (sticky, group and Never Auto Delete clips are kept).", button: "Delete") else { return }
        do { let n = try m.state.store.deleteNonUsedClips(); m.state.clipsChanged(); message = "Deleted \(n) clip(s)." } catch { message = error.localizedDescription }
    }

    private func resetAll() {
        guard m.confirm("Reset all settings?", "Every preference, shortcut, rule and friend returns to its default. Your clips and usage statistics are kept.", button: "Reset") else { return }
        m.s.resetToDefaults()
        m.state.friends?.applySettings()
        m.state.monitor.isConnected = m.s.connectedToClipboard
        m.changed(); m.hotkeysChanged()
        message = "Settings reset to defaults."
    }
}
