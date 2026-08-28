#Requires -Version 5.1
Set-StrictMode -Version 2.0

function ConvertTo-AFZWindowsCommandLineArgument {
  [CmdletBinding()]
  param([AllowEmptyString()][string]$Value)

  if($null -eq $Value -or $Value.Length -eq 0){return '""'}
  if($Value -notmatch '[\s"]'){return $Value}

  $sb=New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $slashCount=0
  foreach($ch in $Value.ToCharArray()){
    if([int]$ch -eq 92){
      $slashCount++
      continue
    }
    if($ch -eq '"'){
      if($slashCount -gt 0){[void]$sb.Append((('\' * ($slashCount*2)) -join ''))}
      [void]$sb.Append('\"')
      $slashCount=0
      continue
    }
    if($slashCount -gt 0){
      [void]$sb.Append((('\' * $slashCount) -join ''))
      $slashCount=0
    }
    [void]$sb.Append($ch)
  }
  if($slashCount -gt 0){[void]$sb.Append((('\' * ($slashCount*2)) -join ''))}
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Invoke-AFZBoundedNative {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string[]]$ArgumentList,
    [ValidateRange(1,900)][int]$TimeoutSeconds=30
  )

  $psi=New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName=$FilePath
  $psi.UseShellExecute=$false
  $psi.CreateNoWindow=$true
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  $psi.Arguments=(($ArgumentList | ForEach-Object { ConvertTo-AFZWindowsCommandLineArgument ([string]$_) }) -join ' ')

  $p=New-Object System.Diagnostics.Process
  $p.StartInfo=$psi
  $started=$false
  try{
    $started=$p.Start()
    if(-not $started){throw "Failed to start native process: $FilePath"}
    $pidValue=$p.Id
    $completed=$p.WaitForExit($TimeoutSeconds*1000)
    if(-not $completed){
      try{$p.Kill()}catch{}
      try{[void]$p.WaitForExit(5000)}catch{}
      $stdout=$p.StandardOutput.ReadToEnd()
      $stderr=$p.StandardError.ReadToEnd()
      return [pscustomobject]@{TimedOut=$true;ExitCode=$null;StdOut=$stdout;StdErr=$stderr;Pid=$pidValue;TimeoutSeconds=$TimeoutSeconds}
    }
    $stdout=$p.StandardOutput.ReadToEnd()
    $stderr=$p.StandardError.ReadToEnd()
    return [pscustomobject]@{TimedOut=$false;ExitCode=$p.ExitCode;StdOut=$stdout;StdErr=$stderr;Pid=$pidValue;TimeoutSeconds=$TimeoutSeconds}
  }finally{
    if($p){$p.Dispose()}
  }
}
