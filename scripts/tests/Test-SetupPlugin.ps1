[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Setup.Plugin.psm1'
$module = Import-Module $modulePath -Force -PassThru
$script:Passed = 0
function Assert-Equal($Expected, $Actual, [string]$Label) {
    if ($Expected -cne $Actual) { throw "FAIL $Label : expected [$Expected], actual [$Actual]" }
    $script:Passed++
}
function Assert-True([bool]$Actual, [string]$Label) { Assert-Equal $true $Actual $Label }
function Write-Json([string]$Path, $Value) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
$fixtureRoot = Join-Path $PSScriptRoot ('SetupPluginFixture-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
try {
    $package = Join-Path $fixtureRoot 'package'
    $version = '1.2.3'
    Write-Json (Join-Path $package 'plugins\codex-shutdown-guard\plugin.json') @{ name='codex-shutdown-guard'; version=$version }
    Assert-Equal $version (Get-CodexGuardSetupPackageVersion $package) 'version comes from package manifest'
    $badPackage = Join-Path $fixtureRoot 'bad-package'
    Write-Json (Join-Path $badPackage 'plugins\codex-shutdown-guard\plugin.json') @{ name='codex-shutdown-guard'; version='../unsafe' }
    $threw = $false; try { Get-CodexGuardSetupPackageVersion $badPackage | Out-Null } catch { $threw = $true }
    Assert-True $threw 'manifest cannot inject a Git ref or output path'

    $originalPath = $env:PATH
    $discoveryFixture = Join-Path $fixtureRoot 'discovery'
    [void][IO.Directory]::CreateDirectory($discoveryFixture)
    [IO.File]::WriteAllText((Join-Path $discoveryFixture 'node.exe'), 'never executed')
    [IO.File]::WriteAllText((Join-Path $discoveryFixture 'codex.cmd'), 'never executed')
    [IO.File]::WriteAllText((Join-Path $discoveryFixture 'git.exe'), 'never executed')
    & $module {
        param($Directory)
        $script:FixtureSearchPath = $Directory
        function script:Get-CodexGuardSetupSearchPath { return $script:FixtureSearchPath }
        function script:Get-CodexGuardSetupNodeVersion { return [pscustomobject]@{supported=$true;version='v24.0.0'} }
    } $discoveryFixture
    $discovery = Get-CodexGuardSetupPluginDependencies $package
    Assert-True $discovery.CanInstall 'PATH finds Node and npm Codex shim'
    Assert-Equal (Join-Path $discoveryFixture 'codex.cmd') $discovery.CodexPath 'npm CLI shim is accepted'
    Assert-Equal $originalPath $env:PATH 'dependency scan leaves parent PATH unchanged'
    Assert-Equal 'https://nodejs.org/en/download' $discovery.NodeDownloadUrl 'missing Node link uses official site'
    Assert-Equal $version $discovery.version 'dependency version comes from manifest'
    [IO.File]::Delete((Join-Path $discoveryFixture 'node.exe'))
    $missingNode = Get-CodexGuardSetupPluginDependencies $package
    Assert-Equal $false $missingNode.CanInstall 'missing Node blocks only optional plugin'
    Assert-True (@($missingNode.Missing | Where-Object { $_ -like 'Node.js 18 *' }).Count -eq 1) 'missing dependency is named'
    [IO.File]::WriteAllText((Join-Path $discoveryFixture 'node.exe'), 'never executed')
    & $module { function script:Get-CodexGuardSetupNodeVersion { return [pscustomobject]@{supported=$false;version='v14.21.3'} } }
    $oldNode = Get-CodexGuardSetupPluginDependencies $package
    Assert-Equal $false $oldNode.CanInstall 'old Node does not count as usable dependency'
    Assert-Equal 'v14.21.3' $oldNode.NodeVersion 'old Node version remains available for diagnostics'
    [IO.File]::Delete((Join-Path $discoveryFixture 'git.exe'))
    $missingGit = Get-CodexGuardSetupPluginDependencies $package
    Assert-Equal $false $missingGit.CanInstall 'missing Git blocks optional remote plugin install'
    Assert-True ($missingGit.Missing -contains 'Git') 'Git dependency is named'
    Import-Module $modulePath -Force

    function New-Fixture([string]$Name, [bool]$Registered = $false, [bool]$Installed = $false) {
        $directory = Join-Path $fixtureRoot $Name
        $state = [pscustomobject]@{
            Home=(Join-Path $directory 'home'); Snapshot=(Join-Path $directory 'snapshot'); Registered=$Registered
            Source='https://github.com/xury222/codex-shutdown-guard.git'; SourceType='git'; Ref='v1.1.0'
            Installed=$Installed; Version='1.1.0'; Enabled=$true; PluginCount=1
            Fail=''; Failed=$false; WrongVersion=$false; BadJson=$false; OmitSource=$false; Calls=(New-Object 'System.Collections.Generic.List[string]')
        }
        Write-Json (Join-Path $state.Snapshot '.agents\plugins\marketplace.json') @{ name='codex-shutdown-guard-local'; plugins=@(@{name='codex-shutdown-guard'}) }
        [void][IO.Directory]::CreateDirectory($state.Home)
        $registration = if ($Registered) { "[marketplaces.codex-shutdown-guard-local]`nsource_type = `"git`"`nsource = `"$($state.Source)`"`nref = `"$($state.Ref)`"`n`n" } else { '' }
        [IO.File]::WriteAllText((Join-Path $state.Home 'config.toml'), $registration + "[marketplaces.unrelated]`nsource_type = `"local`"`nsource = `"C:/keep-this-source`"`n`n[plugins.`"unrelated@unrelated`"]`nenabled = true`n", (New-Object Text.UTF8Encoding($false)))
        $dependencies = [pscustomobject]@{ CanInstall=$true; CodexPath='C:\fake executable\codex.exe'; NodePath='C:\fake executable\node.exe'; SearchPath='C:\fake executable'; CodexHome=$state.Home; message='ready' }
        return [pscustomobject]@{ State=$state; Dependencies=$dependencies }
    }
    function New-Invoker($State) {
        return {
            param($Executable, [string[]]$Arguments, $SearchPath)
            $State.Calls.Add(($Arguments -join ' '))
            $stdout = $null; $errorText = ''
            $isMarketplace = $Arguments.Count -gt 2 -and $Arguments[1] -ceq 'marketplace'
            $operation = if ($isMarketplace) { $Arguments[2] } else { $Arguments[1] }
            $targetVersion = '1.2.3'
            if ($State.BadJson) { return [pscustomobject]@{ exitCode=0; stdout='{broken'; stderr='' } }
            if ($State.Fail -ceq 'list') { return [pscustomobject]@{ exitCode=3; stdout=''; stderr='fixture list failure' } }
            if ($isMarketplace -and $operation -ceq 'list') {
                $items = @(@{ name='unrelated'; root='C:\do-not-change'; marketplaceSource=@{sourceType='local';source='C:\do-not-change'} })
                if ($State.Registered) {
                    $own = @{name='codex-shutdown-guard-local';root=$State.Snapshot}
                    if (-not $State.OmitSource) { $own.marketplaceSource=@{sourceType=$State.SourceType;source=$State.Source} }
                    $items += $own
                }
                $stdout = @{marketplaces=@($items)}
            }
            elseif (-not $isMarketplace -and $operation -ceq 'list') {
                $items = @()
                if ($State.Installed) { $items += @{pluginId='codex-shutdown-guard@codex-shutdown-guard-local';name='codex-shutdown-guard';marketplaceName='codex-shutdown-guard-local';version=$State.Version;enabled=$State.Enabled;installed=$true} }
                $stdout = @{installed=@($items); available=@()}
            }
            elseif ($isMarketplace -and $operation -ceq 'remove') {
                if ($Arguments[3] -cne 'codex-shutdown-guard-local') { throw 'Attempt to remove an unrelated marketplace.' }
                $State.Registered=$false; $stdout=@{removed=$true}
            }
            elseif ($isMarketplace -and $operation -ceq 'add') {
                $refIndex = [array]::IndexOf($Arguments, '--ref')
                $nextRef = if ($refIndex -ge 0) { $Arguments[$refIndex+1] } else { '' }
                if (($State.Fail -ceq 'new-add' -and $nextRef -ceq ('v'+$targetVersion)) -or ($State.Fail -ceq 'restore-add' -and $nextRef -ceq 'v1.1.0')) { $errorText='fixture add failure' }
                else { $State.Source=$Arguments[3]; $State.SourceType='git'; $State.Ref=$nextRef; $State.Registered=$true; $stdout=@{marketplaceName='codex-shutdown-guard-local';alreadyAdded=$false} }
            }
            elseif (-not $isMarketplace -and $operation -ceq 'add') {
                if ($State.Fail -ceq 'timeout') { return [pscustomobject]@{exitCode=-1;stdout='';stderr='fixture timeout';timedOut=$true} }
                if ($State.Fail -in @('plugin-add','restore-add') -and $State.Ref -ceq ('v'+$targetVersion)) { $errorText='fixture plugin failure' }
                else { $State.Installed=$true; $State.Enabled=$true; $State.Version=$State.Ref.TrimStart('v'); if ($State.WrongVersion) { $State.Version='0.0.1' }; $stdout=@{version=$State.Version} }
            }
            elseif (-not $isMarketplace -and $operation -ceq 'remove') {
                if ($Arguments[2] -cne 'codex-shutdown-guard@codex-shutdown-guard-local') { throw 'Attempt to remove an unrelated plugin.' }
                $State.Installed=$false; $stdout=@{removed=$true}
            }
            else { throw ('Unexpected CLI command: '+($Arguments -join ' ')) }
            if ($errorText) { return [pscustomobject]@{ exitCode=2; stdout=''; stderr=$errorText } }
            $registration = if ($State.Registered) { "[marketplaces.codex-shutdown-guard-local]`nsource_type = `"git`"`nsource = `"$($State.Source)`"`nref = `"$($State.Ref)`"`n`n" } else { '' }
            if ($operation -cne 'list') { [IO.File]::WriteAllText((Join-Path $State.Home 'config.toml'), $registration + "[marketplaces.unrelated]`nsource_type = `"local`"`nsource = `"C:/keep-this-source`"`n`n[plugins.`"unrelated@unrelated`"]`nenabled = true`n", (New-Object Text.UTF8Encoding($false))) }
            return [pscustomobject]@{exitCode=0;stdout=($stdout|ConvertTo-Json -Depth 8);stderr=''}
        }.GetNewClosure()
    }
    function Run-Fixture($Fixture) { return Install-CodexGuardChatPlugin -PackageRoot $package -Dependencies $Fixture.Dependencies -CliInvoker (New-Invoker $Fixture.State) }
    function Assert-UnrelatedPreserved($Fixture) {
        $text = [IO.File]::ReadAllText((Join-Path $Fixture.State.Home 'config.toml'))
        Assert-True ($text.Contains('[marketplaces.unrelated]') -and $text.Contains('C:/keep-this-source') -and $text.Contains('[plugins."unrelated@unrelated"]')) 'unrelated configuration remains'
        Assert-Equal 0 @($Fixture.State.Calls | Where-Object { $_ -match '^plugin marketplace upgrade(?: --json)?$|^plugin remove unrelated|^plugin marketplace remove unrelated' }).Count 'no broad or unrelated mutation command'
    }
    $fresh = New-Fixture 'fresh'
    $result = Run-Fixture $fresh
    Assert-True $result.ok 'fresh install succeeds'
    Assert-Equal 'installed' $result.code 'fresh result has specific success code'
    Assert-Equal $version $fresh.State.Version 'installed version matches package'
    Assert-True ($fresh.State.Calls -contains 'plugin marketplace add https://github.com/xury222/codex-shutdown-guard.git --ref v1.2.3 --json') 'GitHub source is pinned to package version'
    Assert-Equal $false $result.rollbackAttempted 'fresh success does not claim rollback'
    Assert-UnrelatedPreserved $fresh

    $upgrade = New-Fixture 'upgrade' $true $true
    $result = Run-Fixture $upgrade
    Assert-True $result.ok 'owned enabled plugin upgrades'
    Assert-Equal $version $upgrade.State.Version 'old installed plugin receives current version'
    Assert-True ($upgrade.State.Calls -contains 'plugin marketplace remove codex-shutdown-guard-local --json') 'only owned marketplace is replaced for changed pin'
    Assert-UnrelatedPreserved $upgrade
    $legacyList = New-Fixture 'legacy-list' $true $true; $legacyList.State.OmitSource=$true
    $result = Run-Fixture $legacyList
    Assert-True $result.ok 'CLI without marketplaceSource uses verified persisted registration'
    Assert-Equal $version $legacyList.State.Version 'older CLI listing shape can upgrade the own plugin'
    Assert-UnrelatedPreserved $legacyList

    $already = New-Fixture 'already' $true $true; $already.State.Version=$version; $already.State.Ref='v'+$version
    [IO.File]::WriteAllText((Join-Path $already.State.Home 'config.toml'), "[marketplaces.codex-shutdown-guard-local]`nsource_type = `"git`"`nsource = `"$($already.State.Source)`"`nref = `"v$version`"`n", (New-Object Text.UTF8Encoding($false)))
    $result = Run-Fixture $already
    Assert-True $result.ok 'current enabled installation is accepted'
    Assert-Equal 'already-installed' $result.code 'current version result is explicit'
    Assert-Equal $false $result.changed 'current pin and version cause no mutation'
    Assert-Equal 2 $already.State.Calls.Count 'already installed uses only read-only listing'

    $disabled = New-Fixture 'disabled' $true $true; $disabled.State.Enabled=$false
    $result = Run-Fixture $disabled
    Assert-Equal $false $result.ok 'disabled plugin is not silently enabled'
    Assert-Equal 'existing-plugin-disabled' $result.code 'disabled plugin gives actionable code'
    Assert-Equal $false $result.changed 'disabled preference is retained without mutation'
    Assert-Equal $false $disabled.State.Enabled 'disabled state remains false'

    foreach ($kind in @('foreign','local','extra-plugin','unreadable-registration','unsafe-ref')) {
        $conflict = New-Fixture $kind $true $true
        if ($kind -ceq 'foreign') { $conflict.State.Source='https://github.com/another-owner/other-repository.git' }
        if ($kind -ceq 'local') { $conflict.State.SourceType='local'; $conflict.State.Source='C:\unverified-local-source' }
        if ($kind -ceq 'extra-plugin') { Write-Json (Join-Path $conflict.State.Snapshot '.agents\plugins\marketplace.json') @{ name='codex-shutdown-guard-local'; plugins=@(@{name='codex-shutdown-guard'},@{name='keep-another-plugin'}) } }
        if ($kind -ceq 'unreadable-registration') { [IO.File]::WriteAllText((Join-Path $conflict.State.Home 'config.toml'), '# No unambiguous CLI-produced own registration.') }
        if ($kind -ceq 'unsafe-ref') { [IO.File]::WriteAllText((Join-Path $conflict.State.Home 'config.toml'), "[marketplaces.codex-shutdown-guard-local]`nsource_type = `"git`"`nsource = `"$($conflict.State.Source)`"`nref = 'v1.1.0 & echo unexpected'`n", (New-Object Text.UTF8Encoding($false))) }
        $result = Run-Fixture $conflict
        Assert-Equal $false $result.ok ('conflicting source refuses: '+$kind)
        Assert-Equal $false $result.changed ('conflicting source has no mutation: '+$kind)
        Assert-Equal 2 $conflict.State.Calls.Count ('conflict only lists: '+$kind)
    }

    foreach ($failure in @('new-add','plugin-add','restore-add')) {
        $rollback = New-Fixture ('rollback-'+$failure) $true $true; $rollback.State.Fail=$failure
        $result = Run-Fixture $rollback
        Assert-Equal $false $result.ok ('failed upgrade never succeeds: '+$failure)
        Assert-True $result.rollbackAttempted ('failed upgrade attempts recovery: '+$failure)
        Assert-Equal ($failure -cne 'restore-add') $result.rollbackSucceeded ('recovery status is truthful: '+$failure)
        if ($failure -cne 'restore-add') {
            Assert-Equal 'v1.1.0' $rollback.State.Ref 'old pinned ref is restored'
            Assert-Equal '1.1.0' $rollback.State.Version 'old plugin version is restored'
            Assert-True $rollback.State.Enabled 'old enabled state is restored'
        }
        Assert-UnrelatedPreserved $rollback
    }
    $freshFailure = New-Fixture 'fresh-failure'; $freshFailure.State.Fail='plugin-add'
    $result = Run-Fixture $freshFailure
    Assert-Equal $false $result.ok 'failed fresh plugin install never succeeds'
    Assert-Equal $true $result.rollbackSucceeded 'failed fresh install rolls back its registration'
    Assert-Equal $false $freshFailure.State.Registered 'newly created marketplace is removed after failure'
    Assert-Equal $false $freshFailure.State.Installed 'fresh failure leaves no installed plugin'
    Assert-UnrelatedPreserved $freshFailure

    $wrong = New-Fixture 'wrong-version'; $wrong.State.WrongVersion=$true
    $result = Run-Fixture $wrong
    Assert-Equal $false $result.ok 'successful CLI exit is insufficient without correct installed version'
    Assert-True $result.rollbackSucceeded 'wrong version rolls back fresh installation'
    Assert-Equal $false $wrong.State.Installed 'wrong-version cache is removed through targeted CLI'
    Assert-UnrelatedPreserved $wrong
    $pending = New-Fixture 'timeout' $true $true; $pending.State.Fail='timeout'
    $result = Run-Fixture $pending
    Assert-Equal $false $result.ok 'timed out command never reports success'
    Assert-Equal 'operation-pending' $result.code 'timeout is explicit uncertain status'
    Assert-Equal $false $result.rollbackAttempted 'timeout does not race a pending descendant with rollback'
    Assert-Equal 'plugin add codex-shutdown-guard@codex-shutdown-guard-local --json' $pending.State.Calls[$pending.State.Calls.Count-1] 'timeout is followed by no further CLI mutation or query'
    Assert-UnrelatedPreserved $pending

    foreach ($failure in @('list','json')) {
        $readFailure = New-Fixture ('read-'+$failure)
        if ($failure -ceq 'json') { $readFailure.State.BadJson=$true } else { $readFailure.State.Fail='list' }
        $result = Run-Fixture $readFailure
        Assert-Equal $false $result.ok ('read failure never succeeds: '+$failure)
        Assert-Equal $false $result.changed ('read failure makes no mutation: '+$failure)
    }
    $absent = New-Fixture 'absent'; $absent.Dependencies.CanInstall=$false; $absent.Dependencies.message='Node.js missing'
    $result = Run-Fixture $absent
    Assert-Equal 'missing-dependencies' $result.code 'missing dependencies are reported'
    Assert-Equal 0 $absent.State.Calls.Count 'missing dependencies execute no CLI'

    # Execute only a fixture PowerShell file, never a real Codex install/control command.
    $programDirectory = Join-Path $fixtureRoot "program's folder"
    [void][IO.Directory]::CreateDirectory($programDirectory)
    $program = Join-Path $programDirectory 'fake-cli.ps1'
    [IO.File]::WriteAllText($program, '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); [pscustomobject]@{ arguments=@($args); childPath=$env:PATH } | ConvertTo-Json -Compress; exit 0', (New-Object Text.UTF8Encoding($false)))
    $boundary = Invoke-CodexGuardSetupCli -Executable $program -Arguments @('plugin','marketplace','list','--json',"fixture's literal") -SearchPath $originalPath -TimeoutSeconds 10
    Assert-Equal 0 $boundary.exitCode 'CLI process boundary runs quoted fixture path'
    $boundaryJson = $boundary.stdout | ConvertFrom-Json
    Assert-Equal "fixture's literal" $boundaryJson.arguments[4] 'argument quotes cannot become script syntax'
    Assert-Equal $originalPath $env:PATH 'CLI child launch leaves parent PATH unchanged'
    Assert-Equal $originalPath $boundaryJson.childPath 'CLI child receives requested search path'
    $cmdDirectory = Join-Path $fixtureRoot "npm's folder & !"
    [void][IO.Directory]::CreateDirectory($cmdDirectory)
    $cmd = Join-Path $cmdDirectory 'codex.cmd'
    [IO.File]::WriteAllText($cmd, "@echo off`r`necho {`"ok`":true}`r`nexit /b 0`r`n", (New-Object Text.UTF8Encoding($false)))
    $cmdBoundary = Invoke-CodexGuardSetupCli -Executable $cmd -Arguments @('plugin','list','--json') -SearchPath $originalPath -TimeoutSeconds 10
    Assert-Equal 0 $cmdBoundary.exitCode 'npm cmd path with quote ampersand exclamation is supported'
    Assert-True (($cmdBoundary.stdout | ConvertFrom-Json).ok) 'cmd fixture produces its intended JSON'
    Write-Output ('PASS: '+$script:Passed+' optional plugin setup checks; all installation commands were mocked.')
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $parent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup target escaped the tests directory.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
