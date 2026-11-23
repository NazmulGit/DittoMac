import AppKit
import DittoCore

private final class GroupNode: NSObject {
    let id: Int64
    let name: String
    var children: [GroupNode] = []
    init(id: Int64, name: String) { self.id = id; self.name = name }
}

/// Window with an outline of nested groups plus "Top level". completion(nil) = cancelled, -1 = top level.
@MainActor
final class GroupPickerController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
    private let store: ClipStore
    private weak var router: WindowRouting?
    private let outline = NSOutlineView()
    private var root = GroupNode(id: -1, name: "Top level")
    private var completion: ((Int64?) -> Void)?
    private var okButton: NSButton!
    var onFinish: (() -> Void)?

    init(store: ClipStore, router: WindowRouting, title: String, completion: @escaping (Int64?) -> Void) {
        self.store = store
        self.router = router
        self.completion = completion
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.minSize = NSSize(width: 260, height: 280)
        super.init(window: w)
        w.delegate = self
        build()
        reload(select: -1)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Group"
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(ok)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let newBtn = NSButton(title: "New Group…", target: self, action: #selector(newGroup))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        okButton = NSButton(title: "OK", target: self, action: #selector(ok))
        okButton.keyEquivalent = "\r"
        let spacer = NSView()
        let row = NSStackView(views: [newBtn, spacer, cancel, okButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll); content.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func reload(select id: Int64) {
        let groups = (try? store.groups()) ?? []
        var nodes: [Int64: GroupNode] = [:]
        for g in groups { nodes[g.id] = GroupNode(id: g.id, name: g.text.isEmpty ? "(unnamed)" : g.text) }
        root = GroupNode(id: -1, name: "Top level")
        for g in groups {
            guard let n = nodes[g.id] else { continue }
            if g.parentID != -1, g.parentID != g.id, let p = nodes[g.parentID] { p.children.append(n) } else { root.children.append(n) }
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        func find(_ n: GroupNode) -> GroupNode? {
            if n.id == id { return n }
            for c in n.children { if let f = find(c) { return f } }
            return nil
        }
        // Guard against cycles from corrupt data: outline expansion is bounded by data size.
        if let n = find(root) {
            let row = outline.row(forItem: n)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
        }
    }

    // MARK: outline
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 1 : (item as? GroupNode)?.children.count ?? 0
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? root : (item as! GroupNode).children[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? GroupNode)?.children.isEmpty ?? true) }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? GroupNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (o.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView(); c.identifier = id
            let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv); c.addSubview(tf); c.imageView = iv; c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2), iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4), tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = n.name
        cell.imageView?.image = NSImage(systemSymbolName: n.id == -1 ? "tray.full" : "folder", accessibilityDescription: nil)
        return cell
    }

    // MARK: actions
    @objc private func ok() {
        let row = outline.selectedRow
        guard row >= 0, let n = outline.item(atRow: row) as? GroupNode else { NSSound.beep(); return }
        finish(n.id)
    }
    @objc private func cancel() { finish(nil) }

    @objc private func newGroup() {
        let parent = (outline.item(atRow: outline.selectedRow) as? GroupNode)?.id ?? -1
        router?.promptText(title: "New Group", message: "Name for the new group:", defaultValue: "") { [weak self] name in
            guard let self, let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            do {
                let id = try self.store.createGroup(name: name, parentID: parent)
                AppState.shared?.clipsChanged()
                self.reload(select: id)
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private func finish(_ id: Int64?) {
        guard let c = completion else { return }
        completion = nil
        window?.orderOut(nil)
        c(id)
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        if let c = completion { completion = nil; c(nil); onFinish?() }
    }
}
