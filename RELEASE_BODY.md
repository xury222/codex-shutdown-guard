## Codex 关机守卫 1.1.0

本版本提供 Windows 原生守卫、Codex 聊天插件和安装脚本。

### 下载

- `codex-shutdown-guard-windows-1.1.0.zip`：完整安装包，包含原生源码、聊天插件和本地 marketplace。首次安装请下载此文件。
- `codex-shutdown-guard-plugin-1.1.0.zip`：单插件目录，适合已有安装或单独管理插件源码的用户。
- `SHA256SUMS.txt`：两个 ZIP 的 SHA-256 校验清单。

完整解压 Windows 包，在 `plugins\codex-shutdown-guard` 目录打开 PowerShell，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

新安装默认位于当前用户的 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`，兼容旧的受标记安装。原生程序需要 Windows PowerShell 5.1；可选聊天插件另需 Node.js 和支持插件命令的 Codex CLI。

### 变化

- 修复 Guardian 内部审批上下文、会话身份和继承历史造成的任务误判，补充主任务、子代理与父任务注明。
- 修复任务统计文本裁切，调整任务窗口尺寸。
- 托盘自动关机合并为一个勾选项，移除“查看状态”。
- 增加可选的“启动 Codex 时自动启动守卫”和第 9 个聊天工具。
- 统一安装目录与状态目录发现；更新保留已有配置，卸载保留状态目录和未知文件。

守卫启动后默认未布防。“启动 Codex 时自动启动守卫”首次安装默认关闭。守卫已布防时，须先取消自动关机再更新；启用聊天插件不会自动安装原生程序或布防。

### 验证范围

932 项隔离检查通过，包含安装、保留配置更新、卸载、任务识别、窗口与 MCP 控制检查。本版未执行真实关机、重启或另一台电脑的验收；安装包未附带用户配置、私人会话、日志或账户凭据。

详细步骤见 [安装说明](https://github.com/xury222/codex-shutdown-guard/blob/v1.1.0/docs/INSTALL.md)，测试范围见 [验证记录](https://github.com/xury222/codex-shutdown-guard/blob/v1.1.0/VALIDATION.md)。