[CmdletBinding()]
param([string]$TestRoot = [IO.Path]::GetTempPath(), [string]$OutputDirectory)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$scripts = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetFullPath($TestRoot)) ('CodexGuardWindowTest-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'package'
foreach ($relative in @('native\Install.ps1','native\Uninstall.ps1','native\CodexShutdownGuard.ps1','scripts\Setup.ps1','scripts\Setup.Core.psm1')) {
    $path = Join-Path $fixture $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, '# Inert fixture: no application or installation code.', (New-Object Text.UTF8Encoding($false)))
}
[IO.File]::WriteAllText((Join-Path $fixture 'product.json'), '{"name":"codex-shutdown-guard","version":"1.2.0"}', (New-Object Text.UTF8Encoding($false)))
Import-Module (Join-Path $scripts 'Setup.Core.psm1') -Force
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'Setup.ps1'), [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw ($parseErrors | Out-String) }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CodexGuardSetupWindow' }, $true)
if ($null -eq $definition) { throw 'The setup window function is missing.' }
. ([scriptblock]::Create($definition.Extent.Text))
$script:Passed = 0
function Assert-Window([bool]$Value, [string]$Message) {
    if (-not $Value) { throw ('FAILED: ' + $Message) }
    $script:Passed++
}
# Run the real event handlers with synthetic workers. No native installer,
# uninstaller, shutdown command or executable is reachable from this test.
$global:CodexGuardSetupWindowFixture = $null
function Start-CodexGuardSetupWorker {
    param($PackageRoot, $Mode)
    $state = $global:CodexGuardSetupWindowFixture
    $state.Starts++
    if ($state.StartError) { throw 'Fixture worker could not start.' }
    $state.LastMode = $Mode
    return $state.Worker
}
function Read-CodexGuardSetupWorkerResult {
    param($Worker)
    $state = $global:CodexGuardSetupWindowFixture
    $state.Reads++
    if ($state.ReadError) { throw 'Fixture result could not be read.' }
    return $state.Result
}
function Remove-CodexGuardSetupWorker {
    param($Worker)
    $global:CodexGuardSetupWindowFixture.Cleanups++
}
function New-WindowFixture([string]$Mode = 'Install') {
    $global:CodexGuardSetupWindowFixture = @{
        Starts=0; Reads=0; Cleanups=0; LastMode=''; StartError=$false; ReadError=$false
        Worker=[pscustomobject]@{ Process=[pscustomobject]@{ HasExited=$false; ExitCode=0 } }
        Result=[pscustomobject]@{ ok=$true; uninstalled=($Mode -eq 'Uninstall'); nativeInstalled=($Mode -eq 'Install'); error=$null }
    }
    $view = New-CodexGuardSetupWindow -PackageRoot $fixture -Mode $Mode
    $view.Form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $view.Form.Location = New-Object Drawing.Point(-12000, -12000)
    $view.Form.ShowInTaskbar = $false
    $view.Form.Show()
    [Windows.Forms.Application]::DoEvents()
    return $view
}
function Tick-Window($View) {
    $method = [Windows.Forms.Timer].GetMethod('OnTick', [Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($View.Timer, @([EventArgs]::Empty))
}
function Close-WindowFixture($View) {
    $View.Worker = $null
    $View.Form.Close()
    $View.Form.Dispose()
}
function Assert-Layout($View, [string]$Name) {
    $layout = $View.Form.Controls[0]
    $layout.PerformLayout()
    $intro = $layout.GetControlFromPosition(0, 1)
    $title = $layout.GetControlFromPosition(0, 0)
    $buttons = $layout.GetControlFromPosition(0, 4)
    $preferred = $intro.GetPreferredSize((New-Object Drawing.Size($intro.Width, 0)))
    Assert-Window ($intro.Height -ge $preferred.Height) ($Name + ' intro text fits its allocated height')
    Assert-Window ($title.Bottom + $title.Margin.Bottom -le $intro.Top) ($Name + ' heading does not overlap the introduction')
    Assert-Window ($intro.Bottom + $intro.Margin.Bottom -le $View.Progress.Top) ($Name + ' introduction does not overlap progress')
    Assert-Window ($View.Progress.Bottom + $View.Progress.Margin.Bottom -le $View.Details.Top) ($Name + ' progress does not overlap result details')
    Assert-Window ($View.Details.Bottom -le $buttons.Top - $buttons.Margin.Top) ($Name + ' details remain above buttons')
    Assert-Window ($buttons.Bottom -le $layout.ClientSize.Height - $layout.Padding.Bottom) ($Name + ' buttons remain inside the window')
    Assert-Window ($View.Details.Height -ge 100) ($Name + ' result details retain readable height')
    Assert-Window ($View.Action.Width -ge $View.Action.PreferredSize.Width) ($Name + ' action text fits the button')
    Assert-Window ($View.Close.Width -ge $View.Close.PreferredSize.Width) ($Name + ' close text fits the button')
    Assert-Window ($layout.Controls.Count -eq 5) ($Name + ' window contains only standalone installation controls')
    Assert-Window (@($layout.Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] -or $_ -is [Windows.Forms.LinkLabel] }).Count -eq 0) ($Name + ' no plugin option or dependency download links remain')
}

foreach ($mode in @('Install','Uninstall')) {
    foreach ($large in @($false, $true)) {
        $savedPath = $env:PATH
        $view = $null
        try {
            # No Node, Git or CLI lookup is available or required by this UI.
            $env:PATH = ''
            $view = New-WindowFixture $mode
            if ($large) {
                $view.Form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
                $view.Form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 13.5)
                $view.Form.MinimumSize = New-Object Drawing.Size(760, 500)
                $view.Form.Size = $view.Form.MinimumSize
            }
            [Windows.Forms.Application]::DoEvents()
            $name = $mode + $(if ($large) { '-large-font' } else { '-default' })
            Assert-Layout $view $name
            if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
                $bitmap = New-Object Drawing.Bitmap($view.Form.Width, $view.Form.Height)
                try {
                    $view.Form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
                    $bitmap.Save((Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('setup-' + $name + '.png')), [Drawing.Imaging.ImageFormat]::Png)
                }
                finally { $bitmap.Dispose() }
            }
        }
        finally { if ($null -ne $view) { Close-WindowFixture $view }; $env:PATH = $savedPath }
    }
}

$view = New-WindowFixture
try {
    $view.Action.PerformClick()
    Assert-Window ($global:CodexGuardSetupWindowFixture.Starts -eq 1) 'install click starts one synthetic worker'
    Assert-Window ($global:CodexGuardSetupWindowFixture.LastMode -eq 'Install') 'install click delegates install mode'
    Assert-Window (-not $view.Action.Enabled -and -not $view.Close.Enabled) 'actions stay disabled while the worker runs'
    $view.Form.Close()
    Assert-Window ($view.Form.Visible -and $null -ne $view.Worker) 'window cannot close while the worker runs'
    Tick-Window $view
    Assert-Window ($global:CodexGuardSetupWindowFixture.Reads -eq 0) 'timer cannot process an unfinished worker'
    $view.Worker.Process.HasExited = $true
    $view.Form.Close()
    Assert-Window ($view.Form.Visible -and $null -ne $view.Worker) 'window cannot close before the completed worker result is processed'
    Tick-Window $view
    Assert-Window ($view.ExitCode -eq 0 -and $null -eq $view.Worker) 'successful install result completes the window operation'
    Assert-Window ($view.Progress.Value -eq 100 -and $view.Close.Enabled -and -not $view.Action.Enabled) 'success displays completion with a usable close button'
    Assert-Window ($global:CodexGuardSetupWindowFixture.Cleanups -eq 1) 'completed operation cleans its worker once'
}
finally { Close-WindowFixture $view }

$view = New-WindowFixture 'Uninstall'
try {
    $view.Action.PerformClick()
    $view.Worker.Process.HasExited = $true
    Tick-Window $view
    Assert-Window ($view.ExitCode -eq 0 -and $view.Progress.Value -eq 100) 'successful uninstall reaches completion'
    Assert-Window ($global:CodexGuardSetupWindowFixture.LastMode -eq 'Uninstall') 'uninstall button delegates only uninstall mode'
}
finally { Close-WindowFixture $view }

$view = New-WindowFixture
try {
    $global:CodexGuardSetupWindowFixture.Result = [pscustomobject]@{ ok=$false; uninstalled=$false; nativeInstalled=$false; error='The running guard must have fresh unarmed status. Cancel automatic shutdown first.' }
    $view.Action.PerformClick()
    $view.Worker.Process.HasExited = $true
    Tick-Window $view
    Assert-Window ($view.ExitCode -eq 1 -and $view.Action.Enabled -and $view.Close.Enabled) 'armed refusal leaves a failed, retryable operation'
    Assert-Window ($view.Details.Text -notmatch 'fresh unarmed status') 'native armed refusal is translated into user-facing guidance'
    Assert-Window ($null -eq $view.Worker) 'failed result does not leave the window waiting on a finished worker'
}
finally { Close-WindowFixture $view }

$view = New-WindowFixture
try {
    $global:CodexGuardSetupWindowFixture.StartError = $true
    $view.Action.PerformClick()
    Assert-Window ($view.ExitCode -eq 1 -and $view.Action.Enabled -and $view.Close.Enabled) 'worker start failure restores usable controls'
    Assert-Window ($null -eq $view.Worker) 'worker start failure does not create a phantom operation'
}
finally { Close-WindowFixture $view }

$view = New-WindowFixture
try {
    $global:CodexGuardSetupWindowFixture.ReadError = $true
    $view.Action.PerformClick()
    $view.Worker.Process.HasExited = $true
    Tick-Window $view
    Assert-Window ($view.ExitCode -eq 1 -and $view.Action.Enabled -and $view.Close.Enabled) 'unreadable worker result reports a retryable failure'
    Assert-Window ($null -eq $view.Worker -and $global:CodexGuardSetupWindowFixture.Cleanups -eq 1) 'unreadable result still releases the completed worker'
}
finally { Close-WindowFixture $view }
Remove-Variable -Name CodexGuardSetupWindowFixture -Scope Global
Write-Output ('PASS: ' + $script:Passed + ' standalone setup window checks. All workers were synthetic; native installation and shutdown were not invoked.')
