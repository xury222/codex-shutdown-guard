[CmdletBinding()]
param([string]$Bridge)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Bridge)) { $Bridge = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\codex-shutdown-guard\scripts\Invoke-Guard.ps1' }
. $Bridge
$script:Passed = 0
function Assert-BridgeEqual($Expected, $Actual, [string]$Label) {
    if ($Expected -cne $Actual) { throw "FAIL $Label : expected [$Expected], actual [$Actual]" }
    $script:Passed++
}
function Assert-BridgeThrows([scriptblock]$Body, [string]$Label) {
    $threw = $false
    try { & $Body | Out-Null } catch { $threw = $true }
    Assert-BridgeEqual $true $threw $Label
}
function Write-TestJson([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
$testRoot = Join-Path $PSScriptRoot ('bridge-test-' + [guid]::NewGuid().ToString('N'))
$native = Join-Path $testRoot 'fake native'
$state = Join-Path $testRoot 'fake state'
$mutex = $null
$previousLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $testRoot 'fake profile'
try {
    [void](New-Item -ItemType Directory -Path $native -Force)
    foreach ($name in @('CodexShutdownGuard.ps1', 'CodexShutdownGuard.Core.psm1', 'CodexShutdownGuard.CodexLaunch.psm1', 'CodexShutdownGuard.CodexStartup.psm1')) {
        [IO.File]::WriteAllText((Join-Path $native $name), '# Isolated test fixture; never executed.', (New-Object Text.UTF8Encoding($false)))
    }
    Write-TestJson (Join-Path $native 'config.default.json') ([ordered]@{ pollSeconds=60; taskInactivitySeconds=1800; dryRun=$false })
    Write-TestJson (Join-Path $native 'config.json') ([ordered]@{ pollSeconds=5; dryRun=$true })
    Write-TestJson (Join-Path $native '.codex-shutdown-guard-install.json') ([ordered]@{ product='CodexShutdownGuard'; installRoot=$native })

    $inspect = Invoke-GuardBridge Inspect $native $state
    Assert-BridgeEqual $true $inspect.readOnly 'Inspect explicitly read-only'
    Assert-BridgeEqual $false (Test-Path -LiteralPath $state) 'Inspect does not create state directory'
    Assert-BridgeEqual $false $inspect.running 'Absent mutex cannot be considered running'
    Assert-BridgeEqual 5 $inspect.configuration.mergedValues.pollSeconds 'Installed config overrides default'
    Assert-BridgeEqual 1800 $inspect.configuration.mergedValues.taskInactivitySeconds 'Absent setting retains native default'
    Assert-BridgeEqual $false $inspect.launchSettings.autoStartCodexWithProxy 'Missing auto-start defaults false'
    Assert-BridgeEqual $false $inspect.guardStartupSettings.startGuardWithCodex 'Codex starts guard defaults false separately'
    Assert-BridgeEqual $true $inspect.nativeAvailable 'Native availability requires core files'
    $fixtureMain = Join-Path $native 'CodexShutdownGuard.ps1'
    $fixtureStartup = Join-Path $native 'CodexShutdownGuard.CodexStartup.psm1'
    $fixtureInstallation = Join-Path $native 'CodexShutdownGuard.Installation.psm1'
    $originalMain = [IO.File]::ReadAllText($fixtureMain)
    $originalStartup = [IO.File]::ReadAllText($fixtureStartup)
    Assert-BridgeEqual $false (Test-Path -LiteralPath $fixtureInstallation) 'Legacy main fixture has no installation module'
    Assert-BridgeEqual $true $inspect.nativeAvailable 'Legacy main without new dependency references remains usable'
    $dependencyOnlyMain = "Import-Module (Join-Path `$PSScriptRoot 'CodexShutdownGuard.CodexStartup.psm1') -Force`r`nImport-Module (Join-Path `$PSScriptRoot 'CodexShutdownGuard.Installation.psm1') -Force"
    [IO.File]::WriteAllText($fixtureMain, $dependencyOnlyMain, (New-Object Text.UTF8Encoding($false)))
    $partial = Invoke-GuardBridge Inspect $native $state
    Assert-BridgeEqual $false $partial.nativeAvailable 'Missing directly imported installation module marks native unavailable'
    Assert-BridgeEqual $true ($partial.nativeDiagnostics.missingFiles -contains 'CodexShutdownGuard.Installation.psm1') 'Missing installation dependency named in diagnostics'
    Assert-BridgeThrows { Invoke-GuardBridge Show $native $state } 'Actions reject missing directly imported installation module'
    [IO.File]::WriteAllText($fixtureInstallation, '# Isolated dependency fixture; never executed.', (New-Object Text.UTF8Encoding($false)))
    Assert-BridgeEqual $true (Invoke-GuardBridge Inspect $native $state).nativeAvailable 'New main is available when declared dependencies exist'
    Remove-Item -LiteralPath $fixtureStartup -Force
    $partial = Invoke-GuardBridge Inspect $native $state
    Assert-BridgeEqual $false $partial.nativeAvailable 'Missing directly imported startup module marks native unavailable'
    Assert-BridgeEqual $true ($partial.nativeDiagnostics.missingFiles -contains 'CodexShutdownGuard.CodexStartup.psm1') 'Missing startup dependency named in diagnostics'
    [IO.File]::WriteAllText($fixtureStartup, $originalStartup, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($fixtureMain, $originalMain, (New-Object Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath $fixtureInstallation -Force
    Assert-BridgeEqual $true (Invoke-GuardBridge Inspect $native $state).nativeAvailable 'Restored legacy main remains compatible without new module'
    $missingRoot = Join-Path $testRoot 'not installed'
    $absent = Invoke-GuardBridge Inspect $missingRoot $state
    Assert-BridgeEqual $false $absent.nativeAvailable 'Missing installation reported without installing'
    Assert-BridgeEqual $false (Test-Path -LiteralPath $missingRoot) 'Inspect does not install native files'
    Assert-BridgeEqual $false (Test-Path -LiteralPath $state) 'Inspect absent installation does not create state'
    foreach ($mode in @('Disarm','Stop','Rescan')) {
        $result = Invoke-GuardBridge $mode $native $state
        Assert-BridgeEqual 'not-running' $result.outcome "$mode when absent is no-op"
        Assert-BridgeEqual $false (Test-Path -LiteralPath $state) "$mode leaves no deferred request"
    }
    Assert-BridgeThrows { Invoke-GuardBridge Arm $native $state } 'Arm refuses absent instance'
    Assert-BridgeEqual $false (Test-Path -LiteralPath $state) 'Rejected Arm leaves no files'
    Assert-BridgeThrows { Invoke-GuardBridge Garbage $native $state } 'Unknown action refused'
    Assert-BridgeThrows { Invoke-GuardBridge inspect $native $state } 'Action case strict'
    Assert-BridgeThrows { Invoke-GuardBridge Inspect 'relative' $state } 'Relative root refused'
    Assert-BridgeThrows { Invoke-GuardBridge Inspect $native 'relative' } 'Relative state root refused'
    Assert-BridgeThrows { Invoke-GuardBridge SetAutoStartCodex $native $state 'yes' } 'Invalid boolean refused'
    Assert-BridgeThrows { Invoke-GuardBridge SetAutoStartCodex $native $state 'False' } 'Boolean spelling strict'
    Assert-BridgeThrows { Invoke-GuardBridge SetAutoStartGuard $native $state 'yes' } 'New startup setting rejects invalid boolean'
    Assert-BridgeThrows { Invoke-GuardBridge SetAutoStartGuard $native $state 'False' } 'New startup boolean spelling strict'
    Assert-BridgeThrows { Invoke-GuardBridge Inspect $native $state 'true' } 'Unexpected Enabled refused'

    $registeredState = Join-Path $env:LOCALAPPDATA 'CodexShutdownGuard'
    [void](New-Item -ItemType Directory -Path $registeredState)
    $registrationPath = Join-Path $registeredState 'installation.json'
    Write-TestJson $registrationPath ([ordered]@{schemaVersion=1; product='CodexShutdownGuard'; installRoot=$missingRoot; stateRoot=$state})
    $registrationHash = (Get-FileHash -LiteralPath $registrationPath).Hash
    $registered = Invoke-GuardBridge -Action Inspect
    Assert-BridgeEqual $missingRoot $registered.root 'Inspect resolves registered missing installation without a D drive dependency'
    Assert-BridgeEqual $false $registered.nativeAvailable 'Registered absent installation is reported missing'
    Assert-BridgeEqual $state $registered.stateRoot 'Omitted StateRoot follows fixed registration custom state root'
    Assert-BridgeEqual $registrationPath $registered.installationRegistrationPath 'Discovery registration stays in default local profile directory'
    Assert-BridgeEqual $false (Test-Path -LiteralPath $state) 'Inspect custom registered state does not create runtime state'
    Assert-BridgeEqual $registeredState (Invoke-GuardBridge -Action Inspect -StateRoot $registeredState).stateRoot 'Explicit state root takes precedence over registered state'
    Assert-BridgeEqual $registrationHash (Get-FileHash -LiteralPath $registrationPath).Hash 'Inspect leaves installation registration unchanged'
    Assert-BridgeEqual 1 @(Get-ChildItem -LiteralPath $registeredState -Force).Count 'Registered Inspect creates no status or queue files'
    Write-TestJson $registrationPath ([ordered]@{schemaVersion=1; product='OtherProduct'; installRoot=$missingRoot})
    Assert-BridgeThrows { Invoke-GuardBridge -Action Inspect } 'Invalid registration errors instead of selecting another guard'
    Assert-BridgeEqual $native (Invoke-GuardBridge Inspect $native $registeredState).root 'Explicit root takes precedence over stored registration'
    Write-TestJson $registrationPath ([ordered]@{schemaVersion=1; product='CodexShutdownGuard'; installRoot=$missingRoot; stateRoot='relative'})
    Assert-BridgeThrows { Invoke-GuardBridge -Action Inspect } 'Relative registered state root is refused'
    Write-TestJson $registrationPath ([ordered]@{schemaVersion=1; product='CodexShutdownGuard'; installRoot=$missingRoot})
    Assert-BridgeEqual $registeredState (Invoke-GuardBridge -Action Inspect).stateRoot 'Legacy registration without state root uses default state'

    function Start-Process {
        param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$PassThru)
        $script:StartCapture = [pscustomobject]@{ FilePath=$FilePath; Arguments=$ArgumentList; Directory=$WorkingDirectory; WindowStyle=$WindowStyle }
        return [pscustomobject]@{ Id=999999 }
    }
    $result = Invoke-GuardBridge Show $native $state
    Assert-BridgeEqual 'start-requested' $result.outcome 'Show requests launch when absent'
    Assert-BridgeEqual 'Hidden' $script:StartCapture.WindowStyle 'Native window stays hidden'
    Assert-BridgeEqual $true $script:StartCapture.Arguments.Contains('-STA') 'Windows Forms launched STA'
    Assert-BridgeEqual $true $script:StartCapture.Arguments.Contains('-Show') 'Show requested'
    Assert-BridgeEqual $false $script:StartCapture.Arguments.Contains('-Arm') 'Show does not arm'
    Assert-BridgeEqual $true $script:StartCapture.Arguments.Contains(('"{0}"' -f (Join-Path $native 'CodexShutdownGuard.ps1'))) 'Native path with spaces quoted'
    Assert-BridgeEqual $false (Test-Path -LiteralPath $state) 'Mocked Show does not write settings'

    [void](New-Item -ItemType Directory -Path $state)
    $name = Get-GuardBridgeMutexName ([IO.Path]::GetFullPath($state))
    $created = $false
    $mutex = [Threading.Mutex]::new($true, $name, [ref]$created)
    Assert-BridgeEqual $true $created 'Only isolated mutex created'
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $originalHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($state)).ToLowerInvariant()))) -replace '-', '').Substring(0,16) }
    finally { $sha.Dispose() }
    Assert-BridgeEqual ('Local\CodexShutdownGuard_' + $originalHash) $name 'Mutex exactly matches native algorithm'
    Write-TestJson (Join-Path $state 'status.json') ([ordered]@{ schemaVersion=6; running=$true; armed=$true; updatedAtUtc=[datetime]::UtcNow.AddHours(-1).ToString('o') })
    $before = (Get-FileHash -LiteralPath (Join-Path $state 'status.json')).Hash
    $inspect = Invoke-GuardBridge Inspect $native $state
    Assert-BridgeEqual $true $inspect.instance.detected 'Existing isolated native mutex detected'
    Assert-BridgeEqual $true $inspect.status.stale 'Old snapshot labeled stale'
    Assert-BridgeEqual $null $inspect.running 'Stale snapshot cannot assert current running state'
    Assert-BridgeEqual $before (Get-FileHash -LiteralPath (Join-Path $state 'status.json')).Hash 'Inspect leaves snapshot bytes unchanged'
    Assert-BridgeEqual $false (Test-Path -LiteralPath (Join-Path $state 'control')) 'Inspect creates no queue'
    Write-TestJson (Join-Path $state 'status.json') ([ordered]@{ running=$true; updatedAtUtc=[datetime]::UtcNow.ToString('o') })
    $inspect = Invoke-GuardBridge Inspect $native $state
    Assert-BridgeEqual $true $inspect.running 'Recent snapshot plus native mutex confirms stored running flag'
    Write-TestJson $registrationPath ([ordered]@{schemaVersion=1; product='CodexShutdownGuard'; installRoot=$native; stateRoot=$state})
    $registered = Invoke-GuardBridge -Action Inspect
    Assert-BridgeEqual $native $registered.root 'Default tool resolves custom registered native root'
    Assert-BridgeEqual $state $registered.stateRoot 'Default tool resolves custom registered runtime state'
    Assert-BridgeEqual $true $registered.instance.detected 'Default tool checks custom state singleton mutex'
    Assert-BridgeEqual $true $registered.running 'Default tool reads fresh custom state snapshot'
    $cancel = Invoke-GuardBridge -Action Disarm
    Assert-BridgeEqual 'queued' $cancel.outcome 'Default cancellation reaches custom state guard'
    Assert-BridgeEqual 1 @(Get-ChildItem -LiteralPath (Join-Path $state 'control') -Filter '*.json' -File).Count 'Default cancellation queues in the registered state'
    Assert-BridgeEqual $false (Test-Path -LiteralPath (Join-Path $registeredState 'control')) 'Default cancellation creates no second default-state queue'
    Write-TestJson (Join-Path $state 'status.json') ([ordered]@{ running=$true; updatedAtUtc=[datetime]::UtcNow.AddHours(1).ToString('o') })
    Assert-BridgeEqual $false (Invoke-GuardBridge Inspect $native $state).status.fresh 'Future timestamps not accepted as fresh'
    [IO.File]::WriteAllText((Join-Path $state 'status.json'),'{partial',(New-Object Text.UTF8Encoding($false)))
    $inspect = Invoke-GuardBridge Inspect $native $state
    Assert-BridgeEqual $false $inspect.status.file.valid 'Partial JSON diagnosed without native scan'
    Assert-BridgeEqual $null $inspect.running 'Partial snapshot cannot assert running'

    foreach ($mode in @('Show','Arm','Disarm','Rescan','Stop')) {
        $result = Invoke-GuardBridge $mode $native $state
        Assert-BridgeEqual 'queued' $result.outcome "$mode queued for existing isolated instance"
        Assert-BridgeEqual $true $result.queued "$mode marked queued"
        Assert-BridgeEqual $false $result.executed "$mode not claimed executed"
    }
    $queue = @(Get-ChildItem -LiteralPath (Join-Path $state 'control') -Filter '*.json' -File)
    Assert-BridgeEqual 6 $queue.Count 'Exactly one request per explicit or default cancellation action'
    Assert-BridgeEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $state 'control') -Filter '*.tmp' -File).Count 'Atomic write leaves no temporary files'
    foreach ($file in $queue) {
        $payload = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-BridgeEqual 3 @($payload.PSObject.Properties).Count 'Native protocol has original three fields'
        Assert-BridgeEqual $PID $payload.processId 'Original protocol process id'
        Assert-BridgeEqual $true ($payload.command -cin @('Show','Arm','Disarm','Rescan','Stop')) 'Native command vocabulary retained'
        $bytes=[IO.File]::ReadAllBytes($file.FullName)
        Assert-BridgeEqual $false ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Request UTF8 without BOM'
    }

    function Import-Module { param($Name,[switch]$Force,$ErrorAction) $script:ImportCapture=$Name }
    function Start-CodexGuardDesktopWithProxy { $script:MockLaunchCount++; return [pscustomobject]@{ Status='AlreadyRunning'; Message='Isolated mock only' } }
    function Set-CodexGuardAutoStartSetting { param([string]$Path,[bool]$Enabled) $script:SettingCapture=[pscustomobject]@{Path=$Path; Enabled=$Enabled} }
    function Set-CodexGuardStartWithCodex {
        param([bool]$Enabled,[string]$SettingsPath,[string]$NativeRoot,[string]$StateRoot)
        $script:StartupCapture=[pscustomobject]@{Path=$SettingsPath; Enabled=$Enabled; NativeRoot=$NativeRoot; StateRoot=$StateRoot}
        return [pscustomobject]@{Enabled=$Enabled; ShortcutPath='mock-only'; WatcherStatus='mock-only'}
    }
    $script:MockLaunchCount = 0
    $launch = Invoke-GuardBridge LaunchCodex $native $state
    Assert-BridgeEqual 1 $script:MockLaunchCount 'Launch delegates once to original named function'
    Assert-BridgeEqual (Join-Path $native 'CodexShutdownGuard.CodexLaunch.psm1') $script:ImportCapture 'Launch uses installed module path'
    Assert-BridgeEqual 'AlreadyRunning' $launch.result.Status 'Original launch result preserved'
    foreach ($value in @('true','false')) {
        $setting = Invoke-GuardBridge SetAutoStartCodex $native $state $value
        Assert-BridgeEqual ($value -ceq 'true') $script:SettingCapture.Enabled 'String bool converted correctly'
        Assert-BridgeEqual (Join-Path $state 'codex-launch-settings.json') $script:SettingCapture.Path 'Original launch setting file retained'
        Assert-BridgeEqual 'saved' $setting.outcome 'Native setter result reported'
    }
    foreach ($value in @('true','false')) {
        $setting = Invoke-GuardBridge SetAutoStartGuard $native $state $value
        Assert-BridgeEqual ($value -ceq 'true') $script:StartupCapture.Enabled 'Codex-to-guard bool converted correctly'
        Assert-BridgeEqual (Join-Path $state 'codex-startup-settings.json') $script:StartupCapture.Path 'Codex-to-guard setting uses independent file'
        Assert-BridgeEqual $native $script:StartupCapture.NativeRoot 'Startup module receives resolved native installation'
        Assert-BridgeEqual $state $script:StartupCapture.StateRoot 'Startup module receives state root'
        Assert-BridgeEqual (Join-Path $native 'CodexShutdownGuard.CodexStartup.psm1') $script:ImportCapture 'Codex-to-guard delegates installed startup module'
        Assert-BridgeEqual 'saved' $setting.outcome 'Startup setter result reported'
    }
    Write-TestJson (Join-Path $state 'codex-launch-settings.json') ([ordered]@{autoStartCodexWithProxy='yes'})
    Assert-BridgeEqual $false (Invoke-GuardBridge Inspect $native $state).launchSettings.valid 'Malformed stored boolean diagnosed'
    Write-TestJson (Join-Path $state 'codex-startup-settings.json') ([ordered]@{startGuardWithCodex=$true})
    $inspect = Invoke-GuardBridge Inspect $native $state
    Assert-BridgeEqual $true $inspect.guardStartupSettings.startGuardWithCodex 'Inspect reads independent Codex-to-guard setting'
    Assert-BridgeEqual $false $inspect.launchSettings.valid 'Independent guard-to-Codex invalid preference stays invalid'
    $startupHash = (Get-FileHash -LiteralPath (Join-Path $state 'codex-startup-settings.json')).Hash
    [void](Invoke-GuardBridge Inspect $native $state)
    Assert-BridgeEqual $startupHash (Get-FileHash -LiteralPath (Join-Path $state 'codex-startup-settings.json')).Hash 'Inspect does not rewrite startup setting'
    Write-TestJson (Join-Path $state 'codex-startup-settings.json') ([ordered]@{startGuardWithCodex='yes'})
    Assert-BridgeEqual $false (Invoke-GuardBridge Inspect $native $state).guardStartupSettings.valid 'Malformed Codex-to-guard stored boolean diagnosed'
    $bytes=[IO.File]::ReadAllBytes($Bridge)
    Assert-BridgeEqual $false ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Bridge UTF8 without BOM'
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Bridge,[ref]$tokens,[ref]$errors)
    Assert-BridgeEqual 0 @($errors).Count 'Bridge parses in Windows PowerShell'
    [pscustomobject]@{Passed=$script:Passed; RealGuardActions=0; RealProxyLaunches=0; RealShutdownCommands=0; RealSettingWrites=0}
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowedParent,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^bridge-test-[0-9a-f]{32}$') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
