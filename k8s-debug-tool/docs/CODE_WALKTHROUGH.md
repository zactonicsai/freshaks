# Code walkthrough — what each part is doing

The source files already contain docstrings and comments. This guide explains
the code in reading order so a newer Python programmer can understand why the
lines exist.

## `models.py`

```python
from dataclasses import dataclass, field
```

`dataclass` saves us from manually writing constructors such as `__init__` for
plain data objects. `field(default_factory=list)` creates a fresh list for each
report instead of accidentally sharing one list between reports.

```python
@dataclass(slots=True)
class CommandResult:
```

`slots=True` prevents arbitrary new attributes from being added by accident and
reduces a little memory overhead.

`CommandResult` stores the exact command, exit code, output, error output, and
runtime. Its `ok` property turns `returncode == 0` into an easy-to-read Boolean.

`Finding` is one check such as "nodes" or "service endpoints". `Report` is the
container holding many findings.

## `runner.py`

```python
shutil.which(binary)
```

This checks whether `kubectl` or `helm` can actually be found in `PATH` before
trying to run it.

```python
subprocess.run([...], shell=False)
```

The code passes a **list of arguments**, not a single shell string. Python does
not need a shell to interpret the command. This avoids shell quoting surprises
and reduces command-injection risk.

```python
check=False
```

A failed kubectl command is often useful diagnostic information, so the runner
returns its exit code/stderr rather than immediately raising an exception.

```python
timeout=...
```

This stops a stuck command from hanging the Python tool forever.

## `clients.py`

`KubectlClient._base()` starts each command with `kubectl` and adds the selected
context and namespace in one place. This avoids repeating the same logic in
every method.

Example:

```python
client.logs("web-123", container="web", tail=100)
```

becomes roughly:

```text
kubectl --context MY_CONTEXT --namespace MY_NS logs web-123 -c web --tail=100
```

The methods named `get_json()` and `get_yaml()` ask kubectl for structured data
and parse it. Diagnostic code can then inspect fields reliably instead of trying
to scrape columns intended for humans.

Write methods accept `execute: bool`. If it is false, they either use Kubernetes
server-side dry-run or return a plan-only result. This makes accidental changes
less likely.

`HelmClient` follows the same pattern. For real upgrades it first asks Helm for
its version so it can choose the failure/rollback flag appropriate to Helm 3 or
Helm 4.

## `diagnostics.py`

This file is the troubleshooting brain.

```python
_items(obj)
```

Kubernetes list responses normally have an `items` array. The helper safely
returns that list or an empty list.

```python
full_report()
```

Runs the major checks in a consistent order: connectivity, nodes, workloads,
pods, Services, storage, networking, events, metrics, and Helm releases.

### Pod inspection

`pod_report()` reads the Pod as JSON, then checks:

- phase;
- container readiness;
- restart counts;
- waiting/terminated reasons;
- selected node and scheduling settings;
- `kubectl describe`;
- events for that Pod;
- current and previous logs;
- referenced ConfigMaps and Secrets.

Secret values are not decoded unless the caller explicitly opts in.

### Configuration review

`_find_pod_spec()` lets the same review logic work for a Pod directly or for a
Deployment/StatefulSet/DaemonSet/Job that stores a Pod template under
`spec.template.spec`.

`_review_pod_spec()` looks for common maintainability, reliability, and security
signals. A warning is not always "wrong"; for example, a platform DaemonSet may
legitimately need host networking.

### Local manifest review

`file_review()` uses `yaml.safe_load_all()` because one YAML file can contain
multiple Kubernetes documents separated by `---`. It does not contact or modify
the cluster.

## `formatters.py`

The diagnostic layer returns Python objects rather than printing directly.
`formatters.py` converts those objects into four views.

### Human

The Rich library draws a readable terminal table.

### JSON

```python
json.dumps(data, indent=2)
```

Useful for scripts, CI pipelines, and other programs.

### YAML

```python
yaml.safe_dump(data, sort_keys=False)
```

Useful for people already working with Kubernetes YAML.

### HTML

The formatter creates a complete standalone HTML page. `html.escape()` is used
when inserting cluster output so strings such as `<script>` are displayed as
text instead of becoming browser markup.

## `cli.py`

`argparse.ArgumentParser` defines the CLI grammar and automatically builds
`--help` output.

```python
sub = parser.add_subparsers(dest="command", required=True)
```

This creates commands such as `doctor`, `pod`, `logs`, and `helm`.

The `helm` command itself has another subparser, which creates commands such as:

```text
k8s-doctor helm list
k8s-doctor helm status RELEASE
k8s-doctor helm upgrade RELEASE CHART
```

`run_command()` is the dispatcher. It translates parsed arguments into calls on
`DiagnosticsService`, `KubectlClient`, or `HelmClient`.

`emit()` handles the final presentation and file output.

`main()` turns expected problems into useful exit codes instead of Python stack
traces.

## Why classes plus small functions?

The classes group responsibilities:

- `CommandRunner`: process execution;
- `KubectlClient`: kubectl syntax;
- `HelmClient`: Helm syntax;
- `DiagnosticsService`: troubleshooting rules.

The small helper functions keep repeated parsing/formatting code in one place.
This separation makes the project easier to test and extend.
