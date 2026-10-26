[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $root 'CodexShutdownGuard.CodexStartup.psm1'
$module = Import-Module $modulePath -Force -PassThru
$script:Passed = 0
function Assert-Equal($expected, $actual, [string]$name) {
    if ($expected -ne $actual) { throw "FAILED: $name; expected [$expected], got [$actual]." }
    $script:Passed++
}
function Assert-Throws([scriptblock]$action, [string]$name) {
    $caught = $false
    try { & $action | Out-Null } catch { $caught = $true }
    Assert-Equal $true $caught $name
}
function Write-TestJson([string]$path, [object]$value) {
    [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
}
$testRoot = Join-Path $env:TEMP ('CodexGuardStartup_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$nativeRoot = Join-Path $testRoot 'native with spaces'
$stateRoot = Join-Path $testRoot 'state with spaces'
$startupRoot = Join-Path $testRoot 'Startup'
[void][IO.Directory]::CreateDirectory($nativeRoot)
[void][IO.Directory]::CreateDirectory($stateRoot)
[void][IO.Directory]::CreateDirectory($startupRoot)
$settingsPath = Join-Path $stateRoot 'codex-startup-settings.json'
$sessionPath = Join-Path $stateRoot 'codex-startup-session.json'
$stopPath = Join-Path $stateRoot 'codex-startup-stop.json'
$shortcutPath = Join-Path $startupRoot 'CodexShutdownGuard.CodexStartup.lnk'
$unrelatedShortcut = Join-Path $startupRoot 'CodexShutdownGuard.lnk'
[IO.File]::WriteAllText($unrelatedShortcut, 'existing-login-guard')
[IO.File]::WriteAllText((Join-Path $nativeRoot 'CodexShutdownGuard.ps1'), '# mock native entry')
[IO.File]::WriteAllText((Join-Path $nativeRoot 'CodexShutdownGuard.CodexStartupWatcher.ps1'), '# mock watcher entry')
$fixture = [pscustomobject]@{
    Starts = @(); ShortcutWrites = 0; ShortcutInfo = $null
    FailShortcut = $false; FailStart = $false; FailWritePath = ''; FailWriteCount = 0
    GuardRunning = $false; WatcherRunning = $false; WatcherChecksUntilExit = 0
    Sessions = @(); Index = 0; Sleeps = 0; DisableOnSleep = $false
    SettingsPath = $settingsPath
}
& $module {
    param($fixture)
    $script:StartupTest = $fixture
    $script:RealStartupAtomic = (Get-Command Write-CodexGuardStartupAtomicBytes).ScriptBlock
    function script:Write-CodexGuardStartupShortcut {
        param($Path, $StartInfo)
        $script:StartupTest.ShortcutWrites++
        $script:StartupTest.ShortcutInfo = $StartInfo
        if ($script:StartupTest.FailShortcut) { throw 'Mock shortcut failure.' }
        [IO.File]::WriteAllText($Path, ($StartInfo.FileName + [Environment]::NewLine + $StartInfo.Arguments))
    }
    function script:Invoke-CodexGuardStartupProcess {
        param($StartInfo)
        if ($script:StartupTest.FailStart) { throw 'Mock process failure.' }
        $script:StartupTest.Starts += @($StartInfo)
        return [pscustomobject]@{ Id = 12345 }
    }
    function script:Test-CodexGuardStartupMutexExists {
        param($Name)
        if ($Name -like '*CodexStartup_*') {
            $running = $script:StartupTest.WatcherRunning
            if ($running -and $script:StartupTest.WatcherChecksUntilExit -gt 0) {
                $script:StartupTest.WatcherChecksUntilExit--
                if ($script:StartupTest.WatcherChecksUntilExit -eq 0) { $script:StartupTest.WatcherRunning = $false }
            }
            return $running
        }
        return $script:StartupTest.GuardRunning
    }
    function script:Write-CodexGuardStartupAtomicBytes {
        param($Path, $Bytes)
        if ($Path -eq $script:StartupTest.FailWritePath -and $script:StartupTest.FailWriteCount -gt 0) {
            $script:StartupTest.FailWriteCount--
            throw 'Mock atomic write failure.'
        }
        & $script:RealStartupAtomic -Path $Path -Bytes $Bytes
    }
    function script:Get-CodexGuardAppSession {
        $index = [Math]::Min($script:StartupTest.Index, $script:StartupTest.Sessions.Count - 1)
        $script:StartupTest.Index++
        return $script:StartupTest.Sessions[$index]
    }
    function script:Start-Sleep {
        param($Seconds, $Milliseconds)
        $script:StartupTest.Sleeps++
        if ($script:StartupTest.DisableOnSleep) {
            [IO.File]::WriteAllText($script:StartupTest.SettingsPath, '{"startGuardWithCodex":false}')
        }
    }
    function script:Start-CodexGuardDesktopWithProxy { throw 'Reverse Codex launch is forbidden.' }
    function script:Start-Process { throw 'Direct process startup is forbidden.' }
    function script:Set-ItemProperty { throw 'Proxy registry writes are forbidden.' }
} $fixture
function Reset-WatcherFixture {
    $fixture.Starts = @(); $fixture.Index = 0; $fixture.Sleeps = 0
    $fixture.GuardRunning = $false; $fixture.WatcherRunning = $false; $fixture.WatcherChecksUntilExit = 0; $fixture.DisableOnSleep = $false
    if ([IO.File]::Exists($sessionPath)) { [IO.File]::Delete($sessionPath) }
    if ([IO.File]::Exists($stopPath)) { [IO.File]::Delete($stopPath) }
    Write-TestJson $settingsPath ([pscustomobject]@{ startGuardWithCodex = $true })
}
function Watch([int]$iterations) {
    return Invoke-CodexGuardCodexStartupWatcher -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -PollSeconds 0 -MaxIterations $iterations
}
$sessionA = [pscustomobject]@{ Available = $true; SessionKey = '202610210102030000000' }
$sessionB = [pscustomobject]@{ Available = $true; SessionKey = '202610210102040000000' }
$unavailable = [pscustomobject]@{ Available = $false; SessionKey = '' }
try {
    Assert-Equal $false (Get-CodexGuardStartWithCodexSetting -Path $settingsPath) 'missing settings default disabled'
    Assert-Equal $false ([IO.File]::Exists($shortcutPath)) 'default creates no startup shortcut'
    foreach ($content in @('{bad', 'null', '[]', 'true', '{"startGuardWithCodex":"true"}', '{"startGuardWithCodex":1}')) {
        [IO.File]::WriteAllText($settingsPath, $content)
        Assert-Equal $false (Get-CodexGuardStartWithCodexSetting -Path $settingsPath) 'malformed or nonboolean settings fail closed'
    }
    [IO.File]::WriteAllText($settingsPath, '{bad')
    Assert-Throws { Set-CodexGuardStartWithCodex -Enabled $true -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -StartupDirectory $startupRoot } 'setter rejects corrupt JSON'
    Assert-Equal '{bad' ([IO.File]::ReadAllText($settingsPath)) 'setter preserves corrupt file for repair'
    Write-TestJson $settingsPath ([pscustomobject]@{ schemaVersion = 6; other = [pscustomobject]@{ keep = 'value' }; startGuardWithCodex = $false })
    $result = Set-CodexGuardStartWithCodex -Enabled $true -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -StartupDirectory $startupRoot
    Assert-Equal $true $result.Enabled 'enable returns enabled'
    Assert-Equal $true (Get-CodexGuardStartWithCodexSetting -Path $settingsPath) 'enable persists boolean true'
    Assert-Equal $true ([IO.File]::Exists($shortcutPath)) 'enable adds only dedicated watcher shortcut'
    Assert-Equal 'value' (([IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json).other.keep) 'enable preserves unknown nested fields'
    Assert-Equal 6 (([IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json).schemaVersion) 'enable preserves existing schema'
    Assert-Equal 1 $fixture.Starts.Count 'enable starts one hidden watcher'
    Assert-Equal $false $fixture.Starts[0].UseShellExecute 'watcher startup never uses a shell'
    Assert-Equal $true $fixture.Starts[0].CreateNoWindow 'watcher startup has no console'
    Assert-Equal 'Hidden' ([string]$fixture.Starts[0].WindowStyle) 'watcher startup explicitly hidden'
    Assert-Equal $true ($fixture.Starts[0].Arguments -like '* -SettingsPath "*codex-startup-settings.json"*') 'watcher gets quoted dedicated settings path'
    Assert-Equal 'existing-login-guard' ([IO.File]::ReadAllText($unrelatedShortcut)) 'enable preserves existing login guard shortcut'
    $bytes = [IO.File]::ReadAllBytes($settingsPath)
    Assert-Equal $false ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'settings written without UTF8 BOM'
    $fixture.Starts = @()
    $result = Set-CodexGuardStartWithCodex -Enabled $false -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -StartupDirectory $startupRoot
    Assert-Equal $false $result.Enabled 'disable returns disabled'
    Assert-Equal $false (Get-CodexGuardStartWithCodexSetting -Path $settingsPath) 'disable persists false'
    Assert-Equal $false ([IO.File]::Exists($shortcutPath)) 'disable deletes dedicated shortcut'
    Assert-Equal 0 $fixture.Starts.Count 'disable starts no process'
    Assert-Equal 'existing-login-guard' ([IO.File]::ReadAllText($unrelatedShortcut)) 'disable preserves existing login guard shortcut'
    $fixture.WatcherRunning = $true; $fixture.WatcherChecksUntilExit = 1
    $result = Set-CodexGuardStartWithCodex -Enabled $true -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -StartupDirectory $startupRoot
    Assert-Equal 'Started' $result.WatcherStatus 'quick re-enable replaces watcher already exiting from disabled setting'
    Assert-Equal 1 $fixture.Starts.Count 'quick re-enable starts a new live watcher'
    Assert-Equal $false ([IO.File]::Exists($stopPath)) 'quick re-enable clears only its completed stop signal'
    $fixture.Starts = @()
    $result = Set-CodexGuardStartWithCodex -Enabled $true -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -StartupDirectory $startupRoot -NoStartWatcher
    Assert-Equal 'NotStarted' $result.WatcherStatus 'install NoStart preserves watcher launch suppression'
    Assert-Equal 0 $fixture.Starts.Count 'NoStart starts no watcher'
    $fixture.WatcherRunning = $true
    $result = Start-CodexGuardCodexStartupWatcher -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot
    Assert-Equal 'AlreadyRunning' $result.Status 'existing watcher prevents redundant launch'
    Assert-Equal 0 $fixture.Starts.Count 'existing watcher starts zero processes'
    $fixture.WatcherRunning = $false

    $savedSettings = [IO.File]::ReadAllText($settingsPath)
    $savedShortcut = [IO.File]::ReadAllText($shortcutPath)
    [IO.File]::WriteAllText($stopPath, 'old-stop-signal')
    $fixture.FailStart = $true
    Assert-Throws { Set-CodexGuardStartWithCodex -Enabled $true -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -StartupDirectory $startupRoot } 'watcher process failure propagates'
    $fixture.FailStart = $false
    Assert-Equal $savedSettings ([IO.File]::ReadAllText($settingsPath)) 'process failure restores exact settings'
    Assert-Equal $savedShortcut ([IO.File]::ReadAllText($shortcutPath)) 'process failure restores exact shortcut'
    Assert-Equal 'old-stop-signal' ([IO.File]::ReadAllText($stopPath)) 'process failure restores stop signal'
    $fixture.FailWritePath = $settingsPath; $fixture.FailWriteCount = 1
    Assert-Throws { Set-CodexGuardStartWithCodex -Enabled $false -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -StartupDirectory $startupRoot } 'settings write failure propagates'
    $fixture.FailWritePath = ''
    Assert-Equal $savedSettings ([IO.File]::ReadAllText($settingsPath)) 'settings write failure preserves previous settings'
    Assert-Equal $savedShortcut ([IO.File]::ReadAllText($shortcutPath)) 'disable write failure restores deleted shortcut'
    $fixture.FailShortcut = $true
    Assert-Throws { Set-CodexGuardStartWithCodex -Enabled $true -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -StartupDirectory $startupRoot } 'shortcut failure propagates'
    $fixture.FailShortcut = $false
    Assert-Equal $savedSettings ([IO.File]::ReadAllText($settingsPath)) 'shortcut failure preserves settings'
    Assert-Equal $savedShortcut ([IO.File]::ReadAllText($shortcutPath)) 'shortcut failure preserves existing shortcut'
    $missingState = Join-Path $testRoot 'first enable rollback'
    $missingSettings = Join-Path $missingState 'codex-startup-settings.json'
    $missingStartup = Join-Path $testRoot 'new startup rollback'
    $fixture.FailStart = $true
    Assert-Throws { Set-CodexGuardStartWithCodex -Enabled $true -SettingsPath $missingSettings -NativeRoot $nativeRoot -StateRoot $missingState -StartupDirectory $missingStartup } 'first enable process failure propagates'
    $fixture.FailStart = $false
    Assert-Equal $false ([IO.File]::Exists($missingSettings)) 'failed first enable removes newly created settings'
    Assert-Equal $false ([IO.File]::Exists((Join-Path $missingStartup 'CodexShutdownGuard.CodexStartup.lnk'))) 'failed first enable removes newly created shortcut'

    Reset-WatcherFixture
    $fixture.Sessions = @($unavailable, $sessionA, $sessionA, $unavailable, $sessionA, $sessionB, $sessionB)
    $result = Watch 7
    Assert-Equal 2 $result.Launches 'new desktop sessions each launch once'
    Assert-Equal 2 $fixture.Starts.Count 'repeated and temporarily unavailable sessions never relaunch'
    foreach ($info in $fixture.Starts) {
        Assert-Equal $true ($info.Arguments -like '* -Tray -FromCodexStartup -StateRoot "*state with spaces"') 'guard starts unarmed with reverse-loop suppression and same state root'
        Assert-Equal $false ($info.Arguments -match '(?i)-Arm(?:\s|$)|LaunchCodex|Proxy|Executor') 'startup cannot arm or launch Codex/proxy/executor'
        Assert-Equal $true $info.CreateNoWindow 'native startup creates no console'
        Assert-Equal 'Hidden' ([string]$info.WindowStyle) 'native startup hidden'
    }
    $fixture.Sessions = @($sessionA); $fixture.Index = 0; $fixture.Starts = @()
    $result = Watch 1
    Assert-Equal 0 $fixture.Starts.Count 'watcher restart preserves consumed session and manual guard exit'
    Assert-Equal 0 $result.Launches 'persisted consumed session starts no native'

    Reset-WatcherFixture
    $fixture.Sessions = @($sessionA); $fixture.FailStart = $true
    $result = Invoke-CodexGuardCodexStartupWatcher -SettingsPath $settingsPath -NativeRoot $nativeRoot -StateRoot $stateRoot -PollSeconds 0 -MaxIterations 1 -WarningAction SilentlyContinue
    $fixture.FailStart = $false; $fixture.Index = 0
    Assert-Equal 0 $result.Launches 'failed native start is not reported as successful'
    $result = Watch 1
    Assert-Equal 0 $fixture.Starts.Count 'failed native start is consumed and never loops within same desktop session'

    Reset-WatcherFixture
    $fixture.GuardRunning = $true; $fixture.Sessions = @($sessionA)
    $result = Watch 1
    Assert-Equal 0 $result.Launches 'running native guard is not duplicated'
    $fixture.GuardRunning = $false; $fixture.Index = 0
    $result = Watch 1
    Assert-Equal 0 $result.Launches 'session observed with guard running stays consumed after manual exit'
    Reset-WatcherFixture
    $fixture.Sessions = @($sessionA); $fixture.DisableOnSleep = $true
    $result = Watch 5
    Assert-Equal 'Disabled' $result.Status 'disabling terminates watcher next poll'
    Assert-Equal 1 $fixture.Sleeps 'disable terminates without repeated polling'
    Reset-WatcherFixture
    Write-TestJson $settingsPath ([pscustomobject]@{ startGuardWithCodex = $false })
    $fixture.Sessions = @($sessionA)
    $result = Watch 1
    Assert-Equal 'Disabled' $result.Status 'disabled watcher exits immediately'
    Assert-Equal 0 $fixture.Starts.Count 'disabled watcher launches nothing'
    Assert-Equal 0 $fixture.Index 'disabled watcher does not query desktop sessions'
    Reset-WatcherFixture
    $mutexName = & $module { param($path) Get-CodexGuardStartupMutexName -StateRoot $path -Kind Watcher } $stateRoot
    $created = $false
    $watcherMutex = [Threading.Mutex]::new($true, $mutexName, [ref]$created)
    try {
        $fixture.Sessions = @($sessionA)
        $result = Watch 1
        Assert-Equal 'AlreadyRunning' $result.Status 'duplicate watcher exits via independent mutex'
        Assert-Equal 0 $fixture.Starts.Count 'duplicate watcher launches nothing'
        Assert-Equal 0 $fixture.Index 'duplicate watcher performs no process discovery'
    }
    finally { if ($created) { $watcherMutex.ReleaseMutex() }; $watcherMutex.Dispose() }
    [IO.File]::WriteAllText($settingsPath, '{bad')
    $result = Stop-CodexGuardCodexStartupWatcher -StateRoot $stateRoot -TimeoutSeconds 0
    Assert-Equal 'Stopped' $result.Status 'explicit stop works without parsing broken settings'
    Assert-Equal $true ([IO.File]::Exists($stopPath)) 'explicit stop writes independent stop signal'
    Write-TestJson $settingsPath ([pscustomobject]@{ startGuardWithCodex = $true })
    $result = Watch 1
    Assert-Equal 'Stopped' $result.Status 'stop signal takes priority over enabled settings'

    $unicodeName = ([char]0x4E2D).ToString() + [char]0x6587 + ' directory with spaces'
    $unicodeRoot = Join-Path $testRoot $unicodeName
    [void][IO.Directory]::CreateDirectory($unicodeRoot)
    [IO.File]::WriteAllText((Join-Path $unicodeRoot 'CodexShutdownGuard.ps1'), '# fixture')
    $unicodeInfo = & $module { param($native, $state) New-CodexGuardStartupProcessInfo -NativeRoot $native -StateRoot $state } $unicodeRoot $unicodeRoot
    Assert-Equal $true $unicodeInfo.Arguments.Contains(('"' + (Join-Path $unicodeRoot 'CodexShutdownGuard.ps1') + '"')) 'Unicode and spaced main path stays one quoted argument'
    Assert-Equal $true $unicodeInfo.Arguments.EndsWith((' -StateRoot "' + $unicodeRoot + '"')) 'Unicode and spaced state path stays one quoted argument'
    $escaped = & $module { ConvertTo-CodexGuardStartupQuotedArgument 'C:\directory with spaces\' }
    Assert-Equal '"C:\directory with spaces\\"' $escaped 'trailing path separator is Windows quoted safely'
    $guardName = & $module { param($path) Get-CodexGuardStartupMutexName -StateRoot $path -Kind Guard } $stateRoot
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $expectedHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($stateRoot.ToLowerInvariant()))) -replace '-', '').Substring(0,16) }
    finally { $sha.Dispose() }
    Assert-Equal ('Local\CodexShutdownGuard_' + $expectedHash) $guardName 'guard detection uses unchanged native mutex algorithm'
    foreach ($path in @($modulePath, (Join-Path $root 'CodexShutdownGuard.CodexStartupWatcher.ps1'))) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        Assert-Equal 0 @($errors).Count 'new startup source parses under Windows PowerShell'
        $forbidden = @($ast.FindAll({ param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
            return $node.GetCommandName() -match '^(shutdown(\.exe)?|Stop-Computer|Restart-Computer|Start-CodexGuardDesktopWithProxy|Set-ItemProperty|New-ItemProperty)$'
        }, $true))
        Assert-Equal 0 $forbidden.Count 'startup code has no shutdown, reverse-launch, or proxy write commands'
    }
    Assert-Equal 'existing-login-guard' ([IO.File]::ReadAllText($unrelatedShortcut)) 'entire test leaves legacy startup shortcut unchanged'
    Write-Output ("PASS: {0} Codex startup checks; all process starts and shortcuts mocked." -f $script:Passed)
}
finally {
    Remove-Module $module -ErrorAction SilentlyContinue
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedRoot.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    if ([IO.Directory]::Exists($resolvedRoot)) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
