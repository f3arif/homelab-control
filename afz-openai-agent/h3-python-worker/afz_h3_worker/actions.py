"""Offline action adapters for evidence-bounded H3 parity work.

These functions do not claim work, perform network I/O, schedule jobs, or own
worker liveness. They only reproduce local action semantics already observed on
the legacy H3 Generic Worker.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable

from .parity import sha256_file


class ActionContractError(ValueError):
    """Raised when a candidate action would exceed the observed legacy contract."""


def _normal(path: Path) -> str:
    return os.path.normcase(os.path.abspath(os.fspath(path)))


def resolve_readonly_file(path: str | Path, allowed_roots: Iterable[str | Path]) -> Path:
    """Resolve one existing file and prove it is inside an allowed read-only root."""

    candidate = Path(path).expanduser().resolve(strict=True)
    if not candidate.is_file():
        raise ActionContractError(f"path is not a file: {candidate}")

    roots = tuple(Path(root).expanduser().resolve(strict=True) for root in allowed_roots)
    if not roots:
        raise ActionContractError("at least one read-only root is required")

    candidate_text = _normal(candidate)
    for root in roots:
        if not root.is_dir():
            raise ActionContractError(f"read-only root is not a directory: {root}")
        root_text = _normal(root)
        try:
            if os.path.commonpath((candidate_text, root_text)) == root_text:
                return candidate
        except ValueError:
            # Different Windows drives (or otherwise incomparable paths) are
            # simply outside this root.
            continue

    raise ActionContractError(f"path outside read-only roots: {candidate}")


def h3_file_hash(path: str | Path, *, allowed_roots: Iterable[str | Path]) -> dict[str, list[str]]:
    """Reproduce the observed legacy ``h3-file-hash`` result payload.

    Legacy evidence shows an uppercase SHA-256 digest and a three-line
    ``summary`` array. The action is intentionally local/read-only.
    """

    resolved = resolve_readonly_file(path, allowed_roots)
    digest = sha256_file(resolved).upper()
    return {
        "summary": [
            "FILE_HASH : READ ONLY",
            f"PATH={resolved}",
            f"SHA256={digest}",
        ]
    }
