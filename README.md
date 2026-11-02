<p align="center">
  <img src="docs/assets/icon.png" width="104" height="104" alt="Nisla 图标">
</p>

<h1 align="center">Nisla</h1>

<p align="center">把文件、音乐和日程，放在 Mac 的屏幕边缘。</p>
<p align="center">macOS 14+ · Apple Silicon & Intel · Swift / SwiftUI · MIT</p>

<p align="center">
  <a href="https://github.com/matt-liao-0108/Nisla/releases">下载安装包</a> ·
  <a href="#快速开始">从源码构建</a> ·
  <a href="https://github.com/matt-liao-0108/Nisla/issues">反馈问题</a>
</p>

Nisla 是一个原生 macOS 刘海收纳与实时活动工具。把文字、图片或文件拖到屏幕边缘，快速收纳；也可以在同一个面板里查看音乐、日历和 Codex 活动。

项目仍处于测试阶段，欢迎反馈使用体验和兼容性问题。

## 功能

- **随手收纳**：保存文字、图片、链接、文件和文件夹，支持便签、标签、搜索、收藏和预览。
- **AirDrop 投放**：拖入文件或图片后，在独立区域松开，交由 macOS 选择接收设备。
- **音乐控制**：展示封面和播放信息，支持 Apple Music、Spotify，以及系统“正在播放”中的网易云音乐和 QQ 音乐。
- **日历与待办**：查看系统日历、订阅日历和提醒事项，快速切换日期。
- **Codex 活动**：置顶本机会话、查看运行状态和最近消息；可选连接本地 App Server。
- **外观与布局**：支持经典黑色和系统玻璃材质，在设置中调整宽度、功能页、停靠位置和快捷键。
- **中英文切换**：默认跟随系统，也可在“设置 → 外观 → 语言”中选择简体中文或 English，切换立即生效。
- **可选系统提示**：耳机连接提示、音量和亮度媒体键接管均由用户按需开启。

## 界面预览

以下图片使用演示数据生成；系统玻璃的透色与折射取决于 macOS 版本和背景。

| 音乐 | 日历 |
| --- | --- |
| ![音乐面板演示](docs/assets/music.png) | ![日历面板演示](docs/assets/calendar.png) |

## 下载与安装

1. 打开 [Releases](https://github.com/matt-liao-0108/Nisla/releases)，下载附件中的 `Nisla-版本号-universal-*.zip`。
2. 解压，把 `Nisla.app` 拖入“应用程序”。更新时先从菜单栏退出旧版，再替换应用。
3. 打开后，通过菜单栏图标进入设置，或把内容拖到屏幕边缘使用。

需要 **macOS 14 或更新版本**，通用安装包包含 Apple Silicon 和 Intel 架构。原生玻璃材质需要 **macOS 26+**；较旧系统或开启“减少透明度”时使用黑色外观。

当前测试包使用本地 ad-hoc 签名，尚无 Developer ID 签名和苹果公证。macOS 可能阻止网络下载包首次启动；请先确认下载来源可信，再按系统提供的安全提示处理。

GitHub 自动生成的 `Source code (zip)` 是源码，不是可直接运行的安装包。

## 基本操作

| 操作 | 使用方式 |
| --- | --- |
| 收纳内容 | 拖入面板，或按 `⌃⌘P` 添加剪贴板内容 |
| 显示 / 隐藏 | `⌃⌘I` |
| 新建便签 | `⌃⌘N`，或点击收纳工具栏的编辑图标 |
| 捕获选中内容 | 默认 `⇧⌘X`，需辅助功能授权 |
| 搜索与整理 | 收纳工具栏的搜索、筛选和排序菜单 |
| 查看原文件 | 文件卡片右键 → 在 Finder 中显示 |
| 调整宽度 | 设置 → 外观；当前版本不提供手动拖拽调宽 |
| AirDrop | 拖拽文件或图片，等待展开后放入右侧 AirDrop 区域 |

快捷键均可在设置中修改。AirDrop 由 macOS 处理，不会自动选择接收人；网络图片能否直接拖入，取决于浏览器是否提供可读取的图片或文件数据。

## 权限与数据

| 权限 | 按需授权后的用途 |
| --- | --- |
| 日历 / 提醒事项 | 只读展示系统日程和待办 |
| 自动化 | 读取和控制 Apple Music / Spotify |
| 辅助功能 | 捕获选中内容，以及可选媒体键接管和菜单栏避让 |
| 蓝牙 | 可选的已配对耳机连接提示与系统提供的电量 |

音乐、自动剪贴板历史、耳机连接提示和媒体键接管默认关闭。应用不需要屏幕录制权限。

收纳内容、设置和历史保存在本机的 `~/Library/Application Support/Island`。`Island` 是旧项目名，保留此目录和内部标识是为了兼容已有数据。

打开网页预览时会向对应网站请求内容；音乐封面可能从播放器提供的网络地址加载。启用 Codex 连接并发送内容时，请同时留意所连接服务的数据处理方式。不要将个人收纳数据、会话日志或登录凭据上传到公开 Issue。

## 快速开始

开发环境需要包含 **macOS 26 SDK 的 Xcode / Command Line Tools** 和 **Swift 6 工具链**。最低运行系统仍为 macOS 14。

```bash
git clone https://github.com/matt-liao-0108/Nisla.git
cd Nisla
bash scripts/build-app.sh
```

在 Finder 中打开 `.build/Nisla.app`。脚本从仓库内固定版本的源码构建音乐辅助组件，不需要安装 Homebrew。

从仓库根目录运行回归检查：

```bash
bash scripts/check.sh
```

检查使用隔离数据和模拟服务，不发送真实模型任务，也不修改真实音量、亮度、播放器或日历。没有 WindowServer 时会跳过原生窗口检查。

更多构建、测试和组件说明见 [开发说明](docs/DEVELOPMENT.md)；维护者发布步骤见 [GitHub 发布指南](docs/PUBLISHING.md)。

## 当前限制

- 系统“正在播放”读取和内置屏幕亮度控制使用非公开接口，系统更新可能影响兼容性；当前版本不适合直接提交 Mac App Store。
- 音乐能力取决于播放器是否提供相应信息，不能保证控制所有后台播放器。
- AirDrop、系统授权、不同浏览器、耳机和多显示器组合仍需更多实机测试。
- Codex 日志展示和 App Server 连接需要兼容的本机环境；真实回复、审批和额度能力不保证所有版本均可用。
- Claude Code 和 WorkBuddy 的双向连接尚未实现；所有显示器目前共享展开状态。

## 反馈与贡献

欢迎提交 Issue 和 Pull Request。反馈时请提供 Nisla 版本、macOS 版本、芯片架构、复现步骤，以及经过脱敏的截图。

修改功能后请运行相应检查，并在涉及窗口、拖拽或系统授权时补充实机验证说明。

## 许可证与致谢

项目自有代码采用 [MIT License](LICENSE)。

内置的 [MediaRemote Adapter](https://github.com/ungive/mediaremote-adapter) 保持 **BSD-3-Clause** 许可，版权、源码版本和许可证保留在 [`Vendor/MediaRemoteAdapter`](Vendor/MediaRemoteAdapter)。第三方代码适用其各自许可证。

Nisla 是独立项目，与 Apple、OpenAI 及文中提到的播放器品牌无隶属或官方合作关系。
