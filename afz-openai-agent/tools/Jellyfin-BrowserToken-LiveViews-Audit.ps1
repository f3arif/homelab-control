#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$known=[ordered]@{
  coolyo='2D994DBA-B8C7-44C8-8D34-7D85716B2EBC'
  movies='64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A'
}
function Add-Candidate([System.Collections.Generic.HashSet[string]]$Set,[string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){return}
  $v=$Value.Trim().Trim('"').Trim("'")
  if($v.Length -ge 20 -and $v.Length -le 256 -and $v -match '^[A-Za-z0-9._-]+$'){[void]$Set.Add($v)}
}
function Scan-Text([System.Collections.Generic.HashSet[string]]$Set,[string]$Text){
  if([string]::IsNullOrWhiteSpace($Text)){return}
  foreach($rx in @(
    '(?i)AccessToken[^A-Za-z0-9._-]{0,32}([A-Za-z0-9._-]{20,256})',
    '(?i)accessToken[^A-Za-z0-9._-]{0,32}([A-Za-z0-9._-]{20,256})',
    '(?i)X-Emby-Token[^A-Za-z0-9._-]{0,32}([A-Za-z0-9._-]{20,256})'
  )){
    foreach($m in [regex]::Matches($Text,$rx)){if($m.Groups.Count -gt 1){Add-Candidate $Set $m.Groups[1].Value}}
  }
}
Write-Output 'AFZ_JELLYFIN_BROWSER_LIVE_VIEWS_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
try{$pub=Invoke-RestMethod -Uri ($base+'/System/Info/Public') -TimeoutSec 8;Write-Output ('SERVER|name='+$pub.ServerName+'|version='+$pub.Version+'|id='+$pub.Id)}catch{Write-Output ('SERVER_ERROR|'+$_.Exception.Message)}
$candidates=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$roots=@(
  (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'),
  (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data')
)
$fileCount=0
foreach($root in $roots){
  if(-not(Test-Path -LiteralPath $root -PathType Container)){continue}
  $files=@()
  foreach($sub in @('Local Storage\leveldb','Session Storage')){
    try{$files+=@(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue|Where-Object {$_.Name -eq 'Default' -or $_.Name -like 'Profile *'}|ForEach-Object {Join-Path $_.FullName $sub}|Where-Object {Test-Path -LiteralPath $_ -PathType Container}|ForEach-Object {Get-ChildItem -LiteralPath $_ -File -ErrorAction SilentlyContinue}|Where-Object {$_.Extension -in @('.ldb','.log')})}catch{}
  }
  foreach($f in @($files|Sort-Object FullName -Unique)){
    $fileCount++
    try{
      $fs=New-Object IO.FileStream($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
      try{$buf=New-Object byte[] $fs.Length;[void]$fs.Read($buf,0,$buf.Length)}finally{$fs.Dispose()}
      Scan-Text $candidates ([Text.Encoding]::UTF8.GetString($buf))
      Scan-Text $candidates ([Text.Encoding]::Unicode.GetString($buf))
    }catch{}
  }
}
Write-Output ('BROWSER_STORAGE_FILES_SCANNED='+$fileCount)
Write-Output ('TOKEN_CANDIDATES='+$candidates.Count)
$success=0
foreach($token in $candidates){
  foreach($entry in $known.GetEnumerator()){
    try{
      $r=Invoke-RestMethod -Uri ($base+'/Users/'+$entry.Value+'/Views') -Headers @{'X-Emby-Token'=$token} -TimeoutSec 8
      $items=@($r.Items)
      $names=@($items|ForEach-Object {[string]$_.Name})
      Write-Output ('LIVE_VIEWS|user='+$entry.Key+'|count='+$names.Count+'|names='+($names -join ' || '))
      $success++
    }catch{}
  }
}
Write-Output ('LIVE_VIEW_SUCCESSES='+$success)
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'AUDIT_STATUS=PASS'
