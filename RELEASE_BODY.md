## Codex 关机守卫 1.1.2

主任务完成后，残留的子代理和内部审批不再单独阻止关机。它们仍保留在任务列表中，显示名称、父任务和异常提示，状态注明“不阻塞”。

### 下载

- `codex-shutdown-guard-windows-1.1.2.zip`：完整 Windows 包，包含双击安装及卸载窗口、原生源码、聊天插件和本地 marketplace。普通安装请选择此文件。
- `codex-shutdown-guard-plugin-1.1.2.zip`：单插件目录及随包原生源码，不含根目录的双击安装窗口。
- `SHA256SUMS.txt`：两份 ZIP 的 SHA-256 校验清单。

完整解压 Windows 包，双击根目录的 `Install.cmd`，在窗口中点击“安装并启动”。原生守卫使用系统 Windows PowerShell 5.1，无需手动输入命令。

### 等待规则

已识别的子代理即使仍活动、疑似失联或日志读取异常，也不会单独增加阻塞数量。主任务异常、来源未识别的记录及全局扫描错误继续暂停关机。只有子代理、从未观察到主任务时，不会启动倒计时。

主任务完成后仍需连续 3 次空闲确认，并经过可撤销的关机缓冲。新主任务会撤销倒计时。

安装不会开启自动关机。更新会保留已有配置；已布防时须先取消自动关机，再重新安装。可选聊天插件使用固定 GitHub 版本 `v1.1.2`。

### 验证范围

本轮检查见 [验证记录](https://github.com/xury222/codex-shutdown-guard/blob/v1.1.2/VALIDATION.md)。本版未执行真实关机、重启或另一台电脑的验收。

完整步骤见 [安装说明](https://github.com/xury222/codex-shutdown-guard/blob/v1.1.2/docs/INSTALL.md)。