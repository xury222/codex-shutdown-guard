# CodexShutdownGuard

`CodexShutdownGuard` 是一个面向 Windows 版 Codex 桌面应用的跨对话自动关机与用量显示工具。

守卫统一观察本机 Codex 主任务，每 1 分钟读取一次任务状态。连续 3 次确认主任务已完成、没有影响主任务判断的未知状态后，再经过 3 分钟关机缓冲，才会调用 Windows 原生关机命令。子代理和内部审批保留在列表中，不单独阻止关机。

工具还会常驻显示一个小型置顶面板，用进度条展示 Codex 返回的真实账户剩余额度、额度窗口与重置时间。若账户同时返回长周期和短周期额度，面板会显示两条进度条；它不会用本地 token 数猜测账户余额。

## 已实现的安全边界

- 安装后默认未布防，不会因为普通对话结束而关机。
- 必须先观察到至少一个运行中的主任务回合，然后确认主任务完成；只有子代理时继续等待首个主任务。
- 并行主对话、主任务中的审批等待、用户输入等待和长时间工具调用会继续阻止关机。已识别的子代理和内部审批不会单独阻止关机。
- 主任务或来源未识别的状态无法读取、事件格式不兼容，以及 Codex 退出或 App Server 不可用时暂停关机。
- 会话文件消失或无法读取的回合会从“活动任务”移到“状态异常”，不会重复计数。主任务和来源未识别的异常会阻止关机；已识别子代理和内部审批的异常只供查看。
- 活动和异常任务保留为可查看条目；用户可以按精确回合 ID 选择“无视”，被无视的条目仍会显示。子代理不需要勾选无视即可免于阻塞。
- “无视”只对当前回合有效并保存在当前 Codex 应用会话中；同一任务开始新回合或 Codex 重启后不会继承旧的无视决定。
- 无法归属到具体任务的全局读取异常不可无视，继续采用 fail-closed 策略阻止关机。
- 会话事件和标题按 JSON 属性解析，不依赖空格、字段顺序或附加元数据的形状。兼容 task_started/turn_started、task_complete/turn_complete 和 turn_aborted；普通错误、工具结束或超时不会被当作回合完成。
- 线程身份以文件首条 `session_meta.id` 为准，避免多 UUID 文件名带来的错位。子代理及内部审批继承的父会话记录按元数据中的历史边界跳过；不同线程复用同一回合 ID 时也不会互相完成或覆盖。
- 活跃时间采用当前会话最新事件时间和文件修改时间中的较新值，避免 Windows 打开日志句柄时文件时间未刷新的误报。文件时间本身不再用于排除候选文件；启动时会分批读取 `sessions` 中的记录，按事件时间筛选当前应用会话，不扫描 `archived_sessions`。首次读取可能需要更长时间，主任务和来源未识别的记录未读完时继续阻止关机；已识别子代理的记录读取不阻塞。
- 对会话元数据明确标识为 Guardian 内部审批来源的记录，`auto-compact-数字` 形式且没有实际开始事件的上下文不会被列为独立任务；真实内部审批回合仍正常跟踪，但不单独阻止关机。来源不明的上下文与读取异常继续阻止关机。
- 长时间未记录到更新的回合标为“疑似失联”。主任务和来源未识别的回合仍阻止关机，子代理和内部审批只保留提示；恢复更新后自动恢复活动分类。默认判断窗口为 30 分钟，只影响显示与未知状态分类，不会把回合判为完成。
- 尚未写完的事件会显示等待完整事件或未知状态，写入完成后自动恢复。已识别子代理的未完整事件不单独阻止关机；解析错误不输出原始会话文本。
- 使用系统 JSON 流式读取器只提取任务和用量元数据，正文不会进入任务状态。历史文件通过 8 KiB 缓冲读取，通常每批约 1.5 秒；读取未完成时显示“读取记录中”，主任务和来源未识别的记录继续阻止关机，界面和控制请求仍可处理。完整记录必须读完才能验证，单条特别大的记录可能让一批稍长一些。
- Codex App Server 进程同时兼容旧版 WindowsApps `app\resources\codex.exe` 与新版 `%LOCALAPPDATA%\OpenAI\Codex\bin\<版本>\codex.exe` 布局；其他同名进程不会被当作桌面应用。
- 新主任务、影响主任务判断的未知状态或 Codex 不可用会立即撤销确认/倒计时；只有从忙碌转为空闲的方向需要连续 3 次确认。
- 桌面图标和托盘控制请求每 0.5 秒处理一次，与每 1 分钟一次的任务状态扫描分离，因此显示窗口、取消关机和退出不需要等待下一次扫描。重复点击桌面图标时，即使系统仍把无边框面板标记为“已显示”，守卫也会重新显示、置前并激活面板。
- 用量面板读取 Codex 会话中主账户 `codex` 的官方 `rate_limits` 快照；内部任务使用的其他额度桶会被忽略，读取不到时明确显示等待数据，不伪造百分比。
- 用量快照优先按额度重置时间判断有效性；3 分钟仅用于缺少重置时间时的兼容兜底。
- 连续 3 次空闲确认后，3 分钟关机缓冲由 60 秒内部缓冲和 120 秒 Windows 原生倒计时组成；原生倒计时期间仍会再检查任务并可撤销关机。
- 缓冲期间出现新主任务时自动撤销倒计时，并继续等待；子代理活动不撤销倒计时。
- 日志不保存提示词、回复内容或工具输出。

v1 只覆盖本机 Codex 桌面端，不覆盖 ChatGPT 网页、云端任务或其他程序的后台进程。

## 安装

在 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

安装程序会：

1. 新安装默认复制到当前用户的 `%LOCALAPPDATA%\Programs\CodexShutdownGuard`，无需管理员权限。
2. 创建 Windows 开机启动快捷方式。
3. 在桌面创建“Codex 关机守卫”快捷方式。
4. 通过隐藏的 PowerShell 快捷方式在后台启动默认未布防的托盘守卫；不依赖可能被系统策略禁止的 Windows Script Host，也不会创建 Windows Terminal 窗口或任务栏按钮。

“启动 Codex 时自动启动守卫”是独立选项，首次安装默认关闭。更新安装保留已保存的选择；`-NoStart` 只安装文件和维护快捷方式，不启动守卫或启动检测器。此选项的设置不改变已有的 Windows 登录启动快捷方式。

安装器优先使用显式 `-InstallRoot`，否则读取 `%LOCALAPPDATA%\CodexShutdownGuard\installation.json` 注册的安装目录，再查找带产品标记的当前用户默认目录和旧版 `D:\Program\CodexShutdownGuard`。旧版已标记安装会原地更新；无产品标记的非空目录不会被覆盖。更新保留现有 `config.json`、任务无视列表和偏好，运行中的守卫必须先处于未布防状态。显式更换 `StateRoot` 前，必须先退出旧状态目录对应的守卫和检测器；安装器不会同时开启另一套监控。

注册文件记录 `schemaVersion: 1`、`product: CodexShutdownGuard`、完整 `installRoot` 和 `stateRoot`，只在安装完成后原子写入。需要自定义状态位置时可使用 `-StateRoot`；之后省略该参数，安装器、卸载器、插件和原生命令行均沿用注册值。`-NoShortcuts` 可跳过桌面及登录快捷方式的创建；它与 `-NoStart` 一起适合隔离验证。安装包不含个人配置、会话、状态或日志。

## 日常使用

双击桌面的“Codex 关机守卫”只会启动守卫并显示用量窗口，默认不开启自动关机。准备离开电脑时，再点击面板右下角开关，或右键托盘盾牌图标并勾选“任务完成后自动关机”。再次点击同一项即可取消，勾选状态与面板开关同步。

托盘菜单还提供：

- 管理活动任务
- 显示/隐藏用量面板
- 任务完成后自动关机（单一开关）
- 启动 Codex 时自动启动守卫
- 启动 Codex（使用当前代理）
- 守卫启动时自动启动 Codex
- 立即重新扫描
- 退出工具（右键托盘小图标即可完全退出后台守卫）

如果布防时没有任何运行中的主任务，工具只会等待，不会立刻关机。只有子代理时也不会满足“已观察到主任务”的条件。

## 一键代理启动 Codex

右键托盘盾牌图标 → **启动 Codex（使用当前代理）**。它会读取当前 Windows 用户已经启用的系统代理，核验已注册 OpenAI.Codex 桌面包与 OpenAI 签名，再只对新桌面进程及其子进程设置代理。由桌面自己启动官方执行器；不会独立启动 exec-server、修改系统代理、重置登录或终止正在运行的 Codex。

若 Codex 已在运行，只提示已运行，不重复启动或向现有进程注入代理。更换代理软件/端口后，先保存并从 Codex 应用菜单退出，再点本项。只切换 VPN 节点、代理协议/地址/端口不变时，无需重新启动。

可以勾选 **守卫启动时自动启动 Codex**，默认关闭。此设置保存在 `%LOCALAPPDATA%\CodexShutdownGuard\codex-launch-settings.json`，与自动关机布防、面板位置和原 config.json 分开。勾选只影响下次守卫启动；每次守卫启动只尝试一次，不会在用户退出 Codex 后反复重开。开机时若代理还未就绪，会明确提示未启动，可等代理开启后使用右键启动入口。

支持系统的单一明确代理地址及 http=/https= 分项地址；不会把仅有 SOCKS 地址但版本不明确的配置猜成 SOCKS5。PAC、未启用的系统代理、包含凭据或无法识别的配置会明确提示，不更改系统设置。端口检查只确认代理可达，不会把“已启动”宣称为 dot 已获授权或读取成功。

关闭自动启动勾选即可恢复守卫原有启动行为。原独立 PowerShell 启动文件仍可作为备选，菜单不依赖临时诊断目录。

## 随 Codex 启动守卫

勾选托盘菜单中的“启动 Codex 时自动启动守卫”后，一个隐藏的轻量检测器每 5 秒检查一次官方 Codex 桌面会话。发现新的应用会话时，它启动默认未布防的守卫；守卫已经运行时不创建第二个实例。在同一 Codex 会话中手动退出守卫后，检测器不会反复将它打开。退出再启动 Codex 后，检测器才会再次尝试。

此选项保存在 `%LOCALAPPDATA%\CodexShutdownGuard\codex-startup-settings.json`，默认关闭。开启时立即启动检测器，并创建独立的用户登录启动项 `Startup\CodexShutdownGuard.CodexStartup.lnk`；关闭时删除该启动项，检测器在下一次检查时自行退出。它只负责启动守卫，不会布防、启动 Codex、注入代理或改写官方 Codex 快捷方式。

“守卫启动时自动启动 Codex”由守卫启动 Codex；本选项由 Codex 启动守卫。两项设置互不代替，且都不会自动开启关机。由检测器启动的守卫跳过反向启动 Codex，避免两个选项同时开启时互相触发。原有 `Startup\CodexShutdownGuard.lnk` 是 Windows 登录时启动守卫的快捷方式，独立保留。

## 常驻用量面板

- 首次启动默认显示，并始终置顶；手动隐藏后会记住隐藏状态，下次开机启动不会自动弹出。
- 进度条代表 Codex 账户的“剩余额度”：绿色条会随着使用逐渐缩短；文字同时标出剩余与已用百分比。它不是单个对话的上下文长度。
- 标题会按 Codex 返回的额度窗口显示，例如“7 天额度”或“5 小时额度”。
- 额度标题右侧默认显示剩余与已用百分比；鼠标移入该文字时会切换显示重置时间，移出后恢复剩余用量。
- 面板显示当前任务条目数、实际阻止关机的条目数、已无视数量和自动关机状态。
- 点击状态文字或托盘中的“管理活动任务”，可以查看任务标题、项目目录、最后更新时间、回合 ID 和异常原因；勾选条目即表示无视，应用前会再次提示风险。
- 管理窗口每秒检查最新扫描快照，随每分钟任务扫描自动更新列表；刷新保留同一回合尚未应用的勾选，新回合不会继承旧选择。
- 管理窗口分别统计主任务、子代理和内部审批，并显示扫描时间。子代理优先使用记录中的任务路径末段和代理名，注明所属父任务；悬停可查看父线程、角色和完整代理路径。未记录名称时保留短 ID，不从提示词或回复中猜测名称。
- 顶部说明与统计按文字自动换行，窗口可调整大小和最大化，列表与列宽随窗口伸缩。
- 会话文件已经消失或长期不再更新的疑似失联任务仍会显示在清单中。主任务默认继续阻止关机，用户可明确勾选无视；子代理和内部审批显示“不阻塞”，无需手动排除。
- 面板右下角的 `○ 关闭` / `● 开启` 按钮是“本轮完成后关机”双态开关：点击关闭态进行布防，再次点击开启态会撤销关机并解除布防；它与托盘菜单状态同步。
- 可以直接拖动窗口；位置与显示/隐藏状态会保存在 `%LOCALAPPDATA%\CodexShutdownGuard\usage-panel-state.json`。
- 关闭面板只会隐藏它，不会退出守卫；双击托盘图标或勾选“显示用量面板”即可恢复。

Codex 通常在完成一次模型响应后写入新的用量快照。如果刚启动 Codex、尚无本轮数据，面板会暂时显示“等待 Codex 返回账户用量数据”。快照优先按照额度窗口的重置时间保持有效；只有缺少重置时间时，才使用 3 分钟兼容期限。

## 命令行

```powershell
# 启动托盘，默认未布防
CodexShutdownGuard.ps1 -Tray

# 启动并显示用量窗口，默认未布防
CodexShutdownGuard.ps1 -Show

# 布防；已有托盘实例时向它发送请求
CodexShutdownGuard.ps1 -Arm

# 撤销关机并解除布防
CodexShutdownGuard.ps1 -Disarm

# 输出 JSON 状态
CodexShutdownGuard.ps1 -Status

# 模拟完整状态机，绝不调用 shutdown.exe
CodexShutdownGuard.ps1 -Tray -DryRun
```

## 配置与日志

- 配置：已注册安装目录中的 `config.json`；新安装默认在 `%LOCALAPPDATA%\Programs\CodexShutdownGuard\config.json`
- 安装注册：`%LOCALAPPDATA%\CodexShutdownGuard\installation.json`，自定义 `StateRoot` 时注册位置仍固定
- 状态：`%LOCALAPPDATA%\CodexShutdownGuard\status.json`
- 当前会话无视列表：`%LOCALAPPDATA%\CodexShutdownGuard\ignored-tasks.json`
- 随 Codex 启动守卫：`%LOCALAPPDATA%\CodexShutdownGuard\codex-startup-settings.json`
- 日志：默认关闭；将 `logRetentionDays` 设为正整数时才会写入 `%LOCALAPPDATA%\CodexShutdownGuard\logs`

默认配置：

```json
{
  "pollSeconds": 60,
  "totalGraceSeconds": 180,
  "nativeShutdownSeconds": 120,
  "sessionStartSkewSeconds": 5,
  "normalDiscoverySeconds": 60,
  "countdownDiscoverySeconds": 60,
  "stableSamplesRequired": 3,
  "usageStaleSeconds": 180,
  "taskInactivitySeconds": 1800,
  "logRetentionDays": 0,
  "showUsagePanel": true,
  "usagePanelTopMost": true,
  "usagePanelOpacity": 0.94,
  "dryRun": false
}
```

用量快照优先按 Codex 返回的额度重置时间判断有效性：只要额度周期尚未重置，即使暂时没有新的任务事件，面板也会继续显示该快照。`usageStaleSeconds` 仅在快照缺少重置时间时作为兼容兜底，不再让正常的 7 天额度在 3 分钟后消失。

将 `dryRun` 改为 `true` 可长期观察工具判断是否准确，而不执行真实关机。

`taskInactivitySeconds` 控制“疑似失联”的显示阈值，默认 1800 秒。长期工具调用或审批等待也可能进入该分类。主任务仍阻止关机，子代理和内部审批不阻塞；记录重新更新后自动恢复，不会按超时结束任务。

将 `showUsagePanel` 改为 `false` 可让新安装默认隐藏面板；`usagePanelOpacity` 可在 `0.65` 到 `1.0` 之间调整。

## 验证

自动测试不会执行任何真实关机命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexShutdownGuard.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-CodexShutdownGuard.Repair.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexShutdownGuard.TaskIdentity.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexShutdownGuard.SubagentPolicy.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexShutdownGuard.StatusMetadata.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexShutdownGuard.StartupLifecycle.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-CodexShutdownGuard.TaskManagerLayout.ps1 -OutputDirectory "$env:TEMP\CodexGuardLayoutPreviews"
```

真正的 Windows 关机链路测试不包含在自动测试中。只有用户明确要求时，才应安排一次 30 秒关机并立即用 `shutdown.exe /a` 撤销。

## 卸载

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

从安装包或已安装目录运行卸载器即可；未指定 `-InstallRoot` 时按同一注册定位。卸载前核验产品目录、标记归属及状态目录边界，确认检测器和守卫均已停止，再删除本安装拥有的文件和指向本安装的快捷方式。只有注册仍指向本安装时才删除注册；未知文件使原目录保留，不递归清空目录。`StateRoot` 中的配置、任务无视列表、偏好和会话文件均保留，官方 Codex 快捷方式与代理设置不受影响。