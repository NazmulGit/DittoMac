// AnnotationTextEditor.swift — the floating inline text editor used by the text tool.
import AppKit

/// Borderless transparent NSTextView laid over the canvas. Return commits, ⇧Return inserts a newline,
/// Esc cancels (and is swallowed only while editing).
@MainActor
final class AnnotationTextEditor: NSTextView, NSTextViewDelegate {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onGrow: (() -> Void)?
    private(set) var editorFontSize: CGFloat

    init(origin: CGPoint, string: String, fontSize: CGFloat, color: NSColor, chip: Bool) {
        self.editorFontSize = fontSize
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 10_000, height: 10_000))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: CGRect(origin: origin, size: .zero), textContainer: container)
        delegate = self
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = CGSize(width: Annotation.textPadding, height: Annotation.textPadding)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        setAccessibilityLabel("Annotation text")
        style(fontSize: fontSize, color: color, chip: chip)
        self.string = string
        fit()
    }
    required init?(coder: NSCoder) { fatalError() }

    func style(fontSize: CGFloat, color: NSColor, chip: Bool) {
        editorFontSize = fontSize
        font = Annotation.font(size: fontSize)
        textColor = color
        insertionPointColor = color
        typingAttributes = [.font: Annotation.font(size: fontSize), .foregroundColor: color]
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        layer?.backgroundColor = chip
            ? (AnnotationRenderer.isLight(color) ? NSColor(white: 0, alpha: 0.7) : NSColor(white: 1, alpha: 0.88)).cgColor
            : NSColor.clear.cgColor
        // keep text storage styled when restyled mid-edit
        textStorage?.setAttributes(typingAttributes, range: NSRange(location: 0, length: (string as NSString).length))
        fit()
    }

    /// Resizes the view to the text (min one empty line).
    func fit() {
        let size = Annotation.textContentSize(string, fontSize: editorFontSize)
        let new = CGSize(width: max(size.width, 24) + 2 * Annotation.textPadding + 2, height: size.height + 2 * Annotation.textPadding)
        if frame.size != new {
            setFrameSize(new)
            onGrow?()
        }
    }

    func textDidChange(_ notification: Notification) { fit() }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSApp?.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                onCommit?()
            }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
