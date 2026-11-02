# Nisla 开发说明

项目介绍、下载和权限说明见 [仓库首页](../README.md)。下述命令均从仓库根目录执行；Swift 项目名称与可执行文件名均为 Nisla。

修改项目时请先阅读 [项目规范](../AGENTS.md)，其中包含界面、窗口动效、系统提示、验证和打包要求。

## 开发环境

- 包含 macOS 26 SDK 的 Xcode / Command Line Tools，以及 Swift 6 工具链。
- 应用最低部署目标为 macOS 14。
- 原生 SwiftUI / AppKit 应用，使用 Swift Package Manager 构建。

```text
Nisla/
├── Package.swift          # Swift 项目与可执行文件名为 Nisla
├── Sources/Nisla/        # 应用源码
├── Support/               # Info.plist、图标、分享版说明
├── Tests/                 # 数据、协议、动效、界面检查
├── Vendor/                # 固定版本第三方源码及许可证
└── scripts/               # 构建与测试脚本
```

原项目名为 Island。可执行文件名现为 Nisla；Bundle ID `local.island.shelf` 与数据目录保持不变，以兼容已有用户；对外名称为 Nisla。

## 构建与运行

```bash
bash scripts/build-app.sh
```

在 Finder 中打开 `.build/Nisla.app`。脚本会构建和嵌入通用音乐辅助组件，并应用本地 ad-hoc 签名。

系统授权和登录启动应使用打包后的 `.app` 验证；直接 `swift run` 的身份与资源不等同于安装版。

需要隔离演示数据时：

```bash
bash scripts/build-app.sh --demo
```

生成的 `.build/NislaDemo.app` 使用独立 Bundle ID 和测试数据，适合界面预览。

## 回归检查

```bash
bash scripts/check.sh
```

脚本检查数据、音乐、Agent、日历、动效、材质、菜单栏避让、AirDrop、实时活动、HUD、耳机、轮廓、界面预览和原生窗口。缺少 WindowServer 时，原生窗口套件会报告跳过。

检查使用模拟服务与隔离数据，不请求真实系统授权、不发送模型任务，也不改变真实音量、亮度、播放器或日历。预览输出位于 `.build/PanelPreviews`，不提交整个构建目录。

窗口、拖拽、弹窗、音乐、耳机、登录启动和多显示器的修改仍需真实桌面与设备验证。

## README 预览素材

```bash
bash scripts/render-readme-previews.sh
```

使用原生视图与隔离的演示数据，在 `docs/assets/` 生成收纳、Codex、日历、音乐、音量和亮度六张完整刘海预览，以及 `notch-overview.gif`。不会读取真实会话、日历、剪贴板或调用音量、亮度调节接口。

GIF 使用生产展开/收起曲线合成，桌面背景为示意，并非实机录屏；经典黑色视图不用于承诺系统玻璃的真实折射效果。更新首页时仅提交这些文档素材，不提交 `.build/`。

## 音乐与系统提示

Apple Music / Spotify 使用应用脚本接口；网易云音乐 / QQ 音乐依赖系统“正在播放”，仅能控制当前系统来源。

构建脚本从 `Vendor/MediaRemoteAdapter` 的固定源码编译组件，来源与版本见 [ISLAND-PROVENANCE.txt](../Vendor/MediaRemoteAdapter/ISLAND-PROVENANCE.txt)，许可为 BSD-3-Clause。亮度控制使用可选的 DisplayServices 私有接口。

相关接口可能受系统更新影响，使当前完整版本不适合直接提交 Mac App Store。接口失败时应保留降级提示，不显示虚假的成功状态。

耳机连接提示、自动剪贴板历史、音乐和系统媒体键接管默认关闭；功能启用与授权由用户控制。动效与材质应遵循系统“减少动态效果”和“减少透明度”设置。

已按用户要求撤回 0.2.44 的 `glassEffect(.regular)` 与共享容器改造，恢复原来的 `NSGlassEffectView.clear`、深色渐变遮光和独立导航材质。顶部及收起状态保持纯黑。底部 Tab 仅在展开且展开进度超过 0.6 时挂载，不以透明度代替移除，避免原生光学层在收起条里残留。

材质测试恢复为原实现对应的遮光、圆角、不拦截点击及系统版本回退检查。离屏 PNG 不能验证系统合成器的真实折射、背景采样和边缘适配；这些仍需用 `GlassBackdropPreview` 的隔离背景窗口实机检查，不可把离屏图当成真实玻璃效果的证据。

## Codex 集成

未连接 App Server 时，仍可读取本机会话日志、手动置顶和显示活动。长时间没有事件时显示待确认状态，不伪造精确进度。

设置 → Agent 中可配置：

- 已有本地服务：通过 `codex app-server proxy` 连接控制 Socket。
- 独立 CLI：启动 `codex app-server --stdio`，可继续已保存会话，不能接管其他窗口已运行的任务。

实现覆盖初始化、会话列表、回复、流式事件、审批、问题回答和额度信息。未知服务请求返回不支持，审批由用户明确操作。

协议模拟验证不等于真实服务端到端验证；能力取决于目标 Codex 版本。Claude Code 和 WorkBuddy 双向连接尚未实现。

共享模式使用 `codex app-server proxy`，要求所选 CLI 支持此命令，且控制 Socket 已存在并监听。缺失或拒绝连接时显示明确原因，并提供用户主动点击的“使用独立服务连接”按钮，不自动切换或启动共享守护服务。独立模式使用文档中的默认 stdio 启动方式 `codex app-server`，不接管其他窗口的活动任务；已有会话的写占用保护仍生效。

启动 stderr 仅在内存中保留最多 64 KiB，用于识别 Socket、CLI 命令兼容性、配置和文件权限问题；不将原始路径、凭据或 stderr 内容写入导出日志。未知错误保持通用提示，不猜测敏感输出。

`Tests/CodexConnectionSmoke.swift` 是可选的真实本机连接检查，需显式设置 `NISLA_CODEX_SMOKE_PATH`；仅握手与查询元数据，不恢复会话或启动模型轮次。常规回归使用 `ConnectionRecoveryChecks` 与模拟服务，不连接真实账号。

刘海对话区立即展示用户发出的内容，并区分发送中、等待回复、流式回复、完成、失败和中断。实时消息缓存最多 16 个会话、每个会话最近 32 条、每条最多 65,536 字符；关闭弹窗不清空，退出应用后清空缓存。发送失败保留草稿，不自动重发。

`ConversationHistoryReader` 不恢复会话、不获得写锁，只在打开的会话弹窗内读取本地日志：单次最多 4 MiB，首批 24 条，逐页最多显示 200 条，每条最多 65,536 字符。忽略未完成 JSON 行、工具和推理记录、环境控制消息，并择一使用 response/event 消息格式以免重复。轮询期间按文件长度和修改时间更新最近记录，较早页通过字节游标读取。界面合并日志与实时消息的重叠尾部；新 task_started 不再覆盖上条助手摘要。用户滚动历史时暂停跟随，回到底部或点按钮恢复；测试使用临时日志及原生滚动通知，不访问真实会话内容。

`ShelfOutsideClickMonitor` 监听本机和其他应用的鼠标按下事件，原事件原样传递，不监控键盘。`ShelfInteractionBoundary` 以真实视图屏幕边界登记面板及独立弹窗，外部点击发出预览关闭代数并收起未锁定面板；锁定时仅关闭短暂预览。结束编辑先提交便签文字，确认框、菜单跟踪、独立编辑 sheet 及宽度调整期间保护交互。`InteractionChecks` 使用隔离窗口验证边界、关闭状态和滚动跟随。

日志预览及实时助手消息共用 `ConversationMarkdown`：通过 Foundation 的 Markdown 解析与 presentation intents 保留段落、标题、粗体、列表、引用、代码块及表格；用户输入仍按原文展示。输入长度限制为 65,536 字符，允许流式消息尚未结束的 Markdown。点击本地文件链接只在 Finder 中定位，不执行文件；相对路径以会话项目目录为基准，支持 `:行号:列号` 引用，缺失文件给出内联提示。网页链接由系统在用户点击后打开，不自动请求 Markdown 图片或加载 HTML。文件变更卡片、Undo 和执行详情仍属于 Codex 客户端的额外结构化界面，不从回复文字猜测或伪造。`MarkdownChecks` 验证语义、路径及部分文本；`ConversationPreviewChecks` 渲染日志和助手消息的原生布局。

任务运行时，对话标题旁显示“停止”。按钮使用当前连接获得的 threadId / turnId 调用 `turn/interrupt`；发送确认前点击会暂存停止意图，取得轮次 ID 后发出请求。RPC 应答只代表请求被接收，收到 `turn/completed` 才结束运行状态。停止失败或 10 秒内未收到结束确认时显示可重试提示，保留部分回复与草稿，不中断其他会话或退出服务。`Tests/InterruptChecks.swift` 使用本地协议模拟服务覆盖早停、重复点击、过期事件、重试和确认超时。

## 悬浮展示与原生岛边界

当前开发修正将 `IslandOptions.presentationStyle` 的默认行为改为自动检测；设置中的名称为“自动（检测系统与设备）”“悬浮胶囊”“贴顶刘海”。旧系统或无法确认原生岛能力时回退贴顶，不仅凭 macOS 版本或屏幕存在刘海推断支持。检测能力未知也使用贴顶，不保证识别所有未来设备；用户仍可手动选择悬浮。

`NativeIslandCompatibility` 使用实际 macOS 主版本、`hw.model` 精确标识及当前显示器是否为内置屏幕。系统低于 macOS 27、外接屏或硬件未验证均回退贴顶。当前 SDK 26.5 未提供公开原生岛能力查询，Apple 型号表也尚无可确认的 PROLED 标识，因此已验证型号集合暂为空；当前自动模式不会对任何未知新机猜测启用悬浮。拿到官方准确标识或公开能力 API 后才能补足原生岛设备的正向识别。测试注入的是虚构型号，不作为真实设备白名单。

`presentationPolicyVersion` 区分 0.2.48 的旧默认行为与修正后的明确选择。旧配置缺少此标记时，将 `floating` 一次性迁移到 `automatic`，保留旧的 `notch` 选择；之后在设置中明确选择悬浮会保存新标记并保留选择，不在每次启动时重置。迁移只改外观偏好，不更改收纳内容或其他功能配置。

手动悬浮使用 36 pt 胶囊头部、200/300 pt 紧凑宽度，按屏幕 `visibleFrame` 与 `safeAreaInsets` 保守避让摄像头和菜单栏，再留 8 pt 间距。展开内容与导航使用一个圆角容器；窗口动画锁定这个目标上沿。原生位置恢复按 `resizeTarget` 修复，不把悬浮模式误拉回物理屏幕边缘。

悬浮界面仍由 Nisla 的应用层 NSPanel 实现，没有接入 Apple 原生 Dynamic Island，也不能获得系统岛的实时展开边界。系统原生能力与 Nisla 的展示选择应分开处理：手动选择悬浮不代表设备支持原生岛，不能把无法确认的能力当成已支持。真正的原生接入需要匹配 SDK、公开能力检测和支持设备的实机验证；Nisla 的媒体和 HUD 功能保持按需开启。

此修正包含于 0.2.49 / 构建号 51。旧的 0.2.48 / 构建号 50 安装包仍默认悬浮，其发布说明和安装包校验值保留原样。

## 构建通用分享包

```bash
bash scripts/package-share.sh
```

分别构建 arm64 与 x86_64 Release 二进制，合并通用应用，校验签名并输出至 `dist/`。这些文件上传为 GitHub Release 资产，不提交进 Git 历史。

发布前同步更新 `Support/Info.plist` 和分享版说明中的版本，核对安装包与源码提交对应。当前脚本没有执行 Developer ID 签名或苹果公证。

## 图标

图标由仓库内脚本绘制，可重新生成：

```bash
swift scripts/render-icon.swift .build/Nisla.iconset Support/Nisla.icns
```

## 本地数据

用户数据位于 `~/Library/Application Support/Island`，不在源码仓库内。不要把个人置顶内容、剪贴板历史、会话日志和账号凭据添加到测试夹具或公开 Issue。

原来的应用可能仍名为 Island。安装调试版或发行版前先退出旧进程，避免同时运行相同 Bundle ID 的多个副本。
