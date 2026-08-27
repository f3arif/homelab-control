#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$Port=8797,
  [string]$BindHost='100.70.25.8'
)
$ErrorActionPreference='Stop'
$allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
$logRoot='C:\ProgramData\AFZ\OpenAIAgent\logs'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
function Log([string]$m){Add-Content -LiteralPath (Join-Path $logRoot 'control.log') -Value "$(Get-Date -Format o) $m" -Encoding UTF8}
function Get-AllowedClients{$ips=@('127.0.0.1','::1');if(Test-Path $allowFile){$ips+=@(Get-Content -LiteralPath $allowFile|ForEach-Object {$_.Trim()}|Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'})};return @($ips|Sort-Object -Unique)}
function Get-RemoteIp($ctx){$a=$ctx.Request.RemoteEndPoint.Address;try{if($a.IsIPv4MappedToIPv6){return $a.MapToIPv4().ToString()}}catch{};return $a.ToString()}
function Send-Json($ctx,[int]$status,$obj){if($obj -eq '[ordered]@' -and $args.Count -gt 0){$obj=$args[0]};$json=$obj|ConvertTo-Json -Depth 10 -Compress;$b=[Text.Encoding]::UTF8.GetBytes($json);$ctx.Response.StatusCode=$status;$ctx.Response.ContentType='application/json; charset=utf-8';$ctx.Response.Headers['Cache-Control']='no-store';$ctx.Response.Headers['Access-Control-Allow-Origin']='*';$ctx.Response.Headers['Access-Control-Allow-Headers']='Content-Type';$ctx.Response.Headers['Access-Control-Allow-Methods']='GET,POST,OPTIONS';$ctx.Response.ContentLength64=$b.Length;$ctx.Response.OutputStream.Write($b,0,$b.Length);$ctx.Response.Close()}
function Send-Html($ctx,[string]$html){$b=[Text.Encoding]::UTF8.GetBytes($html);$ctx.Response.StatusCode=200;$ctx.Response.ContentType='text/html; charset=utf-8';$ctx.Response.Headers['Cache-Control']='no-store';$ctx.Response.ContentLength64=$b.Length;$ctx.Response.OutputStream.Write($b,0,$b.Length);$ctx.Response.Close()}
function Read-Json($ctx){$r=New-Object IO.StreamReader($ctx.Request.InputStream,$ctx.Request.ContentEncoding);try{$raw=$r.ReadToEnd()}finally{$r.Dispose()};if([string]::IsNullOrWhiteSpace($raw)){return [pscustomobject]@{}};return $raw|ConvertFrom-Json}
function Start-Update{$task='AFZ OpenAI Agent Updater';$t=Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue;if(-not $t){throw "Scheduled task missing: $task"};Start-ScheduledTask -TaskName $task;return [ordered]@{ok=$true;state='UPDATE_STARTED';task=$task;startedAt=(Get-Date -Format o)}}
function Get-Commit{if(Test-Path $sourceState){try{return [string]((Get-Content $sourceState -Raw|ConvertFrom-Json).remoteSha)}catch{}};return $null}
$listener=New-Object Net.HttpListener;$listener.Prefixes.Add("http://127.0.0.1:$Port/");if($BindHost -and $BindHost -ne '127.0.0.1'){$listener.Prefixes.Add("http://$BindHost`:$Port/")};$listener.Start();Log "START version=1.1.1 port=$Port bind=$BindHost"
try{
  while($listener.IsListening){$ctx=$listener.GetContext();try{
    $ip=Get-RemoteIp $ctx;if(-not ((Get-AllowedClients) -contains $ip)){Send-Json $ctx 403 @{ok=$false;error='client not allowlisted';client=$ip};continue}
    if($ctx.Request.HttpMethod -eq 'OPTIONS'){Send-Json $ctx 200 @{ok=$true};continue};$path=$ctx.Request.Url.AbsolutePath.TrimEnd('/')
    if($path -eq ''){$html=@'
<!doctype html><html><head><meta charset="utf-8"><title>AFZ Agent Control</title><style>body{font:16px system-ui;background:#0b1220;color:#e6edf7;padding:32px}button{padding:12px 18px;border:0;border-radius:9px;background:#185abc;color:white;font-weight:700;cursor:pointer}pre{background:#111b2e;padding:16px;border-radius:10px}</style></head><body><h2>AFZ Agent Control</h2><p>Sync GitHub main and apply AFZ OpenAI Agent policy immediately. Git is not required.</p><button id="u">Update now</button><pre id="o">Ready.</pre><script>const b=document.getElementById('u'),o=document.getElementById('o');b.onclick=async()=>{b.disabled=true;o.textContent='Starting update…';try{const r=await fetch('/api/update-now',{method:'POST'});const j=await r.json();o.textContent=JSON.stringify(j,null,2)+'\n\nThe agent may restart for a few seconds.'}catch(e){o.textContent=e.message}finally{setTimeout(()=>b.disabled=false,4000)}}</script></body></html>
'@;Send-Html $ctx $html;continue}
    if($path -eq '/health' -and $ctx.Request.HttpMethod -eq 'GET'){Send-Json $ctx 200 [ordered]@{ok=$true;service='AFZ-Agent-Control';version='1.1.1';commit=(Get-Commit);transport='github-zip-no-git';updateTask=(Get-ScheduledTask -TaskName 'AFZ OpenAI Agent Updater' -ErrorAction SilentlyContinue).State;time=(Get-Date -Format o)};continue}
    if($path -eq '/api/update-now' -and $ctx.Request.HttpMethod -eq 'POST'){$r=Start-Update;Log "update requested by $ip";Send-Json $ctx 202 $r;continue}
    if($path -eq '/api/control' -and $ctx.Request.HttpMethod -eq 'POST'){$req=Read-Json $ctx;$action=[string]$req.action;if($action -notin @('update-agent','update-openai-agent','pull-agent-now')){Send-Json $ctx 400 @{ok=$false;error='unsupported action'};continue};$r=Start-Update;Log "control action=$action requested by $ip";Send-Json $ctx 202 $r;continue}
    Send-Json $ctx 404 @{ok=$false;error='not found'}
  }catch{try{Send-Json $ctx 500 @{ok=$false;error=$_.Exception.Message}}catch{}}}
}finally{try{$listener.Stop()}catch{};try{$listener.Close()}catch{};Log 'STOP'}
