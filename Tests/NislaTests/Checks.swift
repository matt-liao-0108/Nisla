import Foundation
import AppKit

@main
struct Checks {
    @MainActor static func main() throws {
        for reveal: CGFloat in [0, 0.2, 0.6, 0.9, 1] {
            precondition(!ShelfGeometry.showsFooter(expanded: false, reveal: reveal))
            precondition(ShelfGeometry.showsFooter(expanded: true, reveal: reveal) == (reveal > 0.6))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "IslandChecks-" + UUID().uuidString)!
        let store = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        store.selectedTab = 3
        precondition(store.bodyHeight == 188)
        store.musicHasTrack = true
        precondition(store.bodyHeight == 156)
        store.musicShowsProgress = true
        precondition(store.bodyHeight == 198)
        store.selectedTab = 0; store.selectedTab = 3
        precondition(store.musicShowsProgress && store.bodyHeight == 198)
        store.musicHasTrack = false
        precondition(store.bodyHeight == 188)
        store.musicGuidanceLines = 1
        precondition(store.bodyHeight == 160)
        store.musicGuidanceLines = 2
        precondition(store.bodyHeight == 174)
        store.musicGuidanceLines = 3
        store.selectedTab = 2
        for (rows, height) in [(4, 154.0), (5, 175), (6, 196)] {
            store.calendarWeekRows = rows
            precondition(store.bodyHeight == height)
        }
        store.musicShowsProgress = false; store.selectedTab = 0
        print("PASS: music height follows guidance lines and timeline; calendar height fits four, five and six weeks")
        let layoutSessions = (0..<6).map { CodexSession(id: "layout-\($0)", title: "Layout \($0)", project: "Fixture", modifiedAt: .now, isRunning: false) }
        store.selectedTab = 1
        precondition(store.bodyHeight == 200)
        for (count, height) in [(1, 134.0), (2, 192), (4, 308), (6, 308)] {
            store.pinnedSessions = Array(layoutSessions.prefix(count))
            precondition(store.bodyHeight == height && store.visibleCodexSessions.count == count)
        }
        store.showRecentSessions = true
        store.codexSessions = layoutSessions
        store.connectedCodexSessions = [layoutSessions[0]]
        precondition(store.bodyHeight == 134 && store.visibleCodexSessions.count == 1)
        store.connectedCodexSessions = []
        precondition(store.bodyHeight == 308 && store.visibleCodexSessions.count == 6)
        store.pinnedSessions = []; store.codexSessions = []
        store.showRecentSessions = false; store.selectedTab = 0
        store.refreshCodex()
        precondition(!store.isRefreshing && store.codexSessions.isEmpty)
        print("PASS: Codex height follows displayed rows, caps at four rows, and fixture stores never scan real logs")
        let legacyOptions = try JSONEncoder().encode(IslandOptions())
        let decodedLegacy = try JSONDecoder().decode(IslandOptions.self, from: legacyOptions)
        precondition(decodedLegacy.activityColorHex == nil)
        store.options.activityColorHex = "468CFF"
        let colorRestored = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        precondition(colorRestored.options.activityColorHex == "468CFF")
        print("PASS: activity color persistence and legacy options compatibility")
        let savedBeforeResize = defaults.data(forKey: "options")
        store.isResizingWidth = true
        for width in stride(from: 600.0, through: 800.0, by: 4) { store.options.shelfWidth = width }
        precondition(defaults.data(forKey: "options") == savedBeforeResize, "Drag events must not repeatedly persist preferences")
        store.isResizingWidth = false
        let widthRestored = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        precondition(widthRestored.options.shelfWidth == 800)
        print("PASS: live width changes defer persistence until drag ends and restore the final width")
        var invalidOptions = IslandOptions()
        invalidOptions.shelfWidth = 1e200; invalidOptions.hoverDelay = -3
        invalidOptions.appearance = "invalid"; invalidOptions.sortOrder = "invalid"
        let invalidDefaults = UserDefaults(suiteName: "IslandInvalidOptions-" + UUID().uuidString)!
        invalidDefaults.set(try JSONEncoder().encode(invalidOptions), forKey: "options")
        let repaired = PinStore(storageDirectory: directory, preferences: invalidDefaults, interactive: false)
        precondition(repaired.options.shelfWidth == 960 && repaired.options.hoverDelay == 0.15)
        precondition(repaired.options.appearance == "automatic" && repaired.options.sortOrder == "added")
        print("PASS: invalid stored geometry and settings are normalized before use")
        precondition(decodedLegacy.visibleTabIDs == [0, 1, 2, 3])
        store.selectedTab = 2
        store.setTabVisible(2, visible: false)
        precondition(store.selectedTab == 0 && !store.options.isTabVisible(2))
        store.selectedTab = 2
        precondition(store.selectedTab == 0)
        let tabsRestored = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        precondition(!tabsRestored.options.isTabVisible(2))
        store.setTabVisible(0, visible: false)
        store.setTabVisible(1, visible: false)
        store.setTabVisible(3, visible: false)
        precondition(store.options.visibleTabIDs == [3] && store.selectedTab == 3)
        let onlyMusic = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        precondition(onlyMusic.selectedTab == 3)
        store.setTabVisible(2, visible: true)
        precondition(store.options.visibleTabIDs == [2, 3])
        for id in 0...3 { store.setTabVisible(id, visible: true) }
        store.selectedTab = 0
        var legacyJSON = try JSONSerialization.jsonObject(with: legacyOptions) as! [String: Any]
        legacyJSON.removeValue(forKey: "hiddenTabs")
        let oldPreferences = try JSONDecoder().decode(IslandOptions.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        precondition(oldPreferences.visibleTabIDs == [0, 1, 2, 3])
        print("PASS: tab visibility persistence, fallback, last-tab protection and old preferences")
        let dropStore = PinStore(storageDirectory: directory.appendingPathComponent("DropFixture"),
            preferences: UserDefaults(suiteName: "IslandDropChecks-" + UUID().uuidString)!, interactive: false)
        dropStore.selectedTab = 2
        dropStore.beginDropPresentation()
        precondition(dropStore.selectedTab == 0 && !dropStore.isExpanded)
        dropStore.cancelDropHover()
        precondition(dropStore.selectedTab == 2 && !dropStore.isExpanded && !dropStore.isDropPresentationActive)
        dropStore.isExpanded = true
        dropStore.beginDropPresentation(); dropStore.beginDropPresentation()
        dropStore.cancelDropHover()
        precondition(dropStore.selectedTab == 2 && dropStore.isExpanded)
        let drop = dropStore.beginDropImport(count: 2)
        precondition(dropStore.selectedTab == 0 && dropStore.isExpanded)
        dropStore.cancelDropHover() // Target exit after performDrop is not cancellation.
        dropStore.receiveDrop(drop) { dropStore.add(text: "first dropped item") }
        dropStore.receiveDrop(drop) { dropStore.add(text: "second dropped item") }
        precondition(dropStore.selectedTab == 0 && dropStore.items.count == 2)
        dropStore.isExpanded = false
        precondition(dropStore.selectedTab == 2 && !dropStore.isDropPresentationActive)
        dropStore.isExpanded = true // Ordinary opening retains the original calendar.
        precondition(dropStore.selectedTab == 2)
        let manual = dropStore.beginDropImport(count: 1)
        dropStore.selectedTab = 3
        dropStore.receiveDrop(manual) { dropStore.add(text: "slow item after manual page switch") }
        precondition(dropStore.selectedTab == 3 && dropStore.items.count == 3)
        let late = dropStore.beginDropImport(count: 1)
        dropStore.isExpanded = false
        dropStore.receiveDrop(late) { dropStore.add(text: "slow item after collapse") }
        precondition(dropStore.selectedTab == 3 && !dropStore.isExpanded && dropStore.items.count == 4)
        let failed = dropStore.beginDropImport(count: 1)
        dropStore.receiveDrop(failed) {} // Failed provider still terminates the batch.
        precondition(dropStore.selectedTab == 3 && !dropStore.isExpanded && dropStore.notice != nil)
        dropStore.notice = nil
        dropStore.setTabVisible(0, visible: false)
        let hidden = dropStore.beginDropImport(count: 1)
        precondition(dropStore.selectedTab == 0 && dropStore.isTabPresented(0) && !dropStore.options.isTabVisible(0))
        dropStore.receiveDrop(hidden) { dropStore.add(text: "temporary hidden destination") }
        dropStore.isExpanded = false
        precondition(dropStore.selectedTab == 3 && !dropStore.isTabPresented(0))
        let remembered = PinStore(storageDirectory: directory.appendingPathComponent("DropFixture"),
            preferences: UserDefaults(suiteName: "IslandDropPersist-" + UUID().uuidString)!, interactive: false)
        precondition(remembered.items.count == 5)
        print("PASS: drag destination switches before import; cancel/collapse restore the original page; manual navigation and late providers win; hidden-tab preference stays unchanged")
        store.add(urls: [URL(string: "https://example.com/path?q=1")!])
        let restored = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        precondition(restored.items.first?.kind == .link)
        precondition(restored.items.first?.payload == "https://example.com/path?q=1")
        print("PASS: web URL classification and persistence")
        let favoriteTarget = store.items.first!
        store.toggleFavorite(favoriteTarget)
        let favoriteRestored = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        precondition(favoriteRestored.items.first?.isFavorite == true)
        store.toggleFavorite(favoriteTarget)
        precondition(store.items.first?.isFavorite == false)
        print("PASS: favorite toggle and persistence")
        let used = store.items.first!
        store.recordUse(used.id)
        precondition(store.items.first!.lastUsedAt >= used.lastUsedAt)
        print("PASS: successful use updates recent-use timestamp")

        let session = CodexSession(id: UUID().uuidString, title: "Session", project: "Test", modifiedAt: .now, isRunning: false)
        store.toggleSession(session)
        store.activities[session.id] = SessionActivity(phase: .running)
        store.recentlyCompleted = session.id
        store.toggleSession(session)
        precondition(store.activities[session.id] == nil && store.recentlyCompleted == nil)
        store.toggleSession(session)
        let pinned = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        precondition(pinned.pinnedSessions.first?.id == session.id)
        pinned.toggleSession(session)
        precondition(pinned.pinnedSessions.isEmpty)
        print("PASS: Codex pin persistence and removal")

        store.newNote()
        let note = store.items.last!
        precondition(note.isNote == true)
        store.edit(note, text: "- [ ] 测试任务\n- [x] 已完成")
        let notesRestored = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        precondition(notesRestored.items.last?.payload == "- [ ] 测试任务\n- [x] 已完成")
        store.setTags(note, text: "工作, 临时, 工作")
        store.tagFilter = "工作"
        precondition(store.filteredItems.count == 1)
        store.filter = .image
        precondition(store.filteredItems.isEmpty)
        store.filter = .all; store.tagFilter = nil
        print("PASS: notes autosave, tag deduplication and combined filters")
        store.filter = .image; store.tagFilter = "不存在"; store.query = "无结果"
        store.selectionMode = true
        store.add(text: "new visible content")
        precondition(!store.hasActiveFilters && !store.filteredItems.isEmpty && !store.selectionMode)
        print("PASS: newly added content clears stale filters")

        let original = directory.appendingPathComponent("original.txt")
        try Data("file".utf8).write(to: original)
        store.options.copyFiles = false
        store.add(urls: [original])
        store.remove(store.items.last!)
        precondition(FileManager.default.fileExists(atPath: original.path))
        store.options.copyFiles = true
        store.add(urls: [original])
        let copied = store.items.last!
        precondition(copied.payload != original.path && copied.ownsAsset == true)
        store.remove(copied)
        precondition(!FileManager.default.fileExists(atPath: copied.payload))
        precondition(FileManager.default.fileExists(atPath: original.path))
        print("PASS: reference and copy mode preserve originals")
        store.options.copyFiles = true
        store.add(urls: [original])
        let owner = store.items.last!
        store.options.copyFiles = false
        store.add(urls: [URL(fileURLWithPath: owner.payload)])
        let reference = store.items.last!
        store.remove(owner)
        precondition(FileManager.default.fileExists(atPath: owner.payload))
        precondition(store.items.first(where: { $0.id == reference.id })?.ownsAsset == true)
        store.remove(reference)
        precondition(!FileManager.default.fileExists(atPath: owner.payload))
        precondition(FileManager.default.fileExists(atPath: original.path))
        print("PASS: shared managed files survive owner deletion and are cleaned after the final reference")

        store.add(text: "first"); let first = store.items.last!.id
        store.add(text: "second"); let second = store.items.last!.id
        store.reorder(first, before: second)
        precondition(store.filteredItems.first?.id == first)
        let reordered = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        precondition(reordered.options.sortOrder == "manual" && reordered.filteredItems.first?.id == first)
        store.selectedIDs = [first]; store.removeSelected()
        precondition(!store.items.contains { $0.id == first })
        print("PASS: ordering persistence and multi-delete")

        var automatic = PinItem(kind: .text, title: "History", payload: "auto")
        automatic.isAutomatic = true
        store.items.append(automatic)
        var favorite = PinItem(kind: .text, title: "Favorite history", payload: "protected")
        favorite.isAutomatic = true; favorite.isFavorite = true
        store.items.append(favorite)
        store.clearHistory()
        precondition(!store.items.contains { $0.id == automatic.id })
        precondition(store.items.contains { $0.id == favorite.id })
        print("PASS: history cleanup protects favorites")

        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 20, height: 20).fill(); image.unlockFocus()
        store.add(image: image)
        let savedImage = store.items.last!
        precondition(FileManager.default.fileExists(atPath: savedImage.payload))
        store.clearAll()
        precondition(store.items.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: savedImage.payload))
        print("PASS: clear removes stored images")

        let file = directory.appendingPathComponent("pins.json")
        let invalid = Data("broken json".utf8)
        try invalid.write(to: file)
        let corrupted = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        corrupted.add(text: "new")
        let preserved = try Data(contentsOf: file)
        precondition(preserved == invalid)
        precondition(corrupted.notice != nil)
        print("PASS: corrupt history preserved")

        let running = Data("""
        {"timestamp":"2026-10-30T04:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"正在检查文件"}]}}
        """.utf8)
        let activity = ActivityReader.parse(data: running, modified: .now)
        precondition(activity.phase == .running && activity.message == "正在检查文件")
        let completed = running + Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"完成\"}}".utf8)
        precondition(ActivityReader.parse(data: completed, modified: .now).phase == .completed)
        precondition(ActivityReader.parse(data: running, modified: .now.addingTimeInterval(-700)).phase == .unknown)
        let waiting = running + Data("""

        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"question"}}
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"other"}}
        """.utf8)
        precondition(ActivityReader.parse(data: waiting, modified: .now).phase == .waiting)
        let waitingActivity = ActivityReader.parse(data: waiting, modified: .now)
        let answered = Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"question\"}}".utf8)
        precondition(ActivityReader.parse(data: answered, modified: .now, previous: waitingActivity).phase == .running)
        print("PASS: live activity start, finish, stale and question correlation")
        let largeLog = directory.appendingPathComponent("large-session.jsonl")
        let tool = "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"" + String(repeating: "x", count: 1_200_000) + "\"}}\n"
        try (running + Data("\n".utf8) + Data(tool.utf8)).write(to: largeLog)
        precondition(ActivityReader.read(path: largeLog.path).phase == .running)
        let delta = Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"text\":\"进度更新\"}]}}".utf8)
        precondition(ActivityReader.parse(data: delta, modified: .now, previous: activity).phase == .running)
        print("PASS: lifecycle recovery from large logs and state retention")

        let protectedAsset = directory.appendingPathComponent("Assets/protected.png")
        try FileManager.default.createDirectory(at: protectedAsset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: protectedAsset)
        let protectedPin = PinItem(kind: .image, title: "Protected", payload: protectedAsset.path)
        corrupted.items.append(protectedPin)
        corrupted.feedback = nil
        corrupted.remove(protectedPin)
        precondition(FileManager.default.fileExists(atPath: protectedAsset.path))
        precondition(corrupted.items.contains { $0.id == protectedPin.id })
        corrupted.add(text: "not persisted")
        precondition(corrupted.feedback == nil && corrupted.persistenceError != nil)
        print("PASS: failed persistence keeps assets and suppresses success feedback")
    }
}
