# Release 1.1.0

> Image `registry.local/web:1.1.0` · generated 2026-10-04 21:56 UTC

## Summary

Compared with **1.0.0**: 1 packages added, 1 removed, 3 version changes, 4 configuration changes. 4 packages total.

## Image

| Field | Value |
|---|---|
| Reference | `registry.local/web:1.1.0` |
| Tags | `registry.local/web:1.1.0` |
| Digest | `sha256:9f8e7d6c5b4a2` |
| Image ID | `abcdef123456` |
| OS / Arch | linux / amd64 |
| Created | 2026-10-02T10:00:00Z |
| Size | 81 MB |
| Layers | 3 |
| SBOM format | CycloneDX 1.5 |

## Changes

### Package updates (3)

| Package | From | To | Type | Direction |
|---|---|---|---|---|
| busybox | `1.36.1-r2` | `1.36.1-r1` | apk | ⬇ downgrade |
| openssl | `3.0.13-r0` | `3.0.15-r1` | apk | ⬆ upgrade |
| requests | `2.31.0` | `2.32.3` | pypi | ⬆ upgrade |

### Packages added (1)

| Package | Version | Type | License |
|---|---|---|---|
| urllib3 | `2.2.2` | pypi | MIT |

### Packages removed (1)

| Package | Version | Type |
|---|---|---|
| curl | `8.5.0-r0` | apk |

### Configuration changes (4)

| Setting | Before | After |
|---|---|---|
| `config.ports` | 8080/tcp | 8080/tcp, 9090/tcp |
| `config.user` | _(none)_ | 1001 |
| `env.LOG_LEVEL` | _(none)_ | info |
| `label.org.opencontainers.image.version` | 1.0.0 | 1.1.0 |

## Runtime configuration

| Setting | Value |
|---|---|
| User | `1001` |
| Working dir | `/app` |
| Entrypoint | `/app/start` |
| Cmd | `--port 8080` |
| Exposed ports | `8080/tcp, 9090/tcp` |
| Volumes | _(not set)_ |
| Stop signal | _(not set)_ |

### Environment

| Variable | Value |
|---|---|
| `APP_ENV` | `prod` |
| `DB_PASSWORD` | `****` |
| `LOG_LEVEL` | `info` |
| `PATH` | `/usr/bin` |

### Labels

| Label | Value |
|---|---|
| `maintainer` | ops\|team |
| `org.opencontainers.image.version` | 1.1.0 |

## Software inventory

| Type | Packages |
|---|---|
| pypi | 2 |
| apk | 2 |

### Licenses

| License | Packages |
|---|---|
| Apache-2.0 | 2 |
| MIT | 1 |
| GPL-2.0-only | 1 |

<details>
<summary>All 4 packages</summary>

| Package | Version | Type | License |
|---|---|---|---|
| busybox | `1.36.1-r1` | apk | GPL-2.0-only |
| openssl | `3.0.15-r1` | apk | Apache-2.0 |
| requests | `2.32.3` | pypi | Apache-2.0 |
| urllib3 | `2.2.2` | pypi | MIT |

</details>

## Reproduce

```bash
podman pull registry.local/web:1.1.0
podman image inspect registry.local/web:1.1.0
syft podman:registry.local/web:1.1.0 -o spdx-json
```
