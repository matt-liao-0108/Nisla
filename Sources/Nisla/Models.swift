import Foundation
import Darwin

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
    static func bodyHeight(_ height: CGFloat, floating: Bool, selectedTab: Int) -> CGFloat {
        guard floating else { return height }
        return max(0, height - (selectedTab == 0 ? 32 : selectedTab == 1 ? 8 : 0))
    }
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
    // Missing values in pre-0.2.48 preferences mean automatic, not a manual
    // request for a floating capsule.
    var presentationStyle: String? = nil
    var presentationPolicyVersion: Int? = 1
    var preferredPresentation: String {
        ["automatic", "floating", "notch"].contains(presentationStyle ?? "automatic")
            ? presentationStyle ?? "automatic" : "automatic"
    }
    var usesFloatingIsland: Bool { usesFloatingIsland(nativeSupport: NativeIslandCompatibility.current()) }
    func usesFloatingIsland(nativeSupport: NativeIslandCompatibility.Support) -> Bool {
        switch preferredPresentation {
        case "floating": true
        case "notch": false
        default: nativeSupport == .verified
        }
    }
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
        if let presentationStyle, !["automatic", "floating", "notch"].contains(presentationStyle) { result.presentationStyle = "automatic" }
        if presentationPolicyVersion == nil {
            // 0.2.48 could persist its globally forced floating default as a
            // selection. Re-evaluate that once; later manual choices survive.
            if presentationStyle == "floating" { result.presentationStyle = "automatic" }
            result.presentationPolicyVersion = 1
        }
        if !["automatic", "black", "glass"].contains(appearance) { result.appearance = "automatic" }
        if !["added", "used", "manual"].contains(sortOrder) { result.sortOrder = "added" }
        if ![0, 3, 6].contains(historyMonths) { result.historyMonths = 0 }
        result.dockPositions = dockPositions.filter { ["top", "left", "right"].contains($0.value) }
        return result
    }
}

enum NativeIslandCompatibility {
    enum Support: Equatable { case unsupportedSystem, externalDisplay, unverifiedDevice, verified }

    // SDK 26 has no public native-island capability API. Apple's model list
    // does not yet identify PROLED devices, so no model is assumed supported.
    // Add exact identifiers only after official verification; chip names and
    // notch/safe-area geometry are not proof of native-island support.
    static let verifiedModels: Set<String> = []
    static let localModelIdentifier: String? = {
        var length = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 1, length < 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &bytes, &length, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
    static func detect(systemMajor: Int, modelIdentifier: String?, builtInDisplay: Bool,
                       confirmedModels: Set<String> = verifiedModels) -> Support {
        guard systemMajor >= 27 else { return .unsupportedSystem }
        guard builtInDisplay else { return .externalDisplay }
        guard let modelIdentifier, confirmedModels.contains(modelIdentifier) else { return .unverifiedDevice }
        return .verified
    }
    static func current(builtInDisplay: Bool = true) -> Support {
        detect(systemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            modelIdentifier: localModelIdentifier, builtInDisplay: builtInDisplay)
    }
}

enum FloatingIslandGeometry {
    static let headerHeight: CGFloat = 36
    static let topGap: CGFloat = 8
    static func frame(screen: CGRect, visible: CGRect, safeTop: CGFloat, size: CGSize) -> CGRect {
        let width = min(max(1, size.width), max(1, screen.width - 32))
        let top = min(visible.maxY, screen.maxY - max(0, safeTop)) - topGap
        return CGRect(x: screen.midX - width / 2, y: top - size.height, width: width, height: size.height)
    }
    static func compactWidth(hasActivity: Bool) -> CGFloat { hasActivity ? 300 : 200 }
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
    var progress: String? = nil
    var phase: ActivityPhase = .unknown
    var message = "暂无可读取的活动记录"
    var startedAt: Date?
    var updatedAt: Date = .distantPast
    var pendingCallID: String?
}
