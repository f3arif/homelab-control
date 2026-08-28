#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$Port = 8796,
  [string]$BindHost = '100.70.25.8',
  [string]$ModelLuna = 'gpt-5.6-luna',
  [string]$ModelSol = 'gpt-5.6-sol'
)

$ErrorActionPreference = 'Stop'
$AgentRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateRoot = 'C:\ProgramData\AFZ\OpenAIAgent'
$KeyFile = Join-Path $StateRoot 'openai-key.dpapi'
$LogRoot = Join-Path $StateRoot 'logs'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Write-AgentLog {
  param([string]$Message)
  $line = "$(Get-Date -Format o) $Message"
  Add-Content -LiteralPath (Join-Path $LogRoot 'agent.log') -Value $line -Encoding UTF8
}

function Get-OpenAIKey {
  if ($env:OPENAI_API_KEY) { return $env:OPENAI_API_KEY }
  if (-not (Test-Path -LiteralPath $KeyFile)) { throw "OpenAI key not configured: $KeyFile" }
  $protected = [IO.File]::ReadAllBytes($KeyFile)
  $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
    $protected,
    $null,
    [Security.Cryptography.DataProtectionScope]::LocalMachine
  )
  return [Text.Encoding]::UTF8.GetString($bytes)
}

$OpenAIKey = Get-OpenAIKey
$Jobs = [hashtable]::Synchronized(@{})
$AllowedClients = @('127.0.0.1','::1','100.70.25.8','100.71.26.69')

function Get-RemoteIp {
  param($Context)
  $addr = $Context.Request.RemoteEndPoint.Address
  try {
    if ($addr.IsIPv4MappedToIPv6) { return $addr.MapToIPv4().ToString() }
  } catch {}
  return $addr.ToString()
}

function Test-ClientAllowed {
  param($Context)
  $ip = Get-RemoteIp $Context
  return ($AllowedClients -contains $ip)
}

function Send-Bytes {
  param($Context,[int]$Status,[string]$ContentType,[byte[]]$Bytes)
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = $ContentType
  $Context.Response.Headers['Cache-Control'] = 'no-store'
  $Context.Response.Headers['Access-Control-Allow-Origin'] = '*'
  $Context.Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
  $Context.Response.Headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
  $Context.Response.ContentLength64 = $Bytes.Length
  $Context.Response.OutputStream.Write($Bytes,0,$Bytes.Length)
  $Context.Response.Close()
}

function Send-Json {
  param($Context,[int]$Status,$Object)
  $json = $Object | ConvertTo-Json -Depth 30 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  Send-Bytes $Context $Status 'application/json; charset=utf-8' $bytes
}

function Send-Text {
  param($Context,[int]$Status,[string]$ContentType,[string]$Text)
  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  Send-Bytes $Context $Status $ContentType $bytes
}

function Read-JsonBody {
  param($Context)
  $reader = New-Object IO.StreamReader($Context.Request.InputStream,$Context.Request.ContentEncoding)
  try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
  if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
  return ($raw | ConvertFrom-Json)
}

function Get-Model {
  param([string]$Processor,[string]$Prompt)
  if ($Processor -eq 'sol') { return $ModelSol }
  if ($Processor -eq 'luna') { return $ModelLuna }
  if ($Prompt -match '(?i)diagnos|root cause|forensic|compare|architect|complex|regression|investigate') { return $ModelSol }
  return $ModelLuna
}

$RootMap = @{
  'jellyfin-local'       = 'C:\Users\Faiz\AppData\Local\Jellyfin'
  'jellyfin-programdata' = 'C:\ProgramData\Jellyfin\Server'
  'jellyfin-web'         = 'C:\Program Files\Jellyfin\Server'
  'afz-backups'          = 'C:\AFZ\MediaCatalog\Backups'
  'afz-diagnostics'      = 'C:\AFZ\Diagnostics'
  'torbox-media'         = 'C:\Media\TorBoxStream'
}

function Resolve-SafePath {
  param([string]$Root,[string]$RelativePath)
  if (-not $RootMap.ContainsKey($Root)) { throw "Unknown root alias: $Root" }
  $base = [IO.Path]::GetFullPath([string]$RootMap[$Root]).TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $base }
  $candidate = [IO.Path]::GetFullPath((Join-Path $base $RelativePath))
  if ($candidate -ne $base -and -not $candidate.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Path escapes allowlisted root'
  }
  return $candidate
}

function Tool-SystemStatus {
  $os = Get-CimInstance Win32_OperatingSystem
  $cpuInfo = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
  $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
  $ramUsedGb = [math]::Round(($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/1MB,2)
  $ramTotalGb = [math]::Round($os.TotalVisibleMemorySize/1MB,2)
  return [pscustomobject][ordered]@{
    computer = $env:COMPUTERNAME
    cpuPercent = [math]::Round([double]$cpuInfo.Average,1)
    ramUsedGb = $ramUsedGb
    ramTotalGb = $ramTotalGb
    ramPercent = [math]::Round(($ramUsedGb/$ramTotalGb)*100,1)
    diskFreeGb = [math]::Round($drive.FreeSpace/1GB,2)
    diskTotalGb = [math]::Round($drive.Size/1GB,2)
    jellyfinRunning = [bool](Get-Process jellyfin -ErrorAction SilentlyContinue)
    timestamp = (Get-Date -Format o)
  }
}

function Tool-ReadFile {
  param($Args)
  $path = Resolve-SafePath ([string]$Args.root) ([string]$Args.path)
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "File not found: $path" }
  $max = [math]::Min([math]::Max([int]$Args.max_chars,1000),60000)
  $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
  $truncated = ($text.Length -gt $max)
  if ($truncated) { $text = $text.Substring(0,$max) }
  return [pscustomobject][ordered]@{root=$Args.root;path=$Args.path;fullPath=$path;chars=$text.Length;truncated=$truncated;text=$text}
}

function Tool-ListFiles {
  param($Args)
  $path = Resolve-SafePath ([string]$Args.root) ([string]$Args.path)
  if (-not (Test-Path -LiteralPath $path)) { throw "Path not found: $path" }
  $depth = [math]::Min([math]::Max([int]$Args.depth,0),3)
  $limit = [math]::Min([math]::Max([int]$Args.limit,1),300)
  if ($depth -gt 0) {
    $items = @(Get-ChildItem -LiteralPath $path -Force -Recurse -Depth $depth -ErrorAction SilentlyContinue)
  } else {
    $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)
  }
  $result = @()
  foreach ($item in @($items | Select-Object -First $limit)) {
    $len = $null
    if (-not $item.PSIsContainer) { $len = $item.Length }
    $result += [pscustomobject][ordered]@{
      name=$item.Name
      fullName=$item.FullName
      directory=[bool]$item.PSIsContainer
      length=$len
      modified=$item.LastWriteTimeUtc.ToString('o')
    }
  }
  return $result
}

function Tool-FileSearch {
  param($Args)
  $path = Resolve-SafePath ([string]$Args.root) ([string]$Args.path)
  if (-not (Test-Path -LiteralPath $path)) { throw "Path not found: $path" }
  $pattern = [string]$Args.pattern
  if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'Search pattern required' }
  if ($pattern.Length -gt 200) { throw 'Search pattern too long' }
  $limit = [math]::Min([math]::Max([int]$Args.limit,1),200)
  $hits = @()
  $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1000)
  foreach ($f in $files) {
    try {
      $matches = @(Select-String -LiteralPath $f.FullName -Pattern $pattern -SimpleMatch -ErrorAction Stop | Select-Object -First 10)
      foreach ($m in $matches) {
        if ($hits.Count -ge $limit) { break }
        $hits += [pscustomobject][ordered]@{file=$f.FullName;line=$m.LineNumber;text=$m.Line.Trim()}
      }
    } catch {}
    if ($hits.Count -ge $limit) { break }
  }
  return $hits
}

function Tool-JellyfinPublicInfo {
  try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec 8
    return [pscustomobject][ordered]@{ok=$true;serverName=$r.ServerName;version=$r.Version;id=$r.Id;startupWizardCompleted=$r.StartupWizardCompleted}
  } catch {
    return [pscustomobject][ordered]@{ok=$false;error=$_.Exception.Message}
  }
}

function Invoke-JsonToolScript {
  param([string]$Name,[string[]]$Arguments)
  $script = Join-Path $AgentRoot (Join-Path 'tools' $Name)
  if (-not (Test-Path -LiteralPath $script)) { throw "Missing tool script: $script" }
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script)
  if ($Arguments) { $argList += $Arguments }
  $raw = & powershell.exe @argList 2>&1 | Out-String
  try { return ($raw | ConvertFrom-Json) }
  catch {
    $max = [math]::Min($raw.Length,50000)
    return [pscustomobject][ordered]@{ok=$false;parseError=$_.Exception.Message;raw=$raw.Substring(0,$max)}
  }
}

function Tool-JellyfinForensic {
  return Invoke-JsonToolScript 'Jellyfin-Regression-Forensic.ps1' @()
}

function Tool-JellyfinUserViews {
  param($Args)
  return Invoke-JsonToolScript 'Jellyfin-UserViews-ReadOnly.ps1' @('-User',[string]$Args.user)
}

function Tool-JellyfinRecentReport {
  $root = 'C:\AFZ\Diagnostics\Jellyfin'
  if (-not (Test-Path -LiteralPath $root)) { return [pscustomobject]@{ok=$false;reason='diagnostics directory missing'} }
  $f = Get-ChildItem -LiteralPath $root -File -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if (-not $f) { return [pscustomobject]@{ok=$false;reason='no reports'} }
  $text = Get-Content -LiteralPath $f.FullName -Raw
  $max = 50000
  $truncated = ($text.Length -gt $max)
  if ($truncated) { $text = $text.Substring(0,$max) }
  return [pscustomobject][ordered]@{ok=$true;file=$f.FullName;modified=$f.LastWriteTimeUtc.ToString('o');truncated=$truncated;text=$text}
}

$ToolDefinitions = @(
  [ordered]@{
    type='function';name='afz_system_status';description='Read current Windows-main CPU, RAM, disk and Jellyfin process status. Read-only.';strict=$true
    parameters=[ordered]@{type='object';properties=[ordered]@{};required=@();additionalProperties=$false}
  },
  [ordered]@{
    type='function';name='afz_read_file';description='Read a text file from an explicitly allowlisted AFZ/Jellyfin root. Read-only.';strict=$true
    parameters=[ordered]@{
      type='object'
      properties=[ordered]@{
        root=[ordered]@{type='string';enum=@('jellyfin-local','jellyfin-programdata','jellyfin-web','afz-backups','afz-diagnostics','torbox-media')}
        path=[ordered]@{type='string'}
        max_chars=[ordered]@{type='integer';minimum=1000;maximum=60000}
      }
      required=@('root','path','max_chars');additionalProperties=$false
    }
  },
  [ordered]@{
    type='function';name='afz_list_files';description='List files or directories under an allowlisted AFZ/Jellyfin root. Read-only.';strict=$true
    parameters=[ordered]@{
      type='object'
      properties=[ordered]@{
        root=[ordered]@{type='string';enum=@('jellyfin-local','jellyfin-programdata','jellyfin-web','afz-backups','afz-diagnostics','torbox-media')}
        path=[ordered]@{type='string'}
        depth=[ordered]@{type='integer';minimum=0;maximum=3}
        limit=[ordered]@{type='integer';minimum=1;maximum=300}
      }
      required=@('root','path','depth','limit');additionalProperties=$false
    }
  },
  [ordered]@{
    type='function';name='afz_search_files';description='Search text files beneath an allowlisted AFZ/Jellyfin root for an exact text pattern. Read-only.';strict=$true
    parameters=[ordered]@{
      type='object'
      properties=[ordered]@{
        root=[ordered]@{type='string';enum=@('jellyfin-local','jellyfin-programdata','jellyfin-web','afz-backups','afz-diagnostics')}
        path=[ordered]@{type='string'}
        pattern=[ordered]@{type='string'}
        limit=[ordered]@{type='integer';minimum=1;maximum=200}
      }
      required=@('root','path','pattern','limit');additionalProperties=$false
    }
  },
  [ordered]@{
    type='function';name='jellyfin_public_info';description='Read Jellyfin server identity and version from localhost:8096. Read-only.';strict=$true
    parameters=[ordered]@{type='object';properties=[ordered]@{};required=@();additionalProperties=$false}
  },
  [ordered]@{
    type='function';name='jellyfin_regression_forensic';description='Run the fixed read-only Jellyfin native-library regression comparison against known-good backups. No service stop, DB write, media scan, or OneDrive.';strict=$true
    parameters=[ordered]@{type='object';properties=[ordered]@{};required=@();additionalProperties=$false}
  },
  [ordered]@{
    type='function';name='jellyfin_user_views';description='Read live Jellyfin views for coolyo or movies using a locally discovered active token without exposing the token. Read-only.';strict=$true
    parameters=[ordered]@{type='object';properties=[ordered]@{user=[ordered]@{type='string';enum=@('coolyo','movies')}};required=@('user');additionalProperties=$false}
  },
  [ordered]@{
    type='function';name='jellyfin_recent_diagnostic_report';description='Read the newest local Jellyfin diagnostic report under C:\AFZ\Diagnostics\Jellyfin. Read-only.';strict=$true
    parameters=[ordered]@{type='object';properties=[ordered]@{};required=@();additionalProperties=$false}
  }
)

function Invoke-Tool {
  param([string]$Name,$Args)
  Write-AgentLog "tool=$Name"
  switch ($Name) {
    'afz_system_status' { return Tool-SystemStatus }
    'afz_read_file' { return Tool-ReadFile $Args }
    'afz_list_files' { return Tool-ListFiles $Args }
    'afz_search_files' { return Tool-FileSearch $Args }
    'jellyfin_public_info' { return Tool-JellyfinPublicInfo }
    'jellyfin_regression_forensic' { return Tool-JellyfinForensic }
    'jellyfin_user_views' { return Tool-JellyfinUserViews $Args }
    'jellyfin_recent_diagnostic_report' { return Tool-JellyfinRecentReport }
    default { throw "Tool not allowlisted: $Name" }
  }
}

function Invoke-OpenAIResponse {
  param($Body)
  $headers = @{Authorization="Bearer $OpenAIKey";'Content-Type'='application/json'}
  $json = $Body | ConvertTo-Json -Depth 40 -Compress
  return Invoke-RestMethod -Method Post -Uri 'https://api.openai.com/v1/responses' -Headers $headers -Body $json -TimeoutSec 180
}

function Get-ResponseText {
  param($Response)
  $parts = @()
  foreach ($item in @($Response.output)) {
    if ($item.type -eq 'message') {
      foreach ($content in @($item.content)) {
        if ($content.type -eq 'output_text' -and $content.text) { $parts += [string]$content.text }
      }
    }
  }
  return ($parts -join "`n")
}

$ProspectEngineModule = Join-Path $AgentRoot 'prospect-engine\ProspectEngine.ps1'
if (-not (Test-Path -LiteralPath $ProspectEngineModule -PathType Leaf)) { throw "Prospect Engine module missing: $ProspectEngineModule" }
. $ProspectEngineModule

$AgentInstructions = @'
You are the AFZ private operations agent running beside Windows-main. Use the typed tools to inspect live state; tool results are authoritative. Do not say a file, backup, database, service, or Jellyfin view is unavailable until you have tried an applicable read-only tool. Never request or expose passwords, API keys, authentication tokens, cookies, credentials, or secrets. The v1 registry is deliberately read-only. Do not imply a mutation was executed. For Jellyfin/TorBox regressions, prefer jellyfin_regression_forensic and jellyfin_user_views, then use the allowlisted file tools for targeted follow-up. Preserve media, databases, library IDs, services, and active work. If a mutation is required, identify the exact minimal reversible change and return APPROVAL_REQUIRED with the evidence. Do not use OneDrive or SharePoint as an execution or state bus.
'@

function Invoke-Agent {
  param([string]$Prompt,[string]$Project,[string]$Processor)
  $model = Get-Model $Processor $Prompt
  $trace = @()
  $response = Invoke-OpenAIResponse ([ordered]@{
    model=$model
    instructions=$AgentInstructions
    input="Project: $Project`nUser request: $Prompt"
    tools=$ToolDefinitions
    tool_choice='auto'
    parallel_tool_calls=$false
  })

  for ($round=0; $round -lt 10; $round++) {
    $calls = @($response.output | Where-Object { $_.type -eq 'function_call' })
    if ($calls.Count -eq 0) {
      return [ordered]@{
        ok=$true
        state='DONE'
        model=$model
        answer=(Get-ResponseText $response)
        responseId=$response.id
        executionBroker='afz-typed-readonly-tools'
        toolTrace=$trace
      }
    }

    $outputs = @()
    foreach ($call in $calls) {
      $args = [pscustomobject]@{}
      if ($call.arguments) {
        try { $args = $call.arguments | ConvertFrom-Json } catch {}
      }
      try {
        $toolResult = Invoke-Tool ([string]$call.name) $args
        $trace += [pscustomobject][ordered]@{name=$call.name;ok=$true}
        $outputText = $toolResult | ConvertTo-Json -Depth 25 -Compress
      } catch {
        $trace += [pscustomobject][ordered]@{name=$call.name;ok=$false;error=$_.Exception.Message}
        $outputText = ([ordered]@{ok=$false;error=$_.Exception.Message} | ConvertTo-Json -Compress)
      }
      $outputs += [ordered]@{type='function_call_output';call_id=$call.call_id;output=$outputText}
    }

    $response = Invoke-OpenAIResponse ([ordered]@{
      model=$model
      instructions=$AgentInstructions
      previous_response_id=$response.id
      input=$outputs
      tools=$ToolDefinitions
      tool_choice='auto'
      parallel_tool_calls=$false
    })
  }

  return [ordered]@{ok=$false;state='FAILED';model=$model;error='Tool loop exceeded 10 rounds';toolTrace=$trace}
}

function Get-UiHtml {
  $file = Join-Path $AgentRoot 'AFZ-Agent-UI.html'
  if (Test-Path -LiteralPath $file) { return Get-Content -LiteralPath $file -Raw }
  return '<!doctype html><html><body><h1>AFZ OpenAI Agent</h1><p>UI file missing.</p></body></html>'
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
if ($BindHost -and $BindHost -ne '127.0.0.1') { $listener.Prefixes.Add("http://$BindHost`:$Port/") }
$listener.Start()
Write-AgentLog "START version=2.0.0 port=$Port bind=$BindHost prospectEngine=enabled"

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      if (-not (Test-ClientAllowed $ctx)) {
        $deniedIp = Get-RemoteIp $ctx
        Write-AgentLog "DENY client=$deniedIp method=$($ctx.Request.HttpMethod) path=$($ctx.Request.Url.AbsolutePath)"
        Send-Json $ctx 403 @{
          ok=$false
          error='client not allowlisted'
          clientIp=$deniedIp
          guidance='Authorize this exact Tailscale client IP in allowed-clients.txt.'
        }
        continue
      }
      if ($ctx.Request.HttpMethod -eq 'OPTIONS') { Send-Json $ctx 200 @{ok=$true}; continue }
      $path = $ctx.Request.Url.AbsolutePath.TrimEnd('/')

      if ($path -eq '') {
        Send-Text $ctx 200 'text/html; charset=utf-8' (Get-UiHtml)
        continue
      }
      if ($path -eq '/health') {
        Send-Json $ctx 200 [ordered]@{
          ok=$true;service='AFZ-OpenAI-Agent';version='2.0.0';mode='typed-ops-plus-prospect-engine';onedriveRequired=$false
          prospectEngine='/prospects';prospectPersistence='server-local';outlookSendEnabled=$false
          modelLuna=$ModelLuna;modelSol=$ModelSol;time=(Get-Date -Format o)
        }
        continue
      }
      if ($path -eq '/api/request' -and $ctx.Request.HttpMethod -eq 'POST') {
        $req = Read-JsonBody $ctx
        $prompt = [string]$req.prompt
        if ([string]::IsNullOrWhiteSpace($prompt)) { Send-Json $ctx 400 @{ok=$false;error='prompt required'}; continue }
        $project = 'AFZ-General'; if ($req.project) { $project=[string]$req.project }
        $processor = 'auto'; if ($req.processor) { $processor=[string]$req.processor }
        $id = [guid]::NewGuid().ToString('n')
        $Jobs[$id] = [ordered]@{id=$id;state='PROCESSING';createdAt=(Get-Date -Format o);project=$project}
        Write-AgentLog "request-start id=$id project=$project processor=$processor"
        try {
          $result = Invoke-Agent $prompt $project $processor
          $result['id'] = $id
          $Jobs[$id] = $result
          Write-AgentLog "request-done id=$id ok=$($result.ok)"
          Send-Json $ctx 200 $result
        } catch {
          $fail = [ordered]@{ok=$false;id=$id;state='FAILED';error=$_.Exception.Message}
          $Jobs[$id] = $fail
          Write-AgentLog "request-failed id=$id error=$($_.Exception.Message)"
          Send-Json $ctx 500 $fail
        }
        continue
      }
      if ($path -eq '/api/request-status' -and $ctx.Request.HttpMethod -eq 'POST') {
        $req = Read-JsonBody $ctx
        $id = [string]$req.id
        if ($Jobs.ContainsKey($id)) { Send-Json $ctx 200 $Jobs[$id] }
        else { Send-Json $ctx 404 @{ok=$false;state='UNKNOWN';error='request id not found'} }
        continue
      }
      if (Invoke-ProspectEngineRoute $ctx $path) { continue }
      Send-Json $ctx 404 @{ok=$false;error='not found'}
    } catch {
      try { Send-Json $ctx 500 @{ok=$false;error=$_.Exception.Message} } catch {}
    }
  }
}
finally {
  try { $listener.Stop() } catch {}
  try { $listener.Close() } catch {}
  Write-AgentLog 'STOP'
}
