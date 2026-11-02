import Foundation

enum PinKind: String, Codable, CaseIterable {
    case text, image, file, folder, link

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .file: "doc.fill"
        case .folder: "folder.fill"
        case .link: "link"
        }
    }
}

struct PinItem: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: PinKind
    var title: String
    var payload: String
    var createdAt: Date
    var lastUsedAt: Date
    var isFavorite: Bool
    var tags: [String]?
    var isNote: Bool?
    var isAutomatic: Bool?
    var manualOrder: Double?
    var ownsAsset: Bool?

    init(kind: PinKind, title: String, payload: String) {
        id = UUID()
        self.kind = kind
        self.title = title
        self.payload = payload
        createdAt = .now
        lastUsedAt = .now
        isFavorite = false
    }
}

enum ShelfGeometry {
    static let footerHeight: CGFloat = 42
    static func showsFooter(expanded: Bool, reveal: CGFloat) -> Bool { expanded && reveal > 0.6 }
    // Moderate clearance inside the 10–12 pt inward shoulders, without
    // spending the compact title's limited width on excessive padding.
    static let headerContentInset: CGFloat = 24
    static let expandedContentInset: CGFloat = 24
    static let codexRowHeight: CGFloat = 50
    static let codexRowSpacing: CGFloat = 8
    static func codexBodyHeight(sessionCount: Int) -> CGFloat {
        guard sessionCount > 0 else { return 200 }
        let rows = CGFloat(min(sessionCount, 4))
        // Two 24 pt toolbars, their gaps, outer insets and a 4 pt cushion.
        return 84 + rows * codexRowHeight + (rows - 1) * codexRowSpacing
    }
    static func calendarBodyHeight(weekRows: Int) -> CGFloat {
        70 + CGFloat(min(6, max(4, weekRows))) * 21
    }
    static func musicBodyHeight(hasTrack: Bool, showsProgress: Bool, guidanceLines: Int = 3) -> CGFloat {
        // Artwork + controls need no reserved space for a hidden timeline.
        // The empty/permission state can contain three lines of guidance.
        guard hasTrack else { return 160 + CGFloat(min(3, max(1, guidanceLines)) - 1) * 14 }
        return showsProgress ? 198 : 156
    }
    static func reveal(height: CGFloat, collapsed: CGFloat, expanded: CGFloat) -> CGFloat {
        min(1, max(0, (height - collapsed) / max(1, expanded - collapsed)))
    }
    static func surfaceHeight(height: CGFloat, collapsed: CGFloat, expanded: CGFloat) -> CGFloat {
        height - footerHeight * reveal(height: height, collapsed: collapsed, expanded: expanded)
    }
}

struct IslandOptions: Codable, Equatable {
    // Optional so preferences written before feature visibility was added still decode.
    var hiddenTabs: [Int]? = nil
    var hudVolumeEnabled: Bool? = nil
    var hudBrightnessEnabled: Bool? = nil
    var headphoneConnectionEnabled: Bool? = nil
    var visibleTabIDs: [Int] {
        let visible = [0, 1, 2, 3].filter { !(hiddenTabs ?? []).contains($0) }
        return visible.isEmpty ? [0] : visible
    }
    func isTabVisible(_ id: Int) -> Bool { visibleTabIDs.contains(id) }
    var activityColorHex: String? = nil
    var clipboardEnabled = false
    var clipboardPaused = false
    var excludedApps = ""
    var historyMonths = 0
    var copyFiles = false
    var appearance = "automatic"
    var sortOrder = "added"
    var shelfWidth: Double = 580
    var hoverDelay: Double = 0.35
    var arrivalSound = true
    var completionSound = true
    var arrivalAnimation = true
    var completionAlert = true
    var showMenuIcon = true
    var screenID = "automatic"
    var allDisplays = false
    var dockPositions: [String: String] = [:]
    var alertScreenID = "automatic"
    var pinKey: UInt32 = 35
    var pinModifiers: UInt32 = 4352
    var toggleKey: UInt32 = 34
    var toggleModifiers: UInt32 = 4352
    var noteKey: UInt32 = 45
    var noteModifiers: UInt32 = 4352
    var selectionKey: UInt32 = 7
    var selectionModifiers: UInt32 = 768

    func validated() -> Self {
        var result = self
        result.shelfWidth = shelfWidth.isFinite ? min(960, max(440, shelfWidth)) : 580
        result.hoverDelay = hoverDelay.isFinite ? min(1, max(0.15, hoverDelay)) : 0.35
        if !["automatic", "black", "glass"].contains(appearance) { result.appearance = "automatic" }
        if !["added", "used", "manual"].contains(sortOrder) { result.sortOrder = "added" }
        if ![0, 3, 6].contains(historyMonths) { result.historyMonths = 0 }
        result.dockPositions = dockPositions.filter { ["top", "left", "right"].contains($0.value) }
        return result
    }
}

enum PinFilter: String, CaseIterable {
    case all = "全部", text = "文字", image = "图片", link = "链接", file = "文件", note = "便签", history = "历史"
}

enum CodexSessionKind: String, Codable, Sendable { case review, subagent }

struct CodexSession: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let project: String
    let modifiedAt: Date
    let isRunning: Bool
    var sourcePath: String? = nil
    var internalKind: CodexSessionKind? = nil
    var parentThreadID: String? = nil
}

enum ActivityPhase: String, Sendable {
    case running, waiting, completed, interrupted, unknown
    var title: String {
        switch self {
        case .running: "正在处理"
        case .waiting: "等待回答"
        case .completed: "已完成"
        case .interrupted: "已中断"
        case .unknown: "状态待确认"
        }
    }
}

struct SessionActivity: Sendable {
    var phase: ActivityPhase = .unknown
    var message = "暂无可读取的活动记录"
    var startedAt: Date?
    var updatedAt: Date = .distantPast
    var pendingCallID: String?
}
