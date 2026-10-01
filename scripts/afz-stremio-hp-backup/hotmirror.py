#!/usr/bin/env python3
"""AFZ Stremio HP hot mirror helper.

select  SRC SEL         Rebuild the newest-first movie selection under the cap.
verify  SRC BASE SEL OUT  Check every source file of TV and the selected movies
                          exists in the mirror with the same size.
"""
import datetime, json, os, sys

DEFAULT_CAP = 200 * 2**30


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def tree(path):
    total = files = 0
    latest = 0.0
    for root, _, names in os.walk(path):
        for n in names:
            try:
                st = os.stat(os.path.join(root, n))
            except OSError:
                continue
            total += st.st_size
            files += 1
            latest = max(latest, st.st_mtime)
    return total, files, latest


def load(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def select(src, sel_path):
    cur = load(sel_path)
    cap = int(os.getenv("AFZ_HOTMIRROR_MOVIE_CAP_BYTES") or cur.get("movieCapBytes") or DEFAULT_CAP)
    rows = []
    for d in os.scandir(os.path.join(src, "Movies")):
        if d.is_dir():
            b, _, latest = tree(d.path)
            if b > 0:
                rows.append({"name": d.name, "bytes": b, "latest": latest})
    if not rows:
        # An empty listing is a mount problem, not an empty library; keep the old selection.
        raise SystemExit("NO_SOURCE_MOVIES")
    rows.sort(key=lambda r: r["latest"], reverse=True)
    selected, total = [], 0
    for r in rows:
        if total + r["bytes"] <= cap:
            selected.append(r)
            total += r["bytes"]
    tv_bytes = tree(os.path.join(src, "TV"))[0]
    out = {
        "schema": 3,
        "createdUtc": now(),
        "sourceRoot": src,
        "movieCapBytes": cap,
        "selectedMovieBytes": total,
        "tvBytes": tv_bytes,
        "totalPlannedBytes": total + tv_bytes,
        "selectedMovies": [
            {
                "name": r["name"],
                "bytes": r["bytes"],
                "latest": datetime.datetime.fromtimestamp(r["latest"], datetime.timezone.utc).isoformat(),
            }
            for r in selected
        ],
    }
    old = {x.get("name") for x in cur.get("selectedMovies") or []}
    new = {r["name"] for r in selected}
    tmp = sel_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    os.replace(tmp, sel_path)
    print(f"SELECTION_OK movies={len(selected)} bytes={total} added={len(new - old)} dropped={len(old - new)}")


def verify(src, base, sel_path, out_path):
    sel = load(sel_path)
    names = [x["name"] for x in sel.get("selectedMovies") or []]
    mismatched, missing = [], []
    counts = {"tvBytes": 0, "tvFiles": 0, "movieBytes": 0, "movieFiles": 0}

    def compare(rel_root, kind):
        s_root = os.path.join(src, rel_root)
        for root, _, files in os.walk(s_root):
            for n in files:
                sp = os.path.join(root, n)
                rel = os.path.relpath(sp, src)
                try:
                    size = os.stat(sp).st_size
                except OSError:
                    continue
                try:
                    msize = os.stat(os.path.join(base, rel)).st_size
                except OSError:
                    missing.append(rel)
                    continue
                if msize != size:
                    mismatched.append(rel)
                    continue
                counts[kind + "Bytes"] += size
                counts[kind + "Files"] += 1

    compare("TV", "tv")
    for n in names:
        compare(os.path.join("Movies", n), "movie")
    present = sorted(d.name for d in os.scandir(os.path.join(base, "Movies")) if d.is_dir())
    unselected = [n for n in present if n not in set(names)]
    ok = not missing and not mismatched
    st = os.statvfs(base)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({
            "status": "completed" if ok else "verify-mismatch",
            "updatedUtc": now(),
            "selectedMovieCount": len(names),
            **counts,
            "missing": missing[:50],
            "sizeMismatch": mismatched[:50],
            "unselectedPresent": unselected,
            "freeBytes": st.f_bavail * st.f_frsize,
        }, f, indent=2, ensure_ascii=False)
    raise SystemExit(0 if ok else 30)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "select" and len(sys.argv) == 4:
        select(sys.argv[2], sys.argv[3])
    elif cmd == "verify" and len(sys.argv) == 6:
        verify(*sys.argv[2:6])
    else:
        raise SystemExit(__doc__)
