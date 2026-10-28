#!/usr/bin/env python3
"""AFZ independent HP router: HP local first, ZBook private HTTPS second.

Never contacts H3, never copies raw HP credential to ZBook storage.
Bind to loopback only. Not production until review/acceptance.
"""
import http.client
import json
import os
import re
import socket
import ssl
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.background import BackgroundTask
from starlette.concurrency import run_in_threadpool

HP_HOST="127.0.0.1"
HP_PORT=int(os.getenv("AFZ_HP_LOCAL_PORT","18810"))
ZBOOK_HOST="afz-zbook.tailc9bb62.ts.net"
ZBOOK_IP="100.77.196.70"
ZBOOK_PORT=19543
PORT=int(os.getenv("AFZ_INDEPENDENT_ROUTER_PORT","18813"))
SECRET_PATH=Path("/home/coolyo/afz-stremio-secondhost-20260918/private/public-transport-token.txt")
assert SECRET_PATH.is_file() and SECRET_PATH.stat().st_mode & 0o077 == 0
TOKEN=SECRET_PATH.read_text().strip()
assert re.fullmatch(r"[A-Za-z0-9_-]{24,128}",TOKEN)
assert PORT in (18813,18814)
assert HP_PORT in (18810,9)  # 9 is a drill-only, intentionally down endpoint
REVISION="no-h3-local-on-zbook-first-20261017-r2"
HOP=frozenset(("connection","keep-alive","proxy-authenticate","proxy-authorization",
               "te","trailer","trailers","transfer-encoding","upgrade","host","content-length"))
CA=ssl.create_default_context()
MUTATIONS={"POST","PUT","PATCH","DELETE","OPTIONS"}
STATS={"hp_success":0,"zbook_success":0,"hp_failure":0,"zbook_failure":0}
MUTEX=threading.Lock()
app=FastAPI(docs_url=None,redoc_url=None,openapi_url=None)
def add_stat(field):
    with MUTEX: STATS[field]+=1

def eligible_for_zbook(method,path):
    if method not in ("GET","HEAD"):return False
    if any(x in path.lower() for x in ("..","//","%2e","%2f","%5c","\\")):
        return False
    return bool(re.fullmatch(r"/manifest\.json",path)
        or re.fullmatch(r"/(?:catalog|meta|stream)/(?:movie|series|tv|sport)/[A-Za-z0-9_:%.,+~@/-]+\.json",path))

def zbook_local_first(method,path):
    if method not in ("GET","HEAD") or not eligible_for_zbook(method,path):
        return False
    return bool(re.fullmatch(r"/catalog/movie/afz_local_ready(?:/[A-Za-z0-9_.%-]+)?\.json",path)
        or re.fullmatch(r"/(?:stream|meta)/movie/afzlib:[A-Za-z0-9_]{12,128}\.json",path))

def upstream(name,method,path,query,headers,body):
    if name=="hp-local":
        connection=http.client.HTTPConnection(HP_HOST,HP_PORT,timeout=18)
        backend=path
    else:
        connection=http.client.HTTPSConnection(ZBOOK_HOST,ZBOOK_PORT,context=CA,timeout=18)
        def connect():
            tcp=socket.create_connection((ZBOOK_IP,ZBOOK_PORT),timeout=4)
            connection.sock=CA.wrap_socket(tcp,server_hostname=ZBOOK_HOST)
        connection.connect=connect
        backend="/"+TOKEN+path
    if query: backend+="?"+query
    connection.request(method,backend,body=body,headers=headers)
    response=connection.getresponse()
    return connection,response

@app.get("/afz-origin/health")
def health():
    with MUTEX:stats=dict(STATS)
    return {"ok":True,"revision":REVISION,"fallback":"zbook","hp_local_port":HP_PORT,
            "h3_dependency":False,"ready_for_cutover":False,"stats":stats}

@app.api_route("/{path:path}",methods=["GET","HEAD","POST","PUT","PATCH","DELETE","OPTIONS"])
async def proxy(path:str,request:Request):
    path="/"+path
    if any(x in path.lower() for x in ("..","//","%2e","%2f","%5c","\\")) or len(path)>1000:
        return JSONResponse({"error":"invalid_route"},status_code=404)
    method=request.method
    data=await request.body()
    if len(data)>1024*1024:
        return JSONResponse({"error":"body_too_large"},status_code=413)
    headers={k:v for k,v in request.headers.items() if k.lower() not in HOP}
    if zbook_local_first(method,path):
        attempts=["zbook","hp-local"]
    else:
        attempts=["hp-local"]+ (["zbook"] if eligible_for_zbook(method,path) else [])
    for name in attempts:
        connection=None
        response=None
        try:
            connection,response=await run_in_threadpool(
                upstream,name,method,path,request.url.query,headers,data if data else None)
            if response.status in (502,503,504):
                add_stat("hp_failure" if name=="hp-local" else "zbook_failure")
                response.close();connection.close()
                continue
            add_stat("hp_success" if name=="hp-local" else "zbook_success")
            output={k:v for k,v in response.getheaders() if k.lower() not in HOP}
            output["X-AFZ-Origin"]="hp-local" if name=="hp-local" else "zbook"
            def chunks():
                try:
                    while True:
                        chunk=response.read(65536)
                        if not chunk:break
                        yield chunk
                finally:
                    response.close()
                    connection.close()
            return StreamingResponse(chunks(),status_code=response.status,headers=output,
                    background=BackgroundTask(lambda: (response.close(),connection.close())))
        except (OSError,TimeoutError,http.client.HTTPException,ssl.SSLError):
            add_stat("hp_failure" if name=="hp-local" else "zbook_failure")
            if response is not None:
                try:response.close()
                except Exception:pass
            if connection is not None:
                try:connection.close()
                except Exception:pass
            continue
    return JSONResponse({"error":"AFZ catalogue unavailable on HP Envy and ZBook"},
            status_code=503,headers={"Cache-Control":"no-store"})
