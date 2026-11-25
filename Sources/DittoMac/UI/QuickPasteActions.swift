// QuickPasteActions.swift — clip and window actions for the Quick Paste popup (used by keys and menus).

import AppKit
import UniformTypeIdentifiers
import DittoCore

extension QuickPasteController {
    enum ReorderOp { case top, up, down, last }
    enum StickyOp { case top, last, remove, replaceTop }

    private var nonGroupSelection: [Clip] { selectedClips.filter { !$0.isGroup } }

    // MARK: Paste / copy

    func pasteSelection(transform: TextTransform?, moveToTop: Bool = true) {
        let sel = selectedClips
        guard !sel.isEmpty else { return }
        if sel.count == 1, sel[0].isGroup {
            enterGroup(id: sel[0].id)
            return
        }
        let clips = sel.filter { !$0.isGroup }
        guard !clips.isEmpty else { return }
        withVaultAccess(clips, reason: "paste a locked note") { [weak self] in
            self?.paste(ids: clips.map(\.id), transform: transform, moveToTop: moveToTop)
        }
    }

    func paste(ids: [Int64], transform: TextTransform?, moveToTop: Bool = true) {
        if isFiltered { recordSearchHistory() }
        let send = settings.sendPasteAfterSelection
        if !settings.alwaysOnTop { hide(restoreFocus: !send) }
        state.paste.paste(clipIDs: ids, transform: transform, sendPaste: send, moveToTop: moveToTop)
    }

    /// Paste As ▸ — an explicit format, regardless of the default paste format.
    func pasteSelection(format: PasteFormat, moveToTop: Bool = true) {
        let sel = selectedClips
        guard !sel.isEmpty else { return }
        if sel.count == 1, sel[0].isGroup {
            enterGroup(id: sel[0].id)
            return
        }
        let clips = sel.filter { !$0.isGroup }
        guard !clips.isEmpty else { return }
        withVaultAccess(clips, reason: "paste a locked note") { [weak self] in
            guard let self else { return }
            if self.isFiltered { self.recordSearchHistory() }
            let send = self.settings.sendPasteAfterSelection
            if !self.settings.alwaysOnTop { self.hide(restoreFocus: !send) }
            self.state.paste.paste(clipIDs: clips.map(\.id), format: format, sendPaste: send, moveToTop: moveToTop)
        }
    }

    /// Copy As ▸ — put the selection on the clipboard in `format` without pasting.
    func copySelection(format: PasteFormat) {
        let clips = nonGroupSelection
        guard !clips.isEmpty else { return }
        withVaultAccess(clips, reason: "copy a locked note") { [weak self] in
            guard let self else { return }
            let ids = clips.map(\.id)
            guard self.state.paste.copyToPasteboard(clipIDs: ids, format: format) else { return }
            let what = ids.count == 1 ? "Copied" : "Copied \(ids.count) clips"
            self.state.message(format == .original ? "\(what) to clipboard" : "\(what) as \(format.title)")
        }
    }

    /// ⌘1…⌘0 (and ⌥⌘ for plain text): paste the row whose first-ten label is `digit`.
    func pastePosition(digit: Int, plain: Bool) {
        let row = (digit - settings.firstTenHotKeysStart + 10) % 10
        guard row < clips.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        pasteSelection(transform: plain ? .plainText : nil)
    }

    func pasteStitched(vertical: Bool) {
        let clips = nonGroupSelection
        guard !clips.isEmpty else { return }
        withVaultAccess(clips, reason: "paste a locked note") { [weak self] in
            guard let self else { return }
            if !self.settings.alwaysOnTop { self.hide(restoreFocus: !self.settings.sendPasteAfterSelection) }
            self.state.paste.pasteImagesStitched(clipIDs: clips.map(\.id), vertical: vertical)
        }
    }

    func copySelection() {
        let clips = nonGroupSelection
        guard !clips.isEmpty else { return }
        withVaultAccess(clips, reason: "copy a locked note") { [weak self] in
            guard let self else { return }
            let ids = clips.map(\.id)
            self.state.paste.copyToPasteboard(clipIDs: ids, transform: nil)
            self.state.message(ids.count == 1 ? "Copied to clipboard" : "Copied \(ids.count) clips to clipboard")
        }
    }

    // MARK: Windows

    func previewSelection() {
        guard let c = nonGroupSelection.first else { return }
        // Arrow-key navigation in the preview never steps onto a locked note while the vault is locked.
        let unlocked = isVaultUnlocked
        let nav = clips.filter { !$0.isGroup && (unlocked || !$0.isLocked) }.map(\.id)
        withVaultAccess([c], reason: "preview a locked note") { [weak self] in
            PreviewWindowController.setNavigationContext(nav.contains(c.id) ? nav : [c.id])
            self?.state.windows.showPreview(clipID: c.id)
        }
    }

    func editSelection() {
        guard let c = nonGroupSelection.first else { return }
        withVaultAccess([c], reason: "edit a locked note") { [weak self] in self?.state.windows.showEditor(clipID: c.id) }
    }

    func newClip() { state.windows.showEditor(clipID: nil) }

    func propertiesSelection() {
        guard let c = selectedClips.first else { return }
        withVaultAccess([c], reason: "show a locked note’s properties") { [weak self] in self?.state.windows.showProperties(clipID: c.id) }
    }

    func showPreferences() { state.windows.showPreferences(tab: nil) }

    // MARK: Quick properties

    private func updateSelected(_ change: (inout Clip) -> Void) {
        for var c in selectedClips {
            guard let fresh = try? store.clip(id: c.id) else { continue }
            c = fresh
            change(&c)
            try? store.update(c)
        }
        state.clipsChanged()
    }

    func toggleNeverAutoDelete() {
        let newValue = !selectedClips.allSatisfy(\.dontAutoDelete)
        updateSelected { $0.dontAutoDelete = newValue }
    }

    func removeHotKeys() {
        updateSelected {
            $0.shortcut = 0
            $0.globalShortcut = false
            $0.moveToGroupShortcut = 0
            $0.globalMoveToGroupShortcut = false
        }
        refreshLocalShortcuts()
        NotificationCenter.default.post(name: .dittoHotkeysChanged, object: nil)
    }

    func removeQuickPasteText() {
        updateSelected { $0.quickPasteText = "" }
    }

    // MARK: Ordering / stickies

    func reorderSelection(_ op: ReorderOp) {
        let sel = selectedClips   // list order, top → bottom
        guard !sel.isEmpty else { return }
        do {
            switch op {
            case .top: for c in sel.reversed() { try store.moveToTop(id: c.id) }
            case .up: for c in sel { try store.moveUp(id: c.id, inGroup: currentGroupID) }
            case .down: for c in sel.reversed() { try store.moveDown(id: c.id, inGroup: currentGroupID) }
            case .last: for c in sel { try store.moveToBottom(id: c.id) }
            }
        } catch {
            state.message("Couldn’t reorder: \(error.localizedDescription)")
        }
        state.clipsChanged()
        reload(keepSelection: true)
    }

    func stickySelection(_ op: StickyOp) {
        let sel = selectedClips
        let inGroup = currentGroupID != nil
        do {
            if op == .replaceTop {
                if let c = sel.first { try store.replaceTopSticky(id: c.id, inGroup: inGroup) }
                state.clipsChanged()
                reload(keepSelection: true)
                return
            }
            for c in (op == .top ? sel.reversed() : sel) {
                switch op {
                case .top: try store.makeTopSticky(id: c.id, inGroup: inGroup)
                case .last: try store.makeLastSticky(id: c.id, inGroup: inGroup)
                case .remove: try store.removeSticky(id: c.id)
                case .replaceTop: break
                }
            }
        } catch {
            state.message("Couldn’t change sticky: \(error.localizedDescription)")
        }
        state.clipsChanged()
        reload(keepSelection: true)
    }

    // MARK: Groups

    func newGroup(fromSelection: Bool) {
        let ids = fromSelection ? selectedIDs : []
        let parent = currentGroupID ?? Ditto.topLevelParent
        let create: (String) -> Void = { [weak self] name in
            guard let self else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            do {
                let gid = try self.store.createGroup(name: String(trimmed.prefix(200)), parentID: parent)
                let moving = ids.filter { $0 != gid }
                if !moving.isEmpty { try self.store.move(ids: moving, toGroup: gid) }
                self.state.clipsChanged()
                self.reload(keepSelection: false)
                self.reloadSidebar()
                if let row = self.clips.firstIndex(where: { $0.id == gid }) {
                    self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.tableView.scrollRowToVisible(row)
                }
                self.state.message(moving.isEmpty ? "Created group “\(trimmed)”" : "Moved \(moving.count) item(s) to new group “\(trimmed)”")
            } catch {
                self.state.message("Couldn’t create group: \(error.localizedDescription)")
            }
        }
        if settings.promptForNewGroupName {
            state.windows.promptText(title: fromSelection ? "New Group from Selection" : "New Group",
                                     message: "Group name:", defaultValue: "New Group") { name in
                if let name { create(name) }
            }
        } else {
            create("New Group")
        }
    }

    func moveSelectionToGroup(copy: Bool) {
        let ids = copy ? nonGroupSelection.map(\.id) : selectedIDs
        guard !ids.isEmpty else { return }
        state.windows.pickGroup(title: copy ? "Copy to Group" : "Move to Group") { [weak self] gid in
            guard let self, let gid else { return }
            self.moveOrCopy(ids: ids, toGroup: gid, copy: copy)
        }
    }

    func moveOrCopy(ids: [Int64], toGroup gid: Int64, copy: Bool) {
        let filtered = ids.filter { $0 != gid }
        guard !filtered.isEmpty else { return }
        do {
            if copy { _ = try store.copyClips(ids: filtered, toGroup: gid) } else { try store.move(ids: filtered, toGroup: gid) }
            let name = gid == Ditto.topLevelParent ? "top level" : "“\((try? store.clip(id: gid))?.text ?? "group")”"
            state.message("\(copy ? "Copied" : "Moved") \(filtered.count) item(s) to \(name)")
        } catch {
            state.message("Couldn’t \(copy ? "copy" : "move"): \(error.localizedDescription)")
        }
        state.clipsChanged()
        reload(keepSelection: false)
        reloadSidebar()
    }

    // MARK: Filter / compare / tools

    func filterOnSelectedClip() {
        guard let c = nonGroupSelection.first, !c.isLocked else { return }
        let firstLine = c.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? c.text
        let text = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
        guard !text.isEmpty else { return }
        switch settings.searchMode {
        case .wildcard: searchField.stringValue = "\"" + text.replacingOccurrences(of: "\"", with: " ") + "\""
        case .contains: searchField.stringValue = text
        case .regex: searchField.stringValue = NSRegularExpression.escapedPattern(for: text)
        }
        runSearchNow(recordHistory: false)
    }

    func compareSelection() {
        let sel = nonGroupSelection
        guard sel.count == 2 else {
            state.message("Select exactly two clips to compare")
            return
        }
        withVaultAccess(sel, reason: "compare a locked note") { [weak self] in
            self?.state.windows.showCompare(leftID: sel[1].id, rightID: sel[0].id)
        }
    }

    func qrCodeSelection() {
        guard let c = nonGroupSelection.first else { return }
        withVaultAccess([c], reason: "make a QR code of a locked note") { [weak self] in
            guard let self else { return }
            guard let text = PasteContent.text(clipID: c.id, store: self.store), !text.isEmpty else {
                self.state.message("Clip has no text for a QR code")
                return
            }
            self.state.windows.showQRCode(text: text)
            if c.isLocked { (self.state.windows as? WindowRouter)?.qrShowsLockedNote = true }
        }
    }

    func webSearchSelection(translate: Bool) {
        guard let c = nonGroupSelection.first else { return }
        withVaultAccess([c], reason: "search the web for a locked note") { [weak self] in
            self?.performWebSearch(c, translate: translate)
        }
    }

    private func performWebSearch(_ c: Clip, translate: Bool) {
        let text = (PasteContent.text(clipID: c.id, store: store) ?? c.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state.message("Clip has no text to search for")
            return
        }
        let template = translate ? settings.translateURL : settings.webSearchURL
        guard let url = Self.templateURL(template, text: text) else {
            state.message("\(translate ? "Translate" : "Web search") URL must start with https:// and contain %s (Preferences › Advanced)")
            return
        }
        if !settings.alwaysOnTop { hide(restoreFocus: false) }
        NSWorkspace.shared.open(url)
    }

    /// Builds a URL from an https template with `%s` replaced by the percent-encoded text. nil if unsafe.
    static func templateURL(_ template: String, text: String) -> URL? {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("https://"), t.contains("%s") else { return nil }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = String(text.prefix(2000)).addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        let s = t.replacingOccurrences(of: "%s", with: encoded)
        guard let comps = URLComponents(string: s), comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty, comps.user == nil, comps.password == nil,
              let url = comps.url else { return nil }
        return url
    }

    func shareItemsForSelection() -> [Any] {
        var items: [Any] = []
        let unlocked = isVaultUnlocked
        for c in nonGroupSelection.prefix(20) where unlocked || !c.isLocked {
            if c.isLocked { vaultService?.noteActivity() }
            switch kind(of: c) {
            case .image:
                if let img = PasteContent.image(clipID: c.id, store: store) { items.append(img) }
            case .files:
                items.append(contentsOf: PasteContent.fileURLs(clipID: c.id, store: store).filter(\.isFileURL) as [Any])
            default:
                if let t = PasteContent.text(clipID: c.id, store: store), !t.isEmpty { items.append(t) }
            }
        }
        return items
    }

    func sendSelection(to peer: FriendPeer) {
        // Locked notes never leave this Mac (FriendsService also refuses them).
        let ids = lockPlan(nonGroupSelection).exportableIDs
        guard !ids.isEmpty else {
            if !nonGroupSelection.isEmpty { state.message("Locked notes can’t be sent") }
            return
        }
        guard let friends = state.friends, settings.friendsEnabled else {
            state.message("Friends sync is turned off (Preferences › Friends)")
            return
        }
        friends.send(clipIDs: ids, to: peer)
        state.message("Sending \(ids.count) clip(s) to \(peer.name.isEmpty ? peer.host : peer.name)…")
    }

    // MARK: Delete

    func deleteSelection() {
        let sel = selectedClips
        guard !sel.isEmpty else { return }
        if lockPlan(sel).hasLocked {
            deleteSelectionWithLocks(sel)
            return
        }
        if settings.promptWhenDeletingClips {
            let a = NSAlert()
            a.alertStyle = .warning
            let groups = sel.filter(\.isGroup).count
            if groups > 0 && sel.count == 1 {
                a.messageText = "Delete Group?"
                a.informativeText = "“\(sel[0].text)” will be deleted. Clips inside it are moved to the top level."
            } else if groups > 0 {
                a.messageText = "Delete \(sel.count) items?"
                a.informativeText = "Includes \(groups) group(s); clips inside groups are moved to the top level. This can’t be undone."
            } else {
                a.messageText = sel.count == 1 ? "Delete Clip?" : "Delete \(sel.count) Clips?"
                a.informativeText = "This can’t be undone."
            }
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            a.buttons[0].hasDestructiveAction = true
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don’t ask again"
            let response = a.runModal()
            if a.suppressionButton?.state == .on, response == .alertFirstButtonReturn { settings.promptWhenDeletingClips = false }
            guard response == .alertFirstButtonReturn else { return }
        }
        performPlainDelete(sel)
    }

    /// Deletes clips / groups that are not locked (no prompt) and restores a sensible selection.
    func performPlainDelete(_ sel: [Clip]) {
        guard !sel.isEmpty else { return }
        let firstRow = tableView.selectedRowIndexes.first ?? 0
        let hadShortcuts = sel.contains { $0.shortcut != 0 || $0.moveToGroupShortcut != 0 }
        do {
            try store.delete(ids: sel.map(\.id))
        } catch {
            state.message("Couldn’t delete: \(error.localizedDescription)")
            return
        }
        sel.forEach { ClipThumbnailCache.shared.invalidate($0.id) }
        state.clipsChanged()
        reload(keepSelection: false)
        if sel.contains(where: \.isGroup) { reloadSidebar() }
        if !clips.isEmpty {
            let row = min(firstRow, clips.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        if hadShortcuts {
            refreshLocalShortcuts()
            NotificationCenter.default.post(name: .dittoHotkeysChanged, object: nil)
        }
    }

    // MARK: Window-level settings

    private func settingsChanged() {
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    func toggleAlwaysOnTop() {
        settings.alwaysOnTop.toggle()
        panel.level = settings.alwaysOnTop ? .floating : .normal
        updateStatus()
        state.message(settings.alwaysOnTop ? "Always on top: on" : "Always on top: off")
        settingsChanged()
    }

    func setTransparency(_ percent: Int) {
        settings.transparencyPercent = percent
        settingsChanged()
    }

    func setLinesPerRow(_ n: Int) {
        settings.linesPerRow = n
        settingsChanged()
    }

    func setPopupPosition(_ p: PopupPosition) {
        settings.popupPosition = p
        settingsChanged()
    }

    // MARK: Database

    private func confirm(_ title: String, _ info: String, button: String, destructive: Bool) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = destructive
        return a.runModal() == .alertFirstButtonReturn
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    private var dittoClipsType: UTType { UTType(filenameExtension: ImportExport.fileExtension) ?? .data }

    func deleteNonUsedClips() {
        guard confirm("Delete all non-used clips?",
                      "Clips that were never pasted are deleted. Groups, stickies, clips with shortcuts and “never auto delete” clips are kept. This can’t be undone.",
                      button: "Delete", destructive: true) else { return }
        do {
            let n = try store.deleteNonUsedClips()
            ClipThumbnailCache.shared.invalidate()
            state.clipsChanged()
            state.message("Deleted \(n) non-used clip(s)")
        } catch {
            state.message("Delete failed: \(error.localizedDescription)")
        }
    }

    func backupDatabase() {
        let p = NSSavePanel()
        p.title = "Backup Database"
        p.nameFieldStringValue = "DittoMac-backup-\(Self.stamp()).\(ImportExport.fileExtension)"
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try store.backup(to: url)
            state.message("Backup saved to \(url.lastPathComponent)")
        } catch {
            state.message("Backup failed: \(error.localizedDescription)")
        }
    }

    func restoreDatabase() {
        let p = NSOpenPanel()
        p.title = "Restore Database"
        p.message = "Choose a DittoMac backup or export. Its clips are merged into your current history."
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        guard confirm("Restore from “\(url.lastPathComponent)”?", "Clips from the file are added to your history; existing clips are kept.",
                      button: "Restore", destructive: false) else { return }
        importFile(url, windows: false)
    }

    func compactDatabase() {
        let store = self.store
        state.message("Compacting database…")
        DispatchQueue.global(qos: .utility).async {
            let err: String?
            do { try store.vacuum(); err = nil } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.state.message(err.map { "Compact failed: \($0)" } ?? "Database compacted")
                }
            }
        }
    }

    func importWindowsDatabase() {
        let p = NSOpenPanel()
        p.title = "Import Windows Ditto Database"
        p.message = "Choose a Ditto.db file copied from Windows Ditto."
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        importFile(url, windows: true)
    }

    func importClips() {
        let p = NSOpenPanel()
        p.title = "Import Clips"
        p.allowedContentTypes = [dittoClipsType]
        p.allowsOtherFileTypes = true
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for url in p.urls { importFile(url, windows: false) }
    }

    private func importFile(_ url: URL, windows: Bool) {
        do {
            let r = windows ? try ImportExport.importWindowsDitto(from: url, into: store)
                            : try ImportExport.importClips(from: url, into: store)
            state.clipsChanged()
            NotificationCenter.default.post(name: .dittoHotkeysChanged, object: nil)
            reloadSidebar()
            state.message("Imported \(r.clipsImported) clip(s), \(r.groupsCreated) group(s); \(r.duplicates) duplicate(s), \(r.skipped) skipped")
        } catch {
            state.message("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: Export

    /// Non-group selection without locked notes (export never includes them); tells the user when some were skipped.
    private func exportableSelection() -> [Clip] {
        let all = nonGroupSelection
        let out = all.filter { !$0.isLocked }
        if out.count < all.count {
            state.message(out.isEmpty ? "Locked notes aren’t exported" : "\(all.count - out.count) locked note(s) skipped")
        }
        return out
    }

    func exportClips() {
        let ids = exportableSelection().map(\.id)
        guard !ids.isEmpty else { return }
        let p = NSSavePanel()
        p.title = "Export Clips"
        p.allowedContentTypes = [dittoClipsType]
        p.nameFieldStringValue = "Clips-\(Self.stamp()).\(ImportExport.fileExtension)"
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let n = try ImportExport.exportClips(ids: ids, from: store, to: url)
            state.message("Exported \(n) clip(s) to \(url.lastPathComponent)")
        } catch {
            state.message("Export failed: \(error.localizedDescription)")
        }
    }

    func exportTextFiles() {
        let items: [(Clip, String)] = exportableSelection().compactMap { c in
            PasteContent.text(clipID: c.id, store: store).map { (c, $0) }
        }
        guard !items.isEmpty else {
            state.message("Selected clips have no text")
            return
        }
        writeFiles(items.enumerated().map { i, pair in
            (ImportExport.textFileName(for: pair.0, index: i + 1), Data(pair.1.utf8))
        }, title: "Export to Text File")
    }

    func exportImageFiles() {
        var files: [(String, Data)] = []
        for (i, c) in exportableSelection().enumerated() {
            guard let formats = try? store.formats(clipID: c.id), let data = PasteContent.imageData(from: formats) else { continue }
            let png: Data
            if formats.contains(where: { $0.type == ClipUTI.png }) { png = data } else {
                guard ImageProbe.isSafeToDecode(data), let rep = NSBitmapImageRep(data: data),
                      let d = rep.representation(using: .png, properties: [:]) else { continue }
                png = d
            }
            var name = ImportExport.textFileName(for: c, index: i + 1)
            if name.hasSuffix(".txt") { name = String(name.dropLast(4)) + ".png" }
            files.append((name, png))
        }
        guard !files.isEmpty else {
            state.message("Selected clips have no images")
            return
        }
        writeFiles(files, title: "Export to Image File")
    }

    /// One file → save panel; several → choose a folder (never overwrites: appends " (n)").
    private func writeFiles(_ files: [(name: String, data: Data)], title: String) {
        if files.count == 1 {
            let p = NSSavePanel()
            p.title = title
            p.nameFieldStringValue = files[0].name
            p.canCreateDirectories = true
            guard p.runModal() == .OK, let url = p.url else { return }
            do {
                try files[0].data.write(to: url, options: .atomic)
                state.message("Saved \(url.lastPathComponent)")
            } catch {
                state.message("Export failed: \(error.localizedDescription)")
            }
            return
        }
        let p = NSOpenPanel()
        p.title = title + "s"
        p.message = "Choose a folder for \(files.count) files"
        p.prompt = "Export"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let dir = p.url else { return }
        var written = 0
        let fm = FileManager.default
        for f in files {
            var url = dir.appendingPathComponent(f.name)
            var n = 2
            let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            while fm.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(stem) (\(n))").appendingPathExtension(ext)
                n += 1
            }
            if (try? f.data.write(to: url, options: .atomic)) != nil { written += 1 }
        }
        state.message("Exported \(written) file(s) to \(dir.lastPathComponent)")
    }
}
