# Codex 关机守卫

Windows 本地 Codex 任务监控、账户额度面板与任务完成后关机工具。原生托盘程序负责监控和关机判断，聊天插件提供状态查询与控制入口。

- 查看主任务、子代理及所属父任务，管理本轮需要等待或无视的任务。
- 显示账户额度窗口、剩余额度及重置时间。
- 明确开启自动关机后，等待任务完成并进入可撤销的倒计时。
- 使用当前系统代理启动 Codex，并分别设置两个启动方向：守卫启动时启动 Codex、启动 Codex 时启动守卫。

功能只覆盖本机 Codex 桌面任务。项目通过 GitHub 分发，尚未上架 OpenAI 官方插件目录。

## 下载与运行条件

在 [1.1.0 Release](https://github.com/xury222/codex-shutdown-guard/releases/tag/v1.1.0) 下载 `codex-shutdown-guard-windows-1.1.0.zip`，完整解压后再安装。

原生程序使用系统 Windows PowerShell 5.1。可选的聊天插件另需本机可用的 `node` 命令，以及支持 `codex plugin` 命令的 Codex CLI。本包不附带 Node.js，无需安装 npm 包；本版验证使用 Node.js 24.15.0。

## 安装原生守卫

在解压后的 `plugins\codex-shutdown-guard` 目录打开 PowerShell，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

新安装默认使用 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`。安装器会复用已有有效注册或带产品安装标记的旧安装，包括旧的 `D:\Program\CodexShutdownGuard`；同时创建当前用户的桌面和登录启动快捷方式。

守卫启动后默认未布防。只有明确开启自动关机后，任务完成和倒计时结束才会触发 Windows 关机。托盘中的“任务完成后自动关机”是一个勾选项，取消勾选即可取消自动关机。

“启动 Codex 时自动启动守卫”首次安装默认关闭，可在托盘或聊天中另行开启；更新会保留已有选择。守卫已布防时，安装器会拒绝更新，须先取消自动关机再手动运行安装命令。

只安装、不启动程序时，在命令末尾加 `-NoStart`。自定义目录、校验和卸载步骤见 [安装说明](docs/INSTALL.md)。

## 安装聊天插件（可选）

安装原生程序后，可在 PowerShell 中注册本仓库的固定版本并安装插件：

```powershell
codex plugin marketplace add xury222/codex-shutdown-guard --ref v1.1.0
codex plugin add codex-shutdown-guard@codex-shutdown-guard-local
```

也可在完整发行包的解压根目录使用本地来源：

```powershell
codex plugin marketplace add .
codex plugin add codex-shutdown-guard@codex-shutdown-guard-local
```

使用本地来源时保留解压目录，供 marketplace 后续读取。在 Codex 中启用“Codex 关机守卫”，并在本地聊天中使用；若工具列表尚未刷新，重启 Codex 后再打开聊天。

启用聊天插件不会自动安装原生程序、启动守卫或开启自动关机。可以请求“查看关机守卫状态和账户额度”“显示关机守卫面板”“取消自动关机”“启动 Codex 时自动启动守卫”。完整的 9 个工具见 [插件说明](plugins/codex-shutdown-guard/README.md)。

## 版本与反馈

[1.1.0 版本说明](RELEASE_NOTES.md) 记录任务识别、窗口和托盘的修复；[验证记录](VALIDATION.md) 列出 932 项隔离检查及验证范围。本版未执行真实关机、重启或另一台电脑的验收。

从源码重新打包时，在仓库根目录运行 `python scripts/build-release.py`，产物写入 `dist`。源码清单为 `SOURCE_SHA256SUMS.txt`，Release 附件 `SHA256SUMS.txt` 用于校验两份 ZIP。

问题反馈请提交到 [Issues](https://github.com/xury222/codex-shutdown-guard/issues)，并提供版本、Windows 环境、操作步骤及必要的已脱敏日志。公开附件不要包含账户凭据、私人会话或用户配置。