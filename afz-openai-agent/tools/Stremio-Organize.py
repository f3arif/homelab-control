import argparse
import json
import socket
import time
from urllib.parse import urlsplit

MARIONETTE_HOST = "127.0.0.1"
MARIONETTE_PORT = 2828
STREMIO_WEB = "https://web.stremio.com/"
AFZ_MANIFEST = "https://desktop-10skf0m.tailc9bb62.ts.net:18767/manifest.json"

def recv_message(sock):
    header = b""
    while b":" not in header:
        chunk = sock.recv(1)
        if not chunk:
            raise RuntimeError("Marionette connection closed while reading header")
        header += chunk
    length = int(header[:-1])
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise RuntimeError("Marionette connection closed while reading payload")
        data += chunk
    return json.loads(data.decode("utf-8"))

def send_message(sock, obj):
    data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    sock.sendall(str(len(data)).encode("ascii") + b":" + data)

def command(sock, seq, name, params):
    send_message(sock, [0, seq, name, params])
    reply = recv_message(sock)
    if not isinstance(reply, list) or len(reply) < 4:
        raise RuntimeError(f"Invalid Marionette response for {name}: {reply!r}")
    if reply[2]:
        raise RuntimeError(f"Marionette {name} failed: {reply[2]!r}")
    return reply[3]

def find_stremio_window(sock, seq):
    handles = command(sock, seq, "WebDriver:GetWindowHandles", {})
    seq += 1
    for handle in handles:
        command(sock, seq, "WebDriver:SwitchToWindow", {"handle": handle})
        seq += 1
        current = command(sock, seq, "WebDriver:GetCurrentURL", {})
        seq += 1
        url = (current or {}).get("value", "")
        if urlsplit(url).netloc == "web.stremio.com":
            return seq, handle
    if not handles:
        raise RuntimeError("Firefox has no Marionette windows")
    command(sock, seq, "WebDriver:SwitchToWindow", {"handle": handles[0]})
    seq += 1
    command(sock, seq, "WebDriver:Navigate", {"url": STREMIO_WEB})
    seq += 1
    time.sleep(5)
    return seq, handles[0]

def execute_async(sock, seq, script, timeout_ms=40000):
    result = command(sock, seq, "WebDriver:ExecuteAsyncScript", {
        "script": script,
        "args": [],
        "newSandbox": True,
        "sandbox": "default",
        "scriptTimeout": timeout_ms,
        "line": 1,
        "filename": "afz-stremio-organize"
    })
    return seq + 1, (result or {}).get("value")

def execute(sock, seq, script):
    result = command(sock, seq, "WebDriver:ExecuteScript", {
        "script": script,
        "args": [],
        "newSandbox": True,
        "sandbox": "default",
        "line": 1,
        "filename": "afz-stremio-organize"
    })
    return seq + 1, (result or {}).get("value")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=("audit", "apply"), default="audit")
    args = parser.parse_args()

    sock = socket.create_connection((MARIONETTE_HOST, MARIONETTE_PORT), 6)
    sock.settimeout(55)
    hello = recv_message(sock)
    if hello.get("applicationType") != "gecko":
        raise RuntimeError(f"Unexpected Marionette peer: {hello!r}")

    seq = 1
    command(sock, seq, "WebDriver:NewSession", {"capabilities": {"alwaysMatch": {}}})
    seq += 1
    seq, _ = find_stremio_window(sock, seq)

    action_json = json.dumps(args.action)
    manifest_json = json.dumps(AFZ_MANIFEST)
    js = r"""
const done = arguments[arguments.length - 1];
(async () => {
  const action = ACTION_VALUE;
  const afzManifestUrl = AFZ_MANIFEST_VALUE;
  const profile = JSON.parse(localStorage.getItem('profile') || '{}');
  const authKey = profile?.auth?.key;
  if (!authKey) return done({ok:false,error:'stremio-auth-missing'});

  async function api(path, body) {
    const r = await fetch('https://api.strem.io/api/' + path, {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify(body)
    });
    const text = await r.text();
    let data = {};
    try { data = JSON.parse(text); } catch (_) {}
    if (!r.ok) throw new Error(path + ' HTTP ' + r.status);
    return data;
  }

  const beforeData = await api('addonCollectionGet', {authKey});
  const before = beforeData?.result?.addons || [];
  const namesBefore = before.map(a => a?.manifest?.name || a?.manifest?.id || '');
  const backupKey = 'AFZ_STREMIO_BACKUP_' + new Date().toISOString().replace(/[:.]/g,'-');
  localStorage.setItem(backupKey, JSON.stringify(before));

  function summary(addons) {
    const afz = addons.find(a => a?.manifest?.id === 'com.afzengineering.releasecatalog' || a?.manifest?.name === 'AFZ New Movie Releases');
    const trakt = addons.find(a => a?.manifest?.name === 'Trakt Integration');
    const tv = addons.find(a => a?.manifest?.name === 'Debridio - TV');
    return {
      count:addons.length,
      order:addons.map(a => a?.manifest?.name || a?.manifest?.id || ''),
      afzVersion:afz?.manifest?.version || null,
      traktCatalogs:(trakt?.manifest?.catalogs || []).map(c => c?.name || c?.id || ''),
      debridioTvCatalogs:(tv?.manifest?.catalogs || []).map(c => c?.name || c?.id || '')
    };
  }

  if (action === 'audit') {
    return done({ok:true,action,backupKey,before:summary(before)});
  }

  let addons = JSON.parse(JSON.stringify(before));
  let afzManifestRefreshed = false;
  let afzRefreshError = null;
  let afz = addons.find(a => a?.manifest?.id === 'com.afzengineering.releasecatalog' || a?.manifest?.name === 'AFZ New Movie Releases');
  try {
    const mr = await fetch(afzManifestUrl, {cache:'no-store'});
    if (!mr.ok) throw new Error('HTTP ' + mr.status);
    const live = await mr.json();
    if (live?.id !== 'com.afzengineering.releasecatalog') throw new Error('unexpected manifest id');
    if (afz) {
      afz.manifest = live;
      afz.transportUrl = afzManifestUrl;
    } else {
      afz = {transportUrl:afzManifestUrl, manifest:live, flags:{}};
      addons.push(afz);
    }
    afzManifestRefreshed = true;
  } catch (e) {
    afzRefreshError = String(e);
  }

  const trakt = addons.find(a => a?.manifest?.name === 'Trakt Integration');
  if (trakt?.manifest?.catalogs) {
    trakt.manifest.catalogs = trakt.manifest.catalogs.filter(c => ['watchlist','recommendations'].includes(c?.id));
  }

  const tv = addons.find(a => a?.manifest?.name === 'Debridio - TV');
  if (tv?.manifest?.catalogs) {
    tv.manifest.catalogs = tv.manifest.catalogs.filter(c => ['ca','in'].includes(c?.id));
  }

  const priority = [
    'AFZ New Movie Releases',
    'Cinemeta',
    'Trakt Integration',
    'Kids Shows Age 3 to 8',
    'EinthusanTV - Hindi',
    'Sports Streams',
    'Debridio - TV',
    'Store | TB',
    'Torrentio RD',
    'Comet | ElfHosted | RD',
    'Torrentio TB',
    'Comet | ElfHosted | TB',
    'StremThru Torz',
    'Debridio - TB',
    'OpenSubtitles v3',
    'IMDb Ratings',
    'WatchHub',
    'Local Files (without catalog support)'
  ];
  const rank = new Map(priority.map((n,i) => [n,i]));
  addons = addons.map((a,i) => ({a,i})).sort((x,y) => {
    const nx = x.a?.manifest?.name || '';
    const ny = y.a?.manifest?.name || '';
    const rx = rank.has(nx) ? rank.get(nx) : 1000 + x.i;
    const ry = rank.has(ny) ? rank.get(ny) : 1000 + y.i;
    return rx - ry;
  }).map(x => x.a);

  const setData = await api('addonCollectionSet', {authKey, addons});
  const verifyData = await api('addonCollectionGet', {authKey});
  const after = verifyData?.result?.addons || [];
  const afterSummary = summary(after);
  const expectedAfz = afzManifestRefreshed ? '0.3.1' : summary(before).afzVersion;
  if (afzManifestRefreshed && afterSummary.afzVersion !== expectedAfz) {
    await api('addonCollectionSet', {authKey, addons:before});
    return done({ok:false,error:'AFZ manifest refresh did not persist; original collection restored',backupKey,before:summary(before),after:afterSummary});
  }

  done({
    ok:true,
    action,
    backupKey,
    setAccepted:true,
    afzManifestRefreshed,
    afzRefreshError,
    before:summary(before),
    after:afterSummary,
    changed:JSON.stringify(namesBefore) !== JSON.stringify(afterSummary.order) ||
      JSON.stringify(summary(before).traktCatalogs) !== JSON.stringify(afterSummary.traktCatalogs) ||
      JSON.stringify(summary(before).debridioTvCatalogs) !== JSON.stringify(afterSummary.debridioTvCatalogs) ||
      summary(before).afzVersion !== afterSummary.afzVersion
  });
})().catch(e => done({ok:false,error:String(e)}));
"""
    js = js.replace("ACTION_VALUE", action_json).replace("AFZ_MANIFEST_VALUE", manifest_json)
    seq, result = execute_async(sock, seq, js)

    if args.action == "apply" and result and result.get("ok"):
        command(sock, seq, "WebDriver:Navigate", {"url": "https://web.stremio.com/#/"})
        seq += 1
        time.sleep(6)
        rows_js = r"""
return [...document.querySelectorAll('*')]
  .filter(e => e.children.length === 0)
  .map(e => (e.textContent || '').trim())
  .filter(t => / - (Movie|Series|Other|Sport|Tv|TV channel|Collections|MDBList|Trakt|Letterboxd|Channel)$/.test(t))
  .slice(0,120);
"""
        seq, rows = execute(sock, seq, rows_js)
        result["homeRows"] = rows or []
        result["homeRowCount"] = len(rows or [])

    sock.close()
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"ok":False,"error":str(exc)}, ensure_ascii=True, separators=(",", ":")))
        raise
