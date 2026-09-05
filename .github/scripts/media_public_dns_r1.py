#!/usr/bin/env python3
import json, os, sys, urllib.error, urllib.request

BASE="https://api.porkbun.com/api/json/v3"
DOMAIN="afzeng.ca"
TARGET="99.235.82.12"
SUBDOMAINS=("request","jellyfin")
RESULT="media-public-dns-r1-result.json"
API_KEY=os.environ.get("PORKBUN_API_KEY","")
SECRET=os.environ.get("PORKBUN_SECRET_API_KEY","")

result={"status":"ERROR","classification":"MEDIA_PUBLIC_DNS_FAILED","domain":DOMAIN,"targetIpv4":TARGET,"records":[],"secretValuesLogged":False}

def save():
    with open(RESULT,"w",encoding="utf-8") as f: json.dump(result,f,separators=(",",":"))

def api(method,path,payload=None,key=None):
    h={"Accept":"application/json","X-API-Key":API_KEY,"X-Secret-API-Key":SECRET}
    data=None
    if payload is not None:
        h["Content-Type"]="application/json"; data=json.dumps(payload,separators=(",",":")).encode()
    if key: h["Idempotency-Key"]=key
    req=urllib.request.Request(BASE+path,data=data,headers=h,method=method)
    try:
        with urllib.request.urlopen(req,timeout=20) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw=e.read().decode("utf-8","replace")
        try: code=json.loads(raw).get("code") or f"HTTP_{e.code}"
        except Exception: code=f"HTTP_{e.code}"
        raise RuntimeError(f"Porkbun API error: {code}") from None

def ok(resp,op):
    if resp.get("status")!="SUCCESS": raise RuntimeError(f"{op} failed: {resp.get('code','UNKNOWN')}")
    if resp.get("wouldSucceed") is False: raise RuntimeError(f"{op} dry-run rejected")

def ensure(name):
    path=f"/dns/retrieveByNameType/{DOMAIN}/A/{name}"
    cur=api("GET",path); ok(cur,f"retrieve {name}")
    rows=cur.get("records") or []
    if len(rows)>1: raise RuntimeError(f"Duplicate A records require review for {name}")
    action="unchanged"
    payload={"name":name,"type":"A","content":TARGET,"ttl":600}
    if rows and rows[0].get("content")!=TARGET:
        rid=rows[0]["id"]
        dry=dict(payload,dryRun=True); ok(api("POST",f"/dns/edit/{DOMAIN}/{rid}",dry),f"dry-run edit {name}")
        ok(api("POST",f"/dns/edit/{DOMAIN}/{rid}",payload,f"media-public-r1-edit-{name}-{TARGET}"),f"edit {name}")
        action="edited"
    elif not rows:
        dry=dict(payload,dryRun=True); ok(api("POST",f"/dns/create/{DOMAIN}",dry),f"dry-run create {name}")
        ok(api("POST",f"/dns/create/{DOMAIN}",payload,f"media-public-r1-create-{name}-{TARGET}"),f"create {name}")
        action="created"
    chk=api("GET",path); ok(chk,f"verify {name}")
    vr=chk.get("records") or []
    if len(vr)!=1 or vr[0].get("content")!=TARGET: raise RuntimeError(f"authoritative verification failed for {name}")
    result["records"].append({"host":f"{name}.{DOMAIN}","type":"A","content":TARGET,"action":action,"verified":True})

def main():
    if not API_KEY or not SECRET:
        result["classification"]="PORKBUN_CREDENTIALS_REQUIRED"; result["error"]="Required Porkbun GitHub secrets are not configured"; save(); return 20
    try:
        for name in SUBDOMAINS: ensure(name)
        result["status"]="SUCCESS"; result["classification"]="MEDIA_PUBLIC_DNS_PROVISIONED_VERIFIED"; save(); return 0
    except Exception as e:
        result["error"]=str(e)[:300]; save(); return 1

if __name__=="__main__": sys.exit(main())
