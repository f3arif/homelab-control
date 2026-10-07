#!/usr/bin/env python3
"""Reproducible, guarded edits to the existing private Pi recovery source.

This module contains no device addresses. It transforms text in memory; callers
must verify source hashes, back up originals, and deploy atomically.
"""
import re


def once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Expected exactly one source anchor: {old[:70]!r}")
    return source.replace(old, new, 1)


def server(source):
    source = once(source,
        "def hp_online():\n    ok,code,_=fetch(HP_DIRECT+'/api/hp-health',1.8); return bool(ok and code==200) or tcp(HP_LAN,22)",
        "def hp_online():\n    if tcp(HP_LAN,22): return True\n    ok,code,_=fetch(HP_DIRECT+'/api/hp-health',6.0); return bool(ok and code==200)")
    source = once(source,
        "hp_ok,hp_code,hp_body=fetch(HP_DIRECT+'/api/hp-health',1.8)",
        "hp_ok,hp_code,hp_body=fetch(HP_DIRECT+'/api/hp-health',6.0)")
    source = once(source,
        "    win_ok,win_code,_=fetch(WIN_URL+'/api/health',2.0)\n    if not win_ok: win_ok,win_code,_=fetch(WIN_DIRECT+'/api/health',1.2)\n", "")
    source, count = re.subn(r"^WIN_URL=.*\n", "", source, flags=re.MULTILINE)
    if count != 1:
        raise ValueError("Expected exactly one retired Windows configuration line")
    source = once(source,
        "'windows':{'online':bool(win_ok),'http':win_code,'url':WIN_URL,'direct':WIN_DIRECT}",
        "'windows':{'online':False,'http':0,'retired':True}")
    source, count = re.subn(
        r"<div class='card'><div class='row'><div><b>Windows Ops Fallback</b>.*?(?=<div class='actions'><button id='refresh'>)",
        "", source)
    if count != 1:
        raise ValueError("Expected exactly one retired Windows dashboard card")
    source = once(source,
        ";ss('win',d.windows.online,d.windows.online?'Fallback reachable':'Fallback may still work from another tailnet client')", "")
    source = once(source, ";ss('win',false,'Recovery status error')", "")
    source = once(source, "Raspberry Pi edge fallback", "Raspberry Pi recovery")
    source = once(source,
        "ThreadingHTTPServer((HOST,PORT),H).serve_forever()",
        "if __name__ == '__main__':\n    ThreadingHTTPServer((HOST,PORT),H).serve_forever()")
    compile(source, "server.py", "exec")
    return source


def watchdog(source):
    """Keep the existing wake policy and targets; widen bounded request budgets."""
    source = once(source, 'wget -q -O /dev/null -T 2 "$HP"',
                  'wget -q -O /dev/null -T 8 "$HP"')
    source = once(source, 'wget -q -O - -T 3 "$REC_STATUS"',
                  'wget -q -O - -T 10 "$REC_STATUS"')
    source = once(source, 'wget -q -O - -T 4 --post-data=',
                  'wget -q -O - -T 10 --post-data=')
    return source


def nginx(source, retired_origin):
    """Remove only the explicitly identified retired secondary origin."""
    return once(source, f'    server {retired_origin} backup;\n', '')
