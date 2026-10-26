[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $root 'CodexShutdownGuard.CodexStartup.psm1'
$module = Import-Module $modulePath -Force -PassThru
$script:Passed = 0
$script:FixtureProcesses = New-Object System.Collections.Generic.List[Diagnostics.Process]

function Assert-SmokeEqual($Expected, $Actual, [string]$Name) {
    if ($Expected -ne $Actual) { throw "FAILED: $Name; expected [$Expected], got [$Actual]." }
    $script:Passed++
}

function Start-SmokeFixture([Diagnostics.ProcessStartInfo]$Info) {
    $process = & $module { param($StartInfo) Invoke-CodexGuardStartupProcess -StartInfo $StartInfo } $Info
    if ($null -eq $process -or $process -isnot [Diagnostics.Process]) { throw 'Fixture did not return a real process handle.' }
    $script:FixtureProcesses.Add($process)
    if (-not $process.WaitForExit(5000)) { throw 'The isolated fixture did not exit within five seconds.' }
    Assert-SmokeEqual 0 $process.ExitCode 'isolated Windows PowerShell process exits successfully'
    return $process
}

$temporaryRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixtureRoot = Join-Path $temporaryRoot ('CodexGuardStartupProcessSmoke_' + [guid]::NewGuid().ToString('N'))
$unicode = ([char]0x4E2D).ToString() + [char]0x6587
$nativeRoot = Join-Path $fixtureRoot ($unicode + ' native with spaces')
$stateRoot = Join-Path $fixtureRoot ($unicode + ' state with spaces')
$disabledStateRoot = Join-Path $fixtureRoot ($unicode + ' disabled state with spaces')
$markerPath = Join-Path $stateRoot 'fixture-native-arguments.json'
$disabledMarkerPath = Join-Path $disabledStateRoot 'fixture-native-arguments.json'
$settingsPath = Join-Path $disabledStateRoot 'codex-startup-settings.json'
$encoding = New-Object Text.UTF8Encoding($false)

try {
    foreach ($path in @($nativeRoot, $stateRoot, $disabledStateRoot)) { [void][IO.Directory]::CreateDirectory($path) }
    # The only native entry in this fixture writes received arguments and exits.
    # No actual guard script is copied, imported, or invoked by this smoke test.
    $dummy = @'
[CmdletBinding()]
param([switch]$Tray, [switch]$FromCodexStartup, [string]$StateRoot)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $Tray -or -not $FromCodexStartup) { exit 4 }
if (-not [IO.Directory]::Exists($StateRoot)) { exit 5 }
$marker = [pscustomobject]@{ tray = [bool]$Tray; fromCodexStartup = [bool]$FromCodexStartup; stateRoot = $StateRoot; pid = $PID }
[IO.File]::WriteAllText((Join-Path $StateRoot 'fixture-native-arguments.json'), ($marker | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $nativeRoot 'CodexShutdownGuard.ps1'), $dummy, $encoding)
    $nativeInfo = & $module { param($Native, $State) New-CodexGuardStartupProcessInfo -NativeRoot $Native -StateRoot $State } $nativeRoot $stateRoot
    Assert-SmokeEqual $false $nativeInfo.UseShellExecute 'fixture uses direct process creation'
    Assert-SmokeEqual $true $nativeInfo.CreateNoWindow 'fixture requests no console window'
    Assert-SmokeEqual 'Hidden' ([string]$nativeInfo.WindowStyle) 'fixture requests hidden Windows PowerShell'
    Assert-SmokeEqual ([IO.Path]::GetFullPath($nativeRoot)) $nativeInfo.WorkingDirectory 'Unicode working directory is preserved'
    $nativeProcess = Start-SmokeFixture $nativeInfo
    Assert-SmokeEqual $true ([IO.File]::Exists($markerPath)) 'dummy native receives quoted Unicode and spaced state path'
    $marker = [IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-SmokeEqual $true $marker.tray 'real child receives Tray switch'
    Assert-SmokeEqual $true $marker.fromCodexStartup 'real child receives reverse-launch suppression switch'
    Assert-SmokeEqual ([IO.Path]::GetFullPath($stateRoot)) $marker.stateRoot 'real child receives complete Unicode and spaced state root'
    Assert-SmokeEqual $nativeProcess.Id $marker.pid 'marker was produced by the exact dummy process started by the test'

    # Exercise the real watcher entry only with disabled isolated settings.
    # Its native target is still the harmless dummy above, never the installed guard.
    foreach ($name in @('CodexShutdownGuard.Core.psm1', 'CodexShutdownGuard.CodexStartup.psm1', 'CodexShutdownGuard.CodexStartupWatcher.ps1')) {
        [IO.File]::WriteAllBytes((Join-Path $nativeRoot $name), [IO.File]::ReadAllBytes((Join-Path $root $name)))
    }
    [IO.File]::WriteAllText($settingsPath, '{"startGuardWithCodex":false}', $encoding)
    $watcherInfo = & $module {
        param($Native, $State, $Settings)
        New-CodexGuardStartupProcessInfo -NativeRoot $Native -StateRoot $State -SettingsPath $Settings -Watcher
    } $nativeRoot $disabledStateRoot $settingsPath
    Assert-SmokeEqual $true $watcherInfo.CreateNoWindow 'disabled watcher requests no console window'
    Assert-SmokeEqual 'Hidden' ([string]$watcherInfo.WindowStyle) 'disabled watcher requests hidden Windows PowerShell'
    [void](Start-SmokeFixture $watcherInfo)
    Assert-SmokeEqual $false ([IO.File]::Exists($disabledMarkerPath)) 'disabled watcher exits without launching even the dummy native'
    Assert-SmokeEqual $false ([IO.File]::Exists((Join-Path $disabledStateRoot 'codex-startup-session.json'))) 'disabled watcher does not consume a desktop session'
    Assert-SmokeEqual $false (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $disabledStateRoot) 'disabled watcher releases isolated mutex before exit'
    Write-Output ("PASS: {0} real Windows PowerShell startup checks; only an isolated dummy native and disabled fixture watcher were launched." -f $script:Passed)
}
finally {
    foreach ($process in $script:FixtureProcesses) {
        try {
            # This list contains only handles returned when starting our exact fixtures.
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
        }
        finally { $process.Dispose() }
    }
    Remove-Module $module -ErrorAction SilentlyContinue
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $allowedPrefix = $temporaryRoot + '\CodexGuardStartupProcessSmoke_'
    if (-not $resolvedFixture.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName($resolvedFixture) -ne $temporaryRoot) { throw 'Unsafe fixture cleanup path.' }
    if ([IO.Directory]::Exists($resolvedFixture)) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
