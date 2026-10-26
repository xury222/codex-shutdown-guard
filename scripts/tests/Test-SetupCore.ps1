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
$native = Join-Path $fixture 'native'
Write-Fixture (Join-Path $fixture 'product.json') '{"name":"codex-shutdown-guard","version":"1.2.0"}'
Write-Fixture (Join-Path $native 'CodexShutdownGuard.ps1') '# No guard exists in this fixture.'
Write-Fixture (Join-Path $native 'Install.ps1') @'
param()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'invoked.txt'), [string]$PSBoundParameters.Count)
$modePath = Join-Path $PSScriptRoot 'fixture-mode.txt'
$mode = if ([IO.File]::Exists($modePath)) { [IO.File]::ReadAllText($modePath) } else { '' }
if ($mode -eq 'armed') { throw 'The running guard must have fresh unarmed status. Cancel automatic shutdown first.' }
if ($mode -eq 'slow') { Start-Sleep -Milliseconds 900 }
if ($mode -eq 'silent') { return }
if ($mode -eq 'invalid') { return [pscustomobject]@{ Installed='true' } }
[pscustomobject]@{ Installed = $true; DefaultArmed = $false }
'@
Write-Fixture (Join-Path $native 'Uninstall.ps1') @'
param()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'uninstall-invoked.txt'), [string]$PSBoundParameters.Count)
[pscustomobject]@{ Uninstalled = $true }
'@
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'scripts'))
Copy-Item -LiteralPath (Join-Path $scripts 'Setup.ps1') -Destination (Join-Path $fixture 'scripts\Setup.ps1')
Copy-Item -LiteralPath (Join-Path $scripts 'Setup.Core.psm1') -Destination (Join-Path $fixture 'scripts\Setup.Core.psm1')
Assert-Setup ((Assert-CodexGuardSetupPackage $fixture).Version -eq '1.2.0') 'complete standalone fixture resolves product metadata'
$installed = Invoke-CodexGuardSetupOperation -PackageRoot $fixture
Assert-Setup ($installed.ok -and $installed.nativeInstalled -and -not $installed.uninstalled) 'default installs only fake native'
Assert-Setup ([IO.File]::ReadAllText((Join-Path $native 'invoked.txt')) -eq '0') 'setup does not replace native path or armed-state arguments'
Assert-Setup (-not (Test-Path -LiteralPath (Join-Path $fixture 'plugins'))) 'standalone installation needs no plugin directory'
Assert-Setup (-not (Get-Command Invoke-CodexGuardSetupOperation).Parameters.ContainsKey('InstallChatPlugin')) 'operation exposes no chat installation option'
Assert-Setup (-not (Get-Command Start-CodexGuardSetupWorker).Parameters.ContainsKey('InstallChatPlugin')) 'worker exposes no chat installation option'
Assert-Throws { Invoke-CodexGuardSetupOperation -PackageRoot $fixture -InstallChatPlugin } 'removed chat operation cannot be invoked'
Assert-Throws { Start-CodexGuardSetupWorker -PackageRoot $fixture -InstallChatPlugin } 'worker rejects the removed chat option'
Assert-Setup ($installed.nativeResult.DefaultArmed -eq $false) 'native unarmed startup result is preserved'
Write-Fixture (Join-Path $native 'fixture-mode.txt') 'armed'
$armed = Invoke-CodexGuardSetupOperation -PackageRoot $fixture
Assert-Setup (-not $armed.ok -and -not $armed.nativeInstalled -and $armed.error -match 'Cancel automatic shutdown first') 'armed rejection remains an explicit failed install'
Write-Fixture (Join-Path $native 'fixture-mode.txt') 'silent'
$silent = Invoke-CodexGuardSetupOperation -PackageRoot $fixture
Assert-Setup (-not $silent.ok) 'missing native result cannot report success'
Write-Fixture (Join-Path $native 'fixture-mode.txt') 'invalid'
$invalid = Invoke-CodexGuardSetupOperation -PackageRoot $fixture
Assert-Setup (-not $invalid.ok -and -not $invalid.nativeInstalled) 'native success confirmation must be a Boolean'
$removed = Invoke-CodexGuardSetupOperation -PackageRoot $fixture -Mode Uninstall
Assert-Setup ($removed.ok -and $removed.uninstalled -and -not $removed.nativeInstalled) 'uninstall invokes only fake native uninstaller'
Assert-Setup ([IO.File]::ReadAllText((Join-Path $native 'uninstall-invoked.txt')) -eq '0') 'uninstall retains native registration resolution'
Assert-Setup ((ConvertTo-CodexGuardSetupArgument $fixture) -ceq ('"' + $fixture + '"')) 'special path passed as one direct process argument'
Assert-Throws { ConvertTo-CodexGuardSetupArgument ('bad' + [char]34 + 'quote') } 'embedded quotes are rejected'
Assert-Throws { ConvertTo-CodexGuardSetupArgument ("bad`npath") } 'line-break arguments are rejected'
$missing = Join-Path $native 'Install.ps1'
$installerText = [IO.File]::ReadAllText($missing)
[IO.File]::Delete($missing)
Assert-Throws { Assert-CodexGuardSetupPackage $fixture } 'incomplete extraction is rejected'
Write-Fixture $missing $installerText

function Wait-FixtureWorker($Worker) {
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while (-not $Worker.Process.HasExited) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'Fixture worker timed out.' }
        Start-Sleep -Milliseconds 40
    }
}
Write-Fixture (Join-Path $native 'fixture-mode.txt') 'slow'
$savedPath = $env:PATH
$env:PATH = ''
$worker = Start-CodexGuardSetupWorker -PackageRoot $fixture -Mode Install
try {
    Assert-Setup ($null -eq (Read-CodexGuardSetupWorkerResult $worker)) 'asynchronous worker has no premature result'
    Assert-Throws { Remove-CodexGuardSetupWorker $worker } 'running worker cannot be cleaned up during installation'
    Wait-FixtureWorker $worker
    $workerResult = Read-CodexGuardSetupWorkerResult $worker
    Assert-Setup ($workerResult.ok -and $worker.Process.ExitCode -eq 0) 'real hidden PS5.1 worker returns successful JSON'
    Assert-Setup ([IO.File]::ReadAllText((Join-Path $native 'invoked.txt')) -eq '0') 'worker special-character package path reaches fixture without injection'
}
finally { if ($worker.Process.HasExited) { Remove-CodexGuardSetupWorker $worker }; $env:PATH = $savedPath }
Assert-Setup (-not [IO.Directory]::Exists($worker.Directory)) 'completed worker record is removed without recursive deletion'
Write-Fixture (Join-Path $native 'fixture-mode.txt') 'armed'
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
$manifest = Join-Path $fixture 'product.json'
Write-Fixture $manifest '{"name":"unrelated-product","version":"1.2.0"}'
Assert-Throws { Assert-CodexGuardSetupPackage $fixture } 'another product cannot use this setup'
Write-Fixture $manifest '{"name":"codex-shutdown-guard","version":"not-a-version"}'
Assert-Throws { Assert-CodexGuardSetupPackage $fixture } 'invalid package version is rejected'
Write-Fixture $manifest '{"name":"codex-shutdown-guard","version":"1.2.0"}'
$resultPath = Join-Path $root 'bad-result.json'
$fake = [pscustomobject]@{ Process=[pscustomobject]@{ HasExited=$true; ExitCode=1 }; ResultPath=$resultPath }
Assert-Throws { Read-CodexGuardSetupWorkerResult $fake } 'missing worker result cannot report success'
Write-Fixture $resultPath '{"ok":true}'
Assert-Throws { Read-CodexGuardSetupWorkerResult $fake } 'failed process cannot report success in JSON'
$fake.Process.ExitCode = 0
Write-Fixture $resultPath '{"ok":"true"}'
Assert-Throws { Read-CodexGuardSetupWorkerResult $fake } 'worker success must be a Boolean'
Write-Fixture $resultPath '{"unexpected":true}'
Assert-Throws { Read-CodexGuardSetupWorkerResult $fake } 'missing worker outcome is rejected'
Write-Fixture $resultPath '{broken'
Assert-Throws { Read-CodexGuardSetupWorkerResult $fake } 'malformed worker result is rejected'
Write-Output ('PASS: ' + $script:Passed + ' standalone setup checks; all application entry points were inert fixtures.')
