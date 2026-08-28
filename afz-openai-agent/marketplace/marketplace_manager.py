#!/usr/bin/env python3
"""AFZ Marketplace Manager: local inventory + deterministic dry-run queue.

No Facebook/Meta credentials are stored here and this module does not call an
unsupported Marketplace Graph API. Listing data remains on the worker.
"""
from __future__ import annotations
import argparse, csv, datetime as dt, json, os, sqlite3
from decimal import Decimal
from pathlib import Path

HOME = Path(os.environ.get("AFZ_MARKETPLACE_HOME", r"C:\ProgramData\AFZ\MarketplaceManager"))
DB = HOME / "marketplace.db"
CFG = HOME / "config.json"
DEFAULT = {
    "stale_days": 14,
    "deep_stale_days": 30,
    "price_drop_amount": 10.0,
    "minimum_price": 20.0,
    "currency": "CAD",
    "hold_when_messages": True,
    "queue_refresh": True,
    "queue_reprice": True,
    "queue_relist": False
}
SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS listings(
 id INTEGER PRIMARY KEY, url TEXT UNIQUE NOT NULL, external_id TEXT, title TEXT NOT NULL,
 description TEXT NOT NULL DEFAULT '', price_cents INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'active',
 posted_at TEXT NOT NULL, refreshed_at TEXT, messages_count INTEGER NOT NULL DEFAULT 0,
 locked INTEGER NOT NULL DEFAULT 0, notes TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS actions(
 id INTEGER PRIMARY KEY, listing_id INTEGER NOT NULL, action_type TEXT NOT NULL,
 payload_json TEXT NOT NULL, reason TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending',
 created_at TEXT NOT NULL, applied_at TEXT, FOREIGN KEY(listing_id) REFERENCES listings(id));
CREATE INDEX IF NOT EXISTS idx_actions_state ON actions(state);
"""

def now(): return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
def cents(v): return int(Decimal(str(v)).quantize(Decimal('0.01')) * 100)
def money(v): return float(Decimal(v) / Decimal(100))
def parse_date(v):
    if not v: return dt.datetime.now(dt.timezone.utc)
    v=str(v).strip().replace('Z','+00:00')
    x=dt.datetime.fromisoformat(v)
    if x.tzinfo is None: x=x.replace(tzinfo=dt.timezone.utc)
    return x.astimezone(dt.timezone.utc)
def con():
    HOME.mkdir(parents=True, exist_ok=True)
    c=sqlite3.connect(DB); c.row_factory=sqlite3.Row; c.execute('PRAGMA foreign_keys=ON'); return c

def init():
    HOME.mkdir(parents=True, exist_ok=True)
    with con() as c: c.executescript(SCHEMA)
    if not CFG.exists(): CFG.write_text(json.dumps(DEFAULT,indent=2)+'\n',encoding='utf-8')
    return {"ok":True,"home":str(HOME),"db":str(DB),"config":str(CFG)}
def cfg():
    out=dict(DEFAULT)
    if CFG.exists(): out.update(json.loads(CFG.read_text(encoding='utf-8')))
    return out

def upsert(r):
    url=str(r.get('url','')).strip(); title=str(r.get('title','')).strip()
    if not url or not title: raise ValueError('url and title required')
    ts=now(); posted=parse_date(r.get('posted_at') or ts).isoformat(); rr=str(r.get('refreshed_at') or '').strip(); refreshed=parse_date(rr).isoformat() if rr else None
    locked=str(r.get('locked') or '0').lower() in {'1','true','yes','y'}
    with con() as c:
        c.execute("""INSERT INTO listings(url,external_id,title,description,price_cents,status,posted_at,refreshed_at,messages_count,locked,notes,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(url) DO UPDATE SET external_id=excluded.external_id,title=excluded.title,
        description=excluded.description,price_cents=excluded.price_cents,status=excluded.status,posted_at=excluded.posted_at,
        refreshed_at=excluded.refreshed_at,messages_count=excluded.messages_count,locked=excluded.locked,notes=excluded.notes,updated_at=excluded.updated_at""",
        (url,str(r.get('external_id') or '') or None,title,str(r.get('description') or ''),cents(r.get('price') or 0),str(r.get('status') or 'active'),posted,refreshed,int(r.get('messages_count') or 0),1 if locked else 0,str(r.get('notes') or ''),ts))
def import_csv(path):
    n=0
    with open(path,newline='',encoding='utf-8-sig') as f:
        for r in csv.DictReader(f): upsert(r); n+=1
    return {"ok":True,"imported":n}
def queue(c,lid,typ,payload,reason):
    p=json.dumps(payload,sort_keys=True,separators=(',',':'))
    existing=c.execute("SELECT id FROM actions WHERE listing_id=? AND action_type=? AND payload_json=? AND state='pending'",(lid,typ,p)).fetchone()
    if existing: return False
    c.execute("INSERT INTO actions(listing_id,action_type,payload_json,reason,state,created_at) VALUES(?,?,?,?, 'pending',?)",(lid,typ,p,reason,now())); return True
def audit(write=False):
    C=cfg(); t=dt.datetime.now(dt.timezone.utc); out=[]; q=0
    with con() as c:
        for r in c.execute("SELECT * FROM listings WHERE status='active' ORDER BY id"):
            base=parse_date(r['refreshed_at'] or r['posted_at']); age=max(0,(t-base).days); findings=[]; proposed=[]
            if r['locked']: findings.append('locked')
            elif C['hold_when_messages'] and r['messages_count']>0: findings.append('hold_messages')
            elif age>=int(C['stale_days']):
                findings.append('stale')
                if C['queue_reprice']:
                    new=max(cents(C['minimum_price']),r['price_cents']-cents(C['price_drop_amount']))
                    if new<r['price_cents']: proposed.append(('reprice',{'price':money(new),'currency':C['currency']},f"stale {age} days"))
                if C['queue_refresh']: proposed.append(('refresh',{},f"stale {age} days"))
                if age>=int(C['deep_stale_days']):
                    findings.append('deep_stale'); proposed.append(('rewrite_review',{'fields':['title','description']},f"deep stale {age} days"))
                    if C['queue_relist']: proposed.append(('relist',{},f"deep stale {age} days"))
            if write:
                for typ,payload,reason in proposed:
                    if queue(c,r['id'],typ,payload,reason): q+=1
            out.append({'id':r['id'],'url':r['url'],'title':r['title'],'price':money(r['price_cents']),'age_days':age,'messages_count':r['messages_count'],'findings':findings,'proposed':[{'action':a,'payload':p,'reason':z} for a,p,z in proposed]})
    return {'ok':True,'queued':q,'listings':out}
def status():
    with con() as c:
        active=c.execute("SELECT COUNT(*) FROM listings WHERE status='active'").fetchone()[0]
        pending=c.execute("SELECT COUNT(*) FROM actions WHERE state='pending'").fetchone()[0]
        held=c.execute("SELECT COUNT(*) FROM listings WHERE locked=1 OR messages_count>0").fetchone()[0]
    return {'ok':True,'active_listings':active,'pending_actions':pending,'held_listings':held,'db':str(DB)}
def export_actions(path=None):
    with con() as c:
        rows=c.execute("SELECT a.id,a.action_type,a.payload_json,a.reason,l.url,l.title,l.description,l.price_cents FROM actions a JOIN listings l ON l.id=a.listing_id WHERE a.state='pending' ORDER BY a.id").fetchall()
    doc={'schema':1,'generated_at':now(),'actions':[{'action_id':r['id'],'listing_url':r['url'],'current_title':r['title'],'current_description':r['description'],'current_price':money(r['price_cents']),'action':r['action_type'],'payload':json.loads(r['payload_json']),'reason':r['reason']} for r in rows]}
    if path: Path(path).write_text(json.dumps(doc,indent=2)+'\n',encoding='utf-8')
    return doc

def main():
    p=argparse.ArgumentParser(); s=p.add_subparsers(dest='cmd',required=True)
    s.add_parser('init'); i=s.add_parser('import-csv'); i.add_argument('path'); a=s.add_parser('audit'); a.add_argument('--queue',action='store_true'); e=s.add_parser('export-actions'); e.add_argument('--out'); s.add_parser('status')
    x=p.parse_args(); init()
    if x.cmd=='init': r=init()
    elif x.cmd=='import-csv': r=import_csv(x.path)
    elif x.cmd=='audit': r=audit(x.queue)
    elif x.cmd=='export-actions': r=export_actions(x.out)
    else: r=status()
    print(json.dumps(r,indent=2)); return 0
if __name__=='__main__': raise SystemExit(main())
