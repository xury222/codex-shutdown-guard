[CmdletBinding()]
param([string]$TestRoot = [IO.Path]::GetTempPath())
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $scripts 'Setup.Core.psm1') -Force
$script:Passed = 0
function Assert-Setup([bool]$Value, [string]$Label) {
    if (-not $Value) { throw ('FAILED: ' + $Label) }
    $script:Passed++
}
function Assert-Throws([scriptblock]$Body, [string]$Label) {
    $threw = $false; try { & $Body | Out-Null } catch { $threw = $true }
    Assert-Setup $threw $Label
}
function Write-Fixture([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
$root = Join-Path ([IO.Path]::GetFullPath($TestRoot)) ('CodexGuardSetupTest-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root ('Fixture space & apostrophe'' bang! (' + [char]0x4e2d + ')')
$plugin = Join-Path $fixture 'plugins\codex-shutdown-guard'
$native = Join-Path $plugin 'skills\codex-shutdown-guard\assets\native'
Write-Fixture (Join-Path $plugin 'plugin.json') '{"name":"codex-shutdown-guard","version":"1.1.1"}'
Write-Fixture (Join-Path $native 'Install.ps1') '# Fake package entry: never executed.'
Write-Fixture (Join-Path $native 'CodexShutdownGuard.ps1') '# No guard exists in this fixture.'
Write-Fixture (Join-Path $plugin 'Install.ps1') @'
param()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'invoked.txt'), [string]$PSBoundParameters.Count)
$modePath = Join-Path $PSScriptRoot 'fixture-mode.txt'
$mode = if ([IO.File]::Exists($modePath)) { [IO.File]::ReadAllText($modePath) } else { '' }
if ($mode -eq 'armed') { throw 'The running guard must have fresh unarmed status. Cancel automatic shutdown first.' }
if ($mode -eq 'slow') { Start-Sleep -Milliseconds 900 }
if ($mode -eq 'silent') { return }
[pscustomobject]@{ Installed = $true; DefaultArmed = $false }
'@
Write-Fixture (Join-Path $plugin 'Uninstall.ps1') @'
param()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'uninstall-invoked.txt'), [string]$PSBoundParameters.Count)
[pscustomobject]@{ Uninstalled = $true }
'@
Write-Fixture (Join-Path $fixture 'scripts\Setup.Plugin.psm1') @'
function Install-CodexGuardChatPlugin {
    param([string]$PackageRoot)
    $path = Join-Path $PackageRoot 'plugin-mode.txt'
    $mode = if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path) } else { '' }
    if ($mode -eq 'throw') { throw 'Fixture CLI launch failed.' }
    if ($mode -eq 'fail') { return [pscustomobject]@{ ok=$false; message='Fixture dependency is missing.' } }
    if ($mode -eq 'pending') { return [pscustomobject]@{ ok=$false; code='operation-pending'; message='Fixture CLI outcome is uncertain.'; details='A child may still be running.' } }
    return [pscustomobject]@{ ok=$true; message='Fixture plugin installed.' }
}
Export-ModuleMember -Function Install-CodexGuardChatPlugin
'@
Copy-Item -LiteralPath (Join-Path $scripts 'Setup.ps1') -Destination (Join-Path $fixture 'scripts\Setup.ps1')
Copy-Item -LiteralPath (Join-Path $scripts 'Setup.Core.psm1') -Destination (Join-Path $fixture 'scripts\Setup.Core.psm1')
Assert-Setup ((Assert-CodexGuardSetupPackage $fixture).Version -eq '1.1.1') 'complete fixture resolves metadata'
$installed = Invoke-CodexGuardSetupOperation -PackageRoot $fixture
Assert-Setup ($installed.ok -and $installed.nativeInstalled -and -not $installed.pluginInstalled) 'default installs only fake native'
Assert-Setup ([IO.File]::ReadAllText((Join-Path $plugin 'invoked.txt')) -eq '0') 'setup does not replace native path or armed-state arguments'
$combined = Invoke-CodexGuardSetupOperation -PackageRoot $fixture -InstallChatPlugin
Assert-Setup ($combined.ok -and $combined.nativeInstalled -and $combined.pluginInstalled) 'optional chat success is required for combined success'
Write-Fixture (Join-Path $fixture 'plugin-mode.txt') 'fail'
$partial = Invoke-CodexGuardSetupOperation -PackageRoot $fixture -InstallChatPlugin
Assert-Setup (-not $partial.ok -and $partial.nativeInstalled -and -not $partial.pluginInstalled) 'plugin failure preserves and reports native installation'
Assert-Setup ($partial.error -eq 'Fixture dependency is missing.') 'actionable plugin failure reaches result'
Write-Fixture (Join-Path $fixture 'plugin-mode.txt') 'pending'
$pending = Invoke-CodexGuardSetupOperation -PackageRoot $fixture -InstallChatPlugin
Assert-Setup (-not $pending.ok -and $pending.nativeInstalled -and $pending.pluginOutcome -eq 'operation-pending') 'uncertain plugin outcome is distinguished from confirmed failure'
Assert-Setup ($pending.error -match 'A child may still be running') 'uncertain CLI details reach the interface'
Write-Fixture (Join-Path $fixture 'plugin-mode.txt') 'throw'
$failed = Invoke-CodexGuardSetupOperation -PackageRoot $fixture -InstallChatPlugin
Assert-Setup (-not $failed.ok -and $failed.error -eq 'Fixture CLI launch failed.') 'CLI exceptions do not produce success'
Write-Fixture (Join-Path $plugin 'fixture-mode.txt') 'armed'
$armed = Invoke-CodexGuardSetupOperation -PackageRoot $fixture
Assert-Setup (-not $armed.ok -and -not $armed.nativeInstalled -and $armed.error -match 'Cancel automatic shutdown first') 'armed rejection remains an explicit failed install'
Write-Fixture (Join-Path $plugin 'fixture-mode.txt') 'silent'
$silent = Invoke-CodexGuardSetupOperation -PackageRoot $fixture
Assert-Setup (-not $silent.ok) 'missing native result cannot report success'
$removed = Invoke-CodexGuardSetupOperation -PackageRoot $fixture -Mode Uninstall
Assert-Setup ($removed.ok -and $removed.uninstalled -and -not $removed.nativeInstalled) 'uninstall invokes only fake native uninstaller'
Assert-Setup ([IO.File]::ReadAllText((Join-Path $plugin 'uninstall-invoked.txt')) -eq '0') 'uninstall retains native registration resolution'
$badMode = Invoke-CodexGuardSetupOperation -PackageRoot $fixture -Mode Uninstall -InstallChatPlugin
Assert-Setup (-not $badMode.ok) 'uninstall cannot install chat plugin'
Assert-Setup ((ConvertTo-CodexGuardSetupArgument $fixture) -ceq ('"' + $fixture + '"')) 'special path passed as one direct process argument'
Assert-Throws { ConvertTo-CodexGuardSetupArgument ('bad' + [char]34 + 'quote') } 'embedded quotes are rejected'
Assert-Throws { ConvertTo-CodexGuardSetupArgument ("bad`npath") } 'line-break arguments are rejected'
$missing = Join-Path $native 'Install.ps1'
[IO.File]::Delete($missing)
Assert-Throws { Assert-CodexGuardSetupPackage $fixture } 'incomplete extraction is rejected'
Write-Fixture $missing '# Fake package entry.'

function Wait-FixtureWorker($Worker) {
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while (-not $Worker.Process.HasExited) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'Fixture worker timed out.' }
        Start-Sleep -Milliseconds 40
    }
}
Write-Fixture (Join-Path $plugin 'fixture-mode.txt') 'slow'
$worker = Start-CodexGuardSetupWorker -PackageRoot $fixture -Mode Install
try {
    Assert-Setup ($null -eq (Read-CodexGuardSetupWorkerResult $worker)) 'asynchronous worker has no premature result'
    Wait-FixtureWorker $worker
    $workerResult = Read-CodexGuardSetupWorkerResult $worker
    Assert-Setup ($workerResult.ok -and $worker.Process.ExitCode -eq 0) 'real hidden PS5.1 worker returns successful JSON'
    Assert-Setup ([IO.File]::ReadAllText((Join-Path $plugin 'invoked.txt')) -eq '0') 'worker special-character package path reaches fixture without injection'
}
finally { if ($worker.Process.HasExited) { Remove-CodexGuardSetupWorker $worker } }
Assert-Setup (-not [IO.Directory]::Exists($worker.Directory)) 'completed worker record is removed without recursive deletion'
Write-Fixture (Join-Path $plugin 'fixture-mode.txt') 'armed'
$worker = Start-CodexGuardSetupWorker -PackageRoot $fixture -Mode Install
try {
    Wait-FixtureWorker $worker
    $workerResult = Read-CodexGuardSetupWorkerResult $worker
    Assert-Setup (-not $workerResult.ok -and $worker.Process.ExitCode -eq 1) 'real failed worker preserves failure and exit code'
}
finally { if ($worker.Process.HasExited) { Remove-CodexGuardSetupWorker $worker } }
$worker = Start-CodexGuardSetupWorker -PackageRoot $fixture -Mode Uninstall
try {
    Wait-FixtureWorker $worker
    $workerResult = Read-CodexGuardSetupWorkerResult $worker
    Assert-Setup ($workerResult.ok -and $workerResult.uninstalled) 'real uninstall worker invokes fixture only'
}
finally { if ($worker.Process.HasExited) { Remove-CodexGuardSetupWorker $worker } }
Write-Output ('PASS: ' + $script:Passed + ' one-click setup checks; every native/CLI entry was an isolated fixture.')
