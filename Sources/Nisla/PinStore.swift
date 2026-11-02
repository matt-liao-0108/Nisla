import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class PinStore: ObservableObject {
    @Published var items: [PinItem] = [] { didSet { save() } }
    @Published var query = ""
    @Published var options = IslandOptions() {
        didSet {
            if !isResizingWidth { persistOptions() }
            if !isTabPresented(selectedTab) { selectedTab = options.visibleTabIDs[0] }
        }
    }
    @Published var filter: PinFilter = .all
    @Published var tagFilter: String?
    @Published var selectedIDs = Set<UUID>()
    @Published var selectionMode = false
    @Published var editingNoteID: UUID?
    @Published var selectedTab = 0 {
        didSet {
            if !isTabPresented(selectedTab) { selectedTab = options.visibleTabIDs[0] }
            // An explicit page change wins over a temporary drop destination.
            if selectedTab != 0 { dropPresentation = nil }
            if selectedTab != oldValue { previousTab = oldValue }
        }
    }
    private(set) var previousTab = 0
    @Published var showRecentSessions = false
    @Published var isExpanded = false {
        didSet { if !isExpanded { restoreDropPresentation() } }
    }
    private struct DropPresentation {
        let id = UUID()
        let returnTab: Int
        let wasExpanded: Bool
        var committed = false
        var pending = 0
        var imported = false
    }
    private var dropPresentation: DropPresentation?
    private var suppressDropReveal = false
    var isDropPresentationActive: Bool { dropPresentation != nil }
    func isTabPresented(_ id: Int) -> Bool {
        options.isTabVisible(id) || (id == 0 && isDropPresentationActive)
    }

    /// Navigation only: entering the drop target must show its destination,
    /// without changing the page to restore on the next ordinary expansion.
    func beginDropPresentation() {
        if dropPresentation == nil {
            dropPresentation = DropPresentation(returnTab: selectedTab, wasExpanded: isExpanded)
        }
        selectedTab = 0
        resetFilters()
        selectedIDs.removeAll(); selectionMode = false
    }

    func cancelDropHover() {
        guard let drop = dropPresentation, !drop.committed else { return }
        restoreDropPresentation()
        if !drop.wasExpanded { isExpanded = false }
    }

    func beginDropImport(count: Int) -> UUID {
        precondition(count > 0)
        beginDropPresentation()
        dropPresentation!.committed = true
        dropPresentation!.pending += count
        isExpanded = true
        return dropPresentation!.id
    }

    /// Slow item providers may finish after the user closes the panel or picks
    /// another page. Still save their payload, but do not steal navigation back.
    func receiveDrop(_ id: UUID, importing: () -> Void) {
        let active = dropPresentation?.id == id
        let previousCount = items.count
        suppressDropReveal = !active
        importing()
        suppressDropReveal = false
        guard active, dropPresentation?.id == id else { return }
        dropPresentation!.pending -= 1
        dropPresentation!.imported = dropPresentation!.imported || (items.count > previousCount && persistenceError == nil)
        if dropPresentation!.pending == 0 && !dropPresentation!.imported {
            notice = notice ?? "拖入来源没有提供可读取的内容；请尝试复制粘贴，或先把文件保存到 Finder 后再拖入。"
            cancelFailedDrop()
        }
    }

    private func cancelFailedDrop() {
        let wasExpanded = dropPresentation?.wasExpanded ?? false
        restoreDropPresentation()
        if !wasExpanded { isExpanded = false }
    }

    private func restoreDropPresentation() {
        guard let drop = dropPresentation else { return }
        dropPresentation = nil
        if selectedTab == 0 {
            selectedTab = options.isTabVisible(drop.returnTab) ? drop.returnTab : options.visibleTabIDs[0]
        }
    }
    @Published var codexSessions: [CodexSession] = []
    @Published var connectedCodexSessions: [CodexSession] = []
    @Published var notice: String?
    @Published var feedback: String?
    @Published var keepOpen = false
    @Published var isResizingWidth = false {
        didSet { if oldValue && !isResizingWidth { persistOptions() } }
    }
    @Published var previewOpen = false
    @Published var notchWidth: CGFloat = 0
    @Published var headerHeight: CGFloat = 36
    @Published var musicHasTrack = false
    @Published var musicShowsProgress = false
    @Published var musicGuidanceLines = 3
    @Published var calendarWeekRows = 6
    var shelfWidth: CGFloat { isExpanded ? options.shelfWidth : max(270, notchWidth + 210) }
    var bodyHeight: CGFloat {
        if selectedTab == 3 { return ShelfGeometry.musicBodyHeight(hasTrack: musicHasTrack, showsProgress: musicShowsProgress, guidanceLines: musicGuidanceLines) }
        if selectedTab == 2 { return ShelfGeometry.calendarBodyHeight(weekRows: calendarWeekRows) }
        guard selectedTab == 1 else { return 154 }
        return ShelfGeometry.codexBodyHeight(sessionCount: visibleCodexSessions.count)
    }
    var visibleCodexSessions: [CodexSession] {
        if showRecentSessions { return connectedCodexSessions.isEmpty ? codexSessions : connectedCodexSessions }
        return pinnedSessions.map { pin in codexSessions.first(where: { $0.id == pin.id }) ?? pin }
    }
    var shelfHeight: CGFloat { headerHeight + (isExpanded ? bodyHeight + ShelfGeometry.footerHeight : 0) }
    @Published var isRefreshing = false
    @Published var pinnedSessions: [CodexSession] = []
    @Published var activities: [String: SessionActivity] = [:]
    @Published var recentlyCompleted: String?
    private var monitorTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var monitoredDates: [String: Date] = [:]
    private var completedUntil: Date = .distantPast
    private var clipboardChange = NSPasteboard.general.changeCount
    private var capturingAutomatic = false
    var activeCount: Int { pinnedSessions.filter { activities[$0.id]?.phase == .running }.count }
    var waitingCount: Int { pinnedSessions.filter { activities[$0.id]?.phase == .waiting }.count }
    private var refreshTask: Task<Void, Never>?
    private var storageReadable = true
    private(set) var persistenceError: String?
    private let storageDirectory: URL?
    private let preferences: UserDefaults
    private let interactive: Bool

    private let fm = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var storageURL: URL {
        let base = storageDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Island", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("pins.json")
    }
    private var assetsURL: URL {
        let url = storageURL.deletingLastPathComponent().appendingPathComponent("Assets", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init(storageDirectory: URL? = nil, preferences: UserDefaults = .standard, interactive: Bool = true) {
        self.storageDirectory = storageDirectory
        self.preferences = preferences
        self.interactive = interactive
        if let data = preferences.data(forKey: "options"), let saved = try? decoder.decode(IslandOptions.self, from: data) { options = saved.validated() }
        selectedTab = options.visibleTabIDs[0]
        load()
        if let data = preferences.data(forKey: "pinnedSessions"),
           let sessions = try? decoder.decode([CodexSession].self, from: data) { pinnedSessions = sessions }
        if interactive {
            refreshCodex()
            monitorTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.refreshActivities()
                    self?.pollClipboard()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    var filteredItems: [PinItem] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            if options.sortOrder == "used" { return lhs.lastUsedAt > rhs.lastUsedAt }
            if options.sortOrder == "manual" { return (lhs.manualOrder ?? -lhs.createdAt.timeIntervalSince1970) < (rhs.manualOrder ?? -rhs.createdAt.timeIntervalSince1970) }
            return lhs.createdAt > rhs.createdAt
        }
        return sorted.filter { item in
            let matchesType: Bool
            switch filter {
            case .all: matchesType = true
            case .text: matchesType = item.kind == .text
            case .image: matchesType = item.kind == .image
            case .link: matchesType = item.kind == .link
            case .file: matchesType = item.kind == .file || item.kind == .folder
            case .note: matchesType = item.isNote == true
            case .history: matchesType = item.isAutomatic == true
            }
            return matchesType && (tagFilter == nil || (item.tags ?? []).contains(tagFilter!)) && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.payload.localizedCaseInsensitiveContains(query))
        }
    }
    var hasActiveFilters: Bool { filter != .all || tagFilter != nil || !query.isEmpty }
    func resetFilters() { filter = .all; tagFilter = nil; query = "" }

    func capturePasteboard() {
        let pb = NSPasteboard.general
        let previousCount = items.count
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            add(urls: urls)
        } else if let image = NSImage(pasteboard: pb) {
            add(image: image)
        } else if let value = pb.string(forType: .string), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(text: value)
        }
        if capturingAutomatic {
            for index in previousCount..<items.count { items[index].isAutomatic = true }
        } else if items.count == previousCount { notice = "剪贴板中没有可添加的内容" }
    }

    func add(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let kind: PinKind = URL(string: trimmed).map { $0.scheme == "http" || $0.scheme == "https" } == true ? .link : .text
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? "文字"
        items.append(PinItem(kind: kind, title: String(firstLine.prefix(80)), payload: trimmed))
        revealNewContent()
    }

    func add(image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let name = UUID().uuidString + ".png"
        let url = assetsURL.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
            items.append(PinItem(kind: .image, title: "图片 \(items.count + 1)", payload: url.path))
            revealNewContent()
        } catch { notice = "图片保存失败：\(error.localizedDescription)" }
    }

    func add(urls: [URL]) {
        for url in urls {
            guard url.isFileURL else { add(text: url.absoluteString); continue }
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &directory) else { notice = "文件不存在：\(url.lastPathComponent)"; continue }
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            let kind: PinKind = directory.boolValue ? .folder : (type?.conforms(to: .image) == true ? .image : .file)
            var destination = url
            if options.copyFiles {
                destination = assetsURL.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                do { try fm.copyItem(at: url, to: destination) }
                catch { notice = "复制文件失败：\(error.localizedDescription)"; continue }
            }
            var item = PinItem(kind: kind, title: url.lastPathComponent, payload: destination.path)
            item.ownsAsset = options.copyFiles
            items.append(item)
            revealNewContent()
        }
    }

    func remove(_ item: PinItem) {
        let previous = items
        guard let item = previous.first(where: { $0.id == item.id }) else { return }
        let asset = URL(fileURLWithPath: item.payload).standardizedFileURL
        let managed = (item.kind == .image || item.ownsAsset == true)
            && asset.deletingLastPathComponent() == assetsURL.standardizedFileURL
        var updated = previous.filter { $0.id != item.id }
        let otherReference = updated.firstIndex { [.image, .file, .folder].contains($0.kind)
            && URL(fileURLWithPath: $0.payload).standardizedFileURL == asset }
        if managed, let index = otherReference { updated[index].ownsAsset = true }
        items = updated
        guard persistenceError == nil else { items = previous; return }
        if managed && otherReference == nil {
            do { try fm.removeItem(atPath: item.payload) }
            catch {
                if fm.fileExists(atPath: item.payload) {
                    items = previous
                    notice = "无法删除副本：\(error.localizedDescription)"; return
                }
            }
        }
        selectedIDs.remove(item.id)
    }

    func toggleFavorite(_ item: PinItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].isFavorite.toggle()
        if persistenceError == nil { feedback = items[i].isFavorite ? "已收藏" : "已取消收藏" }
    }

    func use(_ item: PinItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let item = items[i]
        guard validate(item) else { return }
        var objects: [NSPasteboardWriting] = []
        switch item.kind {
        case .text, .link: objects = [item.payload as NSString]
        case .image:
            guard let image = NSImage(contentsOfFile: item.payload) else { notice = "无法读取图片"; return }
            objects = [image]
        case .file, .folder: objects = [URL(fileURLWithPath: item.payload) as NSURL]
        }
        items[i].lastUsedAt = .now
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.writeObjects(objects) { feedback = "已复制"; skipClipboardChange() }
        else { notice = "复制失败，请重试" }
    }

    func open(_ item: PinItem) {
        guard let current = items.first(where: { $0.id == item.id }) else { return }
        let item = current
        guard validate(item) else { return }
        switch item.kind {
        case .link:
            if let url = URL(string: item.payload), NSWorkspace.shared.open(url) { recordUse(item.id) }
            else { notice = "无法打开链接" }
        case .image: QuickLookController.shared.show(path: item.payload); recordUse(item.id)
        case .file, .folder:
            if NSWorkspace.shared.open(URL(fileURLWithPath: item.payload)) { recordUse(item.id) }
            else { notice = "无法打开文件，请检查默认应用或访问权限" }
        case .text: use(item)
        }
    }

    func revealInFinder(_ item: PinItem) {
        guard let current = items.first(where: { $0.id == item.id }),
              [.image, .file, .folder].contains(current.kind), validate(current) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current.payload)])
    }

    func refreshCodex() {
        guard interactive, !isRefreshing else { return }
        isRefreshing = true
        refreshTask = Task {
            let retained = Set(pinnedSessions.map(\.id))
            let sessions = await Task.detached(priority: .utility) { Self.scanCodex(retaining: retained) }.value
            codexSessions = sessions
            isRefreshing = false
            refreshActivities()
        }
    }

    nonisolated private static func scanCodex(retaining: Set<String> = []) -> [CodexSession] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var titles: [String: String] = [:]
        if let index = try? String(contentsOf: home.appendingPathComponent(".codex/session_index.jsonl"), encoding: .utf8) {
            for line in index.split(separator: "\n") {
                if let data = line.data(using: .utf8),
                   let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = row["id"] as? String,
                   let title = row["thread_name"] as? String { titles[id] = title }
            }
        }
        let roots = [home.appendingPathComponent(".codex/sessions"), home.appendingPathComponent(".codex/archived_sessions")]
        var candidates: [(URL, Date)] = []
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else { continue }
                candidates.append((url, attrs.contentModificationDate ?? .distantPast))
            }
        }
        var found: [CodexSession] = []
        var seen = Set<String>()
        for (index, entry) in candidates.sorted(by: { $0.1 > $1.1 }).enumerated() {
                let (url, date) = entry
                let id = url.deletingPathExtension().lastPathComponent
                let parts = id.split(separator: "-")
                let compactID = parts.count > 4 ? parts.suffix(5).joined(separator: "-") : id
                guard index < 100 || retaining.contains(compactID) else { continue }
                guard seen.insert(compactID).inserted else { continue }
                found.append(CodexSession(id: compactID, title: titles[compactID] ?? sessionTitle(from: url) ?? "会话 \(compactID.prefix(8))", project: "本机会话", modifiedAt: date, isRunning: false, sourcePath: url.path))
        }
        return found
    }

    nonisolated private static func sessionTitle(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_097_152) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let payload = object["payload"] as? [String: Any],
               payload["role"] as? String == "user",
               let content = payload["content"] as? [[String: Any]] {
                for block in content {
                    if let text = block["text"] as? String,
                       !text.hasPrefix("<"), !text.hasPrefix("# "), !text.isEmpty {
                        return String(text.replacingOccurrences(of: "\n", with: " ").prefix(80))
                    }
                }
            }
            if let payload = object["payload"] as? [String: Any], payload["type"] as? String == "user_message", let message = payload["message"] as? String, !message.isEmpty {
                return String(message.replacingOccurrences(of: "\n", with: " ").prefix(80))
            }
        }
        return nil
    }

    private func load() {
        guard fm.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            items = try decoder.decode([PinItem].self, from: data)
        } catch {
            storageReadable = false
            notice = "无法读取历史数据，已保留原文件并暂停覆盖保存：\(error.localizedDescription)"
        }
    }

    private func save() {
        persistenceError = nil
        guard storageReadable else {
            persistenceError = "历史数据读取失败，当前更改尚未保存。请先备份并修复 pins.json。"
            notice = persistenceError; return
        }
        guard let data = try? encoder.encode(items) else { return }
        do { try data.write(to: storageURL, options: .atomic) }
        catch { persistenceError = "保存失败：\(error.localizedDescription)"; notice = persistenceError }
    }

    func toggleSession(_ session: CodexSession) {
        if pinnedSessions.contains(where: { $0.id == session.id }) { pinnedSessions.removeAll { $0.id == session.id } }
        else { pinnedSessions.append(session) }
        let pinnedIDs = Set(pinnedSessions.map(\.id))
        activities = activities.filter { pinnedIDs.contains($0.key) }
        monitoredDates = monitoredDates.filter { pinnedIDs.contains($0.key) }
        if let recentlyCompleted, !pinnedIDs.contains(recentlyCompleted) { self.recentlyCompleted = nil }
        if let data = try? encoder.encode(pinnedSessions) { preferences.set(data, forKey: "pinnedSessions") }
        if interactive { refreshActivities() }
    }

    private func refreshActivities() {
        guard activityTask == nil else { return }
        if recentlyCompleted != nil, Date.now > completedUntil { recentlyCompleted = nil }
        let sessions = pinnedSessions.map { pin in codexSessions.first(where: { $0.id == pin.id }) ?? pin }
        let dates = monitoredDates
        let previousActivities = activities
        activityTask = Task { @MainActor in
            let updates = await Task.detached(priority: .utility) {
                var updates: [String: SessionActivity] = [:]
                for session in sessions {
                    guard let path = session.sourcePath else {
                        updates[session.id] = SessionActivity(message: "尚未找到会话记录，请刷新列表或重新置顶")
                        continue
                    }
                    let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    let previous = previousActivities[session.id]
                    if dates[session.id] != date || (Date.now.timeIntervalSince(date) > 600 && (previous?.phase == .running || previous?.phase == .waiting)) {
                        updates[session.id] = ActivityReader.read(path: path, previous: previous?.phase == .unknown ? nil : previous)
                    }
                }
                return updates
            }.value
            for (id, activity) in updates {
                guard pinnedSessions.contains(where: { $0.id == id }) else { continue }
                if let previous = activities[id], previous.phase == .running || previous.phase == .waiting,
                   activity.phase == .completed {
                    recentlyCompleted = id
                    completedUntil = .now.addingTimeInterval(10)
                    if options.completionSound { NSSound(named: "Blow")?.play() }
                    if options.completionAlert && options.isTabVisible(1) { selectedTab = 1; isExpanded = true; NotificationCenter.default.post(name: .init("IslandAgentAlert"), object: nil) }
                }
                if activity.phase == .waiting, activities[id]?.phase != .waiting, options.completionAlert, options.isTabVisible(1) {
                    selectedTab = 1; isExpanded = true
                    NotificationCenter.default.post(name: .init("IslandAgentAlert"), object: nil)
                }
                activities[id] = activity
                monitoredDates[id] = activity.updatedAt
            }
            activityTask = nil
        }
    }

    func clearAll() {
        for item in items { remove(item) }
        if items.isEmpty { feedback = "已清空收纳内容" }
    }

    func edit(_ item: PinItem, text: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard items[i].payload != text else { return }
        var updated = items[i]
        updated.payload = text
        updated.title = String(text.components(separatedBy: .newlines).first?.prefix(80) ?? "")
        if updated.title.isEmpty { updated.title = "未命名文字" }
        items[i] = updated
    }

    private func validate(_ item: PinItem) -> Bool {
        if [.image, .file, .folder].contains(item.kind), !fm.fileExists(atPath: item.payload) {
            notice = "原文件已移动或删除，请重新添加"; return false
        }
        return true
    }

    private func revealNewContent() {
        if capturingAutomatic || suppressDropReveal || persistenceError != nil { return }
        feedback = "已添加到收纳区"
        selectedTab = 0
        resetFilters()
        selectedIDs.removeAll()
        selectionMode = false
        if options.arrivalAnimation { isExpanded = true }
        guard interactive else { return }
        NotificationCenter.default.post(name: .init("IslandReveal"), object: nil)
        if options.arrivalSound { NSSound(named: "Glass")?.play() }
    }

    private func persistOptions() {
        if let data = try? encoder.encode(options) { preferences.set(data, forKey: "options") }
    }

    func setTabVisible(_ id: Int, visible: Bool) {
        guard (0...3).contains(id) else { return }
        if !visible && options.isTabVisible(id) && options.visibleTabIDs.count == 1 { return }
        var hidden = Set(options.hiddenTabs ?? [])
        if visible { hidden.remove(id) } else { hidden.insert(id) }
        options.hiddenTabs = hidden.sorted()
    }

    func newNote() {
        var note = PinItem(kind: .text, title: "新便签", payload: "")
        note.isNote = true
        items.append(note)
        revealNewContent()
        editingNoteID = note.id
        previewOpen = true
        isExpanded = true
    }

    var allTags: [String] { Array(Set(items.flatMap { $0.tags ?? [] })).sorted() }
    func setTags(_ item: PinItem, text: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].tags = Array(Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    }
    func reorder(_ id: UUID, before target: UUID) {
        guard id != target else { return }
        var ordered = items.sorted { ($0.manualOrder ?? -$0.createdAt.timeIntervalSince1970) < ($1.manualOrder ?? -$1.createdAt.timeIntervalSince1970) }.map(\.id)
        guard let from = ordered.firstIndex(of: id), let to = ordered.firstIndex(of: target) else { return }
        ordered.remove(at: from)
        let targetIndex = ordered.firstIndex(of: target) ?? min(to, ordered.count)
        ordered.insert(id, at: targetIndex)
        var updated = items
        for (rank, id) in ordered.enumerated() {
            if let i = updated.firstIndex(where: { $0.id == id }) { updated[i].manualOrder = Double(rank) }
        }
        options.sortOrder = "manual"
        items = updated
    }
    func removeSelected() {
        for item in items where selectedIDs.contains(item.id) { remove(item) }
        selectedIDs.removeAll(); selectionMode = false
    }
    func clearHistory() {
        for item in items where item.isAutomatic == true && !item.isFavorite { remove(item) }
    }
    private func pollClipboard() {
        guard options.clipboardEnabled, !options.clipboardPaused else { clipboardChange = NSPasteboard.general.changeCount; return }
        let pb = NSPasteboard.general
        guard pb.changeCount != clipboardChange else { return }
        clipboardChange = pb.changeCount
        let excluded = options.excludedApps.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier != Bundle.main.bundleIdentifier,
              !excluded.contains(front?.bundleIdentifier ?? ""), !excluded.contains(front?.localizedName ?? "") else { return }
        // Password managers mark confidential/transient clipboard data; don't retain it.
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !blocked.contains(where: { pb.types?.contains(NSPasteboard.PasteboardType($0)) == true }) else { return }
        if let string = pb.string(forType: .string), items.contains(where: { $0.payload == string }) { return }
        capturingAutomatic = true
        capturePasteboard()
        capturingAutomatic = false
        if options.historyMonths > 0, let cutoff = Calendar.current.date(byAdding: .month, value: -options.historyMonths, to: .now) {
            for item in items where item.isAutomatic == true && !item.isFavorite && item.createdAt < cutoff { remove(item) }
        }
    }
    func skipClipboardChange() { clipboardChange = NSPasteboard.general.changeCount }
    func recordUse(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].lastUsedAt = .now }
    }
}
