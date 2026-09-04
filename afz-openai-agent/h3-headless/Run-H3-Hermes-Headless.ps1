#Requires -Version 5.1
$ErrorActionPreference='Continue'
$env:HERMES_HOME='C:\Users\Faiz\AppData\Local\hermes'
$env:COMPUTERNAME=[Environment]::MachineName
$h='C:\Users\Faiz\AppData\Local\hermes\bin\hermes.exe'
$log='C:\ProgramData\AFZ\H3Headless\hermes-headless-gateway.log'

function Log([string]$m){
  Add-Content -LiteralPath $log -Value ((Get-Date -Format o)+' '+$m) -Encoding UTF8
}

if([Environment]::MachineName -ne 'DESKTOP-H3R6CQN'){Log 'WRONG_HOST';exit 20}
if(-not(Test-Path -LiteralPath $h -PathType Leaf)){Log 'HERMES_MISSING';exit 21}

$auth=(& $h auth status openai-codex 2>&1|Out-String)
if($auth -notmatch 'logged in'){Log 'OPENAI_CODEX_AUTH_NOT_READY';exit 22}

for($i=0;$i -lt 60;$i++){
  try{$null=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3;break}
  catch{Start-Sleep -Seconds 2}
}
try{$null=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3}
catch{Log 'OLLAMA_NOT_READY';exit 23}

$status=(& $h gateway status 2>&1|Out-String)
if($status -match '(?i)running' -and $status -match '(?i)PID'){
  Log 'GATEWAY_ALREADY_RUNNING'
  exit 0
}

Log 'GATEWAY_RUN_START'
& $h gateway run *>> $log
$ec=$LASTEXITCODE
Log ('GATEWAY_RUN_EXIT='+$ec)
exit $ec
