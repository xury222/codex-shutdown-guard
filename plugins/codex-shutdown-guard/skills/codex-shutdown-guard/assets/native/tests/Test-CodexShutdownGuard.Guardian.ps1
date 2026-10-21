[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CodexShutdownGuard.Core.psm1') -Force -PassThru
$testRoot = Join-Path $env:TEMP ('CodexGuardGuardian_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
try {
    $passed = & $module {
        param($testRoot)
        $script:GuardianPassed = 0
        $now = [datetime]::UtcNow
        $utf8 = New-Object Text.UTF8Encoding($false)
        $guardianSource = @{ subagent = @{ other = 'guardian' } }
        function Check($expected, $actual, [string]$name) {
            if ($expected -ne $actual) { throw "FAILED: $name; expected [$expected], got [$actual]." }
            $script:GuardianPassed++
        }
        function New-Case([string]$name) {
            $home = Join-Path $testRoot $name
            $sessions = Join-Path $home 'sessions'
            [void](New-Item -ItemType Directory -Path $sessions -Force)
            $path = Join-Path $sessions 'rollout-11111111-1111-1111-1111-111111111111.jsonl'
            $tracker = New-CodexGuardTracker -CodexHome $home -BaselineUtc $now.AddHours(-1)
            $file = New-CodexGuardFileState $path
            $file.LastWriteUtc = $now
            $tracker.Files[$path] = $file
            return [pscustomobject]@{ Tracker = $tracker; File = $file; Path = $path }
        }
        function Meta-Line($source, [string]$threadSource = 'guardian_review') {
            # Metadata predates the tracker baseline, as real historical sessions do.
            return ([ordered]@{
                payload = [ordered]@{ source = $source; thread_source = $threadSource; cwd = 'C:\ExampleProject'; base_instructions = 'PRIVATE_INSTRUCTIONS_DO_NOT_RETAIN' }
                timestamp = $now.AddDays(-2).ToString('o'); type = 'session_meta'
            } | ConvertTo-Json -Depth 12 -Compress)
        }
        function Context-Line([string]$turnId) {
            return ([ordered]@{ payload = [ordered]@{ cwd = 'C:\ExampleProject'; turn_id = $turnId }; timestamp = $now.ToString('o'); type = 'turn_context' } | ConvertTo-Json -Depth 5 -Compress)
        }
        function Task-Line([string]$type, [string]$turnId) {
            return ([ordered]@{ payload = [ordered]@{ turn_id = $turnId; type = $type }; type = 'event_msg'; timestamp = $now.ToString('o') } | ConvertTo-Json -Depth 5 -Compress)
        }
        function Send($case, [string]$line) { Register-CodexGuardLine -Tracker $case.Tracker -FileState $case.File -Line $line }
        function Save-Lines($case, [string[]]$lines, [string]$tail = '') { [IO.File]::WriteAllText($case.Path, (($lines -join "`n") + "`n" + $tail), $utf8) }
        function Snapshot($case) { return Get-CodexGuardSnapshot -Tracker $case.Tracker -NowUtc $now }
        function Check-Protected($case, [string]$name) {
            $snapshot = Snapshot $case
            Check $true ($snapshot.UnknownCount -gt 0) "$name remains a blocking unknown"
            $runtime = New-CodexGuardRuntime -DryRun
            Set-CodexGuardArmed -Runtime $runtime -CurrentObservedTaskCount 1
            $actions = @(Update-CodexGuardRuntime -Runtime $runtime -Snapshot $snapshot -AppAvailable $true -NowUtc $now -TotalGraceSeconds 180 -NativeShutdownSeconds 30)
            Check 'PausedUnknownState' $runtime.Phase "$name pauses automatic shutdown"
            Check $false ('ScheduleShutdown' -in $actions) "$name emits no shutdown schedule"
        }

        $parsed = New-Case 'parse-old-meta'
        $metaLine = Meta-Line $guardianSource
        $metadata = [CodexGuardJsonReader]::Parse($metaLine)
        Register-CodexGuardLine -Tracker $parsed.Tracker -FileState $parsed.File -Metadata $metadata
        Send $parsed (Context-Line 'auto-compact-0')
        Send $parsed (Context-Line 'auto-compact-123')
        Check 0 (Snapshot $parsed).TaskCount 'old exact guardian metadata excludes automatic compact contexts'
        Check 0 (Snapshot $parsed).UnknownCount 'guardian automatic compact contexts create no phantom unknown'
        Check 0 $parsed.Tracker.UnknownTurns.Count 'excluded contexts are not retained in UnknownTurns'
        Check $false (($metadata | ConvertTo-Json -Depth 15 -Compress) -match 'PRIVATE_INSTRUCTIONS_DO_NOT_RETAIN') 'metadata parser never retains base instructions'

        $streamed = New-Case 'streamed-old-meta'
        Save-Lines $streamed @($metaLine, (Context-Line 'auto-compact-7'))
        $batch = [CodexGuardJsonReader]::ReadFile($streamed.Path, 0, 5000)
        Check 2 $batch.Events.Count 'streaming reader extracts metadata and context'
        Check $false $batch.Malformed 'guardian source object is valid streaming metadata'
        Check $false $batch.Incomplete 'complete guardian fixture has no partial record'
        foreach ($event in $batch.Events) { Register-CodexGuardLine -Tracker $streamed.Tracker -FileState $streamed.File -Metadata $event }
        $streamed.File.Position = $batch.Position
        $streamed.File.LastLength = $batch.Length
        Check 0 (Snapshot $streamed).UnknownCount 'streamed historical guardian metadata is recognized'
        Check $false (($batch.Events | ConvertTo-Json -Depth 15 -Compress) -match 'PRIVATE_INSTRUCTIONS_DO_NOT_RETAIN') 'streaming reader retains no private instructions'

        $sourceCases = @(
            @{ Name = 'desktop'; Source = 'vscode' },
            @{ Name = 'cli'; Source = 'cli' },
            @{ Name = 'unknown-string'; Source = 'future_source' },
            @{ Name = 'guardian-string'; Source = 'guardian' },
            @{ Name = 'spawn'; Source = @{ subagent = @{ spawn = @{ parent_thread_id = '22222222-2222-2222-2222-222222222222'; depth = 1 } } } },
            @{ Name = 'review'; Source = @{ subagent = 'review' } },
            @{ Name = 'other-review'; Source = @{ subagent = @{ other = 'review' } } },
            @{ Name = 'other-guardian-review'; Source = @{ subagent = @{ other = 'guardian_review' } } },
            @{ Name = 'other-guardian-suffix'; Source = @{ subagent = @{ other = 'guardian-worker' } } },
            @{ Name = 'other-guardian-case'; Source = @{ subagent = @{ other = 'Guardian' } } },
            @{ Name = 'unknown-object'; Source = @{ future = 'guardian' } },
            @{ Name = 'null-source'; Source = $null }
        )
        foreach ($sourceCase in $sourceCases) {
            $case = New-Case $sourceCase.Name
            Send $case (Meta-Line $sourceCase.Source)
            Send $case (Context-Line 'auto-compact-0')
            $snapshot = Snapshot $case
            Check 1 $snapshot.TaskCount "$($sourceCase.Name) automatic-looking context is still tracked"
            Check $true ($snapshot.UnknownCount -gt 0) "$($sourceCase.Name) source cannot gain guardian exemption"
        }
        $noMeta = New-Case 'missing-meta'
        Send $noMeta (Context-Line 'auto-compact-0')
        Check 1 (Snapshot $noMeta).TaskCount 'automatic-looking context with missing metadata remains tracked'
        Check 1 (Snapshot $noMeta).UnknownCount 'missing metadata fails closed'

        foreach ($sourceCase in @($sourceCases | Where-Object { $_.Name -in @('desktop','cli','spawn','review','other-review') })) {
            $case = New-Case ($sourceCase.Name + '-active')
            Send $case (Meta-Line $sourceCase.Source)
            Send $case (Task-Line 'task_started' 'real-active-turn')
            Send $case (Context-Line 'real-active-turn')
            Check 1 (Snapshot $case).ActiveCount "$($sourceCase.Name) real task remains active and blocking"
            Check 0 (Snapshot $case).UnknownCount "$($sourceCase.Name) started task remains recognized"
        }

        foreach ($turnId in @('real-context-turn','auto-compact-','auto-compact--1','auto-compact-1x','xauto-compact-1','auto-compact-1-suffix')) {
            $case = New-Case ('near-id-' + $script:GuardianPassed)
            Send $case $metaLine
            Send $case (Context-Line $turnId)
            Check 1 (Snapshot $case).UnknownCount "guardian context [$turnId] is not an exact automatic compact ID"
        }

        $guardian = New-Case 'real-guardian-turn'
        Send $guardian $metaLine
        Send $guardian (Task-Line 'task_started' 'real-guardian-turn')
        Send $guardian (Context-Line 'real-guardian-turn')
        Check 1 (Snapshot $guardian).ActiveCount 'real started guardian work still blocks'
        Check 0 (Snapshot $guardian).UnknownCount 'real guardian work is recognized rather than hidden'
        Send $guardian (Task-Line 'task_complete' 'real-guardian-turn')
        Check 0 (Snapshot $guardian).TaskCount 'real guardian completion clears its exact task'
        Send $guardian (Task-Line 'turn_started' 'guardian-abort-turn')
        Send $guardian (Context-Line 'guardian-abort-turn')
        Check 1 (Snapshot $guardian).ActiveCount 'guardian second turn remains active'
        Send $guardian (Task-Line 'turn_aborted' 'guardian-abort-turn')
        Check 0 (Snapshot $guardian).TaskCount 'real guardian abort clears its exact task'

        $startedCompact = New-Case 'explicitly-started-compact'
        Send $startedCompact $metaLine
        Send $startedCompact (Task-Line 'task_started' 'auto-compact-12')
        Send $startedCompact (Context-Line 'auto-compact-12')
        Check 1 (Snapshot $startedCompact).ActiveCount 'explicitly started compact-looking turn is never suppressed'
        Check 'C:\ExampleProject' $startedCompact.Tracker.Turns['auto-compact-12'].Cwd 'started compact-looking context still binds project metadata'
        Send $startedCompact (Task-Line 'task_complete' 'auto-compact-12')
        Check 0 (Snapshot $startedCompact).TaskCount 'explicit compact-looking terminal event remains recognized'

        $spoofed = New-Case 'source-only-on-non-meta'
        $notMeta = ([ordered]@{ type = 'response_item'; timestamp = $now.ToString('o'); payload = @{ type = 'message'; source = $guardianSource; thread_source = 'guardian_review'; content = @(@{ text = 'PRIVATE_BODY_DO_NOT_RETAIN' }) } } | ConvertTo-Json -Depth 12 -Compress)
        Send $spoofed $notMeta
        Send $spoofed (Context-Line 'auto-compact-0')
        Check 1 (Snapshot $spoofed).UnknownCount 'source on a response item cannot classify a file as guardian'
        Check $false (([CodexGuardJsonReader]::Parse($notMeta) | ConvertTo-Json -Depth 15 -Compress) -match 'PRIVATE_BODY_DO_NOT_RETAIN') 'response body never enters metadata'

        $large = New-Case 'large-private-meta'
        $largeLine = $metaLine.Replace('PRIVATE_INSTRUCTIONS_DO_NOT_RETAIN', ('PRIVATE_LARGE_BODY_' + ('x' * 1000000)))
        Save-Lines $large @($largeLine, (Context-Line 'auto-compact-9'))
        Update-CodexGuardTracker -Tracker $large.Tracker
        Check 0 (Snapshot $large).UnknownCount 'large skipped instructions do not break source recognition'
        Check $false (($large.Tracker | ConvertTo-Json -Depth 15 -Compress) -match 'PRIVATE_LARGE_BODY_') 'large instructions never enter task state'

        $malformed = New-Case 'guardian-malformed'
        Save-Lines $malformed @($metaLine, (Context-Line 'auto-compact-0'), '{"private_text":"PRIVATE_PARSE_ERROR_DO_NOT_RETAIN",broken')
        Update-CodexGuardTracker -Tracker $malformed.Tracker
        Check 0 (Snapshot $malformed).TaskCount 'guardian malformed file does not revive a synthetic task'
        Check-Protected $malformed 'malformed guardian record'
        Check $false (((Snapshot $malformed) | ConvertTo-Json -Depth 15 -Compress) -match 'PRIVATE_PARSE_ERROR_DO_NOT_RETAIN') 'malformed error reports expose no private record content'

        $partial = New-Case 'guardian-partial'
        Save-Lines $partial @($metaLine, (Context-Line 'auto-compact-0')) '{"type":"response_item","payload":'
        Update-CodexGuardTracker -Tracker $partial.Tracker
        Check 0 (Snapshot $partial).TaskCount 'partial guardian file does not revive a synthetic task'
        Check-Protected $partial 'partial guardian record'
        [IO.File]::AppendAllText($partial.Path, '{"type":"message"}}' + "`n", $utf8)
        Update-CodexGuardTracker -Tracker $partial.Tracker
        Check 0 (Snapshot $partial).UnknownCount 'completed guardian partial record clears only its read uncertainty'

        $backlog = New-Case 'guardian-backlog'
        Send $backlog $metaLine
        Send $backlog (Context-Line 'auto-compact-0')
        $backlog.File.Position = 100
        $backlog.File.LastLength = 200
        Check $true (Snapshot $backlog).HasPendingReads 'guardian backlog remains explicit'
        Check-Protected $backlog 'unread guardian backlog'

        $unreadable = New-Case 'guardian-unreadable'
        Save-Lines $unreadable @($metaLine, (Context-Line 'auto-compact-0'))
        Update-CodexGuardTracker -Tracker $unreadable.Tracker
        $locked = [IO.File]::Open($unreadable.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            Update-CodexGuardTracker -Tracker $unreadable.Tracker
            Check-Protected $unreadable 'unreadable guardian file'
        }
        finally { $locked.Dispose() }
        Update-CodexGuardTracker -Tracker $unreadable.Tracker
        Check 0 (Snapshot $unreadable).UnknownCount 'recoverable guardian read failure clears after a successful retry'

        $replaced = New-Case 'guardian-truncated-stream'
        Save-Lines $replaced @($metaLine, (Context-Line 'auto-compact-0'))
        Update-CodexGuardTracker -Tracker $replaced.Tracker
        Check 0 (Snapshot $replaced).UnknownCount 'guardian source is recognized before streaming truncation'
        Check $true $replaced.File.IsGuardianSession 'streaming fixture starts with a confirmed guardian source'
        Save-Lines $replaced @((Context-Line 'auto-compact-1'))
        Update-CodexGuardTracker -Tracker $replaced.Tracker
        Check $false $replaced.File.IsGuardianSession 'streaming truncation resets the previous guardian source'
        Check 1 (Snapshot $replaced).UnknownCount 'shortened file without session metadata remains protected'

        $deltaReplaced = New-Case 'guardian-truncated-delta'
        Save-Lines $deltaReplaced @($metaLine, (Context-Line 'auto-compact-0'))
        Update-CodexGuardTracker -Tracker $deltaReplaced.Tracker
        Check 0 (Snapshot $deltaReplaced).UnknownCount 'guardian source is recognized before delta truncation'
        Check $true $deltaReplaced.File.IsGuardianSession 'delta fixture starts with a confirmed guardian source'
        Save-Lines $deltaReplaced @((Context-Line 'auto-compact-2'))
        foreach ($line in @(Read-CodexGuardFileDelta -FileState $deltaReplaced.File)) { Send $deltaReplaced $line }
        Check $false $deltaReplaced.File.IsGuardianSession 'legacy delta truncation resets the previous guardian source'
        Check 1 (Snapshot $deltaReplaced).UnknownCount 'legacy delta reader protects a shortened file with missing source'

        return $script:GuardianPassed
    } $testRoot
    Write-Output "PASS: $passed guardian regression assertions. Native shutdown was not invoked."
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedRoot -Leaf) -notlike 'CodexGuardGuardian_*') { throw 'Refusing cleanup outside isolated test root.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
}
