[CmdletBinding()]
param([string]$OutputDirectory)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$root=Split-Path $PSScriptRoot -Parent
$text=[IO.File]::ReadAllText((Join-Path $root 'CodexShutdownGuard.ps1'))
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count){ throw 'Main script syntax is invalid.' }
$script:Passed=0; $script:ArmCalls=0; $script:DisarmCalls=0; $script:PollCalls=0; $script:StatusWrites=0; $script:UsageUpdates=0
function Check($expected,$actual,[string]$name){if($expected -ne $actual){throw "FAILED: $name expected [$expected], got [$actual]."};$script:Passed++}
foreach($name in @('Switch-GuardShutdown','Update-TrayPresentation')){
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Get-CodexGuardAutoStartSetting { param($Path) return $false }
function Get-CodexGuardStartWithCodexSetting { param($Path) return $false }
function Get-PhaseLabel { param($Phase) return $Phase }
function Get-RemainingSeconds { param($Runtime,$NowUtc) return $null }
function Show-GuardBalloon { throw 'No production action may run while constructing the test menu.' }
function Request-Arm { $script:ArmCalls++ }
function Request-Disarm { $script:DisarmCalls++; $script:Runtime.Armed=$false }
function Invoke-GuardPoll { $script:PollCalls++; $script:Runtime.Armed=$true; Update-TrayPresentation }
function Write-GuardStatus { param($Running,$Runtime,$Snapshot,$AppAvailable,$AppReason) $script:StatusWrites++; return @{} }
function Update-UsagePanel { $script:UsageUpdates++ }
function Invoke-NativeShutdownSchedule { throw 'Shutdown is forbidden in tray tests.' }
function Invoke-NativeShutdownAbort { throw 'Native shutdown commands are forbidden in tray tests.' }
$script:CodexLaunchSettingsPath='isolated-launch-setting'
$script:CodexStartupSettingsPath='isolated-startup-setting'
$script:Runtime=[pscustomobject]@{Armed=$false;Phase='Disarmed'}
$script:LastSnapshot=[pscustomobject]@{ActiveCount=2;UnknownCount=0;IgnoredCount=0}
$script:LastAppAvailable=$true; $script:LastAppReason=''
$script:NotifyIcon=[pscustomobject]@{Text='';ContextMenuStrip=$null}
$begin=$text.IndexOf('$contextMenu = New-Object Windows.Forms.ContextMenuStrip',[StringComparison]::Ordinal)
$end=$text.IndexOf('$script:NotifyIcon.ContextMenuStrip = $contextMenu',$begin,[StringComparison]::Ordinal)
if($begin -lt 0 -or $end -lt 0){throw 'Cannot find the actual tray construction block.'}
. ([scriptblock]::Create($text.Substring($begin,$end-$begin)))
try {
    Check $false ($text.Contains('$script:DisarmMenuItem')) 'duplicate cancel menu is removed'
    Check $false ($text.Contains('$statusMenuItem')) 'status dialog menu is removed'
    Check $false ($text.Contains('function Get-StatusDialogText')) 'obsolete status dialog helper is removed'
    Check 1 @($contextMenu.Items | Where-Object {[object]::ReferenceEquals($_,$script:ArmMenuItem)}).Count 'exactly one shutdown menu item exists'
    Check 1 @($contextMenu.Items | Where-Object {[object]::ReferenceEquals($_,$script:AutoStartGuardMenuItem)}).Count 'new inverse startup option is present'
    Check $false $script:ArmMenuItem.CheckOnClick 'shutdown checkmark reflects committed runtime state'
    Check $false $script:AutoStartGuardMenuItem.Checked 'new startup option is off by default'
    $handler=$ast.Find({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Click' -and $node.Expression.Extent.Text -eq '$script:ArmMenuItem'},$true)
    Check $true ($null -ne $handler) 'actual tray click handler exists'
    . ([scriptblock]::Create($handler.Extent.Text))
    Update-TrayPresentation
    Check $false $script:ArmMenuItem.Checked 'unarmed state has no checkmark'
    $script:ArmMenuItem.PerformClick()
    Check 1 $script:ArmCalls 'first click uses native arm request'
    Check 1 $script:PollCalls 'first click polls to commit arm state'
    Check $true $script:ArmMenuItem.Checked 'armed runtime is reflected in the same menu item'
    Check 0 $script:DisarmCalls 'enabling does not invoke cancellation'
    $script:ArmMenuItem.PerformClick()
    Check 1 $script:DisarmCalls 'second click uses native cancellation path'
    Check 1 $script:ArmCalls 'cancellation does not arm again'
    Check $false $script:ArmMenuItem.Checked 'same menu item clears its checkmark after cancellation'
    Check 1 $script:StatusWrites 'cancellation publishes updated status'
    Check 1 $script:UsageUpdates 'cancellation updates the usage panel'
    Check 2 ([regex]::Matches($text,'\.Add_Click\(\{ Switch-GuardShutdown \}\)').Count) 'panel and tray share one toggle handler'
    Check $true ($text.Contains('-not $FromCodexStartup -and $script:AutoStartCodexMenuItem.Checked')) 'inverse startup cannot trigger reverse Codex launch'
    if($OutputDirectory){
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
        $contextMenu.Show((New-Object Drawing.Point(20,20)))
        [Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($contextMenu.Width,$contextMenu.Height)
        try{$contextMenu.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$bitmap.Save((Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) 'guard-tray-menu.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose();$contextMenu.Hide()}
    }
    Write-Output "PASS: $script:Passed tray toggle assertions. Native shutdown was not invoked."
}
finally{$contextMenu.Dispose()}
