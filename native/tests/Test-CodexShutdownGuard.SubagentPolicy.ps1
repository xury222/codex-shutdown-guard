[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CodexShutdownGuard.Core.psm1') -Force -PassThru
$testRoot = Join-Path $env:TEMP ('CodexGuardSubagentPolicy_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
try {
    $passed = & $module {
        param($testRoot)
        $script:PolicyPassed = 0
        $now = [datetime]::UtcNow
        $parentId = '11111111-1111-1111-1111-111111111111'
        $childId = '22222222-2222-2222-2222-222222222222'
        $otherMainId = '33333333-3333-3333-3333-333333333333'
        $source = @{ subagent=@{ thread_spawn=@{ parent_thread_id=$parentId; agent_path='/root/worker'; depth=1 } } }
        function Check($expected, $actual, [string]$name) {
            if ($expected -ne $actual) { throw "FAILED: $name; expected [$expected], got [$actual]." }
            $script:PolicyPassed++
        }
        function New-Case([string]$name) {
            $home = Join-Path $testRoot $name
            [void](New-Item -ItemType Directory -Path (Join-Path $home 'sessions') -Force)
            return New-CodexGuardTracker -CodexHome $home -BaselineUtc $now.AddHours(-1)
        }
        function Send($tracker, $file, [string]$type, [string]$turnId, [datetime]$at = $now) {
            $line = @{ type='event_msg'; timestamp=$at.ToString('o'); payload=@{ type=$type; turn_id=$turnId } } | ConvertTo-Json -Depth 6 -Compress
            Register-CodexGuardLine -Tracker $tracker -FileState $file -Line $line
        }
        function File($tracker, [string]$id, $sessionSource, [hashtable]$extra = @{}) {
            $file = New-CodexGuardFileState (Join-Path $tracker.SessionsRoot "rollout-$id.jsonl")
            $tracker.Files[$file.Path] = $file
            $payload = @{ id=$id; source=$sessionSource; cwd='C:\PolicyFixture' }
            foreach ($key in $extra.Keys) { $payload[$key] = $extra[$key] }
            $line = @{ type='session_meta'; timestamp=$now.AddDays(-1).ToString('o'); payload=$payload } | ConvertTo-Json -Depth 10 -Compress
            Register-CodexGuardLine -Tracker $tracker -FileState $file -Line $line
            return $file
        }
        function Snapshot($tracker, [datetime]$at = $now, [string[]]$ignored = @()) {
            return Get-CodexGuardSnapshot -Tracker $tracker -NowUtc $at -InactiveSeconds 3600 -IgnoredTurnIds $ignored
        }
        function Tick($runtime, $snapshot, [datetime]$at) {
            return @(Update-CodexGuardRuntime -Runtime $runtime -Snapshot $snapshot -AppAvailable $true -NowUtc $at -TotalGraceSeconds 90 -NativeShutdownSeconds 30)
        }

        # Every authoritative descendant representation must receive the same policy.
        $variants = @(
            @{ Name='nested-spawn'; Source=$source; Extra=@{}; Type='Subagent' },
            @{ Name='legacy-spawn'; Source=@{ subagent=@{ spawn=@{ parent_thread_id=$parentId; depth=2 } } }; Extra=@{}; Type='Subagent' },
            @{ Name='thread-source'; Source='future_source'; Extra=@{ thread_source='subagent' }; Type='Subagent' },
            @{ Name='parent-only'; Source='app'; Extra=@{ parent_thread_id=$parentId }; Type='Subagent' },
            @{ Name='review'; Source=@{ subagent='review' }; Extra=@{}; Type='InternalReview' },
            @{ Name='guardian'; Source=@{ subagent=@{ other='guardian' } }; Extra=@{ thread_source='guardian_review' }; Type='InternalReview' }
        )
        foreach ($variant in $variants) {
            $tracker = New-Case $variant.Name
            $file = File $tracker $childId $variant.Source $variant.Extra
            Send $tracker $file 'task_started' 'child-turn'
            $snapshot = Snapshot $tracker
            Check $variant.Type $snapshot.TaskEntries[0].TaskType "$($variant.Name) is authoritatively classified"
            Check 1 $snapshot.TaskCount "$($variant.Name) remains visible"
            Check 1 $snapshot.ObservedActiveCount "$($variant.Name) remains observable as active"
            Check 0 $snapshot.ActiveCount "$($variant.Name) cannot block shutdown"
            Check $false $snapshot.TaskEntries[0].BlocksShutdown "$($variant.Name) entry reports its non-blocking policy"
            Check $false $snapshot.TaskEntries[0].IsIgnored "$($variant.Name) needs no manual ignore"
            Check 0 $snapshot.IgnoredCount "$($variant.Name) does not alter manual ignores"
            $stateText = Get-CodexGuardTaskStateLabel $snapshot.TaskEntries[0]
            Check $true ($stateText.EndsWith(([string][char]0x4e0d + [char]0x963b + [char]0x585e))) "$($variant.Name) UI describes the non-blocking policy"
            Check 0 $snapshot.ObservedShutdownTaskCount "$($variant.Name) cannot satisfy first-main-task observation"
            $stale = Get-CodexGuardSnapshot -Tracker $tracker -NowUtc $now.AddMinutes(2) -InactiveSeconds 60
            Check 'StaleTurn' $stale.TaskEntries[0].Kind "$($variant.Name) retains stale diagnosis"
            Check 1 $stale.ObservedUnknownCount "$($variant.Name) stale uncertainty remains observable"
            Check 0 $stale.UnknownCount "$($variant.Name) stale uncertainty cannot block shutdown"
            Check $false $stale.TaskEntries[0].BlocksShutdown "$($variant.Name) stale entry remains non-blocking"
        }

        # The parent completion is the boundary even if a worker never emits completion.
        $tracker = New-Case 'parent-boundary'
        $parent = File $tracker $parentId 'vscode' @{ thread_source='user' }
        $child = File $tracker $childId $source
        Send $tracker $parent 'task_started' 'parent-turn'
        Send $tracker $child 'task_started' 'child-turn'
        $snapshot = Snapshot $tracker
        Check 1 $snapshot.ActiveCount 'only the main task blocks in a mixed snapshot'
        Check 2 $snapshot.TaskCount 'both main and worker remain visible'
        Check 1 $snapshot.ObservedShutdownTaskCount 'only the main task is observed for arming'
        Check 'parent-turn' $snapshot.ActiveTurns[0].TurnId 'blocking active turns retain the parent identity'
        $ignored = Snapshot $tracker $now @('parent-turn')
        Check 0 $ignored.ActiveCount 'manual parent ignore still works with a worker running'
        Check 1 $ignored.ObservedShutdownTaskCount 'ignored main task still counts as observed work'
        Check 1 $ignored.IgnoredCount 'manual ignore ownership stays explicit'
        $runtime = New-CodexGuardRuntime -DryRun
        Set-CodexGuardArmed -Runtime $runtime -CurrentActiveCount $snapshot.ActiveCount -CurrentObservedTaskCount $snapshot.ObservedShutdownTaskCount
        Send $tracker $parent 'task_complete' 'parent-turn'
        $childOnly = Snapshot $tracker
        Check 1 $childOnly.TaskCount 'unfinished worker remains visible after the parent completes'
        Check 0 $childOnly.ActiveCount 'unfinished worker cannot delay the completed parent'
        [void](Tick $runtime $childOnly $now)
        [void](Tick $runtime $childOnly $now.AddSeconds(1))
        $actions = Tick $runtime $childOnly $now.AddSeconds(2)
        Check $true ('GraceStarted' -in $actions) 'parent completion starts grace after three stable idle samples'
        Send $tracker $child 'task_started' 'child-new-turn' $now.AddSeconds(3)
        $actions = Tick $runtime (Snapshot $tracker $now.AddSeconds(4)) $now.AddSeconds(4)
        Check 'GraceCountdown' $runtime.Phase 'new worker activity cannot reset grace'
        Check $false ('AbortShutdown' -in $actions) 'new worker activity emits no abort action during grace'
        $actions = Tick $runtime (Snapshot $tracker $now.AddSeconds(62)) $now.AddSeconds(62)
        Check $true ('ScheduleShutdown' -in $actions) 'completed parent reaches native countdown despite worker activity'
        Send $tracker $child 'task_started' 'child-another-turn' $now.AddSeconds(63)
        $actions = Tick $runtime (Snapshot $tracker $now.AddSeconds(64)) $now.AddSeconds(64)
        Check 'NativeCountdown' $runtime.Phase 'new worker activity cannot cancel native countdown'
        Check $false ('AbortShutdown' -in $actions) 'new worker activity emits no abort action during native countdown'
        Send $tracker $parent 'task_started' 'parent-next-turn' $now.AddSeconds(65)
        $actions = Tick $runtime (Snapshot $tracker $now.AddSeconds(66)) $now.AddSeconds(66)
        Check $true ('AbortShutdown' -in $actions) 'a new main-task turn still cancels native countdown'
        Check 'WaitingTasks' $runtime.Phase 'new main work remains blocking'

        $onlyChildren = New-Case 'child-only-first-task'
        $onlyChild = File $onlyChildren $childId $source
        Send $onlyChildren $onlyChild 'task_started' 'only-child'
        $snapshot = Snapshot $onlyChildren
        $unseen = New-CodexGuardRuntime -DryRun
        Set-CodexGuardArmed -Runtime $unseen -CurrentActiveCount $snapshot.ActiveCount -CurrentObservedTaskCount $snapshot.ObservedShutdownTaskCount
        foreach ($offset in @(0,1,2,100)) { [void](Tick $unseen $snapshot $now.AddSeconds($offset)) }
        Check $false $unseen.SeenActive 'a child-only snapshot cannot satisfy main-work observation'
        Check 'WaitingFirstTask' $unseen.Phase 'arming while only workers exist waits for the first main task'
        Check $false $unseen.ShutdownScheduled 'only workers never initiate a shutdown'

        # File-local uncertainty inherits the confirmed owning session, even without a turn.
        foreach ($problem in @('ContextOnly','ReadError','Partial','PendingRead','InheritedHistory')) {
            foreach ($hasTask in @($false,$true)) {
                $tracker = New-Case ("child-$problem-$hasTask")
                $file = File $tracker $childId $source
                if ($hasTask) { Send $tracker $file 'task_started' 'uncertain-child' }
                switch ($problem) {
                    'ContextOnly' {
                        if (-not $hasTask) {
                            $context = @{ type='turn_context'; timestamp=$now.ToString('o'); payload=@{ turn_id='uncertain-child' } } | ConvertTo-Json -Depth 6 -Compress
                            Register-CodexGuardLine -Tracker $tracker -FileState $file -Line $context
                        }
                        else { $tracker.ReadErrors[$file.Path] = 'Fixture read failure.' }
                    }
                    'ReadError' { $tracker.ReadErrors[$file.Path] = 'Fixture read failure.' }
                    'Partial' { $file.Partial = 'pending' }
                    'PendingRead' { $file.Position = 100; $file.LastLength = 200 }
                    'InheritedHistory' { $file.InheritedRecordsRemaining = 2 }
                }
                $snapshot = Snapshot $tracker
                Check 0 $snapshot.ActiveCount "$problem with task=$hasTask is not a child blocker"
                Check 0 $snapshot.UnknownCount "$problem with task=$hasTask cannot block through unknown items"
                Check $true ($snapshot.ObservedUnknownCount -gt 0) "$problem with task=$hasTask remains diagnosable"
                Check $false (@($snapshot.AllUnknownItems | Where-Object { $_.BlocksShutdown }).Count -gt 0) "$problem with task=$hasTask reports no blocking unknown"
                $rows = @(Get-CodexGuardTaskManagerRows -Snapshot $snapshot)
                Check 1 $rows.Count "$problem with task=$hasTask remains visible as one diagnostic row"
                Check 'Subagent' $rows[0].TaskType "$problem with task=$hasTask UI retains confirmed child ownership"
                Check $true ($rows[0].StateText.EndsWith(([string][char]0x4e0d + [char]0x963b + [char]0x585e))) "$problem with task=$hasTask UI describes a non-blocking diagnosis"
                if ($problem -eq 'PendingRead') {
                    Check $true $snapshot.HasPendingReads 'child pending read remains observable for replay bookkeeping'
                    Check 100 $snapshot.HistoryBytesRemaining 'child unread bytes remain observable for diagnosis'
                }
            }
        }

        # Exemption requires source metadata; neither unknown files nor global discovery errors qualify.
        foreach ($kind in @('Main','Unknown')) {
            $tracker = New-Case ("protected-$kind")
            $sessionSource = if ($kind -eq 'Main') { 'vscode' } else { 'future_source' }
            $file = File $tracker $parentId $sessionSource
            Send $tracker $file 'task_started' 'protected-turn'
            Check 1 (Snapshot $tracker).ActiveCount "$kind source task remains blocking"
            $tracker.ReadErrors[$file.Path] = 'Fixture read failure.'
            Check 1 (Snapshot $tracker).UnknownCount "$kind source read failure remains blocking"
        }
        $invalidSources = @(
            @{ Name='false'; Value=$false },
            @{ Name='number'; Value=0 },
            @{ Name='empty'; Value='' },
            @{ Name='whitespace'; Value='  ' },
            @{ Name='array'; Value=@('review') },
            @{ Name='empty-object'; Value=@{} },
            @{ Name='nested-array'; Value=@(@{ subagent='review' }) }
        )
        foreach ($invalidSource in $invalidSources) {
            $tracker = New-Case ('invalid-subagent-' + $invalidSource.Name)
            $file = File $tracker $parentId @{ subagent=$invalidSource.Value }
            Send $tracker $file 'task_started' 'unclassified-turn'
            $snapshot = Snapshot $tracker
            Check 'Unknown' $snapshot.TaskEntries[0].TaskType "$($invalidSource.Name) is not a valid subagent discriminator"
            Check 1 $snapshot.ActiveCount "$($invalidSource.Name) cannot exempt unclassified work"
            Check $true $snapshot.TaskEntries[0].BlocksShutdown "$($invalidSource.Name) remains conservatively blocking"
            Check 1 $snapshot.ObservedShutdownTaskCount "$($invalidSource.Name) retains unknown-main-work observation"
        }
        $nestedTracker = New-Case 'nested-source-is-not-authority'
        $nestedFile = File $nestedTracker $parentId @{ future=@{ subagent='review' } }
        Send $nestedTracker $nestedFile 'task_started' 'nested-unclassified-turn'
        Check 'Unknown' (Snapshot $nestedTracker).TaskEntries[0].TaskType 'subagent text nested under an unrelated source is not authority'
        Check 1 (Snapshot $nestedTracker).ActiveCount 'unrelated nested source metadata cannot exempt a task'
        $global = New-Case 'global-errors'
        $global.GlobalErrors['DiscoveryIncomplete'] = 'Fixture discovery still incomplete.'
        Check 1 (Snapshot $global).UnknownCount 'global discovery failure remains blocking'
        Check 0 (Snapshot $global).TaskCount 'global discovery uncertainty does not invent a task'
        $twoMains = New-Case 'all-main-tasks'
        $firstMain = File $twoMains $parentId 'vscode'
        $secondMain = File $twoMains $otherMainId 'app'
        Send $twoMains $firstMain 'task_started' 'main-one'
        Send $twoMains $secondMain 'task_started' 'main-two'
        Check 2 (Snapshot $twoMains).ActiveCount 'independent user main tasks continue to block until completion'
        Check 2 (Snapshot $twoMains).ObservedShutdownTaskCount 'all independent main tasks count as observed work'
        return $script:PolicyPassed
    } $testRoot
    Write-Output "PASS: $passed subagent shutdown policy assertions. Native shutdown was not invoked."
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedRoot -Leaf) -notlike 'CodexGuardSubagentPolicy_*') { throw 'Refusing cleanup outside isolated test root.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
}
