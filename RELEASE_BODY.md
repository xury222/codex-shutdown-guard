## Codex 关机守卫 1.1.3

修复历史会话文件已移除后，守卫仍保留“正在读取任务记录”并长期阻止关机的问题。没有已观测未结束回合的缺失文件会自动清理内存占位；用户会话和压缩副本保留。

### 下载

- `codex-shutdown-guard-windows-1.1.3.zip`：完整 Windows 包，包含双击安装及卸载窗口、原生源码、聊天插件和本地 marketplace。普通安装请选择此文件。
- `codex-shutdown-guard-plugin-1.1.3.zip`：单插件目录及随包原生源码，不含根目录的双击安装窗口。
- `SHA256SUMS.txt`：两份 ZIP 的 SHA-256 校验清单。

完整解压 Windows 包，双击根目录的 `Install.cmd`，在窗口中点击“安装并启动”。原生守卫使用系统 Windows PowerShell 5.1，无需手动输入命令。

### 读取状态

仍在读取或读取异常的记录显示已有任务名或线程 ID，并保留项目目录和原因。已有未结束回合的缺失文件继续保留异常判断；权限或其他 I/O 错误不会触发清理。主任务与来源未识别的有效记录仍按原规则判断，子代理和内部审批不单独阻塞。

清理适用于历史文件压缩或归档后留下的缓存；仍存在的未读记录继续按原规则判断。

安装不会开启自动关机。更新会保留已有配置；已布防时须先取消自动关机，再重新安装。可选聊天插件使用固定 GitHub 版本 `v1.1.3`。

### 验证范围

本轮检查见 [验证记录](https://github.com/xury222/codex-shutdown-guard/blob/v1.1.3/VALIDATION.md)。本版未执行真实关机、重启或另一台电脑的验收。

完整步骤见 [安装说明](https://github.com/xury222/codex-shutdown-guard/blob/v1.1.3/docs/INSTALL.md)。
