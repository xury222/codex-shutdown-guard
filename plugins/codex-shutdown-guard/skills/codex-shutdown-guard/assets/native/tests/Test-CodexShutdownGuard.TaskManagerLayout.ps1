[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\..\..\outputs')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'CodexShutdownGuard.ps1'), [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw ($parseErrors | Out-String) }
$script:Passed = 0
$script:NativeCalls = 0

function Assert-Layout($condition, [string]$name) {
    if (-not $condition) { throw "FAILED: $name" }
    $script:Passed++
}

# Load only the dialog functions. The scheduler, tray, state directory and installed guard never run.
foreach ($name in @('Update-CodexTaskManagerView', 'Show-TaskManagerDialog')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Assert-Layout ($null -ne $definition) "$name exists"
    $source = $definition.Extent.Text
    if ($name -eq 'Update-CodexTaskManagerView') {
        $source = $source.Replace('function Update-CodexTaskManagerView', 'function Invoke-LayoutProductionUpdate')
    }
    . ([scriptblock]::Create($source))
}

function Invoke-GuardPoll { }
function Read-CodexThreadTitles { return @{} }
function Get-CodexGuardTaskManagerRows { param($Snapshot, $ThreadTitles, $PendingChecks) return $script:MockRows }
function Invoke-NativeShutdownSchedule { $script:NativeCalls++; throw 'Shutdown is forbidden in layout tests.' }
function Invoke-NativeShutdownAbort { $script:NativeCalls++; throw 'Shutdown abort is forbidden in layout tests.' }
function Set-IgnoredTurnIds { $script:NativeCalls++; throw 'Persisting ignore changes is forbidden in layout tests.' }

function Assert-TaskManagerBounds {
    param($View, [string]$Stage, [int]$MinimumListHeight = 170)
    $layout = $View.Dialog.Controls[0]
    $instruction = $layout.GetControlFromPosition(0, 0)
    $summary = $View.Summary
    $list = $View.List
    $buttons = $layout.GetControlFromPosition(0, 3)
    $layout.PerformLayout()
    foreach ($label in @($instruction, $summary)) {
        $preferred = $label.GetPreferredSize((New-Object Drawing.Size($label.Width, 0)))
        Assert-Layout ($label.Height -ge $preferred.Height) "$Stage text height contains every line"
        Assert-Layout ($label.Left -ge $layout.Padding.Left -and $label.Right -le $layout.ClientSize.Width - $layout.Padding.Right) "$Stage text remains inside the client width"
    }
    Assert-Layout ($instruction.Bottom + $instruction.Margin.Bottom -le $summary.Top) "$Stage instruction and summary do not overlap"
    Assert-Layout ($summary.Bottom + $summary.Margin.Bottom -le $list.Top) "$Stage summary and list do not overlap"
    Assert-Layout ($list.Bottom -le $buttons.Top - $buttons.Margin.Top) "$Stage list remains above buttons"
    Assert-Layout ($buttons.Bottom -le $layout.ClientSize.Height - $layout.Padding.Bottom) "$Stage buttons remain visible"
    Assert-Layout ($list.Height -ge $MinimumListHeight) "$Stage list retains usable height"
}

function Update-CodexTaskManagerView {
    Invoke-LayoutProductionUpdate
    if ($script:HookAdded -or $null -eq $script:TaskManagerView) { return }
    $script:HookAdded = $true
    $script:TaskManagerView.Dialog.Add_Shown({
        param($sender, $eventArgs)
        try {
            $view = $script:TaskManagerView
            $sender.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
            if ($script:Scenario.Scale -ne 1) {
                $sender.Scale((New-Object Drawing.SizeF($script:Scenario.Scale, $script:Scenario.Scale)))
            }
            if ($script:Scenario.FontSize -ne 9) {
                $sender.Font = New-Object Drawing.Font('Microsoft YaHei UI', $script:Scenario.FontSize)
                $view.Summary.Font = New-Object Drawing.Font('Microsoft YaHei UI', $script:Scenario.FontSize, [Drawing.FontStyle]::Bold)
            }
            if ($script:Scenario.Narrow) {
                $sender.MinimumSize = New-Object Drawing.Size(860, 440)
                $sender.Size = $sender.MinimumSize
            }
            $sender.PerformLayout()
            [Windows.Forms.Application]::DoEvents()
            Assert-Layout ($sender.FormBorderStyle -eq [Windows.Forms.FormBorderStyle]::Sizable) 'dialog can be resized'
            Assert-Layout ($sender.MaximizeBox) 'dialog can be maximized'
            Assert-Layout ($view.List.Items.Count -eq 3) 'production view renders mock tasks'
            Assert-Layout ($view.Summary.Text -match '当前条目：3') 'summary contains current task count'
            Assert-Layout ($view.Summary.Text -match '阻止关机：1') 'only the main task is included in the blocking summary'
            Assert-Layout ($view.List.Items[1].SubItems[1].Text -eq '活动 · 不阻塞') 'first subagent row reports non-blocking activity'
            Assert-Layout ($view.List.Items[2].SubItems[1].Text -eq '活动 · 不阻塞') 'second subagent row reports non-blocking activity'
            Assert-Layout ($view.Summary.Text -match '主任务 1  ·  子代理 2  ·  内部审批 0') 'summary identifies main task and subagent counts'
            Assert-Layout ($view.Summary.Text -match '扫描 \d{2}:\d{2}:\d{2}') 'summary includes the snapshot scan time'
            Assert-TaskManagerBounds -View $view -Stage $script:Scenario.Name
            $originalSummary = $view.Summary.Text
            $originalSummaryHeight = $view.Summary.Height
            $view.Summary.Text = ($originalSummary + '  ·  ') * 3
            $sender.PerformLayout()
            Assert-Layout ($view.Summary.Height -gt $originalSummaryHeight) 'long summary grows its own row'
            # This artificial stress text has six or more lines; ordinary statistics still require 170px.
            Assert-TaskManagerBounds -View $view -Stage ($script:Scenario.Name + ' wrapped summary') -MinimumListHeight 60
            $view.Summary.Text = $originalSummary
            $sender.PerformLayout()
            $originalSize = $sender.ClientSize
            $originalListHeight = $view.List.Height
            $originalTitleWidth = $view.List.Columns[0].Width
            $sender.ClientSize = New-Object Drawing.Size(($originalSize.Width + 400), ($originalSize.Height + 80))
            $sender.PerformLayout()
            Assert-Layout ($view.List.Height -gt $originalListHeight) 'resizing grows the task list'
            Assert-Layout ($view.List.Columns[0].Width -gt $originalTitleWidth) 'resizing grows the title column'
            Assert-TaskManagerBounds -View $view -Stage ($script:Scenario.Name + ' resized')
            $sender.ClientSize = $originalSize
            $sender.PerformLayout()
            $view.List.Items[0].Checked = $true
            Assert-Layout ($view.PendingChecks['turn-one'] -eq $true) 'checkbox still stages the exact turn'
            $view.List.Items[0].Checked = $false
            $script:MeasuredLayouts += [pscustomobject]@{
                Scenario = $script:Scenario.Name
                ClientWidth = $sender.ClientSize.Width
                ClientHeight = $sender.ClientSize.Height
                FontPoints = $sender.Font.SizeInPoints
                SummaryHeight = $view.Summary.Height
                ListHeight = $view.List.Height
            }
        }
        catch { $script:LayoutFailure = $_ }
    })
}

$script:Config = [pscustomobject]@{ usagePanelTopMost = $false }
$script:StopRequested = $false
$script:UsageForm = $null
$script:TaskManagerView = $null
$script:ThreadTitles = @{}
$script:MeasuredLayouts = @()
$script:LastSnapshot = [pscustomobject]@{
    ActiveCount = 1; UnknownCount = 0; TaskCount = 3; ObservedShutdownTaskCount=1; IgnoredCount = 0
    ObservedUnknownCount = 0; HasPendingReads = $true
    CapturedAtUtc = [datetime]'2026-10-20T17:25:32Z'
    TaskEntries = @(
        [pscustomobject]@{ Kind='ActiveTurn'; TaskType='MainTask' },
        [pscustomobject]@{ Kind='ActiveTurn'; TaskType='Subagent' },
        [pscustomobject]@{ Kind='ActiveTurn'; TaskType='Subagent' }
    )
}
$script:MockRows = @(
    [pscustomobject]@{ Title='设计示例任务入口与任务进度画面'; StateText='活动 · 阻塞'; Cwd='C:\ExampleProject'; Updated='10-21 01:25:30'; TurnId='turn-one'; Tooltip='主任务'; Checked=$false; Tone='Normal' },
    [pscustomobject]@{ Title='子代理：检查示例任务布局（所属父任务：设计示例任务入口与任务进度画面）'; StateText='活动 · 不阻塞'; Cwd='C:\ExampleProject'; Updated='10-21 01:25:31'; TurnId='turn-two'; Tooltip='测试示例：子代理所属父任务'; Checked=$false; Tone='Normal' },
    [pscustomobject]@{ Title='子代理：验证任务进度流程（所属父任务：设计示例任务入口与任务进度画面）'; StateText='活动 · 不阻塞'; Cwd='C:\ExampleProject'; Updated='10-21 01:25:32'; TurnId='turn-three'; Tooltip='测试示例：子代理所属父任务'; Checked=$false; Tone='Normal' }
)
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
foreach ($scenario in @(
    [pscustomobject]@{ Name='100-percent'; Scale=1.0; FontSize=9.0; Narrow=$false },
    [pscustomobject]@{ Name='150-percent-layout'; Scale=1.5; FontSize=13.5; Narrow=$false },
    [pscustomobject]@{ Name='large-font-narrow'; Scale=1.0; FontSize=13.5; Narrow=$true }
)) {
    $script:Scenario = $scenario
    $script:HookAdded = $false
    $script:LayoutFailure = $null
    Show-TaskManagerDialog -ScreenshotPath (Join-Path $OutputDirectory ('task-manager-' + $scenario.Name + '.png'))
    if ($null -ne $script:LayoutFailure) { throw $script:LayoutFailure }
    Assert-Layout ($null -eq $script:TaskManagerView) 'screenshot path disposes the dialog and clears its reference'
}
Assert-Layout ($script:NativeCalls -eq 0) 'layout tests never call shutdown or save ignore state'
$script:MeasuredLayouts | Format-Table -AutoSize | Out-String | Write-Output
Write-Output "Passed $script:Passed layout checks; screenshots: $([IO.Path]::GetFullPath($OutputDirectory))"
