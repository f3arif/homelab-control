"""Single subprocess boundary for the staged H3 Python worker.

All native child processes must be launched through :func:`run_process`.
The wrapper is deliberately small, synchronous, and dependency-free so it can
be parity-tested before any live worker migration.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
import subprocess
import time
from typing import Mapping, Sequence

_CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


@dataclass(frozen=True)
class ProcessResult:
    argv: tuple[str, ...]
    exit_code: int | None
    stdout: str
    stderr: str
    duration_seconds: float
    timed_out: bool


def _validate_argv(argv: Sequence[str]) -> tuple[str, ...]:
    if isinstance(argv, (str, bytes)):
        raise TypeError("argv must be a sequence of arguments; shell strings are forbidden")
    normalized = tuple(str(part) for part in argv)
    if not normalized or not normalized[0].strip():
        raise ValueError("argv must contain an executable")
    if any("\x00" in part for part in normalized):
        raise ValueError("argv contains a NUL byte")
    return normalized


def _kill_process_tree(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    if os.name == "nt":
        # taskkill is invoked only inside this central process boundary and is
        # itself forced no-window. /T is important for wrappers such as cmd,
        # PowerShell, ffmpeg, git, ssh, adb, and Docker CLI that may spawn
        # descendants.
        try:
            subprocess.run(
                ["taskkill.exe", "/PID", str(proc.pid), "/T", "/F"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                shell=False,
                creationflags=_CREATE_NO_WINDOW,
                timeout=5,
                check=False,
            )
        except Exception:
            proc.kill()
    else:
        proc.kill()


def run_process(
    argv: Sequence[str],
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout_seconds: float = 60.0,
    env: Mapping[str, str] | None = None,
    input_text: str | None = None,
) -> ProcessResult:
    """Run one native process without an interactive console or prompt path.

    Non-zero process exits are returned verbatim; they are not converted into
    wrapper success. A timeout is reported separately with ``exit_code=None``.
    """

    args = _validate_argv(argv)
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")

    child_env = os.environ.copy()
    child_env.update(
        {
            "GIT_TERMINAL_PROMPT": "0",
            "GCM_INTERACTIVE": "Never",
        }
    )
    if env:
        child_env.update({str(k): str(v) for k, v in env.items()})

    started = time.monotonic()
    proc = subprocess.Popen(
        args,
        cwd=cwd,
        env=child_env,
        stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        shell=False,
        creationflags=_CREATE_NO_WINDOW,
    )

    timed_out = False
    try:
        stdout, stderr = proc.communicate(input=input_text, timeout=timeout_seconds)
        exit_code: int | None = int(proc.returncode)
    except subprocess.TimeoutExpired:
        timed_out = True
        _kill_process_tree(proc)
        stdout, stderr = proc.communicate()
        exit_code = None

    return ProcessResult(
        argv=args,
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        duration_seconds=time.monotonic() - started,
        timed_out=timed_out,
    )
