Set-StrictMode -Version 2.0

function Get-CodexGuardSetupPackageVersion {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    $path = Join-Path $PackageRoot 'plugins\codex-shutdown-guard\plugin.json'
    $manifest = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($manifest.name -cne 'codex-shutdown-guard' -or $manifest.version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'The package must contain the Codex Shutdown Guard manifest with a stable semantic version.'
    }
    return [string]$manifest.version
}

function Get-CodexGuardSetupSearchPath {
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in @($env:PATH, [Environment]::GetEnvironmentVariable('PATH', 'User'), [Environment]::GetEnvironmentVariable('PATH', 'Machine'))) {
        foreach ($part in ([string]$value).Split(';')) {
            $part = [Environment]::ExpandEnvironmentVariables($part.Trim().Trim('"'))
            if (-not [string]::IsNullOrWhiteSpace($part) -and -not $paths.Contains($part)) { $paths.Add($part) }
        }
    }
    return ($paths -join ';')
}

function Find-CodexGuardSetupApplication {
    param([string[]]$Names, [string]$SearchPath)
    foreach ($name in $Names) {
        foreach ($directory in $SearchPath.Split(';')) {
            if ([string]::IsNullOrWhiteSpace($directory)) { continue }
            try { $candidate = Join-Path $directory $name } catch { continue }
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
        }
    }
    return $null
}

function Get-CodexGuardSetupPluginDependencies {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    $version = Get-CodexGuardSetupPackageVersion -PackageRoot $PackageRoot
    $searchPath = Get-CodexGuardSetupSearchPath
    $node = Find-CodexGuardSetupApplication -Names @('node.exe') -SearchPath $searchPath
    $nodeVersion = if (-not [string]::IsNullOrWhiteSpace($node)) { Get-CodexGuardSetupNodeVersion -NodePath $node -SearchPath $searchPath } else { [pscustomobject]@{ supported=$false; version=$null } }
    $git = Find-CodexGuardSetupApplication -Names @('git.exe') -SearchPath $searchPath
    $codex = Find-CodexGuardSetupApplication -Names @('codex.exe', 'codex.cmd') -SearchPath $searchPath
    if ([string]::IsNullOrWhiteSpace($codex) -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $bundle = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        if (Test-Path -LiteralPath $bundle -PathType Container) {
            $candidates = @(Get-ChildItem -LiteralPath $bundle -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $candidate = Join-Path $_.FullName 'codex.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
            } | Sort-Object LastWriteTimeUtc -Descending)
            if ($candidates.Count -gt 0) { $codex = $candidates[0].FullName }
        }
    }
    $missing = @()
    if (-not $nodeVersion.supported) { $missing += 'Node.js 18 或更新版本' }
    if ([string]::IsNullOrWhiteSpace($codex)) { $missing += 'Codex CLI' }
    if ([string]::IsNullOrWhiteSpace($git)) { $missing += 'Git' }
    $codexHome = $env:CODEX_HOME
    if ([string]::IsNullOrWhiteSpace($codexHome)) { $codexHome = Join-Path $env:USERPROFILE '.codex' }
    $message = if ($missing.Count -eq 0) { '聊天插件所需程序已找到。' } else { '聊天插件尚缺少：' + ($missing -join '、') + '。原生守卫仍可安装。' }
    return [pscustomobject]@{
        version = $version; NodePath = $node; CodexPath = $codex; GitPath = $git; SearchPath = $searchPath
        CodexHome = [IO.Path]::GetFullPath($codexHome)
        NodeAvailable = [bool]$nodeVersion.supported; NodeVersion = $nodeVersion.version
        CodexAvailable = -not [string]::IsNullOrWhiteSpace($codex)
        GitAvailable = -not [string]::IsNullOrWhiteSpace($git)
        CanInstall = $missing.Count -eq 0; Missing = @($missing); message = $message
        NodeDownloadUrl = 'https://nodejs.org/en/download'
    }
}

function Get-CodexGuardSetupNodeVersion {
    param([string]$NodePath, [string]$SearchPath)
    try {
        $probe = Invoke-CodexGuardSetupCli -Executable $NodePath -Arguments @('--version') -SearchPath $SearchPath -TimeoutSeconds 8
        $text = ([string]$probe.stdout).Trim()
        if ($probe.exitCode -eq 0 -and $text -match '^v([0-9]+)\.[0-9]+\.[0-9]+$') {
            return [pscustomobject]@{ supported = [int]$matches[1] -ge 18; version = $text }
        }
    }
    catch { }
    return [pscustomobject]@{ supported=$false; version=$null }
}

function ConvertTo-CodexGuardSetupLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-CodexGuardSetupCli {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$SearchPath,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 180
    )
    # Encoded PowerShell passes each fixed CLI argument separately, including npm .cmd shims.
    # Only the child receives the refreshed PATH; the installing process and registry are untouched.
    $argumentList = @($Arguments | ForEach-Object { ConvertTo-CodexGuardSetupLiteral $_ }) -join ','
    $command = '$ProgressPreference = ''SilentlyContinue''; [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); $OutputEncoding = [Console]::OutputEncoding; $setupArguments = @(' + $argumentList + '); & ' + (ConvertTo-CodexGuardSetupLiteral $Executable) + ' @setupArguments; if ($null -eq $LASTEXITCODE) { exit 1 }; exit $LASTEXITCODE'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    if (-not [string]::IsNullOrWhiteSpace($SearchPath)) { $start.EnvironmentVariables['PATH'] = $SearchPath }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start Codex CLI.' }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            return [pscustomobject]@{ exitCode = -1; stdout = ''; stderr = 'Codex CLI timed out. A child Git operation may still be finishing; inspect plugin status before retrying.'; timedOut = $true }
        }
        return [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $outputTask.GetAwaiter().GetResult(); stderr = $errorTask.GetAwaiter().GetResult(); timedOut = $false }
    }
    finally { $process.Dispose() }
}

function Test-CodexGuardSetupOwnedSource {
    param([string]$Source)
    return $Source -match '^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)xury222/codex-shutdown-guard(?:\.git)?/?$'
}

function Read-CodexGuardSetupMarketplaceRegistration {
    param([string]$CodexHome, [string]$Name)
    $path = Join-Path $CodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The existing marketplace registration could not be read safely.' }
    $escaped = [regex]::Escape($Name)
    $header = '^\s*\[marketplaces\.(?:' + $escaped + '|"' + $escaped + '"|\x27' + $escaped + '\x27)\]\s*(?:#.*)?$'
    $inside = $false; $found = 0; $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if ($line -match $header) { $inside = $true; $found++; continue }
        if ($line -match '^\s*\[') { $inside = $false }
        if (-not $inside -or $line -match '^\s*(?:#.*)?$') { continue }
        if ($line -notmatch '^\s*(source_type|source|ref)\s*=\s*("(?:\\.|[^"\\])*"|\x27[^\x27]*\x27)\s*(?:#.*)?$') {
            throw 'The existing marketplace uses a configuration format this installer cannot restore safely.'
        }
        $key = $matches[1]; $literal = $matches[2]
        if ($values.ContainsKey($key)) { throw 'The existing marketplace contains duplicate settings.' }
        if ($literal.StartsWith("'")) { $values[$key] = $literal.Substring(1, $literal.Length - 2) }
        else { $values[$key] = $literal | ConvertFrom-Json }
    }
    if ($found -ne 1 -or -not $values.ContainsKey('source_type') -or $values.source_type -cne 'git' -or -not $values.ContainsKey('source') -or -not (Test-CodexGuardSetupOwnedSource $values.source)) {
        throw 'The existing marketplace is not the verified GitHub source for this guard.'
    }
    if ($values.ContainsKey('ref') -and ($values.ref -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$')) {
        throw 'The previous Git ref cannot be passed to the installed CLI safely; no marketplace was changed.'
    }
    return [pscustomobject]@{ source = [string]$values.source; hasRef = $values.ContainsKey('ref'); ref = if ($values.ContainsKey('ref')) { [string]$values.ref } else { $null } }
}

function Install-CodexGuardChatPlugin {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [object]$Dependencies,
        [scriptblock]$CliInvoker
    )
    $name = 'codex-shutdown-guard'; $marketplaceName = 'codex-shutdown-guard-local'
    $pluginId = $name + '@' + $marketplaceName
    $source = 'https://github.com/xury222/codex-shutdown-guard.git'
    $version = Get-CodexGuardSetupPackageVersion -PackageRoot $PackageRoot
    if ($null -eq $Dependencies) { $Dependencies = Get-CodexGuardSetupPluginDependencies -PackageRoot $PackageRoot }
    $execution = [pscustomobject]@{ changed = $false; removedOld = $false; addedNew = $false; attemptedInstall = $false; uncertain = $false }
    $previousRegistration = $null; $previousPlugin = $null
    function Result([bool]$Ok, [string]$Code, [string]$Message, [bool]$RollbackAttempted = $false, $RollbackSucceeded = $null, [string]$Details = '') {
        return [pscustomobject]@{ ok = $Ok; code = $Code; message = $Message; version = $version; pluginId = $pluginId; changed = $execution.changed; rollbackAttempted = $RollbackAttempted; rollbackSucceeded = $RollbackSucceeded; details = $Details }
    }
    function Run-Cli([string[]]$CommandArguments) {
        if ($null -ne $CliInvoker) { $result = & $CliInvoker $Dependencies.CodexPath $CommandArguments $Dependencies.SearchPath }
        else { $result = Invoke-CodexGuardSetupCli -Executable $Dependencies.CodexPath -Arguments $CommandArguments -SearchPath $Dependencies.SearchPath }
        if ($null -ne $result -and $null -ne $result.PSObject.Properties['timedOut'] -and $result.timedOut) { $execution.uncertain = $true }
        if ($null -eq $result -or $result.exitCode -ne 0) {
            $detail = if ($null -eq $result) { 'Codex CLI returned no result.' } else { ([string]$result.stderr + "`n" + [string]$result.stdout).Trim() }
            throw $detail
        }
        try { return ([string]$result.stdout | ConvertFrom-Json) }
        catch { throw 'Codex CLI returned invalid JSON. The operation may already have completed.' }
    }
    function Read-Installed {
        $listing = Run-Cli -CommandArguments @('plugin','list','--marketplace',$marketplaceName,'--json')
        if ($null -eq $listing.PSObject.Properties['installed']) { throw 'Codex CLI did not return an installed-plugin list.' }
        return @($listing.installed | Where-Object { $_.pluginId -ceq $pluginId })
    }
    if (-not $Dependencies.CanInstall) { return Result $false 'missing-dependencies' ([string]$Dependencies.message) }
    try {
        $marketplaces = Run-Cli -CommandArguments @('plugin','marketplace','list','--json')
        if ($null -eq $marketplaces.PSObject.Properties['marketplaces']) { throw 'Codex CLI did not return a marketplace list.' }
        $existing = @($marketplaces.marketplaces | Where-Object { $_.name -ceq $marketplaceName })
        if ($existing.Count -gt 1) { throw 'More than one marketplace has the guard name; no changes were made.' }
        $installed = @(Read-Installed)
        if ($installed.Count -gt 1) { throw 'More than one installed guard entry was returned; no changes were made.' }
        if ($installed.Count -eq 1) {
            $previousPlugin = $installed[0]
            if ($previousPlugin.enabled -isnot [bool] -or -not $previousPlugin.enabled) {
                return Result $false 'existing-plugin-disabled' '聊天插件当前处于禁用状态，安装器已保留该选择。请先在 Codex 中启用此插件后重试，或仅安装原生守卫。'
            }
        }
        if ($existing.Count -eq 1) {
            $entry = $existing[0]
            $previousRegistration = Read-CodexGuardSetupMarketplaceRegistration -CodexHome $Dependencies.CodexHome -Name $marketplaceName
            if ($null -ne $entry.PSObject.Properties['marketplaceSource'] -and ($entry.marketplaceSource.sourceType -cne 'git' -or -not (Test-CodexGuardSetupOwnedSource ([string]$entry.marketplaceSource.source)))) {
                return Result $false 'marketplace-conflict' '同名插件来源不是本项目的 GitHub 仓库，安装器未替换它。请在 Codex 中检查该来源，或仅安装原生守卫。'
            }
            $snapshot = Join-Path ([string]$entry.root) '.agents\plugins\marketplace.json'
            $metadata = [IO.File]::ReadAllText($snapshot, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($metadata.name -cne $marketplaceName -or @($metadata.plugins).Count -ne 1 -or $metadata.plugins[0].name -cne $name) {
                return Result $false 'marketplace-conflict' '同名来源中包含其他插件，安装器未修改它。请仅安装原生守卫，或在 Codex 中单独管理聊天插件。'
            }
            if ($null -ne $previousPlugin -and $previousPlugin.version -ceq $version -and $previousRegistration.hasRef -and $previousRegistration.ref -ceq ('v' + $version)) {
                return Result $true 'already-installed' ('聊天插件 ' + $version + ' 已安装并启用。')
            }
            $execution.changed = $true; $execution.removedOld = $true
            Run-Cli -CommandArguments @('plugin','marketplace','remove',$marketplaceName,'--json') | Out-Null
        }
        $execution.changed = $true; $execution.addedNew = $true; $execution.attemptedInstall = $true
        Run-Cli -CommandArguments @('plugin','marketplace','add',$source,'--ref',('v' + $version),'--json') | Out-Null
        Run-Cli -CommandArguments @('plugin','add',$pluginId,'--json') | Out-Null
        $verified = @(Read-Installed)
        if ($verified.Count -ne 1 -or $verified[0].version -cne $version -or $verified[0].enabled -isnot [bool] -or -not $verified[0].enabled) { throw 'The installed plugin version or enabled state does not match this package.' }
        return Result $true 'installed' ('聊天插件 ' + $version + ' 已安装。请重启 Codex 后在本地聊天中使用。')
    }
    catch {
        $failure = $_.Exception.Message
        if ($execution.uncertain) { return Result $false 'operation-pending' '聊天插件操作超时，状态尚未确认，Git 或 Codex CLI 可能仍在后台完成操作。安装器没有继续修改或回滚；请稍后在 Codex 插件管理中检查状态后再试。' $false $null $failure }
        if (-not $execution.changed) {
            $message = if ($failure -match 'unrecognized|unexpected argument|unknown (?:command|subcommand)') { '当前 Codex CLI 不支持所需插件命令，请更新 Codex 后重试。已有插件设置未修改，原生守卫仍可独立使用。' } else { '聊天插件未安装，已有插件设置未修改。原生守卫仍可独立使用。' }
            return Result $false 'install-failed' $message $false $null $failure
        }
        $restored = $true
        try {
            if ($execution.attemptedInstall -and $null -eq $previousPlugin) {
                $after = @(Read-Installed)
                if ($after.Count -gt 0) { Run-Cli -CommandArguments @('plugin','remove',$pluginId,'--json') | Out-Null }
            }
            $currentMarketplaces = Run-Cli -CommandArguments @('plugin','marketplace','list','--json')
            $current = @($currentMarketplaces.marketplaces | Where-Object { $_.name -ceq $marketplaceName })
            if ($current.Count -gt 1) { throw 'More than one marketplace has the guard name during restoration.' }
            if ($current.Count -eq 1) {
                Read-CodexGuardSetupMarketplaceRegistration -CodexHome $Dependencies.CodexHome -Name $marketplaceName | Out-Null
                if ($null -ne $current[0].PSObject.Properties['marketplaceSource'] -and ($current[0].marketplaceSource.sourceType -cne 'git' -or -not (Test-CodexGuardSetupOwnedSource ([string]$current[0].marketplaceSource.source)))) { throw 'The marketplace source changed during installation; it was not removed.' }
                $currentSnapshot = Join-Path ([string]$current[0].root) '.agents\plugins\marketplace.json'
                $currentMetadata = [IO.File]::ReadAllText($currentSnapshot, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($currentMetadata.name -cne $marketplaceName -or @($currentMetadata.plugins).Count -ne 1 -or $currentMetadata.plugins[0].name -cne $name) { throw 'The marketplace contents changed during installation; they were not removed.' }
                Run-Cli -CommandArguments @('plugin','marketplace','remove',$marketplaceName,'--json') | Out-Null
            }
            if ($execution.removedOld -and $null -ne $previousRegistration) {
                $restoreArguments = @('plugin','marketplace','add',$previousRegistration.source)
                if ($previousRegistration.hasRef) { $restoreArguments += @('--ref',$previousRegistration.ref) }
                $restoreArguments += '--json'
                Run-Cli $restoreArguments | Out-Null
                if ($null -ne $previousPlugin) {
                    Run-Cli -CommandArguments @('plugin','add',$pluginId,'--json') | Out-Null
                    $restoredPlugins = @(Read-Installed)
                    if ($restoredPlugins.Count -ne 1 -or $restoredPlugins[0].version -cne $previousPlugin.version -or -not $restoredPlugins[0].enabled) { throw 'The previous plugin version could not be confirmed after restoration.' }
                }
            }
        }
        catch { $restored = $false; $failure += "`nRestore: " + $_.Exception.Message }
        $message = if ($restored) { '聊天插件安装失败，已恢复此前的插件来源与安装状态。原生守卫仍可独立使用。' } else { '聊天插件安装失败，自动恢复未完成。请在 Codex 插件管理中检查此插件；原生守卫仍可独立使用。' }
        return Result $false 'install-failed' $message $true $restored $failure
    }
}

Export-ModuleMember -Function Get-CodexGuardSetupPluginDependencies, Get-CodexGuardSetupPackageVersion, Invoke-CodexGuardSetupCli, Install-CodexGuardChatPlugin
