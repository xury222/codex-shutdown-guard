## Codex 关机守卫 1.2.0

本版以独立 Windows 程序分发，移除 MCP 服务和聊天控制入口。原有托盘、任务监控、额度面板、自动关机、任务无视、代理启动及两项启动设置保留。

### 下载与安装

- `codex-shutdown-guard-windows-1.2.0.zip`：完整 Windows 包，包含双击安装及卸载窗口、原生源码和说明。
- `SHA256SUMS.txt`：Windows ZIP 的 SHA-256 校验清单。

完整解压 Windows 包，双击根目录的 `Install.cmd`，在窗口中点击“安装并启动”。程序使用系统 Windows PowerShell 5.1，无需手动输入命令，也不依赖 Node.js、Git 或 Codex CLI。

### 更新保留内容

更新会复用已有有效安装，保留配置、面板偏好、任务无视记录和启动设置。安装不会开启自动关机；已布防时须先取消，再重新安装。

新包不含 MCP、marketplace 或单独的聊天插件 ZIP。以前安装过聊天插件时，可在 Codex 插件管理中单独移除，独立守卫继续运行。根目录的 `Uninstall.cmd` 用于卸载守卫本体。

本轮检查见 [验证记录](https://github.com/xury222/codex-shutdown-guard/blob/v1.2.0/VALIDATION.md)，完整步骤见 [安装说明](https://github.com/xury222/codex-shutdown-guard/blob/v1.2.0/docs/INSTALL.md)。
