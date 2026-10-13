import datetime,hashlib,json,os,pathlib,re,shutil
root=pathlib.Path(os.environ.get('AFZ_H3_CORE_ROOT',r'C:\AFZ\Stremio-Failover-H3'))
launcher=root/'Start-AFZ-Stremio-H3-Core243.ps1'
out=pathlib.Path(os.environ['AFZ_REQUESTS_RECOVERY_DIR'])
text=launcher.read_text(encoding='utf-8-sig')
assert (root/'state/media-requests-connection.json').is_file()
new=text
replace={
'SEERR_URL':"$env:SEERR_URL=[string]$mediaRequests.seerr.url",
'SEERR_API_KEY':"$env:SEERR_API_KEY=[string]$mediaRequests.seerr.apiKey",
'RADARR_URL':"$env:RADARR_URL=[string]$mediaRequests.radarr.url",
'RADARR_API_KEY':"$env:RADARR_API_KEY=[string]$mediaRequests.radarr.apiKey",
}
for key,value in replace.items():
    new,n=re.subn(r'(?m)^  \$env:'+key+r'=.*$', '  '+value,new)
    assert n==1,key
needle="  $env:AFZ_STREMIO_FAILOVER_MODE='1'\n"
assert new.count(needle)==1
new=new.replace(needle,needle+"  $mediaRequests=Get-Content -LiteralPath (Join-Path $root 'state\\media-requests-connection.json') -Raw | ConvertFrom-Json\n  $env:STREMIO_RADARR_DIRECT_ROOT=[string]$mediaRequests.radarrRoot\n")
backup=out/'Start-AFZ-Stremio-H3-Core243.before-requests.ps1'
assert not backup.exists()
shutil.copy2(launcher,backup)
candidate=out/'Start-AFZ-Stremio-H3-Core243.restored-requests.ps1'
candidate.write_text(new,encoding='utf-8')
report={'launcher':str(launcher),'candidate':str(candidate),'backup':str(backup),'before_sha256':hashlib.sha256(launcher.read_bytes()).hexdigest(),'candidate_sha256':hashlib.sha256(candidate.read_bytes()).hexdigest(),'source_sha256':hashlib.sha256((root/'stremio_catalog.py').read_bytes()).hexdigest()}
(out/'h3-launcher-preflight.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report))
