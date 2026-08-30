"""Strict side-by-side parity helpers for legacy-vs-candidate execution."""

from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import json
from pathlib import Path
from typing import Any, Iterable, Mapping

from .process import ProcessResult


@dataclass(frozen=True)
class ParityReport:
    ok: bool
    checks: Mapping[str, bool]
    differences: tuple[str, ...] = field(default_factory=tuple)


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compare_process_results(legacy: ProcessResult, candidate: ProcessResult) -> ParityReport:
    checks = {
        "timed_out": legacy.timed_out == candidate.timed_out,
        "exit_code": legacy.exit_code == candidate.exit_code,
        "stdout": legacy.stdout == candidate.stdout,
        "stderr": legacy.stderr == candidate.stderr,
    }
    differences = tuple(name for name, passed in checks.items() if not passed)
    return ParityReport(ok=all(checks.values()), checks=checks, differences=differences)


def _strip_volatile(value: Any, ignore_keys: frozenset[str]) -> Any:
    if isinstance(value, dict):
        return {
            key: _strip_volatile(item, ignore_keys)
            for key, item in sorted(value.items())
            if key not in ignore_keys
        }
    if isinstance(value, list):
        return [_strip_volatile(item, ignore_keys) for item in value]
    return value


def semantic_json_equal(
    legacy_text: str,
    candidate_text: str,
    *,
    ignore_keys: Iterable[str] = (),
) -> bool:
    ignored = frozenset(ignore_keys)
    legacy = _strip_volatile(json.loads(legacy_text), ignored)
    candidate = _strip_volatile(json.loads(candidate_text), ignored)
    return legacy == candidate
