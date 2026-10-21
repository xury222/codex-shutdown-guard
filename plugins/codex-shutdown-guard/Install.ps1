#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$StateRoot,
    [string]$RegistrationPath,
    [switch]$NoStart,
    [switch]$NoShortcuts
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Codex Shutdown Guard requires Windows.' }
$installer = Join-Path $PSScriptRoot 'skills\codex-shutdown-guard\assets\native\Install.ps1'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'Extract the complete package before running Install.ps1.' }
& $installer @PSBoundParameters
