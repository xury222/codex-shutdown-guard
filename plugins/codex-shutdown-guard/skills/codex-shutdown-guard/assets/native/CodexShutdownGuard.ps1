[CmdletBinding()]
param(
    [switch]$Tray,
    [switch]$Show,
    [switch]$Arm,
    [switch]$Disarm,
    [switch]$Status,
    [switch]$DryRun,
    [switch]$FromCodexStartup,
    [switch]$Stop,
    [string]$ConfigPath,
    [string]$CodexHome,
    [string]$StateRoot,
    [string]$UsagePanelScreenshotPath,
    [switch]$UsagePanelScreenshotHover,
    [string]$TaskManagerScreenshotPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.CodexLaunch.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.CodexStartup.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.Installation.psm1') -Force

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-IgnoredTaskState {
    $state = [pscustomobject]@{
        AppSessionKey = ''
        TurnIds = @()
    }
    if (-not (Test-Path -LiteralPath $script:IgnoredTaskStatePath -PathType Leaf)) {
        return $state
    }

    try {
        $payload = Get-Content -LiteralPath $script:IgnoredTaskStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $turnIds = New-Object System.Collections.Generic.List[string]
        foreach ($turnId in @($payload.turnIds)) {
            $value = [string]$turnId
            if ($value -match '^[0-9a-fA-F-]{36}$') {
                $turnIds.Add($value)
            }
        }
        return [pscustomobject]@{
            AppSessionKey = [string]$payload.appSessionKey
            TurnIds = $turnIds.ToArray()
        }
    }
    catch {
        Write-GuardLog -Level 'WARN' -Message "Ignored task state could not be read: $($_.Exception.Message)"
        return $state
    }
}

function Write-IgnoredTaskState {
    $payload = [ordered]@{
        schemaVersion = 1
        updatedAtUtc = [datetime]::UtcNow.ToString('o')
        appSessionKey = [string]$script:IgnoredAppSessionKey
        turnIds = @($script:IgnoredTurnIds.Keys | Sort-Object)
    }
    Write-Utf8NoBom -Path $script:IgnoredTaskStatePath -Text ($payload | ConvertTo-Json -Depth 3)
}

function Sync-IgnoredTaskSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionKey
    )

    if ($script:IgnoredAppSessionKey -eq $SessionKey) {
        return
    }
    $script:IgnoredAppSessionKey = $SessionKey
    $script:IgnoredTurnIds = @{}
    Write-IgnoredTaskState
}

function Set-IgnoredTurnIds {
    param(
        [string[]]$TurnIds = @()
    )

    $next = @{}
    foreach ($turnId in @($TurnIds)) {
        $value = [string]$turnId
        if ($value -match '^[0-9a-fA-F-]{36}$') {
            $next[$value] = $true
        }
    }
    $script:IgnoredTurnIds = $next
    Write-IgnoredTaskState
}

function Remove-CompletedIgnoredTurns {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    # Absence during partial replay is not evidence that an ignored turn ended.
    if ($null -ne $Snapshot.PSObject.Properties['HasPendingReads'] -and $Snapshot.HasPendingReads) { return }
    $current = @{}
    foreach ($entry in @($Snapshot.TaskEntries)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.TurnId)) {
            $current[[string]$entry.TurnId] = $true
        }
    }
    $changed = $false
    foreach ($turnId in @($script:IgnoredTurnIds.Keys)) {
        if (-not $current.ContainsKey($turnId)) {
            [void]$script:IgnoredTurnIds.Remove($turnId)
            $changed = $true
        }
    }
    if ($changed) {
        Write-IgnoredTaskState
    }
}

function Read-CodexThreadTitles {
    $titles = @{}
    $indexPath = Join-Path $script:ResolvedCodexHome 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return $titles
    }

    $stream = $null
    $reader = $null
    try {
        $stream = New-Object IO.FileStream(
            $indexPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 8192)
        while (($line = $reader.ReadLine()) -ne $null) {
            $entry = ConvertFrom-CodexGuardThreadTitleLine -Line $line
            if ($null -ne $entry) { $titles[$entry.ThreadId] = $entry.Title }
        }
    }
    catch {
        Write-GuardLog -Level 'WARN' -Message "Codex task titles could not be read: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    return $titles
}

function Get-CodexTaskTitle {
    param(
        [string]$ThreadId,
        [object]$Entry
    )

    if ($null -ne $Entry) {
        return Get-CodexGuardTaskDisplayTitle -Entry $Entry -ThreadTitles $script:ThreadTitles
    }
    if (-not [string]::IsNullOrWhiteSpace($ThreadId) -and $script:ThreadTitles.ContainsKey($ThreadId)) {
        return [string]$script:ThreadTitles[$ThreadId]
    }
    if (-not [string]::IsNullOrWhiteSpace($ThreadId)) {
        return "任务 $ThreadId"
    }
    return '无法识别的任务状态'
}

function Get-CodexTaskMetadataValue {
    param([object]$Entry, [string]$Name)
    if ($null -eq $Entry) { return '' }
    $property = $Entry.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Get-StablePathHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16)
    }
    finally {
        $sha.Dispose()
    }
}

function Read-GuardConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SelectedPath
    )

    $defaultPath = Join-Path $PSScriptRoot 'config.default.json'
    $defaultConfig = Get-Content -LiteralPath $defaultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $config = [ordered]@{
        pollSeconds = [int]$defaultConfig.pollSeconds
        totalGraceSeconds = [int]$defaultConfig.totalGraceSeconds
        nativeShutdownSeconds = [int]$defaultConfig.nativeShutdownSeconds
        sessionStartSkewSeconds = [int]$defaultConfig.sessionStartSkewSeconds
        normalDiscoverySeconds = [int]$defaultConfig.normalDiscoverySeconds
        countdownDiscoverySeconds = [int]$defaultConfig.countdownDiscoverySeconds
        stableSamplesRequired = [int]$defaultConfig.stableSamplesRequired
        usageStaleSeconds = [int]$defaultConfig.usageStaleSeconds
        taskInactivitySeconds = [int]$defaultConfig.taskInactivitySeconds
        logRetentionDays = [int]$defaultConfig.logRetentionDays
        showUsagePanel = [bool]$defaultConfig.showUsagePanel
        usagePanelTopMost = [bool]$defaultConfig.usagePanelTopMost
        usagePanelOpacity = [double]$defaultConfig.usagePanelOpacity
        dryRun = [bool]$defaultConfig.dryRun
    }

    if (Test-Path -LiteralPath $SelectedPath -PathType Leaf) {
        $userConfig = Get-Content -LiteralPath $SelectedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @($config.Keys)) {
            if ($null -ne $userConfig.PSObject.Properties[$name]) {
                $config[$name] = $userConfig.$name
            }
        }
    }

    $config.pollSeconds = [Math]::Max(1, [Math]::Min(3600, [int]$config.pollSeconds))
    $config.totalGraceSeconds = [Math]::Max(60, [int]$config.totalGraceSeconds)
    $config.nativeShutdownSeconds = [Math]::Max(10, [Math]::Min(120, [int]$config.nativeShutdownSeconds))
    if ($config.totalGraceSeconds -le $config.nativeShutdownSeconds) {
        throw 'totalGraceSeconds must be greater than nativeShutdownSeconds.'
    }
    $config.sessionStartSkewSeconds = [Math]::Max(0, [Math]::Min(30, [int]$config.sessionStartSkewSeconds))
    $config.normalDiscoverySeconds = [Math]::Max(1, [Math]::Min(3600, [int]$config.normalDiscoverySeconds))
    $config.countdownDiscoverySeconds = [Math]::Max(1, [Math]::Min(3600, [int]$config.countdownDiscoverySeconds))
    $config.stableSamplesRequired = [Math]::Max(1, [Math]::Min(10, [int]$config.stableSamplesRequired))
    $config.usageStaleSeconds = [Math]::Max(60, [Math]::Min(86400, [int]$config.usageStaleSeconds))
    $config.taskInactivitySeconds = [Math]::Max(60, [Math]::Min(604800, [int]$config.taskInactivitySeconds))
    $config.logRetentionDays = [Math]::Max(0, [Math]::Min(90, [int]$config.logRetentionDays))
    $config.showUsagePanel = [bool]$config.showUsagePanel
    $config.usagePanelTopMost = [bool]$config.usagePanelTopMost
    $config.usagePanelOpacity = [Math]::Max(0.65, [Math]::Min(1.0, [double]$config.usagePanelOpacity))
    $config.dryRun = [bool]$config.dryRun
    return [pscustomobject]$config
}

function Request-CodexProxyLaunch {
    param([switch]$Automatic)
    try {
        $result = Start-CodexGuardDesktopWithProxy
        if (-not $Automatic -or $result.Status -eq 'Started') {
            Show-GuardBalloon -Title 'Codex 启动' -Text $result.Message
        }
    }
    catch {
        Show-GuardBalloon -Title 'Codex 未启动' -Text $_.Exception.Message -Icon 'Warning'
    }
}

function Set-GuardCodexAutoStart {
    param([bool]$Enabled)
    try {
        Set-CodexGuardAutoStartSetting -Path $script:CodexLaunchSettingsPath -Enabled $Enabled
        $script:AutoStartCodexMenuItem.Checked = $Enabled
        $message = if ($Enabled) { '已启用：下次守卫启动时，用当前系统代理启动 Codex。请先开启代理软件。' } else { '已关闭随守卫启动 Codex；右键启动入口仍可使用。' }
        Show-GuardBalloon -Title 'Codex 启动设置' -Text $message
    }
    catch {
        Show-GuardBalloon -Title '启动设置未保存' -Text $_.Exception.Message -Icon 'Warning'
    }
}

function Set-GuardStartWithCodex {
    param([bool]$Enabled)
    try {
        $result = Set-CodexGuardStartWithCodex -Enabled $Enabled -SettingsPath $script:CodexStartupSettingsPath -NativeRoot $PSScriptRoot -StateRoot $script:StateRoot
        $script:AutoStartGuardMenuItem.Checked = [bool]$result.Enabled
        $message = if ($result.Enabled) { '已启用：启动 Codex 时自动启动守卫。仅启动监控，不会自动开启关机。' }
            else { '已关闭随 Codex 启动守卫；桌面和托盘入口仍可使用。' }
        Show-GuardBalloon -Title '守卫启动设置' -Text $message
    }
    catch {
        Show-GuardBalloon -Title '启动设置未保存' -Text $_.Exception.Message -Icon 'Warning'
    }
}

function Write-GuardLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if ($null -ne $script:Config -and [int]$script:Config.logRetentionDays -le 0) {
        return
    }

    try {
        $line = '{0:o} [{1}] {2}' -f [datetime]::UtcNow, $Level, $Message
        [IO.File]::AppendAllText(
            $script:LogPath,
            $line + [Environment]::NewLine,
            (New-Object Text.UTF8Encoding($false))
        )
    }
    catch {
        # Logging must never make the guard less safe.
    }
}

function Remove-ExpiredGuardLogs {
    try {
        $cutoff = [datetime]::UtcNow.AddDays(-1 * $script:Config.logRetentionDays)
        foreach ($file in @(Get-ChildItem -LiteralPath $script:LogsRoot -Filter 'guard-*.log' -File -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTimeUtc -lt $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-GuardLog -Level 'WARN' -Message "Log retention cleanup failed: $($_.Exception.Message)"
    }
}

function Write-ControlRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Show', 'Arm', 'Disarm', 'Rescan', 'Stop')]
        [string]$Command
    )

    [void](New-Item -ItemType Directory -Path $script:ControlRoot -Force)
    $payload = [ordered]@{
        command = $Command
        requestedAtUtc = [datetime]::UtcNow.ToString('o')
        processId = $PID
    } | ConvertTo-Json -Compress
    $name = '{0:D20}-{1}.json' -f [datetime]::UtcNow.Ticks, [guid]::NewGuid().ToString('N')
    $target = Join-Path $script:ControlRoot $name
    $temporary = $target + '.tmp'
    Write-Utf8NoBom -Path $temporary -Text $payload
    Move-Item -LiteralPath $temporary -Destination $target -Force
}

function Read-ControlRequests {
    $commands = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $script:ControlRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object Name
    )) {
        try {
            $request = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($request.command -in @('Show', 'Arm', 'Disarm', 'Rescan', 'Stop')) {
                $commands.Add([string]$request.command)
            }
        }
        catch {
            Write-GuardLog -Level 'WARN' -Message "Ignored invalid control request $($file.Name)."
        }
        finally {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $commands.ToArray()
}

function Get-PhaseLabel {
    param([string]$Phase)

    switch ($Phase) {
        'Disarmed' { return '未布防' }
        'WaitingFirstTask' { return '已布防，等待任务开始' }
        'WaitingTasks' { return '等待 Codex 任务完成' }
        'ConfirmingIdle' { return '确认空闲状态' }
        'GraceCountdown' { return '稳定空闲缓冲' }
        'NativeCountdown' { return 'Windows 关机倒计时' }
        'PausedAppUnavailable' { return '已暂停：Codex 状态不可用' }
        'PausedUnknownState' { return '已暂停：存在未知任务状态' }
        'DryRunComplete' { return 'DryRun 已完成' }
        'Error' { return '错误：需要重新布防' }
        default { return $Phase }
    }
}

function Get-RemainingSeconds {
    param(
        [object]$Runtime,
        [datetime]$NowUtc
    )

    if ($Runtime.Phase -eq 'GraceCountdown' -and $null -ne $Runtime.GraceDeadlineUtc) {
        $grace = [Math]::Max(0, [Math]::Ceiling(($Runtime.GraceDeadlineUtc - $NowUtc).TotalSeconds))
        return [int]($grace + $script:Config.nativeShutdownSeconds)
    }
    if ($Runtime.Phase -eq 'NativeCountdown' -and $null -ne $Runtime.NativeDeadlineUtc) {
        return [int][Math]::Max(0, [Math]::Ceiling(($Runtime.NativeDeadlineUtc - $NowUtc).TotalSeconds))
    }
    return $null
}

function Get-UsageFreshness {
    param(
        [object]$Usage,
        [datetime]$NowUtc = [datetime]::UtcNow
    )

    return Get-CodexGuardUsageValidity `
        -Usage $Usage `
        -NowUtc $NowUtc `
        -FallbackMaxAgeSeconds ([int]$script:Config.usageStaleSeconds)
}

function New-StatusPayload {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Running,

        [Parameter(Mandatory = $true)]
        [object]$Runtime,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [bool]$AppAvailable,

        [string]$AppReason = ''
    )

    $now = [datetime]::UtcNow
    $usageFreshness = Get-UsageFreshness -Usage $Snapshot.Usage -NowUtc $now
    $usagePayload = $null
    if ($Snapshot.UsageAvailable -and $null -ne $Snapshot.Usage) {
        $usage = $Snapshot.Usage
        $usagePayload = [ordered]@{
            updatedAtUtc = $usage.UpdatedAtUtc.ToString('o')
            threadId = [string]$usage.ThreadId
            limitId = [string]$usage.LimitId
            limitName = [string]$usage.LimitName
            planType = [string]$usage.PlanType
            primary = if ($null -ne $usage.Primary) {
                [ordered]@{
                    usedPercent = [double]$usage.Primary.UsedPercent
                    windowMinutes = [int]$usage.Primary.WindowMinutes
                    resetsAtUtc = if ($null -ne $usage.Primary.ResetsAtUtc) {
                        $usage.Primary.ResetsAtUtc.ToString('o')
                    }
                    else {
                        $null
                    }
                    valid = [bool]$usageFreshness.PrimaryValid
                }
            }
            else {
                $null
            }
            secondary = if ($null -ne $usage.Secondary) {
                [ordered]@{
                    usedPercent = [double]$usage.Secondary.UsedPercent
                    windowMinutes = [int]$usage.Secondary.WindowMinutes
                    resetsAtUtc = if ($null -ne $usage.Secondary.ResetsAtUtc) {
                        $usage.Secondary.ResetsAtUtc.ToString('o')
                    }
                    else {
                        $null
                    }
                    valid = [bool]$usageFreshness.SecondaryValid
                }
            }
            else {
                $null
            }
            modelContextWindow = $usage.ModelContextWindow
            lastInputTokens = $usage.LastInputTokens
            lastTotalTokens = $usage.LastTotalTokens
            cumulativeTokens = $usage.CumulativeTokens
        }
    }

    $taskPayload = @(
        foreach ($entry in @($Snapshot.TaskEntries)) {
            [ordered]@{
                kind = [string]$entry.Kind
                state = [string]$entry.State
                title = Get-CodexTaskTitle -ThreadId ([string]$entry.ThreadId) -Entry $entry
                turnId = [string]$entry.TurnId
                threadId = [string]$entry.ThreadId
                taskType = Get-CodexTaskMetadataValue -Entry $entry -Name 'TaskType'
                parentThreadId = Get-CodexTaskMetadataValue -Entry $entry -Name 'ParentThreadId'
                parentTitle = if ([string]::IsNullOrWhiteSpace((Get-CodexTaskMetadataValue -Entry $entry -Name 'ParentThreadId'))) { '' }
                    else { Get-CodexTaskTitle -ThreadId (Get-CodexTaskMetadataValue -Entry $entry -Name 'ParentThreadId') }
                agentName = Get-CodexTaskMetadataValue -Entry $entry -Name 'AgentName'
                agentRole = Get-CodexTaskMetadataValue -Entry $entry -Name 'AgentRole'
                agentPath = Get-CodexTaskMetadataValue -Entry $entry -Name 'AgentPath'
                threadSource = Get-CodexTaskMetadataValue -Entry $entry -Name 'ThreadSource'
                cwd = [string]$entry.Cwd
                startedAtUtc = if ($null -ne $entry.StartedAtUtc) {
                    ([datetime]$entry.StartedAtUtc).ToUniversalTime().ToString('o')
                }
                else {
                    $null
                }
                lastUpdatedAtUtc = if ($null -ne $entry.LastUpdatedAtUtc) {
                    ([datetime]$entry.LastUpdatedAtUtc).ToUniversalTime().ToString('o')
                }
                else {
                    $null
                }
                path = [string]$entry.Path
                reason = [string]$entry.Reason
                stateLabel = Get-CodexGuardTaskStateLabel -Entry $entry
                ignored = [bool]$entry.IsIgnored
                blocksShutdown = [bool]$entry.BlocksShutdown
            }
        }
    )

    return [ordered]@{
        schemaVersion = 7
        updatedAtUtc = $now.ToString('o')
        running = $Running
        armed = [bool]$Runtime.Armed
        startGuardWithCodexEnabled = if (Test-Path variable:script:CodexStartupSettingsPath) {
            Get-CodexGuardStartWithCodexSetting -Path $script:CodexStartupSettingsPath
        } else { $false }
        phase = [string]$Runtime.Phase
        phaseLabel = Get-PhaseLabel -Phase $Runtime.Phase
        activeCount = [int]$Snapshot.ActiveCount
        observedActiveCount = [int]$Snapshot.ObservedActiveCount
        activeTurnIds = @($Snapshot.ActiveTurns | ForEach-Object { $_.TurnId })
        activeThreadIds = @(
            $Snapshot.ActiveTurns |
                ForEach-Object { $_.ThreadId } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        taskCount = [int]$Snapshot.TaskCount
        blockingTaskCount = [int]($Snapshot.ActiveCount + $Snapshot.UnknownCount)
        ignoredCount = [int]$Snapshot.IgnoredCount
        readingHistory = ($null -ne $Snapshot.PSObject.Properties['HasPendingReads'] -and [bool]$Snapshot.HasPendingReads)
        historyBytesRemaining = if ($null -ne $Snapshot.PSObject.Properties['HistoryBytesRemaining']) { [long]$Snapshot.HistoryBytesRemaining } else { 0 }
        ignoredTurnIds = @($Snapshot.IgnoredTurnIds)
        taskEntries = $taskPayload
        unknownCount = [int]$Snapshot.UnknownCount
        observedUnknownCount = [int]$Snapshot.ObservedUnknownCount
        unknownItems = @(
            $Snapshot.UnknownItems |
                Select-Object Kind, Id, TurnId, ThreadId, ParentThreadId, TaskType, AgentName, AgentRole, AgentPath, Cwd, Path, Reason, IsIgnored
        )
        allUnknownItems = @(
            $Snapshot.AllUnknownItems |
                Select-Object Kind, Id, TurnId, ThreadId, ParentThreadId, TaskType, AgentName, AgentRole, AgentPath, Cwd, Path, Reason, IsIgnored
        )
        seenActiveSinceArm = [bool]$Runtime.SeenActive
        stableIdleSamples = [int]$Runtime.StableIdleSamples
        stableIdleSamplesRequired = [int]$script:Config.stableSamplesRequired
        remainingSeconds = Get-RemainingSeconds -Runtime $Runtime -NowUtc $now
        dryRun = [bool]$Runtime.DryRun
        appAvailable = $AppAvailable
        appReason = $AppReason
        appSessionStartUtc = if ($null -ne $Runtime.AppSessionStartUtc) {
            $Runtime.AppSessionStartUtc.ToString('o')
        }
        else {
            $null
        }
        codexHome = $script:ResolvedCodexHome
        usageAvailable = [bool]$Snapshot.UsageAvailable
        usageValid = [bool]$usageFreshness.Valid
        usageExpired = [bool]$usageFreshness.Expired
        usageStale = [bool]$usageFreshness.Stale
        usageAgeSeconds = $usageFreshness.AgeSeconds
        usageValidityReason = [string]$usageFreshness.Reason
        usage = $usagePayload
        usageError = [string]$Snapshot.UsageError
        lastError = [string]$Runtime.LastError
    }
}

function Write-GuardStatus {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Running,

        [Parameter(Mandatory = $true)]
        [object]$Runtime,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [bool]$AppAvailable,

        [string]$AppReason = ''
    )

    $payload = New-StatusPayload -Running $Running -Runtime $Runtime -Snapshot $Snapshot -AppAvailable $AppAvailable -AppReason $AppReason
    Write-Utf8NoBom -Path $script:StatusPath -Text ($payload | ConvertTo-Json -Depth 6)
    return $payload
}

function Read-ExistingStatus {
    if (Test-Path -LiteralPath $script:StatusPath -PathType Leaf) {
        try {
            return Get-Content -LiteralPath $script:StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            return $null
        }
    }
    return $null
}

function Invoke-NativeShutdownSchedule {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Seconds
    )

    if ($script:Runtime.DryRun) {
        Write-GuardLog -Message "DryRun: would schedule Windows shutdown in $Seconds seconds."
        return 0
    }

    $shutdownExe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    $arguments = "/s /t $Seconds /c `"Codex tasks completed. Cancel from Codex Shutdown Guard if needed.`""
    $process = Start-Process -FilePath $shutdownExe -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    Write-GuardLog -Message "shutdown.exe schedule exit code: $($process.ExitCode)"
    return [int]$process.ExitCode
}

function Invoke-NativeShutdownAbort {
    if ($script:Runtime.DryRun) {
        Write-GuardLog -Message 'DryRun: would abort a guard-owned Windows shutdown.'
        return 0
    }

    $shutdownExe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    $process = Start-Process -FilePath $shutdownExe -ArgumentList '/a' -WindowStyle Hidden -Wait -PassThru
    Write-GuardLog -Message "shutdown.exe abort exit code: $($process.ExitCode)"
    return [int]$process.ExitCode
}

function Show-GuardBalloon {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Text,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Icon = 'Info'
    )

    if ($null -eq $script:NotifyIcon) {
        return
    }
    $toolTipIcon = [Windows.Forms.ToolTipIcon]::$Icon
    $script:NotifyIcon.ShowBalloonTip(6000, $Title, $Text, $toolTipIcon)
}

function Read-UsagePanelState {
    $state = [ordered]@{
        visible = [bool]$script:Config.showUsagePanel
        hasPosition = $false
        x = 0
        y = 0
    }

    if (Test-Path -LiteralPath $script:UsagePanelStatePath -PathType Leaf) {
        try {
            $stored = Get-Content -LiteralPath $script:UsagePanelStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $stored.PSObject.Properties['visible']) {
                $state.visible = [bool]$stored.visible
            }
            if (
                $null -ne $stored.PSObject.Properties['x'] -and
                $null -ne $stored.PSObject.Properties['y']
            ) {
                $state.hasPosition = $true
                $state.x = [int]$stored.x
                $state.y = [int]$stored.y
            }
        }
        catch {
            Write-GuardLog -Level 'WARN' -Message "Unable to read usage panel state: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]$state
}

function Write-UsagePanelState {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Visible
    )

    try {
        $x = 0
        $y = 0
        $hasPosition = $false
        if (
            $null -ne $script:UsageForm -and
            -not $script:UsageForm.IsDisposed
        ) {
            $x = [int]$script:UsageForm.Left
            $y = [int]$script:UsageForm.Top
            $hasPosition = $true
        }
        elseif ($null -ne $script:UsagePanelState) {
            $x = [int]$script:UsagePanelState.x
            $y = [int]$script:UsagePanelState.y
            $hasPosition = [bool]$script:UsagePanelState.hasPosition
        }

        $payload = [ordered]@{
            visible = $Visible
            x = $x
            y = $y
            hasPosition = $hasPosition
            updatedAtUtc = [datetime]::UtcNow.ToString('o')
        } | ConvertTo-Json
        Write-Utf8NoBom -Path $script:UsagePanelStatePath -Text $payload

        $script:UsagePanelState.visible = $Visible
        $script:UsagePanelState.x = $x
        $script:UsagePanelState.y = $y
        $script:UsagePanelState.hasPosition = $hasPosition
    }
    catch {
        Write-GuardLog -Level 'WARN' -Message "Unable to save usage panel state: $($_.Exception.Message)"
    }
}

function Get-UsageWindowLabel {
    param([int]$WindowMinutes)

    if ($WindowMinutes -eq 10080) {
        return '7 天额度'
    }
    if ($WindowMinutes -ge 1440 -and ($WindowMinutes % 1440) -eq 0) {
        return ('{0} 天额度' -f [int]($WindowMinutes / 1440))
    }
    if ($WindowMinutes -ge 60 -and ($WindowMinutes % 60) -eq 0) {
        return ('{0} 小时额度' -f [int]($WindowMinutes / 60))
    }
    return ('{0} 分钟额度' -f $WindowMinutes)
}

function Initialize-UsagePanelTypes {
    if ($null -ne ('CodexShutdownGuard.UsagePanelForm' -as [type])) {
        return
    }

    $source = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CodexShutdownGuard
{
    internal static class UiDrawing
    {
        internal static GraphicsPath RoundedRectangle(RectangleF bounds, float radius)
        {
            float diameter = Math.Max(1f, radius * 2f);
            GraphicsPath path = new GraphicsPath();
            path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180f, 90f);
            path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270f, 90f);
            path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0f, 90f);
            path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90f, 90f);
            path.CloseFigure();
            return path;
        }
    }

    public sealed class UsagePanelForm : Form
    {
        public UsagePanelForm()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams parameters = base.CreateParams;
                parameters.ClassStyle |= 0x00020000;
                return parameters;
            }
        }

        protected override void OnResize(EventArgs eventArgs)
        {
            base.OnResize(eventArgs);
            if (Width <= 0 || Height <= 0)
            {
                return;
            }
            using (GraphicsPath path = UiDrawing.RoundedRectangle(new RectangleF(0f, 0f, Width, Height), 9f))
            {
                Region oldRegion = Region;
                Region = new Region(path);
                if (oldRegion != null)
                {
                    oldRegion.Dispose();
                }
            }
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            base.OnPaint(eventArgs);
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = UiDrawing.RoundedRectangle(new RectangleF(0.5f, 0.5f, Width - 1f, Height - 1f), 9f))
            using (Pen pen = new Pen(Color.FromArgb(205, 210, 218), 1f))
            {
                eventArgs.Graphics.DrawPath(pen, path);
            }
        }
    }

    public sealed class UsageProgressBar : Control
    {
        private float value;

        public UsageProgressBar()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            TrackColor = Color.FromArgb(229, 233, 239);
            FillColor = Color.FromArgb(53, 165, 107);
            BorderColor = Color.FromArgb(201, 207, 216);
            value = 0f;
        }

        public float Value
        {
            get { return value; }
            set
            {
                this.value = Math.Max(0f, Math.Min(100f, value));
                Invalidate();
            }
        }

        public Color TrackColor { get; set; }
        public Color FillColor { get; set; }
        public Color BorderColor { get; set; }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            RectangleF bounds = new RectangleF(0.5f, 0.5f, Math.Max(1f, Width - 1f), Math.Max(1f, Height - 1f));
            float radius = Math.Min(bounds.Height / 2f, 6f);
            using (GraphicsPath path = UiDrawing.RoundedRectangle(bounds, radius))
            using (SolidBrush trackBrush = new SolidBrush(TrackColor))
            {
                eventArgs.Graphics.FillPath(trackBrush, path);
                if (value > 0f)
                {
                    GraphicsState state = eventArgs.Graphics.Save();
                    eventArgs.Graphics.SetClip(path);
                    using (SolidBrush fillBrush = new SolidBrush(FillColor))
                    {
                        eventArgs.Graphics.FillRectangle(fillBrush, 0f, 0f, Width * value / 100f, Height);
                    }
                    eventArgs.Graphics.Restore(state);
                }
                using (Pen pen = new Pen(BorderColor, 1f))
                {
                    eventArgs.Graphics.DrawPath(pen, path);
                }
            }
        }
    }

    public sealed class UsageToggle : CheckBox
    {
        public UsageToggle()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            AutoCheck = false;
            Cursor = Cursors.Hand;
            Font = new Font("Microsoft YaHei UI", 9f, FontStyle.Bold);
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            Color surface = Parent != null ? Parent.BackColor : BackColor;
            eventArgs.Graphics.Clear(surface);
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            RectangleF bounds = new RectangleF(0.5f, 0.5f, Width - 1f, Height - 1f);
            Color background = Checked ? Color.FromArgb(244, 183, 67) : Color.FromArgb(240, 243, 247);
            Color border = Checked ? Color.FromArgb(205, 142, 28) : Color.FromArgb(195, 201, 210);
            Color foreground = Checked ? Color.FromArgb(53, 40, 15) : Color.FromArgb(71, 77, 87);
            using (GraphicsPath path = UiDrawing.RoundedRectangle(bounds, bounds.Height / 2f))
            using (SolidBrush brush = new SolidBrush(background))
            using (Pen pen = new Pen(border, 1f))
            {
                eventArgs.Graphics.FillPath(brush, path);
                eventArgs.Graphics.DrawPath(pen, path);
            }

            float dotSize = 8f;
            float dotX = 13f;
            float dotY = (Height - dotSize) / 2f;
            using (SolidBrush dotBrush = new SolidBrush(Checked ? Color.FromArgb(104, 69, 8) : Color.FromArgb(139, 146, 157)))
            {
                eventArgs.Graphics.FillEllipse(dotBrush, dotX, dotY, dotSize, dotSize);
            }
            Rectangle textBounds = new Rectangle(22, 0, Width - 27, Height);
            TextRenderer.DrawText(
                eventArgs.Graphics,
                Checked ? "开启" : "关闭",
                Font,
                textBounds,
                foreground,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine
            );
        }
    }

    public static class WindowDrag
    {
        [DllImport("user32.dll")]
        private static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr window, int message, int wParam, int lParam);

        public static void Begin(Form form)
        {
            ReleaseCapture();
            SendMessage(form.Handle, 0x00A1, 0x0002, 0);
        }
    }
}
'@

    Add-Type -TypeDefinition $source -ReferencedAssemblies @(
        'System.Windows.Forms',
        'System.Drawing'
    )
}

function New-UsageBarRow {
    param(
        [Parameter(Mandatory = $true)]
        [Windows.Forms.Control]$Parent,

        [Parameter(Mandatory = $true)]
        [int]$Top
    )

    $nameLabel = New-Object Windows.Forms.Label
    $nameLabel.Location = New-Object Drawing.Point(16, $Top)
    $nameLabel.Size = New-Object Drawing.Size(70, 20)
    $nameLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
    $nameLabel.ForeColor = [Drawing.Color]::FromArgb(42, 46, 53)

    $valueLabel = New-Object Windows.Forms.Label
    $valueLabel.Location = New-Object Drawing.Point(86, $Top)
    $valueLabel.Size = New-Object Drawing.Size(278, 20)
    $valueLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
    $valueLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $valueLabel.ForeColor = [Drawing.Color]::FromArgb(43, 103, 75)
    $valueLabel.Cursor = [Windows.Forms.Cursors]::Hand

    $bar = New-Object CodexShutdownGuard.UsageProgressBar
    $bar.Location = New-Object Drawing.Point(16, ($Top + 25))
    $bar.Size = New-Object Drawing.Size(348, 12)

    $Parent.Controls.Add($nameLabel)
    $Parent.Controls.Add($valueLabel)
    $Parent.Controls.Add($bar)

    $row = [pscustomobject]@{
        NameLabel = $nameLabel
        ValueLabel = $valueLabel
        Bar = $bar
        DefaultValueText = ''
        ResetValueText = ''
        IsHovering = $false
    }
    $valueLabel.Add_MouseEnter({
        $row.IsHovering = $true
        $row.ValueLabel.Text = $row.ResetValueText
        $row.ValueLabel.ForeColor = [Drawing.Color]::FromArgb(100, 107, 118)
    }.GetNewClosure())
    $valueLabel.Add_MouseLeave({
        $row.IsHovering = $false
        $row.ValueLabel.Text = $row.DefaultValueText
        $row.ValueLabel.ForeColor = [Drawing.Color]::FromArgb(43, 103, 75)
    }.GetNewClosure())
    return $row
}

function Set-UsageBarRow {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,

        [object]$Window
    )

    $visible = ($null -ne $Window)
    foreach ($control in @($Row.NameLabel, $Row.ValueLabel, $Row.Bar)) {
        $control.Visible = $visible
    }
    if (-not $visible) {
        return
    }

    $usedPercent = [Math]::Max(0.0, [Math]::Min(100.0, [double]$Window.UsedPercent))
    $remainingPercent = 100.0 - $usedPercent
    $Row.NameLabel.Text = Get-UsageWindowLabel -WindowMinutes ([int]$Window.WindowMinutes)
    $Row.DefaultValueText = ('剩余 {0:0.#}%（已用 {1:0.#}%）' -f $remainingPercent, $usedPercent)
    $Row.Bar.Value = [single]$remainingPercent
    if ($remainingPercent -le 10) {
        $Row.Bar.FillColor = [Drawing.Color]::FromArgb(207, 74, 74)
    }
    elseif ($remainingPercent -le 30) {
        $Row.Bar.FillColor = [Drawing.Color]::FromArgb(218, 151, 40)
    }
    else {
        $Row.Bar.FillColor = [Drawing.Color]::FromArgb(53, 165, 107)
    }

    if ($null -ne $Window.ResetsAtUtc) {
        $localReset = $Window.ResetsAtUtc.ToLocalTime()
        $Row.ResetValueText = ('重置  {0:MM月dd日 HH:mm}' -f $localReset)
    }
    else {
        $Row.ResetValueText = '重置时间待刷新'
    }
    if ($Row.IsHovering) {
        $Row.ValueLabel.Text = $Row.ResetValueText
        $Row.ValueLabel.ForeColor = [Drawing.Color]::FromArgb(100, 107, 118)
    }
    else {
        $Row.ValueLabel.Text = $Row.DefaultValueText
        $Row.ValueLabel.ForeColor = [Drawing.Color]::FromArgb(43, 103, 75)
    }
}

function Update-CodexTaskManagerView {
    $view = $script:TaskManagerView
    if ($null -eq $view -or $view.Dialog.IsDisposed) { return }
    if ($script:StopRequested) { $view.Dialog.Close(); return }
    if ([object]::ReferenceEquals($view.LastSnapshot, $script:LastSnapshot) -and
        [object]::ReferenceEquals($view.LastTitles, $script:ThreadTitles)) { return }
    $snapshot = $script:LastSnapshot
    $selected = @{}
    foreach ($item in $view.List.SelectedItems) { $selected[[string]$item.Tag] = $true }
    $topId = if ($null -ne $view.List.TopItem) { [string]$view.List.TopItem.Tag } else { '' }
    $rows = @(Get-CodexGuardTaskManagerRows -Snapshot $snapshot -ThreadTitles $script:ThreadTitles -PendingChecks $view.PendingChecks)
    $view.Refreshing = $true
    $view.List.BeginUpdate()
    try {
        $view.List.Items.Clear()
        foreach ($row in $rows) {
            $item = New-Object Windows.Forms.ListViewItem([string]$row.Title)
            [void]$item.SubItems.Add([string]$row.StateText)
            [void]$item.SubItems.Add([string]$row.Cwd)
            [void]$item.SubItems.Add([string]$row.Updated)
            [void]$item.SubItems.Add([string]$row.TurnId)
            $item.Tag = [string]$row.TurnId
            $item.ToolTipText = [string]$row.Tooltip
            $item.Checked = [bool]$row.Checked
            $item.ForeColor = switch ($row.Tone) {
                'Warning' { [Drawing.Color]::FromArgb(178, 92, 35) }
                'Error' { [Drawing.Color]::FromArgb(178, 62, 62) }
                'Muted' { [Drawing.Color]::FromArgb(100, 107, 118) }
                default { [Drawing.Color]::FromArgb(48, 54, 63) }
            }
            [void]$view.List.Items.Add($item)
            if ($selected.ContainsKey([string]$row.TurnId)) { $item.Selected = $true }
            if (-not [string]::IsNullOrWhiteSpace($topId) -and $row.TurnId -eq $topId) { $view.List.TopItem = $item }
        }
        $staleCount = @($snapshot.TaskEntries | Where-Object { $_.Kind -eq 'StaleTurn' }).Count
        $blockingCount = [int]($snapshot.ActiveCount + $snapshot.UnknownCount)
        $view.Summary.Text = "当前条目：$($snapshot.TaskCount)  ·  阻止关机：$blockingCount  ·  已无视：$($snapshot.IgnoredCount)  ·  异常：$($snapshot.ObservedUnknownCount)（疑似失联 $staleCount）"
        $mainCount = @($snapshot.TaskEntries | Where-Object { $null -ne $_.PSObject.Properties['TaskType'] -and $_.TaskType -eq 'MainTask' }).Count
        $agentCount = @($snapshot.TaskEntries | Where-Object { $null -ne $_.PSObject.Properties['TaskType'] -and $_.TaskType -eq 'Subagent' }).Count
        $reviewCount = @($snapshot.TaskEntries | Where-Object { $null -ne $_.PSObject.Properties['TaskType'] -and $_.TaskType -eq 'InternalReview' }).Count
        if (($mainCount + $agentCount + $reviewCount) -gt 0) {
            $view.Summary.Text += "`r`n主任务 $mainCount  ·  子代理 $agentCount  ·  内部审批 $reviewCount"
        }
        if ($null -ne $snapshot.PSObject.Properties['CapturedAtUtc']) {
            $view.Summary.Text += '  ·  扫描 ' + ([datetime]$snapshot.CapturedAtUtc).ToLocalTime().ToString('HH:mm:ss')
        }
        if ($null -ne $snapshot.PSObject.Properties['HasPendingReads'] -and $snapshot.HasPendingReads) {
            $view.Summary.Text = '历史记录读取中 · ' + $view.Summary.Text
        }
        $view.LastSnapshot = $snapshot
        $view.LastTitles = $script:ThreadTitles
    }
    finally { $view.List.EndUpdate(); $view.Refreshing = $false }
}


function Show-TaskManagerDialog {
    param(
        [string]$ScreenshotPath = ''
    )

    if ($null -ne $script:TaskManagerView -and -not $script:TaskManagerView.Dialog.IsDisposed) { $script:TaskManagerView.Dialog.Activate(); return }
    $script:ForceDiscovery = $true
    Invoke-GuardPoll
    $script:ThreadTitles = Read-CodexThreadTitles

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Codex 活动任务管理'
    $dialog.FormBorderStyle = [Windows.Forms.FormBorderStyle]::Sizable
    $dialog.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $dialog.ClientSize = New-Object Drawing.Size(1080, 520)
    $dialog.MinimumSize = New-Object Drawing.Size(860, 440)
    $dialog.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $dialog.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $dialog.MaximizeBox = $true
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.TopMost = [bool]$script:Config.usagePanelTopMost
    $dialog.BackColor = [Drawing.Color]::FromArgb(249, 250, 252)
    $dialog.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

    # Text owns its row height, so DPI/font changes cannot overlap the summary or list.
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = [Windows.Forms.DockStyle]::Fill
    $layout.Padding = New-Object Windows.Forms.Padding(14, 12, 14, 14)
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $dialog.Controls.Add($layout)

    $instruction = New-Object Windows.Forms.Label
    $instruction.AutoSize = $true
    $instruction.Dock = [Windows.Forms.DockStyle]::Fill
    $instruction.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
    $instruction.Text = '勾选表示“无视”：该回合将不再阻止关机。只应无视已失联或无需等待的任务；同一任务的新回合仍会重新阻止关机。'
    $instruction.ForeColor = [Drawing.Color]::FromArgb(70, 75, 84)
    $layout.Controls.Add($instruction, 0, 0)

    $blockingCount = [int]($script:LastSnapshot.ActiveCount + $script:LastSnapshot.UnknownCount)
    $summary = New-Object Windows.Forms.Label
    $summary.AutoSize = $true
    $summary.Dock = [Windows.Forms.DockStyle]::Fill
    $summary.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 10)
    $summary.Text = "当前条目：$($script:LastSnapshot.TaskCount)  ·  阻止关机：$blockingCount  ·  已无视：$($script:LastSnapshot.IgnoredCount)  ·  异常：$($script:LastSnapshot.ObservedUnknownCount)"
    $summary.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
    $summary.ForeColor = [Drawing.Color]::FromArgb(48, 54, 63)
    $layout.Controls.Add($summary, 0, 1)
    $layout.Add_SizeChanged({
        $textWidth = [Math]::Max(1, $layout.ClientSize.Width - $layout.Padding.Horizontal)
        $instruction.MaximumSize = New-Object Drawing.Size($textWidth, 0)
        $summary.MaximumSize = New-Object Drawing.Size($textWidth, 0)
    }.GetNewClosure())

    $list = New-Object Windows.Forms.ListView
    $list.Dock = [Windows.Forms.DockStyle]::Fill
    $list.Margin = New-Object Windows.Forms.Padding(0)
    $list.View = [Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.CheckBoxes = $true
    $list.HideSelection = $false
    $list.ShowItemToolTips = $true
    [void]$list.Columns.Add('任务（勾选 = 无视）', 340)
    [void]$list.Columns.Add('状态', 128)
    [void]$list.Columns.Add('项目 / 目录', 260)
    [void]$list.Columns.Add('最后更新', 114)
    [void]$list.Columns.Add('回合 ID', 180)
    $resizeColumns = {
        param($sender, $eventArgs)
        if ($sender.Columns.Count -ne 5) { return }
        $fontScale = [Math]::Max(1.0, $sender.Font.Height / 17.0)
        $availableWidth = [Math]::Max(1, $sender.ClientSize.Width - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 4)
        $sender.Columns[0].Width = [int][Math]::Max(240 * $fontScale, $availableWidth * 0.33)
        $sender.Columns[1].Width = [int](128 * $fontScale)
        $sender.Columns[2].Width = [int][Math]::Max(180 * $fontScale, $availableWidth * 0.25)
        $sender.Columns[3].Width = [int](114 * $fontScale)
        $sender.Columns[4].Width = [int](180 * $fontScale)
    }
    $list.Add_SizeChanged($resizeColumns)
    $list.Add_FontChanged($resizeColumns)
    $layout.Controls.Add($list, 0, 2)

    $script:TaskManagerView = [pscustomobject]@{
        Dialog=$dialog; List=$list; Summary=$summary; PendingChecks=@{}
        Refreshing=$false; LastSnapshot=$null; LastTitles=$null
    }
    $list.Add_ItemCheck({
        param($sender, $eventArgs)
        $view = $script:TaskManagerView
        if ($null -eq $view -or $view.Refreshing) { return }
        $id = [string]$sender.Items[$eventArgs.Index].Tag
        if ([string]::IsNullOrWhiteSpace($id)) { $eventArgs.NewValue = $eventArgs.CurrentValue; return }
        $view.PendingChecks[$id] = ($eventArgs.NewValue -eq [Windows.Forms.CheckState]::Checked)
    })

    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true
    $buttons.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $buttons.Dock = [Windows.Forms.DockStyle]::Fill
    $buttons.FlowDirection = [Windows.Forms.FlowDirection]::RightToLeft
    $buttons.WrapContents = $false
    $buttons.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 0)
    $layout.Controls.Add($buttons, 0, 3)

    $applyButton = New-Object Windows.Forms.Button
    $applyButton.AutoSize = $true
    $applyButton.MinimumSize = New-Object Drawing.Size(88, 30)
    $applyButton.Margin = New-Object Windows.Forms.Padding(8, 0, 0, 0)
    $applyButton.Text = '应用'
    $applyButton.DialogResult = [Windows.Forms.DialogResult]::OK

    $cancelButton = New-Object Windows.Forms.Button
    $cancelButton.AutoSize = $true
    $cancelButton.MinimumSize = New-Object Drawing.Size(88, 30)
    $cancelButton.Margin = New-Object Windows.Forms.Padding(8, 0, 0, 0)
    $cancelButton.Text = '取消'
    $cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $buttons.Controls.Add($cancelButton)
    $buttons.Controls.Add($applyButton)
    $dialog.AcceptButton = $applyButton
    $dialog.CancelButton = $cancelButton
    Update-CodexTaskManagerView
    $refreshTimer = New-Object Windows.Forms.Timer
    $refreshTimer.Interval = 1000
    $refreshTimer.Add_Tick({ Update-CodexTaskManagerView })
    $refreshTimer.Start()

    try {
        if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
            $resolvedPath = [IO.Path]::GetFullPath($ScreenshotPath)
            $parent = Split-Path $resolvedPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($parent)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            $dialog.Show()
            [Windows.Forms.Application]::DoEvents()
            $bitmap = New-Object Drawing.Bitmap($dialog.Width, $dialog.Height)
            try {
                $rectangle = New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)
                $dialog.DrawToBitmap($bitmap, $rectangle)
                $bitmap.Save($resolvedPath, [Drawing.Imaging.ImageFormat]::Png)
            }
            finally {
                $bitmap.Dispose()
            }
            $dialog.Hide()
            return
        }

        $result = if ($null -ne $script:UsageForm -and -not $script:UsageForm.IsDisposed -and $script:UsageForm.Visible) {
            $dialog.ShowDialog($script:UsageForm)
        }
        else {
            $dialog.ShowDialog()
        }
        if ($result -ne [Windows.Forms.DialogResult]::OK) {
            return
        }

        $selectedIdList = New-Object System.Collections.Generic.List[string]
        foreach ($item in $list.Items) {
            if ($item.Checked -and -not [string]::IsNullOrWhiteSpace([string]$item.Tag)) {
                $selectedIdList.Add([string]$item.Tag)
            }
        }
        $selectedIds = $selectedIdList.ToArray()
        $newIgnoredIds = @($selectedIds | Where-Object { -not $script:IgnoredTurnIds.ContainsKey($_) })
        if ($newIgnoredIds.Count -gt 0) {
            $confirmation = [Windows.Forms.MessageBox]::Show(
                "无视后，即使所选任务仍在运行，守卫也可能继续进入关机流程。`r`n`r`n确定无视 $($newIgnoredIds.Count) 个新任务条目吗？",
                '确认无视活动任务',
                [Windows.Forms.MessageBoxButtons]::YesNo,
                [Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($confirmation -ne [Windows.Forms.DialogResult]::Yes) {
                return
            }
        }

        Set-IgnoredTurnIds -TurnIds $selectedIds
        $script:ForceDiscovery = $true
        Invoke-GuardPoll
    }
    finally {
        $refreshTimer.Stop()
        $refreshTimer.Dispose()
        $script:TaskManagerView = $null
        $dialog.Dispose()
    }
}

function New-UsagePanel {
    Initialize-UsagePanelTypes
    $form = New-Object CodexShutdownGuard.UsagePanelForm
    $form.Text = 'Codex 当前用量'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.ClientSize = New-Object Drawing.Size(380, 128)
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.TopMost = [bool]$script:Config.usagePanelTopMost
    $form.Opacity = [double]$script:Config.usagePanelOpacity
    $form.BackColor = [Drawing.Color]::FromArgb(249, 250, 252)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi

    $header = New-Object Windows.Forms.Panel
    $header.Location = New-Object Drawing.Point(1, 1)
    $header.Size = New-Object Drawing.Size(378, 34)
    $header.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $header.BackColor = [Drawing.Color]::FromArgb(243, 246, 248)
    $form.Controls.Add($header)

    $headerAccent = New-Object Windows.Forms.Label
    $headerAccent.Location = New-Object Drawing.Point(13, 7)
    $headerAccent.Size = New-Object Drawing.Size(12, 20)
    $headerAccent.Text = '●'
    $headerAccent.Font = New-Object Drawing.Font('Microsoft YaHei UI', 8)
    $headerAccent.ForeColor = [Drawing.Color]::FromArgb(53, 165, 107)
    $header.Controls.Add($headerAccent)

    $headerTitle = New-Object Windows.Forms.Label
    $headerTitle.Location = New-Object Drawing.Point(27, 7)
    $headerTitle.Size = New-Object Drawing.Size(320, 20)
    $headerTitle.Text = 'Codex 当前用量'
    $headerTitle.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
    $headerTitle.ForeColor = [Drawing.Color]::FromArgb(48, 54, 63)
    $header.Controls.Add($headerTitle)

    $headerDivider = New-Object Windows.Forms.Panel
    $headerDivider.Location = New-Object Drawing.Point(1, 34)
    $headerDivider.Size = New-Object Drawing.Size(378, 1)
    $headerDivider.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $headerDivider.BackColor = [Drawing.Color]::FromArgb(225, 229, 235)
    $form.Controls.Add($headerDivider)

    $dragHandler = {
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left) {
            [CodexShutdownGuard.WindowDrag]::Begin($script:UsageForm)
        }
    }
    $header.Add_MouseDown($dragHandler)
    $headerAccent.Add_MouseDown($dragHandler)
    $headerTitle.Add_MouseDown($dragHandler)

    $primaryRow = New-UsageBarRow -Parent $form -Top 43
    $secondaryRow = New-UsageBarRow -Parent $form -Top 89

    $statusLabel = New-Object Windows.Forms.Label
    $statusLabel.Location = New-Object Drawing.Point(16, 89)
    $statusLabel.Size = New-Object Drawing.Size(238, 30)
    $statusLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
    $statusLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 8)
    $statusLabel.ForeColor = [Drawing.Color]::FromArgb(70, 75, 84)
    $statusLabel.AutoEllipsis = $true
    $statusLabel.Cursor = [Windows.Forms.Cursors]::Hand
    $form.Controls.Add($statusLabel)

    $shutdownToggle = New-Object CodexShutdownGuard.UsageToggle
    $shutdownToggle.Location = New-Object Drawing.Point(268, 87)
    $shutdownToggle.Size = New-Object Drawing.Size(96, 30)
    $form.Controls.Add($shutdownToggle)
    $shutdownToolTip = New-Object Windows.Forms.ToolTip
    $shutdownToolTip.SetToolTip($shutdownToggle, '本轮全部 Codex 任务完成后关机；再次点击可取消。')
    $shutdownToolTip.SetToolTip($statusLabel, '点击查看全部活动任务，并选择是否无视某个任务。')

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $script:AllowUsageFormClose) {
            $eventArgs.Cancel = $true
            $sender.Hide()
            $script:UsagePanelMenuItem.Checked = $false
            Write-UsagePanelState -Visible $false
        }
    })

    $script:UsageForm = $form
    $script:UsagePrimaryRow = $primaryRow
    $script:UsageSecondaryRow = $secondaryRow
    $script:UsageStatusLabel = $statusLabel
    $script:UsageShutdownToggle = $shutdownToggle
    $script:UsageShutdownToolTip = $shutdownToolTip

    $shutdownToggle.Add_Click({ Switch-GuardShutdown })
    $statusLabel.Add_Click({
        Show-TaskManagerDialog
    })

    $workingArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $left = $workingArea.Right - $form.Width - 16
    $top = $workingArea.Bottom - $form.Height - 16
    if ($script:UsagePanelState.hasPosition) {
        $candidate = New-Object Drawing.Rectangle(
            [int]$script:UsagePanelState.x,
            [int]$script:UsagePanelState.y,
            $form.Width,
            $form.Height
        )
        $isVisibleOnScreen = $false
        foreach ($screen in [Windows.Forms.Screen]::AllScreens) {
            if ($screen.WorkingArea.IntersectsWith($candidate)) {
                $isVisibleOnScreen = $true
                break
            }
        }
        if ($isVisibleOnScreen) {
            $left = [int]$script:UsagePanelState.x
            $top = [int]$script:UsagePanelState.y
        }
    }
    $form.Location = New-Object Drawing.Point($left, $top)
}

function Update-UsagePanel {
    if ($null -eq $script:UsageForm -or $script:UsageForm.IsDisposed) {
        return
    }

    $rawUsage = if ($script:LastSnapshot.UsageAvailable) {
        $script:LastSnapshot.Usage
    }
    else {
        $null
    }
    $usageFreshness = Get-UsageFreshness -Usage $rawUsage
    $usage = if ($usageFreshness.Available -and $usageFreshness.Valid) {
        $rawUsage
    }
    else {
        $null
    }

    if ($null -eq $usage) {
        Set-UsageBarRow -Row $script:UsagePrimaryRow -Window $null
        Set-UsageBarRow -Row $script:UsageSecondaryRow -Window $null
        $script:UsageStatusLabel.Location = New-Object Drawing.Point(16, 43)
        $script:UsageShutdownToggle.Location = New-Object Drawing.Point(268, 41)
        $script:UsageForm.ClientSize = New-Object Drawing.Size(380, 78)
    }
    else {
        $firstWindow = if ($usageFreshness.PrimaryValid) { $usage.Primary } else { $null }
        $secondWindow = if ($usageFreshness.SecondaryValid) { $usage.Secondary } else { $null }
        if ($null -eq $firstWindow -and $null -ne $secondWindow) {
            $firstWindow = $secondWindow
            $secondWindow = $null
        }
        Set-UsageBarRow -Row $script:UsagePrimaryRow -Window $firstWindow
        Set-UsageBarRow -Row $script:UsageSecondaryRow -Window $secondWindow

        $hasSecondWindow = ($null -ne $secondWindow)
        $footerTop = if ($hasSecondWindow) { 135 } else { 89 }
        $script:UsageStatusLabel.Location = New-Object Drawing.Point(16, $footerTop)
        $script:UsageShutdownToggle.Location = New-Object Drawing.Point(268, ($footerTop - 2))
        $script:UsageForm.ClientSize = New-Object Drawing.Size(380, ($footerTop + 39))
    }

    $usagePrefix = if ($usageFreshness.Expired) {
        '等待新周期用量  ·  '
    }
    elseif ($usageFreshness.Available -and -not $usageFreshness.Valid) {
        '等待有效用量  ·  '
    }
    elseif ($null -eq $usage) {
        '等待用量数据  ·  '
    }
    else {
        ''
    }
    $blockingTaskCount = [int]($script:LastSnapshot.ActiveCount + $script:LastSnapshot.UnknownCount)
    $ignoredSuffix = if ($script:LastSnapshot.IgnoredCount -gt 0) {
        "  ·  无视：$($script:LastSnapshot.IgnoredCount)"
    }
    else {
        ''
    }
    $phaseSuffix = if ($script:Runtime.Armed) {
        if ($script:Runtime.Phase -eq 'ConfirmingIdle') {
            "  ·  确认空闲 $($script:Runtime.StableIdleSamples)/$($script:Config.stableSamplesRequired)"
        }
        else {
            '  ·  ' + (Get-PhaseLabel -Phase $script:Runtime.Phase)
        }
    }
    else {
        ''
    }
    $script:UsageStatusLabel.Text = "${usagePrefix}任务：$($script:LastSnapshot.TaskCount)  ·  阻塞：$blockingTaskCount$ignoredSuffix$phaseSuffix"
    $tooltipLines = New-Object System.Collections.Generic.List[string]
    $tooltipLines.Add($script:UsageStatusLabel.Text)
    if ($null -ne $rawUsage) {
        $lastUsageLocal = $rawUsage.UpdatedAtUtc.ToLocalTime()
        $validityText = if ($usageFreshness.Valid) { '当前额度周期内有效' } else { '等待下一次主配额事件' }
        $tooltipLines.Add(('用量快照：{0:MM-dd HH:mm:ss}（{1}）' -f $lastUsageLocal, $validityText))
    }
    if ($script:LastSnapshot.TaskCount -gt 0) {
        $tooltipLines.Add('当前任务条目（点击管理）：')
        foreach ($entry in @($script:LastSnapshot.TaskEntries | Select-Object -First 8)) {
            $entryState = Get-CodexGuardTaskStateLabel -Entry $entry
            $tooltipLines.Add("  [$entryState] $(Get-CodexTaskTitle -ThreadId ([string]$entry.ThreadId) -Entry $entry)")
        }
    }
    if ($script:LastSnapshot.UnknownCount -gt 0) {
        $tooltipLines.Add('未无视的异常状态会阻止自动关机。')
    }
    $script:UsageShutdownToolTip.SetToolTip(
        $script:UsageStatusLabel,
        ($tooltipLines -join [Environment]::NewLine)
    )
    $script:UsageShutdownToggle.Checked = [bool]$script:Runtime.Armed
    if ($script:Runtime.Armed) {
        $script:UsageShutdownToggle.Text = '开启'
    }
    else {
        $script:UsageShutdownToggle.Text = '关闭'
    }
}

function Show-UsagePanel {
    if ($null -eq $script:UsageForm -or $script:UsageForm.IsDisposed) {
        New-UsagePanel
    }
    Update-UsagePanel

    if ($script:UsageForm.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) {
        $script:UsageForm.WindowState = [Windows.Forms.FormWindowState]::Normal
    }

    # A second desktop-shortcut click must create an observable foreground
    # transition even when WinForms still reports the borderless panel as
    # visible. Re-showing it also repairs stale z-order state after Explorer,
    # UAC prompts, display changes, or full-screen applications.
    if ($script:UsageForm.Visible) {
        $script:UsageForm.Hide()
    }
    $script:UsageForm.TopMost = $false
    $script:UsageForm.Show()
    $script:UsageForm.TopMost = [bool]$script:Config.usagePanelTopMost
    $script:UsageForm.BringToFront()
    [void]$script:UsageForm.Activate()
    $script:UsagePanelMenuItem.Checked = $true
    Write-UsagePanelState -Visible $true
}

function Hide-UsagePanel {
    if ($null -ne $script:UsageForm -and -not $script:UsageForm.IsDisposed) {
        $script:UsageForm.Hide()
    }
    $script:UsagePanelMenuItem.Checked = $false
    Write-UsagePanelState -Visible $false
}

function Save-UsagePanelScreenshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($null -eq $script:UsageForm -or $script:UsageForm.IsDisposed) {
        throw 'Usage panel is not available for screenshot capture.'
    }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path $resolvedPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $bitmap = New-Object Drawing.Bitmap($script:UsageForm.Width, $script:UsageForm.Height)
    try {
        $rectangle = New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)
        $script:UsageForm.DrawToBitmap($bitmap, $rectangle)
        $bitmap.Save($resolvedPath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Invoke-GuardActions {
    param(
        [string[]]$Actions,
        [string]$AbortReason = '状态发生变化，已撤销关机并继续等待。'
    )

    foreach ($action in @($Actions)) {
        switch ($action) {
            'AbortShutdown' {
                $exitCode = Invoke-NativeShutdownAbort
                if ($exitCode -notin @(0, 1116)) {
                    Write-GuardLog -Level 'WARN' -Message "Unable to abort shutdown; exit code $exitCode."
                }
                Show-GuardBalloon -Title 'Codex 自动关机已撤销' -Text $AbortReason -Icon 'Warning'
            }
            'GraceStarted' {
                Show-GuardBalloon -Title 'Codex 任务已全部完成' -Text '开始 3 分钟可撤销缓冲；出现新任务会自动取消倒计时。'
                Write-GuardLog -Message 'All monitored turns completed; grace countdown started.'
            }
            'ScheduleShutdown' {
                $exitCode = Invoke-NativeShutdownSchedule -Seconds $script:Config.nativeShutdownSeconds
                if ($exitCode -eq 0) {
                    Show-GuardBalloon -Title 'Windows 即将关机' -Text ("将在 {0} 秒后关机；可从托盘取消。" -f $script:Config.nativeShutdownSeconds) -Icon 'Warning'
                }
                else {
                    $script:Runtime.ShutdownScheduled = $false
                    $script:Runtime.Armed = $false
                    $script:Runtime.Phase = 'Error'
                    $script:Runtime.LastError = "shutdown.exe failed with exit code $exitCode."
                    Write-GuardLog -Level 'ERROR' -Message $script:Runtime.LastError
                    Show-GuardBalloon -Title '无法安排关机' -Text '系统关机命令失败；工具已解除布防，请查看日志。' -Icon 'Error'
                }
            }
            'DryRunComplete' {
                Show-GuardBalloon -Title 'DryRun 完成' -Text '完整倒计时已模拟完成，没有执行真实关机。'
                Write-GuardLog -Message 'DryRun countdown completed.'
            }
        }
    }
}

function Request-Arm {
    $script:PendingArm = $true
    $script:ForceDiscovery = $true
}

function Request-Disarm {
    $script:PendingArm = $false
    $actions = Set-CodexGuardDisarmed -Runtime $script:Runtime
    Invoke-GuardActions -Actions $actions -AbortReason '用户已取消本轮自动关机。'
    Write-GuardLog -Message 'Guard disarmed by user.'
    Show-GuardBalloon -Title 'Codex 自动关机已取消' -Text '本轮监控已解除布防。'
}

function Request-Stop {
    Request-Disarm
    $script:StopRequested = $true
}

function Switch-GuardShutdown {
    if ($script:Runtime.Armed) {
        Request-Disarm
        [void](Write-GuardStatus -Running $true -Runtime $script:Runtime -Snapshot $script:LastSnapshot -AppAvailable $script:LastAppAvailable -AppReason $script:LastAppReason)
        Update-TrayPresentation
        Update-UsagePanel
    }
    else {
        Request-Arm
        Invoke-GuardPoll
    }
}



function Update-TrayPresentation {
    if ($null -eq $script:NotifyIcon) {
        return
    }

    $phaseLabel = Get-PhaseLabel -Phase $script:Runtime.Phase
    $remaining = Get-RemainingSeconds -Runtime $script:Runtime -NowUtc ([datetime]::UtcNow)
    $blockingCount = [int]($script:LastSnapshot.ActiveCount + $script:LastSnapshot.UnknownCount)
    $tooltip = if ($null -ne $remaining) {
        "Codex关机守卫：$phaseLabel，剩余${remaining}秒"
    }
    elseif ($blockingCount -gt 0) {
        "Codex关机守卫：$phaseLabel（阻塞 $blockingCount）"
    }
    elseif ($script:LastSnapshot.IgnoredCount -gt 0) {
        "Codex关机守卫：$phaseLabel（无视 $($script:LastSnapshot.IgnoredCount)）"
    }
    else {
        "Codex关机守卫：$phaseLabel"
    }
    if ($tooltip.Length -gt 63) {
        $tooltip = $tooltip.Substring(0, 63)
    }
    $script:NotifyIcon.Text = $tooltip
    $script:ArmMenuItem.Checked = [bool]$script:Runtime.Armed
}

function Invoke-GuardControlRequests {
    $shouldPoll = $false
    foreach ($command in @(Read-ControlRequests)) {
        switch ($command) {
            'Show' { Show-UsagePanel }
            'Arm' {
                Request-Arm
                $shouldPoll = $true
            }
            'Disarm' {
                Request-Disarm
                [void](Write-GuardStatus -Running $true -Runtime $script:Runtime -Snapshot $script:LastSnapshot -AppAvailable $script:LastAppAvailable -AppReason $script:LastAppReason)
                Update-TrayPresentation
                Update-UsagePanel
            }
            'Rescan' {
                $script:ForceDiscovery = $true
                $shouldPoll = $true
            }
            'Stop' { Request-Stop }
        }
    }

    if ($shouldPoll -and -not $script:PollBusy -and -not $script:StopRequested) {
        Invoke-GuardPoll
    }
}

function Invoke-GuardPoll {
    if ($script:PollBusy) {
        return
    }
    $script:PollBusy = $true
    try {
        Invoke-GuardControlRequests

        if ($script:StopRequested) {
            return
        }

        $appSession = Get-CodexGuardAppSession
        $script:LastAppAvailable = [bool]$appSession.Available
        $script:LastAppReason = [string]$appSession.Reason
        $resetActions = @()

        if ($appSession.Available) {
            Sync-IgnoredTaskSession -SessionKey $appSession.SessionKey
            if (
                $null -eq $script:Tracker -or
                $script:Runtime.AppSessionKey -ne $appSession.SessionKey
            ) {
                $resetActions = Reset-CodexGuardForAppSession -Runtime $script:Runtime -SessionKey $appSession.SessionKey -StartTimeUtc $appSession.StartTimeUtc
                $baseline = $appSession.StartTimeUtc.AddSeconds(-1 * $script:Config.sessionStartSkewSeconds)
                $script:Tracker = New-CodexGuardTracker -CodexHome $script:ResolvedCodexHome -BaselineUtc $baseline
                $script:ForceDiscovery = $true
                Write-GuardLog -Message "Tracking Codex app session $($appSession.SessionKey), baseline $($baseline.ToString('o'))."
            }

            $discoverySeconds = if ($script:Runtime.Phase -in @('GraceCountdown', 'NativeCountdown')) {
                $script:Config.countdownDiscoverySeconds
            }
            else {
                $script:Config.normalDiscoverySeconds
            }
            $discover = $script:ForceDiscovery
            if (
                -not $discover -and
                (
                    $null -eq $script:Tracker.LastDiscoveryUtc -or
                    ([datetime]::UtcNow - $script:Tracker.LastDiscoveryUtc).TotalSeconds -ge $discoverySeconds
                )
            ) {
                $discover = $true
            }

            Update-CodexGuardTracker -Tracker $script:Tracker -Discover:$discover
            $script:ForceDiscovery = $false
            if ($discover) {
                $script:ThreadTitles = Read-CodexThreadTitles
            }
            $script:LastSnapshot = Get-CodexGuardSnapshot `
                -Tracker $script:Tracker `
                -IgnoredTurnIds @($script:IgnoredTurnIds.Keys) `
                -InactiveSeconds $script:Config.taskInactivitySeconds
            Remove-CompletedIgnoredTurns -Snapshot $script:LastSnapshot
        }

        if ($script:PendingArm) {
            Set-CodexGuardArmed `
                -Runtime $script:Runtime `
                -CurrentActiveCount $script:LastSnapshot.ActiveCount `
                -CurrentObservedTaskCount $script:LastSnapshot.TaskCount
            $script:PendingArm = $false
            Write-GuardLog -Message "Guard armed; blocking active turns: $($script:LastSnapshot.ActiveCount); observed task entries: $($script:LastSnapshot.TaskCount); ignored: $($script:LastSnapshot.IgnoredCount)."
            if ($script:LastSnapshot.ActiveCount -gt 0) {
                Show-GuardBalloon -Title 'Codex 自动关机已布防' -Text ("正在等待 {0} 个活动回合完成。" -f $script:LastSnapshot.ActiveCount)
            }
            elseif ($script:LastSnapshot.IgnoredCount -gt 0) {
                Show-GuardBalloon -Title 'Codex 自动关机已布防' -Text ("当前任务均已设为无视；完成空闲确认后继续关机流程。")
            }
            else {
                Show-GuardBalloon -Title 'Codex 自动关机已布防' -Text '当前没有运行任务；将等待至少一个任务开始并完成后再关机。'
            }
        }

        Invoke-GuardActions -Actions $resetActions -AbortReason 'Codex 已重启，旧倒计时已撤销并重新建立监控基线。'

        $oldPhase = $script:Runtime.Phase
        $oldActiveCount = $script:LastRecordedActiveCount
        $actions = Update-CodexGuardRuntime `
            -Runtime $script:Runtime `
            -Snapshot $script:LastSnapshot `
            -AppAvailable $appSession.Available `
            -NowUtc ([datetime]::UtcNow) `
            -TotalGraceSeconds $script:Config.totalGraceSeconds `
            -NativeShutdownSeconds $script:Config.nativeShutdownSeconds `
            -RequiredStableSamples $script:Config.stableSamplesRequired
        Invoke-GuardActions -Actions $actions

        if (
            $oldPhase -in @('ConfirmingIdle', 'GraceCountdown', 'NativeCountdown') -and
            $script:Runtime.Phase -eq 'WaitingTasks'
        ) {
            Show-GuardBalloon -Title '发现新的 Codex 任务' -Text '稳定空闲缓冲已取消；工具会继续等待全部任务完成。' -Icon 'Warning'
            Write-GuardLog -Message 'A new active turn cancelled the grace countdown.'
        }

        $summaryKey = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $script:Runtime.Phase, $script:LastSnapshot.ActiveCount, $script:LastSnapshot.UnknownCount, $appSession.Available, $script:Runtime.StableIdleSamples, $script:LastSnapshot.TaskCount, $script:LastSnapshot.IgnoredCount
        if ($summaryKey -ne $script:LastLoggedSummary) {
            Write-GuardLog -Message "State=$($script:Runtime.Phase) Active=$($script:LastSnapshot.ActiveCount) Unknown=$($script:LastSnapshot.UnknownCount) TaskEntries=$($script:LastSnapshot.TaskCount) Ignored=$($script:LastSnapshot.IgnoredCount) AppAvailable=$($appSession.Available)"
            $script:LastLoggedSummary = $summaryKey
        }
        if ($oldActiveCount -ne $script:LastSnapshot.ActiveCount) {
            Write-GuardLog -Message "Active turn count changed: $oldActiveCount -> $($script:LastSnapshot.ActiveCount)."
            $script:LastRecordedActiveCount = $script:LastSnapshot.ActiveCount
        }

        [void](Write-GuardStatus -Running $true -Runtime $script:Runtime -Snapshot $script:LastSnapshot -AppAvailable $appSession.Available -AppReason $appSession.Reason)
        Update-TrayPresentation
        Update-UsagePanel
    }
    catch {
        $script:Runtime.LastError = $_.Exception.Message
        $script:Runtime.Phase = 'PausedUnknownState'
        if ($script:Runtime.ShutdownScheduled) {
            [void](Invoke-NativeShutdownAbort)
            $script:Runtime.ShutdownScheduled = $false
        }
        Write-GuardLog -Level 'ERROR' -Message "Polling failed closed: $($_.Exception.ToString())"
        Show-GuardBalloon -Title 'Codex 关机守卫已暂停' -Text '监控发生异常；为避免误关机，当前不会执行关机。' -Icon 'Error'
        Update-TrayPresentation
    }
    finally {
        $script:PollBusy = $false
    }
}

function Invoke-OneShotStatus {
    $appSession = Get-CodexGuardAppSession
    $snapshot = [pscustomobject]@{
        ActiveCount = 0
        ActiveTurns = @()
        ObservedActiveCount = 0
        AllActiveTurns = @()
        UnknownCount = 0
        UnknownItems = @()
        ObservedUnknownCount = 0
        AllUnknownItems = @()
        TaskCount = 0
        TaskEntries = @()
        IgnoredCount = 0
        IgnoredTurnIds = @()
        TrackedFileCount = 0
        TrackedTurnCount = 0
        UsageAvailable = $false
        Usage = $null
        UsageError = ''
    }
    if ($appSession.Available) {
        Sync-IgnoredTaskSession -SessionKey $appSession.SessionKey
        $baseline = $appSession.StartTimeUtc.AddSeconds(-1 * $script:Config.sessionStartSkewSeconds)
        $tracker = New-CodexGuardTracker -CodexHome $script:ResolvedCodexHome -BaselineUtc $baseline
        Update-CodexGuardTracker -Tracker $tracker -Discover
        $script:ThreadTitles = Read-CodexThreadTitles
        $snapshot = Get-CodexGuardSnapshot -Tracker $tracker -IgnoredTurnIds @($script:IgnoredTurnIds.Keys) -InactiveSeconds $script:Config.taskInactivitySeconds
        Remove-CompletedIgnoredTurns -Snapshot $snapshot
        $script:Runtime.AppSessionKey = $appSession.SessionKey
        $script:Runtime.AppSessionStartUtc = $appSession.StartTimeUtc
    }
    $payload = New-StatusPayload -Running $false -Runtime $script:Runtime -Snapshot $snapshot -AppAvailable $appSession.Available -AppReason $appSession.Reason
    $payload | ConvertTo-Json -Depth 6
}

$script:StateRoot = Resolve-CodexGuardStateRoot -StateRoot $StateRoot
[void](New-Item -ItemType Directory -Path $script:StateRoot -Force)
$script:ControlRoot = Join-Path $script:StateRoot 'control'
$script:LogsRoot = Join-Path $script:StateRoot 'logs'
[void](New-Item -ItemType Directory -Path $script:ControlRoot -Force)
$script:StatusPath = Join-Path $script:StateRoot 'status.json'
$script:UsagePanelStatePath = Join-Path $script:StateRoot 'usage-panel-state.json'
$script:IgnoredTaskStatePath = Join-Path $script:StateRoot 'ignored-tasks.json'
$script:CodexLaunchSettingsPath = Join-Path $script:StateRoot 'codex-launch-settings.json'
$script:CodexStartupSettingsPath = Join-Path $script:StateRoot 'codex-startup-settings.json'
$script:LogPath = Join-Path $script:LogsRoot ('guard-{0:yyyyMMdd}.log' -f [datetime]::Now)

$packageConfigPath = Join-Path $PSScriptRoot 'config.json'
$stateConfigPath = Join-Path $script:StateRoot 'config.json'
$selectedConfigPath = if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    [IO.Path]::GetFullPath($ConfigPath)
}
elseif (Test-Path -LiteralPath $packageConfigPath -PathType Leaf) {
    $packageConfigPath
}
elseif (Test-Path -LiteralPath $stateConfigPath -PathType Leaf) {
    $stateConfigPath
}
else {
    Join-Path $PSScriptRoot 'config.default.json'
}
$script:Config = Read-GuardConfiguration -SelectedPath $selectedConfigPath
$script:ResolvedCodexHome = Get-GuardCodexHome -Override $CodexHome
$effectiveDryRun = [bool]($DryRun -or $script:Config.dryRun)
$script:Runtime = New-CodexGuardRuntime -DryRun:$effectiveDryRun

if ([int]$script:Config.logRetentionDays -gt 0) {
    [void](New-Item -ItemType Directory -Path $script:LogsRoot -Force)
}
Remove-ExpiredGuardLogs

$mutexHash = Get-StablePathHash -Path $script:StateRoot
$mutexName = "Local\CodexShutdownGuard_$mutexHash"
$createdNew = $false
$mutex = [Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)

if (-not $createdNew) {
    try {
        if ($Show) {
            Write-ControlRequest -Command 'Show'
            'Codex Shutdown Guard: show request sent.'
        }
        elseif ($Arm) {
            Write-ControlRequest -Command 'Arm'
            'Codex Shutdown Guard: arm request sent.'
        }
        elseif ($Disarm) {
            Write-ControlRequest -Command 'Disarm'
            'Codex Shutdown Guard: disarm request sent.'
        }
        elseif ($Stop) {
            Write-ControlRequest -Command 'Stop'
            'Codex Shutdown Guard: stop request sent.'
        }
        elseif ($Status) {
            $existingStatus = Read-ExistingStatus
            if ($null -eq $existingStatus) {
                '{"running":true,"status":"starting"}'
            }
            else {
                $existingStatus | ConvertTo-Json -Depth 6
            }
        }
        # A duplicate -Tray invocation exits silently.
    }
    finally {
        $mutex.Dispose()
    }
    exit 0
}

try {
    $ignoredState = Read-IgnoredTaskState
    $script:IgnoredAppSessionKey = [string]$ignoredState.AppSessionKey
    $script:IgnoredTurnIds = @{}
    foreach ($turnId in @($ignoredState.TurnIds)) {
        $script:IgnoredTurnIds[[string]$turnId] = $true
    }
    $script:ThreadTitles = Read-CodexThreadTitles

    if ($Disarm -or $Stop) {
        'Codex Shutdown Guard is not running.'
        exit 0
    }

    if ($Status -and -not $Tray -and -not $Show -and -not $Arm) {
        Invoke-OneShotStatus
        exit 0
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $script:NotifyIcon = New-Object Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = [Drawing.SystemIcons]::Shield
    $script:NotifyIcon.Visible = $true

    $contextMenu = New-Object Windows.Forms.ContextMenuStrip
    $launchCodexMenuItem = New-Object Windows.Forms.ToolStripMenuItem('启动 Codex（使用当前代理）')
    $script:AutoStartCodexMenuItem = New-Object Windows.Forms.ToolStripMenuItem('守卫启动时自动启动 Codex')
    $script:AutoStartCodexMenuItem.CheckOnClick = $false
    try { $script:AutoStartCodexMenuItem.Checked = Get-CodexGuardAutoStartSetting -Path $script:CodexLaunchSettingsPath }
    catch { Show-GuardBalloon -Title 'Codex 启动设置' -Text '无法读取自动启动设置，本次保持关闭。' -Icon 'Warning' }
    $script:AutoStartGuardMenuItem = New-Object Windows.Forms.ToolStripMenuItem('启动 Codex 时自动启动守卫')
    $script:AutoStartGuardMenuItem.CheckOnClick = $false
    $script:AutoStartGuardMenuItem.Checked = Get-CodexGuardStartWithCodexSetting -Path $script:CodexStartupSettingsPath
    $script:ArmMenuItem = New-Object Windows.Forms.ToolStripMenuItem('任务完成后自动关机')
    $script:ArmMenuItem.CheckOnClick = $false
    $taskManagerMenuItem = New-Object Windows.Forms.ToolStripMenuItem('管理活动任务')
    $script:UsagePanelMenuItem = New-Object Windows.Forms.ToolStripMenuItem('显示用量面板')
    $script:UsagePanelMenuItem.CheckOnClick = $false
    $rescanMenuItem = New-Object Windows.Forms.ToolStripMenuItem('立即重新扫描')
    $exitMenuItem = New-Object Windows.Forms.ToolStripMenuItem('退出工具')

    [void]$contextMenu.Items.Add($launchCodexMenuItem)
    [void]$contextMenu.Items.Add($script:AutoStartCodexMenuItem)
    [void]$contextMenu.Items.Add($script:AutoStartGuardMenuItem)
    [void]$contextMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    [void]$contextMenu.Items.Add($script:ArmMenuItem)
    [void]$contextMenu.Items.Add($taskManagerMenuItem)
    [void]$contextMenu.Items.Add($script:UsagePanelMenuItem)
    [void]$contextMenu.Items.Add($rescanMenuItem)
    [void]$contextMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    [void]$contextMenu.Items.Add($exitMenuItem)
    $script:NotifyIcon.ContextMenuStrip = $contextMenu

    $script:ApplicationContext = New-Object Windows.Forms.ApplicationContext
    $script:Tracker = $null
    $script:LastSnapshot = [pscustomobject]@{
        ActiveCount = 0
        ActiveTurns = @()
        ObservedActiveCount = 0
        AllActiveTurns = @()
        UnknownCount = 0
        UnknownItems = @()
        ObservedUnknownCount = 0
        AllUnknownItems = @()
        TaskCount = 0
        TaskEntries = @()
        IgnoredCount = 0
        IgnoredTurnIds = @()
        TrackedFileCount = 0
        TrackedTurnCount = 0
        UsageAvailable = $false
        Usage = $null
        UsageError = ''
    }
    $script:LastAppAvailable = $false
    $script:LastAppReason = ''
    $script:PendingArm = [bool]$Arm
    $script:ForceDiscovery = $true
    $script:StopRequested = $false
    $script:PollBusy = $false
    $script:LastLoggedSummary = ''
    $script:LastRecordedActiveCount = 0
    $script:TaskManagerView = $null
    $script:UsageForm = $null
    $script:UsageShutdownToolTip = $null
    $script:UsagePanelState = Read-UsagePanelState
    $script:AllowUsageFormClose = $false
    $script:UsagePanelMenuItem.Checked = [bool]$script:UsagePanelState.visible

    $launchCodexMenuItem.Add_Click({ Request-CodexProxyLaunch })
    $script:AutoStartCodexMenuItem.Add_Click({ Set-GuardCodexAutoStart -Enabled (-not $script:AutoStartCodexMenuItem.Checked) })
    $script:AutoStartGuardMenuItem.Add_Click({ Set-GuardStartWithCodex -Enabled (-not $script:AutoStartGuardMenuItem.Checked) })

    $script:ArmMenuItem.Add_Click({ Switch-GuardShutdown })
    $taskManagerMenuItem.Add_Click({
        Show-TaskManagerDialog
    })
    $script:UsagePanelMenuItem.Add_Click({
        if ($null -ne $script:UsageForm -and $script:UsageForm.Visible) {
            Hide-UsagePanel
        }
        else {
            Show-UsagePanel
        }
    })
    $rescanMenuItem.Add_Click({
        $script:ForceDiscovery = $true
        Invoke-GuardPoll
        Show-GuardBalloon -Title 'Codex 关机守卫' -Text '已完成一次重新扫描。'
    })
    $exitMenuItem.Add_Click({
        Request-Stop
        $script:ApplicationContext.ExitThread()
    })
    $script:NotifyIcon.Add_DoubleClick({
        Show-UsagePanel
    })

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = [int]($script:Config.pollSeconds * 1000)
    $timer.Add_Tick({
        Invoke-GuardPoll
        if ($script:StopRequested) {
            $script:ApplicationContext.ExitThread()
        }
    })

    $controlTimer = New-Object Windows.Forms.Timer
    $controlTimer.Interval = 500
    $controlTimer.Add_Tick({
        Invoke-GuardControlRequests
        # Resume bounded history batches while remaining fail-closed. Ordinary
        # idle monitoring retains its configured one-minute polling interval.
        if (-not $script:StopRequested -and $null -ne $script:Tracker -and
            $null -ne $script:LastSnapshot.PSObject.Properties['HasPendingReads'] -and $script:LastSnapshot.HasPendingReads) {
            Invoke-GuardPoll
        }
        if ($script:StopRequested) {
            $script:ApplicationContext.ExitThread()
        }
    })

    Write-GuardLog -Message "Guard started. DryRun=$effectiveDryRun CodexHome=$($script:ResolvedCodexHome)"
    Invoke-GuardPoll
    if ($Show -or $script:UsagePanelState.visible) {
        Show-UsagePanel
    }
    if (-not [string]::IsNullOrWhiteSpace($UsagePanelScreenshotPath)) {
        if (-not $script:UsageForm.Visible) {
            Show-UsagePanel
        }
        if ($UsagePanelScreenshotHover -and $script:LastSnapshot.UsageAvailable) {
            $script:UsagePrimaryRow.IsHovering = $true
            Update-UsagePanel
        }
        [Windows.Forms.Application]::DoEvents()
        Save-UsagePanelScreenshot -Path $UsagePanelScreenshotPath
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskManagerScreenshotPath)) {
        Show-TaskManagerDialog -ScreenshotPath $TaskManagerScreenshotPath
    }
    # Only once at guard startup; never re-open Codex from a monitoring tick.
    if ($script:AutoStartGuardMenuItem.Checked) {
        try { [void](Start-CodexGuardCodexStartupWatcher -SettingsPath $script:CodexStartupSettingsPath -NativeRoot $PSScriptRoot -StateRoot $script:StateRoot) }
        catch { Show-GuardBalloon -Title '守卫自动启动' -Text '启动检测未能运行，请重新勾选启动选项。' -Icon 'Warning' }
    }
    if (-not $FromCodexStartup -and $script:AutoStartCodexMenuItem.Checked) { Request-CodexProxyLaunch -Automatic }
    $timer.Start()
    $controlTimer.Start()
    [Windows.Forms.Application]::Run($script:ApplicationContext)
}
finally {
    try {
        if ($null -ne $script:UsageShutdownToolTip) {
            $script:UsageShutdownToolTip.Dispose()
        }
        if ($null -ne $script:UsageForm -and -not $script:UsageForm.IsDisposed) {
            Write-UsagePanelState -Visible $script:UsageForm.Visible
            $script:AllowUsageFormClose = $true
            $script:UsageForm.Close()
            $script:UsageForm.Dispose()
        }
    }
    catch {
    }
    try {
        if ($null -ne $timer) {
            $timer.Stop()
            $timer.Dispose()
        }
    }
    catch {
    }
    try {
        if ($null -ne $controlTimer) {
            $controlTimer.Stop()
            $controlTimer.Dispose()
        }
    }
    catch {
    }
    try {
        if ($null -ne $script:NotifyIcon) {
            $script:NotifyIcon.Visible = $false
            $script:NotifyIcon.Dispose()
        }
    }
    catch {
    }
    try {
        [void](Write-GuardStatus -Running $false -Runtime $script:Runtime -Snapshot $script:LastSnapshot -AppAvailable $script:LastAppAvailable -AppReason $script:LastAppReason)
    }
    catch {
    }
    Write-GuardLog -Message 'Guard stopped.'
    if ($createdNew) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }
    }
    $mutex.Dispose()
}
