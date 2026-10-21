Set-StrictMode -Version 2.0

if (-not ('CodexGuardJsonReader' -as [type])) {
    $guardJsonTypeDefinition = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Xml;

public static class CodexGuardJsonReader {
    public sealed class FileBatch {
        public readonly List<object> Events = new List<object>();
        public long Position, Length;
        public bool Incomplete, Malformed;
    }
    private sealed class RecordStream : Stream {
        private readonly Stream source;
        public bool EndedByNewline;
        public RecordStream(Stream source) { this.source = source; }
        public override int Read(byte[] buffer, int offset, int count) {
            if (EndedByNewline) return 0;
            int read = source.Read(buffer, offset, Math.Min(count, 8192));
            for (int i = 0; i < read; i++) if (buffer[offset + i] == 10) {
                int used = i + 1;
                source.Seek(used - read, SeekOrigin.Current);
                EndedByNewline = true;
                return used;
            }
            return read;
        }
        public void Drain() { var buffer = new byte[8192]; while (Read(buffer, 0, buffer.Length) > 0) {} }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override void Flush() {}
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    }
    public static FileBatch ReadFile(string path, long position, int milliseconds) {
        var batch = new FileBatch();
        var watch = System.Diagnostics.Stopwatch.StartNew();
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            if (position > file.Length) position = 0;
            file.Position = position;
            while (file.Position < file.Length && watch.ElapsedMilliseconds < Math.Max(1, milliseconds)) {
                long start = file.Position;
                var record = new RecordStream(file);
                object metadata = null;
                bool malformed = false;
                try {
                    using (var reader = JsonReaderWriterFactory.CreateJsonReader(record, XmlDictionaryReaderQuotas.Max)) {
                        if (reader.MoveToContent() != XmlNodeType.None) metadata = ReadObject(reader, "root");
                        if (reader.MoveToContent() != XmlNodeType.None) malformed = true;
                    }
                }
                catch { malformed = true; }
                record.Drain();
                if (!record.EndedByNewline) { batch.Incomplete = true; file.Position = start; break; }
                if (malformed) batch.Malformed = true;
                // Include an empty metadata record for malformed/empty lines
                // so inherited-history boundaries retain their record ordinal.
                batch.Events.Add(metadata ?? new Dictionary<string, object>());
            }
            batch.Position = file.Position;
            batch.Length = file.Length;
        }
        return batch;
    }
    // The framework JSON reader validates JSON syntax while skipped values are
    // never converted into PowerShell objects or retained in task state.
    public static object Parse(string json) { return Read(json, "root"); }
    public static object ParseTitle(string json) { return Read(json, "title"); }
    private static object Read(string json, string schema) {
        using (var stream = new MemoryStream(Encoding.UTF8.GetBytes(json)))
        using (var reader = JsonReaderWriterFactory.CreateJsonReader(stream, XmlDictionaryReaderQuotas.Max)) {
            reader.MoveToContent();
            var result = ReadObject(reader, schema);
            if (reader.MoveToContent() != XmlNodeType.None) throw new FormatException("Trailing JSON data.");
            return result;
        }
    }
    private static Dictionary<string, object> ReadObject(XmlDictionaryReader reader, string schema) {
        if (reader.GetAttribute("type") != "object") throw new FormatException("Expected JSON object.");
        var result = new Dictionary<string, object>(StringComparer.Ordinal);
        bool empty = reader.IsEmptyElement;
        reader.ReadStartElement();
        if (empty) return result;
        while (reader.MoveToContent() != XmlNodeType.EndElement) {
            if (reader.NodeType != XmlNodeType.Element) throw new FormatException("Incomplete JSON object.");
            string name = reader.LocalName;
            int rule = Rule(schema, name);
            if (rule == 1) result[name] = ReadScalar(reader);
            else if (rule == 2) {
                if (reader.GetAttribute("type") == "null") { reader.Skip(); result[name] = null; }
                else result[name] = ReadObject(reader, schema + "/" + name);
            }
            else if (rule == 3) { bool present = reader.GetAttribute("type") != "null"; reader.Skip(); result[name] = present ? (object)true : null; }
            else if (rule == 4) {
                // Session source and its subagent discriminator are tagged
                // unions. Retain only their scalar or whitelisted metadata.
                if (reader.GetAttribute("type") == "object") result[name] = ReadObject(reader, schema + "/" + name);
                else if (reader.GetAttribute("type") == "array") { reader.Skip(); result[name] = null; }
                else result[name] = ReadScalar(reader);
            }
            else reader.Skip();
        }
        reader.ReadEndElement();
        return result;
    }
    private static object ReadScalar(XmlDictionaryReader reader) {
        string type = reader.GetAttribute("type");
        if (type == "null") { reader.Skip(); return null; }
        if (type == "object" || type == "array") throw new FormatException("Expected scalar metadata.");
        string text = reader.ReadElementContentAsString();
        if (type == "number") {
            long integer;
            if (Int64.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out integer)) return integer;
            return Double.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture);
        }
        if (type == "boolean") return Boolean.Parse(text);
        return text;
    }
    private static int Rule(string schema, string name) {
        switch (schema) {
            case "root":
                if (name == "timestamp" || name == "type") return 1;
                if (name == "payload") return 2;
                break;
            case "title":
                if (name == "id" || name == "thread_name") return 1;
                break;
            case "root/payload":
                if (name == "type" || name == "turn_id" || name == "cwd" || name == "id" ||
                    name == "parent_thread_id" || name == "agent_nickname" || name == "agent_role" ||
                    name == "agent_path" || name == "thread_source" || name == "subagent_history_start_ordinal") return 1;
                if (name == "rate_limits" || name == "info") return 2;
                if (name == "source") return 4;
                if (name == "error") return 3;
                break;
            case "root/payload/source":
                if (name == "subagent") return 4;
                break;
            case "root/payload/source/subagent":
                if (name == "other") return 1;
                if (name == "thread_spawn" || name == "spawn") return 4;
                break;
            case "root/payload/source/subagent/thread_spawn":
            case "root/payload/source/subagent/spawn":
                if (name == "parent_thread_id" || name == "agent_nickname" || name == "agent_role" ||
                    name == "agent_path" || name == "depth") return 1;
                break;
            case "root/payload/rate_limits":
                if (name == "limit_id" || name == "limit_name" || name == "plan_type") return 1;
                if (name == "primary" || name == "secondary") return 2;
                break;
            case "root/payload/rate_limits/primary":
            case "root/payload/rate_limits/secondary":
                if (name == "used_percent" || name == "window_minutes" || name == "resets_at") return 1;
                break;
            case "root/payload/info":
                if (name == "model_context_window") return 1;
                if (name == "last_token_usage" || name == "total_token_usage") return 2;
                break;
            case "root/payload/info/last_token_usage":
            case "root/payload/info/total_token_usage":
                if (name == "input_tokens" || name == "total_tokens") return 1;
                break;
        }
        return 0;
    }
}
'@
    if ($PSVersionTable.PSVersion.Major -le 5) {
        Add-Type -ReferencedAssemblies System.Runtime.Serialization,System.Xml -TypeDefinition $guardJsonTypeDefinition
    }
    else { Add-Type -TypeDefinition $guardJsonTypeDefinition }
}


$script:ThreadIdFromFilePattern = [regex]::new(
    '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

function ConvertTo-GuardUtc {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    $parsed = [datetimeoffset]::MinValue
    $ok = [datetimeoffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )
    if (-not $ok) {
        return $null
    }
    return $parsed.UtcDateTime
}

function Get-GuardThreadIdFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $match = $script:ThreadIdFromFilePattern.Match($Path)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ''
}

function Get-CodexGuardJsonProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function ConvertFrom-CodexGuardThreadTitleLine {
    param([string]$Line)
    try { $entry = [CodexGuardJsonReader]::ParseTitle($Line) }
    catch { return $null }
    $id = [string](Get-CodexGuardJsonProperty -Object $entry -Name 'id')
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($id, [ref]$guid)) { return $null }
    $title = ([string](Get-CodexGuardJsonProperty -Object $entry -Name 'thread_name') -replace '[\r\n]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { return $null }
    if ($title.Length -gt 120) { $title = $title.Substring(0, 117) + '...' }
    return [pscustomobject]@{ ThreadId = $id; Title = $title }
}

function ConvertTo-CodexGuardMetadataText {
    param([object]$Value, [int]$MaxLength = 160)
    $text = ([string]$Value -replace '[\x00-\x1f\x7f]+', ' ').Trim()
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) }
    return $text
}

function Get-CodexGuardTaskTypeLabel {
    param([object]$Entry)
    switch ([string](Get-CodexGuardJsonProperty $Entry 'TaskType')) {
        'MainTask' { return '主任务' }
        'Subagent' { return '子代理' }
        'InternalReview' { return '内部审批' }
        default { return '来源未识别' }
    }
}

function Get-CodexGuardTaskDisplayTitle {
    param([object]$Entry, [hashtable]$ThreadTitles = @{})
    $threadId = [string](Get-CodexGuardJsonProperty $Entry 'ThreadId')
    $parentId = [string](Get-CodexGuardJsonProperty $Entry 'ParentThreadId')
    $taskType = [string](Get-CodexGuardJsonProperty $Entry 'TaskType')
    $title = if ($ThreadTitles.ContainsKey($threadId)) { ConvertTo-CodexGuardMetadataText $ThreadTitles[$threadId] 240 } else { '' }
    $parentTitle = if ($ThreadTitles.ContainsKey($parentId)) { ConvertTo-CodexGuardMetadataText $ThreadTitles[$parentId] 240 } else { '' }
    $agentName = ConvertTo-CodexGuardMetadataText (Get-CodexGuardJsonProperty $Entry 'AgentName')
    $agentRole = ConvertTo-CodexGuardMetadataText (Get-CodexGuardJsonProperty $Entry 'AgentRole')
    $agentPath = ConvertTo-CodexGuardMetadataText (Get-CodexGuardJsonProperty $Entry 'AgentPath')
    $pathName = if ($agentPath) { @($agentPath.TrimEnd([char[]]@('/','\')) -split '[\\/]')[-1] } else { '' }
    $agentLabel = if ($pathName -and $agentName -and $pathName -ne $agentName) { "$pathName（$agentName）" }
        elseif ($pathName) { $pathName } elseif ($agentName) { $agentName } elseif ($agentRole) { $agentRole } else { '' }
    $shortId = if ($threadId.Length -gt 8) { $threadId.Substring(0, 8) } else { $threadId }
    if ($taskType -in @('Subagent', 'InternalReview')) {
        $typeLabel = Get-CodexGuardTaskTypeLabel $Entry
        if ($title) { return "$typeLabel · $title" }
        $detail = if ($agentLabel) { "$typeLabel $agentLabel" } elseif ($shortId) { "$typeLabel $shortId" } else { $typeLabel }
        if ($parentTitle) { return "$detail · $parentTitle" }
        return $detail
    }
    if ($title) { return $title }
    if ($shortId) { return "未命名任务 $shortId" }
    return '无法识别的任务状态'
}

function Get-CodexGuardTaskTooltip {
    param([object]$Entry, [hashtable]$ThreadTitles = @{})
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((Get-CodexGuardTaskDisplayTitle $Entry $ThreadTitles))
    $parts.Add(('类型：' + (Get-CodexGuardTaskTypeLabel $Entry)))
    $parts.Add(('线程：' + [string](Get-CodexGuardJsonProperty $Entry 'ThreadId')))
    $parentId = [string](Get-CodexGuardJsonProperty $Entry 'ParentThreadId')
    if ($parentId) {
        $parentTitle = if ($ThreadTitles.ContainsKey($parentId)) { ConvertTo-CodexGuardMetadataText $ThreadTitles[$parentId] 240 } else { '' }
        $parts.Add("父任务：$parentTitle [$parentId]")
    }
    foreach ($field in @(@('AgentName','代理名称'), @('AgentRole','代理职责'), @('AgentPath','代理路径'), @('ThreadSource','记录来源'))) {
        $value = ConvertTo-CodexGuardMetadataText (Get-CodexGuardJsonProperty $Entry $field[0])
        if ($value) { $parts.Add("$($field[1])：$value") }
    }
    $reason = [string](Get-CodexGuardJsonProperty $Entry 'Reason')
    if ($reason) { $parts.Add($reason) }
    return $parts -join "`r`n"
}

function Get-CodexGuardTaskStateLabel {
    param([object]$Entry)
    $label = if ($Entry.Kind -eq 'StaleTurn') { '疑似失联' }
        elseif ($Entry.Kind -eq 'IncompleteActiveTurn') { '等待完整事件' }
        elseif ($Entry.Kind -eq 'PendingReadActiveTurn') { '读取记录中' }
        elseif ($Entry.State -eq 'Unknown') { '异常' }
        else { '活动' }
    return "$label · $(if ($Entry.IsIgnored) { '已无视' } else { '阻塞' })"
}

function Get-CodexGuardTaskManagerRows {
    param([object]$Snapshot, [hashtable]$ThreadTitles = @{}, [hashtable]$PendingChecks = @{})
    $rows = New-Object System.Collections.Generic.List[object]
    $current = @{}
    foreach ($entry in @($Snapshot.TaskEntries | Sort-Object State, StartedAtUtc, TurnId)) {
        $id = [string]$entry.TurnId
        $current[$id] = $true
        $title = Get-CodexGuardTaskDisplayTitle -Entry $entry -ThreadTitles $ThreadTitles
        $cwd = if ([string]::IsNullOrWhiteSpace([string]$entry.Cwd)) { Split-Path -Leaf ([string]$entry.Path) } else { [string]$entry.Cwd }
        $updated = if ($null -ne $entry.LastUpdatedAtUtc) { ([datetime]$entry.LastUpdatedAtUtc).ToLocalTime().ToString('MM-dd HH:mm:ss') } else { '未知' }
        $rows.Add([pscustomobject]@{
            TurnId=$id; Title=$title; StateText=(Get-CodexGuardTaskStateLabel -Entry $entry)
            ThreadId=[string]$entry.ThreadId; ParentThreadId=[string](Get-CodexGuardJsonProperty $entry 'ParentThreadId')
            TaskType=[string](Get-CodexGuardJsonProperty $entry 'TaskType'); TaskTypeLabel=(Get-CodexGuardTaskTypeLabel $entry)
            AgentName=[string](Get-CodexGuardJsonProperty $entry 'AgentName'); AgentRole=[string](Get-CodexGuardJsonProperty $entry 'AgentRole')
            AgentPath=[string](Get-CodexGuardJsonProperty $entry 'AgentPath'); ThreadSource=[string](Get-CodexGuardJsonProperty $entry 'ThreadSource')
            Cwd=$cwd; Updated=$updated; Checked=if ($PendingChecks.ContainsKey($id)) { [bool]$PendingChecks[$id] } else { [bool]$entry.IsIgnored }
            Tooltip=(Get-CodexGuardTaskTooltip $entry $ThreadTitles); Tone=if ($entry.State -eq 'Unknown') { 'Warning' } else { 'Normal' }
        })
    }
    foreach ($id in @($PendingChecks.Keys)) { if (-not $current.ContainsKey($id)) { [void]$PendingChecks.Remove($id) } }
    foreach ($unknown in @($Snapshot.AllUnknownItems | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.TurnId) })) {
        $isPending = $unknown.Kind -eq 'PendingRead'
        $rows.Add([pscustomobject]@{
            TurnId=''; Title=if ($isPending) { '正在读取任务记录' } else { '无法归属到具体任务的异常' }
            StateText=if ($isPending) { '读取中 · 阻塞' } else { '系统异常 · 不可无视' }
            Cwd=''; Updated='未知'; Checked=$false; Tooltip=[string]$unknown.Reason; Tone='Error'
        })
    }
    if ($rows.Count -eq 0) {
        $rows.Add([pscustomobject]@{ TurnId=''; Title='当前没有活动或异常任务'; StateText='空闲'; Cwd=''; Updated=''; Checked=$false; Tooltip=''; Tone='Muted' })
    }
    return $rows.ToArray()
}

function ConvertTo-CodexGuardRateWindow {
    param(
        [object]$Window
    )

    if ($null -eq $Window) {
        return $null
    }

    $usedPercent = Get-CodexGuardJsonProperty -Object $Window -Name 'used_percent'
    $windowMinutes = Get-CodexGuardJsonProperty -Object $Window -Name 'window_minutes'
    $resetsAt = Get-CodexGuardJsonProperty -Object $Window -Name 'resets_at'
    if ($null -eq $usedPercent -or $null -eq $windowMinutes) {
        return $null
    }

    $resetUtc = $null
    if ($null -ne $resetsAt) {
        try {
            $resetUtc = [datetimeoffset]::FromUnixTimeSeconds([long]$resetsAt).UtcDateTime
        }
        catch {
            $resetUtc = $null
        }
    }

    return [pscustomobject]@{
        UsedPercent = [double]$usedPercent
        WindowMinutes = [int]$windowMinutes
        ResetsAtUnix = if ($null -ne $resetsAt) { [long]$resetsAt } else { $null }
        ResetsAtUtc = $resetUtc
    }
}

function ConvertTo-CodexGuardUsageSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Event,

        [Parameter(Mandatory = $true)]
        [datetime]$EventUtc,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $payload = Get-CodexGuardJsonProperty -Object $Event -Name 'payload'
    $info = Get-CodexGuardJsonProperty -Object $payload -Name 'info'
    $rateLimits = Get-CodexGuardJsonProperty -Object $payload -Name 'rate_limits'
    if ($null -eq $info -and $null -eq $rateLimits) {
        return $null
    }

    $lastTokenUsage = Get-CodexGuardJsonProperty -Object $info -Name 'last_token_usage'
    $totalTokenUsage = Get-CodexGuardJsonProperty -Object $info -Name 'total_token_usage'
    $modelContextWindow = Get-CodexGuardJsonProperty -Object $info -Name 'model_context_window'
    $lastInputTokens = Get-CodexGuardJsonProperty -Object $lastTokenUsage -Name 'input_tokens'
    $lastTotalTokens = Get-CodexGuardJsonProperty -Object $lastTokenUsage -Name 'total_tokens'
    $cumulativeTokens = Get-CodexGuardJsonProperty -Object $totalTokenUsage -Name 'total_tokens'

    $primary = ConvertTo-CodexGuardRateWindow -Window (
        Get-CodexGuardJsonProperty -Object $rateLimits -Name 'primary'
    )
    $secondary = ConvertTo-CodexGuardRateWindow -Window (
        Get-CodexGuardJsonProperty -Object $rateLimits -Name 'secondary'
    )

    return [pscustomobject]@{
        UpdatedAtUtc = $EventUtc.ToUniversalTime()
        ThreadId = Get-GuardThreadIdFromPath -Path $FilePath
        LimitId = [string](Get-CodexGuardJsonProperty -Object $rateLimits -Name 'limit_id')
        LimitName = [string](Get-CodexGuardJsonProperty -Object $rateLimits -Name 'limit_name')
        PlanType = [string](Get-CodexGuardJsonProperty -Object $rateLimits -Name 'plan_type')
        Primary = $primary
        Secondary = $secondary
        ModelContextWindow = if ($null -ne $modelContextWindow) { [long]$modelContextWindow } else { $null }
        LastInputTokens = if ($null -ne $lastInputTokens) { [long]$lastInputTokens } else { $null }
        LastTotalTokens = if ($null -ne $lastTotalTokens) { [long]$lastTotalTokens } else { $null }
        CumulativeTokens = if ($null -ne $cumulativeTokens) { [long]$cumulativeTokens } else { $null }
    }
}

function Get-CodexGuardUsageValidity {
    param(
        [object]$Usage,

        [datetime]$NowUtc = [datetime]::UtcNow,

        [int]$FallbackMaxAgeSeconds = 180
    )

    if ($null -eq $Usage) {
        return [pscustomobject]@{
            Available = $false
            Valid = $false
            Stale = $false
            Expired = $false
            AgeSeconds = $null
            PrimaryValid = $false
            SecondaryValid = $false
            PrimaryState = 'Missing'
            SecondaryState = 'Missing'
            Reason = 'Unavailable'
        }
    }

    $now = $NowUtc.ToUniversalTime()
    $fallbackSeconds = [Math]::Max(60, $FallbackMaxAgeSeconds)
    $ageSeconds = $null
    $updatedAtValue = Get-CodexGuardJsonProperty -Object $Usage -Name 'UpdatedAtUtc'
    if ($null -ne $updatedAtValue) {
        try {
            $updatedAtUtc = ([datetime]$updatedAtValue).ToUniversalTime()
            $ageSeconds = [int][Math]::Max(0, [Math]::Floor(($now - $updatedAtUtc).TotalSeconds))
        }
        catch {
            $ageSeconds = $null
        }
    }

    $states = [ordered]@{}
    $validCount = 0
    $windowCount = 0
    $expiredCount = 0
    foreach ($name in @('Primary', 'Secondary')) {
        $window = Get-CodexGuardJsonProperty -Object $Usage -Name $name
        if ($null -eq $window) {
            $states[$name] = 'Missing'
            continue
        }

        $windowCount++
        $resetValue = Get-CodexGuardJsonProperty -Object $window -Name 'ResetsAtUtc'
        if ($null -ne $resetValue) {
            try {
                $resetUtc = ([datetime]$resetValue).ToUniversalTime()
                if ($resetUtc -gt $now) {
                    $states[$name] = 'Active'
                    $validCount++
                }
                else {
                    $states[$name] = 'Expired'
                    $expiredCount++
                }
                continue
            }
            catch {
                # Fall through to the age-based compatibility check.
            }
        }

        if ($null -ne $ageSeconds -and $ageSeconds -le $fallbackSeconds) {
            $states[$name] = 'FallbackFresh'
            $validCount++
        }
        else {
            $states[$name] = 'FallbackStale'
        }
    }

    $valid = ($validCount -gt 0)
    $expired = (-not $valid -and $expiredCount -gt 0)
    $stale = (-not $valid -and $windowCount -gt 0)
    $reason = if ($valid) {
        'QuotaWindowActive'
    }
    elseif ($expired) {
        'QuotaWindowExpired'
    }
    elseif ($windowCount -eq 0) {
        'NoQuotaWindows'
    }
    else {
        'MissingResetTimeAndFallbackExpired'
    }

    return [pscustomobject]@{
        Available = $true
        Valid = $valid
        Stale = $stale
        Expired = $expired
        AgeSeconds = $ageSeconds
        PrimaryValid = ($states.Primary -in @('Active', 'FallbackFresh'))
        SecondaryValid = ($states.Secondary -in @('Active', 'FallbackFresh'))
        PrimaryState = [string]$states.Primary
        SecondaryState = [string]$states.Secondary
        Reason = $reason
    }
}

function Get-GuardCodexHome {
    param(
        [string]$Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return [IO.Path]::GetFullPath($Override)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex'))
}

function Test-CodexGuardAppServerPath {
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    catch {
        return $false
    }

    $oldPackagedLayout = $fullPath -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\resources\\codex\.exe$'
    if ($oldPackagedLayout) {
        return $true
    }

    try {
        $localBinRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin')).TrimEnd('\') + '\'
        return (
            $fullPath.StartsWith($localBinRoot, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($fullPath).Equals('codex.exe', [StringComparison]::OrdinalIgnoreCase)
        )
    }
    catch {
        return $false
    }
}

function Get-CodexGuardPowerShellLaunchArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MainScriptPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Tray', 'Show', 'Arm', 'Disarm', 'Stop')]
        [string]$Mode
    )

    $resolvedMain = [IO.Path]::GetFullPath($MainScriptPath)
    return "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$resolvedMain`" -$Mode"
}

function Get-CodexGuardAppSession {
    $chatCandidates = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)) {
        try {
            $path = ''
            try {
                $path = [string]$process.Path
            }
            catch {
                $path = ''
            }
            if ([string]::IsNullOrWhiteSpace($path) -or $path -like '*OpenAI.Codex*') {
                $chatCandidates.Add([pscustomobject]@{
                    Id = $process.Id
                    StartTimeUtc = $process.StartTime.ToUniversalTime()
                    Path = $path
                })
            }
        }
        catch {
            # A protected helper process is not useful as the session anchor.
        }
    }

    if ($chatCandidates.Count -eq 0) {
        return [pscustomobject]@{
            Available = $false
            Reason = 'Codex desktop process is not running.'
            SessionKey = ''
            StartTimeUtc = $null
        }
    }

    $appServerFound = $false
    foreach ($process in @(Get-Process -Name 'codex' -ErrorAction SilentlyContinue)) {
        try {
            $path = [string]$process.Path
            if (Test-CodexGuardAppServerPath -Path $path) {
                $appServerFound = $true
                break
            }
        }
        catch {
            # Keep looking for another accessible Codex process.
        }
    }

    if (-not $appServerFound) {
        return [pscustomobject]@{
            Available = $false
            Reason = 'Codex desktop is open, but its local app server was not found.'
            SessionKey = ''
            StartTimeUtc = $null
        }
    }

    $anchor = $chatCandidates | Sort-Object StartTimeUtc | Select-Object -First 1
    return [pscustomobject]@{
        Available = $true
        Reason = ''
        SessionKey = ('{0:yyyyMMddHHmmssfffffff}' -f $anchor.StartTimeUtc)
        StartTimeUtc = $anchor.StartTimeUtc
    }
}

function New-CodexGuardTracker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome,

        [Parameter(Mandatory = $true)]
        [datetime]$BaselineUtc
    )

    return [pscustomobject]@{
        CodexHome = [IO.Path]::GetFullPath($CodexHome)
        SessionsRoot = [IO.Path]::GetFullPath((Join-Path $CodexHome 'sessions'))
        BaselineUtc = $BaselineUtc.ToUniversalTime()
        Files = @{}
        Turns = @{}
        UnknownTurns = @{}
        ReadErrors = @{}
        GlobalErrors = @{}
        LatestUsage = $null
        UsageError = ''
        LastDiscoveryUtc = $null
        ReadCursor = 0
    }
}

function New-CodexGuardFileState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [pscustomobject]@{
        Path = $Path
        Position = [long]0
        Partial = ''
        Decoder = [Text.Encoding]::UTF8.GetDecoder()
        LastLength = [long]0
        LastWriteUtc = [datetime]::MinValue
        LastEventAtUtc = [datetime]::MinValue
        SessionMetadataSeen = $false
        InheritedRecordsRemaining = [long]0
        ThreadId = Get-GuardThreadIdFromPath -Path $Path
        ParentThreadId = ''
        TaskType = 'Unknown'
        AgentName = ''
        AgentRole = ''
        AgentPath = ''
        ThreadSource = ''
        SessionSource = ''
        Cwd = ''
        IsGuardianSession = $false
    }
}

function Reset-CodexGuardFileIdentity {
    param([object]$FileState)
    $fresh = New-CodexGuardFileState -Path $FileState.Path
    foreach ($field in @('LastEventAtUtc','SessionMetadataSeen','InheritedRecordsRemaining','ThreadId','ParentThreadId','TaskType','AgentName','AgentRole','AgentPath','ThreadSource','SessionSource','Cwd','IsGuardianSession')) {
        $FileState.$field = $fresh.$field
    }
}

function Set-CodexGuardSessionIdentity {
    param([object]$FileState, [object]$Payload)
    # Child session files may embed their parent's session_meta and lifecycle
    # records. Only the first metadata record owns this physical file.
    if ($FileState.SessionMetadataSeen) { return }
    $FileState.SessionMetadataSeen = $true
    $id = [string](Get-CodexGuardJsonProperty $Payload 'id')
    $validId = [guid]::Empty
    if ([guid]::TryParse($id, [ref]$validId)) { $FileState.ThreadId = $id }
    $source = Get-CodexGuardJsonProperty $Payload 'source'
    $subagent = Get-CodexGuardJsonProperty $source 'subagent'
    $spawn = Get-CodexGuardJsonProperty $subagent 'thread_spawn'
    if ($null -eq $spawn) { $spawn = Get-CodexGuardJsonProperty $subagent 'spawn' }
    $other = [string](Get-CodexGuardJsonProperty $subagent 'other')
    $FileState.IsGuardianSession = $other -ceq 'guardian'
    foreach ($field in @(@('parent_thread_id','ParentThreadId'), @('agent_nickname','AgentName'), @('agent_role','AgentRole'), @('agent_path','AgentPath'))) {
        $value = Get-CodexGuardJsonProperty $Payload $field[0]
        if ([string]::IsNullOrWhiteSpace([string]$value)) { $value = Get-CodexGuardJsonProperty $spawn $field[0] }
        $FileState.($field[1]) = ConvertTo-CodexGuardMetadataText $value
    }
    $FileState.ThreadSource = ConvertTo-CodexGuardMetadataText (Get-CodexGuardJsonProperty $Payload 'thread_source')
    $FileState.Cwd = ConvertTo-CodexGuardMetadataText (Get-CodexGuardJsonProperty $Payload 'cwd') 1024
    $FileState.SessionSource = if ($source -is [string]) { ConvertTo-CodexGuardMetadataText $source } elseif ($null -ne $subagent) { 'subagent' } else { '' }
    if ($FileState.IsGuardianSession -or $FileState.ThreadSource -eq 'guardian_review' -or ($subagent -is [string] -and $subagent -eq 'review')) { $FileState.TaskType = 'InternalReview' }
    elseif ($null -ne $subagent -or $FileState.ThreadSource -eq 'subagent' -or $FileState.ParentThreadId) { $FileState.TaskType = 'Subagent' }
    elseif ($FileState.ThreadSource -eq 'user' -or $FileState.SessionSource -in @('cli','vscode','app','desktop')) { $FileState.TaskType = 'MainTask' }
    $historyStart = Get-CodexGuardJsonProperty $Payload 'subagent_history_start_ordinal'
    $historyOrdinal = [long]0
    if ($FileState.TaskType -in @('Subagent','InternalReview') -and [long]::TryParse([string]$historyStart, [ref]$historyOrdinal) -and $historyOrdinal -gt 0) {
        # The first session_meta has ordinal zero. Own records start at the
        # stated zero-based ordinal; the intervening N-1 records are inherited.
        $FileState.InheritedRecordsRemaining = $historyOrdinal - 1
    }
}

function Get-CodexGuardTurnKey {
    param([object]$Tracker, [string]$ThreadId, [string]$TurnId)
    # Keep native turn IDs and the existing ignore protocol externally. Only
    # disambiguate the in-memory key when different threads reuse an ID.
    $scopedKey = "$ThreadId|$TurnId"
    if ($Tracker.Turns.ContainsKey($scopedKey) -or $Tracker.UnknownTurns.ContainsKey($scopedKey)) { return $scopedKey }
    foreach ($table in @($Tracker.Turns, $Tracker.UnknownTurns)) {
        if ($table.ContainsKey($TurnId) -and $table[$TurnId].ThreadId -ne $ThreadId) { return "$ThreadId|$TurnId" }
    }
    return $TurnId
}

function Get-CodexGuardFileIdentity {
    param([object]$Tracker, [string]$Path)
    if ($Tracker.Files.ContainsKey($Path)) { return $Tracker.Files[$Path] }
    return New-CodexGuardFileState -Path $Path
}

function Read-CodexGuardFileDelta {
    param(
        [Parameter(Mandatory = $true)]
        [object]$FileState
    )

    $stream = $null
    $memory = $null
    try {
        $stream = New-Object IO.FileStream(
            $FileState.Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )

        if ($stream.Length -lt $FileState.Position) {
            $FileState.Position = [long]0
            $FileState.Partial = ''
            $FileState.Decoder.Reset()
            Reset-CodexGuardFileIdentity -FileState $FileState
        }

        [void]$stream.Seek($FileState.Position, [IO.SeekOrigin]::Begin)
        # Bound each read; historical files can contain very large tool outputs.
        $bytes = New-Object byte[] 262144
        $byteCount = $stream.Read($bytes, 0, $bytes.Length)
        $FileState.Position = $stream.Position
        $FileState.LastLength = $stream.Length
    }
    finally {
        if ($null -ne $memory) {
            $memory.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    if ($byteCount -eq 0) {
        return @()
    }

    $chars = New-Object char[] ([Text.Encoding]::UTF8.GetMaxCharCount($byteCount))
    $charCount = $FileState.Decoder.GetChars($bytes, 0, $byteCount, $chars, 0, $false)
    $chunk = [string]::new($chars, 0, $charCount)
    $text = $FileState.Partial + $chunk
    $segments = [regex]::Split($text, "\r?\n")
    $endsWithNewline = $text.EndsWith("`n")
    $lineCount = $segments.Count

    if ($endsWithNewline) {
        $FileState.Partial = ''
        $lineCount--
    }
    else {
        $FileState.Partial = $segments[$segments.Count - 1]
        $lineCount--
    }

    if ($lineCount -le 0) {
        return @()
    }

    $lines = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $lineCount; $index++) {
        if (-not [string]::IsNullOrEmpty($segments[$index])) {
            $lines.Add($segments[$index])
        }
    }
    return $lines.ToArray()
}

function Register-CodexGuardLine {
    param(
        [Parameter(Mandatory = $true)][object]$Tracker,
        [Parameter(Mandatory = $true)][object]$FileState,
        [string]$Line,
        [object]$Metadata
    )
    if ($null -eq $Metadata -and [string]::IsNullOrWhiteSpace($Line)) { return }
    if ($FileState.InheritedRecordsRemaining -gt 0) {
        $FileState.InheritedRecordsRemaining--
        return
    }
    try { $event = if ($null -ne $Metadata) { $Metadata } else { [CodexGuardJsonReader]::Parse($Line) } }
    catch {
        # JSON exceptions can contain the original content. Never publish them.
        $Tracker.ReadErrors[$FileState.Path] = 'A complete session event could not be parsed; task completion cannot be confirmed.'
        return
    }
    $topLevelType = [string](Get-CodexGuardJsonProperty -Object $event -Name 'type')
    $payload = Get-CodexGuardJsonProperty -Object $event -Name 'payload'
    # Source metadata predates most observed turns and must be read even when
    # the session was created before this app session's tracking baseline.
    if ($topLevelType -eq 'session_meta') {
        Set-CodexGuardSessionIdentity -FileState $FileState -Payload $payload
        return
    }
    $payloadType = [string](Get-CodexGuardJsonProperty -Object $payload -Name 'type')
    $timestamp = Get-CodexGuardJsonProperty -Object $event -Name 'timestamp'
    $eventUtc = if ($null -ne $timestamp) { ConvertTo-GuardUtc -Value $timestamp } else { $null }
    $starts = @('task_started', 'turn_started')
    $completes = @('task_complete', 'turn_complete')
    $isTask = $topLevelType -eq 'event_msg' -and $payloadType -in ($starts + $completes + @('turn_aborted'))
    $isContext = $topLevelType -eq 'turn_context'
    $isUsage = $topLevelType -eq 'event_msg' -and $payloadType -eq 'token_count'
    if (($isTask -or $isContext -or $isUsage) -and $null -eq $eventUtc) {
        if ($isUsage) { $Tracker.UsageError = 'A usage event contained an invalid timestamp.' }
        else { $Tracker.ReadErrors[$FileState.Path] = 'A task event contained an invalid timestamp.' }
        return
    }
    if ($null -eq $eventUtc -or $eventUtc -lt $Tracker.BaselineUtc) { return }
    # Open Windows log handles may keep LastWriteTime at session creation.
    # Any timestamped event owned by this session supplies genuine liveness.
    if ($eventUtc -gt $FileState.LastEventAtUtc) { $FileState.LastEventAtUtc = $eventUtc }

    # File-level activity avoids traversing all historical turns for every
    # message or tool-output record.
    if ($isUsage) {
        try {
            $usage = ConvertTo-CodexGuardUsageSnapshot -Event $event -EventUtc $eventUtc -FilePath $FileState.Path
            if ($null -ne $usage) { $usage.ThreadId = $FileState.ThreadId }
            if ($null -ne $usage -and $usage.LimitId -eq 'codex' -and ($null -ne $usage.Primary -or $null -ne $usage.Secondary)) {
                if ($null -eq $Tracker.LatestUsage -or $usage.UpdatedAtUtc -ge $Tracker.LatestUsage.UpdatedAtUtc) { $Tracker.LatestUsage = $usage }
                $Tracker.UsageError = ''
            }
        }
        catch { $Tracker.UsageError = 'A usage event could not be interpreted.' }
        return
    }
    if (-not $isTask -and -not $isContext) { return }
    $turnId = [string](Get-CodexGuardJsonProperty -Object $payload -Name 'turn_id')
    $threadId = [string]$FileState.ThreadId

    # Older abort events omit turn_id. Correlate only within this thread and
    # before this timestamp, never to a newer turn or another project task.
    if ($payloadType -eq 'turn_aborted' -and [string]::IsNullOrWhiteSpace($turnId)) {
        $candidates = @($Tracker.Turns.Values | Where-Object {
            $_.ThreadId -eq $threadId -and $_.State -eq 'Active' -and $_.StartedAtUtc -le $eventUtc
        })
        $unknownCandidates = @($Tracker.UnknownTurns.Values | Where-Object {
            $_.ThreadId -eq $threadId -and $_.ObservedAtUtc -le $eventUtc
        })
        if ($candidates.Count -eq 1 -and $unknownCandidates.Count -eq 0) { $turnId = $candidates[0].TurnId }
        elseif ($candidates.Count -eq 0 -and $unknownCandidates.Count -eq 1) { $turnId = $unknownCandidates[0].TurnId }
        elseif (@($Tracker.Turns.Values | Where-Object {
            $_.ThreadId -eq $threadId -and $_.State -ne 'Active' -and $null -ne $_.CompletedAtUtc -and $_.CompletedAtUtc -le $eventUtc
        }).Count -gt 0 -and $candidates.Count -eq 0 -and $unknownCandidates.Count -eq 0) { return }
        else {
            $Tracker.ReadErrors[$FileState.Path] = 'An abort event could not be attributed to one exact turn.'
            return
        }
    }
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        $Tracker.ReadErrors[$FileState.Path] = 'A task event did not contain a turn_id.'
        return
    }
    $turnKey = Get-CodexGuardTurnKey -Tracker $Tracker -ThreadId $threadId -TurnId $turnId

    if ($isContext) {
        $cwd = [string](Get-CodexGuardJsonProperty -Object $payload -Name 'cwd')
        if ($Tracker.Turns.ContainsKey($turnKey)) {
            $turn = $Tracker.Turns[$turnKey]
            if (-not [string]::IsNullOrWhiteSpace($cwd)) { $turn.Cwd = $cwd }
            if ($eventUtc -gt $turn.LastEventAtUtc) { $turn.LastEventAtUtc = $eventUtc }
        }
        else {
            # Guardian compaction emits context-only synthetic IDs, without a
            # task lifecycle. Keep actual Guardian tasks and all unidentified
            # contexts under the normal fail-closed tracking rules.
            if ($FileState.IsGuardianSession -and $turnId -cmatch '\Aauto-compact-[0-9]+\z') { return }
            $Tracker.UnknownTurns[$turnKey] = [pscustomobject]@{
                TurnId = $turnId; ThreadId = $threadId; FilePath = $FileState.Path
                Cwd = $cwd; ObservedAtUtc = $eventUtc
                Reason = 'A current turn was found without a recognized start event.'
            }
        }
        return
    }

    if ($payloadType -in $starts) {
        if ($Tracker.Turns.ContainsKey($turnKey)) {
            # Replayed starts do not resurrect completed, aborted, or superseded turns.
            $existing = $Tracker.Turns[$turnKey]
            if ($existing.State -eq 'Active' -and $eventUtc -gt $existing.LastEventAtUtc) { $existing.LastEventAtUtc = $eventUtc }
            [void]$Tracker.UnknownTurns.Remove($turnKey)
            return
        }
        $newState = 'Active'
        foreach ($existing in @($Tracker.Turns.Values | Where-Object { $_.ThreadId -eq $threadId -and $_.State -eq 'Active' })) {
            if ($existing.StartedAtUtc -gt $eventUtc) { $newState = 'Superseded' }
            else { $existing.State = 'Superseded'; $existing.CompletedAtUtc = $eventUtc }
        }
        $cwd = if ($Tracker.UnknownTurns.ContainsKey($turnKey)) { [string]$Tracker.UnknownTurns[$turnKey].Cwd } else { [string]$FileState.Cwd }
        $Tracker.Turns[$turnKey] = [pscustomobject]@{
            TurnId = $turnId; ThreadId = $threadId; FilePath = $FileState.Path
            State = $newState; Cwd = $cwd; StartedAtUtc = $eventUtc
            CompletedAtUtc = if ($newState -eq 'Superseded') { $eventUtc } else { $null }
            LastEventAtUtc = $eventUtc
        }
    }
    else {
        $terminalState = if ($payloadType -eq 'turn_aborted') { 'Aborted' }
            elseif ($null -ne (Get-CodexGuardJsonProperty -Object $payload -Name 'error')) { 'Failed' }
            else { 'Completed' }
        if ($Tracker.Turns.ContainsKey($turnKey)) {
            $turn = $Tracker.Turns[$turnKey]
            # Reject a terminal record dated before this turn began.
            if ($null -ne $turn.StartedAtUtc -and $eventUtc -lt $turn.StartedAtUtc) {
                $Tracker.ReadErrors[$FileState.Path] = 'A terminal event predates its turn start.'
                return
            }
            $turn.State = $terminalState
            $turn.CompletedAtUtc = $eventUtc
            if ($eventUtc -gt $turn.LastEventAtUtc) { $turn.LastEventAtUtc = $eventUtc }
        }
        else {
            $Tracker.Turns[$turnKey] = [pscustomobject]@{
                TurnId = $turnId; ThreadId = $threadId; FilePath = $FileState.Path
                State = $terminalState; Cwd = ''; StartedAtUtc = $null
                CompletedAtUtc = $eventUtc; LastEventAtUtc = $eventUtc
            }
        }
    }
    [void]$Tracker.UnknownTurns.Remove($turnKey)
}


function Add-CodexGuardCandidateFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tracker,

        [Parameter(Mandatory = $true)]
        [IO.FileInfo]$File
    )

    # Windows can keep both file timestamps at session creation while an open
    # log is still appending. Admit all session files and apply the tracking
    # baseline to event timestamps inside the bounded, fair metadata reader.
    if (-not $Tracker.Files.ContainsKey($File.FullName)) {
        $Tracker.Files[$File.FullName] = New-CodexGuardFileState -Path $File.FullName
    }
    $Tracker.Files[$File.FullName].LastWriteUtc = $File.LastWriteTimeUtc
    $Tracker.Files[$File.FullName].LastLength = $File.Length
}

function Update-CodexGuardTracker {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tracker,

        [switch]$Discover
    )

    if ($Discover) {
        try {
            if (-not (Test-Path -LiteralPath $Tracker.SessionsRoot -PathType Container)) {
                $Tracker.GlobalErrors['sessions'] = "Sessions directory does not exist: $($Tracker.SessionsRoot)"
            }
            else {
                [void]$Tracker.GlobalErrors.Remove('sessions')
                foreach ($file in @(
                    Get-ChildItem -LiteralPath $Tracker.SessionsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction Stop
                )) {
                    Add-CodexGuardCandidateFile -Tracker $Tracker -File $file
                }
                $Tracker.LastDiscoveryUtc = [datetime]::UtcNow
            }
        }
        catch {
            $Tracker.GlobalErrors['discovery'] = $_.Exception.Message
        }
    }

    $scanWatch = [Diagnostics.Stopwatch]::StartNew()
    $paths = @($Tracker.Files.Keys | Sort-Object)
    for ($scanIndex = 0; $scanIndex -lt $paths.Count; $scanIndex++) {
        if ($scanWatch.ElapsedMilliseconds -ge 1500) { break }
        $pathIndex = ($Tracker.ReadCursor + $scanIndex) % $paths.Count
        $path = $paths[$pathIndex]
        $fileState = $Tracker.Files[$path]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $hasActiveTurn = @(
                $Tracker.Turns.Values |
                    Where-Object { $_.FilePath -eq $path -and $_.State -eq 'Active' }
            ).Count -gt 0
            if ($hasActiveTurn) {
                $Tracker.ReadErrors[$path] = 'A session file disappeared while its turn was active.'
            }
            continue
        }

        try {
            $startPosition = [long]$fileState.Position
            if ((Get-Item -LiteralPath $path).Length -lt $startPosition) {
                $startPosition = [long]0
                Reset-CodexGuardFileIdentity -FileState $fileState
            }
            # The delta reader is retained for compatibility tests. Rewind its
            # partial prefix if switching to the streaming metadata reader.
            if ($fileState.Partial -ne '' -and $fileState.Partial -ne 'pending') {
                $startPosition -= [Text.Encoding]::UTF8.GetByteCount($fileState.Partial)
            }
            $batch = [CodexGuardJsonReader]::ReadFile($path, [Math]::Max([long]0, $startPosition), [Math]::Max(1, 1500 - [int]$scanWatch.ElapsedMilliseconds))
            $fileState.Position = $batch.Position
            $fileState.LastLength = $batch.Length
            $fileState.Partial = if ($batch.Incomplete) { 'pending' } else { '' }
            $fileState.Decoder.Reset()
            if ($batch.Malformed) { $Tracker.ReadErrors[$path] = 'A complete session event could not be parsed; task completion cannot be confirmed.' }
            foreach ($metadata in $batch.Events) {
                Register-CodexGuardLine -Tracker $Tracker -FileState $fileState -Metadata $metadata
            }
            $fileState.LastWriteUtc = (Get-Item -LiteralPath $path).LastWriteTimeUtc
            if (
                $Tracker.ReadErrors.ContainsKey($path) -and
                (
                    $Tracker.ReadErrors[$path] -like 'Unable to read session file:*' -or
                    $Tracker.ReadErrors[$path] -eq 'A session file disappeared while its turn was active.'
                )
            ) {
                [void]$Tracker.ReadErrors.Remove($path)
            }
        }
        catch {
            $Tracker.ReadErrors[$path] = "Unable to read session file: $($_.Exception.Message)"
        }
    }
    if ($paths.Count -gt 0) { $Tracker.ReadCursor = ($Tracker.ReadCursor + $scanIndex) % $paths.Count }
    $scanWatch.Stop()
}

function Get-CodexGuardSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Tracker,
        [string[]]$IgnoredTurnIds = @(),
        [datetime]$NowUtc = [datetime]::UtcNow,
        [int]$InactiveSeconds = 1800
    )
    $now = $NowUtc.ToUniversalTime()
    $ignoredLookup = @{}
    foreach ($id in $IgnoredTurnIds) { if (-not [string]::IsNullOrWhiteSpace($id)) { $ignoredLookup[$id] = $true } }
    $pathProblems = @{}
    foreach ($path in $Tracker.ReadErrors.Keys) {
        $pathProblems[$path] = [pscustomobject]@{ Kind = 'UnreadableActiveTurn'; Reason = [string]$Tracker.ReadErrors[$path] }
    }
    foreach ($path in $Tracker.Files.Keys) {
        if (-not $pathProblems.ContainsKey($path) -and $Tracker.Files[$path].InheritedRecordsRemaining -gt 0) {
            $pathProblems[$path] = [pscustomobject]@{ Kind = 'IncompleteActiveTurn'; Reason = 'Inherited session history is incomplete; the current task boundary cannot be confirmed.' }
        }
        elseif (-not $pathProblems.ContainsKey($path) -and $Tracker.Files[$path].Partial -eq 'pending') {
            $pathProblems[$path] = [pscustomobject]@{ Kind = 'IncompleteActiveTurn'; Reason = 'A session event is not yet fully written; completion cannot be confirmed.' }
        }
        elseif (-not $pathProblems.ContainsKey($path) -and $Tracker.Files[$path].Position -lt $Tracker.Files[$path].LastLength) {
            $pathProblems[$path] = [pscustomobject]@{ Kind = 'PendingReadActiveTurn'; Reason = 'Historical task records are still being read; completion cannot be confirmed yet.' }
        }
        elseif (-not $pathProblems.ContainsKey($path) -and -not [string]::IsNullOrWhiteSpace($Tracker.Files[$path].Partial)) {
            $pathProblems[$path] = [pscustomobject]@{ Kind = 'IncompleteActiveTurn'; Reason = 'A session event is not yet fully written; completion cannot be confirmed.' }
        }
    }
    $taskEntries = New-Object System.Collections.Generic.List[object]
    $allUnknownItems = New-Object System.Collections.Generic.List[object]
    $recentTurns = New-Object System.Collections.Generic.List[object]
    $coveredProblems = @{}
    $allActiveTurns = @($Tracker.Turns.Values | Where-Object { $_.State -eq 'Active' } | Sort-Object StartedAtUtc, TurnId)
    foreach ($turn in $allActiveTurns) {
        $identity = Get-CodexGuardFileIdentity -Tracker $Tracker -Path $turn.FilePath
        $lastWrite = $null
        if ($Tracker.Files.ContainsKey($turn.FilePath) -and $Tracker.Files[$turn.FilePath].LastWriteUtc -gt [datetime]::MinValue) {
            $lastWrite = [datetime]$Tracker.Files[$turn.FilePath].LastWriteUtc
        }
        if ($identity.LastEventAtUtc -gt [datetime]::MinValue -and ($null -eq $lastWrite -or $identity.LastEventAtUtc -gt $lastWrite)) { $lastWrite = $identity.LastEventAtUtc }
        $activity = [datetime]$turn.LastEventAtUtc
        if ($null -ne $lastWrite -and $lastWrite -gt $activity) { $activity = $lastWrite }
        $age = [Math]::Max(0, ($now - $activity).TotalSeconds)
        $kind = 'ActiveTurn'; $state = 'Active'; $reason = ''
        if ($pathProblems.ContainsKey($turn.FilePath)) {
            $kind = $pathProblems[$turn.FilePath].Kind; $state = 'Unknown'
            $reason = $pathProblems[$turn.FilePath].Reason
            $coveredProblems[$turn.FilePath] = $true
        }
        elseif ($age -ge [Math]::Max(60, $InactiveSeconds)) {
            $kind = 'StaleTurn'; $state = 'Unknown'
            $reason = ('No recorded updates for {0} minutes; this turn may be disconnected or waiting. Completion has not been confirmed.' -f [Math]::Floor($age / 60))
        }
        else { $recentTurns.Add($turn) }
        $ignored = $ignoredLookup.ContainsKey($turn.TurnId)
        $entry = [pscustomobject]@{
            Kind = $kind; State = $state; TurnId = $turn.TurnId; ThreadId = $turn.ThreadId
            ParentThreadId=$identity.ParentThreadId; TaskType=$identity.TaskType
            AgentName=$identity.AgentName; AgentRole=$identity.AgentRole; AgentPath=$identity.AgentPath
            ThreadSource=$identity.ThreadSource; SessionSource=$identity.SessionSource
            Cwd = [string]$turn.Cwd; Path = $turn.FilePath; StartedAtUtc = $turn.StartedAtUtc
            LastUpdatedAtUtc = $lastWrite; ActivityAgeSeconds = [int][Math]::Floor($age)
            Reason = $reason; IsIgnored = $ignored; BlocksShutdown = (-not $ignored)
        }
        $taskEntries.Add($entry)
        if ($state -eq 'Unknown') {
            $allUnknownItems.Add([pscustomobject]@{
                Kind=$kind; Id=$turn.TurnId; TurnId=$turn.TurnId; ThreadId=$turn.ThreadId
                ParentThreadId=$identity.ParentThreadId; TaskType=$identity.TaskType
                AgentName=$identity.AgentName; AgentRole=$identity.AgentRole; AgentPath=$identity.AgentPath
                ThreadSource=$identity.ThreadSource; SessionSource=$identity.SessionSource
                Cwd=$entry.Cwd; Path=$entry.Path; StartedAtUtc=$entry.StartedAtUtc
                LastUpdatedAtUtc=$lastWrite; Reason=$reason; IsIgnored=$ignored
            })
        }
    }
    foreach ($unknown in $Tracker.UnknownTurns.Values) {
        # A single exact turn is never both active and unknown.
        $unknownKey = Get-CodexGuardTurnKey -Tracker $Tracker -ThreadId $unknown.ThreadId -TurnId $unknown.TurnId
        if ($Tracker.Turns.ContainsKey($unknownKey)) { continue }
        $identity = Get-CodexGuardFileIdentity -Tracker $Tracker -Path $unknown.FilePath
        $lastWrite = $null
        if ($Tracker.Files.ContainsKey($unknown.FilePath)) { $lastWrite = $Tracker.Files[$unknown.FilePath].LastWriteUtc }
        if ($identity.LastEventAtUtc -gt [datetime]::MinValue -and ($null -eq $lastWrite -or $identity.LastEventAtUtc -gt $lastWrite)) { $lastWrite = $identity.LastEventAtUtc }
        $ignored = $ignoredLookup.ContainsKey($unknown.TurnId)
        $item = [pscustomobject]@{
            Kind='UnknownTurn'; Id=$unknown.TurnId; TurnId=$unknown.TurnId; ThreadId=$unknown.ThreadId
            ParentThreadId=$identity.ParentThreadId; TaskType=$identity.TaskType
            AgentName=$identity.AgentName; AgentRole=$identity.AgentRole; AgentPath=$identity.AgentPath
            ThreadSource=$identity.ThreadSource; SessionSource=$identity.SessionSource
            Cwd=[string]$unknown.Cwd; Path=$unknown.FilePath; StartedAtUtc=$unknown.ObservedAtUtc
            LastUpdatedAtUtc=$lastWrite; Reason=$unknown.Reason; IsIgnored=$ignored
        }
        $allUnknownItems.Add($item)
        $taskEntries.Add([pscustomobject]@{
            Kind=$item.Kind; State='Unknown'; TurnId=$item.TurnId; ThreadId=$item.ThreadId
            ParentThreadId=$identity.ParentThreadId; TaskType=$identity.TaskType
            AgentName=$identity.AgentName; AgentRole=$identity.AgentRole; AgentPath=$identity.AgentPath
            ThreadSource=$identity.ThreadSource; SessionSource=$identity.SessionSource
            Cwd=$item.Cwd; Path=$item.Path; StartedAtUtc=$item.StartedAtUtc
            LastUpdatedAtUtc=$lastWrite; ActivityAgeSeconds=$null; Reason=$item.Reason
            IsIgnored=$ignored; BlocksShutdown=(-not $ignored)
        })
        $coveredProblems[$unknown.FilePath] = $true
    }
    foreach ($path in $pathProblems.Keys) {
        if ($coveredProblems.ContainsKey($path)) { continue }
        $identity = Get-CodexGuardFileIdentity -Tracker $Tracker -Path $path
        $allUnknownItems.Add([pscustomobject]@{
            Kind = if ($pathProblems[$path].Kind -eq 'IncompleteActiveTurn') { 'IncompleteEvent' }
                elseif ($pathProblems[$path].Kind -eq 'PendingReadActiveTurn') { 'PendingRead' } else { 'ReadError' }
            Id=''; TurnId=''; ThreadId=$identity.ThreadId; Cwd=$identity.Cwd; Path=$path; StartedAtUtc=$null; LastUpdatedAtUtc=$null
            ParentThreadId=$identity.ParentThreadId; TaskType=$identity.TaskType
            AgentName=$identity.AgentName; AgentRole=$identity.AgentRole; AgentPath=$identity.AgentPath
            ThreadSource=$identity.ThreadSource; SessionSource=$identity.SessionSource
            Reason=$pathProblems[$path].Reason; IsIgnored=$false
        })
    }
    foreach ($key in $Tracker.GlobalErrors.Keys) {
        $allUnknownItems.Add([pscustomobject]@{
            Kind='GlobalError'; Id=$key; TurnId=''; ThreadId=''; Cwd=''; Path=$Tracker.SessionsRoot
            ParentThreadId=''; TaskType='Unknown'; AgentName=''; AgentRole=''; AgentPath=''; ThreadSource=''; SessionSource=''
            StartedAtUtc=$null; LastUpdatedAtUtc=$null; Reason=[string]$Tracker.GlobalErrors[$key]; IsIgnored=$false
        })
    }
    $activeTurns = @($recentTurns.ToArray() | Where-Object { -not $ignoredLookup.ContainsKey($_.TurnId) })
    $unknownItems = @($allUnknownItems.ToArray() | Where-Object { -not $_.IsIgnored })
    $ignoredEntries = @($taskEntries.ToArray() | Where-Object { $_.IsIgnored })
    return [pscustomobject]@{
        CapturedAtUtc=$now; BaselineUtc=$Tracker.BaselineUtc
        ActiveCount=$activeTurns.Count; ActiveTurns=$activeTurns; ObservedActiveCount=$recentTurns.Count
        AllActiveTurns=$allActiveTurns; UnknownCount=$unknownItems.Count; UnknownItems=$unknownItems
        ObservedUnknownCount=$allUnknownItems.Count; AllUnknownItems=$allUnknownItems.ToArray()
        TaskCount=$taskEntries.Count; TaskEntries=$taskEntries.ToArray(); IgnoredCount=$ignoredEntries.Count
        IgnoredTurnIds=@($ignoredEntries | ForEach-Object { $_.TurnId })
        TrackedFileCount=$Tracker.Files.Count; TrackedTurnCount=$Tracker.Turns.Count
        HasPendingReads=(@($Tracker.Files.Values | Where-Object { $_.Position -lt $_.LastLength -and $_.Partial -ne 'pending' }).Count -gt 0)
        HistoryBytesRemaining=([long](@($Tracker.Files.Values | ForEach-Object { [Math]::Max([long]0, [long]($_.LastLength - $_.Position)) } | Measure-Object -Sum).Sum))
        UsageAvailable=($null -ne $Tracker.LatestUsage); Usage=$Tracker.LatestUsage; UsageError=[string]$Tracker.UsageError
    }
}


function New-CodexGuardRuntime {
    param(
        [switch]$DryRun
    )

    return [pscustomobject]@{
        Armed = $false
        SeenActive = $false
        Phase = 'Disarmed'
        GraceDeadlineUtc = $null
        NativeDeadlineUtc = $null
        ShutdownScheduled = $false
        StableIdleSamples = 0
        DryRun = [bool]$DryRun
        LastError = ''
        AppSessionKey = ''
        AppSessionStartUtc = $null
    }
}

function Reset-CodexGuardForAppSession {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Runtime,

        [Parameter(Mandatory = $true)]
        [string]$SessionKey,

        [Parameter(Mandatory = $true)]
        [datetime]$StartTimeUtc
    )

    $actions = New-Object System.Collections.Generic.List[string]
    if ($Runtime.ShutdownScheduled) {
        $actions.Add('AbortShutdown')
    }
    $Runtime.AppSessionKey = $SessionKey
    $Runtime.AppSessionStartUtc = $StartTimeUtc.ToUniversalTime()
    $Runtime.SeenActive = $false
    $Runtime.GraceDeadlineUtc = $null
    $Runtime.NativeDeadlineUtc = $null
    $Runtime.ShutdownScheduled = $false
    $Runtime.StableIdleSamples = 0
    if ($Runtime.Armed) {
        $Runtime.Phase = 'WaitingFirstTask'
    }
    else {
        $Runtime.Phase = 'Disarmed'
    }
    return $actions.ToArray()
}

function Set-CodexGuardArmed {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Runtime,

        [int]$CurrentActiveCount = 0,

        [int]$CurrentObservedTaskCount = $CurrentActiveCount
    )

    $Runtime.Armed = $true
    $Runtime.SeenActive = ($CurrentObservedTaskCount -gt 0)
    $Runtime.GraceDeadlineUtc = $null
    $Runtime.NativeDeadlineUtc = $null
    $Runtime.ShutdownScheduled = $false
    $Runtime.StableIdleSamples = 0
    $Runtime.LastError = ''
    if ($Runtime.SeenActive) {
        $Runtime.Phase = 'WaitingTasks'
    }
    else {
        $Runtime.Phase = 'WaitingFirstTask'
    }
}

function Set-CodexGuardDisarmed {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Runtime
    )

    $actions = New-Object System.Collections.Generic.List[string]
    if ($Runtime.ShutdownScheduled) {
        $actions.Add('AbortShutdown')
    }
    $Runtime.Armed = $false
    $Runtime.SeenActive = $false
    $Runtime.Phase = 'Disarmed'
    $Runtime.GraceDeadlineUtc = $null
    $Runtime.NativeDeadlineUtc = $null
    $Runtime.ShutdownScheduled = $false
    $Runtime.StableIdleSamples = 0
    return $actions.ToArray()
}

function Update-CodexGuardRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Runtime,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [bool]$AppAvailable,

        [Parameter(Mandatory = $true)]
        [datetime]$NowUtc,

        [Parameter(Mandatory = $true)]
        [int]$TotalGraceSeconds,

        [Parameter(Mandatory = $true)]
        [int]$NativeShutdownSeconds,

        [int]$RequiredStableSamples = 3
    )

    $actions = New-Object System.Collections.Generic.List[string]
    $now = $NowUtc.ToUniversalTime()
    $internalGraceSeconds = [Math]::Max(0, $TotalGraceSeconds - $NativeShutdownSeconds)
    $stableSamplesRequired = [Math]::Max(1, $RequiredStableSamples)

    if (-not $Runtime.Armed) {
        $Runtime.Phase = 'Disarmed'
        $Runtime.StableIdleSamples = 0
        return $actions.ToArray()
    }

    if (-not $AppAvailable) {
        if ($Runtime.ShutdownScheduled) {
            $actions.Add('AbortShutdown')
        }
        $Runtime.ShutdownScheduled = $false
        $Runtime.GraceDeadlineUtc = $null
        $Runtime.NativeDeadlineUtc = $null
        $Runtime.StableIdleSamples = 0
        $Runtime.Phase = 'PausedAppUnavailable'
        return $actions.ToArray()
    }

    if ($Snapshot.UnknownCount -gt 0) {
        if ($Runtime.ShutdownScheduled) {
            $actions.Add('AbortShutdown')
        }
        $Runtime.ShutdownScheduled = $false
        $Runtime.GraceDeadlineUtc = $null
        $Runtime.NativeDeadlineUtc = $null
        $Runtime.StableIdleSamples = 0
        $Runtime.Phase = 'PausedUnknownState'
        return $actions.ToArray()
    }

    if ($Snapshot.ActiveCount -gt 0) {
        $Runtime.SeenActive = $true
        if ($Runtime.ShutdownScheduled) {
            $actions.Add('AbortShutdown')
        }
        $Runtime.ShutdownScheduled = $false
        $Runtime.GraceDeadlineUtc = $null
        $Runtime.NativeDeadlineUtc = $null
        $Runtime.StableIdleSamples = 0
        $Runtime.Phase = 'WaitingTasks'
        return $actions.ToArray()
    }

    if (-not $Runtime.SeenActive) {
        $Runtime.StableIdleSamples = 0
        $Runtime.Phase = 'WaitingFirstTask'
        return $actions.ToArray()
    }

    if ($null -eq $Runtime.GraceDeadlineUtc) {
        if ($Runtime.StableIdleSamples -lt $stableSamplesRequired) {
            $Runtime.StableIdleSamples++
        }
        if ($Runtime.StableIdleSamples -lt $stableSamplesRequired) {
            $Runtime.Phase = 'ConfirmingIdle'
            $actions.Add('IdleSampleRecorded')
            return $actions.ToArray()
        }
        $Runtime.GraceDeadlineUtc = $now.AddSeconds($internalGraceSeconds)
        $Runtime.Phase = 'GraceCountdown'
        $actions.Add('GraceStarted')
        return $actions.ToArray()
    }

    if ($now -lt $Runtime.GraceDeadlineUtc) {
        $Runtime.Phase = 'GraceCountdown'
        return $actions.ToArray()
    }

    if (-not $Runtime.ShutdownScheduled) {
        $Runtime.ShutdownScheduled = $true
        $Runtime.NativeDeadlineUtc = $now.AddSeconds($NativeShutdownSeconds)
        $Runtime.Phase = 'NativeCountdown'
        $actions.Add('ScheduleShutdown')
        return $actions.ToArray()
    }

    if (
        $Runtime.DryRun -and
        $null -ne $Runtime.NativeDeadlineUtc -and
        $now -ge $Runtime.NativeDeadlineUtc
    ) {
        $Runtime.ShutdownScheduled = $false
        $Runtime.Armed = $false
        $Runtime.Phase = 'DryRunComplete'
        $actions.Add('DryRunComplete')
        return $actions.ToArray()
    }

    $Runtime.Phase = 'NativeCountdown'
    return $actions.ToArray()
}

Export-ModuleMember -Function @(
    'ConvertFrom-CodexGuardThreadTitleLine',
    'Get-CodexGuardTaskDisplayTitle',
    'Get-CodexGuardTaskTooltip',
    'Get-CodexGuardTaskTypeLabel',
    'Get-CodexGuardTaskStateLabel',
    'Get-CodexGuardTaskManagerRows',
    'Get-GuardCodexHome',
    'Test-CodexGuardAppServerPath',
    'Get-CodexGuardPowerShellLaunchArguments',
    'Get-CodexGuardAppSession',
    'Get-CodexGuardUsageValidity',
    'New-CodexGuardTracker',
    'Update-CodexGuardTracker',
    'Get-CodexGuardSnapshot',
    'New-CodexGuardRuntime',
    'Reset-CodexGuardForAppSession',
    'Set-CodexGuardArmed',
    'Set-CodexGuardDisarmed',
    'Update-CodexGuardRuntime'
)
