# Architecture and coding choices

## Flow

```text
CLI arguments
    |
    v
cli.py
    |
    +--> KubectlClient ----+
    |                      |
    +--> HelmClient -------+--> CommandRunner --> local kubectl / helm
    |                      |
    +--> DiagnosticsService+
    |
    v
Report dataclasses --> formatter --> human / JSON / YAML / HTML
```

## Why call kubectl and Helm instead of using a Kubernetes Python SDK?

This utility is intentionally a wrapper around tools the operator already uses.
That means it automatically follows the user's kubeconfig, credential plugins,
cloud login helpers, contexts, and Helm configuration.

It also makes every important operation easy to reproduce manually. The report
can display the same command an engineer would type at a terminal.

## Main classes

### `CommandRunner`

Single responsibility: execute an external program safely.

Key choices:

- argument list rather than shell string;
- no `shell=True`;
- timeout;
- captured stdout/stderr;
- return code preserved rather than always throwing an exception.

### `KubectlClient`

Single responsibility: construct `kubectl` operations while consistently
applying context and namespace.

### `HelmClient`

Same pattern for Helm. Read operations run directly. Write operations use dry
run or plan mode unless `execute=True`.

### `DiagnosticsService`

Contains the troubleshooting knowledge. It receives clients rather than creating
them internally, which makes the logic easier to unit-test.

### `Report` and `Finding`

Diagnostics produce structured data first. Formatting happens later. Because of
that separation, adding CSV, Markdown, SQLite, or an HTTP API later does not
require rewriting diagnostic logic.

## Adding a new check

Example idea: check PodDisruptionBudgets.

1. Add a private method such as `_check_pdbs()` to `DiagnosticsService`.
2. Fetch structured JSON with `kubectl.get_json("poddisruptionbudgets")`.
3. Convert raw Kubernetes fields into a small human-focused summary.
4. Add one or more `Finding` objects to the `Report`.
5. Call the new method from `full_report()`.
6. Add a test with a fake client result.

## Adding a new command

1. Add an argparse subcommand in `build_parser()`.
2. Add a client method in `KubectlClient` or `HelmClient`.
3. Dispatch it in `run_command()`.
4. For mutating commands, default to dry-run/plan mode and require `--execute`.
5. For destructive commands, also require `--yes`.

## Operational guardrails

The utility does not try to bypass Kubernetes RBAC. If the current user cannot
read Secrets, list nodes, patch Deployments, or uninstall a release, Kubernetes
or Helm should reject the action.

That is intentional: authorization belongs to the cluster, not this wrapper.
