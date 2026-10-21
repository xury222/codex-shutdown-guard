# 安装与卸载

## 选择下载文件

首次安装请在 [1.1.0 Release](https://github.com/xury222/codex-shutdown-guard/releases/tag/v1.1.0) 下载 `codex-shutdown-guard-windows-1.1.0.zip`。它包含原生守卫、聊天插件、安装脚本和本地 marketplace。

`codex-shutdown-guard-plugin-1.1.0.zip` 只包含插件目录及随包原生源码，不含仓库根目录的 marketplace 配置。通过本地 marketplace 安装聊天插件时，应使用完整 Windows 包，或按 [README](../README.md) 从 GitHub 注册。

校验下载文件时，将 Release 的 `SHA256SUMS.txt` 与 ZIP 放在同一目录，运行：

```powershell
Get-FileHash .\codex-shutdown-guard-windows-1.1.0.zip -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

核对输出中的 SHA-256 与清单内同名文件一致，再完整解压 ZIP。

## 安装原生守卫

进入解压后的 `plugins\codex-shutdown-guard` 目录，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

原生程序使用系统 Windows PowerShell 5.1。安装器创建桌面与当前用户登录启动快捷方式，并启动未布防的守卫。只安装、不启动时使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -NoStart
```

新安装默认位于 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`。已有有效注册或带产品标记的旧安装会继续复用，包括旧的 `D:\Program\CodexShutdownGuard`。固定注册文件 `%LOCALAPPDATA%\CodexShutdownGuard\installation.json` 记录程序和状态目录。

指定新安装目录时，目录名必须为 `CodexShutdownGuard`，且应为独立的空目录或已有受标记安装，例如：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -InstallRoot "$env:LOCALAPPDATA\Programs\CodexShutdownGuard"
```

更换状态目录前先退出已有守卫及启动监听程序；旧实例仍运行时，安装器会拒绝切换。更新会保留已有配置；守卫已布防时，先取消自动关机，再运行安装命令。

## 可选聊天插件

聊天插件需要本机 Node.js 和支持插件命令的 Codex CLI，无需 npm 包。在完整发行包的解压根目录运行：

```powershell
codex plugin marketplace add .
codex plugin add codex-shutdown-guard@codex-shutdown-guard-local
```

保留解压目录，然后在 Codex 中启用插件并在本地聊天中使用。若工具列表没有刷新，重启 Codex。启用插件不会自动安装原生守卫或布防。

“启动 Codex 时自动启动守卫”首次安装默认关闭，可在托盘或聊天中开启。它与“守卫启动时启动 Codex”相互独立，两个选项均不会开启自动关机。

## 卸载

在 `plugins\codex-shutdown-guard` 目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

卸载会退出守卫和启动监听程序，移除属于本安装的程序文件及快捷方式，保留状态目录和未知文件。Codex 聊天插件可在插件管理中单独移除；移除聊天插件不会卸载原生程序。