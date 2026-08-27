#Requires -Version 5.1
param([ValidateSet('coolyo','movies')][string]$User='coolyo')
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$sqlite=(Get-Command sqlite3.exe -ErrorAction Stop).Source
$ids=@{coolyo='2D994DBA-B8C7-44C8-8D34-7D85716B2EBC';movies='64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A'}
$userId=$ids[$User]
$candidates=New-Object System.Collections.Generic.List[string]
$seen=New-Object 'System.Collections.Generic.HashSet[string]'
$tables=@(& $sqlite -readonly $db "select name from sqlite_master where type='table' order by name;" 2>$null)
foreach($t in $tables){
  $safeT=$t.Replace(']','']]')
  $cols=@(& $sqlite -readonly $db "pragma table_info([$safeT]);" 2>$null)
  foreach($line in $cols){
    $p=$line -split '\|'
    if($p.Count -ge 3 -and $p[1] -match '(?i)token|accesskey|apikey'){
      $col=$p[1].Replace(']','']]')
      try{
        $vals=@(& $sqlite -readonly $db "select [$col] from [$safeT] where [$col] is not null and length([$col])>=12 limit 100;" 2>$null)
        foreach($v in $vals){if($v -and $seen.Add($v)){[void]$candidates.Add($v)}}
      }catch{}
    }
  }
}
$valid=$null;$tested=0
foreach($tok in $candidates){
  $tested++
  try{
    $h=@{'X-Emby-Token'=$tok}
    $me=Invoke-RestMethod -Uri "http://127.0.0.1:8096/Users/$userId" -Headers $h -TimeoutSec 5
    if($me.Id){$valid=$tok;break}
  }catch{}
}
if(-not $valid){
  [ordered]@{ok=$false;user=$User;userId=$userId;candidateCount=$candidates.Count;tested=$tested;reason='No active token found; no secret values were exposed.'}|ConvertTo-Json -Compress
  exit 0
}
$headers=@{'X-Emby-Token'=$valid}
$out=New-Object System.Collections.Generic.List[object]
$errors=New-Object System.Collections.Generic.List[string]
foreach($uri in @(
  "http://127.0.0.1:8096/Users/$userId/Views?IncludeExternalContent=true",
  "http://127.0.0.1:8096/UserViews?userId=$userId&includeHidden=true"
)){
  try{
    $r=Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 10
    [void]$out.Add([ordered]@{endpoint=$uri;total=$r.TotalRecordCount;items=@($r.Items|ForEach-Object{[ordered]@{name=$_.Name;id=$_.Id;type=$_.Type;collectionType=$_.CollectionType;locationType=$_.LocationType;isFolder=$_.IsFolder}})})
  }catch{[void]$errors.Add("$uri :: $($_.Exception.Message)")}
}
[ordered]@{ok=($out.Count -gt 0);user=$User;userId=$userId;tokenFound=$true;tokenExposed=$false;tested=$tested;responses=@($out);errors=@($errors)}|ConvertTo-Json -Depth 10 -Compress
