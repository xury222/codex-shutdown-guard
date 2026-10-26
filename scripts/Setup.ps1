#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall')][string]$Mode = 'Install',
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Worker,
    [string]$ResultPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Setup.Core.psm1') -Force

if ($Worker) {
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { throw 'A worker result path is required.' }
    $result = Invoke-CodexGuardSetupOperation -PackageRoot $PackageRoot -Mode $Mode
    [IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    if ($result.ok) { exit 0 } else { exit 1 }
}

function New-CodexGuardSetupWindow {
    param([string]$PackageRoot, [ValidateSet('Install', 'Uninstall')][string]$Mode)
    $package = Assert-CodexGuardSetupPackage -PackageRoot $PackageRoot
    $isInstall = $Mode -eq 'Install'
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Codex 关机守卫 ' + $package.Version
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = New-Object Drawing.Size(620, 330)
    $form.MinimumSize = New-Object Drawing.Size(600, 360)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.Padding = New-Object Windows.Forms.Padding(16)
    $layout.ColumnCount = 1; $layout.RowCount = 5
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    foreach ($row in 0..4) {
        $style = if ($row -eq 3) { New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100) } else { New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize) }
        [void]$layout.RowStyles.Add($style)
    }
    $form.Controls.Add($layout)
    $title = New-Object Windows.Forms.Label
    $title.Text = if ($isInstall) { '安装 Codex 关机守卫' } else { '卸载 Codex 关机守卫' }
    $title.Font = New-Object Drawing.Font($form.Font.FontFamily, 13, [Drawing.FontStyle]::Bold)
    $title.AutoSize = $true; $title.Dock = 'Fill'; $title.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 10)
    $layout.Controls.Add($title, 0, 0)
    $intro = New-Object Windows.Forms.Label
    $intro.Text = if ($isInstall) { '安装独立守卫，创建桌面快捷方式并启动。更新会保留已有配置；安装不会开启自动关机。' } else { '退出守卫并移除程序及其快捷方式，保留状态目录和额外文件。' }
    $intro.AutoSize = $true; $intro.Dock = 'Fill'; $intro.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
    $layout.Controls.Add($intro, 0, 1)
    $layout.Add_SizeChanged({
        $intro.MaximumSize = New-Object Drawing.Size([Math]::Max(1, $layout.ClientSize.Width - $layout.Padding.Horizontal), 0)
    }.GetNewClosure())
    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Dock = 'Fill'; $progress.Height = 16; $progress.Style = 'Continuous'
    $progress.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 10)
    $layout.Controls.Add($progress, 0, 2)
    $details = New-Object Windows.Forms.TextBox
    $details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'; $details.WordWrap = $true; $details.TabStop = $false
    $details.Dock = 'Fill'; $details.MinimumSize = New-Object Drawing.Size(0, 100)
    $details.Text = if ($isInstall) { '点击“安装并启动”开始。已有守卫若开启了自动关机，请先取消后再更新。' } else { '点击“卸载守卫”开始。' }
    $layout.Controls.Add($details, 0, 3)
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'; $buttons.AutoSize = $true; $buttons.Dock = 'Fill'
    $buttons.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 0)
    $close = New-Object Windows.Forms.Button
    $close.Text = '关闭'; $close.AutoSize = $true; $close.Padding = New-Object Windows.Forms.Padding(12, 4, 12, 4)
    $action = New-Object Windows.Forms.Button
    $action.Text = if ($isInstall) { '安装并启动' } else { '卸载守卫' }
    $action.AutoSize = $true; $action.Padding = New-Object Windows.Forms.Padding(12, 4, 12, 4)
    [void]$buttons.Controls.Add($close); [void]$buttons.Controls.Add($action)
    $layout.Controls.Add($buttons, 0, 4)
    $form.AcceptButton = $action; $form.CancelButton = $close
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 200
    $view = [pscustomobject]@{ Form = $form; Action = $action; Close = $close; Details = $details; Progress = $progress; Timer = $timer; Worker = $null; ExitCode = 0; PackageRoot = $package.Root; Mode = $Mode }
    $close.add_Click({ $view.Form.Close() }.GetNewClosure())
    $action.add_Click({
        try {
            $view.Action.Enabled = $false; $view.Close.Enabled = $false
            $view.Progress.Style = 'Marquee'
            $view.Details.Text = if ($view.Mode -eq 'Install') { '正在安装，请等待完成…' } else { '正在卸载，请等待完成…' }
            $view.Worker = Start-CodexGuardSetupWorker -PackageRoot $view.PackageRoot -Mode $view.Mode
            $view.Timer.Start()
        }
        catch {
            $view.Details.Text = '无法开始操作：' + $_.Exception.Message
            $view.Progress.Style = 'Continuous'; $view.Action.Enabled = $true; $view.Close.Enabled = $true
            $view.ExitCode = 1
        }
    }.GetNewClosure())
    $timer.add_Tick({
        if ($null -eq $view.Worker -or -not $view.Worker.Process.HasExited) { return }
        $view.Timer.Stop()
        try {
            $result = Read-CodexGuardSetupWorkerResult -Worker $view.Worker
            $view.ExitCode = if ($result.ok) { 0 } else { 1 }
            if ($result.ok) {
                $view.Progress.Value = 100
                $view.Details.Text = if ($result.uninstalled) { '守卫已卸载。状态目录和额外文件已保留。' } else { '守卫已安装，已请求启动。自动关机未开启。可从桌面快捷方式或系统托盘打开。' }
                $view.Action.Text = '已完成'
            }
            else {
                $errorText = [string]$result.error
                if ($errorText -match 'fresh unarmed status|Cancel automatic shutdown first') { $errorText = '守卫已开启自动关机，或状态尚未更新。请先取消自动关机，等待片刻后重试。' }
                $view.Details.Text = '操作未完成：' + [Environment]::NewLine + $errorText
                $view.Action.Enabled = $true
            }
        }
        catch { $view.Details.Text = '无法确认操作结果：' + $_.Exception.Message; $view.ExitCode = 1; $view.Action.Enabled = $true }
        finally {
            $view.Progress.Style = 'Continuous'; $view.Close.Enabled = $true
            try { Remove-CodexGuardSetupWorker -Worker $view.Worker } catch { }
            $view.Worker = $null
        }
    }.GetNewClosure())
    $form.add_FormClosing({
        param($sender, $eventArgs)
        if ($null -ne $view.Worker) {
            $eventArgs.Cancel = $true
            $view.Details.Text = '操作正在进行，请等待完成后关闭窗口。'
        }
    }.GetNewClosure())
    $form.add_FormClosed({ $view.Timer.Stop(); $view.Timer.Dispose() }.GetNewClosure())
    return $view
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $window = New-CodexGuardSetupWindow -PackageRoot $PackageRoot -Mode $Mode
    [void]$window.Form.ShowDialog()
    $exitCode = $window.ExitCode
    $window.Form.Dispose()
    exit $exitCode
}
catch {
    try { [void][Windows.Forms.MessageBox]::Show(('安装窗口无法打开。请完整解压 Windows 安装包。' + [Environment]::NewLine + $_.Exception.Message), 'Codex 关机守卫', 'OK', 'Error') } catch { Write-Error $_ }
    exit 1
}
