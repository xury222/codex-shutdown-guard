# Codex 关机守卫插件 1.1.0

插件为 Windows 原生 CodexShutdownGuard 提供聊天控制入口，沿用原托盘、任务监控与额度面板。

## 安装

原生程序使用系统 Windows PowerShell 5.1。聊天 MCP 服务另需本机可用的 `node` 命令；本包不附带 Node.js 安装器，无需 npm 依赖。

在本目录打开 PowerShell，由用户执行原生程序安装：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

只安装、不启动时，在命令末尾加 `-NoStart`。新安装默认位于 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`；已有有效注册或带安装标记的旧安装会继续复用。默认注册文件固定为 `%LOCALAPPDATA%\CodexShutdownGuard\installation.json`，记录 `installRoot` 和 `stateRoot`；自定义 `StateRoot` 时仍通过该文件发现安装。守卫已布防时，安装器会拒绝更新；先取消自动关机，再手动运行安装命令。

聊天插件可从 GitHub 的固定版本安装：

```powershell
codex plugin marketplace add xury222/codex-shutdown-guard --ref v1.1.0
codex plugin add codex-shutdown-guard@codex-shutdown-guard-local
```

从完整 Windows 发行包安装时，也可在解压根目录使用本地来源：

```powershell
codex plugin marketplace add .
codex plugin add codex-shutdown-guard@codex-shutdown-guard-local
```

之后在 Codex 中启用插件，并在本地聊天中使用。完整 Windows 发行包的本地 marketplace 配置位于 `.agents/plugins/marketplace.json`；只解压本插件目录不包含该配置。使用本地来源时，应保留解压目录供 marketplace 读取。

启用插件不会自动安装原生程序或布防。首次安装时，“启动 Codex 时自动启动守卫”默认关闭；更新保留已有设置。原生守卫启动后也默认未布防。

## 聊天控制

| 工具 | 用途 |
| --- | --- |
| `guard_status` | 只读查询状态、任务快照、设置与账户额度 |
| `guard_show` | 显示原生面板 |
| `guard_arm` | 开启任务完成后自动关机 |
| `guard_disarm` | 取消自动关机及倒计时 |
| `guard_rescan` | 请求重新扫描任务 |
| `guard_stop` | 取消监控并退出守卫 |
| `guard_launch_codex` | 使用当前系统代理启动 Codex |
| `guard_set_codex_autostart` | 设置守卫启动时是否启动 Codex |
| `guard_set_guard_autostart` | 设置启动 Codex 时是否启动未布防的守卫 |

示例：“查看关机守卫状态和账户额度”“本轮全部任务完成后关机”“取消自动关机”“启动 Codex 时自动启动守卫”。两个启动选项相互独立，都不会开启自动关机。

原生面板提供任务无视与恢复、主任务和子代理归属、完整任务信息、额度窗口与重置时间，以及显示、隐藏、拖动和位置保存。托盘中的自动关机操作合并为一个勾选项，取消勾选即取消自动关机；托盘“查看状态”已移除，只读聊天查询继续保留。

状态查询包含快照时间和新鲜度。控制请求可能排队，需再次查询状态确认执行结果。自动关机仍由原生守卫判断，等待、倒计时和撤销规则见 [原生程序说明](skills/codex-shutdown-guard/assets/native/README.md)。

## 程序与状态

运行时读取已注册的有效安装，兼容带产品安装标记的每用户目录与旧 `D:\Program\CodexShutdownGuard`。无有效安装时会报告缺失，不会为了完成状态查询而安装程序。

随包原生源码位于 `skills/codex-shutdown-guard/assets/native`，哈希清单位于 `skills/codex-shutdown-guard/assets/source-manifest.json`。插件不会自动用随包源码覆盖已安装程序。本包不含用户配置、日志、Codex 会话或账户凭据。

卸载原生程序时，在本目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

聊天插件可在 Codex 插件管理中单独移除，原生程序需单独卸载。本插件要求 Windows 本机执行，网页或手机端无法直接运行包内程序。完整安装步骤及发行包下载见 [GitHub 仓库](https://github.com/xury222/codex-shutdown-guard)。