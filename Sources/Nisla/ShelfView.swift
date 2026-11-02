import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject private var localization = AppLocalization.shared
    var animateHeadphoneEntrance = true
    @EnvironmentObject private var store: PinStore
    @EnvironmentObject private var layout: PanelLayout
    @ObservedObject private var music = MusicStore.shared
    @ObservedObject private var hud = SystemHUD.shared
    @ObservedObject private var headphones = HeadphoneConnection.shared
    @State private var isTargeted = false
    @State private var dropHasFiles = false
    @State private var airDropTargeted = false
    @State private var completedDropAt: TimeInterval = 0
    @State private var collapseTask: Task<Void, Never>?
    @State private var dragExpandTask: Task<Void, Never>?
    @State private var dragReleaseTask: Task<Void, Never>?
    @State private var isHovering = false
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool
    @State private var confirmSelection = false
    @State private var suppressHoverUntilExit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var floatingIsland: Bool { !layout.attachedToMenuBar && layout.dock == "top" }
    private var attachedSurface: Bool { layout.attachedToMenuBar && !floatingIsland }
    private var bodyHeight: CGFloat { ShelfGeometry.bodyHeight(store.bodyHeight, floating: floatingIsland, selectedTab: store.selectedTab) }

    var body: some View {
        let hudReading = hud.reading ?? (headphones.reading == nil ? hud.displayReading : nil)
        let showingHUD = hudReading != nil && layout.dock == "top"
        let showingConnection = headphones.reading != nil && layout.dock == "top" && !showingHUD
        let showingOverlay = showingConnection || showingHUD
        ZStack {
            // Keep the page mounted: drafts and page-local state must survive
            // a connection toast, even when the native panel temporarily shrinks.
            shelfContent.opacity(showingOverlay ? 0 : 1)
                .allowsHitTesting(!showingOverlay)
                .accessibilityHidden(showingOverlay)
            if let reading = hudReading, layout.dock == "top" {
                SystemHUDNotificationBanner(reading: reading, headerHeight: floatingIsland ? 0 : layout.headerHeight,
                    appearance: store.options.appearance,
                    attached: attachedSurface)
            } else if let device = headphones.reading, layout.dock == "top" {
                HeadphoneNotificationBanner(device: device, headerHeight: layout.headerHeight,
                    track: music.enabled && store.options.isTabVisible(3) ? music.track : nil,
                    remoteArtwork: music.remoteArtwork, animateEntrance: animateHeadphoneEntrance,
                    attached: attachedSurface)
                    .transition(.identity)
                    .onTapGesture { headphones.dismiss() }
                    .help(L10n.text("点击收起耳机连接提示"))
            }
        }
        .background(ShelfInteractionBoundary())
        .environment(\.locale, localization.locale)
        .onChange(of: showingOverlay) { _, showing in
            if showing { collapseTask?.cancel(); dragExpandTask?.cancel() }
            else { scheduleCollapseIfNeeded() }
        }
        .onDrop(of: [.fileURL, .image, .text, .url], delegate: ShelfDropDelegate(
            targeted: $isTargeted, hasFiles: $dropHasFiles, airDropTargeted: $airDropTargeted,
            completedAt: $completedDropAt, panelWidth: store.options.shelfWidth,
            headerHeight: layout.headerHeight, bodyHeight: bodyHeight,
            isExpanded: store.isExpanded, perform: handleDrop))
        .onChange(of: isTargeted) { _, targeted in
            dragExpandTask?.cancel()
            dragReleaseTask?.cancel()
            collapseTask?.cancel()
            if targeted {
                hud.dismissPresentation()
                headphones.dismiss()
                store.beginDropPresentation()
                dragReleaseTask = Task { @MainActor in
                    // AppKit can omit dropExited after the destination changes
                    // size during a drag. Release must still end the preview.
                    while !Task.isCancelled && isTargeted {
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled else { return }
                        if NSEvent.pressedMouseButtons == 0 {
                            isTargeted = false
                            dropHasFiles = false
                            airDropTargeted = false
                            return
                        }
                    }
                }
                dragExpandTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(store.options.hoverDelay))
                    guard !Task.isCancelled, isTargeted, store.isDropPresentationActive else { return }
                    store.isExpanded = true
                }
            } else {
                // performDrop marks a committed import synchronously. Allow it
                // to run before interpreting target-exit as a cancelled drag.
                dragExpandTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, !isTargeted else { return }
                    store.cancelDropHover()
                    scheduleCollapseIfNeeded()
                }
            }
        }
    }

    private var shelfContent: some View {
        GeometryReader { geometry in
            let collapsedHeight: CGFloat = layout.dock == "top" ? layout.headerHeight : 96
            let expandedHeight = layout.headerHeight + bodyHeight + ShelfGeometry.footerHeight
            let reveal = ShelfGeometry.reveal(height: geometry.size.height, collapsed: collapsedHeight, expanded: expandedHeight)
            let surfaceHeight = floatingIsland ? geometry.size.height
                : ShelfGeometry.surfaceHeight(height: geometry.size.height, collapsed: collapsedHeight, expanded: expandedHeight)
            let contentReveal = min(1, max(0, (reveal - 0.22) / 0.78))
            Group {
             if layout.dock != "top" && !store.isExpanded {
                Button { store.isExpanded = true } label: {
                    Capsule().fill(.white.opacity(0.35)).frame(width: 3, height: 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("展开收纳区"))
             } else { VStack(spacing: 0) {
                collapsedBar
                    .background {
                        if attachedSurface { Color.black.allowsHitTesting(false) }
                    }
                expandedShelf
                    // The native panel is the layout authority during a live
                    // resize. Published options can be one layout pass behind.
                    .frame(width: geometry.size.width)
                    .opacity(store.isExpanded ? contentReveal * contentReveal : 0)
                    .offset(y: reduceMotion ? 0 : -8 * (1 - contentReveal))
                    .animation(reduceMotion ? nil : .easeOut(duration: store.isExpanded ? 0.12 : 0.08), value: store.isExpanded)
                    .allowsHitTesting(store.isExpanded && reveal > 0.95)
                    .accessibilityHidden(!store.isExpanded)
                if floatingIsland && ShelfGeometry.showsFooter(expanded: store.isExpanded, reveal: reveal) {
                    ShelfTabBar(embedded: true)
                        .frame(height: ShelfGeometry.footerHeight)
                        .frame(maxWidth: .infinity)
                        .opacity(max(0, (reveal - 0.6) / 0.4))
                        .allowsHitTesting(store.isExpanded && reveal > 0.95)
                }
             } }
            }
            .frame(width: geometry.size.width, height: surfaceHeight, alignment: .top)
            .modifier(ShelfMaterial(appearance: store.options.appearance, reveal: reveal,
                shape: NotchOutline(reveal: reveal, shoulders: attachedSurface, floating: !attachedSurface),
                shoulders: attachedSurface))
        }
        .focusEffectDisabled()
        .ignoresSafeArea()
        // Mask the entire hosting surface, not just a GeometryReader child.
        .clipShape(ShelfSurfaceShape(collapsedHeight: layout.dock == "top" ? layout.headerHeight : 96,
            expandedHeight: layout.headerHeight + bodyHeight + ShelfGeometry.footerHeight,
            shoulders: attachedSurface, floating: !attachedSurface, integratedFooter: floatingIsland))
        .overlay(alignment: .bottom) {
          if !floatingIsland {
            GeometryReader { geometry in
                let reveal = ShelfGeometry.reveal(height: geometry.size.height, collapsed: layout.dock == "top" ? layout.headerHeight : 96, expanded: layout.headerHeight + bodyHeight + ShelfGeometry.footerHeight)
                // The footer must only receive clicks in its own capsule. A
                // full-height frame here masked calendar day and month buttons.
                VStack(spacing: 0) {
                    Spacer(minLength: 0).allowsHitTesting(false)
                    // Do not rely on opacity to hide compositor-backed glass:
                    // remove the footer before the native window collapses.
                    if ShelfGeometry.showsFooter(expanded: store.isExpanded, reveal: reveal) {
                    ShelfTabBar()
                        .opacity(store.isExpanded ? max(0, (reveal - 0.6) / 0.4) : 0)
                        .offset(y: reduceMotion ? 0 : 5 * (1 - reveal))
                        .padding(.bottom, 1)
                        .allowsHitTesting(store.isExpanded && reveal > 0.95)
                        .accessibilityHidden(!store.isExpanded)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
          }
        }
        .contentShape(Rectangle())
        .environment(\.colorScheme, .dark)
        .onExitCommand { ShelfOutsideClickMonitor.shared.requestCollapse(store: store, force: true) }
        .task(id: store.feedback) {
            guard store.feedback != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { store.feedback = nil }
        }
        .onHover { inside in
            guard headphones.reading == nil, !CalendarStore.shared.authorizationInProgress else { collapseTask?.cancel(); return }
            withAnimation(.easeOut(duration: 0.16)) { isHovering = inside }
            collapseTask?.cancel()
            if !inside && !layout.anchorHovered { suppressHoverUntilExit = false }
            if inside && !isTargeted && !store.isExpanded && !suppressHoverUntilExit && hud.reading == nil {
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(store.options.hoverDelay))
                    guard !Task.isCancelled, !isTargeted, hud.reading == nil, headphones.reading == nil,
                          !CalendarStore.shared.authorizationInProgress else { return }
                    store.isExpanded = true
                }
            }
            if !inside { scheduleCollapseIfNeeded() }
        }
        .onChange(of: store.isExpanded) { old, expanded in
            if old && !expanded {
                if store.previewOpen { store.dismissPreviews() }
                isTargeted = false
                dropHasFiles = false
                airDropTargeted = false
                suppressHoverUntilExit = isHovering || layout.anchorHovered
                collapseTask?.cancel()
                dragExpandTask?.cancel()
            }
        }
        .onChange(of: store.previewOpen) { _, _ in scheduleCollapseIfNeeded() }
        .onChange(of: layout.anchorHovered) { _, hovered in
            if hovered { if store.isExpanded { collapseTask?.cancel() } }
            else {
                if !isHovering { suppressHoverUntilExit = false }
                if store.isExpanded { scheduleCollapseIfNeeded() }
            }
        }
        .onChange(of: store.keepOpen) { _, _ in scheduleCollapseIfNeeded() }
        .onChange(of: store.notice) { _, _ in scheduleCollapseIfNeeded() }
        .onChange(of: confirmSelection) { _, _ in scheduleCollapseIfNeeded() }
        .onDisappear { collapseTask?.cancel(); dragExpandTask?.cancel(); dragReleaseTask?.cancel(); isTargeted = false; dropHasFiles = false; airDropTargeted = false }
        .onAppear {
            if let notice = store.notice { presentNotice(notice) }
        }
        .onChange(of: store.notice) { _, notice in
            if let notice { presentNotice(notice) }
        }
        .onChange(of: confirmSelection) { _, confirming in
            guard confirming else { return }
            CenteredNoticeAlert.shared.confirmDeletion(count: store.selectedIDs.count) { confirmed in
                if confirmed { store.removeSelected() }
                confirmSelection = false
            }
        }
        .sheet(isPresented: Binding(get: { store.editingNoteID != nil }, set: { if !$0 { store.editingNoteID = nil; store.previewOpen = false } }), onDismiss: { store.previewOpen = false }) {
            if let id = store.editingNoteID { NoteComposer(id: id).environmentObject(store) }
        }
    }

    private func presentNotice(_ notice: String) {
        CenteredNoticeAlert.shared.show(notice) {
            if store.notice == notice { store.notice = nil }
        }
    }

    private func scheduleCollapseIfNeeded() {
        collapseTask?.cancel()
        guard headphones.reading == nil, hud.reading == nil, !store.isResizingWidth, !isHovering, !layout.anchorHovered, !isTargeted, !store.keepOpen, !store.previewOpen, !store.isClosingPreview, !confirmSelection, store.notice == nil else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, headphones.reading == nil, hud.reading == nil, !store.isResizingWidth, !isHovering, !layout.anchorHovered, !isTargeted, !store.previewOpen, !store.isClosingPreview, !store.keepOpen, !confirmSelection, store.notice == nil else { return }
            store.isExpanded = false
        }
    }

    private func openShelfFromClick(tab: Int? = nil) {
        // A click is navigation, even if a drag destination missed its exit.
        completedDropAt = ProcessInfo.processInfo.systemUptime
        isTargeted = false
        dropHasFiles = false
        airDropTargeted = false
        store.cancelDropHover()
        if let tab { store.selectedTab = tab }
        store.isExpanded = true
    }

    private func toggleShelfFromClick() {
        if store.isExpanded { ShelfOutsideClickMonitor.shared.requestCollapse(store: store, force: true) }
        else { openShelfFromClick() }
    }

    @ViewBuilder private var collapsedBar: some View {
      if floatingIsland {
        floatingIslandBar
      } else if !store.isExpanded && layout.dock == "top" && layout.compactPresentation == .notch {
        Button { openShelfFromClick() } label: {
            Color.clear.frame(maxWidth: .infinity).frame(height: layout.headerHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L10n.text("展开 Nisla；菜单栏空间不足时隐藏两侧内容"))
          .help(L10n.text("菜单栏避让中；悬停或点击展开"))
      } else {
        HStack(spacing: 0) {
          Button {
              openShelfFromClick(tab: compactActivity.tab)
          } label: {
           HStack(spacing: 6) {
            if let reading = hud.reading, !isTargeted {
                SystemHUDLeading(reading: reading)
            } else if !isTargeted && compactActivity.kind != .idle {
                CompactActivityLabel(activity: compactActivity, remoteArtwork: music.remoteArtwork,
                    showTitle: store.isExpanded || layout.compactPresentation == .full)
            } else {
                Image(systemName: "tray")
                    .foregroundStyle(isTargeted ? store.options.activityColor : .white)
            }
            if layout.notchWidth == 0 && compactActivity.kind == .idle && hud.reading == nil { Text(isTargeted ? L10n.text("松开即可收纳") : "Nisla")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            }
           }.frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: layout.headerHeight).contentShape(Rectangle())
          }.buttonStyle(.plain).help(L10n.text("打开当前实时活动或收纳区"))
            .accessibilityLabel(hud.reading.map { L10n.text("\($0.kind == .volume ? L10n.text("音量") : L10n.text("亮度")) \($0.percentage)%") }
                ?? L10n.text("打开\(compactActivity.kind == .music ? L10n.text("音乐") : compactActivity.kind == .codex ? L10n.text("Codex 活动") : L10n.text("收纳区"))"))
            .opacity(store.isExpanded && hud.reading == nil ? 0 : 1)
            .allowsHitTesting(!store.isExpanded && hud.reading == nil)
            .disabled(hud.reading != nil)
            .accessibilityHidden(store.isExpanded && hud.reading == nil)
            if layout.notchWidth > 0 {
                Button {
                    toggleShelfFromClick()
                } label: {
                    Color.clear.frame(width: layout.notchWidth + 12, height: layout.headerHeight).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("展开或收起"))
            }
          ZStack(alignment: .trailing) {
            if let reading = hud.reading, !isTargeted {
                SystemHUDTrailing(reading: reading).padding(.leading, 6).allowsHitTesting(false)
            } else if compactActivity.kind != .idle && !store.isExpanded && !isTargeted {
                Button {
                    openShelfFromClick(tab: compactActivity.tab)
                } label: {
                    CompactActivityIndicator(activity: compactActivity, tint: store.options.activityColor,
                        showCount: layout.compactPresentation == .full)
                        .frame(minWidth: layout.compactPresentation == .icons ? 24 : 40, minHeight: layout.headerHeight).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.text("查看\(compactActivity.kind == .music ? L10n.text("音乐") : "Codex")活动"))
            } else {
            HStack(spacing: 5) {
                Image(systemName: "square.stack").font(.system(size: 10))
                Text("\(store.items.count)").font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            }.foregroundStyle(.white.opacity(0.5))
                .opacity(isHovering || store.isExpanded ? 0 : 1)
            HStack(spacing: 4) {
                if (store.selectedTab == 2 || store.selectedTab == 3) && store.isExpanded {
                    Button { store.keepOpen.toggle() } label: {
                        Image(systemName: store.keepOpen ? "lock.fill" : "lock.open")
                            .font(.system(size: 11)).frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(store.keepOpen ? L10n.text("允许自动收起") : L10n.text("保持展开"))
                }
                if store.isExpanded || layout.compactPresentation == .full {
                Button { store.capturePasteboard() } label: {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.text("添加当前剪贴板（⌃⌘P）")).accessibilityLabel(L10n.text("添加当前剪贴板"))
                }
                Button { toggleShelfFromClick() } label: {
                    Image(systemName: store.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("展开或收起"))
            }.foregroundStyle(.white.opacity(0.75))
                .opacity(isHovering || store.isExpanded ? 1 : 0)
                .allowsHitTesting(isHovering || store.isExpanded)
            }
          }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ShelfGeometry.headerContentInset)
        .frame(height: layout.headerHeight)
        .background(.clear)
      }
    }

    private var floatingIslandBar: some View {
        HStack(spacing: 10) {
            if store.isExpanded && store.selectedTab == 0 && searchVisible {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("搜索收纳内容"), text: $store.query).textFieldStyle(.plain)
                    .focused($searchFocused)
                Button { store.query = ""; searchVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help(L10n.text("关闭搜索"))
            } else {
            Button {
                if !store.isExpanded { openShelfFromClick(tab: compactActivity.tab) }
            } label: {
                HStack(spacing: 7) {
                    if store.isExpanded {
                        let tab = ShelfTab(rawValue: store.selectedTab) ?? .pins
                        Image(systemName: tab.symbol).foregroundStyle(store.options.activityColor)
                        Text(L10n.text(tab.title)).font(.system(size: 12, weight: .semibold))
                    } else if !isTargeted && compactActivity.kind != .idle {
                        CompactActivityLabel(activity: compactActivity, remoteArtwork: music.remoteArtwork, showTitle: true)
                    } else {
                        Image(systemName: "tray").foregroundStyle(isTargeted ? store.options.activityColor : .white)
                        Text(isTargeted ? L10n.text("松开即可收纳") : "Nisla")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: layout.headerHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .allowsHitTesting(!store.isExpanded)
                .accessibilityLabel(L10n.text("打开当前实时活动或收纳区"))
            }
            if store.isExpanded {
                if let feedback = store.feedback {
                    Text(L10n.text(feedback)).font(.system(size: 10)).foregroundStyle(.mint.opacity(0.8))
                        .lineLimit(1).allowsHitTesting(false)
                }
                if store.selectedTab == 0 { storageToolbarActions }
                Button { store.keepOpen.toggle() } label: {
                    Image(systemName: store.keepOpen ? "lock.fill" : "lock.open").frame(width: 24, height: 24)
                }.buttonStyle(.plain)
                    .help(store.keepOpen ? L10n.text("允许自动收起") : L10n.text("保持展开"))
                Button { store.capturePasteboard() } label: {
                    Image(systemName: "doc.on.clipboard").frame(width: 24, height: 24)
                }.buttonStyle(.plain).help(L10n.text("添加当前剪贴板（⌃⌘P）"))
                Button { ShelfOutsideClickMonitor.shared.requestCollapse(store: store, force: true) } label: {
                    Image(systemName: "chevron.up").frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("展开或收起"))
            } else if isHovering {
                Button { openShelfFromClick(tab: compactActivity.tab) } label: {
                    Image(systemName: "chevron.down").frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("展开或收起"))
            } else if compactActivity.kind != .idle && !isTargeted {
                Button { openShelfFromClick(tab: compactActivity.tab) } label: {
                    CompactActivityIndicator(activity: compactActivity, tint: store.options.activityColor, showCount: true)
                        .frame(minWidth: 24, minHeight: layout.headerHeight)
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("打开当前实时活动或收纳区"))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack").font(.system(size: 10))
                    Text("\(store.items.count)").monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .frame(height: layout.headerHeight)
    }

    private var compactActivity: CompactActivity {
        let session = store.pinnedSessions.first { store.activities[$0.id]?.phase == .running || store.activities[$0.id]?.phase == .waiting }
        return CompactActivity.resolve(selectedTab: store.selectedTab,
            codexVisible: store.options.isTabVisible(1), running: store.activeCount, waiting: store.waitingCount,
            completed: store.recentlyCompleted != nil, codexTitle: session?.title ?? "Codex",
            musicVisible: store.options.isTabVisible(3) && music.enabled, track: music.track)
    }

    private var expandedShelf: some View {
        VStack(spacing: 8) {
          if !floatingIsland && store.selectedTab != 2 && store.selectedTab != 3 {
          HStack(spacing: 8) {
            if searchVisible && store.selectedTab == 0 {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(L10n.text("搜索收纳内容"), text: $store.query).textFieldStyle(.plain)
                    .font(.system(size: 11)).focused($searchFocused)
                Button { store.query = ""; searchVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help(L10n.text("关闭搜索"))
            } else if !floatingIsland {
                Text(L10n.text(ShelfTab(rawValue: store.selectedTab)?.title ?? "收纳"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            if let feedback = store.feedback {
                Text(L10n.text(feedback)).font(.system(size: 10)).foregroundStyle(.mint.opacity(0.8))
                    .lineLimit(1).allowsHitTesting(false)
            }
            if store.selectedTab == 0 { storageToolbarActions }
            if !floatingIsland {
                Button { store.keepOpen.toggle() } label: {
                    Image(systemName: store.keepOpen ? "lock.fill" : "lock.open").foregroundStyle(store.keepOpen ? .white : .gray)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help(store.keepOpen ? L10n.text("允许自动收起") : L10n.text("保持展开"))
            }
          }
          }

            ZStack(alignment: .topLeading) {
                if store.selectedTab == 0 {
                    HStack(spacing: 10) {
                        if isTargeted && dropHasFiles {
                            StorageDropTarget(highlighted: !airDropTargeted,
                                totalCount: store.items.count, recentItems: Array(store.items.suffix(3).reversed()))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            AirDropTarget(highlighted: airDropTargeted)
                                .frame(width: 132).frame(maxHeight: .infinity)
                        } else {
                            pinsContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                else if store.selectedTab == 1 { CodexView() }
                else if store.selectedTab == 2 { CalendarShelf() }
                else { MusicShelf() }
            }
            .id(store.selectedTab)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .offset(x: store.selectedTab >= store.previousTab ? 18 : -18).combined(with: .opacity),
                removal: .offset(x: store.selectedTab >= store.previousTab ? -12 : 12).combined(with: .opacity)))
            .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 1), value: store.selectedTab)
            .overlay {
                if isTargeted && !dropHasFiles { RoundedRectangle(cornerRadius: 10).fill(.mint.opacity(0.06)).allowsHitTesting(false) }
            }
        }
        .padding(.horizontal, ShelfGeometry.expandedContentInset)
        .padding(.vertical, 8)
        .frame(height: bodyHeight, alignment: .top)
    }

    @ViewBuilder private var storageToolbarActions: some View {
        Button { store.newNote() } label: { Image(systemName: "square.and.pencil").frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(L10n.text("新建便签"))
        Menu {
            Picker(L10n.text("类型"), selection: $store.filter) { ForEach(PinFilter.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) } }
            Menu(L10n.text("标签")) {
                Button(L10n.text("全部标签")) { store.tagFilter = nil }
                ForEach(store.allTags, id: \.self) { tag in Button(tag) { store.tagFilter = tag } }
            }
            Picker(L10n.text("排序"), selection: $store.options.sortOrder) {
                Text(L10n.text("添加时间")).tag("added"); Text(L10n.text("最近使用")).tag("used"); Text(L10n.text("手动顺序")).tag("manual")
            }
            Divider()
            Button(store.selectionMode ? L10n.text("退出多选") : L10n.text("多选")) { store.selectionMode.toggle(); store.selectedIDs.removeAll() }
            if store.selectionMode { Button(L10n.text("删除选中…"), role: .destructive) { confirmSelection = true }.disabled(store.selectedIDs.isEmpty) }
        } label: { Image(systemName: "line.3.horizontal.decrease").foregroundStyle(store.hasActiveFilters ? Color.mint : Color.primary).frame(width: 24, height: 24) }.menuStyle(.borderlessButton).fixedSize().help(L10n.text("筛选、标签与排序"))
        if !searchVisible {
            Button { searchVisible = true; searchFocused = true } label: {
                Image(systemName: "magnifyingglass").frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text("搜索"))
        }
    }

    private var pinsContent: some View {
        VStack(spacing: 0) {
            if store.filteredItems.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: store.hasActiveFilters ? "line.3.horizontal.decrease.circle" : "tray.and.arrow.down")
                        .font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.35))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.hasActiveFilters ? L10n.text("没有符合条件的内容") : L10n.text("把常用内容放在这里"))
                            .font(.system(size: 12, weight: .medium))
                        Text(store.hasActiveFilters ? L10n.text("调整类型、标签或搜索关键词") : L10n.text("拖入文字、图片或文件，也可以新建便签"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.hasActiveFilters {
                        Button(L10n.text("清除筛选")) { store.resetFilters() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.mint)
                    } else {
                        Button(L10n.text("新建便签")) { store.newNote() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.mint)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.white.opacity(0.75))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(store.filteredItems) { item in PinCard(item: item) }
                    }.padding(.vertical, 2)
                }.scrollIndicators(.hidden)
            }
        }.foregroundStyle(.white)
    }

    private func handleDrop(_ providers: [NSItemProvider], intoAirDrop: Bool) -> Bool {
        if intoAirDrop {
            store.cancelDropHover()
            return AirDropSharing.shared.share(providers) { message in
                CenteredNoticeAlert.shared.show(message)
            }
        }
        // An internal drag already carries a file/text representation. Never
        // import that representation as another pin when released on the shelf.
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier("app.island.pin-id") }) { return true }
        let supported = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                || $0.canLoadObject(ofClass: NSString.self)
        }
        guard !supported.isEmpty else { return false }
        hud.dismissPresentation(); headphones.dismiss()
        let dropID = store.beginDropImport(count: supported.count)
        for provider in supported {
            DragItemReader.load(provider) { value in
                store.receiveDrop(dropID) {
                    switch value {
                    case .file(let url)?: store.add(urls: [url])
                    case .image(let data)?:
                        if let image = NSImage(data: data) { store.add(image: image) }
                    case .link(let url)?: store.add(urls: [url])
                    case .text(let text)?: store.add(text: text)
                    case nil: break
                    }
                }
            }
        }
        return true
    }
}

struct AirDropTarget: View {
    @ObservedObject private var localization = AppLocalization.shared
    var highlighted: Bool
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 24, weight: .medium))
            Text("AirDrop").font(.system(size: 12, weight: .semibold))
            Text(L10n.text("松开后选择设备")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(highlighted ? Color.blue.opacity(0.34) : Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlighted ? Color.blue.opacity(0.9) : Color.white.opacity(0.14), lineWidth: 1))
        .accessibilityLabel(L10n.text("AirDrop，放入文件或图片后选择设备"))
    }
}

struct StorageDropTarget: View {
    @ObservedObject private var localization = AppLocalization.shared
    var highlighted: Bool
    var totalCount = 0
    var recentItems: [PinItem] = []
    var body: some View {
        Group {
            if recentItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 24, weight: .medium))
                    Text(L10n.text("收纳 · \(totalCount) 项")).font(.system(size: 12, weight: .semibold))
                    Text(L10n.text("松开后添加到收纳区")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 24, weight: .medium))
                        Text(L10n.text("收纳 · \(totalCount) 项"))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(L10n.text("松开添加"))
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        ForEach(recentItems) { item in
                            StorageDropThumbnail(item: item)
                        }
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 12)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(highlighted ? Color.mint.opacity(0.18) : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlighted ? Color.mint.opacity(0.7) : Color.white.opacity(0.10), lineWidth: 1))
        .accessibilityLabel(L10n.text("收纳，已有 \(totalCount) 项，放入文件或图片"))
    }
}

private struct StorageDropThumbnail: View {
    @ObservedObject private var localization = AppLocalization.shared
    let item: PinItem

    var body: some View {
        Group {
            if item.kind == .image, let image = NSImage(contentsOfFile: item.payload) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if (item.kind == .file || item.kind == .folder),
                      FileManager.default.fileExists(atPath: item.payload) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.payload)).resizable().scaledToFit()
            } else if item.kind == .text || item.kind == .link {
                Text(item.kind == .text ? item.payload : item.title)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(width: 30, height: 30, alignment: .topLeading)
            } else {
                Image(systemName: item.kind.symbol).resizable().scaledToFit().padding(8)
            }
        }
        .frame(width: 36, height: 36)
        .background(.white.opacity(0.19), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.17)))
        .accessibilityLabel(item.title)
        .help(item.title)
    }
}

private struct ShelfDropDelegate: DropDelegate {
    @Binding var targeted: Bool
    @Binding var hasFiles: Bool
    @Binding var airDropTargeted: Bool
    @Binding var completedAt: TimeInterval
    let panelWidth: CGFloat
    let headerHeight: CGFloat
    let bodyHeight: CGFloat
    let isExpanded: Bool
    let perform: ([NSItemProvider], Bool) -> Bool
    private let types: [UTType] = [.fileURL, .image, .text, .url]

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: types) }

    func dropEntered(info: DropInfo) {
        // A completed drag can send a final entered/updated callback after
        // performDrop. Only a later entry starts another drag session.
        if completedAt != 0 {
            guard ProcessInfo.processInfo.systemUptime - completedAt > 0.35 else { return }
            completedAt = 0
        }
        targeted = true
        hasFiles = info.hasItemsConforming(to: [.fileURL, .image])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard completedAt == 0 else { return DropProposal(operation: .cancel) }
        targeted = true
        hasFiles = info.hasItemsConforming(to: [.fileURL, .image])
        let overAirDrop = AirDropDropRouting.contains(info.location, panelWidth: panelWidth,
            headerHeight: headerHeight, bodyHeight: bodyHeight, expanded: isExpanded, hasFiles: hasFiles)
        if airDropTargeted != overAirDrop { airDropTargeted = overAirDrop }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        targeted = false; hasFiles = false; airDropTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        guard completedAt == 0 else { return false }
        completedAt = ProcessInfo.processInfo.systemUptime
        let intoAirDrop = airDropTargeted || AirDropDropRouting.contains(info.location, panelWidth: panelWidth,
            headerHeight: headerHeight, bodyHeight: bodyHeight, expanded: isExpanded,
            hasFiles: info.hasItemsConforming(to: [.fileURL, .image]))
        let providers = info.itemProviders(for: types)
        let accepted = perform(providers, intoAirDrop)
        targeted = false; hasFiles = false; airDropTargeted = false
        return accepted
    }
}

private struct PinCard: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject private var store: PinStore
    let item: PinItem
    @State private var showPreview = false
    @State private var editedText = ""
    @State private var hoverTask: Task<Void, Never>?
    @State private var tagEditor = false
    @State private var tags = ""
    @State private var checklistMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack {
                if item.kind == .image, let image = NSImage(contentsOfFile: item.payload) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 116, height: 62).clipped()
                } else if item.kind == .text || item.kind == .link {
                    Text(item.payload).font(.system(size: 10, weight: .medium))
                        .lineLimit(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: item.kind.symbol).font(.system(size: 22)).foregroundStyle(accent.opacity(0.8))
                        Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(3)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }.frame(width: 116, height: 62).clipped()
            .onDrag { hoverTask?.cancel(); return dragProvider() }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !store.selectionMode else { return }
                if item.kind == .text { editedText = item.payload; showPreview = true }
                else { store.open(item) }
            }
            .onTapGesture(count: 1) {
                if store.selectionMode {
                    if !store.selectedIDs.insert(item.id).inserted { store.selectedIDs.remove(item.id) }
                } else { editedText = item.payload; showPreview = true }
            }
            .onHover { inside in
                hoverTask?.cancel()
                if inside { scheduleHoverPreview() }
            }
            HStack {
                Text(item.isNote == true ? L10n.text("便签") : item.kind == .text ? L10n.text("文字") : item.kind == .image ? item.title : item.kind == .link ? L10n.text("链接") : item.kind == .folder ? L10n.text("文件夹") : L10n.text("文件"))
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !(item.tags ?? []).isEmpty {
                    Circle().fill(tagColor((item.tags ?? [""])[0])).frame(width: 5, height: 5)
                }
                Button {
                    hoverTask?.cancel()
                    store.toggleFavorite(item)
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star").font(.system(size: 9)).foregroundStyle(item.isFavorite ? .yellow : .gray)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(item.isFavorite ? L10n.text("取消收藏") : L10n.text("收藏"))
                    .help(item.isFavorite ? L10n.text("取消收藏") : L10n.text("收藏并优先显示"))
            }
        }
        .padding(8).frame(width: 132, height: 104)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.045))
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [accent.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06), lineWidth: 0.5).allowsHitTesting(false))
        .overlay(alignment: .topTrailing) {
            if store.selectionMode {
                Image(systemName: store.selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.mint).padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: ["app.island.pin-id"], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: "app.island.pin-id") { data, _ in
                if let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) {
                    Task { @MainActor in store.reorder(id, before: item.id) }
                }
            }
            return true
        }
        .popover(isPresented: $showPreview) {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.headline).lineLimit(2)
                if item.kind == .text {
                    HStack {
                        Button(checklistMode ? L10n.text("编辑文本") : L10n.text("清单")) {
                            if !checklistMode && !editedText.contains("- [") {
                                editedText = editedText.components(separatedBy: "\n").map { "- [ ] " + $0 }.joined(separator: "\n")
                                store.edit(item, text: editedText)
                            }
                            checklistMode.toggle()
                        }
                        Spacer()
                        Button(L10n.text("标签")) { tags = (item.tags ?? []).joined(separator: ", "); tagEditor = true }
                    }.font(.caption)
                    if checklistMode {
                        ChecklistEditor(text: $editedText).frame(width: 340, height: 180)
                            .onChange(of: editedText) { _, text in store.edit(item, text: text) }
                    } else {
                        InlineTextEditor(text: $editedText) { text in store.edit(item, text: text) }
                            .frame(width: 340, height: 180).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else if item.kind == .image, let image = NSImage(contentsOfFile: item.payload) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 340, height: 220)
                } else if item.kind == .file {
                    FilePreview(path: item.payload).frame(width: 340, height: 220)
                } else if item.kind == .link {
                    WebPreview(address: item.payload).frame(width: 340, height: 180)
                } else { Text(item.payload).font(.caption).textSelection(.enabled).frame(width: 340, alignment: .leading) }
                HStack {
                    if item.kind == .text {
                        Text(L10n.text("编辑自动保存")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button(L10n.text("复制")) { store.use(item) }
                    if item.kind != .text { Button(openTitle) { store.open(item) } }
                    if [.image, .file, .folder].contains(item.kind) {
                        Button(L10n.text("在 Finder 中显示")) { store.revealInFinder(item) }
                    }
                }
            }
            .padding(12).frame(width: 364)
            .background(Color(white: 0.09))
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
            .background(ShelfInteractionBoundary(preview: true))
        }
#if ISLAND_PANEL_PREVIEW
        // Test-only entry into the same delayed hover path, without moving the
        // user's pointer or replacing the actual SwiftUI card popover.
        .onReceive(NotificationCenter.default.publisher(for: .init("NislaTestHoverPinPreview"))) { notification in
            guard let id = notification.object as? UUID, id == item.id else { return }
            hoverTask?.cancel()
            scheduleHoverPreview()
        }
#endif
        .onChange(of: store.isExpanded) { _, expanded in
            if !expanded {
                hoverTask?.cancel()
                showPreview = false
            }
        }
        .onChange(of: store.previewDismissal) { _, _ in
            hoverTask?.cancel()
            showPreview = false
        }
        .onChange(of: showPreview) { _, visible in store.previewOpen = visible || tagEditor }
        .onChange(of: tagEditor) { _, visible in
            store.previewOpen = visible || showPreview
            if visible {
                CenteredNoticeAlert.shared.editTags(initialValue: tags) { result in
                    if let result { tags = result; store.setTags(item, text: result) }
                    tagEditor = false
                }
            }
        }
        .onDisappear { hoverTask?.cancel(); if showPreview || tagEditor { store.previewOpen = false } }
        .contextMenu {
            if item.kind == .text {
                Button(L10n.text("编辑文字")) { editedText = item.payload; showPreview = true }
            } else { Button(openTitle) { store.open(item) } }
            if [.image, .file, .folder].contains(item.kind) {
                Button(L10n.text("在 Finder 中显示")) { store.revealInFinder(item) }
            }
            Button(L10n.text("复制")) { store.use(item) }
            Button(item.isFavorite ? L10n.text("取消收藏") : L10n.text("收藏")) { store.toggleFavorite(item) }
            Button(L10n.text("编辑标签…")) { tags = (item.tags ?? []).joined(separator: ", "); tagEditor = true }
            Divider()
            Button(L10n.text("删除"), role: .destructive) { store.remove(item) }
        }
        .help(item.kind == .text ? L10n.text("悬停或单击编辑，自动保存；可直接拖出") : L10n.text("单击预览，双击打开；可直接拖出"))
    }

    private func scheduleHoverPreview() {
        guard store.isExpanded, !showPreview, !store.previewOpen, !store.selectionMode else { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, store.isExpanded, !store.previewOpen, !store.selectionMode else { return }
            editedText = item.payload
            showPreview = true
        }
    }

    private var openTitle: String {
        switch item.kind {
        case .link: L10n.text("在浏览器打开")
        case .image: L10n.text("打开图片")
        case .folder: L10n.text("打开文件夹")
        case .file: L10n.text("打开文件")
        case .text: L10n.text("编辑文字")
        }
    }
    private func dragProvider() -> NSItemProvider {
        let provider: NSItemProvider
        switch item.kind {
        case .text, .link: provider = NSItemProvider(object: item.payload as NSString)
        case .image, .file, .folder: provider = NSItemProvider(object: URL(fileURLWithPath: item.payload) as NSURL)
        }
        let id = item.id.uuidString
        provider.registerDataRepresentation(forTypeIdentifier: "app.island.pin-id", visibility: .ownProcess) { completion in completion(Data(id.utf8), nil); return nil }
        return provider
    }

    private var accent: Color {
        switch item.kind { case .text: .orange; case .image: .purple; case .link: .blue; case .file: .mint; case .folder: .yellow }
    }
    private func tagColor(_ name: String) -> Color {
        let colors: [Color] = [.mint, .blue, .purple, .orange, .pink, .yellow]
        return colors[name.utf8.reduce(0) { $0 + Int($1) } % colors.count]
    }
}

private struct CodexView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject private var store: PinStore
    private var showAll: Bool { store.showRecentSessions }
    @State private var selectedSession: CodexSession?
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showAll ? L10n.text("最近会话") : L10n.text("已置顶会话")).font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Menu {
                    Toggle(L10n.text("显示内部会话"), isOn: $store.showInternalCodexSessions)
                } label: {
                    Image(systemName: store.showInternalCodexSessions ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }.menuStyle(.borderlessButton).fixedSize().help(L10n.text("默认仅显示主会话；可查看内部审查与子任务"))
                Button(showAll ? L10n.text("返回置顶") : L10n.text("添加会话")) { store.showRecentSessions.toggle() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Button { store.refreshCodex() } label: {
                    ZStack {
                        if store.isRefreshing { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.isRefreshing).help(L10n.text("刷新会话"))
            }
            if visibleSessions.isEmpty {
                ContentUnavailableView(showAll ? L10n.text("未找到 Codex 会话") : L10n.text("还没有置顶会话"), systemImage: "sparkles", description: Text(L10n.text("点击“添加会话”选择会话；筛选菜单可显示内部会话。")))
            } else {
                ScrollView {
                    LazyVStack(spacing: ShelfGeometry.codexRowSpacing) {
                        ForEach(visibleSessions) { session in
                            HStack(spacing: 10) {
                                let phase = store.activities[session.id]?.phase
                                ZStack {
                                    Circle().fill(statusColor(phase).opacity(0.12))
                                    if phase == .running { ActivityPulse() }
                                    else { Image(systemName: phase == .completed ? "checkmark" : phase == .waiting ? "questionmark" : phase == .interrupted ? "pause.fill" : "sparkles").foregroundStyle(statusColor(phase)) }
                                }.frame(width: 28, height: 28)
                                Button {
                                    selectedSession = session
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        HStack {
                                            if let kind = session.internalKind {
                                                Text(kind == .review ? L10n.text("内部审查") : L10n.text("子任务"))
                                                    .foregroundStyle(.orange)
                                            }
                                            if let activity = store.activities[session.id] {
                                                Text(L10n.text(activity.phase.title)).foregroundStyle(statusColor(activity.phase))
                                                if activity.phase == .running, let started = activity.startedAt { Text(started, style: .timer).monospacedDigit() }
                                            } else {
                                                Text(L10n.text("更新于"))
                                                Text(session.modifiedAt, style: .relative)
                                            }
                                        }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { store.toggleSession(session) } label: {
                                    Image(systemName: store.pinnedSessions.contains(where: { $0.id == session.id }) ? "pin.fill" : "pin")
                                }.buttonStyle(.plain).help(L10n.text("置顶或取消置顶"))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 10)
                            .frame(height: ShelfGeometry.codexRowHeight)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }.foregroundStyle(.white)
        .popover(item: $selectedSession) { session in
            AgentConversation(session: session).environmentObject(store)
                .background(ShelfInteractionBoundary(preview: true))
        }
        .onChange(of: store.previewDismissal) { _, _ in selectedSession = nil }
        .onChange(of: selectedSession) { _, session in store.previewOpen = session != nil }
        .onDisappear { store.previewOpen = false }
        .onAppear { store.refreshCodex() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { store.refreshCodex() }
            }
        }
    }

    private var visibleSessions: [CodexSession] {
        store.visibleCodexSessions
    }

    private func statusColor(_ phase: ActivityPhase?) -> Color {
        switch phase {
        case .running, .completed: store.options.activityColor
        case .waiting: .orange
        case .interrupted: .yellow
        default: .gray
        }
    }
}

private struct ActivityPulse: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject private var store: PinStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5) { index in
                    let wave = 0.5 + 0.5 * sin(time * 3.6 - Double(index) * 0.85)
                    Capsule().fill(store.options.activityColor.opacity(0.85))
                        .frame(width: 2, height: reduceMotion ? 8 : 4 + 9 * wave)
                }
            }.frame(width: 18, height: 16)
        }.accessibilityLabel(L10n.text("Codex 正在工作"))
    }
}
