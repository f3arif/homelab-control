# AFZ_PORTABLE_WINDOWS=1
# AFZ_LENOVO_ALLOWED=1
# AFZ_DIRECT_PORTABLE=1
# AFZ_DIRECT_RISK=A0
$ErrorActionPreference='Stop'
[pscustomobject]@{
  ok=$true
  computer=$env:COMPUTERNAME
  user=$env:USERNAME
  processId=$PID
  powershell=$PSVersionTable.PSVersion.ToString()
  time=(Get-Date).ToUniversalTime().ToString('o')
  canary='lenovo-direct-portable-r1'
} | ConvertTo-Json -Compress
