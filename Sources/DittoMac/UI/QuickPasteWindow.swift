// QuickPasteWindow.swift — the Quick Paste popup: panel, layout, show/hide, positioning, data loading,
// search, groups sidebar. Actions live in QuickPasteActions.swift, keyboard in QuickPasteKeyboard.swift.

import AppKit
import ApplicationServices
import DittoCore

// MARK: - Panel

@MainActor
final class QuickPastePanel: NSPanel {
    weak var controller: QuickPasteController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Every key-down goes through the controller first so popup shortcuts work regardless of focus.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let c = controller, c.handleKeyDown(event) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { controller?.escapePressed(force: false) }

    override func performClose(_ sender: Any?) { controller?.hide(restoreFocus: true) }
}

// MARK: - Group tree node

final class QuickPasteGroupNode: NSObject {
    let id: Int64?          // nil = History root
    let name: String
    var children: [QuickPasteGroupNode] = []
    init(id: Int64?, name: String) { self.id = id; self.name = name }
}

// MARK: - Controller

@MainActor
final class QuickPasteController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSplitViewDelegate {

    let state: AppState
    var settings: Settings { state.settings }
    var store: ClipStore { state.store }

    let panel: QuickPastePanel
    let searchField = NSSearchField()
    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let backButton = NSButton()
    let tableView = ClipTableView()
    let tableScroll = NSScrollView()
    let outlineView = NSOutlineView()
    let sidebarScroll = NSScrollView()
    let splitView = NSSplitView()
    let statusLabel = NSTextField(labelWithString: "")
    let gearButton = NSButton()
    let moreButton = NSButton()
    private let tableMenu = NSMenu()
    private let gearMenu = NSMenu()
    private let moreMenu = NSMenu()
    lazy var contextMenu = ClipContextMenu(controller: self)

    // Data
    static let pageSize = 500
    private(set) var clips: [Clip] = []
    private(set) var totalCount = 0
    private var kindCache: [Int64: ClipKind] = [:]
    private var summaryCache: [Int64: ClipFormatSummary] = [:]
    private var loadingMore = false
    private var dirty = true
    private var groupRoots: [QuickPasteGroupNode] = []
    private var syncingSidebar = false

    // Navigation
    var currentGroupID: Int64? { didSet { if oldValue != currentGroupID { lastGroupID = oldValue ?? Ditto.topLevelParent } } }
    private(set) var lastGroupID: Int64?
    var currentGroupName: String?

    // Search
    private var searchDebounce: DispatchWorkItem?
    private var appliedSearchText = ""
    var isSearchPending: Bool { searchField.stringValue != appliedSearchText }
    var isFiltered: Bool { !appliedSearchText.isEmpty }
    private(set) var highlighter: QuickPasteHighlighter?

    // Hotkey hold-to-cycle
    private var pasteOnModifierRelease = false
    private var flagsMonitor: Any?
    private var appObservers: [NSObjectProtocol] = []

    /// Local (in-popup) clip shortcuts: encoded combo → clip.
    var localShortcuts: [Int: Clip] = [:]
    var localMoveToGroupShortcuts: [Int: Clip] = [:]

    private let sidebarKey = "quickPasteShowGroupsSidebar"

    var isVisible: Bool { panel.isVisible }
    var isGroupsSidebarVisible: Bool { !sidebarScroll.isHidden }
    var hasLastGroup: Bool { lastGroupID != nil }

    init(state: AppState) {
        self.state = state
        let rect = NSRect(x: 0, y: 0, width: state.settings.popupWidth, height: state.settings.popupHeight)
        panel = QuickPastePanel(contentRect: rect, styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                                backing: .buffered, defer: true)
        super.init()
        panel.controller = self
        panel.delegate = self
        panel.title = "DittoMac"
        panel.titleVisibility = .visible
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 220, height: 160)
        panel.animationBehavior = .utilityWindow
        buildUI()
        applySettings()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(clipsChangedNote), name: .dittoClipsChanged, object: nil)
        nc.addObserver(self, selector: #selector(settingsChangedNote), name: .dittoSettingsChanged, object: nil)
        nc.addObserver(self, selector: #selector(connectionChangedNote), name: .dittoConnectionChanged, object: nil)
        appObservers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appResignedActive() }
        })

        state.showQuickPaste = { [weak self] groupID in self?.show(groupID: groupID) }
        state.hideQuickPaste = { [weak self] in self?.hide(restoreFocus: false) }
    }

    // MARK: UI construction

    private func buildUI() {
        guard let content = panel.contentView else { return }

        // Search row.
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.maximumRecents = Settings.maxSearchHistory
        searchField.focusRingType = .none
        searchField.controlSize = .regular
        searchField.translatesAutoresizingMaskIntoConstraints = false

        modePopup.controlSize = .small
        modePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modePopup.addItems(withTitles: ["Wildcard", "Contains", "Regex"])
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.toolTip = "Search mode"
        modePopup.translatesAutoresizingMaskIntoConstraints = false
        modePopup.setContentHuggingPriority(.required, for: .horizontal)

        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to parent group")
        backButton.bezelStyle = .texturedRounded
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(backClicked(_:))
        backButton.toolTip = "Back to parent group (⌘↑)"
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setContentHuggingPriority(.required, for: .horizontal)

        let searchRow = NSStackView(views: [backButton, searchField, modePopup])
        searchRow.orientation = .horizontal
        searchRow.spacing = 6
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        // Table.
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.gridStyleMask = []
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.onCopy = { [weak self] in self?.copySelection() }
        tableMenu.delegate = self
        tableView.menu = tableMenu
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = true
        NotificationCenter.default.addObserver(self, selector: #selector(tableScrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: tableScroll.contentView)
        tableScroll.contentView.postsBoundsChangedNotifications = true

        // Sidebar.
        let gcol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        outlineView.addTableColumn(gcol)
        outlineView.outlineTableColumn = gcol
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.indentationPerLevel = 12
        outlineView.rowSizeStyle = .small
        sidebarScroll.documentView = outlineView
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.borderType = .noBorder
        sidebarScroll.drawsBackground = false

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebarScroll)
        splitView.addArrangedSubview(tableScroll)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.isHidden = !settings.defaults.bool(forKey: sidebarKey)

        // Status row.
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (b, sym, tip, act) in [(gearButton, "gearshape", "Clip actions", #selector(gearClicked(_:))),
                                   (moreButton, "ellipsis.circle", "More", #selector(moreClicked(_:)))] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            b.isBordered = false
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            b.target = self
            b.action = act
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        gearMenu.delegate = self
        moreMenu.delegate = self
        let statusRow = NSStackView(views: [statusLabel, gearButton, moreButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(searchRow)
        content.addSubview(splitView)
        content.addSubview(statusRow)
        let guide = content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            searchRow.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            searchRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            searchRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            splitView.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 6),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusRow.topAnchor.constraint(equalTo: splitView.bottomAnchor, constant: 3),
            statusRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            statusRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            statusRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            statusRow.heightAnchor.constraint(equalToConstant: 18),
            sidebarScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        DispatchQueue.main.async { [weak self] in self?.splitView.setPosition(150, ofDividerAt: 0) }
        rebuildSearchMenu()
        syncModePopup()
    }

    // MARK: Settings / theme

    func applySettings() {
        let theme = AppTheme.current
        panel.appearance = theme.appearance
        panel.backgroundColor = theme.windowBackground
        panel.alphaValue = CGFloat(1 - Double(settings.transparencyPercent) / 100)
        panel.level = settings.alwaysOnTop ? .floating : .normal
        tableView.backgroundColor = theme.listBackground
        tableScroll.backgroundColor = theme.listBackground
        outlineView.backgroundColor = theme.groupTreeBackground
        statusLabel.textColor = theme.captionText
        tableView.rowHeight = rowHeight()
        syncModePopup()
        rebuildSearchMenu()
        updateTitle()
        updateStatus()
    }

    func rowHeight() -> CGFloat {
        let f = AppTheme.listFont(settings)
        let lineH = ceil(f.ascender - f.descender + f.leading)
        return max(lineH * CGFloat(settings.linesPerRow) + 6, 20)
    }

    @objc private func settingsChangedNote() {
        applySettings()
        tableView.reloadData()
    }

    @objc private func connectionChangedNote() {
        updateTitle()
        updateStatus()
    }

    @objc private func clipsChangedNote() {
        dirty = true
        guard panel.isVisible else { return }
        // Coalesce bursts of changes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dirty, self.panel.isVisible else { return }
            self.reload(keepSelection: true)
            self.reloadSidebar()
        }
    }

    // MARK: Show / hide

    /// Shows the popup (recording the paste target first) or brings it forward.
    func show(groupID: Int64?) {
        if !panel.isVisible || !NSApp.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                state.paste.targetApp = front
            }
        }
        let caret = settings.popupPosition == .caret && !panel.isVisible ? Self.caretRect(paste: state.paste) : nil

        if !panel.isVisible {
            if !settings.maintainSearchView {
                searchField.stringValue = ""
                appliedSearchText = ""
                highlighter = nil
            }
            if settings.revertToTopLevelGroup { setGroup(nil, reload: false) }
            if settings.openToGroupByActiveApp, let name = state.paste.targetApp?.localizedName,
               let g = (try? store.groups())?.first(where: { $0.text.caseInsensitiveCompare(name) == .orderedSame }) {
                setGroup(g.id, reload: false)
            }
        }
        if let groupID { setGroup(groupID == Ditto.topLevelParent ? nil : groupID, reload: false) }

        refreshLocalShortcuts()
        if !panel.isVisible { positionPanel(caret: caret) }
        applySettings()
        reload(keepSelection: false)
        if isGroupsSidebarVisible { reloadSidebar() }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tableView)
        installFlagsMonitor()
    }

    func hide(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        saveFrame()
        removeFlagsMonitor()
        pasteOnModifierRelease = false
        searchDebounce?.cancel()
        panel.orderOut(nil)
        if settings.revertToTopLevelGroup { setGroup(nil, reload: false) }
        if restoreFocus { restoreTargetFocus() }
    }

    /// Re-activates the previous app if no other DittoMac window needs focus.
    func restoreTargetFocus() {
        let others = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeKey }
        guard !others, let target = state.paste.targetApp, !target.isTerminated else { return }
        if #available(macOS 14.0, *) { target.activate() } else { target.activate(options: [.activateIgnoringOtherApps]) }
    }

    private func appResignedActive() {
        guard panel.isVisible, !settings.alwaysOnTop else { return }
        hide(restoreFocus: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide(restoreFocus: true)
        return false
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { if panel.isVisible { saveFrame() } }

    private func saveFrame() {
        let f = panel.frame
        settings.popupWidth = Int(f.width)
        settings.popupHeight = Int(f.height)
        settings.popupX = Double(f.minX)
        settings.popupY = Double(f.maxY)
    }

    // MARK: Positioning

    private func positionPanel(caret: NSRect?) {
        let size = NSSize(width: CGFloat(settings.popupWidth), height: CGFloat(settings.popupHeight))
        let mouse = NSEvent.mouseLocation
        var topLeft = mouse
        switch settings.popupPosition {
        case .caret:
            if let c = caret { topLeft = NSPoint(x: c.minX, y: c.minY - 2) }
        case .cursor:
            break
        case .previous:
            if let x = settings.popupX, let y = settings.popupY { topLeft = NSPoint(x: x, y: y) }
        }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(topLeft, $0.frame, false) })
            ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: min(size.width, vf.width), height: min(size.height, vf.height))
        if let c = caret, settings.popupPosition == .caret, frame.minY < vf.minY, c.maxY + 2 + frame.height <= vf.maxY {
            frame.origin.y = c.maxY + 2   // no room below the caret: open above it
        }
        frame.origin.x = min(max(frame.origin.x, vf.minX), vf.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, vf.minY), vf.maxY - frame.height)
        panel.setFrame(frame, display: false)
    }

    /// Caret rectangle (Cocoa screen coordinates) of the focused text element via Accessibility.
    static func caretRect(paste: PasteServicing) -> NSRect? {
        guard paste.isAccessibilityTrusted(prompt: false) else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeRef, &boundsRef) == .success,
              let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.origin != .zero || rect.size != .zero else { return nil }
        // AX uses top-left origin on the primary screen; flip to Cocoa coordinates.
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = NSRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: max(rect.width, 1), height: max(rect.height, 1))
        guard NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) else { return nil }
        return flipped
    }

    // MARK: Hold-modifier-and-repeat (activate hotkey)

    /// Called by the activate hotkey(s).
    func activateHotkeyPressed() {
        if panel.isVisible && panel.isKeyWindow && NSApp.isActive {
            let held = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            if settings.moveSelectionOnOpenHotkey && !held.isEmpty {
                moveSelection(by: 1)
                pasteOnModifierRelease = true
                return
            }
            if settings.hideOnHotKeyIfAlreadyShown {
                hide(restoreFocus: true)
            }
            return
        }
        show(groupID: nil)
    }

    private func installFlagsMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event) }
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
    }

    private func flagsChanged(_ event: NSEvent) {
        guard pasteOnModifierRelease else { return }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            pasteOnModifierRelease = false
            pasteSelection(transform: nil)
        }
    }

    // MARK: Data

    func buildSearchQuery() -> SearchQuery? {
        let text = appliedSearchText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var q = SearchQuery(text, mode: SearchQuery.Mode(rawValue: settings.searchMode.rawValue) ?? .wildcard)
        q.searchDescription = settings.searchDescription
        q.searchFullText = settings.searchFullText
        q.searchQuickPaste = settings.searchQuickPaste
        q.caseInsensitive = q.mode == .regex ? settings.regexCaseInsensitive : true
        return q
    }

    private func buildFilter(offset: Int) -> ClipFilter {
        ClipFilter(parentID: currentGroupID, showAllClipsInMainList: settings.showAllClipsInMainList,
                   showGroupsInMainList: settings.showGroupsInMainList, search: buildSearchQuery(),
                   limit: Self.pageSize, offset: offset)
    }

    func reload(keepSelection: Bool) {
        dirty = false
        let keepIDs = keepSelection ? Set(selectedIDs) : []
        let firstSelRow = tableView.selectedRow
        let f = buildFilter(offset: 0)
        let q = f.search
        highlighter = q.flatMap { QuickPasteHighlighter(query: $0) }
        clips = (try? store.clips(f)) ?? []
        totalCount = clips.count < Self.pageSize ? clips.count : ((try? store.count(f)) ?? clips.count)
        kindCache.removeAll(keepingCapacity: true)
        summaryCache.removeAll(keepingCapacity: true)
        tableView.reloadData()
        var rows = IndexSet()
        if !keepIDs.isEmpty {
            for (i, c) in clips.enumerated() where keepIDs.contains(c.id) { rows.insert(i) }
        }
        if rows.isEmpty, !clips.isEmpty {
            rows.insert(keepSelection && firstSelRow >= 0 ? min(firstSelRow, clips.count - 1) : 0)
        }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let r = rows.first { tableView.scrollRowToVisible(r) }
        updateBackButton()
        updateTitle()
        updateStatus()
    }

    private func loadMoreIfNeeded(row: Int) {
        guard !loadingMore, clips.count < totalCount, row >= clips.count - 60 else { return }
        loadingMore = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.loadingMore = false }
            let more = (try? self.store.clips(self.buildFilter(offset: self.clips.count))) ?? []
            guard !more.isEmpty else { self.totalCount = self.clips.count; return }
            let start = self.clips.count
            self.clips.append(contentsOf: more)
            self.tableView.insertRows(at: IndexSet(start..<self.clips.count), withAnimation: [])
            self.updateStatus()
        }
    }

    @objc private func tableScrolled(_ note: Notification) {
        let visible = tableView.rows(in: tableScroll.contentView.bounds)
        if visible.length > 0 { loadMoreIfNeeded(row: visible.location + visible.length) }
    }

    var selectedClips: [Clip] {
        tableView.selectedRowIndexes.compactMap { $0 < clips.count ? clips[$0] : nil }
    }

    var selectedIDs: [Int64] { selectedClips.map(\.id) }

    func clip(atRow row: Int) -> Clip? { row >= 0 && row < clips.count ? clips[row] : nil }

    func kind(of clip: Clip) -> ClipKind {
        if let k = kindCache[clip.id] { return k }
        let types = ((try? store.formatTypes(clipID: clip.id)) ?? []).map(\.type)
        let k = ClipKind.classify(types: types, isGroup: clip.isGroup)
        kindCache[clip.id] = k
        summaryCache[clip.id] = ClipFormatSummary(types: types)
        return k
    }

    /// Which kinds of content the clip carries (rich text / image indicators on rows).
    func formatSummary(of clip: Clip) -> ClipFormatSummary {
        if let s = summaryCache[clip.id] { return s }
        _ = kind(of: clip)
        return summaryCache[clip.id] ?? ClipFormatSummary(types: [])
    }

    func refreshLocalShortcuts() {
        localShortcuts.removeAll()
        localMoveToGroupShortcuts.removeAll()
        for c in (try? store.clipsWithShortcuts()) ?? [] {
            if c.shortcut != 0 { localShortcuts[c.shortcut] = c }
            if c.moveToGroupShortcut != 0, c.isGroup { localMoveToGroupShortcuts[c.moveToGroupShortcut] = c }
        }
    }

    // MARK: Navigation

    func setGroup(_ id: Int64?, reload doReload: Bool = true) {
        currentGroupID = id
        if let id, let g = try? store.clip(id: id) { currentGroupName = g.text } else { currentGroupName = nil }
        if doReload {
            reload(keepSelection: false)
            syncSidebarSelection()
        }
    }

    func enterGroup(id: Int64) {
        if !settings.maintainSearchView { clearSearch(reload: false) }
        setGroup(id)
    }

    func goBack() {
        guard let gid = currentGroupID else { return }
        let parent = (try? store.clip(id: gid))?.parentID ?? Ditto.topLevelParent
        let previous = gid
        setGroup(parent <= 0 ? nil : parent)
        if let row = clips.firstIndex(where: { $0.id == previous }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    func goHome() { setGroup(nil) }

    func toggleLastGroup() {
        guard let last = lastGroupID else { return }
        setGroup(last == -1 ? nil : last)
    }

    private func updateBackButton() {
        backButton.isHidden = currentGroupID == nil
    }

    func updateTitle() {
        var t = "DittoMac"
        if let name = currentGroupName, currentGroupID != nil { t += " – \(name)" }
        if !(state.monitor?.isConnected ?? true) { t += " [Disconnected]" }
        panel.title = t
    }

    func updateStatus() {
        var parts: [String] = []
        let sel = tableView.selectedRowIndexes
        let pos = sel.count > 1 ? "\(sel.count) selected" : (sel.first.map { "\($0 + 1)" } ?? "0")
        parts.append("\(pos) / \(totalCount)")
        if let target = state.paste?.targetApp?.localizedName { parts.append("Target: \(target)") }
        if let name = currentGroupName, currentGroupID != nil { parts.append("Group: \(name)") }
        if isFiltered { parts.append("Filtered") }
        var s = parts.joined(separator: " · ")
        if !(state.monitor?.isConnected ?? true) { s += " [Disconnected]" }
        if settings.alwaysOnTop { s += " [Always on top]" }
        statusLabel.stringValue = s
    }

    func moveSelection(by delta: Int) {
        guard !clips.isEmpty else { return }
        let cur = tableView.selectedRowIndexes.last ?? -1
        var next = cur + delta
        if next >= clips.count { next = 0 } else if next < 0 { next = clips.count - 1 }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        searchDebounce?.cancel()
        guard settings.findAsYouType else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runSearchNow(recordHistory: false) }
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        // Recent-search pick, cancel button, or Enter with a non-intercepted path.
        runSearchNow(recordHistory: true)
    }

    func runSearchNow(recordHistory: Bool) {
        searchDebounce?.cancel()
        appliedSearchText = searchField.stringValue
        if recordHistory { recordSearchHistory() }
        reload(keepSelection: false)
    }

    func recordSearchHistory() {
        let t = appliedSearchText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        settings.addSearchHistory(t)
        searchField.recentSearches = settings.searchHistory
    }

    func clearSearch(reload doReload: Bool = true) {
        searchDebounce?.cancel()
        searchField.stringValue = ""
        let changed = !appliedSearchText.isEmpty
        appliedSearchText = ""
        highlighter = nil
        if doReload && changed { reload(keepSelection: false) }
    }

    func focusSearch(seed: String? = nil) {
        panel.makeFirstResponder(searchField)
        if let seed {
            searchField.stringValue += seed
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        }
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
        }
    }

    var isSearchFocused: Bool {
        if panel.firstResponder === searchField { return true }
        if let tv = panel.firstResponder as? NSText, tv.delegate === searchField { return true }
        return false
    }

    private func syncModePopup() {
        switch settings.searchMode {
        case .wildcard: modePopup.selectItem(at: 0)
        case .contains: modePopup.selectItem(at: 1)
        case .regex: modePopup.selectItem(at: 2)
        }
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        let modes: [SearchMode] = [.wildcard, .contains, .regex]
        settings.searchMode = modes[max(0, min(sender.indexOfSelectedItem, 2))]
        rebuildSearchMenu()
        if isFiltered { reload(keepSelection: false) }
    }

    /// Cycles wildcard → contains → regex.
    func cycleSearchMode() {
        let modes: [SearchMode] = [.wildcard, .contains, .regex]
        let i = modes.firstIndex(of: settings.searchMode) ?? 0
        settings.searchMode = modes[(i + 1) % modes.count]
        syncModePopup()
        rebuildSearchMenu()
        state.message("Search mode: \(settings.searchMode.rawValue.capitalized)")
        if isFiltered { reload(keepSelection: false) }
    }

    func rebuildSearchMenu() {
        let m = NSMenu(title: "Search")
        func add(_ title: String, _ sel: Selector, tag: Int, on: Bool) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.tag = tag
            it.state = on ? .on : .off
            m.addItem(it)
        }
        let header = NSMenuItem(title: "Search In", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        add("Description", #selector(scopeToggled(_:)), tag: 0, on: settings.searchDescription)
        add("Full Text", #selector(scopeToggled(_:)), tag: 1, on: settings.searchFullText)
        add("Quick Paste Text", #selector(scopeToggled(_:)), tag: 2, on: settings.searchQuickPaste)
        m.addItem(.separator())
        let mh = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        mh.isEnabled = false
        m.addItem(mh)
        add("Wildcard (AND / OR / NOT, *)", #selector(modeMenuPicked(_:)), tag: 0, on: settings.searchMode == .wildcard)
        add("Contains", #selector(modeMenuPicked(_:)), tag: 1, on: settings.searchMode == .contains)
        add("Regular Expression", #selector(modeMenuPicked(_:)), tag: 2, on: settings.searchMode == .regex)
        m.addItem(.separator())
        let rt = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
        rt.tag = NSSearchField.recentsTitleMenuItemTag
        m.addItem(rt)
        let ri = NSMenuItem(title: "Item", action: nil, keyEquivalent: "")
        ri.tag = NSSearchField.recentsMenuItemTag
        m.addItem(ri)
        let nr = NSMenuItem(title: "No Recent Searches", action: nil, keyEquivalent: "")
        nr.tag = NSSearchField.noRecentsMenuItemTag
        m.addItem(nr)
        let cr = NSMenuItem(title: "Clear Recent Searches", action: #selector(clearRecents(_:)), keyEquivalent: "")
        cr.target = self
        cr.tag = NSSearchField.clearRecentsMenuItemTag
        m.addItem(cr)
        searchField.searchMenuTemplate = m
        searchField.recentSearches = settings.searchHistory
    }

    @objc private func scopeToggled(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: settings.searchDescription.toggle()
        case 1: settings.searchFullText.toggle()
        default: settings.searchQuickPaste.toggle()
        }
        if !settings.searchDescription && !settings.searchFullText && !settings.searchQuickPaste { settings.searchDescription = true }
        rebuildSearchMenu()
        if isFiltered { reload(keepSelection: false) }
    }

    @objc private func modeMenuPicked(_ sender: NSMenuItem) {
        let modes: [SearchMode] = [.wildcard, .contains, .regex]
        settings.searchMode = modes[max(0, min(sender.tag, 2))]
        syncModePopup()
        rebuildSearchMenu()
        if isFiltered { reload(keepSelection: false) }
    }

    @objc private func clearRecents(_ sender: Any?) {
        settings.searchHistory = []
        searchField.recentSearches = []
    }

    // MARK: Buttons

    @objc private func backClicked(_ sender: Any?) { goBack() }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        pasteSelection(transform: nil)
    }

    @objc private func gearClicked(_ sender: NSButton) {
        contextMenu.buildClipMenu(into: gearMenu)
        gearMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func moreClicked(_ sender: NSButton) {
        contextMenu.buildMoreMenu(into: moreMenu)
        moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tableMenu { contextMenu.buildClipMenu(into: menu) }
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === self.tableView ? clips.count : 0
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("ClipRow")
        let rv = (tableView.makeView(withIdentifier: id, owner: nil) as? ClipRowView) ?? {
            let v = ClipRowView()
            v.identifier = id
            return v
        }()
        rv.rowIndex = row
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let clip = clip(atRow: row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: ClipCellView.identifier, owner: nil) as? ClipCellView) ?? {
            let v = ClipCellView()
            v.identifier = ClipCellView.identifier
            return v
        }()
        cell.font = AppTheme.listFont(settings)
        cell.linesPerRow = settings.linesPerRow
        let k = kind(of: clip)
        var thumb: NSImage?
        if settings.drawThumbnails, k == .image {
            let maxPixel = Int(tableView.rowHeight * 2 * 2.5)
            thumb = ClipThumbnailCache.shared.thumbnail(for: clip.id, maxPixel: max(maxPixel, 64), store: store) { [weak self] id in
                guard let self, let r = self.clips.firstIndex(where: { $0.id == id }) else { return }
                self.tableView.reloadData(forRowIndexes: IndexSet(integer: r), columnIndexes: IndexSet(integer: 0))
            }
        }
        var indexLabel: String?
        if settings.showFirstTenIndex, row < 10 {
            indexLabel = "\((row + settings.firstTenHotKeysStart) % 10)"
        }
        cell.model = ClipRowModel(
            clip: clip, row: row, kind: k, thumbnail: thumb,
            swatch: settings.drawCopiedColorCode && !clip.isGroup ? ClipColorCode.color(from: clip.text) : nil,
            indexLabel: indexLabel,
            showPasted: settings.showIfClipWasPasted && clip.wasPasted && !clip.isGroup,
            showSymbols: currentGroupID == nil,
            highlighter: highlighter,
            richIndicator: !clip.isGroup && formatSummary(of: clip).hasRichText,
            imageIndicator: !clip.isGroup && formatSummary(of: clip).hasImage && formatSummary(of: clip).hasText,
            rich: settings.drawRTF && !clip.isGroup ? ClipRTFCache.shared.attributed(for: clip.id, store: store) : nil)
        loadMoreIfNeeded(row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === tableView { updateStatus() }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let clip = clip(atRow: row), !clip.isGroup,
              let formats = try? store.formats(clipID: clip.id), !formats.isEmpty else { return nil }
        return PasteContent.pasteboardItems(for: formats).first
    }

    /// A row can provide only one pasteboard writer, so a clip with several files adds its extra file items here.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        var extras: [NSPasteboardItem] = []
        for row in rowIndexes {
            guard let clip = clip(atRow: row), !clip.isGroup,
                  let formats = try? store.formats(clipID: clip.id), formats.contains(where: { $0.type == ClipUTI.fileURL }) else { continue }
            extras.append(contentsOf: PasteContent.pasteboardItems(for: formats).dropFirst())
        }
        if !extras.isEmpty { session.draggingPasteboard.writeObjects(extras) }
    }

    // MARK: Groups sidebar

    func toggleGroupsSidebar() {
        sidebarScroll.isHidden.toggle()
        settings.defaults.set(!sidebarScroll.isHidden, forKey: sidebarKey)
        if !sidebarScroll.isHidden {
            reloadSidebar()
            splitView.setPosition(150, ofDividerAt: 0)
        }
        splitView.adjustSubviews()
    }

    func reloadSidebar() {
        guard isGroupsSidebarVisible else { return }
        let all = (try? store.groups()) ?? []
        var byParent: [Int64: [Clip]] = [:]
        for g in all { byParent[g.parentID, default: []].append(g) }
        var visited = Set<Int64>()
        func build(_ parent: Int64) -> [QuickPasteGroupNode] {
            (byParent[parent] ?? []).compactMap { g in
                guard !visited.contains(g.id) else { return nil }   // guard against cycles
                visited.insert(g.id)
                let n = QuickPasteGroupNode(id: g.id, name: g.text.isEmpty ? "(unnamed)" : g.text)
                n.children = build(g.id)
                return n
            }
        }
        let root = QuickPasteGroupNode(id: nil, name: "History")
        groupRoots = [root] + build(Ditto.topLevelParent)
        // Orphans (parent missing) at top level.
        let orphans = all.filter { !visited.contains($0.id) }
        for g in orphans where !visited.contains(g.id) {
            visited.insert(g.id)
            let n = QuickPasteGroupNode(id: g.id, name: g.text)
            n.children = build(g.id)
            groupRoots.append(n)
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        syncSidebarSelection()
    }

    private func findNode(_ id: Int64?, in nodes: [QuickPasteGroupNode]) -> QuickPasteGroupNode? {
        for n in nodes {
            if n.id == id { return n }
            if let f = findNode(id, in: n.children) { return f }
        }
        return nil
    }

    private func syncSidebarSelection() {
        guard isGroupsSidebarVisible, let node = findNode(currentGroupID, in: groupRoots) else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        syncingSidebar = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        syncingSidebar = false
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? QuickPasteGroupNode else { return groupRoots.count }
        return n.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? QuickPasteGroupNode else { return groupRoots[index] }
        return n.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? QuickPasteGroupNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? QuickPasteGroupNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("GroupCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let iv = NSImageView()
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            iv.translatesAutoresizingMaskIntoConstraints = false
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv)
            c.addSubview(tf)
            c.imageView = iv
            c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = n.name
        cell.textField?.textColor = AppTheme.current.groupTreeText
        cell.imageView?.image = NSImage(systemSymbolName: n.id == nil ? "clock" : "folder", accessibilityDescription: nil)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSidebar else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let n = outlineView.item(atRow: row) as? QuickPasteGroupNode else { return }
        if n.id != currentGroupID {
            if !settings.maintainSearchView { clearSearch(reload: false) }
            setGroup(n.id)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 140)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 100)
    }
}
