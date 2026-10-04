# Python Template Tutorial

This guide explains `python_template.py`, a starter program you can copy whenever you begin a new Python command-line tool. It reads data (JSON, YAML, XML, or `.properties`), runs the shell command `ps` to list running processes, and keeps a log of what it does.

Every line in the program has a comment next to it. This guide adds the bigger picture: how to run it, why it is built this way, and how to change it.

---

## Part 1: Quick start (one example, step by step)

### Step 1. Check Python

Open a terminal and type:

```bash
python3 --version
```

You need Python 3.10 or newer. Any currently supported Python version works.

### Step 2. Make a project folder and a virtual environment

A virtual environment is a private box of Python packages for one project, so projects do not interfere with each other.

```bash
mkdir my_tool
cd my_tool
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
```

### Step 3. Install the one extra package

Python can read JSON, XML, and properties files on its own. YAML needs a helper package:

```bash
pip install pyyaml
```

### Step 4. Copy in the program and make a sample file

Put `python_template.py` in the folder, then create `config.json`:

```json
{"app": "demo", "port": 8080, "tags": ["a", "b"]}
```

### Step 5. Run it

```bash
python python_template.py --file config.json
```

You will see two kinds of output:

```text
2026-10-04 23:39:13,812 | INFO     | __main__:122 | Reading file config.json as json
{
  "app": "demo",
  "port": 8080,
  "tags": ["a", "b"]
}
2026-10-04 23:39:13,813 | INFO     | __main__:426 | Finished successfully
```

The lines with timestamps are **log messages**. The block in the middle is the **result**. They travel on separate channels, which Part 4 explains.

### Step 6. Try the other ways to run it

```bash
# Data typed directly on the command line
python python_template.py --data '{"name": "Ada"}' --format json

# Data piped in from another command ("-" means standard input)
cat config.yaml | python python_template.py --file - --format yaml

# Show the 5 busiest processes
python python_template.py --ps --top 5

# Extra detail, saved to a log file too
python python_template.py --file config.json --log-level DEBUG --log-file run.log

# See all options
python python_template.py --help
```

---

## Part 2: Background

### The four file formats

All four formats store settings as text. Here is the same data in each one.

**JSON**

```json
{"app": "demo", "port": 8080}
```

**YAML**

```yaml
app: demo
port: 8080
```

**XML**

```xml
<config><app>demo</app><port>8080</port></config>
```

**Properties**

```properties
app=demo
port=8080
```

| Format | Pros | Cons |
|---|---|---|
| JSON | Built into Python. Strict, so few surprises. Used by almost every web service. | No comments allowed. Lots of quotes and braces. |
| YAML | Easiest for people to read. Allows comments. | Needs an extra package. Spacing mistakes change the meaning. |
| XML | Handles very complex documents. Common in older and enterprise systems. | Wordy. No built-in idea of numbers or lists; everything is text. |
| Properties | Simplest possible format. Common in Java applications. | Flat only (no nesting). Every value is text. |

Note the last column for XML and properties: the number `8080` comes back as the text `"8080"`. Convert it yourself with `int(value)` when you need a number.

### What is a process, and what is `ps`?

A **process** is a program that is currently running. Each one gets a number called a **PID** (process ID). The `ps` command ("process status") lists them. The template runs:

```bash
ps -eo pid,ppid,user,pcpu,pmem,comm
```

`-e` means every process. `-o` picks the columns: PID, parent PID, owner, CPU percent, memory percent, and command name. This works on Linux and macOS. Windows has no `ps`, so the program checks first and gives a clear error there.

### Classes and functions

A **function** is a named set of steps, like a recipe. A **class** is a blueprint that bundles data together with the functions that work on it. Functions that live inside a class are called **methods**.

---

## Part 3: How the program is organized

The file reads top to bottom in this order:

| Section | What it is | Job |
|---|---|---|
| Shebang and docstring | First lines | Lets the file run directly; describes the program |
| Imports | `import ...` | Brings in the tools the program needs |
| Constants | `UPPER_CASE` names | Fixed values kept in one place |
| Exceptions | `TemplateError`, `ParseError`, `CommandError` | Named kinds of errors |
| `ProcessInfo` | Data class | Holds one row of `ps` output |
| `DataParser` | Class | Turns text into Python data |
| `ProcessViewer` | Class | Runs `ps` and reads the answer |
| `setup_logging` | Function | Turns logging on |
| `build_arg_parser` | Function | Defines the command-line options |
| `load_input` | Function | Picks where the input comes from |
| `print_processes` | Function | Prints the process table |
| `main` | Function | Runs everything; returns an exit code |
| `if __name__ == "__main__":` | Last lines | Starts `main()` when the file is run |

### What happens when you run it

1. Python reaches the last two lines and calls `main()`.
2. `main()` reads your command-line options and turns logging on.
3. If you gave `--file` or `--data`, `load_input()` creates a `DataParser`, which picks the right method for the format and returns Python data. The result is printed as JSON.
4. If you gave `--ps`, a `ProcessViewer` runs the command, converts each line to a `ProcessInfo`, and the table is printed.
5. `main()` returns `0` for success or another number for failure, and `sys.exit()` hands that number to the shell.

---

## Part 4: The key ideas, explained

### The dispatch table

Inside `DataParser.__init__`:

```python
self._parsers = {
    "json": self._parse_json,
    "yaml": self._parse_yaml,
    "xml": self._parse_xml,
    "properties": self._parse_properties,
}
```

This dictionary maps a format name to the method that handles it. To parse, the program looks up the name and calls whatever it finds. The alternative is a long `if / elif / elif` chain. The dictionary is shorter, and adding a format means adding one line.

### Custom exceptions

When something goes wrong, the program raises a `ParseError` or `CommandError`. Both are children of `TemplateError`, so `main()` can catch every expected problem with a single `except TemplateError`. Unexpected problems (real bugs) are deliberately **not** caught, so you get the full error report and can fix them.

`raise ParseError(...) from exc` keeps the original error attached, so no detail is lost.

### Running a shell command safely

```python
subprocess.run(
    ["ps", "-eo", "pid,ppid,user,pcpu,pmem,comm"],
    capture_output=True, text=True, check=True, timeout=10,
)
```

| Piece | Meaning |
|---|---|
| A list of words | Runs the program directly, with no shell in between |
| `capture_output=True` | Collect what the command prints |
| `text=True` | Give back normal text instead of raw bytes |
| `check=True` | Raise an error if the command fails |
| `timeout=10` | Give up after 10 seconds |

| Option | Pros | Cons |
|---|---|---|
| List of words (used here) | Safe from command injection. Predictable. | No shell features such as pipes or `*` wildcards. |
| `shell=True` with one string | Pipes and wildcards work. | Dangerous if any part of the string comes from a user, who could add their own commands. |

### Logging instead of print

| Option | Pros | Cons |
|---|---|---|
| `logging` (used here) | Timestamps and levels. Can go to a file. Turn detail up or down with one option. | A few lines of setup. |
| `print()` | Zero setup. | No levels, no timestamps, and it mixes with your real output. |

There are five levels, from most to least chatty: `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`. Setting `--log-level WARNING` hides the first two.

Logs go to **stderr** and results go to **stdout**. These are two separate output channels, so this saves only the clean data:

```bash
python python_template.py --file config.json > result.json
```

Log calls are written as `logger.info("Reading %s", path)` and not as an f-string. That way Python only builds the message if that level is switched on.

### Command-line arguments

| Option | Pros | Cons |
|---|---|---|
| `argparse` (used here) | Built in. Writes `--help` for you. Checks types and choices. | Slightly wordy. |
| Reading `sys.argv` by hand | Nothing to learn. | You write all the checking and help text yourself. |
| Third-party tools (`click`, `typer`) | Very pleasant to write. | One more package to install. |

### The `main()` pattern

```python
def main(argv=None) -> int:
    ...
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

The `if` line is true only when you run the file directly. If another file imports it, nothing runs on its own, so the classes can be reused and tested. Returning a number lets other programs and scripts tell whether yours worked: `0` is success, `1` is an error, `2` is wrong usage, `130` is Ctrl+C.

---

## Part 5: Best practices used in the template

| Practice | Where you see it | Why it matters |
|---|---|---|
| Docstrings | Top of the file, every class and function | Explains the purpose; powers `--help` |
| Type hints | `def parse_text(self, text: str, fmt: str) -> Any` | Editors and checkers catch mistakes early |
| Named constants | `PS_TIMEOUT_SECONDS`, `EXIT_OK` | No mystery numbers scattered in the code |
| `pathlib.Path` | `path.read_text(...)`, `path.suffix` | Works the same on every operating system |
| Explicit encoding | `encoding="utf-8"` | Same result on every computer |
| Specific exceptions | `except json.JSONDecodeError` | Never a bare `except:` that hides bugs |
| `yaml.safe_load` | `_parse_yaml` | Plain `yaml.load` can run code hidden in a file |
| No `shell=True` | `ProcessViewer` | Prevents command injection |
| Timeout on commands | `timeout=self.timeout` | The program can never hang forever |
| Optional dependency | `try: import yaml` | JSON, XML, and properties still work without PyYAML |
| Data class | `ProcessInfo` | Clear field names instead of loose lists |
| Small pieces | One job per function | Easy to read, test, and replace |
| Exit codes | `return EXIT_ERROR` | Scripts can react to failure |

**One security note on XML.** Python's built-in XML reader is fine for files you trust. For XML from the internet or from strangers, install `defusedxml` and use it instead, because specially crafted XML can attack a parser.

---

## Part 6: Making it your own

**Add a new file format (example: TOML).** Python has a built-in TOML reader called `tomllib`.

1. Add `import tomllib` with the other imports.
2. Add `".toml": "toml"` to `EXTENSION_TO_FORMAT`.
3. Add `"toml": self._parse_toml` to the dispatch table.
4. Write the method:

```python
@staticmethod
def _parse_toml(text: str) -> Any:
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise ParseError(f"Invalid TOML: {exc}") from exc
```

**Run a different command.** Copy `ProcessViewer`, change `PS_COMMAND` to your command as a list of words, and rewrite `_parse_ps_output` to match what that command prints.

**Add a new option.** Add one `parser.add_argument(...)` call in `build_arg_parser()`, then read it in `main()` as `args.your_option`.

**Test it.** Because `main()` accepts a list, a test can call it directly:

```python
from python_template import DataParser, main

def test_json():
    assert DataParser().parse_text('{"a": 1}', "json") == {"a": 1}

def test_missing_file_returns_error():
    assert main(["--file", "does_not_exist.json"]) == 1
```

Run tests with `pip install pytest` and then `pytest`.

---

## Part 7: Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| `YAML support needs PyYAML` | The package is not installed | `pip install pyyaml` |
| `Cannot detect format from extension` | Unknown file ending | Add `--format json` (or yaml, xml, properties) |
| `--format is required when using --data` | Typed data has no extension to guess from | Add `--format` |
| `'ps' command not found` | You are on Windows | Use Linux, macOS, or WSL |
| `Invalid JSON: ...` | A typo in the data | The message gives the line and column |
| `Cannot read file` | Wrong path or no permission | Check the spelling and location |

---

## Glossary

| Word | Meaning |
|---|---|
| Argument | Extra words typed after the program name, such as `--file config.json` |
| Class | A blueprint that bundles data with the functions that use it |
| Method | A function that belongs to a class |
| Exception | Python's way of signalling that something went wrong |
| Parse | To read text and turn it into structured data |
| Process | A program that is currently running |
| stdin, stdout, stderr | The standard channels for input, results, and messages |
| Exit code | A number a program hands back when it ends; `0` means success |
| Virtual environment | A private set of Python packages for one project |
