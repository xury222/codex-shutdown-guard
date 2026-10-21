Set-StrictMode -Version 2.0

function Get-CodexGuardCanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x1f"]') {
        throw 'A nonempty Windows path without quotes or line breaks is required.'
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Get-CodexGuardStateRoot {
    param([string]$StateRoot)
    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexShutdownGuard'
    }
    return Get-CodexGuardCanonicalPath -Path $StateRoot
}

function Get-CodexGuardRegistrationPath {
    param([string]$StateRoot, [string]$RegistrationPath)
    if ([string]::IsNullOrWhiteSpace($RegistrationPath)) {
        # Discovery is per-user, independent of a customized native StateRoot.
        $RegistrationPath = Join-Path (Get-CodexGuardStateRoot) 'installation.json'
    }
    return Get-CodexGuardCanonicalPath -Path $RegistrationPath
}

function Test-CodexGuardPathInside {
    param([string]$Path, [string]$Directory)
    return $Path.Equals($Directory, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Directory + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-CodexGuardNoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = Get-CodexGuardCanonicalPath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Installation paths must not traverse links or junctions: $candidate"
            }
        }
        $candidate = [IO.Path]::GetDirectoryName($candidate)
    }
}

function Get-CodexGuardInstallationMarker {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [switch]$AllowMissing)
    $resolved = Get-CodexGuardCanonicalPath -Path $InstallRoot
    $markerPath = Join-Path $resolved '.codex-shutdown-guard-install.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        if ($AllowMissing) { return $null }
        throw "The installation directory has no product marker: $resolved"
    }
    Assert-CodexGuardNoReparsePath -Path $markerPath
    try { $marker = [IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { throw "Invalid installation marker JSON: $markerPath" }
    if ($null -eq $marker -or $null -eq $marker.PSObject.Properties['product'] -or $marker.product -cne 'CodexShutdownGuard') {
        throw "Invalid installation marker product: $markerPath"
    }
    if ($null -ne $marker.PSObject.Properties['installRoot']) {
        if ($marker.installRoot -isnot [string] -or -not [IO.Path]::IsPathRooted($marker.installRoot)) {
            throw "Invalid installation marker root: $markerPath"
        }
        $recordedRoot = Get-CodexGuardCanonicalPath -Path $marker.installRoot
        if (-not $recordedRoot.Equals($resolved, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The installation marker belongs to another directory: $markerPath"
        }
    }
    return $marker
}

function Get-CodexGuardInstallationRegistration {
    param([string]$StateRoot, [string]$RegistrationPath)
    $path = Get-CodexGuardRegistrationPath -StateRoot $StateRoot -RegistrationPath $RegistrationPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    Assert-CodexGuardNoReparsePath -Path $path
    try { $registration = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { throw "Invalid installation registration JSON: $path" }
    if ($null -eq $registration -or
        $null -eq $registration.PSObject.Properties['schemaVersion'] -or $registration.schemaVersion -ne 1 -or
        $null -eq $registration.PSObject.Properties['product'] -or $registration.product -cne 'CodexShutdownGuard' -or
        $null -eq $registration.PSObject.Properties['installRoot'] -or $registration.installRoot -isnot [string] -or
        -not [IO.Path]::IsPathRooted($registration.installRoot)) {
        throw "Invalid installation registration fields: $path"
    }
    $registration.installRoot = Get-CodexGuardCanonicalPath -Path $registration.installRoot
    if ($null -ne $registration.PSObject.Properties['stateRoot']) {
        if ($registration.stateRoot -isnot [string] -or -not [IO.Path]::IsPathRooted($registration.stateRoot)) {
            throw "Invalid installation registration stateRoot: $path"
        }
        $registration.stateRoot = Get-CodexGuardCanonicalPath -Path $registration.stateRoot
    }
    return $registration
}

function Resolve-CodexGuardStateRoot {
    param([string]$StateRoot, [string]$RegistrationPath)
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) { return Get-CodexGuardStateRoot -StateRoot $StateRoot }
    $registration = Get-CodexGuardInstallationRegistration -RegistrationPath $RegistrationPath
    if ($null -ne $registration -and $null -ne $registration.PSObject.Properties['stateRoot']) {
        return $registration.stateRoot
    }
    return Get-CodexGuardStateRoot
}

function Resolve-CodexGuardInstallRoot {
    param(
        [string]$InstallRoot,
        [string]$StateRoot,
        [string]$RegistrationPath,
        [string]$DefaultInstallRoot,
        [string]$LegacyInstallRoot = 'D:\Program\CodexShutdownGuard'
    )
    # Explicit roots also support isolated bridge fixtures. Mutating installers apply stricter checks.
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        return Get-CodexGuardCanonicalPath -Path $InstallRoot
    }
    $registration = Get-CodexGuardInstallationRegistration -StateRoot $StateRoot -RegistrationPath $RegistrationPath
    if ($null -ne $registration) {
        $registeredRoot = $registration.installRoot
        if (Test-Path -LiteralPath $registeredRoot) {
            Get-CodexGuardInstallationMarker -InstallRoot $registeredRoot | Out-Null
        }
        # A missing or incomplete registered installation keeps its identity so repair cannot create a second one.
        return $registeredRoot
    }
    if ([string]::IsNullOrWhiteSpace($DefaultInstallRoot)) {
        $DefaultInstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\CodexShutdownGuard'
    }
    $defaultRoot = Get-CodexGuardCanonicalPath -Path $DefaultInstallRoot
    foreach ($candidate in @($defaultRoot, $LegacyInstallRoot)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $candidate = Get-CodexGuardCanonicalPath -Path $candidate
        $marker = Get-CodexGuardInstallationMarker -InstallRoot $candidate -AllowMissing
        if ($null -ne $marker) { return $candidate }
    }
    return $defaultRoot
}

function Assert-CodexGuardInstallRoot {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$StateRoot,
        [string]$RegistrationPath,
        [switch]$RequireMarker
    )
    $resolved = Get-CodexGuardCanonicalPath -Path $InstallRoot
    $parent = [IO.Path]::GetDirectoryName($resolved)
    if ([string]::IsNullOrWhiteSpace($parent) -or
        -not [IO.Path]::GetFileName($resolved).Equals('CodexShutdownGuard', [StringComparison]::OrdinalIgnoreCase)) {
        throw "InstallRoot must be a dedicated directory named CodexShutdownGuard: $resolved"
    }
    $resolvedState = Get-CodexGuardStateRoot -StateRoot $StateRoot
    $resolvedRegistration = Get-CodexGuardRegistrationPath -StateRoot $resolvedState -RegistrationPath $RegistrationPath
    if ((Test-CodexGuardPathInside -Path $resolvedState -Directory $resolved) -or
        (Test-CodexGuardPathInside -Path $resolved -Directory $resolvedState) -or
        (Test-CodexGuardPathInside -Path $resolvedRegistration -Directory $resolved)) {
        throw 'InstallRoot must be separate from StateRoot and its installation registration.'
    }
    Assert-CodexGuardNoReparsePath -Path $resolved
    if (Test-Path -LiteralPath $resolved) {
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "InstallRoot is not a directory: $resolved" }
        $marker = Get-CodexGuardInstallationMarker -InstallRoot $resolved -AllowMissing
        if ($null -eq $marker -and ($RequireMarker -or @(Get-ChildItem -LiteralPath $resolved -Force).Count -gt 0)) {
            throw "Refusing to change an unmarked nonempty installation directory: $resolved"
        }
    }
    elseif ($RequireMarker) { throw "The marked installation directory does not exist: $resolved" }
    return $resolved
}

function Write-CodexGuardInstallationRegistration {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [string]$StateRoot, [string]$RegistrationPath)
    $path = Get-CodexGuardRegistrationPath -StateRoot $StateRoot -RegistrationPath $RegistrationPath
    $root = Get-CodexGuardCanonicalPath -Path $InstallRoot
    Assert-CodexGuardNoReparsePath -Path $path
    # Refuse to overwrite malformed or unrelated registration data.
    Get-CodexGuardInstallationRegistration -StateRoot $StateRoot -RegistrationPath $path | Out-Null
    $document = [ordered]@{ schemaVersion = 1; product = 'CodexShutdownGuard'; installRoot = $root; stateRoot = (Get-CodexGuardStateRoot -StateRoot $StateRoot) }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($document | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($path)) {
            [IO.File]::Replace($temporary, $path, [Management.Automation.Language.NullString]::Value)
        }
        else { [IO.File]::Move($temporary, $path) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    return $path
}

function Remove-CodexGuardInstallationRegistration {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [string]$StateRoot, [string]$RegistrationPath)
    $path = Get-CodexGuardRegistrationPath -StateRoot $StateRoot -RegistrationPath $RegistrationPath
    $registration = Get-CodexGuardInstallationRegistration -StateRoot $StateRoot -RegistrationPath $path
    if ($null -ne $registration -and $registration.installRoot.Equals((Get-CodexGuardCanonicalPath -Path $InstallRoot), [StringComparison]::OrdinalIgnoreCase)) {
        [IO.File]::Delete($path)
        return $true
    }
    return $false
}

function Test-CodexGuardNativeRunning {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $path = Get-CodexGuardStateRoot -StateRoot $StateRoot
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToLowerInvariant()))).Replace('-', '').Substring(0, 16) }
    finally { $sha.Dispose() }
    $handle = $null
    try { $handle = [Threading.Mutex]::OpenExisting('Local\CodexShutdownGuard_' + $hash); return $true }
    catch [Threading.WaitHandleCannotBeOpenedException] { return $false }
    finally { if ($null -ne $handle) { $handle.Dispose() } }
}

function Assert-CodexGuardUpgradeUnarmed {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    if (-not (Test-CodexGuardNativeRunning -StateRoot $StateRoot)) { return }
    $statusPath = Join-Path $StateRoot 'status.json'
    try {
        $status = [IO.File]::ReadAllText($statusPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $status.PSObject.Properties['armed'] -or $status.armed -isnot [bool] -or $status.armed -or
            $null -eq $status.PSObject.Properties['updatedAtUtc'] -or
            [Math]::Abs(([datetime]::UtcNow - ([datetime]$status.updatedAtUtc).ToUniversalTime()).TotalSeconds) -gt 30) {
            throw 'Armed or stale status.'
        }
    }
    catch { throw 'The running guard must have fresh unarmed status before upgrading. Cancel automatic shutdown first.' }
}

function Stop-CodexGuardNativeForInstallation {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [Parameter(Mandatory = $true)][string]$StateRoot)
    if (-not (Test-CodexGuardNativeRunning -StateRoot $StateRoot)) { return }
    $main = Join-Path $InstallRoot 'CodexShutdownGuard.ps1'
    if (-not (Test-Path -LiteralPath $main -PathType Leaf)) { throw 'Cannot stop a running guard because its installed script is missing.' }
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $main + '" -Stop -StateRoot "' + $StateRoot + '"'
    $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit(10000)) { throw 'The native stop request did not complete; installation files were preserved.' }
        if ($process.ExitCode -ne 0) { throw 'The native stop request failed; installation files were preserved.' }
    }
    finally { $process.Dispose() }
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    while (Test-CodexGuardNativeRunning -StateRoot $StateRoot) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'The native guard is still running; installation files were preserved.' }
        Start-Sleep -Milliseconds 200
    }
}

function Remove-CodexGuardOwnedShortcut {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$InstallRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    Assert-CodexGuardNoReparsePath -Path $Path
    $shell = $null; $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $root = Get-CodexGuardCanonicalPath -Path $InstallRoot
        # Product names alone do not authorize deleting a shortcut that now points elsewhere.
        $arguments = [string]$shortcut.Arguments
        $owned = $arguments.IndexOf('"' + (Join-Path $root 'CodexShutdownGuard.ps1') + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $arguments.IndexOf('"' + (Join-Path $root 'CodexShutdownGuard.CodexStartupWatcher.ps1') + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ([string]$shortcut.TargetPath).Equals((Join-Path $root 'CodexShutdownGuard.Launcher.vbs'), [StringComparison]::OrdinalIgnoreCase)
        if ($owned) { [IO.File]::Delete($Path); return $true }
        return $false
    }
    finally {
        if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    }
}

Export-ModuleMember -Function Get-CodexGuardCanonicalPath, Get-CodexGuardStateRoot, Resolve-CodexGuardStateRoot, Get-CodexGuardRegistrationPath, Assert-CodexGuardNoReparsePath, Get-CodexGuardInstallationMarker, Get-CodexGuardInstallationRegistration, Resolve-CodexGuardInstallRoot, Assert-CodexGuardInstallRoot, Write-CodexGuardInstallationRegistration, Remove-CodexGuardInstallationRegistration, Test-CodexGuardNativeRunning, Assert-CodexGuardUpgradeUnarmed, Stop-CodexGuardNativeForInstallation, Remove-CodexGuardOwnedShortcut
