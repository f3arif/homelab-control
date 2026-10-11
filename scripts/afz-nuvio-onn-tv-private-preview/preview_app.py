"""Private, stream-only Nuvio TV addon backed by the staged R2+R3 source.

No catalog controls, downloads, writes to production state, or public listener.
"""
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse, Response
from fastapi.middleware.cors import CORSMiddleware
import os, re, time
import stremio_catalog as impl

PREVIEW_URL=os.getenv(
    "AFZ_NUVIO_PREVIEW_URL",
    "https://desktop-h3r6cqn.tailc9bb62.ts.net:18886"
).rstrip("/")
ADDON_ID="com.afzengineering.nuvio.tvpreview.r2r3"
ALLOWED_MOVIES={
    "tt6723592":("Tenet", "2020"),
    "tt32393988":("Insidious: Out of the Further", "2026"),
    "tt22084616":("Spider-Man: Brand New Day", "2026"),
}
# The preview is not a production catalog: provide metadata for tested titles
# to avoid repeated external title lookups in the private staging service.
for imdb,(name,year) in ALLOWED_MOVIES.items():
    impl.cache.setdefault("idmap",{})[imdb]={"title":name,"year":year}

preview=FastAPI(
    title="AFZ Nuvio TV Private Preview",
    docs_url=None, redoc_url=None, openapi_url=None
)
preview.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=False,
    allow_methods=["GET","HEAD","OPTIONS"], allow_headers=["*"]
)
_allow_public=(
    re.compile(r"^/manifest\.json$"),
    re.compile(r"^/stream/movie/tt\d+\.json$"),
    re.compile(r"^/external-stream/tt\d+/[0-9a-f]{20,64}$"),
    re.compile(r"^/auto-stream/tt\d+/(?:saver|mobile)$")
)

@preview.middleware("http")
async def preview_firewall(request:Request, call_next):
    path=request.url.path
    if request.method not in ("GET","HEAD","OPTIONS"):
        return JSONResponse({"error":"Preview is read-only"},status_code=405)
    if not any(rule.fullmatch(path) for rule in _allow_public):
        return JSONResponse({"error":"Not exposed by the TV preview"},status_code=404)
    if path.startswith(("/external-stream/","/auto-stream/")):
        parts=path.strip("/").split("/")
        if parts[1] not in ALLOWED_MOVIES:
            return JSONResponse({"error":"Not a preview test title"},status_code=404)
    return await call_next(request)

@preview.api_route("/manifest.json", methods=["GET","HEAD"])
def manifest(request:Request):
    response={
        "id":ADDON_ID,
        "version":"0.6.244-preview.1",
        "name":"AFZ TV Preview R2+R3",
        "description":"Private Tailscale-only movie stream testing. Separate from the live AFZ Movies & TV addon.",
        "resources":[{"name":"stream","types":["movie"],"idPrefixes":["tt"]}],
        "types":["movie"],
        "catalogs":[],
        "idPrefixes":["tt"],
    }
    if request.method=="HEAD":
        return Response(status_code=200, headers={"Cache-Control":"no-store"})
    return JSONResponse(response,headers={"Cache-Control":"no-store"})

@preview.api_route("/stream/movie/{vid}.json",methods=["GET","HEAD"])
def preview_movie_streams(vid:str,request:Request):
    if vid not in ALLOWED_MOVIES:
        return JSONResponse({"streams":[]},headers={"Cache-Control":"no-store"})
    if request.method=="HEAD":
        return Response(status_code=200,headers={"Cache-Control":"no-store"})
    # Fetch source discovery using the combined candidate, never the original.
    # First lookup is bounded by the existing H3 bridge request timeout.
    items=impl._auto_quick_source_rows(vid,"saver")
    viable=[r for r in items
            if isinstance(r,dict) and r.get("cached")
            and int(r.get("resolution") or 0)==1080
            and 2*1024**3<=int(r.get("size") or 0)<=8*1024**3]
    prioritized=impl._auto_quick_ranked_candidates(viable,"saver")
    streams=[
        {
            "name":"AFZ TV Preview | Auto 1080p",
            "title":"R2+R3 private beta - healthy cached 1080p with fallback",
            "url":f"{PREVIEW_URL}/auto-stream/{vid}/saver",
            "behaviorHints":{"filename":"AFZ-TV-Preview-Auto-1080p.mkv"},
        },
        {
            "name":"AFZ TV Preview | Auto Mobile",
            "title":"R2+R3 private beta - mobile-size 1080p with fallback",
            "url":f"{PREVIEW_URL}/auto-stream/{vid}/mobile",
            "behaviorHints":{"filename":"AFZ-TV-Preview-Mobile-1080p.mkv"},
        },
    ]
    selected=set()
    for row in prioritized:
        token=str(row.get("token") or "")
        if not re.fullmatch("[0-9a-f]{20,64}",token):
            continue
        # Put distinct small Comet releases ahead of other providers, preserving
        # their exact IDs. Manual source links still use R2 expiry recovery.
        filename=str(row.get("filename") or "")
        identity=(str(row.get("source") or "").lower(),
                  re.sub("[^a-z0-9]+","",filename.lower()))
        if identity in selected:continue
        selected.add(identity)
        size=float(int(row.get("size") or 0))/(1024**3)
        src=str(row.get("source") or "Remote")
        streams.append({
            "name":f"AFZ TV Preview | {src} 1080p",
            "title":f"{size:.1f} GiB | cached | {filename[:170]}",
            "url":f"{PREVIEW_URL}/external-stream/{vid}/{token}",
            "behaviorHints":{
                "filename":filename or f"AFZ-preview-{vid}.mkv",
                "videoSize":int(row.get("size") or 0),
            }
        })
        if len(selected)>=4:break
    return JSONResponse({"streams":streams},headers={"Cache-Control":"no-store, max-age=0"})

# Reuse ONLY the two read-only media-playback endpoint implementations from the
# combined R2+R3 candidate. All catalog/search/delete/download/control endpoints
# are deliberately omitted.
selected_routes={
    "/external-stream/{vid}/{token}",
    "/auto-stream/{vid}/{mode}",
}
found=set()
for route in impl.app.router.routes:
    if getattr(route,"path",None) in selected_routes:
        preview.router.routes.append(route)
        found.add(route.path)
if found!=selected_routes:
    raise RuntimeError("Staged backend media paths mismatch; fail closed")

app=preview
