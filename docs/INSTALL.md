# 安装与卸载

## 下载完整 Windows 包

在 [1.1.2 Release](https://github.com/xury222/codex-shutdown-guard/releases/tag/v1.1.2) 下载 `codex-shutdown-guard-windows-1.1.2.zip`，右键选择“全部解压”。请先完整解压，勿只从 ZIP 中打开一个 CMD 文件。

Windows 包包含双击安装窗口、原生守卫、聊天插件和本地 marketplace。单独的 `codex-shutdown-guard-plugin-1.1.2.zip` 只包含插件目录及随包原生源码，没有根目录的双击安装窗口。完整克隆或下载仓库源码后，也可运行根目录的安装入口。

## 安装守卫

双击解压根目录的 `Install.cmd`，点击“安装并启动”。安装窗口会显示操作进度和结果；操作未结束时请等待完成。

原生程序使用系统 Windows PowerShell 5.1，不依赖 Node.js、Git 或 Codex CLI。新安装默认位于 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`，会创建桌面与当前用户登录启动快捷方式，并请求启动未布防的守卫。

已有有效注册或带产品标记的旧安装会继续复用，包括旧的 `D:\Program\CodexShutdownGuard`。固定注册文件 `%LOCALAPPDATA%\CodexShutdownGuard\installation.json` 记录程序和状态目录，安装器与聊天插件读取同一安装。

安装不会开启自动关机。需要使用时，在系统托盘中勾选“任务完成后自动关机”；取消勾选即可取消自动关机及倒计时。已有守卫若开启了自动关机，须先取消，等待状态更新后再安装；安装器不会替你取消或重启已布防的守卫。

## 自动关机等待规则

守卫等待本机尚未完成的主任务。子代理和内部审批保留名称、父任务和异常提示，但不会单独阻止关机；主任务完成后，无需等待残留子代理。只有子代理、从未观察到主任务时，不会启动关机倒计时。

来源尚未识别的任务、主任务状态异常及全局扫描错误仍会暂停关机。主任务需要连续 3 次空闲确认，再进入可撤销的倒计时。

## 同时安装聊天插件

在安装窗口中勾选“同时安装 / 更新 Codex 聊天插件（可选，需联网）”，再开始安装。窗口会执行固定 GitHub 版本 `v1.1.2` 的插件安装，无需手动输入命令。

聊天插件需要 Node.js 18 或更新版本、支持 `codex plugin` 命令的 Codex CLI，以及 Git。安装窗口会检测 PATH 和常见安装位置，并寻找 Codex 桌面应用自带的 CLI。缺少依赖时，聊天插件选项不可选。原生守卫仍可安装。

可通过窗口中的链接打开 [Node.js 官网](https://nodejs.org/en/download)、[Codex 桌面应用说明](https://developers.openai.com/codex/app) 或 [Git for Windows 官网](https://gitforwindows.org/)。安装器不会自动下载或安装这些依赖。Node.js 建议选择官网 LTS 版本；安装依赖后，关闭并重新打开守卫安装窗口以重新检测。

聊天插件安装完成后，关闭并重新打开 Codex，以刷新插件工具。安装器不会自动重启 Codex，也不会启用已经被你停用的聊天插件；若因此停止安装，可在 Codex 中启用该插件后再重试。若窗口报告同名 marketplace 来源冲突，请先在 Codex 插件管理中核对该来源，勿删除无关插件。

原生守卫已安装而聊天插件失败时，窗口会分别说明结果，守卫仍可使用。通过安装窗口注册的是 GitHub 来源，安装完成后无需保留下载的解压目录。

“启动 Codex 时自动启动守卫”首次安装默认关闭，可在托盘或聊天中开启。它与“守卫启动时启动 Codex”相互独立，两个选项均不会开启自动关机。

## 更新与卸载

下载新版本完整 Windows 包，完整解压后双击 `Install.cmd` 即可更新原生守卫，已有配置会保留。需要同时更新聊天插件时，勾选对应选项。旧版本 Release 和标签继续保留。

卸载时双击完整包根目录的 `Uninstall.cmd`，点击“卸载守卫”。卸载会退出守卫和启动监听程序，移除属于本安装的程序文件及快捷方式，保留状态目录和额外文件。聊天插件可在 Codex 插件管理中单独移除；移除聊天插件不会卸载原生守卫。

## 可选：手动命令与校验

需要只安装不启动，或指定目录时，在 `plugins\codex-shutdown-guard` 目录打开 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -NoStart
```

指定安装目录时使用 `-InstallRoot`。目录名必须为 `CodexShutdownGuard`，并为独立空目录或已有受标记安装。更换状态目录前须先退出已有守卫和启动监听程序；旧实例仍运行时，安装器会拒绝切换。

从 GitHub 手动安装聊天插件的命令为：

```powershell
codex plugin marketplace add xury222/codex-shutdown-guard --ref v1.1.2
codex plugin add codex-shutdown-guard@codex-shutdown-guard-local
```

手动使用本地来源时，在完整包根目录将第一条命令改为 `codex plugin marketplace add .`，并保留该目录供 marketplace 读取。已有同名来源时，CLI 可能拒绝重新添加；可使用安装窗口处理本仓库的已知注册，或在 Codex 中核对来源后操作。

校验下载文件时，将 Release 的 `SHA256SUMS.txt` 与 ZIP 放在同一目录，运行：

```powershell
Get-FileHash .\codex-shutdown-guard-windows-1.1.2.zip -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

核对输出中的 SHA-256 与清单内同名文件一致。