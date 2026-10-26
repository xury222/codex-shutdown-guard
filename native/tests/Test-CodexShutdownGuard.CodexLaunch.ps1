[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $root 'CodexShutdownGuard.CodexLaunch.psm1') -Force -PassThru
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
$testRoot = Join-Path $env:TEMP ('CodexGuardCodexLaunch_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
$environmentNames = @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')
$originalEnvironment = @{}
foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    Assert-Equal 'http://127.0.0.1:10080' (ConvertTo-CodexGuardProxyUri '127.0.0.1:10080') 'bare system endpoint uses HTTP'
    Assert-Equal 'socks5h://localhost:1080' (ConvertTo-CodexGuardProxyUri 'socks5h://localhost:1080') 'explicit SOCKS5 DNS protocol is retained'
    Assert-Equal 'https://localhost:10081' (ConvertTo-CodexGuardProxyUri 'https://localhost:10081') 'explicit HTTPS protocol is retained'
    $ipv6=[Uri](ConvertTo-CodexGuardProxyUri 'http://[::1]:10080')
    Assert-Equal ([Net.IPAddress]::IPv6Loopback.ToString()) ([Net.IPAddress]::Parse($ipv6.Host.Trim('[]')).ToString()) 'IPv6 endpoint is retained'
    Assert-Equal 10080 $ipv6.Port 'IPv6 port is retained'
    foreach ($address in @('http://user:password@localhost:1080','ftp://localhost:1080','http://localhost:1080/path','http://localhost:1080/?secret=1','http://localhost:1080/#fragment','socks5://localhost')) {
        Assert-Throws { ConvertTo-CodexGuardProxyUri $address } 'invalid or credential-bearing proxy is rejected'
    }
    $proxy = Get-CodexGuardCurrentProxy ([pscustomobject]@{ ProxyEnable=1; ProxyServer='127.0.0.1:10080' })
    Assert-Equal 'http://127.0.0.1:10080' $proxy.Http 'single proxy HTTP endpoint'
    Assert-Equal $proxy.Http $proxy.Https 'single proxy is used for HTTPS CONNECT'
    $split = Get-CodexGuardCurrentProxy ([pscustomobject]@{ ProxyEnable=1; ProxyServer='http=127.0.0.1:10080;https=https://localhost:10081' })
    Assert-Equal 'http://127.0.0.1:10080' $split.Http 'protocol mapping HTTP endpoint'
    Assert-Equal 'https://localhost:10081' $split.Https 'protocol mapping HTTPS endpoint'
    Assert-Throws { Get-CodexGuardCurrentProxy ([pscustomobject]@{ ProxyEnable=0; ProxyServer='127.0.0.1:10080' }) } 'disabled system proxy never silently reused'
    Assert-Throws { Get-CodexGuardCurrentProxy ([pscustomobject]@{ ProxyEnable=1; ProxyServer='socks=127.0.0.1:1080' }) } 'ambiguous SOCKS version is rejected'
    Assert-Throws { Get-CodexGuardCurrentProxy ([pscustomobject]@{ ProxyEnable=1; ProxyServer='http=' }) } 'incomplete mapping is rejected'
    $fixture = [pscustomobject]@{
        Package = [pscustomobject]@{ InstallLocation='C:\Program Files\WindowsApps\OpenAI.Codex_26.930.6422.0_x64__fixture'; Version=[version]'26.930.6422.0' }
        Signature = [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{ Subject='CN=OpenAI OpCo, LLC, O=OpenAI OpCo, LLC' } }
        Running=@(); ProcessesCalls=0; BecomeRunningAt=0; Registry=[pscustomobject]@{ ProxyEnable=1; ProxyServer='127.0.0.1:10080' }
        RegistryReads=0; ProxyReachable=$true; Probed=@(); Starts=0; StartInfo=$null
    }
    & $module {
        param($fixture)
        $script:LaunchFixture=$fixture
        function script:Get-AppxPackage { param($Name) if ($Name -ne 'OpenAI.Codex') { throw 'Wrong package name' }; return $script:LaunchFixture.Package }
        function script:Get-AuthenticodeSignature { param($LiteralPath) return $script:LaunchFixture.Signature }
        function script:Get-Process {
            param($Name,$ErrorAction)
            if ($Name -ne 'ChatGPT') { throw 'Only desktop process discovery is allowed' }
            $script:LaunchFixture.ProcessesCalls++
            if ($script:LaunchFixture.BecomeRunningAt -gt 0 -and $script:LaunchFixture.ProcessesCalls -ge $script:LaunchFixture.BecomeRunningAt) {
                return [pscustomobject]@{ Id=314; Path='C:\Program Files\WindowsApps\OpenAI.Codex_26.930.6422.0_x64__fixture\app\ChatGPT.exe' }
            }
            return $script:LaunchFixture.Running
        }
        function script:Get-ItemProperty { param($LiteralPath) if ($LiteralPath -ne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') { throw 'Unexpected registry read' }; $script:LaunchFixture.RegistryReads++; return $script:LaunchFixture.Registry }
        function script:Set-ItemProperty { throw 'Registry writes are forbidden in launch tests.' }
        function script:New-ItemProperty { throw 'Registry writes are forbidden in launch tests.' }
        function script:Test-CodexGuardProxyPort { param($Proxy) $script:LaunchFixture.Probed+=@($Proxy); return $script:LaunchFixture.ProxyReachable }
        function script:Invoke-CodexGuardDesktopProcessStart { param($StartInfo) $script:LaunchFixture.Starts++; $script:LaunchFixture.StartInfo=$StartInfo; return [pscustomobject]@{ Id=2718 } }
    } $fixture
    $desktop = Get-CodexGuardSignedDesktop
    Assert-Equal '26.930.6422.0' $desktop.Version 'registered official desktop version is selected'
    Assert-Equal $true $desktop.Path.EndsWith('\app\ChatGPT.exe') 'selected executable is desktop, never standalone CLI'
    $savedPackage=$fixture.Package
    $fixture.Package=$null
    Assert-Throws { Get-CodexGuardSignedDesktop } 'missing registered package fails closed'
    $fixture.Package=[pscustomobject]@{ InstallLocation='C:\Tools\OldCodex'; Version=[version]'1.0' }
    Assert-Throws { Get-CodexGuardSignedDesktop } 'other installation layout is rejected'
    $fixture.Package=$savedPackage
    $savedSignature=$fixture.Signature
    $fixture.Signature=[pscustomobject]@{ Status='NotSigned'; SignerCertificate=$null }
    Assert-Throws { Start-CodexGuardDesktopWithProxy } 'invalid signature cannot start desktop'
    $fixture.Signature=[pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{ Subject='CN=Another vendor' } }
    Assert-Throws { Start-CodexGuardDesktopWithProxy } 'other vendor signature cannot start desktop'
    $fixture.Signature=$savedSignature
    Assert-Equal 0 $fixture.Starts 'signature and package failures started zero processes'
    $fixture.Running=@([pscustomobject]@{ Id=314; Path=$desktop.Path })
    $result=Start-CodexGuardDesktopWithProxy
    Assert-Equal 'AlreadyRunning' $result.Status 'official desktop is not restarted or duplicated'
    Assert-Equal 0 $fixture.RegistryReads 'existing desktop does not need proxy discovery'
    Assert-Equal 0 $fixture.Starts 'existing desktop starts no new processes'
    $fixture.Running=@([pscustomobject]@{ Id=123; Path='' })
    Assert-Throws { Start-CodexGuardDesktopWithProxy } 'unknown running process path fails closed'
    $fixture.Running=@([pscustomobject]@{ Id=123; Path='C:\Tools\ChatGPT.exe' })
    Assert-Equal 0 @(Get-CodexGuardRunningDesktop).Count 'unrelated named app is not official desktop'
    $fixture.Running=@()
    $fixture.ProxyReachable=$false
    Assert-Throws { Start-CodexGuardDesktopWithProxy } 'unreachable existing proxy starts no app'
    Assert-Equal 0 $fixture.Starts 'bad proxy started zero processes'
    $fixture.ProxyReachable=$true
    $fixture.ProcessesCalls=0
    $fixture.BecomeRunningAt=2
    $result=Start-CodexGuardDesktopWithProxy
    Assert-Equal 'AlreadyRunning' $result.Status 'concurrent desktop appearance is detected after probing'
    Assert-Equal 0 $fixture.Starts 'second deduplication check starts zero processes'
    $fixture.BecomeRunningAt=0
    foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) { [Environment]::SetEnvironmentVariable($name,'http://parent.invalid:9999','Process') }
    [Environment]::SetEnvironmentVariable('NO_PROXY','fixture.internal','Process')
    $parentSnapshot=@{}
    foreach ($name in $environmentNames) { $parentSnapshot[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
    $result=Start-CodexGuardDesktopWithProxy
    Assert-Equal 'Started' $result.Status 'healthy current proxy starts official desktop'
    Assert-Equal 2718 $result.DesktopProcessId 'result is desktop process id'
    Assert-Equal 1 $fixture.Starts 'one desktop launch call'
    Assert-Equal $desktop.Path $fixture.StartInfo.FileName 'exact signed desktop is launched'
    Assert-Equal $false $fixture.StartInfo.UseShellExecute 'desktop launch retains child environment'
    Assert-Equal '' $fixture.StartInfo.Arguments 'no executor or unsafe commandline is launched'
    Assert-Equal 'http://127.0.0.1:10080' $fixture.StartInfo.EnvironmentVariables['HTTP_PROXY'] 'child HTTP proxy'
    Assert-Equal 'http://127.0.0.1:10080' $fixture.StartInfo.EnvironmentVariables['HTTPS_PROXY'] 'child HTTPS proxy'
    Assert-Equal 'http://127.0.0.1:10080' $fixture.StartInfo.EnvironmentVariables['ALL_PROXY'] 'child all proxy'
    Assert-Equal 'fixture.internal,localhost,127.0.0.1,::1' $fixture.StartInfo.EnvironmentVariables['NO_PROXY'] 'parent bypass is preserved with loopback additions'
    foreach ($name in $environmentNames) { Assert-Equal $parentSnapshot[$name] ([Environment]::GetEnvironmentVariable($name,'Process')) 'parent environment remains unchanged' }
    $fixture.Registry=[pscustomobject]@{ ProxyEnable=1; ProxyServer='127.0.0.1:10082' }
    $result=Start-CodexGuardDesktopWithProxy
    Assert-Equal 'http://127.0.0.1:10082' $fixture.StartInfo.EnvironmentVariables['HTTPS_PROXY'] 'each invocation reads current proxy endpoint'
    Assert-Equal $true ($fixture.RegistryReads -ge 2) 'current registry is re-read rather than pinned to old endpoint'
    $settingsPath=Join-Path $testRoot 'codex-launch-settings.json'
    Assert-Equal $false (Get-CodexGuardAutoStartSetting $settingsPath) 'new installation defaults auto-launch off'
    Set-CodexGuardAutoStartSetting $settingsPath $true
    Assert-Equal $true (Get-CodexGuardAutoStartSetting $settingsPath) 'auto-launch enable is persisted'
    [IO.File]::WriteAllText($settingsPath,'{"schemaVersion":7,"unknown":{"keep":[1,2]},"autoStartCodexWithProxy":true}',(New-Object Text.UTF8Encoding($false)))
    Set-CodexGuardAutoStartSetting $settingsPath $false
    $settings=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 7 $settings.schemaVersion 'settings schema preserved'
    Assert-Equal '1,2' ($settings.unknown.keep -join ',') 'unknown nested settings preserved'
    Assert-Equal $false (Get-CodexGuardAutoStartSetting $settingsPath) 'auto-launch disable is persisted'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp').Count 'settings save leaves no temporary files'
    [IO.File]::WriteAllText($settingsPath,'{"autoStartCodexWithProxy":"true"}',(New-Object Text.UTF8Encoding($false)))
    Assert-Throws { Get-CodexGuardAutoStartSetting $settingsPath } 'string booleans are not silently coerced'
    [IO.File]::WriteAllText($settingsPath,'{"broken":',(New-Object Text.UTF8Encoding($false)))
    $beforeInvalid=[IO.File]::ReadAllText($settingsPath)
    Assert-Throws { Set-CodexGuardAutoStartSetting $settingsPath $true } 'invalid existing settings fail instead of being overwritten'
    Assert-Equal $beforeInvalid ([IO.File]::ReadAllText($settingsPath)) 'malformed settings remain intact after failure'
    Remove-Item -LiteralPath $settingsPath

    $tokens=$null; $errors=$null
    $mainAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'CodexShutdownGuard.ps1'),[ref]$tokens,[ref]$errors)
    Assert-Equal 0 @($errors).Count 'updated main script parses in Windows PowerShell'
    foreach ($functionName in @('Request-CodexProxyLaunch','Set-GuardCodexAutoStart')) {
        $definition=$mainAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName },$true)
        if ($null -eq $definition) { throw "Required function missing: $functionName" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $script:BalloonCalls=0
    function Show-GuardBalloon { param($Title,$Text,$Icon) $script:BalloonCalls++ }
    function Invoke-NativeShutdownSchedule { throw 'Shutdown forbidden in launch tests.' }
    function Invoke-NativeShutdownAbort { throw 'Shutdown abort forbidden in launch tests.' }
    $script:CodexLaunchSettingsPath=$settingsPath
    $script:Runtime=[pscustomobject]@{ Armed=$true; SeenActive=$true; Phase='WaitingTasks'; GraceDeadlineUtc=$null; NativeDeadlineUtc=$null; ShutdownScheduled=$false; StableIdleSamples=0 }
    $script:Config=[pscustomobject]@{ pollSeconds=60; dryRun=$false; userMarker='keep' }
    $script:IgnoredTurnIds=@{ 'real-turn'=$true }
    $script:UsagePanelState=[pscustomobject]@{ visible=$false; x=12; y=34; hasPosition=$true }
    $runtimeBefore=$script:Runtime | ConvertTo-Json -Compress
    $configBefore=$script:Config | ConvertTo-Json -Compress
    $ignoreBefore=$script:IgnoredTurnIds | ConvertTo-Json -Compress
    $panelBefore=$script:UsagePanelState | ConvertTo-Json -Compress
    Add-Type -AssemblyName System.Windows.Forms
    $launchMenu=New-Object Windows.Forms.ToolStripMenuItem('Launch fixture')
    $script:AutoStartCodexMenuItem=New-Object Windows.Forms.ToolStripMenuItem('Auto fixture')
    $script:AutoStartCodexMenuItem.Checked=$false
    foreach ($pair in @(@('launchCodexMenuItem',$launchMenu),@('script:AutoStartCodexMenuItem',$script:AutoStartCodexMenuItem))) {
        $variableName=$pair[0]
        $clickAst=$mainAst.Find({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Click' -and $node.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $node.Expression.VariablePath.UserPath -eq $variableName },$true)
        if ($null -eq $clickAst) { throw "Required menu callback missing: $variableName" }
        $pair[1].Add_Click([scriptblock]::Create($clickAst.Arguments[0].ScriptBlock.Extent.Text.Trim('{}')))
    }
    $fixture.Running=@([pscustomobject]@{ Id=314; Path=$desktop.Path })
    $startsBefore=$fixture.Starts
    $launchMenu.PerformClick()
    Assert-Equal $startsBefore $fixture.Starts 'actual menu callback does not duplicate running desktop'
    Assert-Equal 1 $script:BalloonCalls 'actual launch menu reports result'
    $script:AutoStartCodexMenuItem.PerformClick()
    Assert-Equal $true $script:AutoStartCodexMenuItem.Checked 'actual auto-start menu enables setting'
    Assert-Equal $true (Get-CodexGuardAutoStartSetting $settingsPath) 'actual auto-start menu persists setting'
    Assert-Equal $startsBefore $fixture.Starts 'changing future auto-launch does not start or restart desktop'
    $script:AutoStartCodexMenuItem.PerformClick()
    Assert-Equal $false (Get-CodexGuardAutoStartSetting $settingsPath) 'actual auto-start menu toggles off'
    Request-CodexProxyLaunch -Automatic
    $fixture.Running=@()
    $fixture.ProxyReachable=$false
    $launchMenu.PerformClick()
    Assert-Equal $startsBefore $fixture.Starts 'actual menu launch failure starts no desktop'
    $fixture.ProxyReachable=$true
    [IO.File]::WriteAllText($settingsPath,'{"broken":',(New-Object Text.UTF8Encoding($false)))
    $script:AutoStartCodexMenuItem.PerformClick()
    Assert-Equal $false $script:AutoStartCodexMenuItem.Checked 'failed settings save does not advertise the new setting'
    Assert-Equal $runtimeBefore ($script:Runtime | ConvertTo-Json -Compress) 'launch and toggle preserve armed state and countdown'
    Assert-Equal $configBefore ($script:Config | ConvertTo-Json -Compress) 'launch and toggle preserve original guard configuration'
    Assert-Equal $ignoreBefore ($script:IgnoredTurnIds | ConvertTo-Json -Compress) 'launch and toggle preserve ignored task decisions'
    Assert-Equal $panelBefore ($script:UsagePanelState | ConvertTo-Json -Compress) 'launch and toggle preserve panel state'
    $launchMenu.Dispose(); $script:AutoStartCodexMenuItem.Dispose()
    [pscustomobject]@{ Passed=$script:Passed; RealDesktopLaunches=0; RealShutdownCommandsExecuted=0; RegistryWrites=0; ActualMenuCallbacksVerified=$true }
}
finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name,$originalEnvironment[$name],'Process') }
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $tempPrefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if ($resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
