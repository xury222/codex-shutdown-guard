#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$StateRoot,
    [string]$RegistrationPath,
    [switch]$NoShortcuts
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Codex Shutdown Guard requires Windows.' }
$uninstaller = Join-Path $PSScriptRoot 'skills\codex-shutdown-guard\assets\native\Uninstall.ps1'
if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'Extract the complete package before running Uninstall.ps1.' }
& $uninstaller @PSBoundParameters
