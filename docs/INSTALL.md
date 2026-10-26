# 安装与卸载

## 下载 Windows 包

在 [1.2.0 Release](https://github.com/xury222/codex-shutdown-guard/releases/tag/v1.2.0) 下载 `codex-shutdown-guard-windows-1.2.0.zip`，右键选择“全部解压”。请先完整解压，勿只从 ZIP 中打开一个 CMD 文件。

包内提供安装和卸载窗口、独立守卫源码及说明。运行守卫只需 Windows 自带的 Windows PowerShell 5.1，无需 MCP、Node.js、Git 或 Codex CLI。

## 安装守卫

双击解压根目录的 `Install.cmd`，点击“安装并启动”。窗口显示操作进度和完成或失败结果，操作结束前请保留窗口。

新安装默认位于 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`，创建桌面与当前用户登录启动快捷方式，并请求启动未布防的守卫。已有有效注册或带产品标记的旧安装会继续复用，包括旧的 `D:\Program\CodexShutdownGuard`。

固定注册文件 `%LOCALAPPDATA%\CodexShutdownGuard\installation.json` 记录程序和状态目录。安装器、卸载器与原生命令行读取同一安装；更新保留 `config.json`、任务无视记录、面板偏好和启动设置。

需要自动关机时，在用量面板或系统托盘中开启“任务完成后自动关机”；取消开关即可取消自动关机及倒计时。已有守卫若已布防，须先取消并等待状态更新后再安装；安装器会拒绝更新已布防的实例。

## 自动关机等待规则

守卫等待本机尚未完成的主任务。子代理和内部审批保留名称、父任务和异常提示，但不单独阻止关机；只有子代理、从未观察到主任务时，不会启动倒计时。

会话文件已移除，且守卫没有观察到该文件中仍有活动或状态未知的回合时，会自动清理遗留的“读取中”占位。这只清理内存记录，保留会话文件和 `.jsonl.zst` 压缩副本。

仍在读取或读取异常的记录标明已有任务名或线程 ID，并提供项目目录和原因。未结束回合的缺失文件、权限或 I/O 错误、来源未识别的有效记录及全局扫描错误继续暂停关机。主任务完成后需连续 3 次空闲确认，再进入可撤销的倒计时；新主任务会撤销倒计时。

## 启动设置与旧聊天插件

“启动 Codex 时自动启动守卫”首次安装默认关闭，可在托盘中开启。它与“守卫启动时自动启动 Codex”相互独立，两项设置均不会开启自动关机。原有设置在更新时保留。

1.2.0 不再包含 MCP 或聊天插件安装入口。若以前安装过聊天插件，可在 Codex 插件管理中单独移除，独立守卫继续运行。安装器不会自动卸载 Codex 中已有的聊天插件或删除其他插件。

## 更新与卸载

下载新版 Windows 包，完整解压后双击 `Install.cmd` 即可更新。旧版本 Release 和标签继续保留，历史聊天插件包可在对应旧版本中找到。

需要卸载守卫本体时，双击完整包根目录的 `Uninstall.cmd`，点击“卸载守卫”。卸载会退出守卫和启动检测器，移除属于本安装的程序文件与快捷方式，保留状态目录和额外文件。

## 可选：手动命令与校验

需要只安装不启动，或指定目录时，在完整包根目录打开 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\native\Install.ps1 -NoStart
```

指定安装目录时使用 `-InstallRoot`。目录名必须为 `CodexShutdownGuard`，并为独立空目录或已有受标记安装。更换状态目录前须先退出旧目录对应的守卫和启动检测器；旧实例仍运行时，安装器会拒绝切换。

校验下载文件时，将 Release 的 `SHA256SUMS.txt` 与 ZIP 放在同一目录，运行：

```powershell
Get-FileHash .\codex-shutdown-guard-windows-1.2.0.zip -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

核对输出中的 SHA-256 与清单内同名文件一致。