# Test report

**When:** 5 and 6 October 2026
**Where:** the author's sandbox — a small Ubuntu 24.04 virtual machine with root access, **no Docker**, and no access to container registries (Docker Hub, Quay, Red Hat).

Because of that, the tests fall into three groups: **run for real**, **run with stand-ins**, and **not run**. This file says plainly which is which. Trimmed logs of the runs are in `tests/evidence/`.

---

## 1. Run for real, no stand-ins

| # | What | How | Result |
|---|---|---|---|
| 1 | Shell syntax of all 24 shell files | `bash -n` | pass |
| 2 | Shell lint | `shellcheck` 0.9 | **0 errors.** 9 warning-level notes, all of the kind "variable looks unused" for variables that are used by another sourced file |
| 3 | Java app compiles | JDK 25.0.4, `javac -Xlint:all -Werror` | pass, no warnings |
| 4 | **Java app against a real Kerberos server** | `tests/app-kerberos-test.sh` with MIT Kerberos 1.20 (FreeIPA's KDC is MIT Kerberos) | **40 of 40 checks pass** |
| 5 | All templates render, no placeholder left | `tests/offline-tests.sh` | pass |
| 6 | Manifests are valid for Istio | real `istioctl` 1.31.1: `validate` and `analyze --use-kube=false` | pass, "No validation issues found" |
| 7 | The FIPS switch reaches istiod | `istioctl manifest generate` with and without `values.pilot.env.COMPLIANCE_POLICY=fips-140-3` | istiod gets `COMPLIANCE_POLICY=fips-140-3` and `GODEBUG=fips140=only`; the sidecar and gateway injection templates in the 1.31.1 charts copy the policy into proxies |
| 8 | The FIPS command of `Dockerfile.fips` | `update-crypto-policies --no-reload --set FIPS` on a real AlmaLinux 9.8 file system (same family as UBI 9) | exit code 0, policy becomes `FIPS`; prints the expected "not sufficient for FIPS compliance" warning |
| 9 | Kerberos key types under FIPS | read `/usr/share/crypto-policies/FIPS/krb5.txt` on that file system | only `aes256-cts-hmac-sha384-192` and `aes128-cts-hmac-sha256-128` — the same list the project uses |

What test 4 proves, in detail:

- public page, login redirect, wrong password refused, right password accepted, secure page, logout, unknown page;
- non-FIPS profile → ticket key type `aes256-cts-hmac-sha1-96`, cookie signed with HmacSHA1;
- FIPS profile → ticket key type `aes256-cts-hmac-sha384-192`, cookie signed with HmacSHA256;
- Kerberos really went over **TCP** (the test KDC only listened on TCP);
- the app's "is this the real KDC?" check works with the keytab, and with the SHA-2-only filtered keytab;
- a cookie from the old pod is refused by the FIPS pod; a changed cookie is refused;
- a user with only SHA-1 keys can log in to the old pod but **not** to the FIPS pod;
- after a key rotation the **old keytab stops working** (the rollback trap);
- the certificate page reads the gateway's client-certificate header correctly and is not fooled by a mesh-only header.

---

## 2. Run on a real Kubernetes cluster, with stand-ins for four things

The **real project scripts** were run on a real **Kubernetes 1.36.4** node (k3s). The app ran in **real pods** and logged users in against a **real Kerberos server** from inside the pods.

### What was a stand-in (be aware of this)

| Real thing | Stand-in on the test box |
|---|---|
| Docker + kind, 3 nodes | one k3s node carrying both the blue and the green label |
| FreeIPA container | a local MIT Kerberos KDC and a local OpenSSL test CA |
| Istio control plane and proxies | **none.** Istio's CRDs were installed, so all Istio objects were stored and schema-checked, but no proxy ran. The "mesh policy" was only recorded |
| Images built by the Dockerfiles (UBI 9 + Red Hat OpenJDK 25) | hand-built images: AlmaLinux 9.8 file system + Eclipse Temurin JRE 25.0.4 + the same compiled app. Blue has the `DEFAULT` crypto policy, green the `FIPS` policy |

Because no gateway ran, the tests used `TEST_MODE=direct` (straight to the pod). The stand-ins live in `tests/sandbox/hooks.sh`; they replace only functions from `lib/platform.sh`.

### Results

| Stage | Script | Result |
|---|---|---|
| Start identity stand-in, record mesh | `02-start-ipa.sh`, `03-install-istio.sh` | pass |
| Deploy non-FIPS and test | `05-deploy-nonfips.sh` (+ `06-test.sh`) | pass, 12 checks |
| Save state | `10-save-state.sh --with-images --with-ipa-data` | pass, zip + checksums written |
| Upgrade, **forced to fail** in the mesh phase | `20-upgrade-to-fips.sh` | exit 1 as wanted; **rolled itself back in 22 s**; blue passed its tests; green and the v2 secrets were gone |
| Upgrade, **forced to fail** because green pods could not start | `20-upgrade-to-fips.sh` | exit 1 as wanted; **rolled itself back in 27 s**; mesh policy back to none |
| Real upgrade | `20-upgrade-to-fips.sh` | pass in 44 s; all gates passed |
| Fast rollback | `30-rollback.sh --fast` | pass in 17 s (includes a snapshot and the tests) |
| Roll forward again | `31-switch-live.sh green` | pass |
| Full rollback from the snapshot | `30-rollback.sh --full` | pass in 35 s; green removed; 114 files matched their checksums |
| Second upgrade | `20-upgrade-to-fips.sh` | pass in 63 s |
| Finalize | `50-finalize-fips.sh --keep-blue-nodes` | pass; new SHA-2-only keys; green: 13 pass, 0 fail, 1 warning (the practice-mode warning) |
| Changed snapshot | `40-restore-state.sh` on a copy with one changed byte | **refused**, as wanted |
| Wipe and restore | both namespaces deleted, then `40-restore-state.sh` run **from the project copy inside the zip** | pass in 15 s; green: 13 pass, 0 fail, 1 warning |
| Encrypted zip | `10-save-state.sh --encrypt`, restore from the `.zip.enc` | pass; a wrong passphrase is refused |
| Collect logs | `60-collect-logs.sh` | pass |
| Expose on localhost | `07-expose-localhost.sh app` | pass: health, public page and status answered on `http://localhost:<port>`. The `gateway` mode was **not** run (no gateway on the test box) |

The times are from a one-node box with one small pod per side. They show that the steps are quick; they are not a benchmark.

The run was done in pieces, because the sandbox stops background programs. One finalize run was cut off by that in the middle of a snapshot and was simply run again; the second run passed. An earlier attempt stopped in the upgrade's own pre-flight check with a failed login; the stand-in Kerberos server had been stopped by the sandbox, and with it running again the same step passed.

### Bugs these runs found (all fixed)

1. `kubectl` refuses a node name together with a label selector, so the "pods run on the right nodes" check always failed.
2. The test left a `kubectl port-forward` running, so a later test of green silently talked to a blue pod.
3. A failed phase printed the whole upgrade block as one error line.
4. A wrong passphrase left a broken zip file behind.

---

## 3. NOT run by the author

Nothing in this list has been executed. It was written from the projects' documentation and source code.

| Not run | Why it matters | Where it lives |
|---|---|---|
| `kind create cluster` with the 3-node config | first step of the demo | `01-create-cluster.sh`, `k8s/kind-cluster.yaml` |
| The FreeIPA container start, including the cgroup flags | the most fragile step; depends on your Docker | `ipa_start` in `lib/platform.sh` |
| The `ipa` commands: user, group, host and service creation, `ipa-getkeytab`, `ipa cert-request`, the `kadmin.local` key check | exact options and behaviour of a real FreeIPA 4.12 | `lib/platform.sh` |
| `docker build` of both Dockerfiles on the UBI 9 OpenJDK 25 images | image names were confirmed to exist; the build itself was not run | `app/Dockerfile.*` |
| `istioctl install` on a cluster, with and without `fips-140-3`; proxies restarting with the policy | `fips-140-3` is new in Istio 1.31 | `mesh_install`, `gateway_install` |
| Everything that needs a running proxy: gateway TLS with the FreeIPA certificate, the mutual-TLS page with a real client certificate, strict mesh mTLS, the `REGISTRY_ONLY` way-out lock, the preview header | the test script has checks for all of these (sections 4–6 of `06-test.sh`); they have never run | `06-test.sh`, `k8s/app/*.yaml` |
| Node drain in the finalize step | needs more than one node | `50-finalize-fips.sh` |
| `40-restore-state.sh --new-cluster`, and the real `--with-images` / `--with-ipa-data` code | need Docker | `40-restore-state.sh`, `lib/platform.sh` |
| A node with a kernel in FIPS mode | on such a node Red Hat's Java switches itself to FIPS providers; the app was never run that way | — |
| macOS, WSL2, ARM computers | only Linux x86_64 was used | — |

### What to watch on your first real run

- If `02-start-ipa.sh` fails, see "When FreeIPA will not start" in the tutorial.
- If Istio does not become healthy with `fips-140-3`, the upgrade rolls itself back. Try `ISTIO_COMPLIANCE_POLICY=fips-140-2`.
- The certificate page assumes the gateway's `X-Forwarded-Client-Cert` header contains a `Subject="..."` entry for the visitor's certificate.
- Read the log of the first failing script. Every script names its log file.

---

## 4. Run the tests yourself

```bash
tests/offline-tests.sh              # groups 1-7 above, no Docker needed (skips what is not installed)
sudo tests/app-kerberos-test.sh     # test 4: needs a JDK and the MIT Kerberos server packages
scripts/06-test.sh                  # on your running demo: the full test, through the gateway
```
