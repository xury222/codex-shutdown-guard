[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $root 'CodexShutdownGuard.Core.psm1') -Force -PassThru
$script:Passed = 0
$script:NativeCalls = 0
function Assert-Equal($expected, $actual, [string]$name) {
    if ($expected -ne $actual) { throw "FAILED: $name; expected [$expected], got [$actual]." }
    $script:Passed++
}
function Invoke-NativeShutdownSchedule { $script:NativeCalls++; throw 'Native shutdown is forbidden in repair tests.' }
function Invoke-NativeShutdownAbort { $script:NativeCalls++; throw 'Native shutdown is forbidden in repair tests.' }
function Invoke-GuardPoll { }
function Write-GuardLog { }
function Write-IgnoredTaskState { $script:IgnoreWrites++ }
$mainTokens=$null; $mainErrors=$null
$mainAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'CodexShutdownGuard.ps1'),[ref]$mainTokens,[ref]$mainErrors)
Assert-Equal 0 @($mainErrors).Count 'main script parses'
foreach ($name in @('Read-CodexThreadTitles','Get-CodexTaskTitle','Update-CodexTaskManagerView','Remove-CompletedIgnoredTurns')) {
    $definition=$mainAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name },$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$dialogAst=$mainAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-TaskManagerDialog' },$true)
$tickAst=$dialogAst.Find({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Tick' },$true)
$checkAst=$dialogAst.Find({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_ItemCheck' },$true)
$testRoot=Join-Path $env:TEMP ('CodexGuardRepair_' + [guid]::NewGuid().ToString('N'))
$script:ResolvedCodexHome=$testRoot
[void](New-Item -ItemType Directory -Path $testRoot -Force)
try {
    $titleLines=@(
        '{ "thread_name": "First title", "extra": {}, "id": "11111111-1111-1111-1111-111111111111" }',
        '{"id":"11111111-1111-1111-1111-111111111111","thread_name":"Latest title"}',
        '{"id":"22222222-2222-2222-2222-222222222222","thread_name":null}',
        '{"thread_name":"truncated"'
    )
    [IO.File]::WriteAllLines((Join-Path $testRoot 'session_index.jsonl'),$titleLines,(New-Object Text.UTF8Encoding($false)))
    $script:ThreadTitles=Read-CodexThreadTitles
    Assert-Equal 1 $script:ThreadTitles.Count 'title reader accepts formatting and ignores missing/malformed titles'
    Assert-Equal 'Latest title' (Get-CodexTaskTitle '11111111-1111-1111-1111-111111111111') 'latest title wins'
    Assert-Equal '任务 22222222-2222-2222-2222-222222222222' (Get-CodexTaskTitle '22222222-2222-2222-2222-222222222222') 'missing title retains the exact identity'
    Assert-Equal 'First title' (ConvertFrom-CodexGuardThreadTitleLine $titleLines[0]).Title 'reordered spaced title is parsed'
    $script:IgnoredTurnIds=@{ 'not-yet-replayed'=$true }
    $script:IgnoreWrites=0
    Remove-CompletedIgnoredTurns ([pscustomobject]@{ TaskEntries=@(); HasPendingReads=$true })
    Assert-Equal $true $script:IgnoredTurnIds.ContainsKey('not-yet-replayed') 'partial history replay preserves persisted ignore decisions'
    Assert-Equal 0 $script:IgnoreWrites 'partial history replay cannot clear the ignore file'
    Remove-CompletedIgnoredTurns ([pscustomobject]@{ TaskEntries=@(); HasPendingReads=$false })
    Assert-Equal 0 $script:IgnoredTurnIds.Count 'completed full replay can prune completed ignores'

    $checks = & $module {
        param($testRoot)
        $script:CasePassed=0
        function Check($expected,$actual,$name) {
            if ($expected -ne $actual) { throw "FAILED: $name; expected [$expected], got [$actual]." }
            $script:CasePassed++
        }
        $now=[datetime]::UtcNow
        $tracker=New-CodexGuardTracker -CodexHome $testRoot -BaselineUtc $now.AddDays(-3)
        $path=Join-Path $testRoot 'rollout-11111111-1111-1111-1111-111111111111.jsonl'
        $file=New-CodexGuardFileState $path
        $file.LastWriteUtc=$now.AddHours(-2)
        $tracker.Files[$path]=$file
        function Send($type,$turn,$at) {
            # Top-level and payload order deliberately differ from old prefilters.
            $line=[ordered]@{ payload=[ordered]@{ turn_id=$turn; metadata=@{ sample=$true }; type=$type }; ordinal=3; type='event_msg'; timestamp=$at.ToString('o') } | ConvertTo-Json -Depth 5 -Compress
            Register-CodexGuardLine $tracker $file $line
        }
        Send 'turn_started' 'old-turn' $now.AddHours(-2)
        $s=Get-CodexGuardSnapshot $tracker -NowUtc $now
        Check 1 $s.TaskCount 'old unresolved turn remains visible'
        Check 0 $s.ActiveCount 'old unresolved turn is not asserted active'
        Check 1 $s.UnknownCount 'stale turn blocks conservatively'
        Check 'StaleTurn' $s.TaskEntries[0].Kind 'stale kind is explicit'
        Check 'Active' $tracker.Turns['old-turn'].State 'staleness never changes lifecycle to completed'
        Check $true $s.TaskEntries[0].BlocksShutdown 'stale turn blocks'
        $ignored=Get-CodexGuardSnapshot $tracker -NowUtc $now -IgnoredTurnIds @('old-turn')
        Check 0 $ignored.UnknownCount 'exact ignored stale turn no longer blocks'
        Check 1 $ignored.TaskCount 'ignored stale turn remains visible'
        Check 1 $ignored.IgnoredCount 'ignore count retained across classification'
        $file.LastWriteUtc=$now
        $s=Get-CodexGuardSnapshot $tracker -NowUtc $now
        Check 'ActiveTurn' $s.TaskEntries[0].Kind 'new file updates recover stale classification'
        Check 1 $s.ActiveCount 'long running turn with current updates stays active'
        Send 'task_started' 'old-turn' $now.AddHours(-2)
        Check 1 (Get-CodexGuardSnapshot $tracker -NowUtc $now).TaskCount 'duplicate start is idempotent'
        Send 'turn_complete' 'old-turn' $now
        Check 0 (Get-CodexGuardSnapshot $tracker -NowUtc $now).TaskCount 'completion alias clears the exact turn'
        Send 'task_started' 'old-turn' $now.AddHours(-2)
        Check 0 (Get-CodexGuardSnapshot $tracker -NowUtc $now).TaskCount 'replayed start never resurrects completed turn'
        Send 'task_started' 'new-turn' $now.AddSeconds(1)
        $s=Get-CodexGuardSnapshot $tracker -NowUtc $now.AddSeconds(2) -IgnoredTurnIds @('old-turn')
        Check 1 $s.ActiveCount 'new turn does not inherit old ignore'
        Send 'task_started' 'replacement-turn' $now.AddSeconds(3)
        Check 1 (Get-CodexGuardSnapshot $tracker -NowUtc $now.AddSeconds(4)).TaskCount 'same thread new turn does not duplicate rows'
        Check 'Superseded' $tracker.Turns['new-turn'].State 'old turn retains inactive history'
        Send 'task_started' 'late-old-turn' $now.AddSeconds(2)
        Check 'Superseded' $tracker.Turns['late-old-turn'].State 'out of order old start cannot replace newer active turn'
        Send 'stream_error' 'replacement-turn' $now.AddSeconds(5)
        Check 1 (Get-CodexGuardSnapshot $tracker -NowUtc $now.AddSeconds(6)).ActiveCount 'retryable error is not a terminal event'
        Send 'turn_aborted' 'replacement-turn' $now.AddSeconds(7)
        Check 0 (Get-CodexGuardSnapshot $tracker -NowUtc $now.AddSeconds(8)).TaskCount 'identified abort clears exact turn'
        Check 'Aborted' $tracker.Turns['replacement-turn'].State 'abort retained as terminal history'
        Send 'task_started' 'legacy-abort-turn' $now.AddSeconds(9)
        $abort=@{ timestamp=$now.AddSeconds(10).ToString('o'); type='event_msg'; payload=@{ type='turn_aborted'; reason='interrupted' } } | ConvertTo-Json -Depth 4 -Compress
        Register-CodexGuardLine $tracker $file $abort
        Check 0 (Get-CodexGuardSnapshot $tracker -NowUtc $now.AddSeconds(11)).TaskCount 'legacy abort without id correlates to one exact same thread turn'
        $ambiguous=New-CodexGuardTracker -CodexHome $testRoot -BaselineUtc $now.AddDays(-1)
        $ambiguous.Files[$path]=$file
        Register-CodexGuardLine $ambiguous $file $abort
        Check 1 (Get-CodexGuardSnapshot $ambiguous).UnknownCount 'unattributable abort fails closed'

        $fsRoot=Join-Path $testRoot 'fixtures'
        $sessions=Join-Path $fsRoot 'sessions'
        [void](New-Item -ItemType Directory -Path $sessions -Force)
        $partialPath=Join-Path $sessions 'rollout-33333333-3333-3333-3333-333333333333.jsonl'
        $started=@{ type='event_msg'; payload=@{ turn_id='partial-turn'; type='task_started' }; timestamp=$now.ToString('o') } | ConvertTo-Json -Depth 4 -Compress
        $ended=@{ payload=@{ turn_id='partial-turn'; type='task_complete'; message='中文分段' }; timestamp=$now.AddSeconds(1).ToString('o'); type='event_msg' } | ConvertTo-Json -Depth 4 -Compress
        $utf8=New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($partialPath,$started+"`n"+$ended.Substring(0,20),$utf8)
        $delta=New-CodexGuardTracker -CodexHome $fsRoot -BaselineUtc $now.AddMinutes(-1)
        Update-CodexGuardTracker $delta -Discover
        $s=Get-CodexGuardSnapshot $delta
        Check 1 $s.TaskCount 'partial tail does not create a duplicate task'
        Check 1 $s.UnknownCount 'partial tail blocks until event is complete'
        Check 'IncompleteActiveTurn' $s.TaskEntries[0].Kind 'incomplete record is explicit'
        [IO.File]::AppendAllText($partialPath,$ended.Substring(20)+"`n",$utf8)
        Update-CodexGuardTracker $delta
        $s=Get-CodexGuardSnapshot $delta
        Check 0 $s.TaskCount 'completed partial event clears its task'
        Check 0 $s.UnknownCount 'completed tail clears pending uncertainty'

        # Split inside a UTF-8 character, rather than only at JSON boundaries.
        $splitPath=Join-Path $sessions 'rollout-55555555-5555-5555-5555-555555555555.jsonl'
        $splitText=$ended.Replace('partial-turn','utf8-turn')
        $splitStart=$started.Replace('partial-turn','utf8-turn')
        $splitBytes=$utf8.GetBytes($splitStart+"`n"+$splitText+"`n")
        $splitAt=0
        for ($i=0;$i -lt $splitBytes.Length;$i++) { if ($splitBytes[$i] -ge 128) { $splitAt=$i+1; break } }
        Check $true ($splitAt -gt 0) 'fixture contains a multibyte UTF-8 character'
        [IO.File]::WriteAllBytes($splitPath,$splitBytes[0..($splitAt-1)])
        Update-CodexGuardTracker $delta -Discover
        Check 1 (Get-CodexGuardSnapshot $delta).UnknownCount 'UTF-8 split remains an incomplete protected turn'
        $appendStream=[IO.File]::Open($splitPath,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
        try { $appendStream.Write($splitBytes,$splitAt,$splitBytes.Length-$splitAt) } finally { $appendStream.Dispose() }
        Update-CodexGuardTracker $delta
        Check 0 (Get-CodexGuardSnapshot $delta).UnknownCount 'UTF-8 split reassembles without a parse error'
        Check 0 (Get-CodexGuardSnapshot $delta).TaskCount 'UTF-8 split completion terminates its exact turn'

        $onlyPartial=Join-Path $sessions 'rollout-44444444-4444-4444-4444-444444444444.jsonl'
        [IO.File]::WriteAllText($onlyPartial,'{"type":"event_msg","payload":',$utf8)
        Update-CodexGuardTracker $delta -Discover
        Check 1 (Get-CodexGuardSnapshot $delta).UnknownCount 'initial truncated record cannot be mistaken for idle'
        [IO.File]::AppendAllText($onlyPartial,'{"type":"task_complete","turn_id":"unseen"},"timestamp":"'+$now.ToString('o')+'"}'+"`n",$utf8)
        Update-CodexGuardTracker $delta
        Check 0 (Get-CodexGuardSnapshot $delta).UnknownCount 'initial partial record recovers'

        $largeRoot=Join-Path $testRoot 'bounded'
        $largeSessions=Join-Path $largeRoot 'sessions'
        [void](New-Item -ItemType Directory -Path $largeSessions -Force)
        $largePath=Join-Path $largeSessions 'rollout-66666666-6666-6666-6666-666666666666.jsonl'
        $largeMessage=@{ timestamp=$now.ToString('o'); type='response_item'; payload=@{ type='message'; content=@(@{ text=('x' * 1000000) }) } } | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText($largePath,$started+"`n"+$largeMessage+"`n"+$ended+"`n",$utf8)
        $bounded=New-CodexGuardTracker -CodexHome $largeRoot -BaselineUtc $now.AddMinutes(-1)
        $largeState=New-CodexGuardFileState $largePath
        $bounded.Files[$largePath]=$largeState
        foreach ($line in @(Read-CodexGuardFileDelta $largeState)) { Register-CodexGuardLine $bounded $largeState $line }
        Check 262144 $largeState.Position 'each historical file read is bounded to 256 KiB'
        $s=Get-CodexGuardSnapshot $bounded
        Check $true $s.HasPendingReads 'history backlog is explicit'
        Check 1 $s.UnknownCount 'unread history keeps the exact task protected'
        Check 'PendingReadActiveTurn' $s.TaskEntries[0].Kind 'unread history is not asserted active or completed'
        Update-CodexGuardTracker $bounded
        $s=Get-CodexGuardSnapshot $bounded
        Check $false $s.HasPendingReads 'history replay completes in bounded batches'
        Check 0 $s.TaskCount 'completion behind a large skipped body is recognized'
        Check 0 $s.UnknownCount 'finished history replay clears its temporary uncertainty'
        $metadata=[CodexGuardJsonReader]::Parse($largeMessage)
        Check $false $metadata['payload'].ContainsKey('content') 'body content is never retained by the JSON metadata reader'
        Register-CodexGuardLine $tracker $file '{"private_text":"DO_NOT_PUBLISH_SECRET",broken'
        $s=Get-CodexGuardSnapshot $tracker
        Check 1 $s.UnknownCount 'malformed complete record fails closed'
        Check $false (($s | ConvertTo-Json -Depth 8) -match 'DO_NOT_PUBLISH_SECRET') 'parse errors never reveal input content'
        $runtime=New-CodexGuardRuntime -DryRun
        Set-CodexGuardArmed $runtime -CurrentObservedTaskCount 1
        $actions=@(Update-CodexGuardRuntime $runtime $s $true $now 180 120)
        Check 'PausedUnknownState' $runtime.Phase 'unknown record prevents shutdown state machine'
        Check $false ('ScheduleShutdown' -in $actions) 'unknown record emits no shutdown action'
        $notArmed=New-CodexGuardRuntime -DryRun
        $actions=@(Update-CodexGuardRuntime $notArmed $s $true $now 180 120)
        Check 'Disarmed' $notArmed.Phase 'unarmed remains unarmed'
        Check 0 $actions.Count 'unarmed emits no native action'
        return $script:CasePassed
    } $testRoot
    $script:Passed += $checks

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $dialog=New-Object Windows.Forms.Form
    $list=New-Object Windows.Forms.ListView
    $list.CheckBoxes=$true
    $list.View=[Windows.Forms.View]::Details
    foreach ($name in @('Title','State','Directory','Updated','Turn')) { [void]$list.Columns.Add($name,100) }
    $summary=New-Object Windows.Forms.Label
    $dialog.Controls.Add($list); $dialog.Controls.Add($summary)
    # Create hidden control handles so checkbox and timer events use WinForms.
    [void]$dialog.Handle
    [void]$list.Handle
    $entry=[pscustomobject]@{ Kind='StaleTurn'; State='Unknown'; TurnId='first'; ThreadId='11111111-1111-1111-1111-111111111111'; Cwd='Fixture'; Path='Fixture.jsonl'; StartedAtUtc=[datetime]::UtcNow; LastUpdatedAtUtc=[datetime]::UtcNow.AddHours(-1); IsIgnored=$false; Reason='No updates'; BlocksShutdown=$true }
    $script:LastSnapshot=[pscustomobject]@{ TaskEntries=@($entry); AllUnknownItems=@(); ActiveCount=0; UnknownCount=1; TaskCount=1; IgnoredCount=0; ObservedUnknownCount=1 }
    $script:StopRequested=$false
    $script:TaskManagerView=[pscustomobject]@{ Dialog=$dialog; List=$list; Summary=$summary; PendingChecks=@{}; Refreshing=$false; LastSnapshot=$null; LastTitles=$null }
    $list.Add_ItemCheck([scriptblock]::Create($checkAst.Arguments[0].ScriptBlock.Extent.Text.Trim('{}')))
    Update-CodexTaskManagerView
    Assert-Equal 1 $list.Items.Count 'actual view displays one exact turn'
    Assert-Equal '疑似失联 · 阻塞' $list.Items[0].SubItems[1].Text 'actual view displays stale classification'
    $list.Items[0].Checked=$true
    Assert-Equal $true $script:TaskManagerView.PendingChecks['first'] 'user check is staged without changing runtime ignores'
    $script:LastSnapshot=[pscustomobject]@{ TaskEntries=@($entry); AllUnknownItems=@(); ActiveCount=0; UnknownCount=1; TaskCount=1; IgnoredCount=0; ObservedUnknownCount=1 }
    Update-CodexTaskManagerView
    Assert-Equal $true $list.Items[0].Checked 'refresh retains unapplied check for the same turn'
    $next=$entry.PSObject.Copy(); $next.TurnId='second'; $next.Kind='ActiveTurn'; $next.State='Active'
    $script:LastSnapshot=[pscustomobject]@{ TaskEntries=@($next); AllUnknownItems=@(); ActiveCount=1; UnknownCount=0; TaskCount=1; IgnoredCount=0; ObservedUnknownCount=0 }
    $refreshTimer=New-Object Windows.Forms.Timer
    $refreshTimer.Interval=50
    $refreshTimer.Add_Tick([scriptblock]::Create($tickAst.Arguments[0].ScriptBlock.Extent.Text.Trim('{}')))
    $refreshTimer.Start()
    $deadline=[datetime]::UtcNow.AddSeconds(2)
    while ([datetime]::UtcNow -lt $deadline -and [string]$list.Items[0].Tag -ne 'second') { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
    $refreshTimer.Stop(); $refreshTimer.Dispose()
    Assert-Equal 'second' $list.Items[0].Tag 'production timer callback refreshes actual view'
    Assert-Equal $false $list.Items[0].Checked 'new turn never inherits staged old check'
    Assert-Equal 0 $script:TaskManagerView.PendingChecks.Count 'completed old selection is pruned'
    Assert-Equal $true ($summary.Text -match '阻止关机：1') 'view summary follows current snapshot'
    $script:LastSnapshot=[pscustomobject]@{ TaskEntries=@(); AllUnknownItems=@(); ActiveCount=0; UnknownCount=0; TaskCount=0; IgnoredCount=0; ObservedUnknownCount=0 }
    Update-CodexTaskManagerView
    Assert-Equal '当前没有活动或异常任务' $list.Items[0].Text 'completed tasks leave actual view automatically'
    $dialog.Dispose()
    Assert-Equal 0 $script:NativeCalls 'shutdown and abort stubs were never invoked'
    [pscustomobject]@{ Passed=$script:Passed; RealShutdownCommandsExecuted=0; ViewRefreshVerified=$true }
}
finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $tempPrefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if ($resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
