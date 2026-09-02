#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ControlHubStateUri = 'http://100.71.26.69:8789/api/state',
    [string]$BrokerHost = '127.0.0.1',
    [int]$BrokerPort = 1883,
    [int]$PollSeconds = 15,
    [int]$StaleSeconds = 120,
    [int]$DiscoveryRefreshSeconds = 1800,
    [switch]$Once,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# AFZ_HOMEASSISTANT_MQTT_PUBLISHER_V1
# One publisher only. Reads live Control Hub /api/state and publishes retained MQTT
# discovery/state. It never creates jobs, routes work, changes worker state, or reads
# GitHub/OneDrive as a liveness source.

$BaseTopic = 'afz/fleet'
$DiscoveryPrefix = 'homeassistant'
$PublisherVersion = '1.0.0'

$WorkerMap = [ordered]@{
    'windows-main' = @{
        Presence = @('windows-control-observer-1')
        Telemetry = @('windows-control-observer-1')
        Job = @()
    }
    'h3' = @{
        Presence = @('h3-presence-observer-1','h3-generic-readiness-observer-1','h3-direct-1')
        Telemetry = @('h3-generic-readiness-observer-1','h3-direct-1')
        Job = @('h3-direct-1')
    }
    'lenovo' = @{
        Presence = @('lenovo-presence-observer-1','lenovo-local-observer-1','lenovo-direct-1')
        Telemetry = @('lenovo-local-observer-1','lenovo-direct-1')
        Job = @('lenovo-direct-1')
    }
    'asus' = @{
        Presence = @()
        Telemetry = @()
        Job = @()
    }
    'hp' = @{
        Presence = @('hpenvy-direct-1')
        Telemetry = @('hpenvy-direct-1')
        Job = @('hpenvy-direct-1')
    }
    'pi' = @{
        Presence = @('raspi-direct-observer-1')
        Telemetry = @('raspi-direct-observer-1')
        Job = @()
    }
}

$EntityDefinitions = @(
    @{ Key='online'; Component='binary_sensor'; Suffix='availability'; DeviceClass='connectivity' },
    @{ Key='cpu'; Component='sensor'; Suffix='cpu_pct'; Unit='%'; StateClass='measurement' },
    @{ Key='ram'; Component='sensor'; Suffix='ram_pct'; Unit='%'; StateClass='measurement' },
    @{ Key='gpu'; Component='sensor'; Suffix='gpu_pct'; Unit='%'; StateClass='measurement' },
    @{ Key='vram'; Component='sensor'; Suffix='vram_pct'; Unit='%'; StateClass='measurement' },
    @{ Key='compute_state'; Component='sensor'; Suffix='compute_state' },
    @{ Key='ollama_state'; Component='sensor'; Suffix='ollama_state' },
    @{ Key='active_job'; Component='sensor'; Suffix='active_job' },
    @{ Key='last_heartbeat'; Component='sensor'; Suffix='last_heartbeat' }
)

function Write-Log([string]$Message) {
    Write-Host "$(Get-Date -Format o) $Message"
}

function ConvertTo-MqttStringBytes([string]$Text) {
    $body = [Text.Encoding]::UTF8.GetBytes($Text)
    if ($body.Length -gt 65535) { throw 'MQTT string too long' }
    $result = New-Object byte[] ($body.Length + 2)
    $result[0] = [byte](($body.Length -shr 8) -band 0xFF)
    $result[1] = [byte]($body.Length -band 0xFF)
    [Array]::Copy($body, 0, $result, 2, $body.Length)
    return $result
}

function ConvertTo-MqttRemainingLength([int]$Length) {
    if ($Length -lt 0 -or $Length -gt 268435455) { throw 'Invalid MQTT remaining length' }
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    do {
        $digit = $Length % 128
        $Length = [math]::Floor($Length / 128)
        if ($Length -gt 0) { $digit = $digit -bor 0x80 }
        $bytes.Add([byte]$digit)
    } while ($Length -gt 0)
    return $bytes.ToArray()
}

function Send-MqttPacket($Stream, [byte]$Header, [byte[]]$Payload) {
    $remaining = ConvertTo-MqttRemainingLength $Payload.Length
    $packet = New-Object byte[] (1 + $remaining.Length + $Payload.Length)
    $packet[0] = $Header
    [Array]::Copy($remaining, 0, $packet, 1, $remaining.Length)
    if ($Payload.Length -gt 0) {
        [Array]::Copy($Payload, 0, $packet, 1 + $remaining.Length, $Payload.Length)
    }
    $Stream.Write($packet, 0, $packet.Length)
    $Stream.Flush()
}

function Read-Exact($Stream, [int]$Count) {
    $buffer = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { throw 'MQTT connection closed unexpectedly' }
        $offset += $read
    }
    return $buffer
}

function Open-MqttConnection {
    $tcp = New-Object Net.Sockets.TcpClient
    $tcp.ReceiveTimeout = 5000
    $tcp.SendTimeout = 5000
    $tcp.Connect($BrokerHost, $BrokerPort)
    $stream = $tcp.GetStream()

    $protocol = ConvertTo-MqttStringBytes 'MQTT'
    $clientId = "afz-ha-publisher-$([Environment]::MachineName.ToLowerInvariant())-$PID"
    $clientBytes = ConvertTo-MqttStringBytes $clientId

    $username = [Environment]::GetEnvironmentVariable('AFZ_MQTT_USERNAME')
    $password = [Environment]::GetEnvironmentVariable('AFZ_MQTT_PASSWORD')

    $flags = 0x02 # clean session
    $payloadParts = New-Object 'System.Collections.Generic.List[byte]'
    $payloadParts.AddRange([byte[]]$clientBytes)

    if (-not [string]::IsNullOrWhiteSpace($username)) {
        $flags = $flags -bor 0x80
        $payloadParts.AddRange([byte[]](ConvertTo-MqttStringBytes $username))
        if ($null -ne $password) {
            $flags = $flags -bor 0x40
            $payloadParts.AddRange([byte[]](ConvertTo-MqttStringBytes $password))
        }
    }

    $variable = New-Object 'System.Collections.Generic.List[byte]'
    $variable.AddRange([byte[]]$protocol)
    $variable.Add([byte]4) # MQTT 3.1.1
    $variable.Add([byte]$flags)
    $variable.Add([byte]0)
    $variable.Add([byte]60)
    $variable.AddRange($payloadParts.ToArray())

    Send-MqttPacket $stream 0x10 $variable.ToArray()
    $connack = Read-Exact $stream 4
    if ($connack[0] -ne 0x20 -or $connack[1] -ne 0x02) {
        $tcp.Dispose()
        throw "Unexpected MQTT CONNACK: $([BitConverter]::ToString($connack))"
    }
    if ($connack[3] -ne 0x00) {
        $code = $connack[3]
        $tcp.Dispose()
        throw "MQTT broker rejected connection, return code $code"
    }

    return [pscustomobject]@{ Tcp=$tcp; Stream=$stream }
}

function Publish-Mqtt($Connection, [string]$Topic, [AllowEmptyString()][string]$Payload, [bool]$Retain=$true) {
    $topicBytes = ConvertTo-MqttStringBytes $Topic
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Payload)
    $packetPayload = New-Object byte[] ($topicBytes.Length + $bodyBytes.Length)
    [Array]::Copy($topicBytes, 0, $packetPayload, 0, $topicBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        [Array]::Copy($bodyBytes, 0, $packetPayload, $topicBytes.Length, $bodyBytes.Length)
    }
    $header = if ($Retain) { [byte]0x31 } else { [byte]0x30 }
    Send-MqttPacket $Connection.Stream $header $packetPayload
}

function Close-MqttConnection($Connection) {
    if ($null -eq $Connection) { return }
    try {
        $Connection.Stream.Write([byte[]](0xE0,0x00), 0, 2)
        $Connection.Stream.Flush()
    } catch {}
    try { $Connection.Stream.Dispose() } catch {}
    try { $Connection.Tcp.Dispose() } catch {}
}

function Get-RecordIndex($State) {
    $index = @{}
    foreach ($record in @($State.workers)) {
        if ($record.worker_id) { $index[[string]$record.worker_id] = $record }
    }
    return $index
}

function Get-HeartbeatTime($Record) {
    if ($null -eq $Record -or -not $Record.last_heartbeat) { return $null }
    try { return [DateTimeOffset]::Parse([string]$Record.last_heartbeat).ToUniversalTime() }
    catch { return $null }
}

function Test-RecordFresh($Record) {
    $hb = Get-HeartbeatTime $Record
    if ($null -eq $hb) { return $false }
    $age = ([DateTimeOffset]::UtcNow - $hb).TotalSeconds
    return ($age -ge -30 -and $age -le $StaleSeconds)
}

function Test-StateOnline([string]$StateValue) {
    if ([string]::IsNullOrWhiteSpace($StateValue)) { return $false }
    $u = $StateValue.Trim().ToUpperInvariant()
    if ($u -match 'OFFLINE|UNAVAILABLE|DISCONNECTED|^DOWN$|^UNKNOWN$') { return $false }
    return $true
}

function Select-FreshRecord($Index, [string[]]$Ids) {
    foreach ($id in @($Ids)) {
        if ($Index.ContainsKey($id) -and (Test-RecordFresh $Index[$id])) {
            return $Index[$id]
        }
    }
    return $null
}

function Select-FirstFreshOnlineRecord($Index, [string[]]$Ids) {
    foreach ($id in @($Ids)) {
        if (-not $Index.ContainsKey($id)) { continue }
        $r = $Index[$id]
        if ((Test-RecordFresh $r) -and (Test-StateOnline ([string]$r.state))) { return $r }
    }
    return $null
}

function Get-MetadataScalar($Record, [string[]]$Keys) {
    if ($null -eq $Record -or $null -eq $Record.metadata) { return $null }
    foreach ($key in $Keys) {
        foreach ($p in $Record.metadata.PSObject.Properties) {
            if ($p.Name -ieq $key) {
                $value = $p.Value
                if ($null -ne $value -and $value -isnot [pscustomobject] -and $value -isnot [System.Array]) {
                    return $value
                }
            }
        }
    }
    return $null
}

function Get-MetricFromPreferences($Index, [string[]]$Ids, [string[]]$Keys) {
    foreach ($id in @($Ids)) {
        if (-not $Index.ContainsKey($id)) { continue }
        $r = $Index[$id]
        if (-not (Test-RecordFresh $r)) { continue }
        $v = Get-MetadataScalar $r $Keys
        if ($null -ne $v -and [string]$v -ne '') { return $v }
    }
    return $null
}

function Get-LatestHeartbeat($Index, [string[]]$Ids) {
    $latest = $null
    foreach ($id in @($Ids)) {
        if (-not $Index.ContainsKey($id)) { continue }
        $hb = Get-HeartbeatTime $Index[$id]
        if ($null -ne $hb -and ($null -eq $latest -or $hb -gt $latest)) { $latest = $hb }
    }
    return $latest
}

function Get-CanonicalWorkerState($Index, [string]$Worker, $Map) {
    $allIds = @($Map.Presence + $Map.Telemetry + $Map.Job | Select-Object -Unique)
    $presence = Select-FirstFreshOnlineRecord $Index $Map.Presence
    $available = ($null -ne $presence)

    $compute = Select-FreshRecord $Index $Map.Job
    if ($null -eq $compute) { $compute = Select-FreshRecord $Index $Map.Telemetry }
    if ($null -eq $compute) { $compute = Select-FreshRecord $Index $Map.Presence }

    $jobRecord = Select-FreshRecord $Index $Map.Job
    $currentJob = $null
    if ($null -ne $jobRecord -and $jobRecord.current_job_id) { $currentJob = [string]$jobRecord.current_job_id }

    $ollama = Get-MetricFromPreferences $Index $Map.Telemetry @('ollama_state','ollamaState')
    $latestHeartbeat = Get-LatestHeartbeat $Index $allIds

    return [ordered]@{
        worker = $Worker
        availability = if ($available) { 'online' } else { 'offline' }
        cpu_pct = Get-MetricFromPreferences $Index $Map.Telemetry @('cpu_percent','cpu_pct','cpuPercent','cpu')
        ram_pct = Get-MetricFromPreferences $Index $Map.Telemetry @('ram_percent','ram_pct','memory_percent','memory_pct','ramPercent','ram')
        gpu_pct = Get-MetricFromPreferences $Index $Map.Telemetry @('gpu_percent','gpu_pct','gpuPercent','gpu')
        vram_pct = Get-MetricFromPreferences $Index $Map.Telemetry @('vram_percent','vram_pct','vramPercent','vram')
        compute_state = if ($null -ne $compute) { [string]$compute.state } else { $null }
        ollama_state = if ($null -ne $ollama) { [string]$ollama } else { $null }
        active_job = if ($available) { if ($currentJob) { $currentJob } else { 'none' } } else { $null }
        last_heartbeat = if ($null -ne $latestHeartbeat) { $latestHeartbeat.ToString('o') } else { $null }
    }
}

function Get-DisplayName([string]$Worker) {
    switch ($Worker) {
        'windows-main' { return 'Windows Main' }
        'h3' { return 'H3' }
        'lenovo' { return 'Lenovo' }
        'asus' { return 'ASUS' }
        'hp' { return 'HP' }
        'pi' { return 'Pi' }
        default { return $Worker }
    }
}

function Get-DiscoveryPayload([string]$Worker, $Def) {
    $slug = $Worker.Replace('-','_')
    $unique = "afz_${slug}_$($Def.Key)"
    $display = Get-DisplayName $Worker
    $device = [ordered]@{
        identifiers = @("afz_worker_$slug")
        name = "AFZ $display"
        manufacturer = 'AFZ'
        model = 'Control Hub worker'
    }

    if ($Def.Key -eq 'online') {
        $cfg = [ordered]@{
            name = "AFZ $display Online"
            unique_id = $unique
            object_id = $unique
            state_topic = "$BaseTopic/$Worker/availability"
            payload_on = 'online'
            payload_off = 'offline'
            device_class = 'connectivity'
            device = $device
        }
    } else {
        $nameSuffix = switch ($Def.Key) {
            'cpu' { 'CPU' }
            'ram' { 'RAM' }
            'gpu' { 'GPU' }
            'vram' { 'VRAM' }
            'compute_state' { 'Compute State' }
            'ollama_state' { 'Ollama State' }
            'active_job' { 'Active Job' }
            'last_heartbeat' { 'Last Heartbeat' }
            default { $Def.Key }
        }
        $cfg = [ordered]@{
            name = "AFZ $display $nameSuffix"
            unique_id = $unique
            object_id = $unique
            state_topic = "$BaseTopic/$Worker/$($Def.Suffix)"
            availability_topic = "$BaseTopic/$Worker/availability"
            payload_available = 'online'
            payload_not_available = 'offline'
            device = $device
        }
        if ($Def.Unit) { $cfg.unit_of_measurement = $Def.Unit }
        if ($Def.StateClass) { $cfg.state_class = $Def.StateClass }
    }
    return ($cfg | ConvertTo-Json -Depth 8 -Compress)
}

function Publish-Discovery($Connection) {
    foreach ($worker in $WorkerMap.Keys) {
        $slug = $worker.Replace('-','_')
        foreach ($def in $EntityDefinitions) {
            $unique = "afz_${slug}_$($def.Key)"
            $topic = "$DiscoveryPrefix/$($def.Component)/$unique/config"
            $payload = Get-DiscoveryPayload $worker $def
            Publish-Mqtt $Connection $topic $payload $true
        }
    }
}

function Publish-WorkerState($Connection, $State) {
    $worker = [string]$State.worker
    Publish-Mqtt $Connection "$BaseTopic/$worker/availability" ([string]$State.availability) $true

    $topicMap = [ordered]@{
        cpu_pct = 'cpu_pct'
        ram_pct = 'ram_pct'
        gpu_pct = 'gpu_pct'
        vram_pct = 'vram_pct'
        compute_state = 'compute_state'
        ollama_state = 'ollama_state'
        active_job = 'active_job'
        last_heartbeat = 'last_heartbeat'
    }

    foreach ($field in $topicMap.Keys) {
        $value = $State[$field]
        $topic = "$BaseTopic/$worker/$($topicMap[$field])"
        if ($null -eq $value -or [string]$value -eq '') {
            Publish-Mqtt $Connection $topic '' $true # clears stale retained state
        } else {
            $text = if ($value -is [double] -or $value -is [single] -or $value -is [decimal]) {
                ([Convert]::ToString($value, [Globalization.CultureInfo]::InvariantCulture))
            } else { [string]$value }
            Publish-Mqtt $Connection $topic $text $true
        }
    }
}

function Read-LiveState {
    $state = Invoke-RestMethod -Method Get -Uri $ControlHubStateUri -TimeoutSec 8
    if ($null -eq $state -or $null -eq $state.workers) { throw 'Control Hub /api/state returned no workers' }
    return $state
}

$lastDiscovery = [DateTimeOffset]::MinValue
$stopping = $false

try {
    Write-Log "START version=$PublisherVersion stateUri=$ControlHubStateUri broker=$BrokerHost`:$BrokerPort pollSeconds=$PollSeconds staleSeconds=$StaleSeconds once=$Once dryRun=$DryRun"

    do {
        $cycleStart = [DateTimeOffset]::UtcNow
        $live = Read-LiveState
        $index = Get-RecordIndex $live
        $mapped = @()
        foreach ($worker in $WorkerMap.Keys) {
            $mapped += ,(Get-CanonicalWorkerState $index $worker $WorkerMap[$worker])
        }

        if ($DryRun) {
            foreach ($m in $mapped) {
                Write-Host ($m | ConvertTo-Json -Compress)
            }
        } else {
            $conn = $null
            try {
                $conn = Open-MqttConnection
                if (([DateTimeOffset]::UtcNow - $lastDiscovery).TotalSeconds -ge $DiscoveryRefreshSeconds) {
                    Publish-Discovery $conn
                    $lastDiscovery = [DateTimeOffset]::UtcNow
                    Write-Log 'DISCOVERY_PUBLISHED=YES'
                }
                foreach ($m in $mapped) { Publish-WorkerState $conn $m }
                Write-Log "STATE_PUBLISHED=YES workers=$($mapped.Count) hubWorkers=$(@($live.workers).Count)"
            } finally {
                Close-MqttConnection $conn
            }
        }

        if ($Once) { break }
        $elapsed = ([DateTimeOffset]::UtcNow - $cycleStart).TotalSeconds
        $sleep = [math]::Max(1, $PollSeconds - [int][math]::Floor($elapsed))
        Start-Sleep -Seconds $sleep
    } while (-not $stopping)
}
finally {
    if (-not $DryRun -and -not $Once) {
        $conn = $null
        try {
            $conn = Open-MqttConnection
            foreach ($worker in $WorkerMap.Keys) {
                Publish-Mqtt $conn "$BaseTopic/$worker/availability" 'offline' $true
            }
            Write-Log 'CLEAN_SHUTDOWN_OFFLINE_PUBLISHED=YES'
        } catch {
            Write-Log "CLEAN_SHUTDOWN_OFFLINE_PUBLISHED=NO error=$($_.Exception.Message)"
        } finally {
            Close-MqttConnection $conn
        }
    }
    Write-Log 'STOP'
}
