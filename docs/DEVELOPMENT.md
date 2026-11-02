# Nisla 开发说明

项目介绍、下载和权限说明见 [仓库首页](../README.md)。下述命令均从仓库根目录执行；Swift 项目名称与可执行文件名均为 Nisla。

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

## 音乐与系统提示

Apple Music / Spotify 使用应用脚本接口；网易云音乐 / QQ 音乐依赖系统“正在播放”，仅能控制当前系统来源。

构建脚本从 `Vendor/MediaRemoteAdapter` 的固定源码编译组件，来源与版本见 [ISLAND-PROVENANCE.txt](../Vendor/MediaRemoteAdapter/ISLAND-PROVENANCE.txt)，许可为 BSD-3-Clause。亮度控制使用可选的 DisplayServices 私有接口。

相关接口可能受系统更新影响，使当前完整版本不适合直接提交 Mac App Store。接口失败时应保留降级提示，不显示虚假的成功状态。

耳机连接提示、自动剪贴板历史、音乐和系统媒体键接管默认关闭；功能启用与授权由用户控制。动效与材质应遵循系统“减少动态效果”和“减少透明度”设置。

## Codex 集成

未连接 App Server 时，仍可读取本机会话日志、手动置顶和显示活动。长时间没有事件时显示待确认状态，不伪造精确进度。

设置 → Agent 中可配置：

- 已有本地服务：通过 `codex app-server proxy` 连接控制 Socket。
- 独立 CLI：启动 `codex app-server --stdio`，可继续已保存会话，不能接管其他窗口已运行的任务。

实现覆盖初始化、会话列表、回复、流式事件、审批、问题回答和额度信息。未知服务请求返回不支持，审批由用户明确操作。

协议模拟验证不等于真实服务端到端验证；能力取决于目标 Codex 版本。Claude Code 和 WorkBuddy 双向连接尚未实现。

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
