import AppKit
import DittoCore

/// Simple line diff (LCS) used by the compare window.
enum LineDiff {
    enum Op: Equatable { case equal(String), removed(String), added(String) }
    static let maxLines = 5000
    private static let maxCells = 16_000_000

    static func diff(_ a: [String], _ b: [String]) -> [Op] {
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var ea = a.count, eb = b.count
        while ea > start, eb > start, a[ea - 1] == b[eb - 1] { ea -= 1; eb -= 1 }
        var ops: [Op] = a[0..<start].map { .equal($0) }
        let am = Array(a[start..<ea]), bm = Array(b[start..<eb])
        let n = am.count, m = bm.count
        if n == 0 { ops += bm.map { .added($0) } }
        else if m == 0 { ops += am.map { .removed($0) } }
        else if n * m > maxCells || n >= Int(UInt16.max) || m >= Int(UInt16.max) {
            ops += am.map { .removed($0) }; ops += bm.map { .added($0) }
        } else {
            // lcs[i][j] = LCS length of am[i...], bm[j...]
            let w = m + 1
            var t = [UInt16](repeating: 0, count: (n + 1) * w)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    t[i * w + j] = am[i] == bm[j] ? t[(i + 1) * w + j + 1] + 1 : max(t[(i + 1) * w + j], t[i * w + j + 1])
                }
            }
            var i = 0, j = 0
            while i < n && j < m {
                if am[i] == bm[j] { ops.append(.equal(am[i])); i += 1; j += 1 }
                else if t[(i + 1) * w + j] >= t[i * w + j + 1] { ops.append(.removed(am[i])); i += 1 }
                else { ops.append(.added(bm[j])); j += 1 }
            }
            while i < n { ops.append(.removed(am[i])); i += 1 }
            while j < m { ops.append(.added(bm[j])); j += 1 }
        }
        ops += a[ea...].map { .equal($0) }
        return ops
    }
}

@MainActor
final class CompareWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let leftView = NSTextView()
    private let rightView = NSTextView()
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "")
    private var syncing = false
    private var observers: [NSObjectProtocol] = []

    init(state: AppState, leftID: Int64, rightID: Int64) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Compare Clips"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 300)
        super.init(window: w)
        w.delegate = self
        build()
        let l = Self.lines(state: state, id: leftID), r = Self.lines(state: state, id: rightID)
        render(left: l, right: r)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private static func lines(state: AppState, id: Int64) -> (lines: [String], truncated: Bool) {
        var text = ""
        if let d = (try? state.store.data(clipID: id, type: ClipUTI.plainText)) ?? nil {
            text = String(decoding: d.prefix(20_000_000), as: UTF8.self)
        } else if let d = (try? state.store.data(clipID: id, type: ClipUTI.rtf)) ?? nil,
                  let a = NSAttributedString(rtf: d, documentAttributes: nil) {
            text = a.string
        } else if let c = (try? state.store.clip(id: id)) ?? nil { text = c.text }
        var ls = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).prefix(LineDiff.maxLines + 1).map(String.init)
        let trunc = ls.count > LineDiff.maxLines
        if trunc { ls = Array(ls.prefix(LineDiff.maxLines)) }
        return (ls, trunc)
    }

    private func configure(_ tv: NSTextView, _ sv: NSScrollView, label: String) {
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = []
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.setAccessibilityLabel(label)
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.borderType = .bezelBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.contentView.postsBoundsChangedNotifications = true
    }

    private func build() {
        guard let content = window?.contentView else { return }
        configure(leftView, leftScroll, label: "Left clip")
        configure(rightView, rightScroll, label: "Right clip")
        summary.textColor = .secondaryLabelColor
        summary.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [leftScroll, rightScroll])
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack); content.addSubview(summary)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -8),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            summary.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        for (src, dst) in [(leftScroll, rightScroll), (rightScroll, leftScroll)] {
            let o = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: src.contentView, queue: .main) { [weak self, weak src, weak dst] _ in
                MainActor.assumeIsolated {
                    guard let self, let src, let dst, !self.syncing else { return }
                    self.syncing = true
                    dst.contentView.scroll(to: src.contentView.bounds.origin)
                    dst.reflectScrolledClipView(dst.contentView)
                    self.syncing = false
                }
            }
            observers.append(o)
        }
    }

    private func render(left: (lines: [String], truncated: Bool), right: (lines: [String], truncated: Bool)) {
        let ops = LineDiff.diff(left.lines, right.lines)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let red = NSColor.systemRed.withAlphaComponent(0.25), green = NSColor.systemGreen.withAlphaComponent(0.25)
        let gray = NSColor.gray.withAlphaComponent(0.12)
        let L = NSMutableAttributedString(), R = NSMutableAttributedString()
        func add(_ s: NSMutableAttributedString, _ text: String, _ bg: NSColor?) {
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            if let bg { a[.backgroundColor] = bg }
            s.append(NSAttributedString(string: text + "\n", attributes: a))
        }
        var removed = 0, added = 0
        for op in ops {
            switch op {
            case .equal(let t): add(L, t, nil); add(R, t, nil)
            case .removed(let t): add(L, t, red); add(R, "", gray); removed += 1
            case .added(let t): add(L, "", gray); add(R, t, green); added += 1
            }
        }
        leftView.textStorage?.setAttributedString(L)
        rightView.textStorage?.setAttributedString(R)
        var s = ops.isEmpty || (removed == 0 && added == 0) ? "The clips have identical text." : "\(removed) line(s) only on the left (red), \(added) line(s) only on the right (green)."
        if left.truncated || right.truncated { s += " Compared the first \(LineDiff.maxLines) lines only." }
        summary.stringValue = s
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
