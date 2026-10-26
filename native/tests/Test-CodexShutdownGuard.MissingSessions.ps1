[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CodexShutdownGuard.Core.psm1') -Force -PassThru
$testRoot = Join-Path $env:TEMP ('CodexGuardMissingSessions_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $passed = & $module {
        param($testRoot)
        $script:MissingPassed = 0
        $now = [datetime]::UtcNow
        $mainId = '11111111-1111-1111-1111-111111111111'
        $otherId = '22222222-2222-2222-2222-222222222222'
        function Check($expected, $actual, [string]$name) {
            if ($expected -ne $actual) { throw "FAILED: $name; expected [$expected], got [$actual]." }
            $script:MissingPassed++
        }
        function New-Case([string]$name) {
            $home = Join-Path $testRoot $name
            [void][IO.Directory]::CreateDirectory((Join-Path $home 'sessions'))
            return New-CodexGuardTracker -CodexHome $home -BaselineUtc $now.AddHours(-1)
        }
        function File($tracker, [string]$name = 'rollout-11111111-1111-1111-1111-111111111111.jsonl', [string]$kind = 'MainTask') {
            $file = New-CodexGuardFileState -Path (Join-Path $tracker.SessionsRoot $name)
            $tracker.Files[$file.Path] = $file
            if ($kind -ne 'Unknown') {
                $source = if ($kind -eq 'Subagent') { @{ subagent=@{ thread_spawn=@{ parent_thread_id=$otherId } } } } else { 'app' }
                $payload = @{ id=$mainId; source=$source; cwd='C:\MissingFixture' }
                $line = @{ type='session_meta'; timestamp=$now.AddDays(-1).ToString('o'); payload=$payload } | ConvertTo-Json -Depth 8 -Compress
                Register-CodexGuardLine -Tracker $tracker -FileState $file -Line $line
            }
            return $file
        }
        function Send($tracker, $file, [string]$type, [string]$id) {
            $top = if ($type -eq 'turn_context') { 'turn_context' } else { 'event_msg' }
            $line = @{ type=$top; timestamp=$now.ToString('o'); payload=@{ type=$type; turn_id=$id; cwd='C:\MissingFixture' } } | ConvertTo-Json -Depth 5 -Compress
            Register-CodexGuardLine -Tracker $tracker -FileState $file -Line $line
        }
        function Snapshot($tracker) { return Get-CodexGuardSnapshot -Tracker $tracker -NowUtc $now }
        function Write-Session([string]$path, [string]$id, [string]$turn) {
            $records = @(
                (@{ type='session_meta'; timestamp=$now.AddMinutes(-5).ToString('o'); payload=@{ id=$id; source='app'; thread_source='user'; cwd='C:\CurrentFixture' } } | ConvertTo-Json -Depth 7 -Compress),
                (@{ type='event_msg'; timestamp=$now.ToString('o'); payload=@{ type='task_started'; turn_id=$turn } } | ConvertTo-Json -Depth 5 -Compress)
            )
            [IO.File]::WriteAllText($path, (($records -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
        }

        # A vanished candidate without observed work must not stay PendingRead forever.
        foreach ($variant in @('unknown-unread', 'known-unstarted', 'partial', 'empty', 'old-read-error', 'completed', 'aborted')) {
            $tracker = New-Case $variant
            $kind = if ($variant -eq 'unknown-unread') { 'Unknown' } else { 'MainTask' }
            $file = File $tracker -kind $kind
            $file.LastLength = if ($variant -eq 'empty') { 0 } else { 180 }
            if ($variant -eq 'partial') { $file.Partial = 'pending' }
            if ($variant -eq 'old-read-error') { $tracker.ReadErrors[$file.Path] = 'A complete session event could not be parsed.' }
            if ($variant -in @('completed', 'aborted')) {
                Send $tracker $file 'task_started' 'finished-turn'
                Send $tracker $file $(if ($variant -eq 'completed') { 'task_complete' } else { 'turn_aborted' }) 'finished-turn'
            }
            Update-CodexGuardTracker -Tracker $tracker
            $snapshot = Snapshot $tracker
            Check 0 $tracker.Files.Count "$variant removes the absent candidate"
            Check 0 $tracker.ReadErrors.Count "$variant removes its obsolete file-read error"
            Check 0 $snapshot.TaskCount "$variant does not invent a task"
            Check 0 $snapshot.UnknownCount "$variant does not block shutdown"
            Check $false $snapshot.HasPendingReads "$variant cannot keep history replay alive"
            Check 0 $snapshot.HistoryBytesRemaining "$variant contributes no ghost history bytes"
            if ($variant -in @('completed', 'aborted')) { Check 1 $tracker.Turns.Count "$variant retains already-recorded terminal history" }
            Update-CodexGuardTracker -Tracker $tracker
            Check 0 (Snapshot $tracker).UnknownCount "$variant remains removed on a subsequent scan"
        }

        # Disappearance is not evidence that an observed main turn completed.
        foreach ($variant in @('active-main', 'context-only-main', 'active-child', 'context-only-child')) {
            $tracker = New-Case $variant
            $isChild = $variant.EndsWith('-child')
            $file = File $tracker -kind $(if ($isChild) { 'Subagent' } else { 'MainTask' })
            $file.LastLength = 180
            Send $tracker $file $(if ($variant.StartsWith('context')) { 'turn_context' } else { 'task_started' }) 'unfinished-turn'
            Update-CodexGuardTracker -Tracker $tracker
            $snapshot = Snapshot $tracker
            Check 1 $tracker.Files.Count "$variant retains its identity and unfinished turn"
            Check $true $tracker.ReadErrors.ContainsKey($file.Path) "$variant records a missing-file error"
            Check 1 $snapshot.TaskCount "$variant remains visible"
            Check $(if ($isChild) { 0 } else { 1 }) $snapshot.UnknownCount "$variant retains the correct shutdown policy"
            Check (-not $isChild) $snapshot.TaskEntries[0].BlocksShutdown "$variant entry agrees with shutdown counts"
        }

        # A missing active file can resume and publish a real completion later.
        $tracker = New-Case 'active-file-returns'
        $file = File $tracker
        Send $tracker $file 'task_started' 'returning-turn'
        Update-CodexGuardTracker -Tracker $tracker
        Check 1 (Snapshot $tracker).UnknownCount 'missing active main remains uncertain before its file returns'
        $records = @(
            (@{ type='session_meta'; timestamp=$now.AddMinutes(-1).ToString('o'); payload=@{ id=$mainId; source='app' } } | ConvertTo-Json -Depth 5 -Compress),
            (@{ type='event_msg'; timestamp=$now.AddSeconds(1).ToString('o'); payload=@{ type='task_complete'; turn_id='returning-turn' } } | ConvertTo-Json -Depth 5 -Compress)
        )
        [IO.File]::WriteAllText($file.Path, (($records -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
        Update-CodexGuardTracker -Tracker $tracker
        Check 0 $tracker.ReadErrors.Count 'reappearing active file clears the transient missing-file error'
        Check 0 (Snapshot $tracker).UnknownCount 'real terminal event releases the recovered main turn'
        Check 'Completed' $tracker.Turns['returning-turn'].State 'completion is confirmed from the returning file'

        # An access denial or unrelated I/O error must never be mistaken for absence.
        foreach ($exceptionType in @('denied', 'io-error')) {
            $tracker = New-Case $exceptionType
            $file = File $tracker -kind 'Unknown'
            $file.LastLength = 100
            $script:InjectedFile = $file.Path
            $script:InjectedFailure = $exceptionType
            function Get-Item {
                [CmdletBinding()]
                param([string]$LiteralPath)
                if ($LiteralPath -eq $script:InjectedFile) {
                    if ($script:InjectedFailure -eq 'denied') { throw (New-Object UnauthorizedAccessException('Injected access denial.')) }
                    throw (New-Object IO.IOException('Injected unrelated I/O failure.'))
                }
                Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
            }
            try { Update-CodexGuardTracker -Tracker $tracker }
            finally { Remove-Item Function:\Get-Item }
            $snapshot = Snapshot $tracker
            Check 1 $tracker.Files.Count "$exceptionType preserves the unresolved file"
            Check $true $tracker.ReadErrors.ContainsKey($file.Path) "$exceptionType remains a real diagnostic"
            Check 1 $snapshot.UnknownCount "$exceptionType conservatively blocks shutdown"
        }

        # Compression/archival can remove the file between metadata inspection and open.
        foreach ($variant in @('unobserved', 'observed-active')) {
            $tracker = New-Case ('open-race-' + $variant)
            $file = File $tracker
            [IO.File]::WriteAllText($file.Path, "{} `n", (New-Object Text.UTF8Encoding($false)))
            $file.LastLength = [IO.FileInfo]::new($file.Path).Length
            if ($variant -eq 'observed-active') { Send $tracker $file 'task_started' 'racing-turn' }
            $script:RaceFile = $file.Path
            function Get-Item {
                [CmdletBinding()]
                param([string]$LiteralPath)
                $item = Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
                if ($LiteralPath -eq $script:RaceFile) {
                    $resolvedFile = [IO.Path]::GetFullPath($LiteralPath)
                    $fixtureBase = [IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
                    if (-not $resolvedFile.StartsWith($fixtureBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing race-fixture deletion outside the workspace test root.' }
                    Remove-Item -LiteralPath $resolvedFile -Force
                }
                return $item
            }
            try { Update-CodexGuardTracker -Tracker $tracker }
            finally { Remove-Item Function:\Get-Item }
            $snapshot = Snapshot $tracker
            $hasObserved = $variant -eq 'observed-active'
            Check $(if ($hasObserved) { 1 } else { 0 }) $tracker.Files.Count "$variant open race preserves only unfinished work"
            Check $(if ($hasObserved) { 1 } else { 0 }) $snapshot.UnknownCount "$variant open race applies the correct conservative policy"
            Check $hasObserved $tracker.ReadErrors.ContainsKey($file.Path) "$variant open race does not retain an obsolete candidate error"
        }

        # A file may also disappear after its readable batch, before LastWriteTime is fetched.
        foreach ($variant in @('unobserved', 'newly-observed-active')) {
            $tracker = New-Case ('post-read-race-' + $variant)
            $file = File $tracker
            if ($variant -eq 'newly-observed-active') { Write-Session $file.Path $mainId 'post-read-turn' }
            else {
                $metadata = @{ type='session_meta'; timestamp=$now.ToString('o'); payload=@{ id=$mainId; source='app' } } | ConvertTo-Json -Depth 5 -Compress
                [IO.File]::WriteAllText($file.Path, ($metadata + "`n"), (New-Object Text.UTF8Encoding($false)))
            }
            $file.LastLength = [IO.FileInfo]::new($file.Path).Length
            $script:PostReadFile = $file.Path
            $script:PostReadInspections = 0
            function Get-Item {
                [CmdletBinding()]
                param([string]$LiteralPath)
                if ($LiteralPath -eq $script:PostReadFile) {
                    $script:PostReadInspections++
                    if ($script:PostReadInspections -eq 2) {
                        $resolvedFile = [IO.Path]::GetFullPath($LiteralPath)
                        $fixtureBase = [IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
                        if (-not $resolvedFile.StartsWith($fixtureBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing post-read-fixture deletion outside the workspace test root.' }
                        Remove-Item -LiteralPath $resolvedFile -Force
                    }
                }
                Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
            }
            try { Update-CodexGuardTracker -Tracker $tracker }
            finally { Remove-Item Function:\Get-Item }
            $snapshot = Snapshot $tracker
            $hasObserved = $variant -eq 'newly-observed-active'
            Check 2 $script:PostReadInspections "$variant exercises the final metadata-inspection race"
            Check $(if ($hasObserved) { 1 } else { 0 }) $tracker.Files.Count "$variant post-read race preserves only newly observed unfinished work"
            Check $(if ($hasObserved) { 1 } else { 0 }) $snapshot.UnknownCount "$variant post-read race resolves missing state in the same scan"
            Check $hasObserved $tracker.ReadErrors.ContainsKey($file.Path) "$variant post-read race reports only the unresolved active turn"
        }

        # A new physical file at a removed path must be discovered from byte zero.
        $tracker = New-Case 'reappearing-file'
        $old = File $tracker -kind 'Subagent'
        $old.Position = 50; $old.LastLength = 150; $old.InheritedRecordsRemaining = 7
        Update-CodexGuardTracker -Tracker $tracker
        Check 0 $tracker.Files.Count 'old absent child candidate is removed'
        Write-Session $old.Path $otherId 'new-main-turn'
        Update-CodexGuardTracker -Tracker $tracker -Discover
        $snapshot = Snapshot $tracker
        Check 1 $tracker.Files.Count 'a reappearing file is rediscovered'
        Check 'MainTask' $tracker.Files[$old.Path].TaskType 'replacement source does not inherit old child exemption'
        Check $otherId $tracker.Files[$old.Path].ThreadId 'replacement reads its own session identity'
        Check 0 $tracker.Files[$old.Path].InheritedRecordsRemaining 'replacement does not inherit an old replay boundary'
        Check 1 $snapshot.ActiveCount 'new main turn blocks shutdown'
        Check $false $snapshot.HasPendingReads 'replacement is read to completion'

        # Removing many candidates during iteration must not skip or corrupt a live file.
        $tracker = New-Case 'many-missing-files'
        for ($index = 0; $index -lt 35; $index++) {
            $file = File $tracker -name ('missing-{0:D2}.jsonl' -f $index) -kind 'Unknown'
            $file.LastLength = 101 + $index
        }
        $livePath = Join-Path $tracker.SessionsRoot 'zz-current.jsonl'
        Write-Session $livePath $otherId 'current-turn'
        Add-CodexGuardCandidateFile -Tracker $tracker -File (Microsoft.PowerShell.Management\Get-Item -LiteralPath $livePath)
        $tracker.ReadCursor = 17
        for ($scan = 0; $scan -lt 5; $scan++) { Update-CodexGuardTracker -Tracker $tracker }
        $snapshot = Snapshot $tracker
        Check 1 $tracker.Files.Count 'all absent candidates removed without enumeration corruption'
        Check $true $tracker.Files.ContainsKey($livePath) 'live file survives candidate cleanup'
        Check 1 $snapshot.ActiveCount 'live task is still observed after cleanup'
        Check 0 $snapshot.UnknownCount 'missing candidates leave no phantom blockers'

        # Removing a phantom candidate permits the ordinary idle-confirmation path.
        $tracker = New-Case 'cleanup-releases-idle'
        $file = File $tracker -kind 'Unknown'
        $file.LastLength = 100
        $runtime = New-CodexGuardRuntime -DryRun
        Set-CodexGuardArmed -Runtime $runtime -CurrentActiveCount 1
        $snapshot = Snapshot $tracker
        [void](Update-CodexGuardRuntime -Runtime $runtime -Snapshot $snapshot -AppAvailable $true -NowUtc $now -TotalGraceSeconds 90 -NativeShutdownSeconds 30)
        Check 'PausedUnknownState' $runtime.Phase 'phantom candidate reproduced the original blocked phase'
        Update-CodexGuardTracker -Tracker $tracker
        for ($index = 1; $index -le 3; $index++) {
            [void](Update-CodexGuardRuntime -Runtime $runtime -Snapshot (Snapshot $tracker) -AppAvailable $true -NowUtc $now.AddSeconds($index) -TotalGraceSeconds 90 -NativeShutdownSeconds 30)
        }
        Check 'GraceCountdown' $runtime.Phase 'cleanup allows the normal three-sample idle confirmation'
        Check $false $runtime.ShutdownScheduled 'cleanup test never schedules a native shutdown'
        Check $true $runtime.DryRun 'runtime integration remains explicitly simulated'

        # Every task-owned file diagnostic has an identifiable UI row even without a turn ID.
        $tracker = New-Case 'diagnostic-labels'
        $file = File $tracker
        $file.LastLength = 100
        $snapshot = Snapshot $tracker
        $rows = @(Get-CodexGuardTaskManagerRows -Snapshot $snapshot -ThreadTitles @{ $mainId='Known local task' })
        Check 1 $rows.Count 'one pending file produces one UI row'
        Check $true ($rows[0].Title -match 'Known local task') 'pending row includes the authored task title'
        Check $mainId $rows[0].ThreadId 'pending row retains its exact thread identity'
        Check $true ($rows[0].Tooltip -match [regex]::Escape($mainId)) 'pending tooltip exposes exact ownership'
        $rows = @(Get-CodexGuardTaskManagerRows -Snapshot $snapshot)
        Check $true ($rows[0].Title -match $mainId.Substring(0,8)) 'untitled pending row includes an identifiable thread ID'
        $tracker.ReadErrors[$file.Path] = 'Fixture read error'
        $rows = @(Get-CodexGuardTaskManagerRows -Snapshot (Snapshot $tracker) -ThreadTitles @{ $mainId='Known local task' })
        Check $true ($rows[0].Title -match 'Known local task') 'file error row includes the authored task title'
        Check $true ($rows[0].Tooltip -match 'Fixture read error') 'file error tooltip retains the diagnostic reason'
        $tracker = New-Case 'global-discovery-error'
        $tracker.GlobalErrors['discovery'] = 'Fixture global discovery failure'
        $snapshot = Snapshot $tracker
        $rows = @(Get-CodexGuardTaskManagerRows -Snapshot $snapshot -ThreadTitles @{ $mainId='Unrelated task' })
        Check 1 $snapshot.UnknownCount 'global discovery errors still block shutdown'
        Check $false ($rows[0].Title -match 'Unrelated task') 'global errors do not invent task ownership'
        Check '' $rows[0].ThreadId 'global errors retain empty task identity'
        return $script:MissingPassed
    } $testRoot
    Write-Output "PASS: $passed missing-session cleanup and task-label assertions. No native guard or shutdown was invoked."
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $base = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside the fixture temporary directory.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
