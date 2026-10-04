#!/usr/bin/env python3
# ^ "Shebang" line: on Linux/macOS it lets you run the file directly
#   (./python_template.py) using whichever python3 is first on your PATH.
"""Reusable Python template.

What it does:
  * Reads data from a file, from standard input, or straight from the command line.
  * Parses JSON, YAML, XML, and Java-style .properties data.
  * Runs the shell command `ps` to show running processes.
  * Logs what it is doing to the screen and (optionally) to a log file.

Examples:
  python python_template.py --file config.json
  python python_template.py --data '{"name": "Ada"}' --format json
  cat config.yaml | python python_template.py --file - --format yaml
  python python_template.py --ps --top 5
"""
# ^ Module docstring: the first string in a file. `python -m pydoc python_template`
#   shows it, and we reuse it as the --help text further down.

# Lets us write modern type hints such as `list[str]` and `str | None`
# even on slightly older Python 3 versions. Must be the first import.
from __future__ import annotations

# --- Standard library imports (alphabetical, one per line: PEP 8 style) -----
import argparse                     # Reads command-line arguments like --file.
import json                         # Reads and writes JSON text.
import logging                      # Records messages (info, warnings, errors).
import shutil                       # We use shutil.which() to check a command exists.
import subprocess                   # Runs other programs, such as `ps`.
import sys                          # Gives access to stdin, stderr, and exit codes.
import xml.etree.ElementTree as ET  # Built-in XML reader; "ET" is the usual nickname.
from dataclasses import asdict, dataclass  # Tools for small "data holder" classes.
from pathlib import Path            # Modern, safe way to work with file paths.
from typing import Any, Callable    # Names used only in type hints.

# --- Third-party import (optional) ------------------------------------------
# YAML is not built into Python. Install it with:  pip install pyyaml
try:                                # Try to load the YAML library...
    import yaml                     # ...this succeeds if PyYAML is installed.
except ImportError:                 # If it is NOT installed, Python raises ImportError.
    yaml = None                     # Remember that YAML is unavailable; do not crash yet.

# --- Module-level constants (UPPER_CASE names mean "do not change me") ------
# One logger per module, named after the module. Never use print() for logs.
logger = logging.getLogger(__name__)

# Maps a file extension to the format name we use inside this program.
EXTENSION_TO_FORMAT: dict[str, str] = {
    ".json": "json",                # config.json        -> "json"
    ".yaml": "yaml",                # config.yaml        -> "yaml"
    ".yml": "yaml",                 # config.yml         -> "yaml" (short form)
    ".xml": "xml",                  # config.xml         -> "xml"
    ".properties": "properties",    # app.properties     -> "properties"
}

# The format names a user may type after --format, sorted for a tidy help message.
SUPPORTED_FORMATS: list[str] = sorted(set(EXTENSION_TO_FORMAT.values()))

# How long (in seconds) we let `ps` run before giving up. Never wait forever.
PS_TIMEOUT_SECONDS: int = 10

# Exit codes: 0 means success; anything else tells the shell something failed.
EXIT_OK: int = 0                    # Everything worked.
EXIT_ERROR: int = 1                 # A problem we understood and reported.
EXIT_USAGE: int = 2                 # The user ran the program incorrectly.
EXIT_INTERRUPTED: int = 130         # The user pressed Ctrl+C (Unix convention).


# =============================================================================
# Custom exceptions
# =============================================================================
class TemplateError(Exception):
    """Base class for every error this program raises on purpose."""
    # Having one base class lets main() catch all "expected" errors in one place.


class ParseError(TemplateError):
    """Raised when input data cannot be read or understood."""


class CommandError(TemplateError):
    """Raised when a shell command cannot be run or fails."""


# =============================================================================
# Data class: one running process
# =============================================================================
@dataclass(frozen=True)             # Auto-writes __init__, __repr__, etc. for us.
class ProcessInfo:                  # frozen=True makes objects read-only (safer).
    """One row from the `ps` command."""

    pid: int                        # Process ID: the process's unique number.
    ppid: int                       # Parent process ID: who started this process.
    user: str                       # The account that owns the process.
    cpu_percent: float              # Share of CPU the process is using.
    mem_percent: float              # Share of memory (RAM) the process is using.
    command: str                    # The program name.


# =============================================================================
# Class: DataParser - turns text into Python data
# =============================================================================
class DataParser:
    """Parses JSON, YAML, XML, and .properties text into Python objects."""

    def __init__(self) -> None:     # __init__ runs when you write DataParser().
        # A "dispatch table": format name -> the method that handles it.
        # This replaces a long if/elif chain; adding a format is one new line.
        self._parsers: dict[str, Callable[[str], Any]] = {
            "json": self._parse_json,
            "yaml": self._parse_yaml,
            "xml": self._parse_xml,
            "properties": self._parse_properties,
        }
        # The leading underscore in _parsers means "private: internal use only".

    # ---- Public methods (the ones other code is meant to call) -------------
    def parse_file(self, path: Path, fmt: str | None = None) -> Any:
        """Read a file and parse it. If fmt is None, guess from the extension."""
        fmt = fmt or self.detect_format(path)   # Use given format, else detect it.
        logger.info("Reading file %s as %s", path, fmt)  # %s = lazy formatting.
        try:                                    # File reading can fail, so guard it.
            text = path.read_text(encoding="utf-8")  # Always name the encoding.
        except OSError as exc:                  # Covers "not found", "no permission"...
            # `from exc` keeps the original error attached for debugging.
            raise ParseError(f"Cannot read file '{path}': {exc}") from exc
        return self.parse_text(text, fmt)       # Hand the text to the real parser.

    def parse_text(self, text: str, fmt: str) -> Any:
        """Parse a string that is already in memory."""
        fmt = fmt.lower()                       # Accept "JSON", "Json", "json".
        parser = self._parsers.get(fmt)         # Look up the matching method.
        if parser is None:                      # Unknown format? Fail clearly.
            raise ParseError(
                f"Unsupported format '{fmt}'. Choose from: {', '.join(SUPPORTED_FORMATS)}"
            )
        logger.debug("Parsing %d characters as %s", len(text), fmt)
        return parser(text)                     # Call the method we looked up.

    @staticmethod                               # No `self` needed: it uses no object data.
    def detect_format(path: Path) -> str:
        """Work out the format from the file extension, e.g. '.json' -> 'json'."""
        suffix = path.suffix.lower()            # ".JSON" and ".json" both work.
        try:
            return EXTENSION_TO_FORMAT[suffix]  # Look the extension up in our map.
        except KeyError as exc:                 # Extension not in the map.
            raise ParseError(
                f"Cannot detect format from extension '{suffix}'. Use --format."
            ) from exc

    # ---- Private helpers: one per format -----------------------------------
    @staticmethod
    def _parse_json(text: str) -> Any:
        """JSON -> dict / list / str / number / bool / None."""
        try:
            return json.loads(text)             # "loads" = "load from string".
        except json.JSONDecodeError as exc:     # Raised when the JSON is malformed.
            raise ParseError(f"Invalid JSON: {exc}") from exc

    @staticmethod
    def _parse_yaml(text: str) -> Any:
        """YAML -> Python objects. Needs the PyYAML package."""
        if yaml is None:                        # The optional import failed earlier.
            raise ParseError("YAML support needs PyYAML. Run: pip install pyyaml")
        try:
            # safe_load only builds plain data. Never use yaml.load() on files
            # you do not fully trust: it can be tricked into running code.
            return yaml.safe_load(text)
        except yaml.YAMLError as exc:           # Any YAML syntax problem.
            raise ParseError(f"Invalid YAML: {exc}") from exc

    def _parse_xml(self, text: str) -> dict[str, Any]:
        """XML -> nested dict, e.g. <a><b>1</b></a> -> {'a': {'b': '1'}}."""
        # Security note: for XML from strangers, use the `defusedxml` package,
        # which blocks known XML attacks. Built-in ET is fine for trusted files.
        try:
            root = ET.fromstring(text)          # Parse the text; get the top element.
        except ET.ParseError as exc:            # Raised when the XML is malformed.
            raise ParseError(f"Invalid XML: {exc}") from exc
        return {root.tag: self._element_to_data(root)}  # Wrap under the root's name.

    def _element_to_data(self, element: ET.Element) -> Any:
        """Convert one XML element (and everything inside it) to Python data."""
        children = list(element)                # The elements nested inside this one.
        text = (element.text or "").strip()     # The element's own text, tidied up.
        if not children and not element.attrib: # Simple case: <name>Ada</name>
            return text                         # ...just becomes the string "Ada".

        result: dict[str, Any] = {}             # Otherwise build a dictionary.
        for name, value in element.attrib.items():  # Attributes: <a id="1">
            result[f"@{name}"] = value          # "@" prefix marks an attribute.
        for child in children:                  # Visit each nested element.
            value = self._element_to_data(child)  # Recursion: same job, one level down.
            if child.tag not in result:         # First time we see this tag name:
                result[child.tag] = value       # ...store the value directly.
            elif isinstance(result[child.tag], list):  # Already a list of them:
                result[child.tag].append(value)  # ...add one more.
            else:                               # Second time we see the tag:
                result[child.tag] = [result[child.tag], value]  # ...turn into a list.
        if text:                                # Text mixed in with children/attributes
            result["#text"] = text              # ...is kept under the key "#text".
        return result

    @staticmethod
    def _parse_properties(text: str) -> dict[str, str]:
        """Java-style .properties -> dict. Lines look like key=value or key: value."""
        result: dict[str, str] = {}             # Where we collect key/value pairs.
        pending = ""                            # Holds a line continued with "\".
        # enumerate(..., start=1) gives line numbers for helpful error messages.
        for line_number, raw_line in enumerate(text.splitlines(), start=1):
            line = pending + raw_line.strip()   # Join with any continued part.
            pending = ""                        # Reset now that we have used it.
            if not line or line[0] in "#!":     # Skip blank lines and comments.
                continue                        # (# and ! both start a comment.)
            if line.endswith("\\"):             # A trailing "\" means "continues".
                pending = line[:-1]             # Save all but the "\" for next loop.
                continue
            # Find the first "=" or ":" - whichever comes earliest splits the line.
            positions = [i for i in (line.find("="), line.find(":")) if i != -1]
            if not positions:                   # No separator at all: bad line.
                raise ParseError(f"Properties line {line_number}: missing '=' or ':'")
            cut = min(positions)                # Index of the earliest separator.
            key = line[:cut].strip()            # Text before the separator.
            value = line[cut + 1:].strip()      # Text after the separator.
            if not key:                         # A line like "=value" has no key.
                raise ParseError(f"Properties line {line_number}: empty key")
            result[key] = value                 # Store it (later duplicates win).
        return result


# =============================================================================
# Class: ProcessViewer - runs `ps` and reads its output
# =============================================================================
class ProcessViewer:
    """Runs the `ps` shell command and returns the result as ProcessInfo objects."""

    # The command as a LIST of words. A list (not one long string) means no
    # shell is involved, so nobody can sneak extra commands in ("injection").
    #   -e  = every process       -o = choose exactly which columns to print
    PS_COMMAND: list[str] = ["ps", "-eo", "pid,ppid,user,pcpu,pmem,comm"]

    def __init__(self, timeout: int = PS_TIMEOUT_SECONDS) -> None:
        self.timeout = timeout                  # Remember the time limit.

    def list_processes(self) -> list[ProcessInfo]:
        """Run `ps` and return one ProcessInfo per running process."""
        if shutil.which("ps") is None:          # Is `ps` installed? (Not on Windows.)
            raise CommandError("'ps' command not found (it needs Linux or macOS).")
        logger.info("Running command: %s", " ".join(self.PS_COMMAND))
        try:
            completed = subprocess.run(         # Start `ps` and wait for it to finish.
                self.PS_COMMAND,                # The command and its arguments.
                capture_output=True,            # Collect its output instead of printing.
                text=True,                      # Give us str, not raw bytes.
                check=True,                     # Raise an error if `ps` reports failure.
                timeout=self.timeout,           # Stop waiting after this many seconds.
            )                                   # shell=False is the (safe) default.
        except subprocess.TimeoutExpired as exc:        # It ran too long.
            raise CommandError(f"'ps' took longer than {self.timeout}s") from exc
        except subprocess.CalledProcessError as exc:    # It exited with an error code.
            raise CommandError(
                f"'ps' failed (exit code {exc.returncode}): {exc.stderr.strip()}"
            ) from exc
        except OSError as exc:                          # It could not start at all.
            raise CommandError(f"Could not run 'ps': {exc}") from exc
        processes = self._parse_ps_output(completed.stdout)  # Text -> objects.
        logger.info("Found %d processes", len(processes))
        return processes

    @staticmethod
    def _parse_ps_output(output: str) -> list[ProcessInfo]:
        """Turn the text table printed by `ps` into ProcessInfo objects."""
        processes: list[ProcessInfo] = []       # Start with an empty list.
        for line in output.splitlines()[1:]:    # [1:] skips the header row.
            # Split into at most 6 pieces, so a command name containing
            # spaces stays together in the final piece.
            parts = line.split(None, 5)
            if len(parts) < 6:                  # Not a full row? Skip it safely.
                logger.debug("Skipping unexpected ps line: %r", line)
                continue
            try:
                processes.append(               # Build the object; add it to the list.
                    ProcessInfo(
                        pid=int(parts[0]),      # Text "123" -> number 123.
                        ppid=int(parts[1]),
                        user=parts[2],
                        cpu_percent=float(parts[3]),  # Text "1.5" -> number 1.5.
                        mem_percent=float(parts[4]),
                        command=parts[5].strip(),
                    )
                )
            except ValueError:                  # A column was not a number.
                logger.debug("Skipping unparsable ps line: %r", line)
        return processes


# =============================================================================
# Plain functions
# =============================================================================
def setup_logging(level: str = "INFO", log_file: Path | None = None) -> None:
    """Configure logging once, at program start."""
    # Logs go to stderr so stdout stays clean for real results. That way
    # `python python_template.py --file x.json > out.json` saves only the data.
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    if log_file is not None:                    # Did the user ask for a log file?
        handlers.append(logging.FileHandler(log_file, encoding="utf-8"))
    logging.basicConfig(
        level=getattr(logging, level.upper()),  # "INFO" -> logging.INFO (a number).
        # time | level (padded to 8 chars) | module:line | the message
        format="%(asctime)s | %(levelname)-8s | %(name)s:%(lineno)d | %(message)s",
        handlers=handlers,                      # Where the messages get sent.
        force=True,                             # Replace any earlier logging setup.
    )


def build_arg_parser() -> argparse.ArgumentParser:
    """Describe the command-line options this program accepts."""
    parser = argparse.ArgumentParser(
        description=__doc__,                    # Reuse the docstring at the top.
        formatter_class=argparse.RawDescriptionHelpFormatter,  # Keep its line breaks.
    )
    # --file and --data are two ways to supply input; allow only one at a time.
    source = parser.add_mutually_exclusive_group()
    source.add_argument(
        "-f", "--file",                         # Short and long spelling.
        help="path of the file to parse; use '-' to read standard input",
    )
    source.add_argument(
        "-d", "--data",
        help="data given directly on the command line (needs --format)",
    )
    parser.add_argument(
        "--format",
        choices=SUPPORTED_FORMATS,              # argparse rejects anything else.
        help="input format (default: guessed from the file extension)",
    )
    parser.add_argument(
        "--ps",
        action="store_true",                    # A flag: present = True, absent = False.
        help="show running processes using the 'ps' command",
    )
    parser.add_argument(
        "--top",
        type=int,                               # Convert the typed text to a number.
        default=10,                             # Value used when --top is not given.
        help="with --ps, how many processes to show (default: %(default)s)",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="how much detail to log (default: %(default)s)",
    )
    parser.add_argument(
        "--log-file",
        type=Path,                              # Convert the typed text to a Path.
        help="also write log messages to this file",
    )
    return parser


def load_input(args: argparse.Namespace) -> Any:
    """Get the input from --data, standard input, or a file, and parse it."""
    data_parser = DataParser()                  # Create a parser object.
    if args.data is not None:                   # Case 1: --data '...'
        if not args.format:                     # Loose text has no extension to guess from.
            raise ParseError("--format is required when using --data")
        logger.info("Parsing data from the command line as %s", args.format)
        return data_parser.parse_text(args.data, args.format)
    if args.file == "-":                        # Case 2: --file -   (piped input)
        if not args.format:
            raise ParseError("--format is required when reading standard input")
        logger.info("Reading standard input as %s", args.format)
        return data_parser.parse_text(sys.stdin.read(), args.format)
    return data_parser.parse_file(Path(args.file), args.format)  # Case 3: a real file.


def print_processes(processes: list[ProcessInfo], limit: int) -> None:
    """Print the busiest processes (highest CPU first) as a neat table."""
    # sorted() returns a new list; key= says what to sort by; reverse= biggest first.
    busiest = sorted(processes, key=lambda p: p.cpu_percent, reverse=True)[:limit]
    # In the f-strings below, ">7" right-aligns in 7 columns, "<12" left-aligns in 12.
    print(f"{'PID':>7} {'PPID':>7} {'USER':<12} {'CPU%':>6} {'MEM%':>6} COMMAND")
    for proc in busiest:                        # One printed row per process.
        print(
            f"{proc.pid:>7} {proc.ppid:>7} {proc.user:<12} "
            f"{proc.cpu_percent:>6.1f} {proc.mem_percent:>6.1f} {proc.command}"
        )                                       # ".1f" = show one decimal place.


def main(argv: list[str] | None = None) -> int:
    """Program entry point. Returns an exit code (0 means success)."""
    # Accepting argv as a parameter makes main() easy to call from tests.
    arg_parser = build_arg_parser()
    args = arg_parser.parse_args(argv)          # None means "use the real command line".
    setup_logging(args.log_level, args.log_file)  # Turn logging on first.
    logger.debug("Arguments: %s", vars(args))   # vars() shows the args as a dict.

    if not (args.file or args.data is not None or args.ps):  # Nothing to do?
        arg_parser.print_help(sys.stderr)       # Show the user how to run it.
        return EXIT_USAGE

    try:
        if args.file or args.data is not None:  # The user gave us data to parse.
            data = load_input(args)
            # Print the result as tidy JSON. default=str converts things JSON
            # cannot store (such as dates from YAML) into text instead of crashing.
            print(json.dumps(data, indent=2, default=str))
        if args.ps:                             # The user asked for process info.
            processes = ProcessViewer().list_processes()
            print_processes(processes, args.top)
            # asdict() turns a dataclass into a dict - handy for debug logs or JSON.
            if processes:
                logger.debug("First process as a dict: %s", asdict(processes[0]))
    except TemplateError as exc:                # A problem we expected and understand.
        logger.error("%s", exc)                 # Short, friendly message...
        logger.debug("Details:", exc_info=True)  # ...full traceback only at DEBUG level.
        return EXIT_ERROR
    except KeyboardInterrupt:                   # The user pressed Ctrl+C.
        logger.warning("Interrupted by user")
        return EXIT_INTERRUPTED
    # Anything else is a real bug: we let it crash with a full traceback
    # rather than hide it. Hidden bugs are much harder to fix.

    logger.info("Finished successfully")
    return EXIT_OK


# This block runs only when the file is executed directly (python python_template.py).
# If another file does `import python_template`, nothing runs automatically,
# so the classes and functions above can be reused and tested.
if __name__ == "__main__":
    sys.exit(main())                            # Pass main()'s number to the shell.
