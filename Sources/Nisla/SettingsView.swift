import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject var store: PinStore
    @State private var launch = SMAppService.mainApp.status == .enabled
    @State private var clear = false
    @State private var history = false
    var body: some View {
        TabView {
            Form {
                Section(L10n.text("语言")) {
                    Picker(L10n.text("语言"), selection: $localization.selection) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    Text(L10n.text("语言切换立即生效；跟随系统时优先使用系统首选的中文或英文，其余语言使用英文。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("功能页显示")) {
                    ForEach(ShelfTab.allCases) { tab in
                        Toggle(isOn: Binding(
                            get: { store.options.isTabVisible(tab.rawValue) },
                            set: { store.setTabVisible(tab.rawValue, visible: $0) }
                        )) { Label(L10n.text(tab.title), systemImage: tab.symbol) }
                        .disabled(store.options.isTabVisible(tab.rawValue) && store.options.visibleTabIDs.count == 1)
                    }
                    Text(L10n.text("关闭后立即隐藏对应 Tab；至少保留一个页面。仅控制页面显示，不删除数据、不撤销授权，也不停止已连接的 Agent 任务。天气接入后也会出现在这里。")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("外观与布局")) {
                    ActivityColorSetting()
                    Button(L10n.text("恢复默认活动颜色")) { store.options.activityColorHex = nil }
                    Picker(L10n.text("材质"), selection: $store.options.appearance) {
                        Text(L10n.text("按系统自动")).tag("automatic"); Text(L10n.text("经典黑色")).tag("black"); Text(L10n.text("液态玻璃（macOS 26+）")).tag("glass")
                    }
                    Text(L10n.text("自动模式：macOS 26+ 使用原生液态玻璃，边缘光学效果由系统绘制；玻璃背后的上黑下透遮光保留阅读对比度。所有页面和底部切换栏统一生效，不读取或录制屏幕画面。顶部刘海区域与收起状态保持纯黑。旧系统、经典黑色或系统“减少透明度”均使用纯黑。")).font(.caption).foregroundStyle(.secondary)
                    Slider(value: $store.options.shelfWidth, in: 440...960, step: 20) { Text(L10n.text("展开宽度 \(Int(store.options.shelfWidth)) pt")) }
                    Button(L10n.text("预览展开效果")) {
                        store.isExpanded = true
                        store.keepOpen = false
                        NotificationCenter.default.post(name: .init("IslandReveal"), object: nil)
                    }
                    if store.isExpanded {
                        Button(L10n.text("收起预览")) { store.isExpanded = false; store.keepOpen = false }
                    }
                    Text(L10n.text("宽度仅改变展开面板，不改变收起时的刘海条。预览后可直接收起，鼠标移出面板也会自动收起。")).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("菜单栏避让仅调整收起条的左右翼，不移动整体位置：确认相邻菜单图标空间不足时先隐藏歌名，再只保留刘海本体，空间恢复后还原。无法读取位置或未授予辅助功能权限时保持正常宽度，此时不能保证自动避让；鼠标位置本身不触发收窄。已有辅助功能授权时仅读取菜单图标位置，不读取菜单文字、不申请录屏权限。展开、收起及临时提示均保持贴顶。")).font(.caption).foregroundStyle(.secondary)
                    Slider(value: $store.options.hoverDelay, in: 0.15...1, step: 0.05) { Text(L10n.text("悬停展开延迟 \(String(format: "%.2f", store.options.hoverDelay)) 秒")) }
                    Text(L10n.text("鼠标移出后再移入收起的刘海条即可测试；点击仍立即展开，移出后的收起延迟不受此项控制。")).font(.caption).foregroundStyle(.secondary)
                    Toggle(L10n.text("所有显示器显示"), isOn: $store.options.allDisplays)
                    Picker(L10n.text("显示器"), selection: $store.options.screenID) {
                        Text(L10n.text("自动（优先内置）")).tag("automatic")
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in Text(screen.localizedName).tag(screen.islandID) }
                    }.disabled(store.options.allDisplays)
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                        Picker(L10n.text("\(screen.localizedName) 停靠"), selection: Binding(get: { store.options.dockPositions[screen.islandID] ?? "top" }, set: { store.options.dockPositions[screen.islandID] = $0 })) {
                            Text(L10n.text("顶部")).tag("top"); Text(L10n.text("左侧")).tag("left"); Text(L10n.text("右侧")).tag("right")
                        }
                    }
                    Picker(L10n.text("Agent 提醒屏幕"), selection: $store.options.alertScreenID) {
                        Text(L10n.text("自动")).tag("automatic")
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in Text(screen.localizedName).tag(screen.islandID) }
                    }
                    Toggle(L10n.text("显示菜单栏图标"), isOn: $store.options.showMenuIcon)
                }
                Section(L10n.text("提示")) {
                    Toggle(L10n.text("内容提示音"), isOn: $store.options.arrivalSound)
                    Toggle(L10n.text("添加后展开"), isOn: $store.options.arrivalAnimation)
                    Toggle(L10n.text("Agent 完成提示音"), isOn: $store.options.completionSound)
                    Toggle(L10n.text("Agent 完成 / 等待时展开"), isOn: $store.options.completionAlert)
                }
                SystemHUDSettings()
                Section(L10n.text("耳机连接提示")) {
                    Toggle(L10n.text("在刘海显示耳机连接与电量"), isOn: Binding(
                        get: { store.options.headphoneConnectionEnabled ?? false },
                        set: { store.options.headphoneConnectionEnabled = $0 }
                    ))
                    Text(L10n.text("默认关闭，不会在安装或启动时主动请求蓝牙权限。自行启用后读取已配对耳机的连接状态，可能需要蓝牙授权；不会主动配对或切换音频。电量仅展示 macOS 提供的数值，部分耳机可能无法读取。仅顶部停靠时展示。")).font(.caption).foregroundStyle(.secondary)
                    HeadphoneConnectionStatus()
                }
                Toggle(L10n.text("登录时启动"), isOn: $launch).disabled(Bundle.main.bundleURL.pathExtension != "app")
                    .onChange(of: launch) { _, enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { store.notice = error.localizedDescription }
                    }
                if Bundle.main.bundleURL.pathExtension != "app" { Text(L10n.text("登录启动需使用打包后的 Nisla.app。")).font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label(L10n.text("外观"), systemImage: "paintbrush") }
            Form {
                Section(L10n.text("剪贴板历史（默认关闭）")) {
                    Toggle(L10n.text("自动记录"), isOn: $store.options.clipboardEnabled)
                    Toggle(L10n.text("暂停记录"), isOn: $store.options.clipboardPaused)
                    TextField(L10n.text("排除应用：名称或 Bundle ID，逗号分隔"), text: $store.options.excludedApps)
                    Picker(L10n.text("保留期限"), selection: $store.options.historyMonths) { Text(L10n.text("永久")).tag(0); Text(L10n.text("三个月")).tag(3); Text(L10n.text("六个月")).tag(6) }
                    Button(L10n.text("清空自动历史…"), role: .destructive) { history = true }
                }
                Section(L10n.text("文件与整理")) {
                    Toggle(L10n.text("独立副本模式"), isOn: $store.options.copyFiles)
                    Text(L10n.text("关闭时引用原文件，开启时保存副本。")).font(.caption).foregroundStyle(.secondary)
                    Picker(L10n.text("排序"), selection: $store.options.sortOrder) { Text(L10n.text("添加时间")).tag("added"); Text(L10n.text("最近使用")).tag("used"); Text(L10n.text("手动")).tag("manual") }
                    LabeledContent(L10n.text("已保存"), value: L10n.text("\(store.items.count) 项"))
                    Button(L10n.text("清空全部…"), role: .destructive) { clear = true }
                }
            }.formStyle(.grouped).tabItem { Label(L10n.text("内容"), systemImage: "tray") }
            Form {
                ShortcutRecorder(title: L10n.text("收纳剪贴板"), key: $store.options.pinKey, modifiers: $store.options.pinModifiers)
                ShortcutRecorder(title: L10n.text("显示 / 隐藏"), key: $store.options.toggleKey, modifiers: $store.options.toggleModifiers)
                ShortcutRecorder(title: L10n.text("快速便签"), key: $store.options.noteKey, modifiers: $store.options.noteModifiers)
                ShortcutRecorder(title: L10n.text("捕获选中内容"), key: $store.options.selectionKey, modifiers: $store.options.selectionModifiers)
                Text(L10n.text("点击录制后按组合键；捕获选中内容需要辅助功能权限。")).font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label(L10n.text("快捷键"), systemImage: "keyboard") }
            AgentSettings().tabItem { Label("Agent", systemImage: "sparkles") }
            CalendarSettings().tabItem { Label(L10n.text("日历"), systemImage: "calendar") }
            MusicSettings().tabItem { Label(L10n.text("音乐"), systemImage: "music.note") }
        }.frame(width: 620, height: 620)
        .environment(\.locale, localization.locale)
        .confirmationDialog(L10n.text("清空所有内容？"), isPresented: $clear) { Button(L10n.text("清空"), role: .destructive) { store.clearAll() } } message: { Text(L10n.text("无法撤销。原文件和 Agent 会话保留。")) }
        .confirmationDialog(L10n.text("清空自动历史？"), isPresented: $history) { Button(L10n.text("清空"), role: .destructive) { store.clearHistory() } } message: { Text(L10n.text("收藏和手动添加内容保留。")) }
    }
}

extension NSScreen {
    var islandID: String { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? localizedName }
}
