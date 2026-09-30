"""Execute the single authorized H3-to-Windows-main read-only health canary."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .canary import execute_health_canary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-db", required=True, type=Path)
    parser.add_argument("--admission-db", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--authorization-key", required=True)
    parser.add_argument("--source-task-id", default="t_834aebec")
    parser.add_argument(
        "--source-task-status", default="triage", choices=("triage", "blocked")
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    result = execute_health_canary(
        state_db=args.state_db,
        admission_db=args.admission_db,
        evidence_dir=args.evidence_dir,
        authorization_key=args.authorization_key,
        source_task_id=args.source_task_id,
        source_task_status=args.source_task_status,
    )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["canary_readback_status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
