#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only recovery launcher; host=$env:COMPUTERNAME"}
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be 40-char SHA.'}
if($JobId -ne 'afz-blog-qwen35b-vs-ridge27b-20260902-r1'){throw 'Unexpected job id.'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()
$root='C:\ProgramData\AFZ\H3AFZBlogModelComparison'
$runner=Join-Path $root 'Recover-H3-AFZBlog-ModelComparison.ps1'
$wrapper=Join-Path $root 'Invoke-AFZBlog-Recovery-Interactive.ps1'
$stdout=Join-Path $root 'recovery.stdout.log'
$stderr=Join-Path $root 'recovery.stderr.log'
$url="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Recover-H3-AFZBlog-ModelComparison.ps1"
$taskName='AFZ H3 AFZ Blog Comparison Recovery'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root|Out-Null
$tmp=Join-Path $env:TEMP ('afz-blog-recovery-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Blog-Recovery';'Cache-Control'='no-cache'} -TimeoutSec 60
  $text=[IO.File]::ReadAllText($tmp)
  $needle='$utf8=New-Object Text.UTF8Encoding($false)'
  if(-not $text.Contains($needle)){throw 'Recovery compatibility patch anchor missing.'}
  $text=$text.Replace($needle,$needle+"`r`n`$script:gh=`$null")

  # Windows PowerShell treats $Args as the automatic unbound-argument variable.
  # Rename the explicit GitHub CLI argument parameter in the downloaded recovery
  # script so Start-Process can never receive a null/empty -ArgumentList from that
  # collision. GitHub publication is additionally disabled for this recovery pass;
  # local state + the external read-only mirror remain the source of observability.
  $invokeNeedle='function Invoke-Gh([string[]]$Args)'
  if(-not $text.Contains($invokeNeedle)){throw 'Recovery Invoke-Gh compatibility anchor missing.'}
  $text=$text.Replace($invokeNeedle,'function Invoke-Gh([string[]]$GhArgs)')
  $argsNeedle='($Args|ForEach-Object{Quote-Arg ([string]$_)})'
  if(-not $text.Contains($argsNeedle)){throw 'Recovery Invoke-Gh argument-use anchor missing.'}
  $text=$text.Replace($argsNeedle,'($GhArgs|ForEach-Object{Quote-Arg ([string]$_)})')
  $ghInitNeedle='$script:gh=Find-Gh'
  if(-not $text.Contains($ghInitNeedle)){throw 'Recovery GitHub init anchor missing.'}
  $text=$text.Replace($ghInitNeedle,'$script:gh=$null')

  [IO.File]::WriteAllText($tmp,$text,$utf8)
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('Recovery script parse failure: '+($errors.Message -join '; '))}
  [IO.File]::WriteAllText($runner,[IO.File]::ReadAllText($tmp),$utf8)
}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}

$existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($existing -and $existing.State -eq 'Running'){
  [Console]::Out.WriteLine((@{ok=$true;already=$true;job_id=$JobId;status='running';task=$taskName}|ConvertTo-Json -Compress));exit 0
}
Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
$wrapperText=@"
#Requires -Version 5.1
`$ErrorActionPreference='Stop'
try {
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '$runner' -SourceSha '$ExpectedSha' -JobId '$JobId' 1> '$stdout' 2> '$stderr'
  exit `$LASTEXITCODE
} catch {
  (`$_|Out-String)|Add-Content -LiteralPath '$stderr' -Encoding UTF8
  exit 1
}
"@
[IO.File]::WriteAllText($wrapper,$wrapperText,$utf8)
$tokens=$null;$errors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($wrapper,[ref]$tokens,[ref]$errors);if($errors.Count){throw ('Wrapper parse failure: '+($errors.Message -join '; '))}
$userId=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if([string]::IsNullOrWhiteSpace($userId) -or $userId -notmatch '\\'){throw "Unable to resolve H3 user identity: $userId"}
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapper`""
$principal=New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($task.State -notin @('Running','Ready')){throw "Recovery task failed to launch; state=$($task.State)"}
[Console]::Out.WriteLine((@{ok=$true;already=$false;job_id=$JobId;status='launched';task=$taskName;task_state=[string]$task.State;expected_sha=$ExpectedSha;principal=$userId}|ConvertTo-Json -Compress))
exit 0
