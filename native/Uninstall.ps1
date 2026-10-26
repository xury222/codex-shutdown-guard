[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$StateRoot,
    [string]$RegistrationPath,
    [switch]$NoShortcuts,
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup'),
    [string]$DesktopDirectory = [Environment]::GetFolderPath('Desktop')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.Installation.psm1') -Force
$StateRoot = Resolve-CodexGuardStateRoot -StateRoot $StateRoot -RegistrationPath $RegistrationPath
$RegistrationPath = Get-CodexGuardRegistrationPath -StateRoot $StateRoot -RegistrationPath $RegistrationPath
$InstallRoot = Resolve-CodexGuardInstallRoot -InstallRoot $InstallRoot -StateRoot $StateRoot -RegistrationPath $RegistrationPath
$InstallRoot = Assert-CodexGuardInstallRoot -InstallRoot $InstallRoot -StateRoot $StateRoot -RegistrationPath $RegistrationPath -RequireMarker
$previousRegistration = Get-CodexGuardInstallationRegistration -StateRoot $StateRoot -RegistrationPath $RegistrationPath

$ownedFiles = @(
    'CodexShutdownGuard.ps1', 'CodexShutdownGuard.Core.psm1', 'CodexShutdownGuard.CodexLaunch.psm1',
    'CodexShutdownGuard.CodexStartup.psm1', 'CodexShutdownGuard.CodexStartupWatcher.ps1',
    'CodexShutdownGuard.Installation.psm1', 'CodexShutdownGuard.Launcher.vbs', 'config.default.json',
    'config.json', 'README.md', 'Install.ps1', 'Uninstall.ps1', '.codex-shutdown-guard-install.json'
)
foreach ($name in $ownedFiles) { Assert-CodexGuardNoReparsePath -Path (Join-Path $InstallRoot $name) }

$codexStartupModule = Join-Path $InstallRoot 'CodexShutdownGuard.CodexStartup.psm1'
# Use the packaged lifecycle helper even when repairing an incomplete installation.
if (-not (Test-Path -LiteralPath $codexStartupModule -PathType Leaf)) {
    $codexStartupModule = Join-Path $PSScriptRoot 'CodexShutdownGuard.CodexStartup.psm1'
}
if (-not (Test-Path -LiteralPath $codexStartupModule -PathType Leaf)) {
    throw 'The Codex startup watcher helper is missing; restore the package before uninstalling.'
}
Import-Module $codexStartupModule -Force

if ($null -ne $previousRegistration) {
    $previousStateRoot = if ($null -ne $previousRegistration.PSObject.Properties['stateRoot']) { $previousRegistration.stateRoot } else { Get-CodexGuardStateRoot }
    if (-not $previousStateRoot.Equals($StateRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if ((Test-CodexGuardNativeRunning -StateRoot $previousStateRoot) -or (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $previousStateRoot)) {
            throw 'The registered guard or Codex startup watcher is still running in the previous StateRoot. Exit it before changing StateRoot.'
        }
    }
}

if (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $StateRoot) {
    Stop-CodexGuardCodexStartupWatcher -StateRoot $StateRoot -TimeoutSeconds 8 | Out-Null
    if (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $StateRoot) {
        throw 'The Codex startup watcher has not stopped; installation files were preserved.'
    }
}
Stop-CodexGuardNativeForInstallation -InstallRoot $InstallRoot -StateRoot $StateRoot

$removedShortcuts = New-Object 'System.Collections.Generic.List[string]'
if (-not $NoShortcuts) {
    if ([string]::IsNullOrWhiteSpace($StartupDirectory) -or [string]::IsNullOrWhiteSpace($DesktopDirectory)) {
        throw 'The current user Startup and Desktop directories are required, or use -NoShortcuts.'
    }
    $desktopName = 'Codex ' + (-join ([char[]]@(0x5173, 0x673a, 0x5b88, 0x536b))) + '.lnk'
    $legacyName = 'Codex ' + (-join ([char[]]@(0x5168, 0x90e8, 0x5b8c, 0x6210, 0x540e, 0x5173, 0x673a))) + '.lnk'
    $shortcuts = @(
        (Join-Path $StartupDirectory 'CodexShutdownGuard.lnk'),
        (Join-Path $StartupDirectory 'CodexShutdownGuard.CodexStartup.lnk'),
        (Join-Path $DesktopDirectory $desktopName),
        (Join-Path $DesktopDirectory $legacyName)
    )
    foreach ($shortcut in $shortcuts) {
        if (Remove-CodexGuardOwnedShortcut -Path $shortcut -InstallRoot $InstallRoot) { $removedShortcuts.Add($shortcut) }
    }
}

# Delete only product-owned files; unknown files and all durable state are preserved.
# Avoid recursive deletion even inside a marked root, which may contain a user's extra files.
foreach ($name in $ownedFiles) {
    $path = Join-Path $InstallRoot $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Delete($path) }
}
$registrationRemoved = Remove-CodexGuardInstallationRegistration -InstallRoot $InstallRoot -StateRoot $StateRoot -RegistrationPath $RegistrationPath
$remainingFiles = @(Get-ChildItem -LiteralPath $InstallRoot -Force)
if ($remainingFiles.Count -eq 0) { [IO.Directory]::Delete($InstallRoot, $false) }
[pscustomobject]@{
    Uninstalled = $true
    InstallRoot = $InstallRoot
    RootRemoved = $remainingFiles.Count -eq 0
    PreservedFiles = @($remainingFiles | ForEach-Object { $_.FullName })
    RemovedShortcuts = @($removedShortcuts)
    RegistrationRemoved = $registrationRemoved
    StateRootPreserved = $StateRoot
}
