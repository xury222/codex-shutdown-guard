Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-CodexGuardProxyUri {
    param([Parameter(Mandatory = $true)][string]$Address)
    $value = $Address.Trim()
    if ($value -notmatch '^[a-z][a-z0-9+.-]*://') { $value = 'http://' + $value }
    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https', 'socks5', 'socks5h') -or
        [string]::IsNullOrWhiteSpace($uri.Host) -or $uri.Port -lt 1 -or $uri.Port -gt 65535 -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or $uri.AbsolutePath -notin @('', '/')) {
        throw '当前代理地址无法安全识别；请在代理软件中确认不含凭据的 HTTP/HTTPS 或明确 SOCKS5 地址。'
    }
    return $uri.GetLeftPart([UriPartial]::Authority)
}

function Get-CodexGuardCurrentProxy {
    param([object]$InternetSettings)
    if ($null -eq $InternetSettings) {
        $InternetSettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    }
    if ($null -eq $InternetSettings.PSObject.Properties['ProxyEnable'] -or -not [bool]$InternetSettings.ProxyEnable -or
        $null -eq $InternetSettings.PSObject.Properties['ProxyServer'] -or [string]::IsNullOrWhiteSpace([string]$InternetSettings.ProxyServer)) {
        throw '没有发现已启用的明确系统代理地址。请先开启代理软件的系统代理，再启动 Codex；不会改动系统代理。'
    }
    $map = @{}
    $server = ([string]$InternetSettings.ProxyServer).Trim()
    if ($server.Contains('=')) {
        foreach ($part in $server.Split(';')) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $pair = $part -split '=', 2
            if ($pair.Length -ne 2 -or [string]::IsNullOrWhiteSpace($pair[1])) { throw '当前系统代理映射不完整，请在代理软件中确认。' }
            $map[$pair[0].Trim().ToLowerInvariant()] = $pair[1].Trim()
        }
        if ($map.ContainsKey('socks') -and -not $map.ContainsKey('http') -and -not $map.ContainsKey('https')) {
            if ($map['socks'] -notmatch '^socks5h?://') { throw '系统只提供 SOCKS 地址，协议版本未明确；请使用代理软件的 HTTP 系统代理或明确的 SOCKS5 地址。' }
            $http = ConvertTo-CodexGuardProxyUri $map['socks']
            $https = $http
        }
        else {
            $httpAddress = if ($map.ContainsKey('http')) { $map['http'] } elseif ($map.ContainsKey('https')) { $map['https'] } else { throw '系统代理未提供 HTTP/HTTPS 地址。' }
            $httpsAddress = if ($map.ContainsKey('https')) { $map['https'] } else { $httpAddress }
            $http = ConvertTo-CodexGuardProxyUri $httpAddress
            $https = ConvertTo-CodexGuardProxyUri $httpsAddress
        }
    }
    else {
        $http = ConvertTo-CodexGuardProxyUri $server
        $https = $http
    }
    return [pscustomobject]@{ Http = $http; Https = $https }
}

function Get-CodexGuardSignedDesktop {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $package) { throw '未找到已注册的官方 OpenAI.Codex 桌面应用。' }
    $path = [IO.Path]::GetFullPath((Join-Path $package.InstallLocation 'app\ChatGPT.exe'))
    if ($path -notmatch '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$') { throw '桌面应用路径不属于已核验的官方安装结构。' }
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'OpenAI OpCo, LLC') { throw '桌面应用的 OpenAI 签名校验失败，未启动应用。' }
    return [pscustomobject]@{ Path = $path; Version = $package.Version.ToString() }
}

function Get-CodexGuardRunningDesktop {
    $running = @()
    foreach ($process in @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)) {
        try { $path = $process.Path } catch { throw '无法确认已运行桌面应用的路径，请先检查当前 Codex 状态。' }
        if ([string]::IsNullOrWhiteSpace($path)) { throw '无法确认已运行桌面应用的路径，请先检查当前 Codex 状态。' }
        if ($path -match '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$') { $running += $process }
    }
    return $running
}

function Test-CodexGuardProxyPort {
    param([Parameter(Mandatory = $true)][string]$Proxy)
    $uri = [Uri]$Proxy
    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.ConnectAsync($uri.Host, $uri.Port)
        if (-not $pending.Wait(2500) -or -not $client.Connected) { return $false }
        return $true
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function New-CodexGuardDesktopStartInfo {
    param([Parameter(Mandatory = $true)][string]$DesktopPath, [Parameter(Mandatory = $true)][object]$Proxy)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $DesktopPath
    $info.WorkingDirectory = Split-Path -Parent $DesktopPath
    $info.UseShellExecute = $false
    # Child-process environment only. The signed desktop owns all executors.
    $info.EnvironmentVariables['HTTP_PROXY'] = $Proxy.Http
    $info.EnvironmentVariables['HTTPS_PROXY'] = $Proxy.Https
    $info.EnvironmentVariables['ALL_PROXY'] = $Proxy.Https
    $existingBypass = $info.EnvironmentVariables['NO_PROXY']
    $info.EnvironmentVariables['NO_PROXY'] = (@($existingBypass, 'localhost', '127.0.0.1', '::1') | Where-Object { $_ }) -join ','
    return $info
}

function Invoke-CodexGuardDesktopProcessStart {
    param([Parameter(Mandatory = $true)][Diagnostics.ProcessStartInfo]$StartInfo)
    return [Diagnostics.Process]::Start($StartInfo)
}

function Start-CodexGuardDesktopWithProxy {
    $desktop = Get-CodexGuardSignedDesktop
    if (@(Get-CodexGuardRunningDesktop).Count -gt 0) {
        return [pscustomobject]@{ Status = 'AlreadyRunning'; Message = 'Codex 已在运行，未重复启动。代理只在新启动时生效；如需更换代理地址，请保存工作并退出 Codex 后再点此项。' }
    }
    $proxy = Get-CodexGuardCurrentProxy
    foreach ($address in @($proxy.Http, $proxy.Https) | Select-Object -Unique) {
        if (-not (Test-CodexGuardProxyPort $address)) { throw '当前系统代理端口不可达。请先开启代理软件，再点击启动 Codex。' }
    }
    # Recheck after proxy probing to avoid ordinary concurrent launches.
    if (@(Get-CodexGuardRunningDesktop).Count -gt 0) {
        return [pscustomobject]@{ Status = 'AlreadyRunning'; Message = 'Codex 已在运行，未重复启动。' }
    }
    $info = New-CodexGuardDesktopStartInfo -DesktopPath $desktop.Path -Proxy $proxy
    $process = Invoke-CodexGuardDesktopProcessStart -StartInfo $info
    return [pscustomobject]@{ Status = 'Started'; DesktopProcessId = $process.Id; Version = $desktop.Version; Message = '已使用当前系统代理启动官方 Codex。连接及任务状态请在 Codex 中查看。' }
}

function Get-CodexGuardAutoStartSetting {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $settings = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $settings.PSObject.Properties['autoStartCodexWithProxy']) { return $false }
    if ($settings.autoStartCodexWithProxy -isnot [bool]) { throw 'Codex 自动启动设置应为布尔值，请检查守卫启动设置文件。' }
    return $settings.autoStartCodexWithProxy
}

function Set-CodexGuardAutoStartSetting {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][bool]$Enabled)
    $settings = if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ schemaVersion = 1 } }
    $settings | Add-Member -NotePropertyName autoStartCodexWithProxy -NotePropertyValue $Enabled -Force
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($settings | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

Export-ModuleMember -Function @('ConvertTo-CodexGuardProxyUri', 'Get-CodexGuardCurrentProxy', 'Get-CodexGuardSignedDesktop', 'Get-CodexGuardRunningDesktop', 'New-CodexGuardDesktopStartInfo', 'Start-CodexGuardDesktopWithProxy', 'Get-CodexGuardAutoStartSetting', 'Set-CodexGuardAutoStartSetting')
