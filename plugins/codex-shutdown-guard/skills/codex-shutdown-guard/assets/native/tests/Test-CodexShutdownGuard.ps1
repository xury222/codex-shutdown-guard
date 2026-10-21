[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CodexShutdownGuard.Core.psm1') -Force

$script:Passed = 0

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Name
    )

    if ($Expected -ne $Actual) {
        throw "FAILED: $Name. Expected [$Expected], got [$Actual]."
    }
    $script:Passed++
}

function Assert-Contains {
    param(
        [object[]]$Items,
        [object]$Expected,
        [string]$Name
    )

    if ($Expected -notin $Items) {
        throw "FAILED: $Name. Missing [$Expected]."
    }
    $script:Passed++
}

function Write-Lines {
    param(
        [string]$Path,
        [string[]]$Lines,
        [switch]$Append
    )

    $encoding = New-Object Text.UTF8Encoding($false)
    $text = ($Lines -join "`n") + "`n"
    if ($Append) {
        [IO.File]::AppendAllText($Path, $text, $encoding)
    }
    else {
        [IO.File]::WriteAllText($Path, $text, $encoding)
    }
}

function Task-Line {
    param(
        [datetime]$AtUtc,
        [string]$Type,
        [string]$TurnId,
        [int]$Ordinal = -1
    )

    $prefix = '{"timestamp":"' + $AtUtc.ToString('o') + '"'
    if ($Ordinal -ge 0) {
        $prefix += ',"ordinal":' + $Ordinal
    }
    return $prefix + ',"type":"event_msg","payload":{"type":"' + $Type + '","turn_id":"' + $TurnId + '"}}'
}

function Context-Line {
    param(
        [datetime]$AtUtc,
        [string]$TurnId,
        [int]$Ordinal = -1
    )

    $prefix = '{"timestamp":"' + $AtUtc.ToString('o') + '"'
    if ($Ordinal -ge 0) {
        $prefix += ',"ordinal":' + $Ordinal
    }
    return $prefix + ',"type":"turn_context","payload":{"turn_id":"' + $TurnId + '"}}'
}

function Usage-Line {
    param(
        [datetime]$AtUtc,
        [double]$PrimaryUsedPercent,
        [int]$PrimaryWindowMinutes,
        [long]$PrimaryResetsAt,
        [double]$SecondaryUsedPercent = -1,
        [int]$SecondaryWindowMinutes = 0,
        [long]$SecondaryResetsAt = 0,
        [string]$LimitId = 'codex',
        [int]$Ordinal = -1
    )

    $secondary = if ($SecondaryUsedPercent -ge 0) {
        '{"used_percent":' + $SecondaryUsedPercent.ToString([Globalization.CultureInfo]::InvariantCulture) +
            ',"window_minutes":' + $SecondaryWindowMinutes +
            ',"resets_at":' + $SecondaryResetsAt + '}'
    }
    else {
        'null'
    }
    $prefix = '{"timestamp":"' + $AtUtc.ToString('o') + '"'
    if ($Ordinal -ge 0) {
        $prefix += ',"ordinal":' + $Ordinal
    }
    return $prefix +
        ',"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":456789},"last_token_usage":{"input_tokens":123456,"total_tokens":124000},"model_context_window":258400},"rate_limits":{"limit_id":"' + $LimitId + '","limit_name":null,"primary":{"used_percent":' +
        $PrimaryUsedPercent.ToString([Globalization.CultureInfo]::InvariantCulture) +
        ',"window_minutes":' + $PrimaryWindowMinutes +
        ',"resets_at":' + $PrimaryResetsAt +
        '},"secondary":' + $secondary +
        ',"credits":null,"individual_limit":null,"plan_type":"prolite","rate_limit_reached_type":null}}}'
}

$testRoot = Join-Path $env:TEMP ('CodexShutdownGuardTests_' + [guid]::NewGuid().ToString('N'))
$codexHome = Join-Path $testRoot '.codex'
$sessionRoot = Join-Path $codexHome 'sessions\2026\07\31'
[void](New-Item -ItemType Directory -Path $sessionRoot -Force)

try {
    $oldPackagedAppServer = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.825.4187.0_x64__2p2nqsd0c76g0\app\resources\codex.exe'
    $newLocalAppServer = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\fac60c5e9a2ae3df\codex.exe'
    Assert-Equal $true (Test-CodexGuardAppServerPath -Path $oldPackagedAppServer) 'legacy WindowsApps Codex app server path is accepted'
    Assert-Equal $true (Test-CodexGuardAppServerPath -Path $newLocalAppServer) 'current local Codex app server path is accepted'
    Assert-Equal $false (Test-CodexGuardAppServerPath -Path 'C:\Tools\codex.exe') 'unrelated codex executable is rejected'

    $launchScript = 'C:\Program Files\Codex Guard\CodexShutdownGuard.ps1'
    $showArguments = Get-CodexGuardPowerShellLaunchArguments -MainScriptPath $launchScript -Mode 'Show'
    $trayArguments = Get-CodexGuardPowerShellLaunchArguments -MainScriptPath $launchScript -Mode 'Tray'
    Assert-Equal '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "C:\Program Files\Codex Guard\CodexShutdownGuard.ps1" -Show' $showArguments 'desktop shortcut uses a hidden direct PowerShell show command'
    Assert-Equal '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "C:\Program Files\Codex Guard\CodexShutdownGuard.ps1" -Tray' $trayArguments 'startup shortcut uses a hidden direct PowerShell tray command'

    $baseline = [datetime]::UtcNow.AddMinutes(-1)
    $now = [datetime]::UtcNow
    $threadA = '11111111-1111-1111-1111-111111111111'
    $threadB = '22222222-2222-2222-2222-222222222222'
    $turnA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $turnB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $fileA = Join-Path $sessionRoot ("rollout-$threadA.jsonl")
    $fileB = Join-Path $sessionRoot ("rollout-$threadB.jsonl")

    Write-Lines -Path $fileA -Lines @(
        (Task-Line -AtUtc $now -Type 'task_started' -TurnId $turnA),
        (Context-Line -AtUtc $now.AddMilliseconds(1) -TurnId $turnA),
        (Usage-Line -AtUtc $now.AddMilliseconds(2) -PrimaryUsedPercent 37.5 -PrimaryWindowMinutes 10080 -PrimaryResetsAt 1786085890 -SecondaryUsedPercent 62 -SecondaryWindowMinutes 300 -SecondaryResetsAt 1785500000)
    )
    Write-Lines -Path $fileB -Lines @(
        (Task-Line -AtUtc $now -Type 'task_started' -TurnId $turnB),
        (Context-Line -AtUtc $now.AddMilliseconds(1) -TurnId $turnB)
    )

    $tracker = New-CodexGuardTracker -CodexHome $codexHome -BaselineUtc $baseline
    Update-CodexGuardTracker -Tracker $tracker -Discover
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 2 $snapshot.ActiveCount 'two interleaved turns are active'
    Assert-Equal 0 $snapshot.UnknownCount 'recognized turns are not unknown'
    Assert-Equal $true $snapshot.UsageAvailable 'token event exposes account usage'
    Assert-Equal 37.5 $snapshot.Usage.Primary.UsedPercent 'primary quota percentage is parsed'
    Assert-Equal 10080 $snapshot.Usage.Primary.WindowMinutes 'primary quota window is parsed'
    Assert-Equal 62 $snapshot.Usage.Secondary.UsedPercent 'secondary quota percentage is parsed'
    Assert-Equal 'prolite' $snapshot.Usage.PlanType 'plan type is parsed'
    Assert-Equal 123456 $snapshot.Usage.LastInputTokens 'last input tokens are parsed'

    $ignoredSnapshot = Get-CodexGuardSnapshot -Tracker $tracker -IgnoredTurnIds @($turnA)
    Assert-Equal 1 $ignoredSnapshot.ActiveCount 'an ignored active turn no longer blocks shutdown'
    Assert-Equal 2 $ignoredSnapshot.ObservedActiveCount 'ignored turns remain visible in the observed active count'
    Assert-Equal 2 $ignoredSnapshot.TaskCount 'ignored turns remain visible in the task list'
    Assert-Equal 1 $ignoredSnapshot.IgnoredCount 'ignored task count is explicit'
    Assert-Contains @($ignoredSnapshot.IgnoredTurnIds) $turnA 'ignored turn id is retained for status and UI'
    Assert-Equal $false (@($ignoredSnapshot.TaskEntries | Where-Object { $_.TurnId -eq $turnA })[0].BlocksShutdown) 'ignored task entry is marked non-blocking'
    Assert-Contains @($ignoredSnapshot.ActiveTurns.TurnId) $turnB 'the non-ignored peer remains the blocker'

    Write-Lines -Path $fileA -Append -Lines @(
        (Task-Line -AtUtc $now.AddSeconds(1) -Type 'task_complete' -TurnId $turnA),
        (Usage-Line -AtUtc $now.AddSeconds(1).AddMilliseconds(1) -PrimaryUsedPercent 41 -PrimaryWindowMinutes 10080 -PrimaryResetsAt 1786085890)
    )
    Update-CodexGuardTracker -Tracker $tracker
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 1 $snapshot.ActiveCount 'one completed turn leaves the other active'
    Assert-Equal $turnB $snapshot.ActiveTurns[0].TurnId 'child or peer turn remains the blocker'
    Assert-Equal 41 $snapshot.Usage.Primary.UsedPercent 'newer usage event replaces the previous snapshot'

    Write-Lines -Path $fileB -Append -Lines @(
        (Usage-Line -AtUtc $now.AddSeconds(1).AddMilliseconds(2) -PrimaryUsedPercent 0 -PrimaryWindowMinutes 10080 -PrimaryResetsAt 1786089999 -LimitId 'codex_bengalfox')
    )
    Update-CodexGuardTracker -Tracker $tracker
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 41 $snapshot.Usage.Primary.UsedPercent 'internal quota buckets cannot replace the main Codex account usage'

    Write-Lines -Path $fileB -Append -Lines @(
        (Task-Line -AtUtc $now.AddSeconds(2) -Type 'task_complete' -TurnId $turnB)
    )
    Update-CodexGuardTracker -Tracker $tracker
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 0 $snapshot.ActiveCount 'all paired turns complete'

    $waitingThread = '33333333-3333-3333-3333-333333333333'
    $waitingTurn = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
    $waitingFile = Join-Path $sessionRoot ("rollout-$waitingThread.jsonl")
    Write-Lines -Path $waitingFile -Lines @(
        (Task-Line -AtUtc $now.AddSeconds(3) -Type 'task_started' -TurnId $waitingTurn),
        (Context-Line -AtUtc $now.AddSeconds(3) -TurnId $waitingTurn)
    )
    Update-CodexGuardTracker -Tracker $tracker -Discover
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 1 $snapshot.ActiveCount 'approval or input wait remains active without task_complete'

    Write-Lines -Path $waitingFile -Append -Lines @(
        (Task-Line -AtUtc $now.AddSeconds(4) -Type 'task_complete' -TurnId $waitingTurn)
    )
    Update-CodexGuardTracker -Tracker $tracker

    $supersededThread = '66666666-6666-6666-6666-666666666666'
    $supersededTurn = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
    $replacementTurn = '99999999-9999-9999-9999-999999999999'
    $supersededFile = Join-Path $sessionRoot ("rollout-$supersededThread.jsonl")
    Write-Lines -Path $supersededFile -Lines @(
        (Task-Line -AtUtc $now.AddSeconds(5) -Type 'task_started' -TurnId $supersededTurn),
        (Context-Line -AtUtc $now.AddSeconds(5).AddMilliseconds(1) -TurnId $supersededTurn),
        (Task-Line -AtUtc $now.AddSeconds(6) -Type 'task_started' -TurnId $replacementTurn),
        (Context-Line -AtUtc $now.AddSeconds(6).AddMilliseconds(1) -TurnId $replacementTurn),
        (Task-Line -AtUtc $now.AddSeconds(7) -Type 'task_complete' -TurnId $replacementTurn)
    )
    Update-CodexGuardTracker -Tracker $tracker -Discover
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 0 $snapshot.ActiveCount 'a newer turn supersedes an incomplete turn in the same thread'
    Assert-Equal 'Superseded' $tracker.Turns[$supersededTurn].State 'superseded turn is retained only as inactive history'

    $orphanThread = '77777777-7777-7777-7777-777777777777'
    $orphanTurn = '12121212-1212-1212-1212-121212121212'
    $orphanFile = Join-Path $sessionRoot ("rollout-$orphanThread.jsonl")
    Write-Lines -Path $orphanFile -Lines @(
        (Task-Line -AtUtc $now.AddSeconds(8) -Type 'task_started' -TurnId $orphanTurn),
        (Context-Line -AtUtc $now.AddSeconds(8).AddMilliseconds(1) -TurnId $orphanTurn)
    )
    Update-CodexGuardTracker -Tracker $tracker -Discover
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 1 $snapshot.ActiveCount 'readable orphan candidate is initially active'
    Remove-Item -LiteralPath $orphanFile -Force
    Update-CodexGuardTracker -Tracker $tracker
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 0 $snapshot.ActiveCount 'missing session file is not double-counted as active'
    Assert-Equal 1 $snapshot.UnknownCount 'missing active session becomes one blocking unknown state'
    $ignoredOrphanSnapshot = Get-CodexGuardSnapshot -Tracker $tracker -IgnoredTurnIds @($orphanTurn)
    Assert-Equal 0 $ignoredOrphanSnapshot.UnknownCount 'a user-ignored missing task no longer blocks shutdown'
    Assert-Equal 1 $ignoredOrphanSnapshot.ObservedUnknownCount 'ignored missing task remains visible as an observed unknown'
    Assert-Equal 1 $ignoredOrphanSnapshot.TaskCount 'missing task remains manageable as a task entry'
    Assert-Equal 1 $ignoredOrphanSnapshot.IgnoredCount 'ignored missing task is counted explicitly'
    Assert-Equal 'Unknown' $ignoredOrphanSnapshot.TaskEntries[0].State 'missing active task is presented as an unknown task entry'
    Write-Lines -Path $orphanFile -Lines @(
        (Task-Line -AtUtc $now.AddSeconds(9) -Type 'task_complete' -TurnId $orphanTurn)
    )
    Update-CodexGuardTracker -Tracker $tracker
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 0 $snapshot.UnknownCount 'reappearing readable session clears its blocking read error'

    $staleThread = '44444444-4444-4444-4444-444444444444'
    $staleTurn = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
    $staleFile = Join-Path $sessionRoot ("rollout-$staleThread.jsonl")
    Write-Lines -Path $staleFile -Lines @(
        (Task-Line -AtUtc $baseline.AddHours(-1) -Type 'task_started' -TurnId $staleTurn),
        (Context-Line -AtUtc $baseline.AddHours(-1) -TurnId $staleTurn)
    )
    [IO.File]::SetLastWriteTimeUtc($staleFile, [datetime]::UtcNow)
    Update-CodexGuardTracker -Tracker $tracker -Discover
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 0 $snapshot.ActiveCount 'stale incomplete turn before app baseline is ignored'

    $unknownThread = '55555555-5555-5555-5555-555555555555'
    $unknownTurn = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
    $unknownFile = Join-Path $sessionRoot ("rollout-$unknownThread.jsonl")
    Write-Lines -Path $unknownFile -Lines @(
        (Context-Line -AtUtc $now.AddSeconds(5) -TurnId $unknownTurn)
    )
    Update-CodexGuardTracker -Tracker $tracker -Discover
    $snapshot = Get-CodexGuardSnapshot -Tracker $tracker
    Assert-Equal 1 $snapshot.UnknownCount 'unrecognized current turn fails closed'
    $ignoredUnknownSnapshot = Get-CodexGuardSnapshot -Tracker $tracker -IgnoredTurnIds @($unknownTurn)
    Assert-Equal 0 $ignoredUnknownSnapshot.UnknownCount 'an explicitly ignored unknown turn no longer blocks shutdown'
    Assert-Equal 1 $ignoredUnknownSnapshot.ObservedUnknownCount 'ignored unknown turn remains visible for review'
    Assert-Equal 1 $ignoredUnknownSnapshot.IgnoredCount 'ignored unknown turn participates in the ignored count'

    $missingCodexHome = Join-Path $testRoot '.codex-missing-sessions'
    $missingTracker = New-CodexGuardTracker -CodexHome $missingCodexHome -BaselineUtc $baseline
    Update-CodexGuardTracker -Tracker $missingTracker -Discover
    $missingSnapshot = Get-CodexGuardSnapshot -Tracker $missingTracker -IgnoredTurnIds @($unknownTurn)
    Assert-Equal 1 $missingSnapshot.UnknownCount 'a global sessions error cannot be bypassed with a task id'
    Assert-Equal 0 $missingSnapshot.IgnoredCount 'global errors are never counted as ignored tasks'
    Assert-Equal 0 $missingSnapshot.TaskCount 'global errors are not presented as selectable task entries'

    $runtime = New-CodexGuardRuntime -DryRun
    Set-CodexGuardArmed -Runtime $runtime -CurrentActiveCount 2
    $activeSnapshot = [pscustomobject]@{ ActiveCount = 2; UnknownCount = 0 }
    $zeroSnapshot = [pscustomobject]@{ ActiveCount = 0; UnknownCount = 0 }
    $unknownSnapshot = [pscustomobject]@{ ActiveCount = 0; UnknownCount = 1 }
    $t0 = [datetime]::UtcNow

    $actions = Update-CodexGuardRuntime -Runtime $runtime -Snapshot $activeSnapshot -AppAvailable $true -NowUtc $t0 -TotalGraceSeconds 180 -NativeShutdownSeconds 30
    Assert-Equal 'WaitingTasks' $runtime.Phase 'armed runtime waits for active turns'
    Assert-Equal 0 @($actions).Count 'active turns do not trigger shutdown'

    $actions = Update-CodexGuardRuntime -Runtime $runtime -Snapshot $zeroSnapshot -AppAvailable $true -NowUtc $t0 -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Equal 'ConfirmingIdle' $runtime.Phase 'first idle observation starts confirmation'
    Assert-Equal 1 $runtime.StableIdleSamples 'first stable idle sample is recorded'

    $actions = Update-CodexGuardRuntime -Runtime $runtime -Snapshot $zeroSnapshot -AppAvailable $true -NowUtc $t0.AddSeconds(60) -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Equal 'ConfirmingIdle' $runtime.Phase 'second idle observation remains in confirmation'
    Assert-Equal 2 $runtime.StableIdleSamples 'second stable idle sample is recorded'

    $actions = Update-CodexGuardRuntime -Runtime $runtime -Snapshot $zeroSnapshot -AppAvailable $true -NowUtc $t0.AddSeconds(120) -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Equal 'GraceCountdown' $runtime.Phase 'third idle observation starts grace period'
    Assert-Contains @($actions) 'GraceStarted' 'grace start action emitted after three samples'

    $actions = Update-CodexGuardRuntime -Runtime $runtime -Snapshot $zeroSnapshot -AppAvailable $true -NowUtc $t0.AddSeconds(269) -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Equal 0 @($actions).Count 'shutdown is not scheduled before 150 seconds'

    $actions = Update-CodexGuardRuntime -Runtime $runtime -Snapshot $zeroSnapshot -AppAvailable $true -NowUtc $t0.AddSeconds(270) -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Contains @($actions) 'ScheduleShutdown' 'native countdown starts at 150 seconds'
    Assert-Equal 'NativeCountdown' $runtime.Phase 'runtime enters native countdown'

    $actions = Update-CodexGuardRuntime -Runtime $runtime -Snapshot $activeSnapshot -AppAvailable $true -NowUtc $t0.AddSeconds(271) -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Contains @($actions) 'AbortShutdown' 'new task aborts pending shutdown'
    Assert-Equal 'WaitingTasks' $runtime.Phase 'new task returns to waiting state'
    Assert-Equal 0 $runtime.StableIdleSamples 'new task resets idle confirmation immediately'

    $actions = Update-CodexGuardRuntime -Runtime $runtime -Snapshot $unknownSnapshot -AppAvailable $true -NowUtc $t0.AddSeconds(272) -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Equal 'PausedUnknownState' $runtime.Phase 'unknown state pauses shutdown'

    $freshRuntime = New-CodexGuardRuntime -DryRun
    Set-CodexGuardArmed -Runtime $freshRuntime -CurrentActiveCount 0
    $actions = Update-CodexGuardRuntime -Runtime $freshRuntime -Snapshot $zeroSnapshot -AppAvailable $true -NowUtc $t0 -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Equal 'WaitingFirstTask' $freshRuntime.Phase 'arming with no task does not immediately shut down'

    $actions = Update-CodexGuardRuntime -Runtime $freshRuntime -Snapshot $zeroSnapshot -AppAvailable $false -NowUtc $t0 -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Equal 'PausedAppUnavailable' $freshRuntime.Phase 'app unavailable fails closed'

    $ignoredOnlyRuntime = New-CodexGuardRuntime -DryRun
    Set-CodexGuardArmed -Runtime $ignoredOnlyRuntime -CurrentActiveCount 0 -CurrentObservedTaskCount 1
    Assert-Equal $true $ignoredOnlyRuntime.SeenActive 'arming with an ignored task still records that work was observed'
    $actions = Update-CodexGuardRuntime -Runtime $ignoredOnlyRuntime -Snapshot $zeroSnapshot -AppAvailable $true -NowUtc $t0 -TotalGraceSeconds 180 -NativeShutdownSeconds 30 -RequiredStableSamples 3
    Assert-Equal 'ConfirmingIdle' $ignoredOnlyRuntime.Phase 'an ignored-only task set can proceed through guarded idle confirmation'

    $defaultConfig = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.default.json') -Raw | ConvertFrom-Json
    Assert-Equal 60 $defaultConfig.pollSeconds 'default task status poll interval is one minute'
    Assert-Equal 3 $defaultConfig.stableSamplesRequired 'default idle confirmation requires three samples'
    Assert-Equal 180 $defaultConfig.usageStaleSeconds 'missing reset time uses a three-minute compatibility fallback'
    Assert-Equal 120 $defaultConfig.nativeShutdownSeconds 'native countdown spans at least one one-minute safety poll'
    $mainScriptText = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'CodexShutdownGuard.ps1') -Raw -Encoding UTF8
    Assert-Equal $true ($mainScriptText -match '\$controlTimer\.Interval\s*=\s*500') 'shortcut control requests use a separate half-second timer'
    Assert-Equal $true ($mainScriptText -match '\$script:UsageForm\.BringToFront\(\)') 'desktop shortcut brings an already-visible usage panel to the foreground'
    Assert-Equal $true ($mainScriptText -match '\$script:UsageForm\.Activate\(\)') 'desktop shortcut activates the usage panel after showing it'
    Assert-Equal $true ($mainScriptText -match 'if \(\$script:UsageForm\.Visible\)\s*\{\s*\$script:UsageForm\.Hide\(\)') 'desktop shortcut re-shows an already-visible usage panel to repair stale z-order'

    $ordinalCodexHome = Join-Path $testRoot '.codex-ordinal'
    $ordinalSessionRoot = Join-Path $ordinalCodexHome 'sessions\2026\08\21'
    [void](New-Item -ItemType Directory -Path $ordinalSessionRoot -Force)
    $ordinalThread = '88888888-8888-8888-8888-888888888888'
    $ordinalTurn = '13131313-1313-1313-1313-131313131313'
    $reorderedThread = '99999999-8888-7777-6666-555555555555'
    $reorderedTurn = '14141414-1414-1414-1414-141414141414'
    $ordinalFile = Join-Path $ordinalSessionRoot ("rollout-$ordinalThread.jsonl")
    $reorderedFile = Join-Path $ordinalSessionRoot ("rollout-$reorderedThread.jsonl")
    $ordinalNow = [datetime]::UtcNow
    $ordinalReset = ([datetimeoffset]$ordinalNow.AddHours(1)).ToUnixTimeSeconds()
    Write-Lines -Path $ordinalFile -Lines @(
        (Task-Line -AtUtc $ordinalNow -Type 'task_started' -TurnId $ordinalTurn -Ordinal 1),
        (Context-Line -AtUtc $ordinalNow.AddMilliseconds(1) -TurnId $ordinalTurn -Ordinal 2),
        (Usage-Line -AtUtc $ordinalNow.AddMilliseconds(2) -PrimaryUsedPercent 44 -PrimaryWindowMinutes 10080 -PrimaryResetsAt $ordinalReset -Ordinal 3)
    )
    Write-Lines -Path $reorderedFile -Lines @(
        ('{"timestamp":"' + $ordinalNow.AddMilliseconds(3).ToString('o') + '","sequence":9,"ordinal":1,"type":"event_msg","source":"desktop","payload":{"type":"task_started","turn_id":"' + $reorderedTurn + '"}}'),
        ('{"timestamp":"' + $ordinalNow.AddMilliseconds(4).ToString('o') + '","ordinal":2,"type":"turn_context","source":"desktop","payload":{"turn_id":"' + $reorderedTurn + '"}}')
    )

    $ordinalTracker = New-CodexGuardTracker -CodexHome $ordinalCodexHome -BaselineUtc $ordinalNow.AddMinutes(-1)
    Update-CodexGuardTracker -Tracker $ordinalTracker -Discover
    $ordinalSnapshot = Get-CodexGuardSnapshot -Tracker $ordinalTracker
    Assert-Equal 2 $ordinalSnapshot.ActiveCount 'ordinal and reordered JSON task events are both active'
    Assert-Equal 0 $ordinalSnapshot.UnknownCount 'ordinal and reordered contexts are recognized'
    Assert-Contains @($ordinalSnapshot.ActiveTurns.TurnId) $ordinalTurn 'ordinal task id is retained'
    Assert-Contains @($ordinalSnapshot.ActiveTurns.TurnId) $reorderedTurn 'reordered task id is retained'
    Assert-Equal $true $ordinalSnapshot.UsageAvailable 'ordinal token event exposes account usage'
    Assert-Equal 44 $ordinalSnapshot.Usage.Primary.UsedPercent 'ordinal quota event is parsed'

    Write-Lines -Path $ordinalFile -Append -Lines @(
        (Task-Line -AtUtc $ordinalNow.AddSeconds(1) -Type 'task_complete' -TurnId $ordinalTurn -Ordinal 4)
    )
    Write-Lines -Path $reorderedFile -Append -Lines @(
        ('{"timestamp":"' + $ordinalNow.AddSeconds(1).AddMilliseconds(1).ToString('o') + '","ordinal":3,"type":"event_msg","source":"desktop","payload":{"type":"task_complete","turn_id":"' + $reorderedTurn + '"}}')
    )
    Update-CodexGuardTracker -Tracker $ordinalTracker
    $ordinalSnapshot = Get-CodexGuardSnapshot -Tracker $ordinalTracker
    Assert-Equal 0 $ordinalSnapshot.ActiveCount 'ordinal and reordered completion events clear both tasks'
    Assert-Equal 0 $ordinalSnapshot.UnknownCount 'completion leaves no parser uncertainty'

    $activeWindowUsage = [pscustomobject]@{
        UpdatedAtUtc = $t0.AddHours(-2)
        Primary = [pscustomobject]@{ ResetsAtUtc = $t0.AddDays(1) }
        Secondary = $null
    }
    $validity = Get-CodexGuardUsageValidity -Usage $activeWindowUsage -NowUtc $t0 -FallbackMaxAgeSeconds 180
    Assert-Equal $true $validity.Valid 'an old snapshot remains valid while its quota window is active'
    Assert-Equal $false $validity.Stale 'age alone does not expire an active quota window'
    Assert-Equal 7200 $validity.AgeSeconds 'snapshot age remains available as diagnostics'

    $expiredWindowUsage = [pscustomobject]@{
        UpdatedAtUtc = $t0.AddMinutes(-1)
        Primary = [pscustomobject]@{ ResetsAtUtc = $t0.AddSeconds(-1) }
        Secondary = $null
    }
    $validity = Get-CodexGuardUsageValidity -Usage $expiredWindowUsage -NowUtc $t0 -FallbackMaxAgeSeconds 180
    Assert-Equal $false $validity.Valid 'a snapshot is invalid after its quota window resets'
    Assert-Equal $true $validity.Expired 'a passed reset time is reported as an expired quota window'

    $mixedWindowUsage = [pscustomobject]@{
        UpdatedAtUtc = $t0.AddHours(-4)
        Primary = [pscustomobject]@{ ResetsAtUtc = $t0.AddSeconds(-1) }
        Secondary = [pscustomobject]@{ ResetsAtUtc = $t0.AddHours(1) }
    }
    $validity = Get-CodexGuardUsageValidity -Usage $mixedWindowUsage -NowUtc $t0 -FallbackMaxAgeSeconds 180
    Assert-Equal $true $validity.Valid 'one active quota window keeps the usable part of a snapshot valid'
    Assert-Equal $false $validity.PrimaryValid 'an expired window is filtered from the panel'
    Assert-Equal $true $validity.SecondaryValid 'an active window remains visible in the panel'

    $fallbackUsage = [pscustomobject]@{
        UpdatedAtUtc = $t0.AddSeconds(-181)
        Primary = [pscustomobject]@{ ResetsAtUtc = $null }
        Secondary = $null
    }
    $validity = Get-CodexGuardUsageValidity -Usage $fallbackUsage -NowUtc $t0 -FallbackMaxAgeSeconds 180
    Assert-Equal $false $validity.Valid 'age fallback still protects snapshots without reset metadata'
    Assert-Equal 'MissingResetTimeAndFallbackExpired' $validity.Reason 'fallback expiration has a diagnostic reason'

    [pscustomobject]@{
        Passed = $script:Passed
        RealShutdownCommandsExecuted = 0
        TestRoot = $testRoot
    }
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
