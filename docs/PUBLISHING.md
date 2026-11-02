# 发布到 GitHub

本指南按仓库 `matt-liao-0108/Nisla` 编写。如果最终名称不同，请同步修改根目录 README 中的链接和克隆地址。

## 创建空仓库

在 GitHub 的 Repositories 页面点击 **New**：

- Repository name：`Nisla`
- Description：`A native macOS notch shelf for files, music, calendar and live activities.`
- Visibility：`Public`
- 不勾选初始化 README、`.gitignore` 或 License；这些文件已在本地准备好。

点击 **Create repository**。创建独立仓库，不要放入已有的个人主页仓库。

## 上传源码

在含 `Package.swift`、`README.md`、`LICENSE`、`Sources/` 和 `scripts/` 的仓库根目录执行：

```bash
git init -b main
git status --short --untracked-files=all
```

待上传内容应包含 README、许可证、文档，以及 `Sources`、`Tests`、`Support`、`Vendor`、`scripts` 和 `Package.swift`。`.build`、`dist`、缓存、安装包、签名密钥和 `.env` 不应出现。

检查后提交并推送：

```bash
git add .
git diff --cached --stat
git commit -m "Initial public release of Nisla"
git remote add origin https://github.com/matt-liao-0108/Nisla.git
git push -u origin main
```

首次使用 Git 时，如果要求配置身份，请设置自己的姓名和提交邮箱；想隐藏私人邮箱，可使用 GitHub 账号设置提供的 noreply 邮箱。HTTPS 推送需要 GitHub 支持的认证方式，不能直接使用账号密码。不要把 Token 写进项目文件或远程 URL。

也可以使用 GitHub Desktop 添加本地仓库，检查 Changes、提交后推送。不要直接把包含隐藏构建目录的整个工作区拖进网页上传；网页上传不会替你执行本地 `.gitignore`。

## 发布安装包

源码推送成功后，进入 **Releases → Draft a new release**：

- Tag：`v0.2.42`，对应此版本的源码提交。
- Title：`Nisla v0.2.42 (Preview)`。
- 正文可使用 [`releases/v0.2.42.md`](releases/v0.2.42.md)。
- 勾选 **Set as a pre-release**，明确这是测试版本。
- 附件拖入 `dist/Nisla-0.2.42-universal-vnzgGg.zip`。

确认附件上传完成，再发布。用户应下载你上传的安装包；GitHub 自动生成的 `Source code` 资产不能直接运行。

当前包没有 Developer ID 签名和苹果公证，请保留 Release 中的签名说明。

## 后续更新

1. 更新 `Support/Info.plist` 中的版本号和构建号，以及分享版使用说明。
2. 运行相关测试；需要新安装包时执行 `bash scripts/package-share.sh`。
3. 提交并推送源码，为对应提交建立同版本 Tag 和 Release。
4. 上传 ZIP，写明变更和已知限制，不把安装包提交进源码历史。

发布前核对版本号、源码提交、压缩包和 SHA-256，避免上传旧版应用。

## 许可声明

自有代码使用根目录 MIT `LICENSE`；第三方组件继续保留 `Vendor/MediaRemoteAdapter/LICENSE` 的 BSD-3-Clause 许可。公开源码和分发二进制时，保留适用的第三方版权和许可声明。
