#Requires -Version 5.1
$ErrorActionPreference='Stop'
$current='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$goodRoot='C:\AFZ\MediaCatalog\Backups\JellyfinNativeLibrariesV3-20260824-151412'
$overlayRoot='C:\AFZ\MediaCatalog\Backups\JellyfinOverlayIsolation-20260825-160957'
$coolyo='2D994DBA-B8C7-44C8-8D34-7D85716B2EBC'
$movies='64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A'
$sqlite=(Get-Command sqlite3.exe -ErrorAction Stop).Source

function BackupDb([string]$root){
  if(-not(Test-Path $root)){return $null}
  $p=Join-Path $root 'jellyfin.db'; if(Test-Path $p){return $p}
  $x=Get-ChildItem $root -Recurse -File -Filter jellyfin.db -ErrorAction SilentlyContinue|Select-Object -First 1
  if($x){return $x.FullName};$null
}
function Sql([string]$db,[string]$q){
  if(-not $db -or -not(Test-Path $db)){return @()}
  @(& $sqlite -readonly -noheader -separator '|' $db $q 2>$null)
}
function Snap([string]$db){
  if(-not $db -or -not(Test-Path $db)){return [ordered]@{exists=$false}}
  [ordered]@{
    exists=$true
    db=$db
    collectionFolders=@(Sql $db "select Id||'|'||coalesce(ParentId,'')||'|'||coalesce(TopParentId,'')||'|'||coalesce(Name,'')||'|'||coalesce(Path,'')||'|'||coalesce(PresentationUniqueKey,'') from BaseItems where Type='MediaBrowser.Controller.Entities.CollectionFolder' order by Name;")
    roots=@(Sql $db "select Id||'|'||coalesce(ParentId,'')||'|'||coalesce(TopParentId,'')||'|'||coalesce(Name,'')||'|'||coalesce(Path,'')||'|'||Type from BaseItems where Type in ('MediaBrowser.Controller.Entities.UserRootFolder','MediaBrowser.Controller.Entities.AggregateFolder') order by Type,Name;")
    preferences=@(Sql $db "select UserId||'|'||Kind||'|'||coalesce(Value,'') from Preferences where upper(UserId) in (upper('$coolyo'),upper('$movies')) order by UserId,Kind;")
    permissions=@(Sql $db "select UserId||'|'||Kind||'|'||Value from Permissions where upper(UserId) in (upper('$coolyo'),upper('$movies')) order by UserId,Kind;")
    displayPreferences=@(Sql $db "select UserId||'|'||Id||'|'||coalesce(Client,'')||'|'||coalesce(ShowSidebar,0) from DisplayPreferences where upper(UserId) in (upper('$coolyo'),upper('$movies')) order by UserId,Id;")
  }
}
function RootDefs([string]$root){
  if(-not(Test-Path $root)){return @()}
  $o=New-Object System.Collections.Generic.List[string]
  Get-ChildItem $root -Directory -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{
    $d=$_;[void]$o.Add("DIR|$($d.Name)")
    Get-ChildItem $d.FullName -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension -ieq '.mblink' -or $_.Name -ieq 'options.xml'}|Sort-Object Name|ForEach-Object{
      try{$t=(Get-Content $_.FullName -Raw)-replace "`r?`n",' ';[void]$o.Add("DEF|$($d.Name)|$($_.Name)|$t")}catch{}
    }
  }
  @($o)
}
function BackupRootDefs([string]$root){
  if(-not(Test-Path $root)){return @()}
  $all=New-Object System.Collections.Generic.List[string]
  Get-ChildItem $root -Recurse -Directory -ErrorAction SilentlyContinue|Where-Object{$_.FullName -match '\\root\\default$'}|ForEach-Object{
    RootDefs $_.FullName|ForEach-Object{[void]$all.Add($_)}
  }
  @($all)
}
function WebEvidence([string]$root){
  if(-not(Test-Path $root)){return @()}
  $out=New-Object System.Collections.Generic.List[string]
  Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -ieq 'index.html' -or $_.Extension -in '.js','.html'}|Select-Object -First 500|ForEach-Object{
    $f=$_;$hit=($f.Name -ieq 'index.html')
    if(-not $hit){try{$hit=[bool](Select-String $f.FullName -Pattern 'AFZ|TorBox|Jellyseerr|My Media|Real-Debrid|Bollywood|Stream Now' -Quiet -ErrorAction Stop)}catch{}}
    if($hit){
      try{[void]$out.Add("HASH|$((Get-FileHash $f.FullName -Algorithm SHA256).Hash)|$($f.FullName)")}catch{}
      try{Select-String $f.FullName -Pattern 'AFZ|TorBox|Jellyseerr|My Media|Real-Debrid|Bollywood|Stream Now|<script|script src' -ErrorAction SilentlyContinue|Select-Object -First 80|ForEach-Object{[void]$out.Add("MATCH|$($f.FullName)|L$($_.LineNumber)|$($_.Line.Trim())")}}catch{}
    }
  }
  @($out)
}
function Diffs($a,$b){
  @((Compare-Object @($a) @($b))|ForEach-Object{"$($_.SideIndicator)|$($_.InputObject)"})
}

$good=BackupDb $goodRoot
$overlay=BackupDb $overlayRoot
$cur=Snap $current;$g=Snap $good;$ov=Snap $overlay
$public=$null
try{$j=Invoke-RestMethod 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec 6;$public=[ordered]@{ok=$true;serverName=$j.ServerName;version=$j.Version;id=$j.Id}}catch{$public=[ordered]@{ok=$false;error=$_.Exception.Message}}

$result=[ordered]@{
  ok=$true
  mode='READ_ONLY'
  onedriveUsed=$false
  timestamp=(Get-Date -Format o)
  public=$public
  paths=[ordered]@{currentDb=$current;knownGoodDb=$good;overlayDb=$overlay}
  current=$cur
  knownGood=$g
  overlay=$ov
  diffs=[ordered]@{
    collectionFoldersCurrentVsKnownGood=(Diffs $g.collectionFolders $cur.collectionFolders)
    rootsCurrentVsKnownGood=(Diffs $g.roots $cur.roots)
    preferencesCurrentVsKnownGood=(Diffs $g.preferences $cur.preferences)
    permissionsCurrentVsKnownGood=(Diffs $g.permissions $cur.permissions)
    displayPreferencesCurrentVsKnownGood=(Diffs $g.displayPreferences $cur.displayPreferences)
  }
  rootDefinitions=[ordered]@{
    currentLocal=@(RootDefs 'C:\Users\Faiz\AppData\Local\Jellyfin\root\default')
    currentProgramData=@(RootDefs 'C:\ProgramData\Jellyfin\Server\root\default')
    knownGood=@(BackupRootDefs $goodRoot)
    overlay=@(BackupRootDefs $overlayRoot)
  }
  torboxCanary=[ordered]@{
    localExists=(Test-Path 'C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Stream Now (TorBox)')
    programDataExists=(Test-Path 'C:\ProgramData\Jellyfin\Server\root\default\Stream Now (TorBox)')
    row=@(Sql $current "select Id||'|'||coalesce(ParentId,'')||'|'||coalesce(TopParentId,'')||'|'||Name||'|'||Path||'|'||coalesce(PresentationUniqueKey,'') from BaseItems where upper(Id)=upper('65F35FF2-0D22-DF95-B3A0-C6958823494A');")
  }
  web=[ordered]@{
    current=@(WebEvidence 'C:\Program Files\Jellyfin\Server')
    knownGood=@(WebEvidence $goodRoot)
    overlay=@(WebEvidence $overlayRoot)
  }
}
$result|ConvertTo-Json -Depth 20 -Compress
