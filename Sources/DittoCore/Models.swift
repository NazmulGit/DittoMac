import Foundation

public enum Ditto {
    /// Value of `stickyClipOrder` / `stickyClipGroupOrder` meaning "not sticky".
    public static let stickySentinel: Double = -2147483647
    /// `lParentID` of a clip / group that lives at top level.
    public static let topLevelParent: Int64 = -1
}

/// Well-known pasteboard types stored by DittoMac.
public enum ClipUTI {
    public static let plainText = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let html = "public.html"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let fileURL = "public.file-url"
}

public enum ClipKind: String, Sendable, CaseIterable {
    case text, richText, html, image, files, group, other

    /// Classifies a clip by its richest stored format.
    public static func classify(types: [String], isGroup: Bool = false) -> ClipKind {
        if isGroup { return .group }
        let set = Set(types)
        if set.contains(ClipUTI.png) || set.contains(ClipUTI.tiff) { return .image }
        if set.contains(ClipUTI.fileURL) { return .files }
        if set.contains(ClipUTI.rtf) { return .richText }
        if set.contains(ClipUTI.html) { return .html }
        if set.contains(ClipUTI.plainText) { return .text }
        return .other
    }
}

public struct ClipFormat: Sendable, Equatable {
    public var id: Int64            // 0 when not yet stored
    public var type: String         // UTI / NSPasteboard.PasteboardType rawValue
    public var data: Data
    public init(id: Int64 = 0, type: String, data: Data) {
        self.id = id
        self.type = type
        self.data = data
    }
}

public struct Clip: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var date: Date                 // lDate
    public var text: String               // mText description / group name
    public var shortcut: Int              // lShortCut (encoded KeyCombo, 0 = none)
    public var globalShortcut: Bool
    public var dontAutoDelete: Bool
    public var crc: Int32
    public var isGroup: Bool
    public var parentID: Int64            // -1 top level
    public var quickPasteText: String
    public var clipOrder: Double
    public var clipGroupOrder: Double
    public var lastPasteDate: Date
    public var stickyClipOrder: Double
    public var stickyClipGroupOrder: Double
    public var moveToGroupShortcut: Int
    public var globalMoveToGroupShortcut: Bool
    public var sourceApp: String

    public init(id: Int64 = 0, date: Date = Date(), text: String = "", shortcut: Int = 0,
                globalShortcut: Bool = false, dontAutoDelete: Bool = false, crc: Int32 = 0,
                isGroup: Bool = false, parentID: Int64 = Ditto.topLevelParent, quickPasteText: String = "",
                clipOrder: Double = 0, clipGroupOrder: Double = 0, lastPasteDate: Date? = nil,
                stickyClipOrder: Double = Ditto.stickySentinel, stickyClipGroupOrder: Double = Ditto.stickySentinel,
                moveToGroupShortcut: Int = 0, globalMoveToGroupShortcut: Bool = false, sourceApp: String = "") {
        self.id = id
        self.date = date
        self.text = text
        self.shortcut = shortcut
        self.globalShortcut = globalShortcut
        self.dontAutoDelete = dontAutoDelete
        self.crc = crc
        self.isGroup = isGroup
        self.parentID = parentID
        self.quickPasteText = quickPasteText
        self.clipOrder = clipOrder
        self.clipGroupOrder = clipGroupOrder
        self.lastPasteDate = lastPasteDate ?? date
        self.stickyClipOrder = stickyClipOrder
        self.stickyClipGroupOrder = stickyClipGroupOrder
        self.moveToGroupShortcut = moveToGroupShortcut
        self.globalMoveToGroupShortcut = globalMoveToGroupShortcut
        self.sourceApp = sourceApp
    }

    /// True when either sticky column holds a real value.
    public var isSticky: Bool {
        stickyClipOrder != Ditto.stickySentinel || stickyClipGroupOrder != Ditto.stickySentinel
    }

    /// Upstream rule: pasted at least once after capture.
    public var wasPasted: Bool { lastPasteDate.timeIntervalSince(date) > 1 }
}

public struct ClipFilter: Sendable {
    public var parentID: Int64? = nil           // nil = history (top level); value = inside group
    public var showAllClipsInMainList = true    // history includes clips that live in groups
    public var showGroupsInMainList = false
    public var search: SearchQuery? = nil
    public var limit: Int = 500
    public var offset: Int = 0

    public init(parentID: Int64? = nil, showAllClipsInMainList: Bool = true, showGroupsInMainList: Bool = false,
                search: SearchQuery? = nil, limit: Int = 500, offset: Int = 0) {
        self.parentID = parentID
        self.showAllClipsInMainList = showAllClipsInMainList
        self.showGroupsInMainList = showGroupsInMainList
        self.search = search
        self.limit = limit
        self.offset = offset
    }
}

public enum AddResult: Sendable, Equatable {
    case inserted(Int64)
    case duplicateBumped(Int64)
    case rejected
}

public struct StoreStats: Sendable {
    public var clips, groups, formats: Int
    public var databaseBytes: Int64
    public init(clips: Int = 0, groups: Int = 0, formats: Int = 0, databaseBytes: Int64 = 0) {
        self.clips = clips
        self.groups = groups
        self.formats = formats
        self.databaseBytes = databaseBytes
    }
}

public struct ClipDataFilter: Sendable {
    public var titleContains: String?
    public var createdFrom, createdTo, usedFrom, usedTo: Date?
    public var formatType: String?
    public init(titleContains: String? = nil, createdFrom: Date? = nil, createdTo: Date? = nil,
                usedFrom: Date? = nil, usedTo: Date? = nil, formatType: String? = nil) {
        self.titleContains = titleContains
        self.createdFrom = createdFrom
        self.createdTo = createdTo
        self.usedFrom = usedFrom
        self.usedTo = usedTo
        self.formatType = formatType
    }
}
