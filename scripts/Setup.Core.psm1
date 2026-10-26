Set-StrictMode -Version 2.0

function Assert-CodexGuardSetupPackage {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    $root = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
    $required = @(
        'product.json', 'native\Install.ps1', 'native\Uninstall.ps1',
        'native\CodexShutdownGuard.ps1', 'scripts\Setup.ps1', 'scripts\Setup.Core.psm1'
    )
    foreach ($relative in $required) {
        if (-not [IO.File]::Exists((Join-Path $root $relative))) {
            throw 'The package is incomplete. Extract the entire Windows ZIP before starting setup.'
        }
    }
    $manifest = [IO.File]::ReadAllText((Join-Path $root 'product.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($manifest.name -cne 'codex-shutdown-guard' -or $manifest.version -notmatch '^\d+\.\d+\.\d+$') {
        throw 'The package identity or version is invalid.'
    }
    return [pscustomobject]@{ Root = $root; Version = [string]$manifest.version }
}

function Invoke-CodexGuardSetupOperation {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [ValidateSet('Install', 'Uninstall')][string]$Mode = 'Install'
    )
    $result = [ordered]@{ ok = $false; mode = $Mode; version = $null; nativeInstalled = $false; uninstalled = $false; nativeResult = $null; error = $null }
    try {
        $package = Assert-CodexGuardSetupPackage -PackageRoot $PackageRoot
        $result.version = $package.Version
        $nativeRoot = Join-Path $package.Root 'native'
        if ($Mode -eq 'Uninstall') {
            $native = & (Join-Path $nativeRoot 'Uninstall.ps1')
            if ($null -eq $native -or $null -eq $native.PSObject.Properties['Uninstalled'] -or $native.Uninstalled -isnot [bool] -or -not $native.Uninstalled) {
                throw 'The native uninstaller did not confirm success.'
            }
            $result.uninstalled = $true
        }
        else {
            # Keep discovery, configuration preservation and armed-instance rejection in the native installer.
            $native = & (Join-Path $nativeRoot 'Install.ps1')
            if ($null -eq $native -or $null -eq $native.PSObject.Properties['Installed'] -or $native.Installed -isnot [bool] -or -not $native.Installed) {
                throw 'The native installer did not confirm success.'
            }
            $result.nativeInstalled = $true
        }
        $result.nativeResult = $native
        $result.ok = $true
    }
    catch { $result.error = $_.Exception.Message }
    return [pscustomobject]$result
}

function ConvertTo-CodexGuardSetupArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '[\x00-\x1f"]' -or $Value.EndsWith('\')) { throw 'Invalid setup process argument.' }
    return '"' + $Value + '"'
}

function Start-CodexGuardSetupWorker {
    param([Parameter(Mandatory = $true)][string]$PackageRoot, [ValidateSet('Install', 'Uninstall')][string]$Mode = 'Install')
    $package = Assert-CodexGuardSetupPackage -PackageRoot $PackageRoot
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('CodexGuardSetup-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $resultPath = Join-Path $directory 'result.json'
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-File', (ConvertTo-CodexGuardSetupArgument (Join-Path $package.Root 'scripts\Setup.ps1')), '-Worker', '-PackageRoot', (ConvertTo-CodexGuardSetupArgument $package.Root), '-Mode', $Mode, '-ResultPath', (ConvertTo-CodexGuardSetupArgument $resultPath))
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = $arguments -join ' '
    $start.WorkingDirectory = $package.Root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    try { $process = [Diagnostics.Process]::Start($start) }
    catch { [IO.Directory]::Delete($directory, $false); throw }
    return [pscustomobject]@{ Process = $process; ResultPath = $resultPath; Directory = $directory }
}

function Read-CodexGuardSetupWorkerResult {
    param([Parameter(Mandatory = $true)]$Worker)
    if (-not $Worker.Process.HasExited) { return $null }
    if (-not [IO.File]::Exists($Worker.ResultPath)) { throw ('Setup did not return a result. Exit code: ' + $Worker.Process.ExitCode) }
    $result = [IO.File]::ReadAllText($Worker.ResultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($null -eq $result -or $null -eq $result.PSObject.Properties['ok'] -or $result.ok -isnot [bool]) { throw 'Setup returned an invalid result.' }
    if ($Worker.Process.ExitCode -ne 0 -and $result.ok) { throw 'Setup reported success but its process failed.' }
    return $result
}

function Remove-CodexGuardSetupWorker {
    param([Parameter(Mandatory = $true)]$Worker)
    if (-not $Worker.Process.HasExited) { throw 'The setup worker is still running.' }
    $Worker.Process.Dispose()
    if ([IO.File]::Exists($Worker.ResultPath)) { [IO.File]::Delete($Worker.ResultPath) }
    if ([IO.Directory]::Exists($Worker.Directory) -and [IO.Directory]::GetFileSystemEntries($Worker.Directory).Length -eq 0) { [IO.Directory]::Delete($Worker.Directory, $false) }
}

Export-ModuleMember -Function Assert-CodexGuardSetupPackage, Invoke-CodexGuardSetupOperation, ConvertTo-CodexGuardSetupArgument, Start-CodexGuardSetupWorker, Read-CodexGuardSetupWorkerResult, Remove-CodexGuardSetupWorker
