#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Write-Output 'AFZ_JELLYFIN_VIRTUAL_FOLDER_ROOT_INVENTORY_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
$roots=@(
 'C:\Users\Faiz\AppData\Local\Jellyfin\root\default',
 'C:\ProgramData\Jellyfin\Server\root\default',
 'C:\Windows\System32\config\systemprofile\AppData\Local\Jellyfin\root\default'
)
foreach($root in $roots){
 $exists=Test-Path -LiteralPath $root -PathType Container
 Write-Output ('ROOT|path='+$root+'|exists='+$exists)
 if(-not $exists){continue}
 foreach($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue|Sort-Object Name)){
   $m=@(Get-ChildItem -LiteralPath $d.FullName -Filter '*.mblink' -File -Force -ErrorAction SilentlyContinue)
   $opts=Join-Path $d.FullName 'options.xml'
   Write-Output ('VF_DIR|root='+$root+'|name='+$d.Name+'|mblinkCount='+$m.Count+'|options='+(Test-Path -LiteralPath $opts -PathType Leaf))
   foreach($f in $m){
     $v='';try{$v=([IO.File]::ReadAllText($f.FullName)).Trim()}catch{$v='READ_FAILED'}
     $existsTarget=$false;if($v -and $v -ne 'READ_FAILED'){try{$existsTarget=Test-Path -LiteralPath $v}catch{}}
     Write-Output ('MBLINK|library='+$d.Name+'|file='+$f.Name+'|target='+$v+'|targetExists='+$existsTarget)
   }
 }
}
Write-Output 'STATUS=PASS'
