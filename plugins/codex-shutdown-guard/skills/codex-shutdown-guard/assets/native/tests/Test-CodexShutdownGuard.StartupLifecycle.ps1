[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'CodexShutdownGuard.Installation.psm1') -Force
$script:Passed = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -cne $Actual) { throw "FAILED: $Name; expected [$Expected], got [$Actual]." }
    $script:Passed++
}
function Assert-True([bool]$Value, [string]$Name) { Assert-Equal $true $Value $Name }
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Name
}
function Read-ScriptAst([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count ('script parses: ' + [IO.Path]::GetFileName($Path))
    return $ast
}
$installAst = Read-ScriptAst (Join-Path $root 'Install.ps1')
$uninstallAst = Read-ScriptAst (Join-Path $root 'Uninstall.ps1')
$moduleAst = Read-ScriptAst (Join-Path $root 'CodexShutdownGuard.Installation.psm1')
$mainAst = Read-ScriptAst (Join-Path $root 'CodexShutdownGuard.ps1')
$watcherAst = Read-ScriptAst (Join-Path $root 'CodexShutdownGuard.CodexStartupWatcher.ps1')
function Get-FunctionScript([string]$Name) {
    $definition = $moduleAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if ($null -eq $definition) { throw "Missing lifecycle helper: $Name" }
    return [scriptblock]::Create($definition.Extent.Text)
}
$upgradeDefinition = Get-FunctionScript 'Assert-CodexGuardUpgradeUnarmed'
$stopDefinition = Get-FunctionScript 'Stop-CodexGuardNativeForInstallation'

# Extract only the lifecycle functions; every process/mutex lookup below is a local mock.
$fixturePath = Join-Path $PSScriptRoot ('CodexGuardLifecycle-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixturePath)
try {
    $statusPath = Join-Path $fixturePath 'status.json'
    function Invoke-UpgradeFixture([bool]$Running) {
        function Test-CodexGuardNativeRunning { param($StateRoot) return $Running }
        . $upgradeDefinition
        Assert-CodexGuardUpgradeUnarmed -StateRoot $fixturePath
    }
    Invoke-UpgradeFixture $false
    $script:Passed++
    Assert-Throws { Invoke-UpgradeFixture $true } 'upgrade refuses running guard with missing status'
    foreach ($status in @(
        @{ armed=$true; updatedAtUtc=[datetime]::UtcNow.ToString('o') },
        @{ armed='false'; updatedAtUtc=[datetime]::UtcNow.ToString('o') },
        @{ armed=$false; updatedAtUtc=[datetime]::UtcNow.AddMinutes(-2).ToString('o') }
    )) {
        [IO.File]::WriteAllText($statusPath, ($status | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        Assert-Throws { Invoke-UpgradeFixture $true } 'upgrade refuses armed, malformed or stale status without stopping guard'
    }
    [IO.File]::WriteAllText($statusPath, (@{ armed=$false; updatedAtUtc=[datetime]::UtcNow.ToString('o') } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Invoke-UpgradeFixture $true
    $script:Passed++

    function New-StopFixture {
        $process = [pscustomobject]@{ ExitCode=0; WaitResult=$true; Disposed=$false }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $this.WaitResult }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed=$true }
        return [pscustomobject]@{ Running=$true; HasMain=$true; Checks=0; Launches=0; Arguments=''; Hidden=$false; Process=$process }
    }
    function Invoke-StopFixture($Fixture) {
        function Test-CodexGuardNativeRunning { param($StateRoot) $Fixture.Checks++; return $Fixture.Running -and $Fixture.Checks -eq 1 }
        function Test-Path { param($LiteralPath, $PathType) return $Fixture.HasMain }
        function Start-Process {
            param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
            $Fixture.Launches++; $Fixture.Arguments=$ArgumentList; $Fixture.Hidden=($WindowStyle -eq 'Hidden')
            return $Fixture.Process
        }
        . $stopDefinition
        Stop-CodexGuardNativeForInstallation -InstallRoot 'C:\isolated fixture\CodexShutdownGuard' -StateRoot 'C:\isolated fixture\state'
    }
    $stop = New-StopFixture; $stop.Running=$false
    Invoke-StopFixture $stop
    Assert-Equal 0 $stop.Launches 'absent native guard creates no Stop subprocess'
    $stop = New-StopFixture; $stop.HasMain=$false
    Assert-Throws { Invoke-StopFixture $stop } 'running guard with missing script prevents file deletion'
    Assert-Equal 0 $stop.Launches 'missing script starts no replacement process'
    $stop = New-StopFixture; $stop.Process.WaitResult=$false
    Assert-Throws { Invoke-StopFixture $stop } 'hung stop request prevents deletion'
    Assert-True $stop.Process.Disposed 'hung request process handle is released'
    $stop = New-StopFixture; $stop.Process.ExitCode=1
    Assert-Throws { Invoke-StopFixture $stop } 'failed stop request prevents deletion'
    $stop = New-StopFixture
    Invoke-StopFixture $stop
    Assert-Equal 1 $stop.Launches 'running native guard receives exactly one stop request'
    Assert-True $stop.Hidden 'stop helper subprocess is hidden'
    Assert-True $stop.Process.Disposed 'successful request process handle is released'
    Assert-True ($stop.Arguments -match '-Stop -StateRoot "C:\\isolated fixture\\state"') 'stop request targets the exact selected state root'
    Assert-Equal 2 $stop.Checks 'stop success is confirmed through native mutex disappearance'
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixturePath)
    if (-not ([IO.Path]::GetDirectoryName($resolved)).Equals([IO.Path]::GetFullPath($PSScriptRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolved)).StartsWith('CodexGuardLifecycle-', [StringComparison]::Ordinal)) { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

foreach ($ast in @($installAst, $uninstallAst)) {
    $stateChangeBlock = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$null -ne $previousRegistration' }, $false)
    Assert-True ($null -ne $stateChangeBlock) 'registered state switch has a preflight guard'
    $stateChangeScript = [scriptblock]::Create($stateChangeBlock.Extent.Text)
    function Invoke-StateChangeFixture($Fixture) {
        $previousRegistration = [pscustomobject]@{ stateRoot='C:\isolated fixture\previous-state' }
        $StateRoot = $Fixture.Target
        function Test-CodexGuardNativeRunning { param($StateRoot) $Fixture.NativeChecks++; return $Fixture.NativeRunning }
        function Test-CodexGuardCodexStartupWatcherRunning { param($StateRoot) $Fixture.WatcherChecks++; return $Fixture.WatcherRunning }
        . $stateChangeScript
    }
    $change = [pscustomobject]@{ Target='C:\isolated fixture\previous-state'; NativeRunning=$true; WatcherRunning=$true; NativeChecks=0; WatcherChecks=0 }
    Invoke-StateChangeFixture $change
    Assert-Equal 0 ($change.NativeChecks + $change.WatcherChecks) 'unchanged state does not reject its own running guard'
    $change.Target='C:\isolated fixture\new-state'
    Assert-Throws { Invoke-StateChangeFixture $change } 'switching state while old native guard runs is refused'
    $change.NativeRunning=$false
    Assert-Throws { Invoke-StateChangeFixture $change } 'switching state while old watcher runs is refused'
    $change.WatcherRunning=$false
    Invoke-StateChangeFixture $change
    $script:Passed++
    $watcherStop = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-CodexGuardCodexStartupWatcher' }, $true)
    $nativeStop = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-CodexGuardNativeForInstallation' }, $true)
    Assert-True ($null -ne $watcherStop -and $null -ne $nativeStop -and $watcherStop.Extent.StartOffset -lt $nativeStop.Extent.StartOffset) 'watcher stops before native guard lifecycle change'
    Assert-True ($stateChangeBlock.Extent.EndOffset -lt $watcherStop.Extent.StartOffset) 'state switch refusal precedes process stops and owned-file mutation'
    Assert-True ($ast.Extent.Text -match 'Resolve-CodexGuardStateRoot -StateRoot \$StateRoot -RegistrationPath \$RegistrationPath') 'install and uninstall use the shared registered state root'
    Assert-True ($ast.Extent.Text -notmatch '\bStop-Process\b|taskkill') 'lifecycle never forcibly terminates Codex or another process'
}
$copyCommand = $installAst.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Copy-Item' }, $true)
$upgradeCheck = $installAst.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-CodexGuardUpgradeUnarmed' }, $true)
Assert-True ($null -ne $copyCommand -and $upgradeCheck.Extent.StartOffset -lt $copyCommand.Extent.StartOffset) 'upgrade validates unarmed status before replacing files'
Assert-True ($uninstallAst.Extent.Text -notmatch '\-Recurse|\[IO\.Directory\]::Delete\(\$InstallRoot, \$true\)') 'uninstall has no recursive product-directory deletion'
Assert-True ($installAst.Extent.Text -notmatch "-Mode 'Arm'|\s-Arm\b") 'installer starts the normal unarmed tray only'
Assert-True ($installAst.Extent.Text -match "'CodexShutdownGuard\.lnk'") 'Windows login guard shortcut remains supported'
Assert-True ($installAst.Extent.Text -match '\$trayArguments.+-StateRoot' -and $installAst.Extent.Text -match '\$showArguments.+-StateRoot' -and $installAst.Extent.Text -match '\$watcherArguments.+-StateRoot') 'all installer shortcuts use the selected state root'
Assert-True ($mainAst.Extent.Text -match '\$script:StateRoot = Resolve-CodexGuardStateRoot -StateRoot \$StateRoot') 'main CLI and VBS defaults follow registered state for Show, Arm, Disarm and Stop'
Assert-True ($watcherAst.Extent.Text -match 'Resolve-CodexGuardStateRoot') 'manual watcher default follows registered state'
Write-Output ("Passed {0} startup lifecycle checks. Process and mutex behavior used mocks; only the generated workspace JSON fixture changed." -f $script:Passed)
