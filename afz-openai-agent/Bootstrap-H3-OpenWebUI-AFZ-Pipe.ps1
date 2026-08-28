#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)
$ErrorActionPreference='Stop'
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()
$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$pipeUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/openwebui/afz_agent_pipe.py"
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-openwebui-pipe-bootstrap'
$stateFile=Join-Path $stateRoot 'latest.json'
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
function Save-State([string]$Status,[string]$Message,$Extra=$null){
  $o=[ordered]@{ok=($Status -eq 'completed');status=$Status;message=$Message;jobId=$JobId;target='DESKTOP-H3R6CQN';transport='windows-main-ssh+github-exact-sha';expectedSha=$ExpectedSha;updatedAt=(Get-Date -Format o)}
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 12 -Compress),$utf8)
}

$installerCode=@'
import json, sqlite3, sys, time
from pathlib import Path

db=Path(sys.argv[1])
pipe=Path(sys.argv[2])
backup_dir=Path(sys.argv[3])
source=pipe.read_text(encoding='utf-8')
now=int(time.time())
backup_dir.mkdir(parents=True, exist_ok=True)
backup=backup_dir / (f'webui-before-afz-pipe-{now}.db')
src=sqlite3.connect(str(db), timeout=20)
dst=sqlite3.connect(str(backup))
try:
    src.backup(dst)
finally:
    dst.close(); src.close()
con=sqlite3.connect(str(db), timeout=20)
try:
    tables={r[0] for r in con.execute("select name from sqlite_master where type='table'")}
    if 'function' not in tables:
        raise RuntimeError('OpenWebUI function table not found')
    info=list(con.execute('pragma table_info("function")'))
    cols={r[1]:r for r in info}
    user_id=None
    if 'user' in tables:
        ucols={r[1] for r in con.execute('pragma table_info("user")')}
        if 'id' in ucols:
            row=None
            if 'role' in ucols:
                row=con.execute('select id from "user" where lower(role)=? order by rowid limit 1',('admin',)).fetchone()
            if not row:
                row=con.execute('select id from "user" order by rowid limit 1').fetchone()
            if row: user_id=row[0]
    existing=con.execute('select id from "function" where id=?',('afz_typed_agent',)).fetchone()
    values={
        'id':'afz_typed_agent',
        'user_id':user_id,
        'name':'AFZ Typed Agent',
        'type':'pipe',
        'content':source,
        'meta':json.dumps({'description':'AFZ typed-agent bridge to Windows-main','manifest':{'title':'AFZ Typed Agent','version':'0.1.0'}},separators=(',',':')),
        'is_active':1,
        'is_global':0,
        'updated_at':now,
        'created_at':now,
        'valves':None,
    }
    if existing:
        update_keys=[k for k in ('user_id','name','type','content','meta','is_active','is_global','updated_at') if k in cols]
        con.execute('update "function" set '+','.join('"%s"=?'%k for k in update_keys)+' where id=?',[values[k] for k in update_keys]+['afz_typed_agent'])
        action='updated'
    else:
        insert_keys=[k for k in values if k in cols]
        missing=[]
        for name,row in cols.items():
            notnull=bool(row[3]); default=row[4]; pk=bool(row[5])
            if notnull and default is None and not pk and name not in insert_keys:
                missing.append(name)
        if missing:
            raise RuntimeError('Unsupported required function columns: '+','.join(missing))
        con.execute('insert into "function" ('+','.join('"%s"'%k for k in insert_keys)+') values ('+','.join('?' for _ in insert_keys)+')',[values[k] for k in insert_keys])
        action='created'
    con.commit()
    row=con.execute('select id,name,type,is_active,is_global,updated_at from "function" where id=?',('afz_typed_agent',)).fetchone()
    print(json.dumps({'ok':True,'action':action,'backup':str(backup),'function':row,'columns':sorted(cols)},separators=(',',':')))
finally:
    con.close()
'@
$smokeCode=@'
import asyncio, importlib.util, json, sys
p=sys.argv[1]
spec=importlib.util.spec_from_file_location('afz_agent_pipe',p)
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
pipe=m.Pipe()
body={'model':'torbox-auto','messages':[{'role':'user','content':'Use afz_system_status and jellyfin_public_info exactly once each. Do not call any other tools. Read-only only. Report concise status.'}]}
out=asyncio.run(pipe.pipe(body))
s=str(out)
ok=not s.startswith('AFZ Agent error') and not s.startswith('AFZ Agent connection error') and not s.startswith('AFZ Agent HTTP error')
print(json.dumps({'ok':ok,'output':s[:12000]},separators=(',',':')))
'@
$installerB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($installerCode))
$smokeB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($smokeCode))

try{
  if(-not(Test-Path $key)){throw "H3 SSH key missing: $key"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  Save-State 'running' 'Installing/updating AFZ Typed Agent Pipe in H3 OpenWebUI.'
  $remoteTemplate=@'
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: $env:COMPUTERNAME"}
$root='C:\OpenWebUI'
$db=Join-Path $root 'data\webui.db'
$py=Join-Path $root 'venv\Scripts\python.exe'
$pipeDir=Join-Path $root 'afz-functions'
$pipePath=Join-Path $pipeDir 'afz_agent_pipe.py'
$backupDir=Join-Path $root 'data\backups'
$resultPath=Join-Path $root 'logs\afz-pipe-bootstrap-latest.json'
if(-not(Test-Path $db)){throw "OpenWebUI database missing: $db"}
if(-not(Test-Path $py)){throw "OpenWebUI venv python missing: $py"}
New-Item -ItemType Directory -Force -Path $pipeDir,$backupDir,(Split-Path $resultPath -Parent)|Out-Null
Invoke-WebRequest -Uri '__PIPE_URL__' -OutFile $pipePath -UseBasicParsing -Headers @{'User-Agent'='AFZ-OpenWebUI-Pipe-Bootstrap'} -TimeoutSec 60
& $py -m py_compile $pipePath
if($LASTEXITCODE -ne 0){throw 'AFZ Pipe Python compile failed'}
$installer=Join-Path $env:TEMP ('afz-openwebui-install-'+[guid]::NewGuid().ToString('n')+'.py')
[IO.File]::WriteAllBytes($installer,[Convert]::FromBase64String('__INSTALLER_B64__'))
$dbResultRaw=& $py $installer $db $pipePath $backupDir 2>&1
$installExit=$LASTEXITCODE
Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
if($installExit -ne 0){throw ('OpenWebUI function DB install failed: '+(($dbResultRaw|ForEach-Object{[string]$_}) -join ' '))}
$dbResult=(($dbResultRaw|Select-Object -Last 1)|ConvertFrom-Json)
$task='OpenWebUI Server'
Get-ScheduledTask -TaskName $task -ErrorAction Stop|Out-Null
try{Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue}catch{}
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $task
$httpOk=$false
for($i=0;$i -lt 30;$i++){
  Start-Sleep -Seconds 2
  try{$r=Invoke-WebRequest -Uri 'http://127.0.0.1:8080/' -UseBasicParsing -TimeoutSec 4;if($r.StatusCode -eq 200){$httpOk=$true;break}}catch{}
}
if(-not $httpOk){throw 'OpenWebUI did not return HTTP 200 after restart'}
$smoke=Join-Path $env:TEMP ('afz-openwebui-smoke-'+[guid]::NewGuid().ToString('n')+'.py')
[IO.File]::WriteAllBytes($smoke,[Convert]::FromBase64String('__SMOKE_B64__'))
$smokeRaw=& $py $smoke $pipePath 2>&1
$smokeExit=$LASTEXITCODE
Remove-Item -LiteralPath $smoke -Force -ErrorAction SilentlyContinue
if($smokeExit -ne 0){throw ('AFZ Pipe smoke execution failed: '+(($smokeRaw|ForEach-Object{[string]$_}) -join ' '))}
$smokeObj=(($smokeRaw|Select-Object -Last 1)|ConvertFrom-Json)
if(-not [bool]$smokeObj.ok){throw ('AFZ Pipe smoke returned failure: '+[string]$smokeObj.output)}
$result=[ordered]@{ok=$true;host=$env:COMPUTERNAME;expectedSha='__SHA__';jobId='__JOB__';pipe=$pipePath;dbAction=$dbResult.action;backup=$dbResult.backup;openWebUiHttp=$httpOk;taskState=[string](Get-ScheduledTask -TaskName $task).State;smoke=$smokeObj.output;completedAt=(Get-Date -Format o)}
$result|ConvertTo-Json -Depth 8 -Compress|Set-Content -LiteralPath $resultPath -Encoding UTF8
$od=$env:OneDriveCommercial
if([string]::IsNullOrWhiteSpace($od) -or -not(Test-Path -LiteralPath $od)){$od=Join-Path $env:USERPROFILE 'OneDrive - AFZ Engineering Inc'}
if(Test-Path -LiteralPath $od){
  $safeResult=Join-Path $od 'AFZ Shared\AFZ Results\000-critical-openwebui-afz-pipe-bootstrap-latest.txt'
  $lines=@('AFZ_OPENWEBUI_PIPE_BOOTSTRAP','STATUS=PASS','HOST='+$env:COMPUTERNAME,'EXPECTED_SHA=__SHA__','JOB_ID=__JOB__','DB_ACTION='+$dbResult.action,'BACKUP='+$dbResult.backup,'OPENWEBUI_HTTP='+$httpOk,'TASK_STATE='+[string](Get-ScheduledTask -TaskName $task).State,'SMOKE_BEGIN',[string]$smokeObj.output,'SMOKE_END','COMPLETED_AT='+$result.completedAt)
  [IO.File]::WriteAllText($safeResult,($lines -join "`r`n"),(New-Object Text.UTF8Encoding($false)))
}
$result|ConvertTo-Json -Depth 8 -Compress
'@
  $remote=$remoteTemplate.Replace('__PIPE_URL__',$pipeUrl).Replace('__INSTALLER_B64__',$installerB64).Replace('__SMOKE_B64__',$smokeB64).Replace('__SHA__',$ExpectedSha).Replace('__JOB__',$JobId)
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  $out=& $ssh -i $key -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known" $h3 powershell.exe -NoProfile -EncodedCommand $encoded 2>&1
  if($LASTEXITCODE -ne 0){throw "H3 OpenWebUI bootstrap SSH failed exit=$LASTEXITCODE output=$($out|Out-String)"}
  $line=@($out|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $line){throw 'H3 OpenWebUI bootstrap returned no JSON result'}
  $extra=$line|ConvertFrom-Json
  Save-State 'completed' 'AFZ Typed Agent Pipe installed/enabled in OpenWebUI and smoke-tested.' $extra
  Write-Output ('AFZ_OPENWEBUI_BOOTSTRAP_JSON='+((Get-Content $stateFile -Raw|ConvertFrom-Json)|ConvertTo-Json -Depth 12 -Compress))
}catch{
  $msg=$_.Exception.Message
  Save-State 'failed' $msg
  Write-Error $msg
  exit 1
}
