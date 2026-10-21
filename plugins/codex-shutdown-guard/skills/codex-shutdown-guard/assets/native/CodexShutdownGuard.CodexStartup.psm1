Set-StrictMode -Version 2.0

# This helper only starts the existing native tray. It never observes tasks,
# arms shutdown, changes proxy settings, or launches a Codex desktop/executor.
function Get-CodexGuardStartupSettingsObject {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ schemaVersion = 1 } }
    $settings = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $settings -or $settings -isnot [pscustomobject]) {
        throw 'Codex startup settings must contain a JSON object.'
    }
    return $settings
}

function Get-CodexGuardStartWithCodexSetting {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $settings = Get-CodexGuardStartupSettingsObject -Path $Path
        $property = $settings.PSObject.Properties['startGuardWithCodex']
        return ($null -ne $property -and $property.Value -is [bool] -and $property.Value)
    }
    catch { return $false }
}

function Write-CodexGuardStartupAtomicBytes {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [void][IO.Directory]::CreateDirectory($parent)
    $temporary = Join-Path $parent ([IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Write-CodexGuardStartupJson {
    param([string]$Path, [object]$Value)
    $encoding = New-Object Text.UTF8Encoding($false)
    Write-CodexGuardStartupAtomicBytes -Path $Path -Bytes $encoding.GetBytes(($Value | ConvertTo-Json -Depth 100))
}

function Get-CodexGuardStartupPathHash {
    param([string]$StateRoot)
    # Keep exactly the native guard's Get-StablePathHash algorithm and root.
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($StateRoot)).ToLowerInvariant())
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16)
    }
    finally { $sha.Dispose() }
}

function Get-CodexGuardStartupMutexName {
    param([string]$StateRoot, [ValidateSet('Guard', 'Watcher')][string]$Kind)
    $prefix = if ($Kind -eq 'Watcher') { 'Local\CodexShutdownGuardCodexStartup_' } else { 'Local\CodexShutdownGuard_' }
    return $prefix + (Get-CodexGuardStartupPathHash -StateRoot $StateRoot)
}

function Test-CodexGuardStartupMutexExists {
    param([string]$Name)
    $existing = $null
    try { $existing = [Threading.Mutex]::OpenExisting($Name); return $true }
    catch [Threading.WaitHandleCannotBeOpenedException] { return $false }
    finally { if ($null -ne $existing) { $existing.Dispose() } }
}

function Test-CodexGuardCodexStartupWatcherRunning {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    return Test-CodexGuardStartupMutexExists -Name (Get-CodexGuardStartupMutexName -StateRoot $StateRoot -Kind Watcher)
}

function ConvertTo-CodexGuardStartupQuotedArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    # Windows command-line escaping, including trailing backslashes. No shell
    # interpolation is used for paths with spaces, Unicode, $, or apostrophes.
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
        }
        else {
            if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-CodexGuardStartupPowerShellPath {
    return Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function New-CodexGuardStartupProcessInfo {
    param([string]$NativeRoot, [string]$StateRoot, [string]$SettingsPath, [switch]$Watcher)
    $scriptName = if ($Watcher) { 'CodexShutdownGuard.CodexStartupWatcher.ps1' } else { 'CodexShutdownGuard.ps1' }
    $scriptPath = Join-Path ([IO.Path]::GetFullPath($NativeRoot)) $scriptName
    if (-not [IO.File]::Exists($scriptPath)) { throw "Missing native startup file: $scriptPath" }
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File ' + (ConvertTo-CodexGuardStartupQuotedArgument $scriptPath)
    if ($Watcher) {
        $arguments += ' -NativeRoot ' + (ConvertTo-CodexGuardStartupQuotedArgument ([IO.Path]::GetFullPath($NativeRoot)))
        $arguments += ' -SettingsPath ' + (ConvertTo-CodexGuardStartupQuotedArgument ([IO.Path]::GetFullPath($SettingsPath)))
    }
    else { $arguments += ' -Tray -FromCodexStartup' }
    $arguments += ' -StateRoot ' + (ConvertTo-CodexGuardStartupQuotedArgument ([IO.Path]::GetFullPath($StateRoot)))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Get-CodexGuardStartupPowerShellPath
    $info.Arguments = $arguments
    $info.WorkingDirectory = [IO.Path]::GetFullPath($NativeRoot)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    return $info
}

function Invoke-CodexGuardStartupProcess {
    param([Diagnostics.ProcessStartInfo]$StartInfo)
    return [Diagnostics.Process]::Start($StartInfo)
}

function Start-CodexGuardCodexStartupWatcher {
    param([Parameter(Mandatory = $true)][string]$SettingsPath, [Parameter(Mandatory = $true)][string]$NativeRoot, [Parameter(Mandatory = $true)][string]$StateRoot)
    if (-not (Get-CodexGuardStartWithCodexSetting -Path $SettingsPath)) { return [pscustomobject]@{ Status = 'Disabled' } }
    if (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $StateRoot) { return [pscustomobject]@{ Status = 'AlreadyRunning' } }
    $info = New-CodexGuardStartupProcessInfo -NativeRoot $NativeRoot -StateRoot $StateRoot -SettingsPath $SettingsPath -Watcher
    $process = Invoke-CodexGuardStartupProcess -StartInfo $info
    if ($null -eq $process) { throw 'The Codex startup watcher could not be started.' }
    try { return [pscustomobject]@{ Status = 'Started'; ProcessId = $process.Id } }
    finally { if ($process -is [Diagnostics.Process]) { $process.Dispose() } }
}

function Write-CodexGuardStartupShortcut {
    param([string]$Path, [Diagnostics.ProcessStartInfo]$StartInfo)
    $parent = [IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($parent)
    $temporary = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.tmp.lnk')
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($temporary)
        $shortcut.TargetPath = $StartInfo.FileName
        $shortcut.Arguments = $StartInfo.Arguments
        $shortcut.WorkingDirectory = $StartInfo.WorkingDirectory
        $shortcut.WindowStyle = 7
        $shortcut.Description = 'Start Codex Shutdown Guard when a local Codex desktop session starts.'
        $shortcut.Save()
        Write-CodexGuardStartupAtomicBytes -Path $Path -Bytes ([IO.File]::ReadAllBytes($temporary))
    }
    finally {
        if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Restore-CodexGuardStartupFile {
    param([string]$Path, [bool]$Existed, [byte[]]$Bytes)
    if ($Existed) { Write-CodexGuardStartupAtomicBytes -Path $Path -Bytes $Bytes }
    elseif ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
}

function Set-CodexGuardStartWithCodex {
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$NativeRoot,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$StartupDirectory = [Environment]::GetFolderPath('Startup'),
        [switch]$NoStartWatcher
    )
    $SettingsPath = [IO.Path]::GetFullPath($SettingsPath)
    $StateRoot = [IO.Path]::GetFullPath($StateRoot)
    if ([string]::IsNullOrWhiteSpace($StartupDirectory)) { throw 'The current user Startup directory is unavailable.' }
    $shortcutPath = Join-Path ([IO.Path]::GetFullPath($StartupDirectory)) 'CodexShutdownGuard.CodexStartup.lnk'
    $stopPath = Join-Path $StateRoot 'codex-startup-stop.json'
    # A malformed object must be repaired by its owner, not silently replaced.
    $settings = Get-CodexGuardStartupSettingsObject -Path $SettingsPath
    $settings | Add-Member -NotePropertyName startGuardWithCodex -NotePropertyValue $Enabled -Force
    $paths = @($SettingsPath, $shortcutPath, $stopPath)
    $previous = @{}
    foreach ($path in $paths) {
        $exists = [IO.File]::Exists($path)
        $bytes = if ($exists) { [IO.File]::ReadAllBytes($path) } else { [byte[]]@() }
        $previous[$path] = [pscustomobject]@{ Existed = $exists; Bytes = $bytes }
    }
    try {
        if ($Enabled) {
            # A disabled watcher can have read false just before this enable.
            # Wait for that old generation before treating its mutex as a live
            # enabled watcher; otherwise it could exit immediately afterwards.
            if (-not (Get-CodexGuardStartWithCodexSetting -Path $SettingsPath) -and (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $StateRoot)) {
                $stopped = Stop-CodexGuardCodexStartupWatcher -StateRoot $StateRoot -TimeoutSeconds 8
                if ($stopped.Status -ne 'Stopped') { throw 'The previous Codex startup watcher has not stopped yet.' }
            }
            $info = New-CodexGuardStartupProcessInfo -NativeRoot $NativeRoot -StateRoot $StateRoot -SettingsPath $SettingsPath -Watcher
            if (-not [IO.File]::Exists((Join-Path $NativeRoot 'CodexShutdownGuard.ps1'))) { throw 'The native guard script is missing.' }
            Write-CodexGuardStartupShortcut -Path $shortcutPath -StartInfo $info
            if ([IO.File]::Exists($stopPath)) { [IO.File]::Delete($stopPath) }
        }
        else { if ([IO.File]::Exists($shortcutPath)) { [IO.File]::Delete($shortcutPath) } }
        Write-CodexGuardStartupJson -Path $SettingsPath -Value $settings
        $status = if ($Enabled) { 'NotStarted' } else { 'Disabled' }
        if ($Enabled -and -not $NoStartWatcher) {
            $watcher = Start-CodexGuardCodexStartupWatcher -SettingsPath $SettingsPath -NativeRoot $NativeRoot -StateRoot $StateRoot
            $status = $watcher.Status
        }
        return [pscustomobject]@{ Enabled = $Enabled; ShortcutPath = $shortcutPath; WatcherStatus = $status }
    }
    catch {
        $originalError = $_
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        foreach ($path in $paths) {
            try { Restore-CodexGuardStartupFile -Path $path -Existed $previous[$path].Existed -Bytes $previous[$path].Bytes }
            catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        if ($rollbackErrors.Count -gt 0) { throw ('Startup setting failed and rollback needs attention: ' + ($rollbackErrors -join '; ') + '. Original error: ' + $originalError.Exception.Message) }
        throw $originalError
    }
}

function Stop-CodexGuardCodexStartupWatcher {
    param([Parameter(Mandatory = $true)][string]$StateRoot, [ValidateRange(0, 60)][int]$TimeoutSeconds = 8)
    $stopPath = Join-Path ([IO.Path]::GetFullPath($StateRoot)) 'codex-startup-stop.json'
    Write-CodexGuardStartupJson -Path $stopPath -Value ([pscustomobject]@{ stop = $true })
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (Test-CodexGuardCodexStartupWatcherRunning -StateRoot $StateRoot) {
        if ([datetime]::UtcNow -ge $deadline) { return [pscustomobject]@{ Status = 'StillRunning' } }
        Start-Sleep -Milliseconds 100
    }
    return [pscustomobject]@{ Status = 'Stopped' }
}

function Invoke-CodexGuardCodexStartupWatcher {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$NativeRoot,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [ValidateRange(0, 60)][int]$PollSeconds = 5,
        [ValidateRange(0, 1000000)][int]$MaxIterations = 0
    )
    $StateRoot = [IO.Path]::GetFullPath($StateRoot)
    $stopPath = Join-Path $StateRoot 'codex-startup-stop.json'
    $sessionPath = Join-Path $StateRoot 'codex-startup-session.json'
    $mutexName = Get-CodexGuardStartupMutexName -StateRoot $StateRoot -Kind Watcher
    $created = $false
    $mutex = [Threading.Mutex]::new($true, $mutexName, [ref]$created)
    if (-not $created) { $mutex.Dispose(); return [pscustomobject]@{ Status = 'AlreadyRunning'; Launches = 0 } }
    $launches = 0
    $iterations = 0
    $consumed = @{}
    try {
        if ([IO.File]::Exists($sessionPath)) {
            try {
                $saved = Get-CodexGuardStartupSettingsObject -Path $sessionPath
                $sessionProperty = $saved.PSObject.Properties['sessionKeys']
                if ($null -ne $sessionProperty) {
                    foreach ($key in @($sessionProperty.Value)) {
                        if ($key -is [string] -and $key -match '^\d{21}$') { $consumed[$key] = $true }
                    }
                }
            }
            catch { throw 'The Codex startup session record is unreadable; automatic startup was not attempted.' }
        }
        while ($true) {
            if ([IO.File]::Exists($stopPath)) { return [pscustomobject]@{ Status = 'Stopped'; Launches = $launches } }
            if (-not (Get-CodexGuardStartWithCodexSetting -Path $SettingsPath)) { return [pscustomobject]@{ Status = 'Disabled'; Launches = $launches } }
            $iterations++
            $session = Get-CodexGuardAppSession
            if ($session.Available -and $session.SessionKey -match '^\d{21}$' -and -not $consumed.ContainsKey([string]$session.SessionKey)) {
                # Consume even if guard is running or its start later fails. A
                # manual guard exit must stay effective for this Codex session.
                $consumed[[string]$session.SessionKey] = $true
                $keys = @($consumed.Keys | Sort-Object -Descending | Select-Object -First 128)
                Write-CodexGuardStartupJson -Path $sessionPath -Value ([pscustomobject]@{ schemaVersion = 1; sessionKeys = $keys })
                if (-not (Test-CodexGuardStartupMutexExists -Name (Get-CodexGuardStartupMutexName -StateRoot $StateRoot -Kind Guard))) {
                    # Recheck user intent immediately before a process launch.
                    if (-not [IO.File]::Exists($stopPath) -and (Get-CodexGuardStartWithCodexSetting -Path $SettingsPath)) {
                        $info = New-CodexGuardStartupProcessInfo -NativeRoot $NativeRoot -StateRoot $StateRoot
                        try {
                            $process = Invoke-CodexGuardStartupProcess -StartInfo $info
                            if ($null -ne $process) { $launches++; if ($process -is [Diagnostics.Process]) { $process.Dispose() } }
                        }
                        catch { Write-Warning ('The native guard could not be started for this Codex session: ' + $_.Exception.Message) }
                    }
                }
            }
            if ($MaxIterations -gt 0 -and $iterations -ge $MaxIterations) { return [pscustomobject]@{ Status = 'IterationLimit'; Launches = $launches } }
            Start-Sleep -Seconds $PollSeconds
        }
    }
    finally { try { $mutex.ReleaseMutex() } finally { $mutex.Dispose() } }
}

Export-ModuleMember -Function @('Get-CodexGuardStartWithCodexSetting', 'Set-CodexGuardStartWithCodex', 'Start-CodexGuardCodexStartupWatcher', 'Stop-CodexGuardCodexStartupWatcher', 'Test-CodexGuardCodexStartupWatcherRunning', 'Invoke-CodexGuardCodexStartupWatcher')
