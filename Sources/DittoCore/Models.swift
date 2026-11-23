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

    // Rich formats kept when `Settings.keepFullFormatting` is on (exact bytes, no re-encoding).
    public static let webArchive = "com.apple.webarchive"
    /// Pre-UTI name some apps still write for web archives; normalised to `webArchive` on capture.
    public static let legacyWebArchive = "Apple Web Archive pasteboard type"
    public static let flatRTFD = "com.apple.flat-rtfd"       // NSPasteboard.PasteboardType.rtfd
    public static let rtfd = "public.rtfd"
    public static let jpeg = "public.jpeg"
    public static let gif = "com.compuserve.gif"
    public static let heic = "public.heic"
    public static let pdf = "com.adobe.pdf"
    public static let url = "public.url"
    public static let urlName = "public.url-name"

    /// The full-formatting set captured independently of `Settings.enabledTypes`.
    public static let fullFormattingTypes: [String] = [webArchive, flatRTFD, rtfd, jpeg, gif, pdf, url, urlName, heic]
    /// Image formats, in the order they are preferred for display / export.
    public static let imageTypes: [String] = [png, tiff, jpeg, gif, heic]
    /// Formats that carry styled text (headings, bold, links …).
    public static let richTextTypes: [String] = [rtf, flatRTFD, rtfd, html, webArchive]

    /// Human-readable name for a stored format type (unknown types are returned unchanged).
    public static func displayName(_ type: String) -> String {
        switch type {
        case plainText, "public.utf16-plain-text": return "Plain Text"
        case rtf: return "Rich Text (RTF)"
        case flatRTFD, rtfd: return "Rich Text with Attachments (RTFD)"
        case html: return "HTML"
        case webArchive, legacyWebArchive: return "Web Archive"
        case png: return "PNG Image"
        case tiff: return "TIFF Image"
        case jpeg: return "JPEG Image"
        case gif: return "GIF Image"
        case heic: return "HEIC Image"
        case pdf: return "PDF"
        case fileURL: return "File References"
        case url: return "Link"
        case urlName: return "Link Title"
        default: return type
        }
    }

    /// Distinct human-readable names for a list of types, in order (e.g. both RTFD types collapse into one).
    public static func displayNames(_ types: [String]) -> [String] {
        var seen = Set<String>()
        return types.map(displayName).filter { seen.insert($0).inserted }
    }
}

/// What kinds of content a clip carries (for row indicators, menus and the Save As panel).
public struct ClipFormatSummary: Sendable, Equatable {
    public var hasText: Bool
    public var hasRichText: Bool
    public var hasImage: Bool
    public var hasWebArchive: Bool
    public var hasRTFD: Bool
    public var hasHTML: Bool
    public var hasRTF: Bool
    public var hasFiles: Bool

    public init(types: [String]) {
        let set = Set(types)
        hasText = set.contains(ClipUTI.plainText) || set.contains("public.utf16-plain-text")
        hasRTF = set.contains(ClipUTI.rtf)
        hasRTFD = set.contains(ClipUTI.flatRTFD) || set.contains(ClipUTI.rtfd)
        hasHTML = set.contains(ClipUTI.html)
        hasWebArchive = set.contains(ClipUTI.webArchive)
        hasRichText = hasRTF || hasRTFD || hasHTML || hasWebArchive
        hasImage = ClipUTI.imageTypes.contains(where: set.contains)
        hasFiles = set.contains(ClipUTI.fileURL)
    }
}

public enum ClipKind: String, Sendable, CaseIterable {
    case text, richText, html, image, files, group, other

    /// Classifies a clip by its richest stored format.
    public static func classify(types: [String], isGroup: Bool = false) -> ClipKind {
        if isGroup { return .group }
        let set = Set(types)
        if ClipUTI.imageTypes.contains(where: set.contains) { return .image }
        if set.contains(ClipUTI.fileURL) { return .files }
        if set.contains(ClipUTI.rtf) || set.contains(ClipUTI.flatRTFD) || set.contains(ClipUTI.rtfd) { return .richText }
        if set.contains(ClipUTI.html) || set.contains(ClipUTI.webArchive) { return .html }
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
