import Testing
import Foundation
@testable import DittoCore

@Suite struct SettingsTests {
    func make() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
    }

    @Test func defaults() {
        let s = make()
        #expect(s.connectedToClipboard && s.showMenuBarIcon && !s.showDockIcon)
        #expect(s.maxEntries == 500 && s.expiredEntries == 5 && s.descTextSize == 500)
        #expect(s.linesPerRow == 2 && s.popupPosition == .caret && s.popupWidth == 380 && s.popupHeight == 460)
        #expect(s.popupX == nil && s.popupY == nil)
        #expect(s.enabledTypes == Settings.defaultEnabledTypes)
        #expect(s.copyAppInclude == "*" && s.searchMode == .wildcard)
        #expect(s.multiPasteSeparator == "[LF]" && s.multiPasteReverse)
        #expect(s.webSearchURL == "https://www.google.com/search?q=%s")
        #expect(s.friendsPort == 23443 && !s.friendsEnabled && !s.friendsDeviceName.isEmpty)
        #expect(s.copyRules.isEmpty && s.friendsPeers.isEmpty)
        #expect(s.themeName == "System" && s.fontSize == 13 && s.editorFontSize == 14)
    }

    @Test func roundTripAndClamp() {
        let s = make()
        s.maxEntries = 42; #expect(s.maxEntries == 42)
        s.linesPerRow = 99; #expect(s.linesPerRow == 5)
        s.linesPerRow = -3; #expect(s.linesPerRow == 1)
        s.transparencyPercent = 100; #expect(s.transparencyPercent == 40)
        s.popupPosition = .cursor; #expect(s.popupPosition == .cursor)
        s.popupX = 12.5; #expect(s.popupX == 12.5)
        s.popupX = nil; #expect(s.popupX == nil)
        s.allowDuplicates = true; #expect(s.allowDuplicates)
        s.searchMode = .regex; #expect(s.searchMode == .regex)
    }

    @Test func searchHistory() {
        let s = make()
        for i in 0..<15 { s.addSearchHistory("q\(i)") }
        #expect(s.searchHistory.count == 10)
        #expect(s.searchHistory.first == "q14")
        s.addSearchHistory("q10")
        #expect(s.searchHistory.first == "q10" && s.searchHistory.count == 10)
        s.addSearchHistory(String(repeating: "x", count: 80))
        #expect(s.searchHistory.first?.count == 50)
        s.addSearchHistory("   ")
        #expect(s.searchHistory.first?.count == 50)
    }

    @Test func peersAndRules() {
        let s = make()
        let p = FriendPeer(name: "Laptop", host: "10.0.0.2", port: 1234, sendAllCopies: true)
        s.friendsPeers = [p]; #expect(s.friendsPeers == [p])
        let r = CopyRule(name: "r", action: .ignore)
        s.copyRules = [r]; #expect(s.copyRules == [r])
    }

    @Test func hotkeys() {
        let s = make()
        let activate = KeyCombo(encoded: s.hotkey("activate"))
        #expect(activate.keyCode == 0x32 && activate.modifiers == 0x1000)
        #expect(activate.displayString == "⌃`")
        #expect(s.hotkey("nope") == 0)
        let c = KeyCombo(keyCode: 0x09, modifiers: KeyCombo.cmdKey | KeyCombo.shiftKey | KeyCombo.optionKey | KeyCombo.controlKey)
        s.setHotkey("paste", c.encoded)
        #expect(s.hotkey("paste") == c.encoded)
        #expect(KeyCombo(encoded: c.encoded) == c)
        #expect(c.displayString == "⌃⌥⇧⌘V")
        #expect(s.hotkey("activate") == Settings.defaultHotkeys["activate"])
        #expect(KeyCombo(keyCode: 0x7A, modifiers: 0).displayString == "F1")
        #expect(KeyCombo(keyCode: 0x31, modifiers: KeyCombo.cmdKey).displayString == "⌘Space")
    }

    @Test func statsAndReset() {
        let s = make()
        s.recordCopy(); s.recordCopy(); s.recordPaste()
        #expect(s.copyCountTotal == 2 && s.copyCountTrip == 2 && s.pasteCountTrip == 1)
        s.resetTrip()
        #expect(s.copyCountTrip == 0 && s.pasteCountTrip == 0 && s.copyCountTotal == 2)
        s.maxEntries = 7
        s.resetToDefaults()
        #expect(s.maxEntries == 500)
        #expect(s.copyCountTotal == 2)
    }
}
