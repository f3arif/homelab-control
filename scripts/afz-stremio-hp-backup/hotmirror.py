#!/usr/bin/env python3
"""AFZ Stremio HP hot mirror helper.

select  SRC SEL                    Rebuild the newest-first movie selection under the cap.
verify  SRC BASE SEL OUT [--prune]  Check every source file of TV and the selected movies
                                    exists in the mirror with the same size. With --prune,
                                    and only when that check passed, remove mirror copies
                                    outside the selection (see prune()).

Pruning only ever touches BASE/Movies on the HP mirror. It never writes to SRC.
"""
import datetime, json, os, shutil, sys

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


def verify(src, base, sel_path, out_path, do_prune=False):
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

    if not os.path.isdir(os.path.join(src, "TV")):
        missing.append("TV/")
    compare("TV", "tv")
    for n in names:
        # A selected movie that vanished from the source must not pass vacuously.
        if not os.path.isdir(os.path.join(src, "Movies", n)):
            missing.append(os.path.join("Movies", n) + "/")
            continue
        compare(os.path.join("Movies", n), "movie")
    ok = not missing and not mismatched
    status = "completed" if ok else "verify-mismatch"
    if not do_prune:
        prune_result = {"result": "skipped:" + (os.getenv("AFZ_PRUNE_SKIP_REASON") or "not-requested")}
    elif not ok:
        prune_result = {"result": "skipped:verify-failed"}
    else:
        prune_result = prune(src, base, sel, os.path.join(base, "logs", "prune.log"))
        if prune_result["result"].startswith("error"):
            status = "prune-error"
    present = sorted(d.name for d in os.scandir(os.path.join(base, "Movies")) if d.is_dir())
    unselected = [n for n in present if n not in set(names)]
    st = os.statvfs(base)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({
            "status": status,
            "updatedUtc": now(),
            "selectedMovieCount": len(names),
            **counts,
            "missing": missing[:50],
            "sizeMismatch": mismatched[:50],
            "unselectedPresent": unselected,
            "prune": prune_result,
            "freeBytes": st.f_bavail * st.f_frsize,
        }, f, indent=2, ensure_ascii=False)
    if status == "prune-error":
        raise SystemExit(31)
    raise SystemExit(0 if ok else 30)


class Abort(Exception):
    pass


def _check(cond, reason):
    if not cond:
        raise Abort(reason)


def _files(root):
    """Relative path -> size for every regular file under root; aborts on symlinks."""
    out = {}
    for d, dirs, names in os.walk(root):
        for n in dirs + names:
            _check(not os.path.islink(os.path.join(d, n)), "symlink:" + os.path.relpath(os.path.join(d, n), root))
        for n in names:
            p = os.path.join(d, n)
            out[os.path.relpath(p, root)] = os.lstat(p).st_size
    return out


def prune(src, base, sel, log_path):
    """Remove mirror movie copies outside the active selection.

    Runs only after verify() passed for this selection. Every guard failure aborts
    before anything is removed. Removals are staged by rename on the mirror
    filesystem, logged file by file, then deleted.
    """
    max_dirs = int(os.getenv("AFZ_HOTMIRROR_PRUNE_MAX_DIRS") or 10)
    events = []

    def log(action, **kw):
        rec = {"ts": now(), "action": action, **kw}
        events.append(rec)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    try:
        if os.getenv("AFZ_HOTMIRROR_PRUNE", "1") != "1":
            return {"result": "skipped:disabled"}
        # The manifest must be the freshly built, internally consistent one.
        entries = sel.get("selectedMovies") or []
        names = [x.get("name") for x in entries]
        cap = int(sel.get("movieCapBytes") or 0)
        _check(sel.get("schema") == 3, "manifest-schema")
        _check(entries and all(isinstance(n, str) and n and "/" not in n and n not in (".", "..") for n in names), "manifest-names")
        _check(len(set(names)) == len(names), "manifest-duplicates")
        _check(sum(int(x.get("bytes") or 0) for x in entries) == int(sel.get("selectedMovieBytes") or -1), "manifest-bytes")
        _check(0 < int(sel["selectedMovieBytes"]) <= cap, "manifest-cap")
        # The source must be the live H3 mount and entirely separate from the mirror.
        movies = os.path.join(base, "Movies")
        src_movies = os.path.join(src, "Movies")
        _check(os.path.ismount(src), "source-not-mounted")
        _check(os.path.isdir(src_movies) and not os.path.islink(movies) and os.path.isdir(movies), "paths")
        _check(not os.path.ismount(movies), "mirror-movies-is-mount")
        rs, rm = os.path.realpath(src), os.path.realpath(movies)
        _check(os.path.commonpath([rs, rm]) not in (rs, rm), "source-mirror-overlap")
        _check(os.stat(rm).st_dev != os.stat(src_movies).st_dev, "source-mirror-same-device")
        src_dirs = {d.name for d in os.scandir(src_movies) if d.is_dir()}
        _check(set(names) <= src_dirs, "selected-missing-on-source")

        # Plan: whole movie folders outside the selection, plus files inside
        # selected folders that no longer exist on the source (e.g. replaced releases).
        plan = []
        for d in os.scandir(rm):
            _check(not d.is_symlink(), "symlink:" + d.name)
            _check(d.is_dir(follow_symlinks=False), "unexpected-entry:" + d.name)
            if d.name not in names:
                files = _files(d.path)
                plan.append({"kind": "movie-dir", "rel": d.name, "files": files, "bytes": sum(files.values())})
        for n in names:
            mirror_files = _files(os.path.join(rm, n))
            source_files = _files(os.path.join(src_movies, n))
            _check(source_files, "selected-source-empty:" + n)
            for rel, size in mirror_files.items():
                if rel not in source_files:
                    plan.append({"kind": "stale-file", "rel": os.path.join(n, rel), "files": {rel: size}, "bytes": size})
        dirs = [x for x in plan if x["kind"] == "movie-dir"]
        total = sum(x["bytes"] for x in plan)
        _check(len(dirs) <= max_dirs, f"too-many-dirs:{len(dirs)}>{max_dirs}")
        _check(total <= cap, "too-many-bytes")
        if not plan:
            return {"result": "nothing-to-prune"}

        stage = os.path.join(base, ".prune-staging", datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
        os.makedirs(stage)
        _check(os.stat(stage).st_dev == os.stat(rm).st_dev, "staging-device")
        free_before = shutil.disk_usage(base).free
        log("plan", items=[{"kind": x["kind"], "rel": x["rel"], "bytes": x["bytes"]} for x in plan], totalBytes=total)
    except Abort as e:
        log("abort", reason=str(e))
        return {"result": "aborted:" + str(e)}
    except Exception as e:
        log("abort", reason="error:" + repr(e))
        return {"result": "aborted:error:" + repr(e)}

    removed = []
    try:
        for i, x in enumerate(plan):
            path = os.path.join(rm, x["rel"])
            staged = os.path.join(stage, str(i))
            os.rename(path, staged)
            if os.path.isdir(staged):
                shutil.rmtree(staged)
            else:
                os.unlink(staged)
            for rel, size in sorted(x["files"].items()):
                log("removed", path=os.path.join(path, rel) if x["kind"] == "movie-dir" else path, bytes=size)
            removed.append(x["rel"])
        os.rmdir(stage)
    except Exception as e:
        log("error", reason=repr(e), removedSoFar=removed)
        return {"result": "error:" + repr(e), "removed": removed}
    freed = shutil.disk_usage(base).free - free_before
    log("done", removed=removed, totalBytes=total, freeDeltaBytes=freed)
    return {"result": "pruned", "removed": removed, "removedBytes": total}


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "select" and len(sys.argv) == 4:
        select(sys.argv[2], sys.argv[3])
    elif cmd == "verify" and len(sys.argv) in (6, 7) and sys.argv[6:] in ([], ["--prune"]):
        verify(*sys.argv[2:6], do_prune=sys.argv[6:] == ["--prune"])
    else:
        raise SystemExit(__doc__)
