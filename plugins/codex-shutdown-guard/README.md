# Codex 关机守卫插件 1.1.2

插件为 Windows 原生 CodexShutdownGuard 提供聊天控制入口，沿用原托盘、任务监控与额度面板。

## 安装

普通用户请下载 [完整 Windows 包](https://github.com/xury222/codex-shutdown-guard/releases/tag/v1.1.2)，完整解压后双击根目录的 `Install.cmd`，在窗口中点击“安装并启动”。勾选“同时安装 / 更新 Codex 聊天插件（可选，需联网）”后，窗口会在后台执行插件安装，无需手动输入命令。

原生守卫使用系统 Windows PowerShell 5.1，不需要 Node.js、Git 或 Codex CLI。聊天插件另需 Node.js 18 或更新版本、支持插件命令的 Codex CLI，以及 Git；窗口会检测依赖，包括 Codex 桌面应用自带的 CLI。缺少依赖时，可通过窗口链接前往官网下载，补齐后重新打开安装窗口。安装器不会自动下载或安装依赖，Node.js 建议选择官网 LTS 版本。

通过窗口安装的聊天插件使用固定 GitHub 版本 `v1.1.2`，无需保留解压目录。完成后关闭并重新打开 Codex，以刷新工具。安装器不会重启 Codex，也不会自动启用已停用的插件。

新安装默认位于 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`，兼容已有有效注册及带产品标记的旧安装。固定注册文件 `%LOCALAPPDATA%\CodexShutdownGuard\installation.json` 记录 `installRoot` 和 `stateRoot`。更新会保留配置；守卫已布防时须先取消自动关机再安装。

守卫启动后默认未布防。“启动 Codex 时自动启动守卫”首次安装默认关闭；启用聊天插件本身不会安装原生程序或开启自动关机。完整步骤见 [仓库安装说明](https://github.com/xury222/codex-shutdown-guard/blob/v1.1.2/docs/INSTALL.md)。

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

原生面板提供任务无视与恢复、主任务和子代理归属、完整任务信息、额度窗口与重置时间，以及显示、隐藏、拖动和位置保存。主任务决定是否等待，子代理和内部审批保留在列表中，不单独阻止关机；来源未识别或全局扫描错误仍会暂停关机。托盘自动关机操作为一个勾选项，取消勾选即取消自动关机。

状态查询包含快照时间和新鲜度。控制请求可能排队，需再次查询状态确认执行结果。自动关机仍由原生守卫判断，等待、倒计时和撤销规则见 [原生程序说明](skills/codex-shutdown-guard/assets/native/README.md)。

## 程序与状态

插件读取已注册的有效安装，兼容带产品标记的每用户目录和旧 `D:\Program\CodexShutdownGuard`。无有效安装时会报告缺失，不会为完成查询而安装程序。

随包原生源码位于 `skills/codex-shutdown-guard/assets/native`，哈希清单位于 `skills/codex-shutdown-guard/assets/source-manifest.json`。插件不会自动用随包源码覆盖已安装程序。本包不含用户配置、日志、Codex 会话或账户凭据。

完整 Windows 包根目录的 `Uninstall.cmd` 可打开守卫卸载窗口；聊天插件在 Codex 插件管理中单独移除。本插件要求 Windows 本机执行，网页或手机端无法直接运行包内程序。

## 可选：单插件包与手动安装

单插件 ZIP 不包含根目录的双击安装窗口或 marketplace 配置。需要这些入口时应下载完整 Windows 包。

在本插件目录打开 PowerShell，可手动安装原生守卫；只安装不启动时加 `-NoStart`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

聊天插件可从固定 GitHub 版本安装：

```powershell
codex plugin marketplace add xury222/codex-shutdown-guard --ref v1.1.2
codex plugin add codex-shutdown-guard@codex-shutdown-guard-local
```

使用完整包的本地来源时，在解压根目录将第一条命令改为 `codex plugin marketplace add .`，并保留该目录。已有同名来源时请先核对；安装窗口仅处理可确认属于本仓库的注册。