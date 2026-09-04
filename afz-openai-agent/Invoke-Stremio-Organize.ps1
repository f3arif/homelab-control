#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('audit','apply')]
  [string]$Action='audit',
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'

$script=Join-Path $InstallRoot 'afz-openai-agent\tools\Stremio-Organize.py'
if(-not(Test-Path -LiteralPath $script -PathType Leaf)){throw "Stremio organizer helper missing: $script"}

$candidates=@()
foreach($name in @('python.exe','py.exe')){
  $cmd=Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if($cmd){
    $path=$(if($cmd.Source){[string]$cmd.Source}else{[string]$cmd.Path})
    if($path){$candidates+=$path}
  }
}
$candidates+=@(
  'C:\Users\Faiz\AppData\Local\Microsoft\WindowsApps\python.exe',
  'C:\Program Files\Python310\python.exe',
  'C:\Python310\python.exe'
)
$python=$candidates | Where-Object {$_ -and (Test-Path -LiteralPath $_ -PathType Leaf)} | Select-Object -First 1
if(-not $python){throw 'Python runtime not found for Stremio organizer'}

$args=@($script,'--action',$Action)
if([IO.Path]::GetFileName($python).ToLowerInvariant() -eq 'py.exe'){$args=@('-3')+$args}
$raw=(& $python @args 2>&1 | Out-String).Trim()
$code=$LASTEXITCODE
if([string]::IsNullOrWhiteSpace($raw)){throw 'Stremio organizer returned empty output'}
if($code -ne 0){throw "Stremio organizer failed exit=$code output=$raw"}
try{$result=$raw|ConvertFrom-Json}catch{throw "Stremio organizer returned invalid JSON: $raw"}
if(-not [bool]$result.ok){throw "Stremio organizer reported failure: $raw"}
$result|ConvertTo-Json -Depth 20 -Compress
