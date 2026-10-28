"""Owner-only Stremio addon for Movie Night files actually indexed on the 8 TB server.

The existing /movie-night/catalog/movie/downloaded.json, backed by MediaIndex,
is authoritative. This adapter only handles GETs *after* the standalone
gateway's exact Host/Origin and Tailscale owner checks. It creates no downloads,
holds no credentials, exposes no backend address and retains no private cache.
"""
import json
import re
from urllib.parse import urlsplit

from movie_gateway import UnixConnection

ADDON_ID = "com.afzengineering.movienight.ready"
CATALOG_ID = "afz_movie_night_ready"
PREFIX = "/movie-night/"
MAX_BODY = 262144
MAX_ITEMS = 500
PAGE_SIZE = 40
IMDB = re.compile(r"tt[0-9]{5,12}\Z")
CATALOG = PREFIX + "catalog/movie/" + CATALOG_ID + ".json"
PAGED = re.compile(r"/movie-night/catalog/movie/afz_movie_night_ready/skip=([0-9]{1,5})\.json\Z")
META = re.compile(r"/movie-night/meta/movie/(tt[0-9]{5,12})\.json\Z")
STREAM = re.compile(r"/movie-night/stream/movie/(tt[0-9]{5,12})\.json\Z")


def route(path):
    """Return a known resource only. No query/encoded/traversal route expansion."""
    if not isinstance(path, str) or "?" in path or "%" in path or "#" in path:
        return None
    if path == PREFIX + "manifest.json":
        return ("manifest", None)
    if path == CATALOG:
        return ("catalog", 0)
    m = PAGED.fullmatch(path)
    if m and int(m[1]) % PAGE_SIZE == 0:
        return ("catalog", int(m[1]))
    m = META.fullmatch(path)
    if m:
        return ("meta", m[1])
    m = STREAM.fullmatch(path)
    if m:
        return ("stream", m[1])
    return None


def fetch_ready(handler):
    """Fetch only the existing private, validated downloaded-file index."""
    connection = UnixConnection(handler.server.movie_socket)
    try:
        connection.request(
            "GET", "/movie-night/catalog/movie/downloaded.json",
            headers={"Host": "localhost", "X-AFZ-Review-Principal": "billing-owner"},
        )
        result = connection.getresponse()
        if result.status != 200 or result.getheader("Content-Type", "").split(";")[0].strip() != "application/json":
            raise ValueError("private index unavailable")
        raw = result.read(MAX_BODY + 1)
        if len(raw) > MAX_BODY:
            raise ValueError("private index exceeds budget")
        data = json.loads(raw)
        if not isinstance(data, dict) or not isinstance(data.get("metas"), list) or len(data["metas"]) > MAX_ITEMS:
            raise ValueError("invalid private index")
        rows = []
        seen = set()
        for item in data["metas"]:
            if not isinstance(item, dict):
                raise ValueError("invalid metadata")
            imdb, name = item.get("id"), item.get("name")
            year = str(item.get("releaseInfo", ""))
            if (not isinstance(imdb, str) or not IMDB.fullmatch(imdb)
                    or not isinstance(name, str) or not 1 <= len(name) <= 200
                    or not year.isdigit() or len(year) != 4):
                raise ValueError("invalid indexed metadata")
            if imdb in seen:
                continue
            seen.add(imdb)
            rows.append({"id": imdb, "type": "movie", "name": name,
                         "releaseInfo": year, "year": int(year),
                         "description": "Downloaded · Ready on AFZ server"})
        return rows
    finally:
        connection.close()


def meta(row, public_origin):
    m = dict(row)
    m["poster"] = public_origin + PREFIX + "posters/" + row["id"] + ".img"
    m["posterShape"] = "poster"
    return m


def payload(handler, kind, key):
    origin = handler.server.public_origin
    if kind == "manifest":
        return {
            "id": ADDON_ID, "version": "1.0.0",
            "name": "AFZ Movie Night · Ready on Server",
            "description": "Your private Movie Night downloads, indexed and verified on the 8 TB server.",
            "types": ["movie"],
            "resources": ["catalog",
                          {"name": "meta", "types": ["movie"], "idPrefixes": ["tt"]},
                          {"name": "stream", "types": ["movie"], "idPrefixes": ["tt"]}],
            "catalogs": [{"type": "movie", "id": CATALOG_ID,
                          "name": "Movie Night · Ready on Server",
                          "extra": [{"name": "skip", "isRequired": False}]}],
            "idPrefixes": ["tt"],
        }
    rows = fetch_ready(handler)
    if kind == "catalog":
        return {"metas": [meta(row, origin) for row in rows[key:key + PAGE_SIZE]],
                "cacheMaxAge": 0, "staleRevalidate": 0, "staleError": 0}
    found = next((row for row in rows if row["id"] == key), None)
    if kind == "meta":
        return {"meta": meta(found, origin)} if found else {"meta": None}
    if kind == "stream":
        return {"streams": [{
            "name": "AFZ Movie Night · Server",
            "title": "Ready on your AFZ 8 TB drive",
            "url": origin + PREFIX + "media/" + key,
        }]} if found else {"streams": [], "cacheMaxAge": 0}
    raise ValueError("unsupported resource")


def handle(handler):
    """Intercept recognized routes; unknown paths retain existing 404 behavior."""
    matched = route(handler.path)
    if matched is None:
        return False
    try:
        data = payload(handler, *matched)
        handler.send(200, json.dumps(data, ensure_ascii=False, separators=(",", ":")), "application/json")
    except (OSError, ValueError, json.JSONDecodeError, TimeoutError):
        handler.send(503, '{"error":"movie_night_catalog_unavailable"}', "application/json")
    return True
