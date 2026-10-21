## Codex 关机守卫 1.1.1

完整解压 Windows 包，双击根目录的 `Install.cmd`，在窗口中点击“安装并启动”，即可安装原生守卫，无需手动输入命令。

### 下载

- `codex-shutdown-guard-windows-1.1.1.zip`：完整 Windows 包，包含双击安装及卸载窗口、原生源码、聊天插件和本地 marketplace。普通安装请选择此文件。
- `codex-shutdown-guard-plugin-1.1.1.zip`：单插件目录及随包原生源码，不含根目录的双击安装窗口。
- `SHA256SUMS.txt`：两份 ZIP 的 SHA-256 校验清单。

原生守卫使用系统 Windows PowerShell 5.1。新安装默认位于 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`，兼容已有有效注册或带产品标记的旧安装。

### 变化

- 新增中文安装窗口、进度及错误结果显示，支持双击安装和更新原生守卫。
- 聊天插件改为窗口中的可选项，自动检查 Node.js、Codex CLI 和 Git；缺少依赖时提供官网下载入口，不自动安装第三方软件。
- 新增 `Uninstall.cmd` 卸载窗口，保留状态目录和额外文件。
- 聊天插件使用固定 GitHub 版本 `v1.1.1`，不会自动重启 Codex 或启用已有停用插件。安装后关闭并重新打开 Codex，以刷新工具。

安装不会开启自动关机。更新会保留已有配置；已布防时须先取消自动关机，再重新安装。聊天插件失败时，窗口会说明原生守卫是否已安装。

### 验证范围

本版新增安装入口验证，详见 [验证记录](https://github.com/xury222/codex-shutdown-guard/blob/v1.1.1/VALIDATION.md)。1.1.0 的 932 项隔离检查保留为上一版记录；本版未执行真实关机、重启或另一台电脑的验收。

完整步骤见 [安装说明](https://github.com/xury222/codex-shutdown-guard/blob/v1.1.1/docs/INSTALL.md)。