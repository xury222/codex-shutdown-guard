[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$nativeRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $nativeRoot 'CodexShutdownGuard.Installation.psm1') -Force
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
function Write-Utf8([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Read-Utf8([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
function New-Marker([string]$Root, [string]$Product = 'CodexShutdownGuard', [string]$RecordedRoot = $Root) {
    Write-Utf8 (Join-Path $Root '.codex-shutdown-guard-install.json') ([ordered]@{ product=$Product; installRoot=$RecordedRoot } | ConvertTo-Json)
}

$temporaryParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$fixtureRoot = Join-Path $temporaryParent ('CodexGuardPortable-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
try {
    $stateRoot = Join-Path $fixtureRoot 'state'
    $defaultRoot = Join-Path $fixtureRoot 'Programs\CodexShutdownGuard'
    $legacyRoot = Join-Path $fixtureRoot 'legacy\CodexShutdownGuard'
    $customRoot = Join-Path $fixtureRoot 'custom\CodexShutdownGuard'
    $registrationPath = Join-Path $stateRoot 'installation.json'
    $resolve = @{ StateRoot=$stateRoot; RegistrationPath=$registrationPath; DefaultInstallRoot=$defaultRoot; LegacyInstallRoot=$legacyRoot }
    Assert-Equal $defaultRoot (Resolve-CodexGuardInstallRoot @resolve) 'fresh default is per-user Programs root'
    Assert-True (-not (Test-Path -LiteralPath $stateRoot)) 'resolution creates no state directory'
    New-Marker $legacyRoot
    Assert-Equal $legacyRoot (Resolve-CodexGuardInstallRoot @resolve) 'legacy marked installation is discovered'
    New-Marker $defaultRoot
    Assert-Equal $defaultRoot (Resolve-CodexGuardInstallRoot @resolve) 'marked default precedes marked legacy'
    Write-CodexGuardInstallationRegistration -InstallRoot $customRoot -StateRoot $stateRoot -RegistrationPath $registrationPath | Out-Null
    Assert-Equal $customRoot (Resolve-CodexGuardInstallRoot @resolve) 'missing registered installation retains repair identity'
    Assert-Equal $legacyRoot (Resolve-CodexGuardInstallRoot @resolve -InstallRoot $legacyRoot) 'explicit install root wins over registration'
    New-Marker $customRoot
    Assert-Equal $customRoot (Resolve-CodexGuardInstallRoot @resolve) 'registered marked installation wins over defaults'
    New-Marker $customRoot 'OtherProduct'
    Assert-Throws { Resolve-CodexGuardInstallRoot @resolve } 'wrong registered product cannot silently fall back'
    New-Marker $customRoot 'CodexShutdownGuard' $legacyRoot
    Assert-Throws { Resolve-CodexGuardInstallRoot @resolve } 'marker from another root is rejected'
    New-Marker $customRoot
    Write-Utf8 $registrationPath '{broken'
    Assert-Throws { Resolve-CodexGuardInstallRoot @resolve } 'malformed registration cannot silently fall back'
    Write-Utf8 $registrationPath '{"schemaVersion":1,"product":"OtherProduct","installRoot":"C:\\fake"}'
    Assert-Throws { Resolve-CodexGuardInstallRoot @resolve } 'wrong registration product is rejected'
    [IO.File]::Delete($registrationPath)
    Write-CodexGuardInstallationRegistration -InstallRoot $customRoot -StateRoot $stateRoot -RegistrationPath $registrationPath | Out-Null
    Write-CodexGuardInstallationRegistration -InstallRoot $customRoot -StateRoot $stateRoot -RegistrationPath $registrationPath | Out-Null
    $registration = Get-CodexGuardInstallationRegistration -StateRoot $stateRoot -RegistrationPath $registrationPath
    Assert-Equal 1 $registration.schemaVersion 'registration schema is version one'
    Assert-Equal 'CodexShutdownGuard' $registration.product 'registration product is stable'
    Assert-Equal $stateRoot $registration.stateRoot 'registration remembers custom native state location'
    Assert-Equal (Join-Path (Get-CodexGuardStateRoot) 'installation.json') (Get-CodexGuardRegistrationPath -StateRoot $stateRoot) 'default registration remains at a fixed per-user discovery path'
    Assert-Equal $stateRoot (Resolve-CodexGuardStateRoot -RegistrationPath $registrationPath) 'default native state follows registration'
    Assert-Equal (Join-Path $fixtureRoot 'explicit-state') (Resolve-CodexGuardStateRoot -StateRoot (Join-Path $fixtureRoot 'explicit-state') -RegistrationPath $registrationPath) 'explicit native state wins over registration'
    Write-Utf8 $registrationPath ([ordered]@{ schemaVersion=1; product='CodexShutdownGuard'; installRoot=$customRoot } | ConvertTo-Json)
    Assert-Equal (Get-CodexGuardStateRoot) (Resolve-CodexGuardStateRoot -RegistrationPath $registrationPath) 'legacy registration without stateRoot keeps old default'
    Write-Utf8 $registrationPath ([ordered]@{ schemaVersion=1; product='CodexShutdownGuard'; installRoot=$customRoot; stateRoot='relative-state' } | ConvertTo-Json)
    Assert-Throws { Resolve-CodexGuardStateRoot -RegistrationPath $registrationPath } 'relative registered state root is rejected'
    [IO.File]::Delete($registrationPath)
    Write-CodexGuardInstallationRegistration -InstallRoot $customRoot -StateRoot $stateRoot -RegistrationPath $registrationPath | Out-Null
    Assert-True (-not ([IO.File]::ReadAllBytes($registrationPath)[0] -eq 239)) 'registration is UTF8 without BOM'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $stateRoot -Filter '*.tmp').Count 'atomic registration leaves no temporary files'
    Assert-Equal $false (Remove-CodexGuardInstallationRegistration -InstallRoot $legacyRoot -StateRoot $stateRoot -RegistrationPath $registrationPath) 'uninstall cannot remove another root registration'
    Assert-True (Test-Path -LiteralPath $registrationPath) 'mismatched registration remains'
    Assert-Equal $true (Remove-CodexGuardInstallationRegistration -InstallRoot $customRoot -StateRoot $stateRoot -RegistrationPath $registrationPath) 'matching registration can be removed'

    Assert-Throws { Assert-CodexGuardInstallRoot -InstallRoot 'C:\' -StateRoot $stateRoot -RegistrationPath $registrationPath } 'volume root is refused'
    Assert-Throws { Assert-CodexGuardInstallRoot -InstallRoot $fixtureRoot -StateRoot $stateRoot -RegistrationPath $registrationPath } 'unrelated directory is refused'
    Assert-Throws { Assert-CodexGuardInstallRoot -InstallRoot $defaultRoot -StateRoot $defaultRoot } 'state and installation must differ'
    Assert-Throws { Assert-CodexGuardInstallRoot -InstallRoot $defaultRoot -StateRoot (Join-Path $defaultRoot 'state') } 'installation cannot contain state'
    Assert-Throws { Assert-CodexGuardInstallRoot -InstallRoot $defaultRoot -StateRoot $stateRoot -RegistrationPath (Join-Path $defaultRoot 'installation.json') } 'installation cannot contain registration'
    $unownedRoot = Join-Path $fixtureRoot 'unowned\CodexShutdownGuard'
    Write-Utf8 (Join-Path $unownedRoot 'keep.txt') 'unrelated data'
    Assert-Throws { & (Join-Path $nativeRoot 'Install.ps1') -InstallRoot $unownedRoot -StateRoot $stateRoot -RegistrationPath $registrationPath -NoStart -NoShortcuts } 'installer cannot overwrite an unmarked nonempty folder'
    Assert-Equal 'unrelated data' (Read-Utf8 (Join-Path $unownedRoot 'keep.txt')) 'failed install preserves unowned content'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $unownedRoot 'CodexShutdownGuard.ps1'))) 'failed install writes no program file'

    # The real installer runs only against this independent fixture. NoStart/NoShortcuts prevent process and COM work.
    $installedRoot = Join-Path $fixtureRoot 'installed\CodexShutdownGuard'
    $installed = & (Join-Path $nativeRoot 'Install.ps1') -InstallRoot $installedRoot -StateRoot $stateRoot -RegistrationPath $registrationPath -NoStart -NoShortcuts
    Assert-True $installed.Installed 'isolated clean install succeeds'
    Assert-Equal $false $installed.Started 'NoStart launches neither native guard nor watcher'
    Assert-Equal $false $installed.DefaultArmed 'fresh install does not arm shutdown'
    Assert-True ($null -eq $installed.StartupShortcut -and $null -eq $installed.DesktopShortcut) 'NoShortcuts avoids user Startup and Desktop'
    Assert-Equal $installedRoot (Get-CodexGuardInstallationRegistration -StateRoot $stateRoot -RegistrationPath $registrationPath).installRoot 'successful install publishes registration'
    Assert-Equal (Read-Utf8 (Join-Path $nativeRoot 'config.default.json')) (Read-Utf8 (Join-Path $installedRoot 'config.json')) 'fresh config uses packaged defaults'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedRoot 'CodexShutdownGuard.Installation.psm1')) 'shared resolver is installed for future upgrades'
    Assert-True (-not (Test-CodexGuardNativeRunning -StateRoot $stateRoot)) 'isolated install created no native guard'

    $customConfig = "{`r`n  `"pollSeconds`": 99, `"ownerField`": `"keep exactly`"`r`n}`r`n"
    Write-Utf8 (Join-Path $installedRoot 'config.json') $customConfig
    $preferenceFiles = @('ignored-tasks.json','codex-launch-settings.json','codex-startup-settings.json','usage-panel-state.json','config.json')
    foreach ($name in $preferenceFiles) {
        $value = if ($name -eq 'codex-startup-settings.json') { '{ "startGuardWithCodex": true, "ownerField": "preserved" }' } else { '{ "ownerField": "preserved ' + $name + '" }' }
        Write-Utf8 (Join-Path $stateRoot $name) $value
    }
    $before = @{}
    foreach ($name in $preferenceFiles) { $before[$name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $stateRoot $name))) }
    $upgraded = & (Join-Path $nativeRoot 'Install.ps1') -RegistrationPath $registrationPath -NoStart -NoShortcuts
    Assert-Equal $installedRoot $upgraded.InstallRoot 'upgrade locates registered root without hardcoded drive'
    Assert-True $upgraded.StartWithCodexEnabled 'upgrade retains the optional watcher preference'
    Assert-Equal $customConfig (Read-Utf8 (Join-Path $installedRoot 'config.json')) 'upgrade preserves custom config exactly'
    foreach ($name in $preferenceFiles) { Assert-Equal $before[$name] ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $stateRoot $name)))) ('upgrade preserves preference bytes: ' + $name) }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'control'))) 'isolated upgrade sends no native control request'

    # Mutex-only fixtures represent the old instance; no real watcher or guard is launched.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $stateHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($stateRoot.ToLowerInvariant()))).Replace('-', '').Substring(0,16) }
    finally { $sha.Dispose() }
    $changedState = Join-Path $fixtureRoot 'changed-state'
    $registrationBeforeChange = [Convert]::ToBase64String([IO.File]::ReadAllBytes($registrationPath))
    $mainBeforeChange = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $installedRoot 'CodexShutdownGuard.ps1')))
    foreach ($prefix in @('Local\CodexShutdownGuard_', 'Local\CodexShutdownGuardCodexStartup_')) {
        $created = $false
        $oldInstance = [Threading.Mutex]::new($false, ($prefix + $stateHash), [ref]$created)
        try {
            foreach ($commandName in @('Install.ps1', 'Uninstall.ps1')) {
                $changeError = ''
                try {
                    $changeArguments = @{ InstallRoot=$installedRoot; StateRoot=$changedState; RegistrationPath=$registrationPath; NoShortcuts=$true }
                    if ($commandName -eq 'Install.ps1') { $changeArguments.NoStart=$true }
                    & (Join-Path $nativeRoot $commandName) @changeArguments | Out-Null
                }
                catch { $changeError = $_.Exception.Message }
                Assert-True ($changeError -match 'previous StateRoot') 'old instance prevents changing state before installing or uninstalling'
                Assert-Equal $registrationBeforeChange ([Convert]::ToBase64String([IO.File]::ReadAllBytes($registrationPath))) 'rejected state switch preserves registration bytes'
                Assert-Equal $mainBeforeChange ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $installedRoot 'CodexShutdownGuard.ps1')))) 'rejected state switch preserves installed program bytes'
                Assert-True (-not (Test-Path -LiteralPath $changedState)) 'rejected state switch creates no new native state'
            }
        }
        finally { $oldInstance.Dispose() }
    }

    # Unknown installation content and state sessions must survive uninstall.
    Write-Utf8 (Join-Path $installedRoot 'keep-user-file.txt') 'preserve me'
    Write-Utf8 (Join-Path $stateRoot 'sessions\session.jsonl') 'formal session sentinel'
    $uninstalled = & (Join-Path $nativeRoot 'Uninstall.ps1') -RegistrationPath $registrationPath -NoShortcuts
    Assert-True $uninstalled.Uninstalled 'registered isolated uninstall succeeds'
    Assert-Equal $false $uninstalled.RootRemoved 'unknown installation file preserves its containing directory'
    Assert-Equal 'preserve me' (Read-Utf8 (Join-Path $installedRoot 'keep-user-file.txt')) 'uninstall preserves unknown installation content'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedRoot 'CodexShutdownGuard.ps1'))) 'uninstall removes owned program file'
    Assert-True (-not (Test-Path -LiteralPath $registrationPath)) 'uninstall removes matching registration'
    Assert-Equal 'formal session sentinel' (Read-Utf8 (Join-Path $stateRoot 'sessions\session.jsonl')) 'uninstall preserves session data'
    foreach ($name in $preferenceFiles) { Assert-Equal $before[$name] ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $stateRoot $name)))) ('uninstall preserves preference bytes: ' + $name) }
    Assert-Equal 0 @($uninstalled.RemovedShortcuts).Count 'NoShortcuts executes no shortcut cleanup'

    # An explicit uninstall of another marked root leaves the discovery registration alone.
    $secondRoot = Join-Path $fixtureRoot 'second\CodexShutdownGuard'
    & (Join-Path $nativeRoot 'Install.ps1') -InstallRoot $secondRoot -StateRoot $stateRoot -RegistrationPath $registrationPath -NoStart -NoShortcuts | Out-Null
    Write-CodexGuardInstallationRegistration -InstallRoot $customRoot -StateRoot $stateRoot -RegistrationPath $registrationPath | Out-Null
    $second = & (Join-Path $nativeRoot 'Uninstall.ps1') -InstallRoot $secondRoot -StateRoot $stateRoot -RegistrationPath $registrationPath -NoShortcuts
    Assert-True $second.RootRemoved 'empty owned installation directory is removed nonrecursively'
    Assert-Equal $false $second.RegistrationRemoved 'explicit other root cannot remove active registration'
    Assert-Equal $customRoot (Get-CodexGuardInstallationRegistration -StateRoot $stateRoot -RegistrationPath $registrationPath).installRoot 'other registration still points to its root'
    Assert-Throws { & (Join-Path $nativeRoot 'Uninstall.ps1') -InstallRoot $unownedRoot -StateRoot $stateRoot -RegistrationPath $registrationPath -NoShortcuts } 'uninstall refuses unmarked directory'
}
finally {
    # This is the only recursive cleanup and is constrained to the exact generated Temp fixture.
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not ([IO.Path]::GetDirectoryName($resolvedFixture)).Equals($temporaryParent, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolvedFixture)).StartsWith('CodexGuardPortable-', [StringComparison]::Ordinal)) {
        throw 'Refusing cleanup outside the generated portable installation fixture.'
    }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
Write-Output ("Passed {0} portable installation checks. Only isolated workspace fixtures changed; no native process, COM, Startup or shutdown action ran." -f $script:Passed)
