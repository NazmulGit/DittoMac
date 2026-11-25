// PreferencesScreenshots.swift — Preferences › Screenshots: permission, hotkeys, actions, output, overlay,
// then the Beautify and Upload & Share sections (owned by the beautify/upload agent).
import AppKit
import SwiftUI
import DittoCore

struct ScreenshotPrefs: View {
    @ObservedObject var m: PrefsModel
    @LState private var granted = false
    @LState private var template = ""
    @LState private var now = Date()

    /// Through the service contract (`hasScreenRecordingPermission`), never prompting on a refresh.
    private func refreshPermission() {
        granted = m.state.screenshots?.hasScreenRecordingPermission(prompt: false) ?? ScreenCapturePermission.isGranted
    }

    /// Recorder binding showing the *effective* shortcut (default when never set; 0 = disabled).
    private func hotkey(_ name: String) -> Binding<Int> {
        Binding(get: { m.s.screenshotHotkey(name) },
                set: { v in m.hotkey(name).wrappedValue = v })
    }

    private var exampleName: String {
        ScreenshotFileName.format(template: template, date: now) + "." + m.s.screenshotFormat.fileExtension
    }

    var body: some View {
        Form {
            permissionSection
            Section("Shortcuts") {
                LabeledContent("Capture area") { KeyRecorder(binding: hotkey("captureArea")) }
                LabeledContent("Capture window") { KeyRecorder(binding: hotkey("captureWindow")) }
                LabeledContent("Capture full screen") { KeyRecorder(binding: hotkey("captureFullScreen")) }
                if let n = m.notice { Text(n).font(.caption).foregroundStyle(.orange) }
                ForEach(m.state.screenshots?.hotkeyProblems ?? [], id: \.self) { p in
                    Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Defaults: ⌃⇧4 area, ⌃⇧5 window, ⌃⇧3 full screen. Clear a shortcut to turn it off.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        for name in Settings.screenshotHotkeyNames {
                            m.s.setHotkey(name, Settings.screenshotDefaultHotkeys[name] ?? 0)
                        }
                        m.notice = nil
                        m.hotkeysChanged()
                    }
                }
            }
            Section("After capturing") {
                Picker("Return key in the editor", selection: m.b(\.screenshotDefaultAction)) {
                    Text("Copy to clipboard").tag(ScreenshotAction.copy)
                    Text("Save to file").tag(ScreenshotAction.save)
                    Text("Upload and copy link").tag(ScreenshotAction.upload)
                    Text("Nothing (keep editing)").tag(ScreenshotAction.editor)
                }
                Picker("Full-screen shortcut", selection: m.b(\.screenshotFullScreenAction)) {
                    ForEach(ScreenshotAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Clicking a window", selection: m.b(\.screenshotWindowAction)) {
                    ForEach(ScreenshotAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Add screenshots to the clipboard history (Quick Paste)", isOn: m.b(\.screenshotAddToHistory))
                Toggle("Play camera sound", isOn: m.b(\.screenshotPlaySound))
            }
            Section("File format") {
                Picker("Format", selection: m.b(\.screenshotFormat)) {
                    ForEach(ScreenshotFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if m.s.screenshotFormat == .jpg {
                    HStack {
                        Text("JPEG quality: \(Int((m.s.screenshotJPEGQuality * 100).rounded()))%")
                            .frame(width: 140, alignment: .leading)
                        Slider(value: m.b(\.screenshotJPEGQuality), in: 0.6...1.0, step: 0.05)
                    }
                }
                Text("Copy always puts PNG on the clipboard; uploads use PNG (or JPEG when selected).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saving") {
                Toggle("Ask where to save each time", isOn: m.b(\.screenshotAskWhereToSave))
                LabeledContent(m.s.screenshotAskWhereToSave ? "Start in folder" : "Save to folder") {
                    HStack(spacing: 6) {
                        Text(abbreviate(m.s.screenshotSaveFolder))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .help(m.s.screenshotSaveFolder)
                        Button("Choose…") { chooseFolder() }
                        Button {
                            if let url = try? ScreenshotOutput.ensureFolder(m.s.screenshotSaveFolder) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                    }
                }
                TextField("File name", text: $template)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: template) { v in m.s.screenshotNameTemplate = v; now = Date(); m.changed() }
                LabeledContent("Example") { Text(exampleName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Text("Tokens: yyyy yy MM MMM dd EEE HH hh mm ss a; put literal text containing them in 'quotes'. Existing files are never overwritten.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { template = ScreenshotFileName.defaultTemplate }
                }
            }
            Section("Capture") {
                Picker("Delay before capturing", selection: m.b(\.screenshotDelaySeconds)) {
                    ForEach(Settings.screenshotDelayChoices, id: \.self) { s in
                        Text(s == 0 ? "None" : "\(s) seconds").tag(s)
                    }
                }
                Toggle("Include the mouse pointer", isOn: m.b(\.screenshotIncludeCursor))
            }
            Section("Selection overlay") {
                HStack {
                    Text("Dim outside selection: \(Int((m.s.screenshotDimOpacity * 100).rounded()))%")
                        .frame(width: 200, alignment: .leading)
                    Slider(value: m.b(\.screenshotDimOpacity), in: 0...0.85, step: 0.05)
                }
                Toggle("Show magnifier and pixel colour while selecting", isOn: m.b(\.screenshotShowMagnifier))
                Toggle("Remember the last annotation tool, colour and line width", isOn: m.b(\.screenshotRememberTool))
                Text("In the overlay: drag to select, drag handles to resize (⇧ keeps the ratio), arrows nudge (⇧ ×10), ⌘A whole screen, Return runs the default action, hold ⌘ while releasing to copy instantly, Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Beautify") { BeautifyDefaultsView() }
            Section("Upload & Share") { UploadSettingsView(m: m) }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshPermission()
            template = m.s.screenshotNameTemplate
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermission() }
    }

    @ViewBuilder private var permissionSection: some View {
        Section("Permission") {
            HStack(spacing: 10) {
                Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? Color.green : Color.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(granted ? "Screen Recording is allowed" : "Screen Recording permission is needed")
                        .font(.headline)
                    Text(granted
                         ? "DittoMac can capture the screen. Screenshots stay on this Mac unless you upload them."
                         : "macOS only lets apps capture the screen after you allow it in Privacy & Security.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                if !granted {
                    Button("Grant Access") {
                        if m.state.screenshots?.hasScreenRecordingPermission(prompt: true) != true {
                            ScreenCapturePermission.openSystemSettings()
                        }
                        refreshPermission()
                    }
                }
                Button("Open System Settings") { ScreenCapturePermission.openSystemSettings() }
                Button("Check Again") { refreshPermission() }
            }
            Text("After allowing access, macOS may require you to quit and reopen DittoMac. Because DittoMac is ad-hoc signed, an update can reset the permission: if capturing stops working, switch DittoMac off and on again under Screen & System Audio Recording.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Choose where DittoMac saves screenshots."
        p.directoryURL = URL(fileURLWithPath: m.s.screenshotSaveFolder)
        guard p.runModal() == .OK, let url = p.url else { return }
        m.s.screenshotSaveFolder = url.path
        m.changed()
    }
}
