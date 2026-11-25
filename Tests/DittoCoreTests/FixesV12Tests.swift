import Testing
import Foundation
import CoreGraphics
@testable import DittoCore

/// Regression tests for the v1.2 bug-fix pass: window reachability, display validation, hotkey clashes and what
/// a sync settings change means for the running driver.
@Suite struct FixesV12Tests {
    typealias G = ScreenshotGeometry
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)           // visibleFrame (AppKit, y up)
    let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)

    // MARK: title bar reachability (sticky note frames)

    @Test func frameFullyOnScreenIsReachable() {
        #expect(G.isTitleBarReachable(CGRect(x: 100, y: 100, width: 270, height: 250), visibleFrames: [screen]))
    }

    @Test func onePixelIntersectionIsNotReachable() {
        // Old check (`intersects`) accepted this: the note hangs off the right edge by all but 1 px.
        #expect(!G.isTitleBarReachable(CGRect(x: 1439, y: 100, width: 270, height: 250), visibleFrames: [screen]))
    }

    @Test func titleBarAboveTheMenuBarIsNotReachable() {
        // Top of the frame is above the visible area: only the body is on screen.
        #expect(!G.isTitleBarReachable(CGRect(x: 100, y: 700, width: 270, height: 250), visibleFrames: [screen]))
        // 40 pt of title bar just inside is fine.
        #expect(G.isTitleBarReachable(CGRect(x: 100, y: 625, width: 270, height: 250), visibleFrames: [screen]))
    }

    @Test func bodyOffScreenButTitleBarOnScreenIsReachable() {
        #expect(G.isTitleBarReachable(CGRect(x: 100, y: -200, width: 270, height: 250), visibleFrames: [screen]))
    }

    @Test func unplugCasesAreUnreachable() {
        // Saved on a second display that is gone.
        let r = CGRect(x: 2000, y: 200, width: 270, height: 250)
        #expect(G.isTitleBarReachable(r, visibleFrames: [screen, second]))
        #expect(!G.isTitleBarReachable(r, visibleFrames: [screen]))
        #expect(!G.isTitleBarReachable(r, visibleFrames: []))
    }

    @Test func titleBarMustLieOnOneScreen() {
        // Straddling the seam with only 15 pt on each side: neither screen holds a usable grab area.
        #expect(!G.isTitleBarReachable(CGRect(x: 1425, y: 100, width: 30, height: 100), visibleFrames: [screen, second]))
        // Mostly on the second screen: reachable there.
        #expect(G.isTitleBarReachable(CGRect(x: 1400, y: 100, width: 300, height: 100), visibleFrames: [screen, second]))
    }

    @Test func degenerateFrames() {
        #expect(!G.isTitleBarReachable(.zero, visibleFrames: [screen]))
        // Shorter than the grab height: the whole frame counts.
        #expect(G.isTitleBarReachable(CGRect(x: 10, y: 10, width: 200, height: 20), visibleFrames: [screen]))
    }

    // MARK: display validation after a capture

    @Test func sameDisplaysMatchInAnyOrder() {
        let a = CGRect(x: 0, y: 0, width: 1440, height: 900), b = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(G.displaysMatch(captured: [a, b], current: [b, a]))
    }

    @Test func changedDisplaysDoNotMatch() {
        let a = CGRect(x: 0, y: 0, width: 1440, height: 900), b = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(!G.displaysMatch(captured: [a, b], current: [a]))                       // one unplugged
        #expect(!G.displaysMatch(captured: [a], current: [a, b]))                       // one added
        #expect(!G.displaysMatch(captured: [a], current: [CGRect(x: 0, y: 0, width: 1280, height: 800)]))   // resolution
        #expect(!G.displaysMatch(captured: [a, b], current: [a, CGRect(x: -1920, y: 0, width: 1920, height: 1080)])) // moved
        #expect(G.displaysMatch(captured: [], current: []))
    }

    // MARK: hotkey clash detection

    @Test func clashFindsAnotherNameWithTheSameCombo() {
        let combo = KeyCombo(keyCode: 0x15, modifiers: KeyCombo.controlKey | KeyCombo.shiftKey).encoded
        #expect(HotkeyClash.firstClash(name: "activate", value: combo, in: ["captureArea": combo, "activate": 7]) == "captureArea")
        #expect(HotkeyClash.firstClash(name: "captureArea", value: combo, in: ["captureArea": combo]) == nil)   // itself
        #expect(HotkeyClash.firstClash(name: "activate", value: 0, in: ["a": 0, "b": 0]) == nil)               // unassigned
        #expect(HotkeyClash.firstClash(name: "x", value: combo, in: ["b": combo, "a": combo]) == "a")           // deterministic
    }

    @Test func effectiveHotkeysIncludeUnsetCaptureDefaults() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-fx-\(UUID())")!)
        // Never set: `hotkeys` doesn't know the capture defaults, `effectiveHotkeys` does.
        #expect(s.hotkeys["captureArea"] == nil)
        let area = Settings.screenshotDefaultHotkeys["captureArea"]!
        #expect(s.effectiveHotkeys["captureArea"] == area)
        // Assigning ⌃⇧4 to another action must be reported as a clash with "captureArea".
        #expect(HotkeyClash.firstClash(name: "textOnlyPaste", value: area, in: s.effectiveHotkeys) == "captureArea")
        // An explicitly cleared capture hotkey no longer clashes.
        s.setHotkey("captureArea", 0)
        #expect(HotkeyClash.firstClash(name: "textOnlyPaste", value: area, in: s.effectiveHotkeys) == nil)
        // A moved capture hotkey is compared at its new value.
        let moved = KeyCombo(keyCode: 0x00, modifiers: KeyCombo.cmdKey).encoded
        s.setHotkey("captureArea", moved)
        #expect(HotkeyClash.firstClash(name: "activate", value: moved, in: s.effectiveHotkeys) == "captureArea")
    }

    // MARK: sync settings changes

    private func snapshot(_ edit: (inout SyncConfigSnapshot) -> Void = { _ in }) -> SyncConfigSnapshot {
        var s = SyncConfigSnapshot(enabled: true, includeImages: true, includeRich: true, backups: true, hasPassphrase: true,
                                   folderPath: "/tmp/x", intervalMinutes: 5, deviceName: "Mac", maxTotalMB: 150, backupKeep: 7)
        edit(&s)
        return s
    }

    @Test func firstSnapshotRestarts() {
        #expect(snapshot().change(from: nil) == .restart)
    }

    @Test func deviceNameAndLimitsNeverForceASync() {
        let base = snapshot()
        // Typing a name one character at a time: every intermediate state is `.none`.
        var typed = ""
        for ch in "Work MacBook" {
            typed.append(ch)
            #expect(snapshot { $0.deviceName = typed }.change(from: base) == .none)
        }
        #expect(snapshot { $0.maxTotalMB = 60 }.change(from: base) == .none)
        #expect(snapshot { $0.backupKeep = 3 }.change(from: base) == .none)
    }

    @Test func intervalOnlyReschedules() {
        #expect(snapshot { $0.intervalMinutes = 10 }.change(from: snapshot()) == .reschedule)
    }

    @Test func structuralChangesRestart() {
        let base = snapshot()
        #expect(snapshot { $0.enabled = false }.change(from: base) == .restart)
        #expect(snapshot { $0.folderPath = "/tmp/y" }.change(from: base) == .restart)
        #expect(snapshot { $0.hasPassphrase = false }.change(from: base) == .restart)
        #expect(snapshot { $0.includeImages = false }.change(from: base) == .restart)
        #expect(snapshot { $0.includeRich = false }.change(from: base) == .restart)
        #expect(snapshot { $0.backups = false }.change(from: base) == .restart)
        // A structural change wins over a simultaneous interval change.
        #expect(snapshot { $0.enabled = false; $0.intervalMinutes = 1 }.change(from: base) == .restart)
        #expect(base.change(from: base) == .none)
    }
}
