"""Offline tests for origin_noh3_r2 path handling. Run: python3 test_origin_noh3_r2.py"""
import importlib.util, os, sys, tempfile, types, unittest
from pathlib import Path

def load():
    tok=Path(tempfile.mkdtemp())/"t.txt"; tok.write_text("x"*32); os.chmod(tok,0o600)
    src=Path(__file__).with_name("origin_noh3_r2.py").read_text()
    src=src.replace('Path("/home/coolyo/afz-stremio-secondhost-20260918/private/public-transport-token.txt")',f'Path({str(tok)!r})')
    m=types.ModuleType("o"); exec(compile(src,"origin_noh3_r2.py","exec"),m.__dict__); return m

class T(unittest.TestCase):
    @classmethod
    def setUpClass(c): c.m=load()
    def test_raw_path_kept(s):
        s.assertEqual(s.m.wire_path(b"/catalog/movie/afz_search/search=social%20reckoning.json","/x"),
                     "/catalog/movie/afz_search/search=social%20reckoning.json")
    def test_decoded_space_reencoded(s):
        w=s.m.wire_path(None,"/catalog/movie/afz_search/search=social reckoning.json")
        s.assertEqual(w,"/catalog/movie/afz_search/search=social%20reckoning.json")
    def test_raw_with_space_reencoded(s):
        s.assertNotIn(" ",s.m.wire_path(b"/catalog/movie/afz_search/search=a b.json","/"))
    def test_proxy_sends_encoded_path(s):
        from fastapi.testclient import TestClient
        seen=[]
        class R:
            status=200
            def getheaders(self): return [("Content-Type","application/json")]
            def read(self,n=-1):
                if getattr(self,"d",0): return b""
                self.d=1; return b'{"metas":[]}'
            def close(self): pass
        class C:
            def close(self): pass
        def up(name,method,path,query,headers,body):
            import http.client; http.client.HTTPConnection("h")._validate_path(path); seen.append(path); return C(),R()
        s.m.upstream=up
        r=TestClient(s.m.app).get("/catalog/movie/afz_search/search=social%20reckoning.json")
        s.assertEqual(r.status_code,200); s.assertEqual(seen,["/catalog/movie/afz_search/search=social%20reckoning.json"])
    def test_traversal_still_blocked(s):
        from fastapi.testclient import TestClient
        s.assertEqual(TestClient(s.m.app).get("/catalog/movie/a%2e%2e/x.json").status_code,404)
if __name__=="__main__": unittest.main(verbosity=2)
