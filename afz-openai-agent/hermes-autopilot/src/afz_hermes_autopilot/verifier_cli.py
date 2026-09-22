"""Fresh-process verifier entrypoint for immutable health packets."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from .adapter import FixedControlHubClient, verify_packet


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packet", required=True, type=Path)
    parser.add_argument("--packet-sha256", required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--approval-id", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    receipt = verify_packet(
        args.packet,
        expected_packet_hash=args.packet_sha256,
        expected_commit=args.expected_commit,
        expected_source_hash=args.source_sha256,
        client=FixedControlHubClient(),
        verifier_pid=os.getpid(),
    )
    receipt["approval_id"] = args.approval_id
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(args.output.name + ".tmp")
    temporary.write_text(
        json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    temporary.replace(args.output)
    print(
        json.dumps(
            {"ok": True, "receipt": str(args.output), "verifier_pid": os.getpid()}
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
