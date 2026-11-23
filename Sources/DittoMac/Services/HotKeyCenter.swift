// HotKeyCenter.swift — global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).

import AppKit
import Carbon.HIToolbox
import DittoCore

/// Carbon event callback. Hot key events are delivered on the main thread; we hop through the main queue
/// so handlers never run re-entrantly inside the Carbon dispatcher.
private func dittoHotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hkID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    guard status == noErr, hkID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
    let id = hkID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotKeyCenter.current?.fire(id: id) }
    }
    return noErr
}

@MainActor
final class HotKeyCenter: HotKeyRegistering {
    nonisolated static let signature: OSType = 0x444D_4143 // 'DMAC'
    fileprivate static weak var current: HotKeyCenter?

    private struct Entry {
        var id: UInt32
        var combo: KeyCombo
        var ref: EventHotKeyRef?
        var handler: () -> Void
    }

    private var entries: [String: Entry] = [:]
    private var idToName: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    var isSuspended = false {
        didSet {
            guard oldValue != isSuspended else { return }
            if isSuspended {
                for name in entries.keys { osUnregister(name) }
            } else {
                for name in entries.keys { _ = osRegister(name) }
            }
        }
    }

    init() {
        HotKeyCenter.current = self
        installHandler()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), dittoHotKeyEventHandler, 1, &spec, nil, &eventHandler)
    }

    @discardableResult
    func register(name: String, combo: KeyCombo, handler: @escaping () -> Void) -> Bool {
        unregister(name: name)
        guard combo.encoded != 0 else { return false }
        let id = nextID
        nextID &+= 1
        entries[name] = Entry(id: id, combo: combo, ref: nil, handler: handler)
        idToName[id] = name
        if isSuspended { return true }
        let ok = osRegister(name)
        if !ok {
            entries[name] = nil
            idToName[id] = nil
        }
        return ok
    }

    func unregister(name: String) {
        guard let e = entries[name] else { return }
        osUnregister(name)
        idToName[e.id] = nil
        entries[name] = nil
    }

    func unregisterAll(withPrefix prefix: String) {
        for name in entries.keys where name.hasPrefix(prefix) { unregister(name: name) }
    }

    /// Names currently registered (for diagnostics / the Keyboard preferences page).
    var registeredNames: [String] { entries.keys.sorted() }

    fileprivate func fire(id: UInt32) {
        guard !isSuspended, let name = idToName[id], let e = entries[name] else { return }
        e.handler()
    }

    private func osRegister(_ name: String) -> Bool {
        guard var e = entries[name] else { return false }
        if e.ref != nil { return true }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: e.id)
        let status = RegisterEventHotKey(e.combo.keyCode, e.combo.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        e.ref = ref
        entries[name] = e
        return true
    }

    private func osUnregister(_ name: String) {
        guard var e = entries[name], let ref = e.ref else { return }
        UnregisterEventHotKey(ref)
        e.ref = nil
        entries[name] = e
    }
}

extension KeyCombo {
    /// Carbon modifier mask from AppKit modifier flags.
    static func dmCarbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= KeyCombo.cmdKey }
        if flags.contains(.shift) { m |= KeyCombo.shiftKey }
        if flags.contains(.option) { m |= KeyCombo.optionKey }
        if flags.contains(.control) { m |= KeyCombo.controlKey }
        return m
    }

    /// AppKit modifier flags from the Carbon mask.
    var dmModifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & KeyCombo.cmdKey != 0 { f.insert(.command) }
        if modifiers & KeyCombo.shiftKey != 0 { f.insert(.shift) }
        if modifiers & KeyCombo.optionKey != 0 { f.insert(.option) }
        if modifiers & KeyCombo.controlKey != 0 { f.insert(.control) }
        return f
    }

    /// Combo for a key-down event (used to match local clip shortcuts in the popup).
    init(dmEvent event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: KeyCombo.dmCarbonModifiers(from: event.modifierFlags))
    }
}
