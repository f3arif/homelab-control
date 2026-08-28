#!/usr/bin/env python3
import asyncio
import importlib.util
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: smoke_afz_agent_pipe.py <pipe.py>")

    pipe_path = Path(sys.argv[1])
    if not pipe_path.is_file():
        raise RuntimeError(f"AFZ pipe source missing: {pipe_path}")

    spec = importlib.util.spec_from_file_location("afz_agent_pipe", str(pipe_path))
    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load AFZ pipe module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    pipe = module.Pipe()
    body = {
        "model": "torbox-auto",
        "messages": [
            {
                "role": "user",
                "content": (
                    "Use afz_system_status and jellyfin_public_info exactly once each. "
                    "Do not call any other tools. Read-only only. Report concise status."
                ),
            }
        ],
    }
    output = asyncio.run(pipe.pipe(body))
    text = str(output)
    bad_prefixes = (
        "AFZ Agent error",
        "AFZ Agent connection error",
        "AFZ Agent HTTP error",
    )
    ok = not text.startswith(bad_prefixes)
    print(json.dumps({"ok": ok, "output": text[:12000]}, separators=(",", ":")))
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
