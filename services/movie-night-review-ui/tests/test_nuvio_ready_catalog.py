"""Disposable owner/Tailscale Stremio addon contract, with no production state."""
import http.client
import json
from http.server import BaseHTTPRequestHandler
from pathlib import Path
import socketserver
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gateway"))
from standalone_server import MovieNightServer

HOST = "movie.example.ts.net:8453"
ORIGIN = "https://" + HOST
OWNER = "owner@example.test"
BASE = "/movie-night"
CATALOG = BASE + "/catalog/movie/afz_movie_night_ready.json"
MANIFEST = BASE + "/manifest.json"
READY = [
    {"id": "tt12262116", "type": "movie", "name": "Thirteen Lives", "releaseInfo": "2022"},
    {"id": "tt3839880", "type": "movie", "name": "Infinity Chamber", "releaseInfo": "2016"},
]


class Backend(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_GET(self):
        self.server.requests.append((self.command, self.path, dict(self.headers)))
        if self.path == BASE + "/catalog/movie/downloaded.json":
            if self.server.broken:
                self.write(500, b'{"error":"index unavailable"}')
                return
            value = json.dumps({"metas": list(self.server.metas)}).encode("utf-8")
            self.write(200, value, "application/json")
        elif self.path == BASE + "/media/tt12262116":
            self.write(206, b"x", "video/x-matroska", {"Content-Range": "bytes 0-0/100"})
        else:
            self.write(404, b"not found")

    def do_HEAD(self):
        self.server.requests.append((self.command, self.path, dict(self.headers)))
        if self.path == BASE + "/media/tt12262116":
            self.send_response(200)
            self.send_header("Content-Type", "video/x-matroska")
            self.send_header("Content-Length", "100")
            self.end_headers()
        else:
            self.send_response(404); self.end_headers()

    def write(self, status, body, mime="application/json", extra=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", mime)
        for k,v in (extra or {}).items(): self.send_header(k,v)
        self.end_headers()
        self.wfile.write(body)


class NuvioReadyCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.path = Path(cls.tmp.name)
        cls.path.chmod(0o700)
        socket = cls.path / "review.sock"
        cls.backend = socketserver.UnixStreamServer(str(socket), Backend)
        socket.chmod(0o600)
        cls.backend.metas = list(READY)
        cls.backend.broken = False
        cls.backend.requests = []
        cls.backend_thread = threading.Thread(target=cls.backend.serve_forever, daemon=True)
        cls.backend_thread.start()
        cls.server = MovieNightServer(ORIGIN, ORIGIN, OWNER, port=0, movie_socket=str(socket))
        cls.front_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.front_thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.front_thread.join()
        cls.backend.shutdown(); cls.backend.server_close(); cls.backend_thread.join()
        cls.tmp.cleanup()

    def setUp(self):
        self.backend.metas = list(READY)
        self.backend.broken = False
        self.backend.requests.clear()

    def call(self, path, method="GET", headers=None):
        values = [("Host", HOST), ("Tailscale-User-Login", OWNER)]
        if headers is not None:
            values += headers
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        connection.putrequest(method, path, skip_host=True)
        for key, value in values:
            connection.putheader(key, value)
        connection.endheaders()
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def json_get(self, path):
        status, headers, body = self.call(path)
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "application/json")
        self.assertIn("no-store", headers.get("Cache-Control",""))
        return json.loads(body)

    def test_manifest_valid_stremio_resources_and_owner_only(self):
        data = self.json_get(MANIFEST)
        self.assertEqual(data["id"], "com.afzengineering.movienight.ready")
        self.assertEqual(data["catalogs"][0]["id"], "afz_movie_night_ready")
        self.assertEqual(data["types"], ["movie"])
        self.assertIn("stream", [x["name"] if isinstance(x, dict) else x for x in data["resources"]])
        self.assertNotIn("owner@example.test", json.dumps(data))
        self.assertEqual(self.backend.requests, [])

    def test_ready_catalog_updates_without_restart_or_private_cache(self):
        a = self.json_get(CATALOG)
        self.assertEqual([x["id"] for x in a["metas"]], ["tt12262116", "tt3839880"])
        self.assertEqual(a["cacheMaxAge"], 0)
        self.assertTrue(all(x["poster"].startswith(ORIGIN + BASE + "/posters/tt") for x in a["metas"]))
        self.backend.metas = READY[:1]
        b = self.json_get(CATALOG)
        self.assertEqual([x["id"] for x in b["metas"]], ["tt12262116"])
        self.backend.metas = READY + [{"id": "tt5073642", "name": "Color Out of Space", "releaseInfo": "2020"}]
        c = self.json_get(CATALOG)
        self.assertEqual(len(c["metas"]), 3)

    def test_exact_meta_and_stream_are_ready_only(self):
        self.assertEqual(self.json_get(BASE + "/meta/movie/tt12262116.json")["meta"]["name"], "Thirteen Lives")
        url = self.json_get(BASE + "/stream/movie/tt12262116.json")["streams"][0]["url"]
        self.assertEqual(url, ORIGIN + BASE + "/media/tt12262116")
        self.assertEqual(self.json_get(BASE + "/stream/movie/tt00000000.json")["streams"], [])
        self.assertIsNone(self.json_get(BASE + "/meta/movie/tt00000000.json")["meta"])
        self.assertEqual([path for _,path,_ in self.backend.requests],
                         [BASE+"/catalog/movie/downloaded.json"]*4)

    def test_media_range_and_head_for_tv_player(self):
        status, headers, body = self.call(BASE + "/media/tt12262116", headers=[("Range","bytes=0-0")])
        self.assertEqual((status, body), (206, b"x"))
        self.assertEqual(headers["Content-Range"], "bytes 0-0/100")
        status, headers, body = self.call(BASE + "/media/tt12262116",method="HEAD")
        self.assertEqual((status, body), (200, b""))
        self.assertEqual(headers["Content-Length"], "100")

    def test_owner_required_and_no_public_or_external_fetch(self):
        h = [("Host", HOST), ("Tailscale-User-Login", "different@example.test")]
        # call() includes good identity; duplicate causes fail closed.
        self.assertEqual(self.call(CATALOG, headers=[("Tailscale-User-Login","other@example.test")])[0],403)
        self.assertEqual(self.call(CATALOG, headers=[("Host","other.example.test")])[0],403)
        self.assertEqual(self.call(CATALOG, headers=[("Origin","https://evil.test")])[0],403)
        self.assertEqual(self.call(CATALOG,headers=[("Sec-Fetch-Site","cross-site"),("Sec-Fetch-Mode","cors"),("Sec-Fetch-Dest","empty")])[0],403)
        self.assertEqual(self.call(CATALOG,method="POST",headers=[("Origin",ORIGIN)])[0],404)
        self.assertEqual(self.backend.requests, [])

    def test_encoded_query_and_traversal_paths_never_route(self):
        for path in (MANIFEST + "?share=yes", CATALOG + "?x=1",
                     BASE + "/stream/movie/tt12262116%2F.json",
                     BASE + "/catalog/movie/../catalog/movie/afz_movie_night_ready.json",
                     BASE + "/stream/movie/tt12262116.json?another=1"):
            self.assertEqual(self.call(path)[0],404, path)

    def test_fail_closed_on_unavailable_or_invalid_index(self):
        self.backend.broken=True
        self.assertEqual(self.call(CATALOG)[0],503)
        self.backend.broken=False
        for metas in (
            [{"id": "tt1", "name": "Bad", "releaseInfo": "2022"}],
            [{"id": "tt12262116", "name": "", "releaseInfo": "2022"}],
            [{"id": "tt12262116", "name": "Movie", "releaseInfo": "2022?bad"}],
        ):
            self.backend.metas=metas
            self.assertEqual(self.call(CATALOG)[0],503)
        self.backend.metas=READY+READY
        self.assertEqual(len(self.json_get(CATALOG)["metas"]), 2)

    def test_existing_non_addon_pages_unmodified(self):
        self.assertEqual(self.call(BASE+"/api/downloads")[0],404)
        self.assertEqual(self.call(BASE+"/catalog/movie/downloaded.json")[0],200)
        self.assertEqual(self.call("/login")[0],303)


if __name__ == "__main__":
    unittest.main()
