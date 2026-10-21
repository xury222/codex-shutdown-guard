[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$StateRoot,
    [string]$RegistrationPath,
    [switch]$NoStart,
    [switch]$NoShortcuts,
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup'),
    [string]$DesktopDirectory = [Environment]::GetFolderPath('Desktop')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.Installation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.CodexStartup.psm1') -Force

function New-GuardShortcut {
    param([string]$Path, [string]$PowerShellPath, [string]$Arguments, [string]$WorkingDirectory, [string]$Description)
    Assert-CodexGuardNoReparsePath -Path $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $shell = $null; $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $PowerShellPath
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = $WorkingDirectory
        $shortcut.Description = $Description
        $shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',27'
        $shortcut.WindowStyle = 7
        $shortcut.Save()
    }
    finally {
        if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    }
}

$StateRoot = Resolve-CodexGuardStateRoot -StateRoot $StateRoot -RegistrationPath $RegistrationPath
$RegistrationPath = Get-CodexGuardRegistrationPath -StateRoot $StateRoot -RegistrationPath $RegistrationPath
$InstallRoot = Resolve-CodexGuardInstallRoot -InstallRoot $InstallRoot -StateRoot $StateRoot -RegistrationPath $RegistrationPath
$InstallRoot = Assert-CodexGuardInstallRoot -InstallRoot $InstallRoot -StateRoot $StateRoot -RegistrationPath $RegistrationPath
# Validate every input before stopping either native process or replacing any installed file.
$previousRegistration = Get-CodexGuardInstallationRegistration -StateRoot $StateRoot -RegistrationPath $RegistrationPath
if ($null -ne $previousRegistration) {
    $previousStateRoot = if ($null -ne $previousRegistration.PSObject.Properties['stateRoot']) { $previousRegistration.stateRoot } else { Get-CodexGuardStateRoot }
    if (-not $previousStateRoot.Equals($StateRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if ((Test-CodexGuardNativeRunning -StateRoot $previousStateRoot) -or (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $previousStateRoot)) {
            throw 'The registered guard or Codex startup watcher is still running in the previous StateRoot. Exit it before changing StateRoot.'
        }
    }
}
Assert-CodexGuardNoReparsePath -Path $RegistrationPath
$filesToInstall = @(
    'CodexShutdownGuard.ps1',
    'CodexShutdownGuard.Core.psm1',
    'CodexShutdownGuard.CodexLaunch.psm1',
    'CodexShutdownGuard.CodexStartup.psm1',
    'CodexShutdownGuard.CodexStartupWatcher.ps1',
    'CodexShutdownGuard.Installation.psm1',
    'CodexShutdownGuard.Launcher.vbs',
    'config.default.json',
    'README.md',
    'Install.ps1',
    'Uninstall.ps1'
)
foreach ($name in $filesToInstall) {
    $source = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Package file is missing: $source" }
    Assert-CodexGuardNoReparsePath -Path (Join-Path $InstallRoot $name)
}
$configPath = Join-Path $InstallRoot 'config.json'
Assert-CodexGuardNoReparsePath -Path $configPath
Assert-CodexGuardUpgradeUnarmed -StateRoot $StateRoot

$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$installedMain = Join-Path $InstallRoot 'CodexShutdownGuard.ps1'
$codexStartupSettingsPath = Join-Path $StateRoot 'codex-startup-settings.json'
$startWithCodex = Get-CodexGuardStartWithCodexSetting -Path $codexStartupSettingsPath
$startupShortcut = $null; $desktopShortcut = $null; $codexStartupShortcut = $null
$legacyArmShortcut = $null
if (-not $NoShortcuts) {
    if ([string]::IsNullOrWhiteSpace($StartupDirectory) -or [string]::IsNullOrWhiteSpace($DesktopDirectory)) {
        throw 'The current user Startup and Desktop directories are required, or use -NoShortcuts.'
    }
    $StartupDirectory = Get-CodexGuardCanonicalPath -Path $StartupDirectory
    $DesktopDirectory = Get-CodexGuardCanonicalPath -Path $DesktopDirectory
    $startupShortcut = Join-Path $StartupDirectory 'CodexShutdownGuard.lnk'
    $desktopName = 'Codex ' + (-join ([char[]]@(0x5173, 0x673a, 0x5b88, 0x536b))) + '.lnk'
    $legacyName = 'Codex ' + (-join ([char[]]@(0x5168, 0x90e8, 0x5b8c, 0x6210, 0x540e, 0x5173, 0x673a))) + '.lnk'
    $desktopShortcut = Join-Path $DesktopDirectory $desktopName
    $legacyArmShortcut = Join-Path $DesktopDirectory $legacyName
    foreach ($path in @($startupShortcut, $desktopShortcut, $legacyArmShortcut)) { Assert-CodexGuardNoReparsePath -Path $path }
}

if (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $StateRoot) {
    Stop-CodexGuardCodexStartupWatcher -StateRoot $StateRoot -TimeoutSeconds 8 | Out-Null
    if (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $StateRoot) {
        throw 'The Codex startup watcher has not stopped; installation was not changed.'
    }
}
Stop-CodexGuardNativeForInstallation -InstallRoot $InstallRoot -StateRoot $StateRoot

[void][IO.Directory]::CreateDirectory($InstallRoot)
foreach ($name in $filesToInstall) {
    $source = Join-Path $PSScriptRoot $name
    $destination = Join-Path $InstallRoot $name
    if (-not ([IO.Path]::GetFullPath($source)).Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}
# Existing configuration and every preference in StateRoot remain byte-for-byte intact.
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config.default.json') -Destination $configPath
}
$marker = [ordered]@{ product = 'CodexShutdownGuard'; installedAtUtc = [datetime]::UtcNow.ToString('o'); installRoot = $InstallRoot }
[IO.File]::WriteAllText((Join-Path $InstallRoot '.codex-shutdown-guard-install.json'), ($marker | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))

$trayArguments = (Get-CodexGuardPowerShellLaunchArguments -MainScriptPath $installedMain -Mode 'Tray') + ' -StateRoot "' + $StateRoot + '"'
if (-not $NoShortcuts) {
    New-GuardShortcut -Path $startupShortcut -PowerShellPath $powerShellPath -Arguments $trayArguments -WorkingDirectory $InstallRoot -Description 'Start Codex Shutdown Guard in the tray; automatic shutdown remains off.'
    $showArguments = (Get-CodexGuardPowerShellLaunchArguments -MainScriptPath $installedMain -Mode 'Show') + ' -StateRoot "' + $StateRoot + '"'
    New-GuardShortcut -Path $desktopShortcut -PowerShellPath $powerShellPath -Arguments $showArguments -WorkingDirectory $InstallRoot -Description 'Open Codex Shutdown Guard usage panel.'
    Remove-CodexGuardOwnedShortcut -Path $legacyArmShortcut -InstallRoot $InstallRoot | Out-Null
}
# Restore the existing opt-in without rewriting preferences or implicitly enabling it.
if ($startWithCodex) {
    if (-not $NoShortcuts) {
        $codexStartupShortcut = Join-Path $StartupDirectory 'CodexShutdownGuard.CodexStartup.lnk'
        $watcherScript = Join-Path $InstallRoot 'CodexShutdownGuard.CodexStartupWatcher.ps1'
        $watcherArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + $watcherScript + '" -NativeRoot "' + $InstallRoot + '" -SettingsPath "' + $codexStartupSettingsPath + '" -StateRoot "' + $StateRoot + '"'
        New-GuardShortcut -Path $codexStartupShortcut -PowerShellPath $powerShellPath -Arguments $watcherArguments -WorkingDirectory $InstallRoot -Description 'Start Codex Shutdown Guard when a local Codex desktop session starts.'
    }
    $stopPath = Join-Path $StateRoot 'codex-startup-stop.json'
    if (Test-Path -LiteralPath $stopPath -PathType Leaf) { [IO.File]::Delete($stopPath) }
}

# Only a complete install publishes the discovery registration. Never issue an Arm command.
$writtenRegistration = Write-CodexGuardInstallationRegistration -InstallRoot $InstallRoot -StateRoot $StateRoot -RegistrationPath $RegistrationPath
if (-not $NoStart) {
    [void](Start-Process -FilePath $powerShellPath -ArgumentList $trayArguments -WindowStyle Hidden)
    if ($startWithCodex) {
        Start-CodexGuardCodexStartupWatcher -SettingsPath $codexStartupSettingsPath -NativeRoot $InstallRoot -StateRoot $StateRoot | Out-Null
    }
}
[pscustomobject]@{
    Installed = $true
    InstallRoot = $InstallRoot
    RegistrationPath = $writtenRegistration
    StartupShortcut = $startupShortcut
    DesktopShortcut = $desktopShortcut
    StartWithCodexEnabled = $startWithCodex
    CodexStartupShortcut = $codexStartupShortcut
    Started = -not $NoStart
    DefaultArmed = $false
}
