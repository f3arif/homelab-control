#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$ollama='C:\Users\Faiz\AppData\Local\Programs\Ollama\ollama.exe'
if(-not(Test-Path -LiteralPath $ollama -PathType Leaf)){
  $ollama='C:\Program Files\Ollama\ollama.exe'
}
if(-not(Test-Path -LiteralPath $ollama -PathType Leaf)){throw 'Ollama executable missing.'}

$env:OLLAMA_HOST='127.0.0.1:11434'
$env:OLLAMA_MODELS='C:\Users\Faiz\.ollama\models'
$env:OLLAMA_KEEP_ALIVE='5m'

try{
  $r=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3
  if($r){exit 0}
}catch{}

& $ollama serve
exit $LASTEXITCODE
