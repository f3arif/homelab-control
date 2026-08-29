# AFZ_LENOVO_ALLOWED=1
#Requires -Version 5.1
$ErrorActionPreference='Stop'
$worker='C:\ProgramData\AFZ\LenovoDirect\AFZ-Lenovo-Direct-Worker.ps1'
$expected='B89D762864943F775434CCB03752B2507C90077D1F1A2127CEA7163704344BA6'
$marker='AFZ_GITHUB_PORTABLE_CANARY_V1'
if(-not(Test-Path -LiteralPath $worker -PathType Leaf)){throw "Direct worker missing: $worker"}
$text=[IO.File]::ReadAllText($worker)
if($text.Contains($marker)){
  Write-Output 'PATCH_STATE=ALREADY_PRESENT'
}else{
  $sha=(Get-FileHash -Algorithm SHA256 -LiteralPath $worker).Hash.ToUpperInvariant()
  Write-Output ('SHA_BEFORE='+$sha)
  if($sha -ne $expected){throw "Unexpected direct worker SHA: $sha"}
  $backup=$worker+'.before-github-portable-canary-'+(Get-Date -Format 'yyyyMMddTHHmmss')+'.ps1'
  Copy-Item -LiteralPath $worker -Destination $backup -Force
  Write-Output ('BACKUP='+$backup)
  $oldVersion="$Version = '1.2-sleep-control'"
  $newVersion="$Version = '1.3-github-portable-canary'"
  if(-not $text.Contains($oldVersion)){throw 'Version anchor missing'}
  $text=$text.Replace($oldVersion,$newVersion)
  $anchor='function Write-Status([bool]$GatewayOk,[string]$State,[string]$Detail) {'
  if(-not $text.Contains($anchor)){throw 'Function insertion anchor missing'}
  $func=@'
# AFZ_GITHUB_PORTABLE_CANARY_V1
function Invoke-GitHubPortablePowerShell($Payload) {
    $repo=[string]$Payload.repo; $commit=[string]$Payload.commit; $path=[string]$Payload.path; $expectedHash=[string]$Payload.sha256
    $timeoutSec=0; try{$timeoutSec=[int]$Payload.timeout_seconds}catch{throw 'portable timeout invalid'}
    if($repo -ne 'f3arif/homelab-control'){throw 'portable repo not allowlisted'}
    if($commit -notmatch '^[0-9a-fA-F]{40}$'){throw 'portable commit must be exact 40-char SHA'}
    if($path -notmatch '^afz-openai-agent/portable-jobs/[A-Za-z0-9._/-]+\.ps1$' -or $path.Contains('..')){throw 'portable path not allowlisted'}
    if($expectedHash -notmatch '^[0-9a-fA-F]{64}$'){throw 'portable sha256 invalid'}
    if($timeoutSec -lt 5 -or $timeoutSec -gt 300){throw 'portable timeout out of range'}
    $url='https://raw.githubusercontent.com/'+$repo+'/'+$commit+'/'+$path
    $tmp=Join-Path $Base ('portable-'+[guid]::NewGuid().ToString('N')+'.ps1')
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp -TimeoutSec 20 -Headers @{'User-Agent'='AFZ-Lenovo-Direct-Worker'}
        $len=(Get-Item -LiteralPath $tmp).Length
        if($len -lt 1 -or $len -gt 65536){throw ('portable size invalid: '+$len)}
        $actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
        if($actual -ne $expectedHash.ToLowerInvariant()){throw 'portable sha256 mismatch'}
        $head=@(Get-Content -LiteralPath $tmp -TotalCount 20)
        foreach($required in @('^#\s*AFZ_PORTABLE_WINDOWS=1\s*$','^#\s*AFZ_LENOVO_ALLOWED=1\s*$','^#\s*AFZ_DIRECT_PORTABLE=1\s*$','^#\s*AFZ_DIRECT_RISK=A0\s*$')){
            if(-not($head -match $required)){throw ('portable marker missing: '+$required)}
        }
        $tokens=$null;$parseErrors=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$parseErrors)
        if(@($parseErrors).Count -gt 0){throw ('portable parse failed: '+((@($parseErrors)|ForEach-Object{$_.Message}) -join ' | '))}
        $psi=New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName='powershell.exe'
        $psi.Arguments="-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tmp`""
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        $p=New-Object System.Diagnostics.Process;$p.StartInfo=$psi
        if(-not $p.Start()){throw 'portable process start failed'}
        $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit($timeoutSec*1000)){
            try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}
            throw 'portable process timed out'
        }
        $stdout=[string]$outTask.Result;$stderr=[string]$errTask.Result
        if($stdout.Length -gt 2048){$stdout=$stdout.Substring(0,2048)+'...[truncated]'}
        if($stderr.Length -gt 2048){$stderr=$stderr.Substring(0,2048)+'...[truncated]'}
        return @{worker='lenovo-direct-1';action='portable-powershell-github';repo=$repo;commit=$commit;path=$path;sha256=$actual;timeout_seconds=$timeoutSec;exit_code=[int]$p.ExitCode;stdout=$stdout;stderr=$stderr;computer=$env:COMPUTERNAME;direct_transport=$true}
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
'@
  $text=$text.Replace($anchor,$func+"`r`n"+$anchor)
  $old=@'
                    } else {
                        Post-Afz '/complete' @{job_id=$CurrentJob;ok=$false;result=@{};error='action not allowlisted by Lenovo direct worker'} | Out-Null
                    }
'@
  if(-not $text.Contains($old)){throw 'Action tail anchor missing'}
  $new=@'
                    } elseif ($action -eq 'portable-powershell-github') {
                        try {
                            $result=Invoke-GitHubPortablePowerShell $job.payload
                            $ok=([int]$result.exit_code -eq 0)
                            Post-Afz '/complete' @{job_id=$CurrentJob;ok=$ok;result=$result;error=$(if($ok){$null}else{'portable PowerShell returned nonzero exit'})} | Out-Null
                        } catch {
                            Post-Afz '/complete' @{job_id=$CurrentJob;ok=$false;result=@{};error=('portable-powershell-github failed: '+$_.Exception.Message)} | Out-Null
                        }
                    } else {
                        Post-Afz '/complete' @{job_id=$CurrentJob;ok=$false;result=@{};error='action not allowlisted by Lenovo direct worker'} | Out-Null
                    }
'@
  $text=$text.Replace($old,$new)
  $tmp=$worker+'.github-portable.new'
  [IO.File]::WriteAllText($tmp,$text,[Text.UTF8Encoding]::new($true))
  try{
    $tokens=$null;$errs=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errs)
    Write-Output ('PARSE_ERRORS='+@($errs).Count)
    if(@($errs).Count -gt 0){throw ('new worker parse failed: '+((@($errs)|ForEach-Object{$_.Message}) -join ' | '))}
    Move-Item -LiteralPath $tmp -Destination $worker -Force
  }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
  Write-Output 'PATCH_STATE=APPLIED'
}
$after=(Get-FileHash -Algorithm SHA256 -LiteralPath $worker).Hash.ToUpperInvariant()
Write-Output ('SHA_AFTER='+$after)
try{Stop-ScheduledTask -TaskName 'AFZ Lenovo Direct Worker' -ErrorAction SilentlyContinue}catch{}
Start-Sleep -Milliseconds 500
Start-ScheduledTask -TaskName 'AFZ Lenovo Direct Worker' -ErrorAction Stop
Start-Sleep -Seconds 3
$task=Get-ScheduledTask -TaskName 'AFZ Lenovo Direct Worker' -ErrorAction Stop
Write-Output ('TASK_STATE='+$task.State)
$status='C:\ProgramData\AFZ\LenovoDirect\status.json'
if(Test-Path -LiteralPath $status){Write-Output ('STATUS='+(Get-Content -LiteralPath $status -Raw))}
if(-not([IO.File]::ReadAllText($worker).Contains($marker))){throw 'portable marker absent after patch'}
Write-Output 'RESULT=PASS_LENOVO_DIRECT_GITHUB_PORTABLE_CANARY_WORKER_PATCH'
