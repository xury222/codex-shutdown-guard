[CmdletBinding()]
param(
    [string]$NativeRoot = $PSScriptRoot,
    [string]$StateRoot,
    [string]$SettingsPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($StateRoot)) {
    Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.Installation.psm1') -Force
    $StateRoot = Resolve-CodexGuardStateRoot
}
else { $StateRoot = [IO.Path]::GetFullPath($StateRoot) }
if ([string]::IsNullOrWhiteSpace($SettingsPath)) { $SettingsPath = Join-Path $StateRoot 'codex-startup-settings.json' }
Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodexShutdownGuard.CodexStartup.psm1') -Force
Invoke-CodexGuardCodexStartupWatcher -SettingsPath $SettingsPath -NativeRoot $NativeRoot -StateRoot $StateRoot | Out-Null
