#!/usr/bin/env python3
import json
import sqlite3
import sys
import time
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: install_afz_agent_pipe.py <webui.db> <pipe.py> <backup-dir>")

    db = Path(sys.argv[1])
    pipe = Path(sys.argv[2])
    backup_dir = Path(sys.argv[3])
    if not db.is_file():
        raise RuntimeError(f"OpenWebUI database missing: {db}")
    if not pipe.is_file():
        raise RuntimeError(f"AFZ pipe source missing: {pipe}")

    source = pipe.read_text(encoding="utf-8")
    now = int(time.time())
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup = backup_dir / f"webui-before-afz-pipe-{now}.db"

    src = sqlite3.connect(str(db), timeout=20)
    dst = sqlite3.connect(str(backup))
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()

    con = sqlite3.connect(str(db), timeout=20)
    try:
        tables = {row[0] for row in con.execute("select name from sqlite_master where type='table'")}
        if "function" not in tables:
            raise RuntimeError("OpenWebUI function table not found")

        info = list(con.execute('pragma table_info("function")'))
        cols = {row[1]: row for row in info}

        user_id = None
        if "user" in tables:
            ucols = {row[1] for row in con.execute('pragma table_info("user")')}
            if "id" in ucols:
                row = None
                if "role" in ucols:
                    row = con.execute(
                        'select id from "user" where lower(role)=? order by rowid limit 1',
                        ("admin",),
                    ).fetchone()
                if not row:
                    row = con.execute('select id from "user" order by rowid limit 1').fetchone()
                if row:
                    user_id = row[0]

        existing = con.execute(
            'select id from "function" where id=?', ("afz_typed_agent",)
        ).fetchone()
        values = {
            "id": "afz_typed_agent",
            "user_id": user_id,
            "name": "AFZ Typed Agent",
            "type": "pipe",
            "content": source,
            "meta": json.dumps(
                {
                    "description": "AFZ typed-agent bridge to Windows-main",
                    "manifest": {"title": "AFZ Typed Agent", "version": "0.1.0"},
                },
                separators=(",", ":"),
            ),
            "is_active": 1,
            "is_global": 0,
            "updated_at": now,
            "created_at": now,
            "valves": None,
        }

        if existing:
            update_keys = [
                key
                for key in (
                    "user_id",
                    "name",
                    "type",
                    "content",
                    "meta",
                    "is_active",
                    "is_global",
                    "updated_at",
                )
                if key in cols
            ]
            con.execute(
                'update "function" set '
                + ",".join(f'"{key}"=?' for key in update_keys)
                + " where id=?",
                [values[key] for key in update_keys] + ["afz_typed_agent"],
            )
            action = "updated"
        else:
            insert_keys = [key for key in values if key in cols]
            missing = []
            for name, row in cols.items():
                not_null = bool(row[3])
                default = row[4]
                primary_key = bool(row[5])
                if not_null and default is None and not primary_key and name not in insert_keys:
                    missing.append(name)
            if missing:
                raise RuntimeError("Unsupported required function columns: " + ",".join(missing))
            con.execute(
                'insert into "function" ('
                + ",".join(f'"{key}"' for key in insert_keys)
                + ") values ("
                + ",".join("?" for _ in insert_keys)
                + ")",
                [values[key] for key in insert_keys],
            )
            action = "created"

        con.commit()
        row = con.execute(
            'select id,name,type,is_active,is_global,updated_at from "function" where id=?',
            ("afz_typed_agent",),
        ).fetchone()
        print(
            json.dumps(
                {
                    "ok": True,
                    "action": action,
                    "backup": str(backup),
                    "function": row,
                    "columns": sorted(cols),
                },
                separators=(",", ":"),
            )
        )
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
