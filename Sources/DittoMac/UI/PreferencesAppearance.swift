// PreferencesAppearance.swift — Preferences › Appearance: light/dark, accent, themes (built-in, custom, import /
// export, editor), row layout, list font, popup size and material, menu-bar icon, sticky notes. Every change posts
// `.dittoSettingsChanged`, which the popup, the status item and AppDelegate apply live.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DittoCore

// MARK: - Helpers

extension Color {
    /// SwiftUI colour from "#RRGGBB" (gray when invalid).
    init(dmHex hex: String) {
        if let c = HexColor(hex) { self = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) } else { self = .gray }
    }

    /// "#RRGGBB" for a SwiftUI colour.
    var dmHex: String { AppearanceManager.hex(NSColor(self)) }
}

/// Working copy of the theme being edited (12 key colours + name).
@MainActor
final class ThemeEditorModel: ObservableObject {
    @Published var colors: [String: String] = [:]
    @Published var name = "My Theme"

    /// Seeds from a theme; the System theme starts from a light or dark neutral palette.
    func load(from spec: ThemeSpec, dark: Bool) {
        let base: [String: String]
        if spec.colors.isEmpty {
            base = ThemeFile(name: "System", colors: dark
                ? ["MainWindowBG": "#1E1E20", "ListBoxOddRowsBG": "#232326", "ListBoxEvenRowsBG": "#232326",
                   "ListBoxOddRowsText": "#ECECEC", "ListBoxSelectedBG": "#2F6FDB", "GroupTreeBG": "#1E1E20"]
                : ["MainWindowBG": "#F5F5F7", "ListBoxOddRowsBG": "#FFFFFF", "ListBoxEvenRowsBG": "#FFFFFF",
                   "ListBoxOddRowsText": "#1D1D1F", "ListBoxSelectedBG": "#2F6FDB", "GroupTreeBG": "#F5F5F7"]).completed()
            name = "My Theme"
        } else {
            base = ThemeFile(name: spec.name, colors: spec.colors).completed()
            name = CustomThemes.safeName(spec.name)
        }
        colors = base
    }

    func binding(_ key: String) -> Binding<Color> {
        Binding(get: { Color(dmHex: self.colors[key] ?? "#808080") },
                set: { self.colors[key] = $0.dmHex })
    }

    func hex(_ key: String) -> String { colors[key] ?? "#808080" }

    var themeFile: ThemeFile {
        var c: [String: String] = [:]
        for (k, v) in colors where ThemeFile.allowedKeys.contains(k) { if let h = HexColor.normalize(v) { c[k] = h } }
        return ThemeFile(name: ThemeFile.sanitizeName(name), colors: c)
    }
}

// MARK: - Tab

struct AppearancePrefs: View {
    @ObservedObject var m: PrefsModel
    @StateObject private var editor = ThemeEditorModel()
    @LState private var showEditor = false
    @LState private var message: String?
    @LState private var customRevision = 0

    private static let families: [String] = NSFontManager.shared.availableFontFamilies

    private var s: DittoCore.Settings { m.s }

    private var builtInThemes: [String] { ThemeData.all.map(\.name) }
    private var customThemes: [String] { _ = customRevision; return CustomThemes.shared.names }
    private var isCustomSelected: Bool { customThemes.contains { $0.caseInsensitiveCompare(s.themeName) == .orderedSame } }

    var body: some View {
        Form {
            lookSection
            themeSection
            if showEditor { editorSection }
            rowsSection
            textSection
            windowSection
            menuBarSection
            notesSection
            Section {
                HStack {
                    if let msg = message { Text(msg).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Restore Appearance Defaults") {
                        s.resetAppearance()
                        AppTheme.invalidate()
                        m.changed()
                        message = "Appearance restored to defaults."
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Look

    private var lookSection: some View {
        Section("Look") {
            Picker("Appearance", selection: m.b(\.appearanceMode)) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Selection colour") {
                HStack(spacing: 7) {
                    accentSwatch(nil)
                    ForEach(AccentPalette.colors, id: \.hex) { accentSwatch($0.hex, name: $0.name) }
                    ColorPicker("", selection: Binding(
                        get: { Color(dmHex: s.accentColorHex.isEmpty ? "#0A84FF" : s.accentColorHex) },
                        set: { s.accentColorHex = $0.dmHex; AppTheme.invalidate(); m.changed() }), supportsOpacity: false)
                        .labelsHidden()
                        .help("Custom colour")
                }
            }
            Picker("Popup material", selection: m.b(\.popupMaterial)) {
                ForEach(PopupMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private func accentSwatch(_ hex: String?, name: String = "Theme default") -> some View {
        let selected = (hex ?? "") == s.accentColorHex
        return Button {
            s.accentColorHex = hex ?? ""
            AppTheme.invalidate()
            m.changed()
        } label: {
            ZStack {
                if let hex {
                    Circle().fill(Color(dmHex: hex))
                } else {
                    Circle().fill(LinearGradient(colors: [.gray.opacity(0.35), .gray.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "circle.slash").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if selected { Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 2).padding(-3) }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help(name)
    }

    // MARK: Themes

    private var themeSection: some View {
        Section("Theme") {
            Picker("Theme", selection: Binding(get: { s.themeName }, set: {
                s.themeName = $0
                AppTheme.invalidate()
                m.changed()
            })) {
                ForEach(builtInThemes, id: \.self) { Text($0).tag($0) }
                if !customThemes.isEmpty {
                    Divider()
                    ForEach(customThemes, id: \.self) { Text("\($0) (custom)").tag($0) }
                }
                if !builtInThemes.contains(s.themeName) && !customThemes.contains(s.themeName) {
                    Text("\(s.themeName) (missing)").tag(s.themeName)
                }
            }
            ThemePreview(spec: AppTheme.spec(named: s.themeName), accent: s.accentColorHex, density: s.rowDensity,
                         radius: s.rowCornerRadius)
                .frame(height: 112)
            HStack {
                Button(showEditor ? "Hide Theme Editor" : "Customise…") {
                    if !showEditor { editor.load(from: AppTheme.spec(named: s.themeName), dark: AppearanceManager.isDark()) }
                    showEditor.toggle()
                }
                Button("Import Theme…") { importTheme() }
                Button("Export Theme…") { exportTheme() }
                if isCustomSelected {
                    Button("Delete Custom Theme", role: .destructive) { deleteCustom() }
                }
            }
            Text("Themes are JSON files (max 64 KB) with hex colours only. Custom themes live in ~/Library/Application Support/DittoMac/Themes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var editorSection: some View {
        Section("Theme editor") {
            TextField("Name", text: $editor.name)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ThemeFile.editorKeys, id: \.key) { item in
                        ColorPicker(item.title, selection: editor.binding(item.key), supportsOpacity: false)
                    }
                }
                .frame(maxWidth: 260)
                ThemePreview(spec: editor.themeFile.spec, accent: "", density: s.rowDensity, radius: s.rowCornerRadius)
                    .frame(minWidth: 200, maxWidth: .infinity, minHeight: 230)
            }
            HStack {
                Spacer()
                Button("Save as Custom Theme") { saveCustom() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Rows

    private var rowsSection: some View {
        Section("Rows") {
            Picker("Density", selection: m.b(\.rowDensity)) {
                ForEach(RowDensity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Selection corner radius")
                Slider(value: Binding(get: { s.rowCornerRadius }, set: { s.rowCornerRadius = $0.rounded(); m.changed() }),
                       in: DittoCore.Settings.rowCornerRadiusRange)
                Text("\(Int(s.rowCornerRadius)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            Stepper("Lines per row: \(s.linesPerRow)", value: m.b(\.linesPerRow), in: 1...5)
            Toggle("Show relative timestamps (5m, 3h, Yesterday)", isOn: m.b(\.showRelativeTimestamps))
            Toggle("Show source-app icon", isOn: m.b(\.showSourceAppIcon))
            Toggle("Show format badges (formatting kept, has image)", isOn: m.b(\.showFormatBadges))
            Toggle("Subtle dividers between rows", isOn: m.b(\.showRowDividers))
            Toggle("Show first-ten numbers", isOn: m.b(\.showFirstTenIndex))
            Picker("First-ten number style", selection: m.b(\.firstTenStyle)) {
                ForEach(FirstTenStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!s.showFirstTenIndex)
        }
    }

    // MARK: Text

    private var textSection: some View {
        Section("List font") {
            Picker("Font", selection: m.b(\.fontName)) {
                Text("System default").tag("")
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                if !s.fontName.isEmpty && !Self.families.contains(s.fontName) { Text(s.fontName).tag(s.fontName) }
            }
            Stepper(value: m.b(\.fontSize), in: 6...72, step: 1) { Text("Size: \(Int(s.fontSize)) pt") }
            Text("The quick brown fox jumps over the lazy dog — 0123456789")
                .font(s.fontName.isEmpty ? .system(size: CGFloat(s.fontSize)) : .custom(s.fontName, size: CGFloat(s.fontSize)))
                .lineLimit(2)
                .padding(.vertical, 4)
        }
    }

    // MARK: Window

    private var windowSection: some View {
        Section("Popup window") {
            HStack {
                TextField("Width", value: m.b(\.popupWidth), format: .number).frame(maxWidth: 150)
                TextField("Height", value: m.b(\.popupHeight), format: .number).frame(maxWidth: 150)
                Button("Reset Size") { s.popupWidth = 380; s.popupHeight = 460; m.changed() }
            }
            Text("Points; 200–4000 wide, 150–4000 tall. The popup also remembers the size you drag it to.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Transparency: \(s.transparencyPercent)%")
                Slider(value: Binding(get: { Double(s.transparencyPercent) },
                                      set: { s.transparencyPercent = Int($0.rounded()); m.changed() }), in: 0...40)
            }
        }
    }

    // MARK: Menu bar

    private var menuBarSection: some View {
        Section("Menu bar") {
            Picker("Icon", selection: m.b(\.menuBarIconSymbol)) {
                ForEach(MenuBarIcon.symbols, id: \.symbol) { item in
                    Label(item.title, systemImage: item.symbol).tag(item.symbol)
                }
            }
            Toggle("Dim the icon while disconnected from the clipboard", isOn: m.b(\.menuBarDimWhenDisconnected))
            Toggle("Show how many clips were copied since Quick Paste was last opened", isOn: m.b(\.menuBarShowRecentCount))
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        Section("Sticky notes") {
            Toggle("Restore desktop notes at launch", isOn: m.b(\.restoreDesktopNotes))
            HStack {
                Text("Sticky notes are clips pinned to the top of the list; they can be locked and shown on the desktop.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("New Sticky Note…") { StickyNoteCenter.shared.newNote(state: m.state) }
            }
        }
    }

    // MARK: Theme actions

    private func saveCustom() {
        do {
            let saved = try CustomThemes.shared.save(editor.themeFile)
            customRevision += 1
            s.themeName = saved.name
            editor.name = saved.name
            AppTheme.invalidate()
            m.changed()
            message = "Saved custom theme “\(saved.name)”."
        } catch {
            message = "Couldn’t save the theme: \(error.localizedDescription)"
        }
    }

    private func importTheme() {
        let p = NSOpenPanel()
        p.title = "Import Theme"
        p.allowedContentTypes = [.json]
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max
            guard size <= ThemeFile.maxFileBytes else { throw ThemeFile.ValidationError.tooLarge }
            let theme = try ThemeFile.parse(try Data(contentsOf: url))
            let saved = try CustomThemes.shared.save(theme)
            customRevision += 1
            s.themeName = saved.name
            AppTheme.invalidate()
            m.changed()
            message = "Imported “\(saved.name)” (\(theme.colors.count) colours)."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportTheme() {
        guard let file = ThemeFile.from(AppTheme.spec(named: s.themeName)) else {
            message = "The System theme has no colours to export. Use Customise… to make a theme first."
            return
        }
        let p = NSSavePanel()
        p.title = "Export Theme"
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = ThemeFile.fileName(for: file.name)
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try file.encoded().write(to: url, options: .atomic)
            message = "Exported “\(file.name)”."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func deleteCustom() {
        let name = s.themeName
        guard m.confirm("Delete the custom theme “\(name)”?", "The theme file is removed. This can’t be undone.", button: "Delete") else { return }
        CustomThemes.shared.delete(named: name)
        customRevision += 1
        s.themeName = ThemeData.systemName
        AppTheme.invalidate()
        m.changed()
        message = "Deleted “\(name)”."
    }
}

// MARK: - Live preview

/// A miniature popup list in the given theme (used by the theme picker and the editor).
struct ThemePreview: View {
    let spec: ThemeSpec
    let accent: String
    let density: RowDensity
    let radius: Double

    private func c(_ key: String, _ fallback: Color) -> Color {
        spec.colors[key].map { Color(dmHex: $0) } ?? fallback
    }

    var body: some View {
        let selBG = accent.isEmpty ? c("ListBoxSelectedBG", Color.accentColor) : Color(dmHex: accent)
        let selText = accent.isEmpty ? c("ListBoxSelectedText", .white)
            : Color(dmHex: (HexColor(accent)?.contrastingText.rgbHex) ?? "#FFFFFF")
        let rows: [(String, String, Bool)] = [
            ("Meeting notes — Thursday", "now", false),
            ("https://github.com/sabrogden/Ditto", "5m", true),
            ("SELECT * FROM Main ORDER BY clipOrder", "2h", false),
            ("#0A84FF", "Yesterday", false),
        ]
        let pad = density == .compact ? 2.0 : (density == .comfortable ? 4.0 : 6.0)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                let selected = r.2
                HStack(spacing: 7) {
                    Text("\(i + 1)").font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .frame(width: 15, height: 13)
                        .background(Capsule().fill((selected ? selText : c("ListBoxOddRowsText", .primary)).opacity(0.12)))
                        .foregroundStyle((selected ? selText : c("ListBoxOddRowsText", .primary)).opacity(0.7))
                    Text(r.0).font(.system(size: 11.5)).lineLimit(1)
                        .foregroundStyle(selected ? selText : c(i % 2 == 0 ? "ListBoxOddRowsText" : "ListBoxEvenRowsText", .primary))
                    Spacer(minLength: 4)
                    if i == 1 { Circle().fill(c("ClipPastedColor", .green)).frame(width: 5, height: 5) }
                    Text(r.1).font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle((selected ? selText : c("ListBoxOddRowsText", .primary)).opacity(0.55))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, pad)
                .background(
                    RoundedRectangle(cornerRadius: radius).fill(selected ? selBG : .clear).padding(.horizontal, 4)
                )
                .background(c(i % 2 == 0 ? "ListBoxOddRowsBG" : "ListBoxEvenRowsBG", Color(nsColor: .controlBackgroundColor)))
            }
            HStack {
                Text("4 / 120 · Target: Notes").font(.system(size: 9.5)).foregroundStyle(c("CaptionTextColor", .secondary))
                Spacer()
                Text("match").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(c("SearchTextHighlight", .red))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(c("MainWindowBG", Color(nsColor: .windowBackgroundColor)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
}
