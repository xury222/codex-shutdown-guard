[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CodexShutdownGuard.Core.psm1') -Force -PassThru
$testRoot = Join-Path $env:TEMP ('CodexGuardIdentity_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
try {
    $passed = & $module {
        param($testRoot)
        $script:IdentityPassed = 0
        $now = [datetime]::UtcNow
        $utf8 = New-Object Text.UTF8Encoding($false)
        $mainId = '11111111-1111-1111-1111-111111111111'
        $childId = '22222222-2222-2222-2222-222222222222'
        $suffixId = '33333333-3333-3333-3333-333333333333'
        function Check($expected, $actual, [string]$name) {
            if ($expected -ne $actual) { throw "FAILED: $name; expected [$expected], got [$actual]." }
            $script:IdentityPassed++
        }
        function New-Case([string]$name) {
            $home = Join-Path $testRoot $name
            $sessions = Join-Path $home 'sessions'
            [void](New-Item -ItemType Directory -Path $sessions -Force)
            $tracker = New-CodexGuardTracker -CodexHome $home -BaselineUtc $now.AddHours(-2)
            return [pscustomobject]@{ Tracker=$tracker; Sessions=$sessions }
        }
        function New-File($case, [string]$name) {
            $file = New-CodexGuardFileState (Join-Path $case.Sessions $name)
            $file.LastWriteUtc = $now.AddHours(-1)
            $case.Tracker.Files[$file.Path] = $file
            return $file
        }
        function Meta($id, $source, [hashtable]$extra = @{}) {
            $payload = @{ id=$id; source=$source; cwd='D:\Fixture'; base_instructions='PRIVATE_INSTRUCTIONS_DO_NOT_RETAIN'; messages=@(@{ content='PRIVATE_BODY_DO_NOT_RETAIN' }) }
            foreach ($key in $extra.Keys) { $payload[$key] = $extra[$key] }
            return (@{ timestamp=$now.AddDays(-2).ToString('o'); type='session_meta'; payload=$payload } | ConvertTo-Json -Depth 12 -Compress)
        }
        function Event([string]$type, [string]$turnId, [datetime]$when = $now) {
            return (@{ timestamp=$when.ToString('o'); type='event_msg'; payload=@{ type=$type; turn_id=$turnId } } | ConvertTo-Json -Depth 4 -Compress)
        }
        function Context([string]$turnId) {
            return (@{ timestamp=$now.ToString('o'); type='turn_context'; payload=@{ turn_id=$turnId; cwd='D:\Fixture' } } | ConvertTo-Json -Depth 4 -Compress)
        }
        function Send($case, $file, [string]$line) { Register-CodexGuardLine -Tracker $case.Tracker -FileState $file -Line $line }
        function Snapshot($case, [datetime]$when = $now) { Get-CodexGuardSnapshot -Tracker $case.Tracker -NowUtc $when -InactiveSeconds 60 }
        function Write-Lines($file, [string[]]$lines) { [IO.File]::WriteAllText($file.Path, (($lines -join "`n") + "`n"), $utf8) }

        $case = New-Case 'suffix-title'
        $file = New-File $case "rollout-$($mainId)_$suffixId.jsonl"
        Send $case $file (Meta $mainId 'vscode' @{ thread_source='user' })
        Send $case $file (Event 'task_started' 'main-turn')
        $entry = (Snapshot $case).TaskEntries[0]
        Check $mainId $entry.ThreadId 'session metadata ID outranks trailing filename UUID'
        Check 'MainTask' $entry.TaskType 'desktop user source is a main task'
        Check 'D:\Fixture' $entry.Cwd 'historical metadata supplies project before first context'
        $titles = @{ $mainId='真实主任务标题'; $suffixId='错误后缀标题' }
        $row = @(Get-CodexGuardTaskManagerRows -Snapshot (Snapshot $case) -ThreadTitles $titles)[0]
        Check '真实主任务标题' $row.Title 'actual thread title resolves through authoritative metadata ID'
        Check '主任务' $row.TaskTypeLabel 'row exposes the task type'
        Check $true ($row.Tooltip -match [regex]::Escape($mainId)) 'tooltip retains complete identity'

        foreach ($source in @('cli','vscode','future_source',@{ future=@{ content='PRIVATE_FUTURE_BODY' } },$null,@{ subagent='review' },@{ subagent=@{ other='guardian' } })) {
            $parserLine = Meta $mainId $source
            $metadata = [CodexGuardJsonReader]::Parse($parserLine)
            Check $false (($metadata | ConvertTo-Json -Depth 12 -Compress) -match 'PRIVATE_') 'source union reader retains only declared metadata and no body'
        }

        $source = @{ subagent=@{ thread_spawn=@{ parent_thread_id=$mainId; agent_nickname='Meitner'; agent_role='reviewer'; agent_path='/root/task_identity'; depth=1; instructions='PRIVATE_NESTED_BODY' } } }
        $child = New-File $case "rollout-$childId.jsonl"
        Send $case $child (Meta $childId $source @{ thread_source='subagent' })
        Send $case $child (Event 'task_started' 'child-turn')
        $childEntry = @((Snapshot $case).TaskEntries | Where-Object { $_.ThreadId -eq $childId })[0]
        Check 'Subagent' $childEntry.TaskType 'spawn object identifies a child task'
        Check $mainId $childEntry.ParentThreadId 'nested metadata associates the parent thread'
        Check 'Meitner' $childEntry.AgentName 'nested nickname retained'
        Check 'reviewer' $childEntry.AgentRole 'nested role retained'
        Check '/root/task_identity' $childEntry.AgentPath 'nested task path retained'
        Check '子代理 task_identity（Meitner） · 真实主任务标题' (Get-CodexGuardTaskDisplayTitle $childEntry $titles) 'unnamed child leads with recorded task path and nickname, followed by parent title'
        Check $true ((Get-CodexGuardTaskDisplayTitle $childEntry $titles) -match 'task_identity') 'recorded task path makes the child work identifiable'
        $titles[$childId] = '真实子任务标题'
        Check '子代理 · 真实子任务标题' (Get-CodexGuardTaskDisplayTitle $childEntry $titles) 'actual child title remains primary with explicit type'
        Check $true ((Get-CodexGuardTaskTooltip $childEntry $titles) -match '父任务：真实主任务标题') 'child tooltip links parent title'
        Check $false (($case.Tracker | ConvertTo-Json -Depth 14 -Compress) -match 'PRIVATE_') 'tracker does not retain text bodies or private instructions'

        $guardian = New-File $case "guardian-$suffixId.jsonl"
        Send $case $guardian (Meta $suffixId @{ subagent=@{ other='guardian' } } @{ parent_thread_id=$mainId; thread_source='guardian_review' })
        Send $case $guardian (Event 'task_started' 'review-turn')
        $reviewEntry = @((Snapshot $case).TaskEntries | Where-Object { $_.ThreadId -eq $suffixId })[0]
        Check 'InternalReview' $reviewEntry.TaskType 'guardian actual lifecycle is explicitly labeled internal review'
        Check '内部审批 · 错误后缀标题' (Get-CodexGuardTaskDisplayTitle $reviewEntry $titles) 'internal review retains its actual indexed title'

        $fallbackCase = New-Case 'fallback-unknown'
        $fallback = New-File $fallbackCase "rollout-$suffixId.jsonl"
        Send $fallbackCase $fallback (Meta 'not-a-guid' 'future_source')
        Send $fallbackCase $fallback (Context 'unknown-turn')
        $unknownEntry = (Snapshot $fallbackCase).TaskEntries[0]
        Check $suffixId $unknownEntry.ThreadId 'invalid metadata ID falls back to filename'
        Check 'Unknown' $unknownEntry.TaskType 'unknown source is not invented as a main task'
        Check '未命名任务 33333333' (Get-CodexGuardTaskDisplayTitle $unknownEntry) 'unknown title retains short exact identity'

        $historyCase = New-Case 'inherited-history'
        $parent = New-File $historyCase "rollout-$mainId.jsonl"
        Send $historyCase $parent (Meta $mainId 'vscode' @{ thread_source='user' })
        Send $historyCase $parent (Event 'task_started' 'parent-current' $now.AddMinutes(-1))
        Write-Lines $parent @((Meta $mainId 'vscode' @{ thread_source='user' }), (Event 'task_started' 'parent-current' $now.AddMinutes(-1)))
        $inherited = New-File $historyCase "rollout-$childId.jsonl"
        $historyMeta = Meta $childId $source @{ thread_source='subagent'; subagent_history_start_ordinal=5 }
        # Ordinal 0 is the owning meta; ordinal 5 is the first own record.
        Write-Lines $inherited @($historyMeta, (Meta $mainId 'vscode'), (Event 'task_started' 'parent-current'))
        Update-CodexGuardTracker -Tracker $historyCase.Tracker
        Check $childId $inherited.ThreadId 'embedded parent metadata cannot replace owning child metadata'
        Check 2 $inherited.InheritedRecordsRemaining 'history record ordinal continues across file reads'
        Check $true ((Snapshot $historyCase).UnknownCount -gt 0) 'EOF inside inherited history remains blocking unknown'
        [IO.File]::AppendAllText($inherited.Path, ((Event 'task_complete' 'parent-current') + "`n" + '{"type":"response_item","payload":{"content":"PRIVATE_HISTORY"}}' + "`n" + '{"type":"thread_settings_applied","timestamp":"' + $now.ToString('o') + '"}' + "`n" + (Event 'task_started' 'child-own') + "`n"), $utf8)
        Update-CodexGuardTracker -Tracker $historyCase.Tracker
        Check 0 $inherited.InheritedRecordsRemaining 'own records begin at zero-based history boundary'
        Check 'Active' $historyCase.Tracker.Turns['parent-current'].State 'inherited completion cannot complete real parent task'
        Check $mainId $historyCase.Tracker.Turns['parent-current'].ThreadId 'inherited starts do not claim parent task for child'
        Check $childId $historyCase.Tracker.Turns['child-own'].ThreadId 'own task has authoritative child identity'
        Check 2 (Snapshot $historyCase).TaskCount 'parent and own child task are both visible'
        Send $historyCase $inherited (Meta $mainId 'vscode' @{ subagent_history_start_ordinal=100 })
        Check $childId $inherited.ThreadId 'later metadata replay cannot change first identity'
        Check 0 $inherited.InheritedRecordsRemaining 'later metadata replay cannot restart history skipping'
        $stale = Snapshot $historyCase $now.AddMinutes(3)
        $staleChild = @($stale.TaskEntries | Where-Object { $_.ThreadId -eq $childId })[0]
        Check 'Subagent' $staleChild.TaskType 'stale entries retain task classification'
        Check $mainId $staleChild.ParentThreadId 'stale entries retain parent relationship'
        Check 'Meitner' $staleChild.AgentName 'stale entries retain agent nickname'

        $reviewHistoryCase = New-Case 'internal-review-history'
        $reviewHistory = New-File $reviewHistoryCase "rollout-$childId.jsonl"
        Send $reviewHistoryCase $reviewHistory (Meta $childId @{ subagent=@{ other='guardian' } } @{ thread_source='guardian_review'; parent_thread_id=$mainId; subagent_history_start_ordinal=3 })
        Send $reviewHistoryCase $reviewHistory (Meta $mainId 'vscode')
        Send $reviewHistoryCase $reviewHistory (Event 'task_started' 'copied-parent-turn')
        Send $reviewHistoryCase $reviewHistory (Event 'task_started' 'own-review-turn')
        Check 1 (Snapshot $reviewHistoryCase).TaskCount 'internal review applies the same inherited-record boundary'
        Check $false $reviewHistoryCase.Tracker.Turns.ContainsKey('copied-parent-turn') 'internal review never registers inherited parent lifecycle'
        Check 'InternalReview' (Snapshot $reviewHistoryCase).TaskEntries[0].TaskType 'internal review keeps its exact classification after parent metadata'
        Check $true $reviewHistory.IsGuardianSession 'embedded parent metadata cannot unset exact guardian classification'

        $collisionCase = New-Case 'turn-collision'
        $first = New-File $collisionCase "rollout-$mainId.jsonl"
        $second = New-File $collisionCase "rollout-$childId.jsonl"
        Send $collisionCase $first (Meta $mainId 'vscode')
        Send $collisionCase $second (Meta $childId $source)
        Send $collisionCase $first (Context 'reused-turn')
        Send $collisionCase $second (Event 'task_started' 'reused-turn')
        Check 2 (Snapshot $collisionCase).TaskCount 'same turn ID in distinct sessions remains independently visible'
        Send $collisionCase $first (Event 'task_complete' 'reused-turn')
        Check 1 (Snapshot $collisionCase).TaskCount 'one session completion does not complete another same-ID turn'
        Check $childId (Snapshot $collisionCase).TaskEntries[0].ThreadId 'remaining same-ID task belongs to exact child'
        Send $collisionCase $second (Event 'task_complete' 'reused-turn')
        Check 0 (Snapshot $collisionCase).TaskCount 'scoped task completes after base unknown key is removed'

        $livenessCase = New-Case 'open-file-liveness'
        $live = New-File $livenessCase "rollout-$mainId.jsonl"
        Send $livenessCase $live (Meta $mainId 'vscode')
        Send $livenessCase $live (Event 'task_started' 'live' $now.AddMinutes(-3))
        Send $livenessCase $live ('{"type":"response_item","timestamp":"' + $now.ToString('o') + '","payload":{"type":"message","content":"PRIVATE_LIVE_BODY"}}')
        $liveEntry = (Snapshot $livenessCase).TaskEntries[0]
        Check 'ActiveTurn' $liveEntry.Kind 'recent non-lifecycle event prevents false stale with old Windows mtime'
        Check $now $liveEntry.LastUpdatedAtUtc 'last updated display uses the latest event timestamp'
        Send $livenessCase $live (Event 'token_count' '' $now.AddMinutes(-2))
        Check $now $live.LastEventAtUtc 'out-of-order older usage does not move liveness backward'
        Check $false (($livenessCase.Tracker | ConvertTo-Json -Depth 14 -Compress) -match 'PRIVATE_') 'liveness tracking does not retain message contents'

        $badCase = New-Case 'malformed-inherited-line'
        $bad = New-File $badCase "rollout-$childId.jsonl"
        Write-Lines $bad @((Meta $childId $source @{ subagent_history_start_ordinal=3 }), '{broken', (Meta $mainId 'vscode'), (Event 'task_started' 'own-after-malformed'))
        Update-CodexGuardTracker -Tracker $badCase.Tracker
        Check 0 $bad.InheritedRecordsRemaining 'malformed inherited record still occupies its record ordinal'
        Check $true $badCase.Tracker.Turns.ContainsKey('own-after-malformed') 'malformed history does not shift own lifecycle boundary'
        Check $true ((Snapshot $badCase).UnknownCount -gt 0) 'malformed history remains fail-closed despite a visible own task'
        Check $childId (Snapshot $badCase).TaskEntries[0].ThreadId 'malformed inherited parent metadata cannot replace identity'

        $discoveryCase = New-Case 'new-file-old-mtime'
        $discoveryPath = Join-Path $discoveryCase.Sessions "rollout-$mainId.jsonl"
        [IO.File]::WriteAllText($discoveryPath, ((Meta $mainId 'vscode') + "`n" + (Event 'task_started' 'new-created') + "`n"), $utf8)
        [IO.File]::SetCreationTimeUtc($discoveryPath, $now.AddSeconds(-5))
        [IO.File]::SetLastWriteTimeUtc($discoveryPath, $now.AddDays(-3))
        Update-CodexGuardTracker -Tracker $discoveryCase.Tracker -Discover
        Check 1 $discoveryCase.Tracker.Files.Count 'recently created session is discovered despite old modification timestamp'
        Check 1 (Snapshot $discoveryCase).ActiveCount 'created session uses its current event activity after discovery'
        Check $mainId (Snapshot $discoveryCase).TaskEntries[0].ThreadId 'new-session discovery preserves metadata identity'

        $oldDatesCase = New-Case 'old-file-times-current-events'
        $oldDatesPath = Join-Path $oldDatesCase.Sessions "rollout-$mainId.jsonl"
        [IO.File]::WriteAllText($oldDatesPath, ((Meta $mainId 'vscode') + "`n" + (Event 'task_started' 'before-baseline' $now.AddDays(-3)) + "`n" + (Event 'task_complete' 'before-baseline' $now.AddDays(-3).AddMinutes(1)) + "`n" + (Event 'task_started' 'after-baseline') + "`n"), $utf8)
        [IO.File]::SetCreationTimeUtc($oldDatesPath, $now.AddDays(-3))
        [IO.File]::SetLastWriteTimeUtc($oldDatesPath, $now.AddDays(-3))
        $oldOnlyPath = Join-Path $oldDatesCase.Sessions "rollout-$childId.jsonl"
        [IO.File]::WriteAllText($oldOnlyPath, ((Meta $childId 'vscode') + "`n" + (Event 'task_started' 'historical-only' $now.AddDays(-3)) + "`n"), $utf8)
        [IO.File]::SetCreationTimeUtc($oldOnlyPath, $now.AddDays(-3))
        [IO.File]::SetLastWriteTimeUtc($oldOnlyPath, $now.AddDays(-3))
        Update-CodexGuardTracker -Tracker $oldDatesCase.Tracker -Discover
        Check 2 $oldDatesCase.Tracker.Files.Count 'old creation and modification dates cannot hide current appended events'
        Check 1 (Snapshot $oldDatesCase).TaskCount 'only lifecycle events after the tracking baseline are admitted'
        Check 'after-baseline' (Snapshot $oldDatesCase).TaskEntries[0].TurnId 'current task is detected through its event timestamp'
        Check $false $oldDatesCase.Tracker.Turns.ContainsKey('historical-only') 'historical-only task remains excluded despite full file discovery'
        Check $false $oldDatesCase.Tracker.Turns.ContainsKey('before-baseline') 'old lifecycle in an active file also stays excluded'

        return $script:IdentityPassed
    } $testRoot
    Write-Output "PASS: $passed task identity, inherited-history and liveness assertions. Native shutdown was not invoked."
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedRoot -Leaf) -notlike 'CodexGuardIdentity_*') { throw 'Refusing cleanup outside isolated test root.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
}
