# Codex 关机守卫

Windows 本地 Codex 任务监控、账户额度面板与任务完成后关机工具。1.2.0 以独立托盘程序分发，操作入口位于桌面快捷方式、用量面板和系统托盘。

- 主任务决定是否等待；子代理和内部审批保留在列表中，不单独阻止关机。
- 文件已移除且未观测到未结束回合时，清理残留的读取占位；用户会话和压缩副本保留。
- 显示账户剩余额度、额度窗口与重置时间。
- 手动开启自动关机后，等待主任务完成，再进入可撤销的倒计时。
- 使用系统代理启动 Codex，并分别设置守卫启动时启动 Codex、启动 Codex 时启动守卫。

功能覆盖本机 Codex 桌面任务。任务监控和关机判断均由独立程序完成，无需 MCP、Node.js、Git 或 Codex CLI。

## 双击安装

1. 在 [1.2.0 Release](https://github.com/xury222/codex-shutdown-guard/releases/tag/v1.2.0) 下载 `codex-shutdown-guard-windows-1.2.0.zip`，右键选择“全部解压”。
2. 双击解压根目录的 `Install.cmd`，在窗口中点击“安装并启动”。

安装器使用系统 Windows PowerShell 5.1。新安装默认位于 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`，创建桌面和当前用户登录启动快捷方式；已有有效注册或带产品标记的旧安装会继续复用。更新保留配置和状态目录中的偏好。

守卫启动后默认未布防。需要自动关机时，在面板或托盘中开启“任务完成后自动关机”；取消开关即可撤销关机。已布防的守卫须先取消自动关机，等待状态更新后再安装新版。

完整仓库源码也可使用同一安装入口。详细步骤、自定义安装和等待规则见 [安装说明](docs/INSTALL.md)，原生程序与配置说明见 [使用手册](native/README.md)。

## 移除旧聊天插件

1.2.0 的安装包不含 MCP 服务、聊天工具或 marketplace，也不会安装聊天插件。已有旧聊天插件时，可在 Codex 插件管理中单独移除；移除聊天插件不会卸载守卫，也不会改动守卫配置。新版安装器不代替用户修改 Codex 中已有的插件安装。

## 卸载与反馈

需要卸载独立守卫时，双击完整包根目录的 `Uninstall.cmd`，点击“卸载守卫”。此操作移除属于本安装的程序文件及快捷方式，保留状态目录和额外文件。

[版本说明](RELEASE_NOTES.md) 记录本版与历史版本变化，本轮检查见 [验证记录](VALIDATION.md)。从源码打包可在仓库根目录运行 `python scripts/build-release.py`。源码清单为 `SOURCE_SHA256SUMS.txt`，Release 附件 `SHA256SUMS.txt` 用于校验 Windows ZIP。

问题反馈请提交到 [Issues](https://github.com/xury222/codex-shutdown-guard/issues)，附上版本、Windows 环境、操作步骤及必要的已脱敏日志。公开附件不要包含账户凭据、私人会话或用户配置。
