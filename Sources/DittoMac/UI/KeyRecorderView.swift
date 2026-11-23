import AppKit
import SwiftUI
import DittoCore

/// Click-to-record shortcut control. `value` is an encoded KeyCombo (0 = none).
@MainActor
final class KeyRecorderView: NSView {
    var value: Int = 0 { didSet { updateLabel() } }
    var onChange: ((Int) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var recording = false { didSet { updateLabel(); setSuspended(recording) } }
    private static let functionKeyCodes: Set<UInt32> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.title = "×"
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.toolTip = "Clear shortcut"
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); addSubview(clearButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Shortcut recorder")
        updateLabel()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    override func updateLayer() { applyColors() }
    override func viewDidChangeEffectiveAppearance() { applyColors() }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }

    private func updateLabel() {
        if recording {
            label.stringValue = "Type shortcut…"
            label.textColor = .secondaryLabelColor
        } else if value == 0 {
            label.stringValue = "Click to record"
            label.textColor = .tertiaryLabelColor
        } else {
            label.stringValue = KeyCombo(encoded: value).displayString
            label.textColor = .labelColor
        }
        clearButton.isHidden = value == 0 || recording
        applyColors()
        setAccessibilityValue(label.stringValue)
    }

    private func setSuspended(_ s: Bool) {
        AppState.shared?.hotkeys?.isSuspended = s
    }

    @objc private func clearTapped() { value = 0; onChange?(0) }

    override func mouseDown(with event: NSEvent) {
        if window?.makeFirstResponder(self) == true { recording = true }
    }

    override func becomeFirstResponder() -> Bool { true }
    override func resignFirstResponder() -> Bool { recording = false; return true }
    override func viewDidMoveToWindow() { if window == nil, recording { recording = false } }
    deinit { if recording { MainActor.assumeIsolated { AppState.shared?.hotkeys?.isSuspended = false } } }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return false }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let code = UInt32(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= KeyCombo.cmdKey }
        if flags.contains(.shift) { mods |= KeyCombo.shiftKey }
        if flags.contains(.option) { mods |= KeyCombo.optionKey }
        if flags.contains(.control) { mods |= KeyCombo.controlKey }
        if code == 0x35 && mods == 0 { recording = false; return }                    // Esc cancels
        if (code == 0x33 || code == 0x75) && mods == 0 { clearTapped(); recording = false; return }
        guard !KeyCombo(keyCode: code, modifiers: 0).displayString.hasPrefix("Key") else { NSSound.beep(); return }
        if mods == 0 && !Self.functionKeyCodes.contains(code) { NSSound.beep(); return }
        let combo = KeyCombo(keyCode: code, modifiers: mods)
        value = combo.encoded
        recording = false
        onChange?(value)
        window?.makeFirstResponder(nil)
    }
}

/// SwiftUI wrapper. Binding holds the encoded KeyCombo (0 = none).
struct KeyRecorder: NSViewRepresentable {
    @Binding var binding: Int
    init(binding: Binding<Int>) { _binding = binding }

    func makeNSView(context: Context) -> KeyRecorderView {
        let v = KeyRecorderView(frame: .zero)
        v.value = binding
        let b = $binding
        v.onChange = { newValue in DispatchQueue.main.async { b.wrappedValue = newValue } }
        return v
    }
    func updateNSView(_ v: KeyRecorderView, context: Context) {
        if v.value != binding { v.value = binding }
        let b = $binding
        v.onChange = { newValue in DispatchQueue.main.async { b.wrappedValue = newValue } }
    }
}
