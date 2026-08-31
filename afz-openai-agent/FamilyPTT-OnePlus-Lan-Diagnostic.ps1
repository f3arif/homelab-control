#Requires -Version 5.1
$ErrorActionPreference='Stop'
$serial='95038870'
$pkg='ca.afzeng.familyptt'
$bridge='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$out=Join-Path $bridge 'FAMILYPTT-ONEPLUS-LAN-DIAG-LATEST.txt'
$adb='C:\Users\Faiz\AppData\Local\Android\Sdk\platform-tools\adb.exe'
$result=[ordered]@{schema=1;purpose='FamilyPTT OnePlus LAN-backup physical diagnostic';readOnly=$true;serial=$serial;package=$pkg;startedAt=(Get-Date -Format o);deviceState=$null;model=$null;pid=$null;appTransportLog=@();connectivity=@();wifi=@();classification='RUNNING';error=$null;finishedAt=$null}
function Save {$result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $out -Encoding UTF8}
Save
try {
 if(-not(Test-Path -LiteralPath $adb -PathType Leaf)){throw 'adb.exe not found'}
 $devices=@(& $adb devices -l 2>&1)
 $line=$devices|Where-Object{$_ -match ('^'+[regex]::Escape($serial)+'\s+')}|Select-Object -First 1
 if(-not $line){$result.classification='ONEPLUS_NOT_VISIBLE';throw 'OnePlus serial not visible to ADB'}
 if($line -notmatch '\sdevice(\s|$)'){$result.classification='ONEPLUS_ADB_NOT_READY';throw "OnePlus ADB state is not device: $line"}
 $result.deviceState='device'
 $result.model=((@(& $adb -s $serial shell getprop ro.product.model 2>&1) -join '').Trim())
 $result.pid=((@(& $adb -s $serial shell pidof $pkg 2>&1) -join '').Trim())
 if([string]::IsNullOrWhiteSpace($result.pid)){$result.classification='FAMILYPTT_NOT_RUNNING';throw 'FamilyPTT PID not found'}
 $log=@(& $adb -s $serial logcat -d "--pid=$($result.pid)" -v time 2>&1)
 $result.appTransportLog=@($log|Where-Object{$_ -match 'TransportPath|Recovery|LiveKit'}|Select-Object -Last 120)
 $conn=@(& $adb -s $serial shell dumpsys connectivity 2>&1)
 $result.connectivity=@($conn|Where-Object{$_ -match 'NetworkAgentInfo|VALIDATED|WIFI|INTERNET|CAPTIVE_PORTAL|NOT_VPN|TRANSPORT_WIFI|NET_CAPABILITY_VALIDATED'}|Select-Object -Last 220)
 $wifi=@(& $adb -s $serial shell dumpsys wifi 2>&1)
 $result.wifi=@($wifi|Where-Object{$_ -match 'mNetworkInfo|Wi-Fi is|SSID|NetworkAgent|connected|Connectivity|validated|internet'}|Select-Object -Last 160)
 $appText=($result.appTransportLog -join "`n")
 $connText=($result.connectivity -join "`n")
 if($appText -match 'LAN_BACKUP_AVAILABLE'){$result.classification='APP_CLASSIFIED_LAN_BACKUP_UI_OR_STATE_PROPAGATION_SUSPECT'}
 elseif($connText -match 'TRANSPORT_WIFI|WIFI'){if($connText -match 'VALIDATED|NET_CAPABILITY_VALIDATED'){$result.classification='ANDROID_REPORTS_VALIDATED_WIFI_DESPITE_BLOCK'}else{$result.classification='WIFI_CONNECTED_NOT_VALIDATED_EXPO_REACHABILITY_STALE_SUSPECT'}}
 else{$result.classification='CONNECTIVITY_EVIDENCE_NEEDS_REVIEW'}
 $result.finishedAt=(Get-Date -Format o);Save;exit 0
} catch {
 $result.error=$_.Exception.Message
 if($result.classification -eq 'RUNNING'){$result.classification='DIAGNOSTIC_FAILED'}
 $result.finishedAt=(Get-Date -Format o);Save;exit 40
}
