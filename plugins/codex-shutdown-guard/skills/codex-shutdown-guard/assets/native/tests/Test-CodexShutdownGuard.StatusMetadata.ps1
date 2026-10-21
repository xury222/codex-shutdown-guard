[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'CodexShutdownGuard.Core.psm1') -Force
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'CodexShutdownGuard.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Main script could not be parsed.' }
foreach ($name in @('Get-CodexTaskTitle', 'Get-CodexTaskMetadataValue', 'New-StatusPayload')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Get-UsageFreshness { param($Usage, $NowUtc) return [pscustomobject]@{ Valid=$false; Expired=$false; Stale=$false; AgeSeconds=$null; Reason='NoUsage' } }
function Get-PhaseLabel { param($Phase) return $Phase }
function Get-RemainingSeconds { param($Runtime, $NowUtc) return $null }
$script:ThreadTitles = @{ 'main-thread'='Parent task'; 'own-title'='Child task title' }
$script:Config = [pscustomobject]@{ stableSamplesRequired=3 }
$script:ResolvedCodexHome = 'isolated-test-only'
$script:Passed = 0
function Check($expected, $actual, [string]$message) {
    if ($expected -ne $actual) { throw "FAILED: $message. Expected [$expected], got [$actual]." }
    $script:Passed++
}
$now = [datetime]::UtcNow
$main = [pscustomobject]@{
    Kind='ActiveTurn'; State='Active'; TurnId='main-turn'; ThreadId='main-thread'; TaskType='MainTask'
    ParentThreadId=''; AgentName=''; AgentRole=''; AgentPath=''; ThreadSource='desktop'
    Cwd='test'; StartedAtUtc=$now; LastUpdatedAtUtc=$now; Path='test'; Reason=''; IsIgnored=$false; BlocksShutdown=$true
}
$child = [pscustomobject]@{
    Kind='ActiveTurn'; State='Active'; TurnId='child-turn'; ThreadId='child-thread'; TaskType='Subagent'
    ParentThreadId='main-thread'; AgentName='check_assets'; AgentRole='explorer'; AgentPath='/root/check_assets'; ThreadSource='agent'
    Cwd='test'; StartedAtUtc=$now; LastUpdatedAtUtc=$now; Path='test'; Reason=''; IsIgnored=$false; BlocksShutdown=$true
}
$snapshot = [pscustomobject]@{
    CapturedAtUtc=$now; ActiveCount=2; ObservedActiveCount=2; ActiveTurns=@($main,$child); AllActiveTurns=@($main,$child)
    UnknownCount=0; UnknownItems=@(); ObservedUnknownCount=0; AllUnknownItems=@()
    TaskCount=2; TaskEntries=@($main,$child); IgnoredCount=0; IgnoredTurnIds=@(); HasPendingReads=$false; HistoryBytesRemaining=0
    UsageAvailable=$false; Usage=$null; UsageError=''
}
$runtime = New-CodexGuardRuntime
$payload = New-StatusPayload -Running $true -Runtime $runtime -Snapshot $snapshot -AppAvailable $true
Check 7 $payload.schemaVersion 'status schema exposes task identity metadata'
Check 2 $payload.taskEntries.Count 'all tasks remain represented'
Check 'Parent task' $payload.taskEntries[0].title 'main task keeps authored title'
Check '' $payload.taskEntries[0].parentTitle 'main task does not invent a parent'
Check 'Subagent' $payload.taskEntries[1].taskType 'child type reaches MCP status'
Check 'main-thread' $payload.taskEntries[1].parentThreadId 'child parent identity reaches MCP status'
Check 'Parent task' $payload.taskEntries[1].parentTitle 'child parent has its real title'
Check 'check_assets' $payload.taskEntries[1].agentName 'child has its recorded agent name'
Check '/root/check_assets' $payload.taskEntries[1].agentPath 'child has its recorded path'
Check $true ($payload.taskEntries[1].title -match 'check_assets') 'child title includes recorded agent name'
Check $true ($payload.taskEntries[1].title -match 'Parent task') 'child title identifies its parent'
Check $true $payload.taskEntries[1].blocksShutdown 'child still blocks shutdown'
Check $false $payload.armed 'building status never arms shutdown'
$json = $payload | ConvertTo-Json -Depth 8 -Compress
Check $true ($json -match 'parentThreadId') 'JSON serialization preserves child ownership'
Check 'Parent task' (Get-CodexTaskTitle -ThreadId 'main-thread') 'old title-only calls remain compatible'
Check (([string][char]0x4efb) + [char]0x52a1 + ' legacy-unknown') (Get-CodexTaskTitle -ThreadId 'legacy-unknown') 'legacy fallback preserves exact identity'
Check '' (Get-CodexTaskMetadataValue -Entry ([pscustomobject]@{}) -Name 'TaskType') 'older snapshots remain compatible'
Write-Output "PASS: $script:Passed status metadata assertions. No native guard or shutdown was invoked."
