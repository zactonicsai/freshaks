# k8s-fips-upgrade-demo

A practice project for one job: **moving a Kubernetes app from normal (non-FIPS) Linux to FIPS Linux with SHA-2, safely, with a way back.**

- Kubernetes in Docker (kind), 3 nodes: control plane, a **blue** (old) worker, a **green** (new, FIPS) worker
- **FreeIPA** as the domain controller: Kerberos logins and a certificate authority
- **Istio**: strict mutual TLS inside the cluster, a gateway with FreeIPA certificates, a locked way out
- A small **Java 25** app with a public page, a login, a secure page and a mutual-TLS page
- Shell scripts for every step, a log file for every run, saved states with SHA-256 checksums in a zip you can carry away

**Start with [TUTORIAL.md](TUTORIAL.md).** It explains everything in simple words.

## The short version

```bash
scripts/00-check-tools.sh            # what is missing on this computer?
scripts/01-create-cluster.sh         # kind cluster
scripts/02-start-ipa.sh              # FreeIPA + demo user + keytab + certificates
scripts/03-install-istio.sh          # Istio + gateway
scripts/04-build-images.sh nonfips   # app image 1.0
scripts/05-deploy-nonfips.sh         # deploy NON-FIPS (blue) and test
scripts/10-save-state.sh             # snapshot + zip
scripts/20-upgrade-to-fips.sh        # safe upgrade to FIPS / SHA-2 (green), undoes itself if a check fails
scripts/30-rollback.sh               # back to blue in seconds   (--full = everything back)
scripts/50-finalize-fips.sh          # remove the old side for good (only when you are sure)
scripts/90-destroy.sh                # clean up
```

## Two things to know before you run it

1. **Practice mode.** On a computer whose kernel is not in FIPS mode you learn the steps, but the result is not a real FIPS system. The scripts print this clearly. `REQUIRE_KERNEL_FIPS=true` in `config.env` makes them refuse instead.
2. **What was tested.** See [tests/TEST-REPORT.md](tests/TEST-REPORT.md). The app, the Kubernetes logic, save, upgrade, rollback, finalize and restore were run on a real cluster. The Docker, kind, Istio-proxy and FreeIPA-container commands were not; your first run is their first real test.

## Folders

| Folder | What is in it |
|---|---|
| `app/` | Java source, web pages, two Dockerfiles |
| `k8s/` | cluster, Istio and app manifests (templates) |
| `lib/` | shared shell helpers |
| `scripts/` | the numbered scripts |
| `tests/` | tests you can run, the test report, evidence from the author's runs |
| `examples/` | a sample saved-state zip from the test run |
| `logs/`, `state/`, `work/` | made when you run things: logs, snapshots, run-time secrets |

The demo passwords in `config.env` are for a toy only. Change them for anything else.
