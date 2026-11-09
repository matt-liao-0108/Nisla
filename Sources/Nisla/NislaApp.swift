import SwiftUI
import AppKit
import Combine
import Carbon
import ApplicationServices

#if !ISLAND_PANEL_PREVIEW
@main
#endif
struct NislaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: PinStore
    override init() {
        if Bundle.main.bundleIdentifier == "local.island.demo" || ProcessInfo.processInfo.environment["ISLAND_DEMO_MODE"] == "1" {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandDemo-" + UUID().uuidString)
            store = PinStore(storageDirectory: directory, preferences: UserDefaults(suiteName: "IslandDemo")!, interactive: false)
            store.add(text: "今天的设计检查\n让常用内容保持触手可及。")
            store.add(text: "- [ ] 检查便签\n- [x] 验证筛选")
        } else { store = PinStore() }
        super.init()
    }
    private var panel: IslandPanel?
    private var panels: [IslandPanel] = []
    private var statusItem: NSStatusItem?
    private var eventMonitor: Any?
    private var localPointerMonitor: Any?
    private let outsideClickMonitor = ShelfOutsideClickMonitor.shared
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var appliedOptions: IslandOptions?
    private var recordingShortcut = false
    private var musicMonitor: Task<Void, Never>?
    private var hudTemporarilyRevealed: IslandPanel?
    private var headphoneTemporarilyRevealed: IslandPanel?
    private var lastHeadphoneID: String?
    private var capturingSelection = false
    private var restoreExpandedAfterAuthorization = false
    private let menuBarMonitor = MenuBarMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        rebuildPanels()
        CalendarStore.shared.$authorizationInProgress.sink { [weak self] requesting in
            guard let self else { return }
            if requesting {
                self.restoreExpandedAfterAuthorization = self.store.isExpanded
                self.panels.forEach { $0.ignoresMouseEvents = true }
                self.store.isExpanded = false
            } else {
                self.panels.forEach { $0.ignoresMouseEvents = false }
                if self.restoreExpandedAfterAuthorization {
                    self.restoreExpandedAfterAuthorization = false
                    self.store.isExpanded = true
                }
            }
        }.store(in: &cancellables)
        // Mouse movement only: no key events, event tap or permission prompt.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels.forEach { $0.updateHoverAnchor() } }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.panels.forEach { $0.updateHoverAnchor() } }
            return event
        }
        outsideClickMonitor.start(store: store) {
            NSApp.modalWindow != nil || NSApp.windows.contains { $0.isVisible && CenteredNoticeAlert.shared.owns($0) }
                || SystemHUD.shared.reading != nil || HeadphoneConnection.shared.reading != nil
        }
        SystemHUD.shared.configure(volume: store.options.hudVolumeEnabled ?? false,
                                   brightness: store.options.hudBrightnessEnabled ?? false)
        SystemHUD.shared.$reading.sink { [weak self] reading in
            guard let self else { return }
            if reading != nil { HeadphoneConnection.shared.dismiss() }
            if reading != nil, !self.panels.contains(where: \.isVisible), let target = self.panels.first {
                self.hudTemporarilyRevealed = target
                target.orderFrontRegardless()
            } else if reading == nil, let target = self.hudTemporarilyRevealed {
                if !self.store.isExpanded && HeadphoneConnection.shared.reading == nil { target.orderOut(nil) }
                else if HeadphoneConnection.shared.reading != nil { self.headphoneTemporarilyRevealed = target }
                self.hudTemporarilyRevealed = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.panels.forEach { $0.setExpanded(self.store.isExpanded) }
            }
        }.store(in: &cancellables)
        Publishers.Merge(HeadphoneConnection.shared.$reading.map { _ in () },
                         HeadphoneConnection.shared.$compact.map { _ in () }).sink { [weak self] _ in
            // @Published emits before assignment; size the panel from the new
            // value on the next main-loop pass without changing shelf/tab state.
            DispatchQueue.main.async {
                guard let self else { return }
                let currentID = HeadphoneConnection.shared.reading?.id
                let newConnection = currentID != nil && currentID != self.lastHeadphoneID
                self.lastHeadphoneID = currentID
                if newConnection,
                   !self.panels.contains(where: \.isVisible),
                   let target = self.panels.first(where: { (self.store.options.dockPositions[$0.targetScreenID] ?? "top") == "top" }) {
                    self.headphoneTemporarilyRevealed = target
                    target.orderFrontRegardless()
                }
                self.panels.forEach { $0.setExpanded(self.store.isExpanded) }
                if HeadphoneConnection.shared.reading == nil, let target = self.headphoneTemporarilyRevealed {
                    if !self.store.isExpanded && SystemHUD.shared.reading == nil { target.orderOut(nil) }
                    else if SystemHUD.shared.reading != nil { self.hudTemporarilyRevealed = target }
                    self.headphoneTemporarilyRevealed = nil
                }
            }
        }.store(in: &cancellables)
        HeadphoneConnection.shared.configure(enabled: store.options.headphoneConnectionEnabled ?? false, allowAuthorizationPrompt: false)
        Publishers.CombineLatest(CodexConnection.shared.$connected, CodexConnection.shared.$sessions)
            .map { connected, sessions in connected ? sessions : [] }
            .removeDuplicates()
            .sink { [weak self] sessions in self?.store.connectedCodexSessions = sessions }
            .store(in: &cancellables)
        CursorConnection.shared.$sessions
            .sink { [weak self] sessions in self?.store.cursorSessionCount = sessions.count }
            .store(in: &cancellables)
        Publishers.CombineLatest3(CursorConnection.shared.$activeSessionID, CursorConnection.shared.$sessions, CursorConnection.shared.$permissions)
            .sink { [weak self] id, sessions, permissions in
                self?.store.cursorActiveTitle = id.map { active in sessions.first(where: { $0.id == active })?.title ?? "Cursor" }
                self?.store.cursorWaiting = !permissions.isEmpty
            }.store(in: &cancellables)
        MusicStore.shared.$track.map { $0 != nil }.removeDuplicates()
            .sink { [weak self] available in self?.store.musicHasTrack = available }
            .store(in: &cancellables)
        // One monitor across all displays; keep compact music metadata fresh too.
        musicMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.store.options.isTabVisible(3), MusicStore.shared.enabled {
                    await MusicStore.shared.refresh(automatic: true)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        store.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.panels.forEach { $0.setExpanded(self.store.isExpanded) }
                }
            }
            .store(in: &cancellables)
        setupMenuBar()
        NotificationCenter.default.publisher(for: .nislaLanguageChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                self.setupMenuBar()
                self.settingsWindow?.title = L10n.text("Nisla 设置")
            }.store(in: &cancellables)
        menuBarMonitor.start { [weak self] reading in
            self?.panels.forEach { $0.updateMenuBar(reading) }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                self?.menuBarMonitor.invalidate()
                self?.panels.forEach { $0.updateMenuBar(MenuBarOccupancy(items: nil, menuBar: nil)) }
            }.store(in: &cancellables)
        }
        appliedOptions = store.options
        // Published emits before options is assigned: pass the emitted width
        // through directly rather than reading the previous value from store.
        store.$options.map(\.shelfWidth).removeDuplicates().dropFirst().sink { [weak self] width in
            guard let self else { return }
            self.panels.forEach { $0.setExpanded(self.store.isExpanded, shelfWidth: width) }
        }.store(in: &cancellables)
        store.$options.removeDuplicates().dropFirst().debounce(for: .milliseconds(150), scheduler: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setupClipboardShortcut()
                self.statusItem?.isVisible = self.store.options.showMenuIcon
                let old = self.appliedOptions
                let options = self.store.options
                if old?.headphoneConnectionEnabled != options.headphoneConnectionEnabled {
                    HeadphoneConnection.shared.configure(enabled: options.headphoneConnectionEnabled ?? false)
                }
                if !self.recordingShortcut && (old?.hudVolumeEnabled != options.hudVolumeEnabled || old?.hudBrightnessEnabled != options.hudBrightnessEnabled) {
                    SystemHUD.shared.configure(volume: options.hudVolumeEnabled ?? false, brightness: options.hudBrightnessEnabled ?? false)
                }
                if old?.screenID != options.screenID || old?.allDisplays != options.allDisplays || old?.dockPositions != options.dockPositions {
                    self.rebuildPanels()
                }
                self.appliedOptions = options
            }
        }.store(in: &cancellables)
        setupClipboardShortcut()
        NotificationCenter.default.publisher(for: .init("IslandShortcutRecording"))
            .sink { [weak self] notification in
                guard let self else { return }
                self.recordingShortcut = notification.object as? Bool ?? false
                if self.recordingShortcut {
                    SystemHUD.shared.stop()
                    self.hotKeys.forEach { UnregisterEventHotKey($0) }; self.hotKeys.removeAll()
                } else {
                    self.setupClipboardShortcut()
                    SystemHUD.shared.configure(volume: self.store.options.hudVolumeEnabled ?? false,
                                               brightness: self.store.options.hudBrightnessEnabled ?? false)
                }
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .init("IslandReveal"))
            .sink { [weak self] _ in self?.panels.forEach { $0.orderFrontRegardless() } }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .init("IslandAgentAlert"))
            .sink { [weak self] _ in
                guard let self, self.store.options.isTabVisible(1) else { return }
                self.store.selectedTab = 1
                self.store.isExpanded = true
                let target = self.panels.first { $0.targetScreenID == self.store.options.alertScreenID } ?? self.panels.first
                target?.orderFrontRegardless()
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.menuBarMonitor.invalidate()
                self.rebuildPanels()
        }.store(in: &cancellables)
    }

    private func setupMenuBar() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = IslandBrand.menuIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.text("显示 / 隐藏 Nisla"), action: #selector(togglePanel), keyEquivalent: "i")
        menu.addItem(withTitle: L10n.text("收纳当前剪贴板"), action: #selector(pinClipboard), keyEquivalent: "p")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("关于 Nisla"), action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("设置…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: L10n.text("退出 Nisla"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        menu.items.last?.target = NSApp
        item.menu = menu
        statusItem = item
        item.isVisible = store.options.showMenuIcon
    }

    private func setupClipboardShortcut() {
        guard !recordingShortcut else { return }
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler); self.hotKeyHandler = nil }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let id = key.id
            Task { @MainActor in delegate.handleShortcut(id) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let o = store.options
        let bindings = [(o.pinKey,o.pinModifiers),(o.toggleKey,o.toggleModifiers),(o.noteKey,o.noteModifiers),(o.selectionKey,o.selectionModifiers)]
        for (index, binding) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.0, binding.1, EventHotKeyID(signature: 0x49534C44, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &ref)
            if let ref { hotKeys.append(ref) }
            if status != noErr { store.notice = "第 \(index + 1) 个快捷键注册失败，请在设置中更换组合键。" }
        }
    }

    private func handleShortcut(_ id: UInt32) {
        switch id {
        case 1: pinClipboard()
        case 2: togglePanel()
        case 3: store.newNote()
        case 4: captureSelection()
        default: break
        }
    }

    private func captureSelection() {
        guard !capturingSelection else { return }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            store.notice = "请在系统设置的辅助功能中允许 Nisla，然后重试捕获选中内容。"; return
        }
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let count = pb.changeCount
        capturingSelection = true
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: down)
            event?.flags = .maskCommand; event?.post(tap: .cghidEventTap)
        }
        Task { @MainActor in
            defer { capturingSelection = false }
            try? await Task.sleep(for: .milliseconds(250))
            if pb.changeCount != count {
                store.capturePasteboard()
                pb.clearContents(); pb.writeObjects(saved)
                store.skipClipboardChange()
            } else { store.notice = "当前应用没有提供可复制的选中内容。" }
        }
    }

    private func rebuildPanels() {
        hudTemporarilyRevealed = nil
        headphoneTemporarilyRevealed = nil
        panels.forEach { $0.orderOut(nil) }
        let screens = NSScreen.screens
        let automatic = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first
        let selected = screens.first(where: { $0.islandID == store.options.screenID }) ?? automatic
        let targets = store.options.allDisplays ? screens : selected.map { [$0] } ?? []
        panels = targets.map { screen in
            let panel = IslandPanel(store: store, screen: screen)
            panel.ignoresMouseEvents = CalendarStore.shared.authorizationInProgress
            panel.orderFrontRegardless()
            return panel
        }
        panel = panels.first
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        outsideClickMonitor.stop()
        menuBarMonitor.stop()
        musicMonitor?.cancel()
        SystemHUD.shared.stop()
        HeadphoneConnection.shared.stop()
        CodexConnection.shared.disconnect()
        CursorConnection.shared.disconnect()
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    @objc private func togglePanel() {
        // Explicit user visibility wins over a temporary toast's later expiry.
        hudTemporarilyRevealed = nil
        headphoneTemporarilyRevealed = nil
        let visible = panels.contains(where: \.isVisible)
        panels.forEach { if visible { $0.orderOut(nil) } else { $0.orderFrontRegardless() } }
    }
    @objc private func pinClipboard() { store.capturePasteboard() }
    @objc private func openAbout() {
        store.isExpanded = false
        NislaAbout.show()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.text("Nisla 设置")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store))
            SettingsWindowStyle.configure(window)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

final class IslandPanel: NSPanel {
    private let store: PinStore
    private var resizeTask: Task<Void, Never>?
    private var resizeTarget: NSRect?
    private var resizeGeneration = 0
    private var applyingFrame = false
    private var geometryObservers: [NSObjectProtocol] = []
    private var headphonePresentationActive = false
    private var hudPresentationActive = false
    private var menuBar = MenuBarOccupancy(items: nil, menuBar: nil)
    private var pointerTask: Task<Void, Never>?
    let targetScreenID: String
    private let layout = PanelLayout()

    init(store: PinStore, screen: NSScreen) {
        self.store = store
        targetScreenID = screen.islandID
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 270, height: 42)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        let hostingView = NSHostingView(rootView: ShelfView().environmentObject(store).environmentObject(layout))
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = contentRect(forFrameRect: frame)
        contentView = hostingView
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            geometryObservers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreSettledGeometry() }
            })
        }
        layout.hoverChanged = { [weak self] in
            guard let self, !self.store.isExpanded else { return }
            self.setExpanded(false)
        }
        setExpanded(store.isExpanded)
        pointerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateHoverAnchor()
                // AppKit can reposition the source panel while a detached
                // popover is closing, including without a later state change.
                if let self, !self.store.previewOpen { self.restoreSettledGeometry() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        SystemHUD.shared.dismissPresentation()
        HeadphoneConnection.shared.dismiss()
        ShelfOutsideClickMonitor.shared.requestCollapse(store: store, force: true)
        setExpanded(store.isExpanded)
    }

    /// AppKit can adjust a popover's source window while dismissing it. The
    /// cached destination is not proof the native window is still at that frame.
    private func restoreSettledGeometry() {
        guard !applyingFrame, resizeTask == nil, !store.isResizingWidth,
              let target = resizeTarget, !matchesFrame(target) else { return }
        applyFrame(target)
    }

    private func matchesFrame(_ target: NSRect) -> Bool {
        abs(frame.minX - target.minX) < 0.5 && abs(frame.minY - target.minY) < 0.5
            && abs(frame.width - target.width) < 0.5 && abs(frame.height - target.height) < 0.5
    }

    private func applyFrame(_ target: NSRect) {
        applyingFrame = true
        setFrame(target, display: true)
        contentView?.layoutSubtreeIfNeeded()
        applyingFrame = false
    }

    func position() {
        resizeTarget = nil
        setExpanded(store.isExpanded)
    }

    func updateMenuBar(_ reading: MenuBarOccupancy) {
        menuBar = reading
        // Shrinking on newly occupied space is immediate, not a slow animation
        // through the other application's icon.
        setExpanded(store.isExpanded, menuBarUpdate: true)
    }

    func updateHoverAnchor() {
        guard layout.attachedToMenuBar, isVisible, layout.dock == "top",
              let screen = NSScreen.screens.first(where: { $0.islandID == targetScreenID }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            if layout.anchorHovered { layout.anchorHovered = false }
            return
        }
        let notch = CGRect(x: left.maxX, y: screen.frame.maxY - max(32, screen.safeAreaInsets.top),
            width: max(0, right.minX - left.maxX), height: max(32, screen.safeAreaInsets.top))
        let mode = MenuBarAvoidance.presentation(notch: notch, screen: screen.frame, occupancy: menuBar)
        let height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) + 4
        let anchor = CGRect(x: notch.midX - (notch.width + mode.extraWidth) / 2,
            y: screen.frame.maxY - height, width: notch.width + mode.extraWidth, height: height)
        let pointer = NSEvent.mouseLocation
        let hovered = anchor.contains(pointer)
        if layout.anchorHovered != hovered { layout.anchorHovered = hovered }
    }

    func setExpanded(_ expanded: Bool, menuBarUpdate: Bool = false, shelfWidth: CGFloat? = nil) {
        guard let targetScreen = NSScreen.screens.first(where: { $0.islandID == targetScreenID }) ?? screen ?? NSScreen.main else { return }
        let notchWidth: CGFloat
        if let left = targetScreen.auxiliaryTopLeftArea, let right = targetScreen.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
        } else { notchWidth = 0 }
        let dock = store.options.dockPositions[targetScreenID] ?? "top"
        let displayID = (targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let nativeSupport = NativeIslandCompatibility.current(builtInDisplay: displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false)
        let floating = dock == "top" && store.options.usesFloatingIsland(nativeSupport: nativeSupport)
        let headerHeight = max(32, targetScreen.safeAreaInsets.top)
        let actualHeader = floating ? FloatingIslandGeometry.headerHeight : dock == "top" ? headerHeight : 32
        if layout.headerHeight != actualHeader { layout.headerHeight = actualHeader }
        if layout.dock != dock { layout.dock = dock }
        let hudVisible = SystemHUD.shared.reading != nil && dock == "top"
        let connectionVisible = HeadphoneConnection.shared.reading != nil && dock == "top" && !hudVisible
        let compactConnection = connectionVisible && HeadphoneConnection.shared.compact
        let notchCenter = targetScreen.auxiliaryTopLeftArea.map { $0.maxX + notchWidth / 2 } ?? targetScreen.frame.midX
        let notch = CGRect(x: notchCenter - notchWidth / 2, y: targetScreen.frame.maxY - headerHeight,
            width: notchWidth, height: headerHeight)
        let mode = MenuBarAvoidance.presentation(notch: notch, screen: targetScreen.frame, occupancy: menuBar)
        // Avoidance is limited to the compact wings. Expansion remains attached
        // to the top edge, including the original physical-notch header.
        let widePresentation = expanded || connectionVisible || SystemHUD.shared.reading != nil || notchWidth == 0
        let attached = dock == "top" && !floating
        if layout.attachedToMenuBar != attached { layout.attachedToMenuBar = attached }
        let oldMode = layout.compactPresentation
        let presentation: CompactPresentation = floating || widePresentation || dock != "top" ? .full : mode
        if layout.compactPresentation != presentation { layout.compactPresentation = presentation }
        let actualNotch = dock == "top" && !floating ? notchWidth : 0
        if layout.notchWidth != actualNotch { layout.notchWidth = actualNotch }
        let headphoneTransition = connectionVisible || headphonePresentationActive
        headphonePresentationActive = connectionVisible
        let hudTransition = hudVisible || hudPresentationActive
        hudPresentationActive = hudVisible
        let expandedWidth = shelfWidth ?? store.options.shelfWidth
        let bodyHeight = ShelfGeometry.bodyHeight(store.bodyHeight, floating: floating, selectedTab: store.selectedTab)
        var size = hudVisible ? SystemHUDGeometry.size(notchWidth: actualNotch, headerHeight: floating ? 0 : layout.headerHeight)
            : connectionVisible
            ? NSSize(width: compactConnection ? max(270, notchWidth + 210) : max(440, min(580, expandedWidth)),
                     height: layout.headerHeight + (compactConnection ? 0 : 96))
            : NSSize(width: expanded ? expandedWidth : dock == "top" ? (widePresentation ? max(270, notchWidth + 210) : notchWidth + mode.extraWidth) : 24, height: expanded ? layout.headerHeight + bodyHeight + ShelfGeometry.footerHeight : dock == "top" ? layout.headerHeight : 96)
        if floating, !expanded, !hudVisible, !connectionVisible {
            let codexActive = store.options.isTabVisible(1) && (store.activeCount > 0 || store.waitingCount > 0 || store.recentlyCompleted != nil)
            let musicActive = store.options.isTabVisible(3) && MusicStore.shared.enabled && MusicStore.shared.track != nil
            size.width = FloatingIslandGeometry.compactWidth(hasActivity: codexActive || musicActive)
        } else if floating, compactConnection { size.width = FloatingIslandGeometry.compactWidth(hasActivity: true) }
        let hoverFeedback = !expanded && dock == "top" && !hudVisible && !connectionVisible
        if hoverFeedback && (layout.surfaceHovered || layout.anchorHovered) {
            // Keep the same center/top anchor; do not grow into occupied menu items.
            size.width += floating || presentation == .full ? 12 : 0
            size.height += 3
        }
        var newFrame: NSRect
        if floating {
            newFrame = FloatingIslandGeometry.frame(screen: targetScreen.frame, visible: targetScreen.visibleFrame,
                safeTop: targetScreen.safeAreaInsets.top, size: size)
        } else if dock == "top" {
            newFrame = MenuBarAvoidance.topFrame(center: notchCenter, screenTop: targetScreen.frame.maxY,
                size: size)
        }
        else { newFrame = NSRect(x: dock == "left" ? targetScreen.frame.minX : targetScreen.frame.maxX - size.width, y: targetScreen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height) }
        if dock == "top" { newFrame = MenuBarAvoidance.nativeTopFrame(newFrame) }
        if resizeTarget == newFrame {
            if resizeTask != nil || matchesFrame(newFrame) { return }
            applyFrame(newFrame)
            return
        }
        resizeTarget = newFrame
        resizeTask?.cancel()
        resizeTask = nil
        resizeGeneration &+= 1
        let generation = resizeGeneration
        let urgentShrink = menuBarUpdate && !widePresentation && presentation.rawValue < oldMode.rawValue
        guard isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !urgentShrink, !store.isResizingWidth else {
            applyFrame(newFrame)
            return
        }
        // One animation owns both the native window and its hosting view. Start
        // from the current frame so quick reversals never jump to an old target.
        let start = frame
        let opening = newFrame.height > start.height + 0.5
            || (abs(newFrame.height - start.height) < 0.5 && newFrame.width > start.width + 0.5)
        let resizingContent = abs(start.width - newFrame.width) < 0.5
            && min(start.height, newFrame.height) > layout.headerHeight + 1
        let duration = hoverFeedback && max(start.height, newFrame.height) <= layout.headerHeight + 3.5 ? 0.14 : hudTransition ? IslandMotion.hudDuration(opening: opening)
            : headphoneTransition ? (opening ? 0.46 : 0.38)
            : IslandMotion.shelfDuration(opening: opening, resizingContent: resizingContent)
        resizeTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.resizeGeneration == generation {
                    self.resizeTask = nil
                    self.restoreSettledGeometry()
                }
            }
            let began = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self, self.resizeGeneration == generation else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / duration)
                if dock == "top" {
                    let safeFrame = MenuBarAvoidance.frame(from: start, to: newFrame,
                        progress: progress, opening: opening, resizingContent: resizingContent,
                        headphone: headphoneTransition, compactOnly: max(start.height, newFrame.height) <= layout.headerHeight + 3.5,
                        hud: hudTransition)
                    self.applyFrame(MenuBarAvoidance.nativeTopFrame(safeFrame,
                        center: newFrame.midX, top: newFrame.maxY))
                    if progress == 1 { break }
                    try? await Task.sleep(for: .milliseconds(16))
                    continue
                }
                let motion = headphoneTransition ? IslandMotion.headphoneProgress(progress, opening: opening)
                    : resizingContent ? (width: IslandMotion.spring(progress), height: IslandMotion.spring(progress))
                    : IslandMotion.progress(progress, opening: opening)
                let width = start.width + (newFrame.width - start.width) * motion.width
                let height = start.height + (newFrame.height - start.height) * motion.height
                let x = dock == "top" ? newFrame.midX - width / 2 : dock == "left" ? newFrame.minX : newFrame.maxX - width
                let y = dock == "top" ? newFrame.maxY - height : newFrame.midY - height / 2
                self.applyFrame(NSRect(x: x, y: y, width: width, height: height))
                if progress == 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    isolated deinit {
        pointerTask?.cancel(); resizeTask?.cancel()
        geometryObservers.forEach(NotificationCenter.default.removeObserver)
    }


    func toggle() {
        if isVisible { orderOut(nil) } else { position(); orderFrontRegardless() }
    }
}

@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 0
    @Published var headerHeight: CGFloat = 32
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    var hoverChanged: (() -> Void)?
    @Published var surfaceHovered = false { didSet { if oldValue != surfaceHovered { hoverChanged?() } } }
    @Published var anchorHovered = false { didSet { if oldValue != anchorHovered { hoverChanged?() } } }
    @Published var attachedToMenuBar = true
}
