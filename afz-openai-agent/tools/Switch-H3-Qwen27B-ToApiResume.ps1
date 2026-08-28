#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only switch; host=$env:COMPUTERNAME"}

$repo='f3arif/homelab-control'
$task='AFZ H3 GitHub Direct Benchmark Watcher'
$stateRoot='C:\ProgramData\AFZ\H3GitHubDirect'
$resumePath=Join-Path $stateRoot 'Resume-H3-Qwen27B-Benchmark-ViaGitHubApi.ps1'
$launchOut=Join-Path $stateRoot 'api-resume-launch.stdout.log'
$launchErr=Join-Path $stateRoot 'api-resume-launch.stderr.log'
$stateFile=Join-Path $stateRoot 'state.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Find-Gh {
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}}
  return $null
}
$gh=Find-Gh
if(-not $gh){throw 'GitHub CLI not found on H3.'}
& $gh auth status --hostname github.com *> $null
if($LASTEXITCODE -ne 0){throw 'GitHub CLI is not authenticated on H3.'}

# Permanently pause the obsolete raw-content watcher for this benchmark recovery.
try{Disable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue|Out-Null}catch{}
try{Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue}catch{}

# Kill only obsolete launcher/watcher processes. Never match the benchmark controller.
for($pass=0;$pass -lt 4;$pass++){
  $legacy=@()
  try{
    $legacy=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {
      $_.ProcessId -ne $PID -and [string]$_.CommandLine -match 'H3-GitHub-Direct-Benchmark-Watcher\.ps1|Start-H3-GitHub-Direct-Benchmark\.ps1'
    })
  }catch{}
  if($legacy.Count -eq 0){break}
  foreach($p in $legacy){try{Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
  Start-Sleep -Milliseconds 500
}
$still=@()
try{$still=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {[string]$_.CommandLine -match 'H3-GitHub-Direct-Benchmark-Watcher\.ps1|Start-H3-GitHub-Direct-Benchmark\.ps1'})}catch{}
if($still.Count -gt 0){throw 'Legacy H3 watcher/launcher process is still alive after stop attempts.'}

# Fetch the API-resume runner through authenticated GitHub API, not raw.githubusercontent.com.
$apiPath='repos/'+$repo+'/contents/afz-openai-agent/tools/Resume-H3-Qwen27B-Benchmark-ViaGitHubApi.ps1?ref=main'
$content=& $gh api $apiPath --jq '.content'
if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$content)){throw 'Could not fetch API-resume runner through authenticated GitHub API.'}
$b64=([string]$content)-replace '\s',''
$text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
[IO.File]::WriteAllText($resumePath,$text,$utf8)
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($resumePath,[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw ('API-resume runner parse failure: '+($errors.Message -join '; '))}

Remove-Item $launchOut,$launchErr -Force -ErrorAction SilentlyContinue
Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$resumePath) -RedirectStandardOutput $launchOut -RedirectStandardError $launchErr|Out-Null
Start-Sleep -Seconds 4

$result=[ordered]@{ok=$true;legacyTaskDisabled=$true;resumeLaunched=$true;state=$null;launchStdout=$launchOut;launchStderr=$launchErr}
if(Test-Path $stateFile){try{$result.state=Get-Content $stateFile -Raw|ConvertFrom-Json}catch{}}
$result|ConvertTo-Json -Depth 12 -Compress
