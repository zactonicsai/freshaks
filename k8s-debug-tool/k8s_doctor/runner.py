"""Safe subprocess execution for kubectl and helm.

Important security choices:
* Commands are passed as a list, never a shell command string.
* ``shell=True`` is never used.
* A timeout prevents a stuck CLI process from hanging forever.
* Environment variables are inherited but can be extended explicitly.
"""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import time
from pathlib import Path
from typing import Mapping, Sequence

from .models import CommandResult


class CommandError(RuntimeError):
    """Raised when a requested external executable is not available."""


class CommandRunner:
    """Run local commands and return normalized results."""

    def __init__(self, timeout: int = 30) -> None:
        self.timeout = timeout

    @staticmethod
    def require_binary(binary: str) -> str:
        """Return the executable path or raise a friendly error."""

        path = shutil.which(binary)
        if path is None:
            raise CommandError(
                f"Required executable '{binary}' was not found in PATH. "
                f"Install it or update PATH, then try again."
            )
        return path

    @staticmethod
    def printable(command: Sequence[str]) -> str:
        """Render a command safely for copy/paste and report output."""

        return shlex.join([str(part) for part in command])

    def run(
        self,
        command: Sequence[str],
        *,
        timeout: int | None = None,
        cwd: str | Path | None = None,
        env: Mapping[str, str] | None = None,
        input_text: str | None = None,
    ) -> CommandResult:
        """Run one command and capture stdout/stderr as text.

        ``check=False`` is deliberate. Kubernetes commands often return a
        non-zero code for a useful troubleshooting condition, and the caller
        should be able to report that result instead of crashing immediately.
        """

        if not command:
            raise ValueError("command cannot be empty")

        self.require_binary(str(command[0]))
        effective_env = os.environ.copy()
        if env:
            effective_env.update(env)

        started = time.monotonic()
        try:
            completed = subprocess.run(
                [str(part) for part in command],
                input=input_text,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                timeout=timeout or self.timeout,
                cwd=str(cwd) if cwd else None,
                env=effective_env,
            )
            duration = time.monotonic() - started
            return CommandResult(
                command=[str(part) for part in command],
                returncode=completed.returncode,
                stdout=completed.stdout.rstrip(),
                stderr=completed.stderr.rstrip(),
                duration_seconds=duration,
            )
        except subprocess.TimeoutExpired as exc:
            duration = time.monotonic() - started
            stdout = exc.stdout if isinstance(exc.stdout, str) else ""
            stderr = exc.stderr if isinstance(exc.stderr, str) else ""
            return CommandResult(
                command=[str(part) for part in command],
                returncode=124,
                stdout=stdout.rstrip(),
                stderr=(stderr.rstrip() + "\nCommand timed out.").strip(),
                duration_seconds=duration,
            )
