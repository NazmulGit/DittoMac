import Testing
import Foundation
@testable import DittoCore

@Suite struct AppearanceTests {
    func settings() -> (Settings, UserDefaults, String) {
        let name = "test-appearance-\(UUID())"
        let d = UserDefaults(suiteName: name)!
        return (Settings(defaults: d), d, name)
    }

    // MARK: Hex colours

    @Test func hexParsingAndNormalising() {
        #expect(HexColor.normalize("#abc") == "#AABBCC")
        #expect(HexColor.normalize("  #0a84ff ") == "#0A84FF")
        #expect(HexColor.normalize("FF8000") == "#FF8000")
        #expect(HexColor.normalize("#11223344") == "#112233")   // alpha dropped
        for bad in ["", "#", "#12", "#12345", "#GGGGGG", "red", "#1234567", "#１２３", "rgb(1,2,3)", String(repeating: "A", count: 40)] {
            #expect(HexColor.normalize(bad) == nil, "\(bad)")
        }
    }

    @Test func luminanceAndContrast() {
        #expect(HexColor("#000000")!.isDark)
        #expect(!HexColor("#FFFFFF")!.isDark)
        #expect(HexColor("#FFF3A6")!.contrastingText.rgbHex == "#000000")
        #expect(HexColor("#1E74D3")!.contrastingText.rgbHex == "#FFFFFF")
        let mid = HexColor("#000000")!.mixed(with: HexColor("#FFFFFF")!, 0.5)
        #expect(mid.rgbHex == "#808080")
        #expect(HexColor("#000000")!.mixed(with: HexColor("#FFFFFF")!, 7).rgbHex == "#FFFFFF")   // t clamped
    }

    // MARK: Density

    @Test func densityMetrics() {
        let lh = 16.0
        let c = RowDensity.compact.rowHeight(lineHeight: lh, lines: 2)
        let m = RowDensity.comfortable.rowHeight(lineHeight: lh, lines: 2)
        let s = RowDensity.spacious.rowHeight(lineHeight: lh, lines: 2)
        #expect(c < m && m < s)
        #expect(c >= 32 && c == (32 + 2 * (2 + 1)))
        #expect(RowDensity.comfortable.rowHeight(lineHeight: lh, lines: 99) == RowDensity.comfortable.rowHeight(lineHeight: lh, lines: 5))
        #expect(RowDensity.comfortable.rowHeight(lineHeight: lh, lines: 0) == RowDensity.comfortable.rowHeight(lineHeight: lh, lines: 1))
        #expect(RowDensity.spacious.rowHeight(lineHeight: 1, lines: 1) == RowDensity.spacious.metrics.minimumHeight)
        #expect(RowDensity.compact.rowHeight(lineHeight: .nan, lines: 1) >= 20)
        for d in RowDensity.allCases {
            let mm = d.metrics
            #expect(mm.selectionInsetX < mm.horizontalPadding)
        }
    }

    @Test func firstTenLabels() {
        #expect(FirstTenStyle.plain.label(3) == "3")
        #expect(FirstTenStyle.badge.label(0) == "0")
        #expect(FirstTenStyle.keycap.label(1) == "⌘1")
    }

    // MARK: Relative time

    @Test func relativeTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let loc = Locale(identifier: "en_GB")
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15, minute: 0))!
        func r(_ secs: TimeInterval) -> String { RelativeTime.short(now.addingTimeInterval(-secs), now: now, calendar: cal, locale: loc) }
        #expect(r(5) == "now")
        #expect(r(-20) == "now")
        #expect(r(5 * 60) == "5m")
        #expect(r(59 * 60) == "59m")
        #expect(r(3 * 3600) == "3h")
        #expect(r(16 * 3600) == "Yesterday")     // 23:00 the day before
        #expect(r(3 * 86400) == "3d")
        let old = RelativeTime.short(cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!, now: now, calendar: cal, locale: loc)
        #expect(old.contains("2") && old.contains("Nov") && !old.contains("2026"))
        let older = RelativeTime.short(cal.date(from: DateComponents(year: 2024, month: 3, day: 9))!, now: now, calendar: cal, locale: loc)
        #expect(older.contains("2024") && older.contains("Mar"))
    }

    // MARK: Note colours

    @Test func noteColorPalette() {
        #expect(NoteColor.allCases.count == 6)
        for c in NoteColor.allCases {
            for dark in [false, true] {
                #expect(HexColor.normalize(c.paper(dark: dark)) == c.paper(dark: dark))
                #expect(HexColor.normalize(c.bar(dark: dark)) == c.bar(dark: dark))
                let paper = HexColor(c.paper(dark: dark))!, text = HexColor(c.text(dark: dark))!
                #expect(abs(paper.luminance - text.luminance) > 0.45, "\(c) dark=\(dark) contrast")
                #expect(paper.isDark == dark)
            }
        }
        #expect(NoteColor.named("GRAY") == .grey)
        #expect(NoteColor.named("pink") == .pink)
        #expect(NoteColor.named("../etc") == .yellow)
        #expect(NoteColor.named(nil) == .yellow)
    }

    @Test func noteSettingsRoundTrip() {
        let (s, d, name) = settings()
        defer { d.removePersistentDomain(forName: name) }
        #expect(s.restoreDesktopNotes)
        #expect(s.noteColor(for: 7) == nil)
        s.setNoteColor(.blue, for: 7)
        #expect(s.noteColor(for: 7) == .blue)
        s.setNoteFrame("{{10, 20}, {240, 200}}", for: 7)
        #expect(s.noteFrame(for: 7) == "{{10, 20}, {240, 200}}")
        #expect(s.noteFloats(7))
        s.setNoteFloats(false, for: 7)
        #expect(!s.noteFloats(7) && s.noteFloats(8))
        s.openDesktopNoteIDs = [7, 9]
        #expect(s.openDesktopNoteIDs == [7, 9])
        s.openDesktopNoteIDs = Array(1...80)
        #expect(s.openDesktopNoteIDs.count == 50)
        s.openDesktopNoteIDs = [7, 9]
        s.forgetNote(7)
        #expect(s.noteColor(for: 7) == nil && s.noteFrame(for: 7) == nil && s.openDesktopNoteIDs == [9] && s.noteFloats(7))
    }

    // MARK: Appearance settings

    @Test func appearanceSettingsDefaultsAndValidation() {
        let (s, d, name) = settings()
        defer { d.removePersistentDomain(forName: name) }
        #expect(s.appearanceMode == .system && s.accentColorHex == "" && s.rowDensity == .comfortable)
        #expect(s.rowCornerRadius == 7 && s.showRelativeTimestamps && !s.showSourceAppIcon && s.showFormatBadges)
        #expect(s.popupMaterial == .opaque && s.firstTenStyle == .badge && s.menuBarIconSymbol == "doc.on.clipboard")
        s.accentColorHex = "#abc"; #expect(s.accentColorHex == "#AABBCC")
        s.accentColorHex = "javascript:"; #expect(s.accentColorHex == "")
        s.rowCornerRadius = 99; #expect(s.rowCornerRadius == 14)
        s.rowCornerRadius = .infinity; #expect(s.rowCornerRadius == 7)
        s.menuBarIconSymbol = "scissors"; #expect(s.menuBarIconSymbol == MenuBarIcon.defaultSymbol)
        s.menuBarIconSymbol = "paperclip"; #expect(s.menuBarIconSymbol == "paperclip")
        d.set("bogus", forKey: "rowDensity"); #expect(s.rowDensity == .comfortable)
        s.appearanceMode = .dark
        s.themeName = "Nord"
        s.resetAppearance()
        #expect(s.appearanceMode == .system && s.themeName == "System" && s.menuBarIconSymbol == "doc.on.clipboard")
        #expect(Settings.appearanceKeys.isDisjoint(with: Settings.allKeys))
        #expect(MenuBarIcon.badgeText(0) == "" && MenuBarIcon.badgeText(5) == "5" && MenuBarIcon.badgeText(140) == "99+")
    }

    // MARK: Theme files

    @Test func themeFileRoundTrip() throws {
        let t = ThemeFile(name: "Ocean", colors: ["MainWindowBG": "#102030", "ListBoxSelectedBG": "#3366CC"])
        let parsed = try ThemeFile.parse(try t.encoded())
        #expect(parsed == t)
        #expect(parsed.spec.isDark)
        let c = parsed.completed()
        #expect(c["ListBoxSelectedText"] == "#FFFFFF")
        for (_, v) in c { #expect(HexColor.normalize(v) == v) }
        #expect(Set(c.keys).isSubset(of: ThemeFile.allowedKeys))
    }

    @Test func themeFileValidation() throws {
        func parse(_ s: String) throws -> ThemeFile { try ThemeFile.parse(Data(s.utf8)) }
        let messy = "{\"name\":\"../../evil\\u0000\\nname/x\",\"colors\":{\"MainWindowBG\":\"#abc\",\"Evil\":\"#000000\",\"GroupTreeText\":\"url(x)\",\"ListBoxOddRowsText\":123}}"
        let otherFormat = "{\"format\":\"other\",\"colors\":{\"MainWindowBG\":\"#fff\"}}"
        let noColors = "{\"name\":\"x\"}"
        let future = "{\"version\":99,\"colors\":{\"MainWindowBG\":\"#fff\"}}"
        let unknownOnly = "{\"colors\":{\"Nope\":\"#fff\"}}"
        let unnamed = "{\"colors\":{\"MainWindowBG\":\"#fff\"}}"
        // unknown keys and bad colours dropped, colours normalised, name sanitised
        let t = try parse(messy)
        #expect(t.colors == ["MainWindowBG": "#AABBCC"])
        #expect(!t.name.contains("/") && !t.name.contains("\n") && !t.name.hasPrefix(".") && !t.name.contains("\u{0}"))
        #expect(throws: ThemeFile.ValidationError.notJSON) { try parse("not json") }
        #expect(throws: ThemeFile.ValidationError.notJSON) { try parse("[1,2]") }
        #expect(throws: ThemeFile.ValidationError.wrongFormat) { try parse(otherFormat) }
        #expect(throws: ThemeFile.ValidationError.wrongFormat) { try parse(noColors) }
        #expect(throws: ThemeFile.ValidationError.unsupportedVersion) { try parse(future) }
        #expect(throws: ThemeFile.ValidationError.noColors) { try parse(unknownOnly) }
        let big = Data(repeating: 0x20, count: ThemeFile.maxFileBytes + 1)
        #expect(throws: ThemeFile.ValidationError.tooLarge) { try ThemeFile.parse(big) }
        var many: [String: String] = [:]
        for i in 0..<200 { many["k\(i)"] = "#000000" }
        let manyData = try JSONSerialization.data(withJSONObject: ["colors": many])
        #expect(throws: ThemeFile.ValidationError.tooManyColors) { try ThemeFile.parse(manyData) }
        // missing name → default
        #expect(try parse(unnamed).name == "Custom Theme")
    }

    @Test func themeNamesAndFileNames() {
        #expect(ThemeFile.sanitizeName("  My   Theme  ") == "My Theme")
        #expect(ThemeFile.sanitizeName("") == "Custom Theme")
        #expect(ThemeFile.sanitizeName("...") == "Custom Theme")
        #expect(ThemeFile.sanitizeName(String(repeating: "x", count: 100)).count == ThemeFile.maxNameLength)
        #expect(ThemeFile.fileName(for: "My Théme/1") == "My-Th-me1.json" || ThemeFile.fileName(for: "My Théme/1") == "My-Th-me-1.json")
        #expect(ThemeFile.fileName(for: "../../x") == "x.json")
        #expect(ThemeFile.fileName(for: "日本") == "Custom-Theme.json")
        let f = ThemeFile.fileName(for: String(repeating: "a", count: 200))
        #expect(f.count <= 53 && f.hasSuffix(".json") && !f.contains("/"))
    }

    @Test func themeFromBuiltIns() {
        #expect(ThemeFile.from(ThemeData.system) == nil)
        for spec in ThemeData.all where spec.name != ThemeData.systemName {
            let f = ThemeFile.from(spec)
            #expect(f != nil)
            #expect(f?.spec.isDark == spec.isDark, "\(spec.name)")
        }
        #expect(ThemeFile.editorKeys.count == 12)
        #expect(ThemeFile.editorKeys.allSatisfy { ThemeFile.allowedKeys.contains($0.key) })
    }

    // MARK: Lock planning

    @Test func lockPlanToggleAndDelete() {
        let mixed = LockPlan([LockItem(id: 1, isLocked: true), LockItem(id: 2, isLocked: false), LockItem(id: 3, isLocked: false, isGroup: true)])
        #expect(mixed.toggle == .lock([2]))
        #expect(mixed.canLock && mixed.canRemoveLock && mixed.hasLocked && !mixed.allLocked)
        #expect(mixed.plainDeleteIDs == [2, 3] && mixed.lockedDeleteIDs == [1])
        #expect(mixed.exportableIDs == [2])
        #expect(mixed.needsUnlock(vaultUnlocked: false) && !mixed.needsUnlock(vaultUnlocked: true))

        let allLocked = LockPlan([LockItem(id: 4, isLocked: true), LockItem(id: 5, isLocked: true)])
        #expect(allLocked.toggle == .removeLock([4, 5]) && allLocked.allLocked && !allLocked.canLock)
        #expect(allLocked.plainDeleteIDs.isEmpty && allLocked.exportableIDs.isEmpty)

        let plain = LockPlan([LockItem(id: 6, isLocked: false)])
        #expect(plain.toggle == .lock([6]) && !plain.needsUnlock(vaultUnlocked: false) && !plain.canRemoveLock)

        #expect(LockPlan([LockItem(id: 7, isLocked: false, isGroup: true)]).toggle == .none)
        #expect(LockPlan([]).toggle == .none)
    }
}
