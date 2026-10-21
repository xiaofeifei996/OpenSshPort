# 上游源码记录（Upstream source record）

本仓库基于以下上游发布包构建：

- 项目：OpenSshPort 1.1.0（OpenSSH Settings）
- 发布：2023-07-23，默认分支 `main`
- 上传归档：`OpenSshPort-main.zip`，27,880 字节
- SHA-256：`649d78135c0a3dbbee623e3a37aec950a0f63f64dc2868e7dcb6b84bb3cd6ff5`

相对上游的改动（仅构建/本地化需要，不改变功能逻辑）：

1. `Makefile` — 适配 CI 的 iPhoneOS15.6 SDK、arm64e 包架构与 rootless 布局（RootHide 可从 `/var/jb` 读取）。
2. `OpenSshPort.m` — 界面中文化；`SSHswitch` 路径探测（`JB_ROOT_PATH` → `/var/jb` → 根目录）及版本校验回退。
3. `Resources/OpenSshPort.plist`、`entry.plist` — 中文化；`entry.plist` 转为 XML。
4. `control` — 架构 `iphoneos-arm64e`、中文名称/描述、维护者信息。

GitHub Actions 工作流 `.github/workflows/build.yml` 会在每次推送到 `main` 时构建 `.deb` 并上传 Release。
