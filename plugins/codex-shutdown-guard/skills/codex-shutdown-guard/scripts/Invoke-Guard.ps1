[CmdletBinding()]
param(
    [string]$Action = 'Inspect',
    [string]$Root = '',
    [string]$StateRoot = '',
    [string]$Enabled,
    [string]$RegistrationPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:GuardBridgeInstallationModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\native\CodexShutdownGuard.Installation.psm1'
$script:GuardBridgeInstallationResolverLoaded = $false

function Resolve-GuardBridgePath {
    param([string]$Path, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or $Path -match '[\x00-\x1f"]') {
        throw "$Label must be an absolute path without control characters or quotes."
    }
    return [IO.Path]::GetFullPath($Path)
}

function Get-GuardBridgeMutexName {
    param([string]$StateRoot)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($StateRoot.ToLowerInvariant()))
        return 'Local\CodexShutdownGuard_' + (([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16))
    }
    finally { $sha.Dispose() }
}

function Get-GuardBridgeInstance {
    param([string]$StateRoot)
    $handle = $null
    try {
        # OpenExisting never creates a mutex or starts the guard. This is the
        # exact per-StateRoot name used by the installed native implementation.
        $handle = [Threading.Mutex]::OpenExisting((Get-GuardBridgeMutexName $StateRoot))
        return [pscustomobject]@{ detected = $true; method = 'native-mutex'; error = $null }
    }
    catch [Threading.WaitHandleCannotBeOpenedException] {
        return [pscustomobject]@{ detected = $false; method = 'native-mutex'; error = $null }
    }
    catch {
        return [pscustomobject]@{ detected = $null; method = 'native-mutex'; error = 'Native guard instance could not be verified.' }
    }
    finally { if ($null -ne $handle) { $handle.Dispose() } }
}

function Read-GuardBridgeJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ exists = $false; valid = $false; path = $Path; lastWriteTimeUtc = $null; value = $null; error = $null }
    }
    $lastWrite = (Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToString('o')
    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $value -or $value -is [array] -or $value -is [string] -or $value -is [ValueType]) { throw 'Expected a JSON object.' }
        return [pscustomobject]@{ exists = $true; valid = $true; path = $Path; lastWriteTimeUtc = $lastWrite; value = $value; error = $null }
    }
    catch {
        return [pscustomobject]@{ exists = $true; valid = $false; path = $Path; lastWriteTimeUtc = $lastWrite; value = $null; error = 'JSON could not be read or is not an object.' }
    }
}

function Get-GuardBridgeProperty {
    param([object]$Value, [string]$Name, [object]$Fallback = $null)
    if ($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $Fallback
}

function Get-GuardBridgeNativeDiagnostic {
    param([string]$Root)
    $required = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in @('CodexShutdownGuard.ps1', 'CodexShutdownGuard.Core.psm1', 'CodexShutdownGuard.CodexLaunch.psm1', 'config.default.json')) { $required.Add($file) }
    $errorText = $null
    $main = Join-Path $Root 'CodexShutdownGuard.ps1'
    if (Test-Path -LiteralPath $main -PathType Leaf) {
        try {
            # Read dependency declarations only; never execute installed code to inspect availability.
            $source = [IO.File]::ReadAllText($main, [Text.Encoding]::UTF8)
            foreach ($file in @('CodexShutdownGuard.CodexStartup.psm1', 'CodexShutdownGuard.Installation.psm1')) {
                if ($source -match ('(?im)^\s*Import-Module[^\r\n]*' + [regex]::Escape($file))) { $required.Add($file) }
            }
        }
        catch { $errorText = 'The installed guard script could not be read for dependency inspection.' }
    }
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf) })
    return [pscustomobject]@{ available = ($missing.Count -eq 0 -and $null -eq $errorText); requiredFiles = @($required.ToArray()); missingFiles = $missing; error = $errorText }
}

function Assert-GuardBridgeNative {
    param([string]$Root)
    $diagnostic = Get-GuardBridgeNativeDiagnostic $Root
    if ($null -ne $diagnostic.error) { throw $diagnostic.error }
    if ($diagnostic.missingFiles.Count -gt 0) { throw "Native guard file is missing: $($diagnostic.missingFiles[0]). Restore the existing installation before using this action." }
}

function Test-GuardBridgeNative {
    param([string]$Root)
    return (Get-GuardBridgeNativeDiagnostic $Root).available
}

function Resolve-GuardBridgeInstallation {
    param([string]$Root, [string]$StateRoot, [string]$RegistrationPath)
    if (-not $script:GuardBridgeInstallationResolverLoaded) {
        Import-Module -Name $script:GuardBridgeInstallationModule -Force -Global -DisableNameChecking -ErrorAction Stop
        $script:GuardBridgeInstallationResolverLoaded = $true
    }
    $resolvedState = Resolve-CodexGuardStateRoot -StateRoot $StateRoot -RegistrationPath $RegistrationPath
    $resolvedRoot = Resolve-CodexGuardInstallRoot -InstallRoot $Root -StateRoot $resolvedState -RegistrationPath $RegistrationPath
    return [pscustomobject]@{
        root = $resolvedRoot
        stateRoot = $resolvedState
        registrationPath = (Get-CodexGuardRegistrationPath -StateRoot $resolvedState -RegistrationPath $RegistrationPath)
    }
}

function Write-GuardBridgeRequest {
    param([string]$Command, [string]$StateRoot)
    if ($Command -notin @('Show', 'Arm', 'Disarm', 'Rescan', 'Stop')) { throw 'Unsupported native control request.' }
    $controlRoot = Join-Path $StateRoot 'control'
    [void](New-Item -ItemType Directory -Path $controlRoot -Force)
    $payload = [ordered]@{ command = $Command; requestedAtUtc = [datetime]::UtcNow.ToString('o'); processId = $PID } | ConvertTo-Json -Compress
    $name = '{0:D20}-{1}.json' -f [datetime]::UtcNow.Ticks, [guid]::NewGuid().ToString('N')
    $target = Join-Path $controlRoot $name
    $temporary = $target + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $payload, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $target -Force
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    return [pscustomobject]@{ ok = $true; action = $Command; outcome = 'queued'; queued = $true; executed = $false; message = 'Request queued for the original guard; execution is not yet confirmed.' }
}

function Invoke-GuardBridgeNativeShow {
    param([string]$Root, [string]$StateRoot)
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $main = Join-Path $Root 'CodexShutdownGuard.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}" -StateRoot "{1}" -Show' -f $main, $StateRoot
    $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory $Root -WindowStyle Hidden -PassThru
    return [pscustomobject]@{ ok = $true; action = 'Show'; outcome = 'start-requested'; queued = $false; executed = $false; processId = $process.Id; message = 'Original guard launch requested with Show; no Arm request was sent.' }
}

function Invoke-GuardBridgeLaunchCodex {
    param([string]$Root)
    Import-Module (Join-Path $Root 'CodexShutdownGuard.CodexLaunch.psm1') -Force -ErrorAction Stop
    return Start-CodexGuardDesktopWithProxy
}

function Invoke-GuardBridgeAutoStartCodex {
    param([string]$Root, [string]$StateRoot, [bool]$Value)
    Import-Module (Join-Path $Root 'CodexShutdownGuard.CodexLaunch.psm1') -Force -ErrorAction Stop
    [void](New-Item -ItemType Directory -Path $StateRoot -Force)
    $path = Join-Path $StateRoot 'codex-launch-settings.json'
    Set-CodexGuardAutoStartSetting -Path $path -Enabled $Value
    return [pscustomobject]@{ ok = $true; action = 'SetAutoStartCodex'; outcome = 'saved'; enabled = $Value; path = $path; message = 'Saved using the original module. Applies on the next guard startup; the current tray checkmark can remain stale. The active guard was not restarted.' }
}

function Invoke-GuardBridgeAutoStartGuard {
    param([string]$Root, [string]$StateRoot, [bool]$Value)
    $module = Join-Path $Root 'CodexShutdownGuard.CodexStartup.psm1'
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) { throw 'Codex startup support is missing. Update the native installation before changing this setting.' }
    Import-Module $module -Force -ErrorAction Stop
    $path = Join-Path $StateRoot 'codex-startup-settings.json'
    $result = Set-CodexGuardStartWithCodex -Enabled $Value -SettingsPath $path -NativeRoot $Root -StateRoot $StateRoot
    $message = if ($Value) { 'Codex startup preference enabled. The native watcher starts the guard unarmed when Codex opens; an existing guard retains its current shutdown mode.' } else { 'Codex startup preference disabled. An existing guard retains its current shutdown mode.' }
    return [pscustomobject]@{ ok = $true; action = 'SetAutoStartGuard'; outcome = 'saved'; enabled = $Value; path = $path; result = $result; message = $message }
}

function Invoke-GuardBridge {
    param([string]$Action, [string]$Root, [string]$StateRoot, [string]$Enabled, [string]$RegistrationPath)
    if ($Action -cnotin @('Inspect', 'Show', 'Arm', 'Disarm', 'Rescan', 'Stop', 'LaunchCodex', 'SetAutoStartCodex', 'SetAutoStartGuard')) { throw 'Unsupported Action.' }
    if ($Action -in @('SetAutoStartCodex', 'SetAutoStartGuard')) {
        if ($Enabled -cnotin @('true', 'false')) { throw "Enabled must be the string 'true' or 'false'." }
    }
    elseif (-not [string]::IsNullOrEmpty($Enabled)) { throw 'Enabled is only valid for startup setting actions.' }
    if (-not [string]::IsNullOrEmpty($StateRoot)) { $StateRoot = Resolve-GuardBridgePath $StateRoot 'StateRoot' }
    if (-not [string]::IsNullOrEmpty($Root)) { $Root = Resolve-GuardBridgePath $Root 'Root' }
    if (-not [string]::IsNullOrEmpty($RegistrationPath)) { $RegistrationPath = Resolve-GuardBridgePath $RegistrationPath 'RegistrationPath' }
    $installation = Resolve-GuardBridgeInstallation $Root $StateRoot $RegistrationPath
    $Root = $installation.root
    $StateRoot = $installation.stateRoot

    if ($Action -eq 'Inspect') {
        $instance = Get-GuardBridgeInstance $StateRoot
        $defaults = Read-GuardBridgeJson (Join-Path $Root 'config.default.json')
        $packageConfig = Join-Path $Root 'config.json'
        $stateConfig = Join-Path $StateRoot 'config.json'
        $configPath = if (Test-Path -LiteralPath $packageConfig -PathType Leaf) { $packageConfig } elseif (Test-Path -LiteralPath $stateConfig -PathType Leaf) { $stateConfig } else { $defaults.path }
        $configuration = Read-GuardBridgeJson $configPath
        $values = [ordered]@{}
        if ($defaults.valid) { foreach ($property in $defaults.value.PSObject.Properties) { $values[$property.Name] = $property.Value } }
        if ($configuration.valid) { foreach ($property in $configuration.value.PSObject.Properties) { $values[$property.Name] = $property.Value } }
        $statusFile = Read-GuardBridgeJson (Join-Path $StateRoot 'status.json')
        $launchFile = Read-GuardBridgeJson (Join-Path $StateRoot 'codex-launch-settings.json')
        $startupFile = Read-GuardBridgeJson (Join-Path $StateRoot 'codex-startup-settings.json')
        $poll = 60
        if ($values.Contains('pollSeconds')) { try { $poll = [Math]::Max(1, [Math]::Min(3600, [int]$values['pollSeconds'])) } catch { $poll = 60 } }
        $freshnessSeconds = ($poll * 2) + 30
        $age = $null
        $fresh = $false
        $updated = Get-GuardBridgeProperty $statusFile.value 'updatedAtUtc'
        if ($null -ne $updated) {
            try {
                $when = [datetimeoffset]::Parse([string]$updated, [Globalization.CultureInfo]::InvariantCulture)
                $age = ([datetimeoffset]::UtcNow - $when.ToUniversalTime()).TotalSeconds
                $fresh = ($age -ge -30 -and $age -le $freshnessSeconds)
            }
            catch { $fresh = $false }
        }
        $running = $null
        if ($instance.detected -eq $false) { $running = $false }
        elseif ($instance.detected -eq $true -and $fresh -and (Get-GuardBridgeProperty $statusFile.value 'running') -is [bool]) { $running = [bool]$statusFile.value.running }
        $autoStart = $false
        $autoStartValid = $true
        if ($launchFile.exists) {
            $setting = Get-GuardBridgeProperty $launchFile.value 'autoStartCodexWithProxy'
            $autoStartValid = ($launchFile.valid -and ($null -eq $setting -or $setting -is [bool]))
            if ($setting -is [bool]) { $autoStart = $setting }
        }
        $startGuard = $false
        $startGuardValid = $true
        if ($startupFile.exists) {
            $setting = Get-GuardBridgeProperty $startupFile.value 'startGuardWithCodex'
            $startGuardValid = ($startupFile.valid -and ($null -eq $setting -or $setting -is [bool]))
            if ($setting -is [bool]) { $startGuard = $setting }
        }
        $nativeDiagnostic = Get-GuardBridgeNativeDiagnostic $Root
        return [pscustomobject]@{
            ok = $true; action = 'Inspect'; readOnly = $true; root = $Root; stateRoot = $StateRoot
            installationRegistrationPath = $installation.registrationPath
            nativeAvailable = $nativeDiagnostic.available
            nativeDiagnostics = $nativeDiagnostic
            instance = $instance; running = $running
            status = [pscustomobject]@{ file = $statusFile; updatedAtUtc = $updated; ageSeconds = $age; fresh = $fresh; stale = ($statusFile.exists -and -not $fresh); freshnessSeconds = $freshnessSeconds; interpretation = if ($fresh) { 'Recent stored snapshot; native instance detection is reported separately.' } else { 'Stored state is absent, invalid or stale; it does not prove current runtime state.' } }
            configuration = [pscustomobject]@{ file = $configuration; defaults = $defaults; mergedValues = [pscustomobject]$values; note = 'Merged stored values; the original guard validates and clamps values at startup.' }
            launchSettings = [pscustomobject]@{ file = $launchFile; valid = $autoStartValid; autoStartCodexWithProxy = if ($autoStartValid) { $autoStart } else { $null } }
            guardStartupSettings = [pscustomobject]@{ file = $startupFile; valid = $startGuardValid; startGuardWithCodex = if ($startGuardValid) { $startGuard } else { $null }; note = 'Saved preference only; it does not prove the startup watcher is currently running.' }
        }
    }

    Assert-GuardBridgeNative $Root
    if ($Action -eq 'LaunchCodex') {
        $result = Invoke-GuardBridgeLaunchCodex $Root
        return [pscustomobject]@{ ok = $true; action = $Action; outcome = 'native-result'; result = $result }
    }
    if ($Action -eq 'SetAutoStartCodex') { return Invoke-GuardBridgeAutoStartCodex $Root $StateRoot ($Enabled -ceq 'true') }
    if ($Action -eq 'SetAutoStartGuard') { return Invoke-GuardBridgeAutoStartGuard $Root $StateRoot ($Enabled -ceq 'true') }
    $instance = Get-GuardBridgeInstance $StateRoot
    if ($null -eq $instance.detected) { throw $instance.error }
    if (-not $instance.detected) {
        if ($Action -eq 'Show') { return Invoke-GuardBridgeNativeShow $Root $StateRoot }
        if ($Action -eq 'Arm') { throw 'Guard is not running. Open it with Show first; no arm request was queued.' }
        return [pscustomobject]@{ ok = $true; action = $Action; outcome = 'not-running'; queued = $false; executed = $false; message = 'No guard instance is running; no control request was created.' }
    }
    return Write-GuardBridgeRequest $Action $StateRoot
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
        $OutputEncoding = [Console]::OutputEncoding
        Invoke-GuardBridge -Action $Action -Root $Root -StateRoot $StateRoot -Enabled $Enabled -RegistrationPath $RegistrationPath | ConvertTo-Json -Depth 20 -Compress
        exit 0
    }
    catch {
        [pscustomobject]@{ ok = $false; action = $Action; error = $_.Exception.Message } | ConvertTo-Json -Depth 4 -Compress
        exit 1
    }
}
