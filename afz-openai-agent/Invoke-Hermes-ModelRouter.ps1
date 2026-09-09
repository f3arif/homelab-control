#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Prompt')]
param(
  [ValidateSet('default','cheap','coding','complex','qwen','sensitive','local')]
  [string]$Lane='default',

  [ValidateSet('normal','private','sensitive','client')]
  [string]$Privacy='normal',

  [string]$Validator='none',

  [Parameter(ParameterSetName='Prompt',Mandatory=$true)]
  [string]$Prompt,

  [Parameter(ParameterSetName='File',Mandatory=$true)]
  [string]$PromptFile,

  [switch]$JsonResult,

  [string]$RouterPath='C:\Projects\HermesRouter\hermes_route.py'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if(-not(Test-Path -LiteralPath $RouterPath -PathType Leaf)){
  throw "Hermes router missing: $RouterPath"
}

$python=(Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
if(-not $python){
  $python=(Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
}
if(-not $python){throw 'Python launcher not found.'}
$pythonPath=$(if($python.Path){[string]$python.Path}else{[string]$python.Source})

$temp=$null
$effectivePromptFile=$PromptFile
try{
  if($PSCmdlet.ParameterSetName -eq 'Prompt'){
    $temp=Join-Path $env:TEMP ('afz-hermes-router-'+[guid]::NewGuid().ToString('n')+'.txt')
    [IO.File]::WriteAllText($temp,$Prompt,(New-Object Text.UTF8Encoding($false)))
    $effectivePromptFile=$temp
  }elseif(-not(Test-Path -LiteralPath $PromptFile -PathType Leaf)){
    throw "Prompt file missing: $PromptFile"
  }

  $args=@()
  if([IO.Path]::GetFileName($pythonPath) -ieq 'py.exe'){$args+='-3'}
  $args+=@(
    $RouterPath,
    '--lane',$Lane,
    '--privacy',$Privacy,
    '--validator',$Validator,
    '--prompt-file',$effectivePromptFile
  )
  if($JsonResult){$args+='--json-result'}

  $raw=(& $pythonPath @args 2>&1 | Out-String).Trim()
  $code=$LASTEXITCODE
  if($raw){Write-Output $raw}
  exit $code
}finally{
  if($temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
}