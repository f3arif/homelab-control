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
New-Item -ItemType Directory -Force -Path $StateRoot,$LogRoot | Out-Null

function Write-AgentLog([string]$Message) {
  $line = "$(Get-Date -Format o) $Message"
  Add-Content -LiteralPath (Join-Path $LogRoot 'agent.log') -Value $line -Encoding UTF8
}

function Get-OpenAIKey {
  if ($env:OPENAI_API_KEY) { return $env:OPENAI_API_KEY }
  if (-not (Test-Path $KeyFile)) { throw "OpenAI key not configured: $KeyFile" }
  $protected = [IO.File]::ReadAllBytes($KeyFile)
  $bytes = [Security.Cryptography.ProtectedData]::Unprotect($protected,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
  return [Text.Encoding]::UTF8.GetString($bytes)
}

$OpenAIKey = Get-OpenAIKey
$Jobs = [hashtable]::Synchronized(@{})
$AllowedClients = @('127.0.0.1','::1','100.70.25.8','100.71.26.69')

function Send-Json($Context, [int]$Status, $Object) {
  $json = $Object | ConvertTo-Json -Depth 30 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = 'application/json; charset=utf-8'
  $Context.Response.Headers['Cache-Control'] = 'no-store'
  $Context.Response.Headers['Access-Control-Allow-Origin'] = '*'
  $Context.Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
  $Context.Response.Headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
  $Context.Response.ContentLength64 = $bytes.Length
  $Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
  $Context.Response.Close()
}

function Read-JsonBody($Context) {
  $reader = New-Object IO.StreamReader($Context.Request.InputStream,$Context.Request.ContentEncoding)
  $raw = $reader.ReadToEnd()
  $reader.Dispose()
  if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
  return $raw | ConvertFrom-Json
}

function Test-ClientAllowed($Context) {
  $ip = $Context.Request.RemoteEndPoint.Address.ToString()
  return $AllowedClients -contains $ip
}

function Get-Model([string]$Processor,[string]$Prompt) {
  if ($Processor -eq 'sol') { return $ModelSol }
  if ($Processor -eq 'luna') { return $ModelLuna }
  if ($Processor -eq 'auto') {
    if ($Prompt -match '(?i)diagnos|root cause|forensic|compare|architect|complex|regression|investigate') { return $ModelSol }
    return $ModelLuna
  }
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

function Resolve-SafePath([string]$Root,[string]$RelativePath) {
  if (-not $RootMap.ContainsKey($Root)) { throw "Unknown root alias: $Root" }
  $base = [IO.Path]::GetFullPath($RootMap[$Root]).TrimEnd('\')
  $candidate = [IO.Path]::GetFullPath((Join-Path $base $RelativePath))
  if ($candidate -ne $base -and -not $candidate.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Path escapes allowed root'
  }
  return $candidate
}

function Tool-SystemStatus($Args) {
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
  $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
  $ramUsed = [math]::Round(($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/1MB,2)
  $ramTotal = [math]::Round($os.TotalVisibleMemorySize/1MB,2)
  [ordered]@{
    computer=$env:COMPUTERNAME
    cpuPercent=[math]::Round($cpu.Average,1)
    ramUsedGb=$ramUsed
    ramTotalGb=$ramTotal
    ramPercent=[math]::Round(($ramUsed/$ramTotal)*100,1)
    diskFreeGb=[math]::Round($drive.FreeSpace/1GB,2)
    diskTotalGb=[math]::Round($drive.Size/1GB,2)
    jellyfinRunning=[bool](Get-Process jellyfin -ErrorAction SilentlyContinue)
    timestamp=(Get-Date -Format o)
  }
}

function Tool-ReadFile($Args) {
  $path = Resolve-SafePath ([string]$Args.root) ([string]$Args.path)
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "File not found: $path" }
  $max = [math]::Min([math]::Max([int]$Args.max_chars,1000),60000)
  $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
  $truncated = $text.Length -gt $max
  if ($truncated) { $text = $text.Substring(0,$max) }
  [ordered]@{root=$Args.root;path=$Args.path;fullPath=$path;chars=$text.Length;truncated=$truncated;text=$text}
}

function Tool-ListFiles($Args) {
  $path = Resolve-SafePath ([string]$Args.root) ([string]$Args.path)
  if (-not (Test-Path -LiteralPath $path)) { throw "Path not found: $path" }
  $depth = [math]::Min([math]::Max([int]$Args.depth,0),3)
  $limit = [math]::Min([math]::Max([int]$Args.limit,1),300)
  $items = if ($depth -gt 0) { Get-ChildItem -LiteralPath $path -Force -Recurse -Depth $depth -ErrorAction SilentlyContinue } else { Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  @($items | Select-Object -First $limit | ForEach-Object {
    [ordered]@{name=$_.Name;fullName=$_.FullName;directory=$_.PSIsContainer;length=if($_.PSIsContainer){$null}else{$_.Length};modified=$_.LastWriteTimeUtc.ToString('o')}
  })
}

function Tool-FileSearch($Args) {
  $path = Resolve-SafePath ([string]$Args.root) ([string]$Args.path)
  $pattern = [string]$Args.pattern
  if ($pattern.Length -gt 200) { throw 'Search pattern too long' }
  $limit = [math]::Min([math]::Max([int]$Args.limit,1),200)
  $files = Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1000
  $hits = New-Object System.Collections.Generic.List[object]
  foreach ($f in $files) {
    try {
      Select-String -LiteralPath $f.FullName -Pattern $pattern -SimpleMatch -ErrorAction Stop | Select-Object -First 10 | ForEach-Object {
        if ($hits.Count -lt $limit) { [void]$hits.Add([ordered]@{file=$f.FullName;line=$_.LineNumber;text=$_.Line.Trim()}) }
      }
    } catch {}
    if ($hits.Count -ge $limit) { break }
  }
  @($hits)
}

function Tool-JellyfinPublicInfo($Args) {
  try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec 8
    [ordered]@{ok=$true;serverName=$r.ServerName;version=$r.Version;id=$r.Id;startupWizardCompleted=$r.StartupWizardCompleted}
  } catch {
    [ordered]@{ok=$false;error=$_.Exception.Message}
  }
}

function Tool-JellyfinForensic($Args) {
  $script = Join-Path $AgentRoot 'tools\Jellyfin-Regression-Forensic.ps1'
  if (-not (Test-Path $script)) { throw "Missing forensic tool: $script" }
  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script 2>&1 | Out-String
  try { return ($raw | ConvertFrom-Json) } catch { return [ordered]@{ok=$false;parseError=$_.Exception.Message;raw=$raw.Substring(0,[math]::Min($raw.Length,50000))} }
}

function Tool-JellyfinUserViews($Args) {
  $script = Join-Path $AgentRoot 'tools\Jellyfin-UserViews-ReadOnly.ps1'
  if (-not (Test-Path $script)) { throw "Missing views tool: $script" }
  $user = [string]$Args.user
  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -User $user 2>&1 | Out-String
  try { return ($raw | ConvertFrom-Json) } catch { return [ordered]@{ok=$false;parseError=$_.Exception.Message;raw=$raw.Substring(0,[math]::Min($raw.Length,30000))} }
}

function Tool-JellyfinRecentReport($Args) {
  $root='C:\AFZ\Diagnostics\Jellyfin'
  if(-not (Test-Path $root)){ return [ordered]@{ok=$false;reason='diagnostics directory missing'} }
  $f=Get-ChildItem $root -File -Filter '*.txt' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if(-not $f){ return [ordered]@{ok=$false;reason='no reports'} }
  $text=Get-Content $f.FullName -Raw
  $max=50000
  [ordered]@{ok=$true;file=$f.FullName;modified=$f.LastWriteTimeUtc.ToString('o');truncated=($text.Length -gt $max);text=$text.Substring(0,[math]::Min($text.Length,$max))}
}

$ToolDefinitions = @(
  [ordered]@{type='function';name='afz_system_status';description='Read current Windows-main CPU, RAM, disk and Jellyfin process status. Read-only.';strict=$true;parameters=[ordered]@{type='object';properties=[ordered]@{};required=@();additionalProperties=$false}},
  [ordered]@{type='function';name='afz_read_file';description='Read a text file from an explicitly allowlisted AFZ/Jellyfin root. Read-only. Never returns files outside allowed roots.';strict=$true;parameters=[ordered]@{type='object';properties=[ordered]@{root=[ordered]@{type='string';enum=@('jellyfin-local','jellyfin-programdata','jellyfin-web','afz-backups','afz-diagnostics','torbox-media')};path=[ordered]@{type='string'};max_chars=[ordered]@{type='integer';minimum=1000;maximum=60000}};required=@('root','path','max_chars');additionalProperties=$false}},
  [ordered]@{type='function';name='afz_list_files';description='List files/directories under an allowlisted AFZ/Jellyfin root. Read-only.';strict=$true;parameters=[ordered]@{type='object';properties=[ordered]@{root=[ordered]@{type='string';enum=@('jellyfin-local','jellyfin-programdata','jellyfin-web','afz-backups','afz-diagnostics','torbox-media')};path=[ordered]@{type='string'};depth=[ordered]@{type='integer';minimum=0;maximum=3};limit=[ordered]@{type='integer';minimum=1;maximum=300}};required=@('root','path','depth','limit');additionalProperties=$false}},
  [ordered]@{type='function';name='afz_search_files';description='Search text files beneath an allowlisted AFZ/Jellyfin root for an exact text pattern. Read-only.';strict=$true;parameters=[ordered]@{type='object';properties=[ordered]@{root=[ordered]@{type='string';enum=@('jellyfin-local','jellyfin-programdata','jellyfin-web','afz-backups','afz-diagnostics')};path=[ordered]@{type='string'};pattern=[ordered]@{type='string'};limit=[ordered]@{type='integer';minimum=1;maximum=200}};required=@('root','path','pattern','limit');additionalProperties=$false}},
  [ordered]@{type='function';name='jellyfin_public_info';description='Read Jellyfin public server identity/version from localhost:8096. Read-only.';strict=$true;parameters=[ordered]@{type='object';properties=[ordered]@{};required=@();additionalProperties=$false}},
  [ordered]@{type='function';name='jellyfin_regression_forensic';description='Run the fixed read-only Jellyfin native-library regression comparison against the known-good V3 and overlay-isolation backups. Does not stop Jellyfin, write the DB, scan media, or use OneDrive.';strict=$true;parameters=[ordered]@{type='object';properties=[ordered]@{};required=@();additionalProperties=$false}},
  [ordered]@{type='function';name='jellyfin_user_views';description='Read the live Jellyfin views returned for coolyo or movies, using a locally discovered active token without exposing the token. Read-only.';strict=$true;parameters=[ordered]@{type='object';properties=[ordered]@{user=[ordered]@{type='string';enum=@('coolyo','movies')}};required=@('user');additionalProperties=$false}},
  [ordered]@{type='function';name='jellyfin_recent_diagnostic_report';description='Read the most recent local Jellyfin diagnostic report under C:\AFZ\Diagnostics\Jellyfin. Read-only and local only.';strict=$true;parameters=[ordered]@{type='object';properties=[ordered]@{};required=@();additionalProperties=$false}}
)

function Invoke-Tool([string]$Name,$Args) {
  Write-AgentLog "tool=$Name"
  switch ($Name) {
    'afz_system_status' { Tool-SystemStatus $Args }
    'afz_read_file' { Tool-ReadFile $Args }
    'afz_list_files' { Tool-ListFiles $Args }
    'afz_search_files' { Tool-FileSearch $Args }
    'jellyfin_public_info' { Tool-JellyfinPublicInfo $Args }
    'jellyfin_regression_forensic' { Tool-JellyfinForensic $Args }
    'jellyfin_user_views' { Tool-JellyfinUserViews $Args }
    'jellyfin_recent_diagnostic_report' { Tool-JellyfinRecentReport $Args }
    default { throw "Tool not allowlisted: $Name" }
  }
}

function Invoke-OpenAIResponse($Body) {
  $headers = @{Authorization="Bearer $OpenAIKey";'Content-Type'='application/json'}
  $json = $Body | ConvertTo-Json -Depth 40 -Compress
  Invoke-RestMethod -Method Post -Uri 'https://api.openai.com/v1/responses' -Headers $headers -Body $json -TimeoutSec 180
}

function Get-ResponseText($Response) {
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Response.output)) {
    if ($item.type -eq 'message') {
      foreach ($c in @($item.content)) {
        if ($c.type -eq 'output_text' -and $c.text) { [void]$parts.Add([string]$c.text) }
      }
    }
  }
  return ($parts -join "`n")
}

$AgentInstructions = @'
You are the AFZ private operations agent running beside the user's Windows-main host. Use the provided typed tools to inspect live state. Tool results are authoritative. Do not claim a file, database, backup, service, or view is unavailable until you have tried an applicable read-only tool. Never request or expose secrets, authentication tokens, API keys, passwords, cookies, or credentials. This v1 tool registry is intentionally READ-ONLY: do not propose arbitrary shell commands as if they were executed. For Jellyfin regressions, prefer jellyfin_regression_forensic, jellyfin_user_views, and the allowlisted file tools. Preserve media, databases, library IDs, services, and existing work. If a mutation is required, identify the exact minimal reversible change and state APPROVAL_REQUIRED; do not pretend it was executed. Never use OneDrive/SharePoint as an execution bus.
'@

function Invoke-Agent([string]$Prompt,[string]$Project,[string]$Processor) {
  $model = Get-Model $Processor $Prompt
  $body = [ordered]@{
    model=$model
    instructions=$AgentInstructions
    input="Project: $Project`nUser request: $Prompt"
    tools=$ToolDefinitions
    tool_choice='auto'
    parallel_tool_calls=$false
  }
  $response = Invoke-OpenAIResponse $body
  $trace = New-Object System.Collections.Generic.List[object]
  for ($round=0; $round -lt 10; $round++) {
    $calls = @($response.output | Where-Object { $_.type -eq 'function_call' })
    if ($calls.Count -eq 0) {
      return [ordered]@{ok=$true;state='DONE';model=$model;answer=(Get-ResponseText $response);responseId=$response.id;executionBroker='afz-typed-readonly-tools';toolTrace=@($trace)}
    }
    $outputs = New-Object System.Collections.Generic.List[object]
    foreach ($call in $calls) {
      try { $args = if($call.arguments){$call.arguments | ConvertFrom-Json}else{@{}} } catch { $args=@{} }
      try {
        $result = Invoke-Tool ([string]$call.name) $args
        [void]$trace.Add([ordered]@{name=$call.name;ok=$true})
        $outText = $result | ConvertTo-Json -Depth 25 -Compress
      } catch {
        [void]$trace.Add([ordered]@{name=$call.name;ok=$false;error=$_.Exception.Message})
        $outText = ([ordered]@{ok=$false;error=$_.Exception.Message}) | ConvertTo-Json -Compress
      }
      [void]$outputs.Add([ordered]@{type='function_call_output';call_id=$call.call_id;output=$outText})
    }
    $response = Invoke-OpenAIResponse ([ordered]@{
      model=$model
      previous_response_id=$response.id
      input=@($outputs)
      tools=$ToolDefinitions
      tool_choice='auto'
      parallel_tool_calls=$false
    })
  }
  return [ordered]@{ok=$false;state='FAILED';model=$model;error='tool loop exceeded 10 rounds';toolTrace=@($trace)}
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
if ($BindHost -and $BindHost -ne '127.0.0.1') { $listener.Prefixes.Add("http://$BindHost`:$Port/") }
$listener.Start()
Write-AgentLog "START port=$Port bind=$BindHost"

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      if (-not (Test-ClientAllowed $ctx)) { Send-Json $ctx 403 @{ok=$false;error='client not allowlisted'}; continue }
      if ($ctx.Request.HttpMethod -eq 'OPTIONS') { Send-Json $ctx 200 @{ok=$true}; continue }
      $path = $ctx.Request.Url.AbsolutePath.TrimEnd('/')
      if ($path -eq '' -or $path -eq '/health') {
        Send-Json $ctx 200 @{ok=$true;service='AFZ-OpenAI-Agent';version='1.0.0';mode='typed-readonly';onedriveRequired=$false;modelLuna=$ModelLuna;modelSol=$ModelSol;time=(Get-Date -Format o)}
        continue
      }
      if ($path -eq '/api/request' -and $ctx.Request.HttpMethod -eq 'POST') {
        $req = Read-JsonBody $ctx
        $prompt = [string]$req.prompt
        if ([string]::IsNullOrWhiteSpace($prompt)) { Send-Json $ctx 400 @{ok=$false;error='prompt required'}; continue }
        $project = if($req.project){[string]$req.project}else{'AFZ-General'}
        $processor = if($req.processor){[string]$req.processor}else{'auto'}
        $id = [guid]::NewGuid().ToString('n')
        $Jobs[$id] = @{id=$id;state='PROCESSING';createdAt=(Get-Date -Format o);project=$project}
        try {
          $result = Invoke-Agent $prompt $project $processor
          $result.id=$id
          $Jobs[$id]=$result
          Send-Json $ctx 200 $result
        } catch {
          $fail=[ordered]@{ok=$false;id=$id;state='FAILED';error=$_.Exception.Message}
          $Jobs[$id]=$fail
          Write-AgentLog "request-failed id=$id error=$($_.Exception.Message)"
          Send-Json $ctx 500 $fail
        }
        continue
      }
      if ($path -eq '/api/request-status' -and $ctx.Request.HttpMethod -eq 'POST') {
        $req=Read-JsonBody $ctx
        $id=[string]$req.id
        if($Jobs.ContainsKey($id)){ Send-Json $ctx 200 $Jobs[$id] } else { Send-Json $ctx 404 @{ok=$false;state='UNKNOWN';error='request id not found'} }
        continue
      }
      Send-Json $ctx 404 @{ok=$false;error='not found'}
    } catch {
      try { Send-Json $ctx 500 @{ok=$false;error=$_.Exception.Message} } catch {}
    }
  }
} finally {
  $listener.Stop(); $listener.Close(); Write-AgentLog 'STOP'
}
