"""Small data models shared by the command runner, diagnostics, and renderers."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(slots=True)
class CommandResult:
    """Normalized result from a subprocess command.

    Keeping subprocess details in a simple object makes it easy to test the
    rest of the application without launching real commands.
    """

    command: list[str]
    returncode: int
    stdout: str = ""
    stderr: str = ""
    duration_seconds: float = 0.0

    @property
    def ok(self) -> bool:
        """Return True when the command completed successfully."""

        return self.returncode == 0


@dataclass(slots=True)
class Finding:
    """One diagnostic result shown to the user."""

    check: str
    status: str
    summary: str
    details: Any = None
    recommendation: str | None = None
    command: str | None = None


@dataclass(slots=True)
class Report:
    """Collection of diagnostic findings plus report metadata."""

    title: str
    context: str | None = None
    namespace: str | None = None
    findings: list[Finding] = field(default_factory=list)

    def add(
        self,
        check: str,
        status: str,
        summary: str,
        *,
        details: Any = None,
        recommendation: str | None = None,
        command: str | None = None,
    ) -> None:
        """Append a finding with one compact call."""

        self.findings.append(
            Finding(
                check=check,
                status=status,
                summary=summary,
                details=details,
                recommendation=recommendation,
                command=command,
            )
        )
