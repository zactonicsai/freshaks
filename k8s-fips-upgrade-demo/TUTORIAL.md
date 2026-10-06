# From Normal Linux to FIPS Linux on Kubernetes

**A safe upgrade you can practise on your own computer — with Docker, FreeIPA Kerberos, Istio and a small Java app**

*Written October 2026. Versions used: Kubernetes 1.36 (kind v0.33.0), Istio 1.31.1, FreeIPA 4.12 container, Java 25, Red Hat UBI 9.*

---

## Read this first (two honest notes)

**1. Practice mode and real FIPS are different things.**
Your laptop's Linux kernel is almost surely *not* in FIPS mode. The project still runs. You practise every step of the upgrade, and all the SHA-2 settings are real. But the result is *not* a real FIPS system until the machines that run your pods are started in FIPS mode. The scripts say so in big letters, and one setting (`REQUIRE_KERNEL_FIPS=true`) makes them refuse to continue on a non-FIPS machine.

**2. Not every part could be tested by the author.**
The file `tests/TEST-REPORT.md` lists exactly what was run and what was not. Short version: the Java app, the Kubernetes parts, save, upgrade, rollback and restore were run on a real Kubernetes cluster. The commands that need Docker, kind, a running Istio and the real FreeIPA container could not be run where this was written. They were written from those projects' own documentation. Treat your first run as the first real test and read the log if something stops.

---

## Table of contents

1. [Part 1 — Do it: one example, step by step](#part-1--do-it-one-example-step-by-step)
2. [Part 2 — Background: what all the words mean](#part-2--background-what-all-the-words-mean)
3. [Part 3 — The safe upgrade strategy](#part-3--the-safe-upgrade-strategy)
4. [Part 4 — A tour of the project](#part-4--a-tour-of-the-project)
5. [Part 5 — Your options, with pros and cons](#part-5--your-options-with-pros-and-cons)
6. [Part 6 — Best practices checklist](#part-6--best-practices-checklist)
7. [Part 7 — From practice to a real FIPS system](#part-7--from-practice-to-a-real-fips-system)
8. [Part 8 — When something goes wrong](#part-8--when-something-goes-wrong)
9. [Part 9 — How this was tested](#part-9--how-this-was-tested)
10. [Part 10 — Word list](#part-10--word-list)
11. [Part 11 — Where the facts come from](#part-11--where-the-facts-come-from)

---

# Part 1 — Do it: one example, step by step

## What you will build

```
 your computer
 +--------------------------------------------------------------------------+
 |  Docker                                                                  |
 |  +------------------------ kind cluster "fipsdemo" --------------------+ |
 |  |                                                                     | |
 |  |  control plane      worker "blue" pool        worker "green" pool   | |
 |  |                     +----------------+        +----------------+    | |
 |  |  Istio gateway  --> | app v1         |   or   | app v2         |    | |
 |  |  (the front door)   | NON-FIPS       |  -->   | FIPS, SHA-2    |    | |
 |  |  https :8443        | + Istio proxy  |        | + Istio proxy  |    | |
 |  |                     +-------+--------+        +--------+-------+    | |
 |  +-----------------------------|--------------------------|------------+ |
 |                                +------ TCP port 88 -------+              |
 |                                            |                             |
 |                              +-------------v-------------+               |
 |                              | FreeIPA container         |               |
 |                              | Kerberos logins + CA      |               |
 |                              +---------------------------+               |
 +--------------------------------------------------------------------------+
```

In plain words:

- A tiny **Kubernetes cluster** runs inside Docker on your computer.
- A small **Java web app** runs in pods. It has a **public page**, a **login page**, a **secure page** and a **certificate page**.
- **FreeIPA** is the "school office" that knows every user. The app asks FreeIPA (using **Kerberos**) whether a password is right.
- **Istio** puts a small helper (a **proxy**) next to every pod. The proxies talk to each other with **mutual TLS**, and they only let the app talk *out* to FreeIPA and nothing else.
- First you run the **non-FIPS** version (we call it **blue**). Then you **save the state**, **upgrade** to the **FIPS, SHA-2** version (**green**), and practise **rolling back**.

## What you need

| You need | Why | How to get it |
|---|---|---|
| A computer with **16 GB RAM** (Docker should have 10 GB or more) | FreeIPA alone wants several GB | — |
| **Linux x86_64** is the best fit (WSL2 or macOS may work) | FreeIPA in a container is picky | — |
| **Docker** | runs everything | docs.docker.com/get-docker |
| **kind** v0.33.0 or newer | makes the cluster | kind.sigs.k8s.io |
| **kubectl** | talks to the cluster | kubernetes.io/docs/tasks/tools |
| **istioctl** 1.31.1 | installs Istio | `curl -L https://istio.io/downloadIstio \| ISTIO_VERSION=1.31.1 sh -` |
| **openssl, curl, jq, zip, unzip**, **bash 4+** | small helpers | your package manager |

Every command below is run from the project folder:

```bash
unzip k8s-fips-upgrade-demo.zip
cd k8s-fips-upgrade-demo
```

> **Tip:** every script prints what it does, and writes the same text to a file in `logs/`. If a script stops, the last lines tell you which log to read.

## Step 0 — Check your tools (1 minute)

```bash
scripts/00-check-tools.sh
```

It changes nothing. It tells you which programs are missing, how much memory Docker has, and whether your own kernel is in FIPS mode (it will most likely say *OFF — practice mode*).

## Step 1 — Create the cluster (2–3 minutes)

```bash
scripts/01-create-cluster.sh
```

**What just happened:** kind started three Docker containers that act as three computers ("nodes"): one boss (control plane) and two workers. One worker has the label `nodepool=blue`, the other `nodepool=green`. The script also looked into each node and wrote down whether its kernel is in FIPS mode.

## Step 2 — Start FreeIPA (5–15 minutes the first time)

```bash
scripts/02-start-ipa.sh
```

**What just happened:**

1. A FreeIPA server started in its own container, on the same Docker network as the cluster. Its name is `ipa.fipsdemo.test` and its Kerberos realm is `FIPSDEMO.TEST`.
2. The script created the user **alice**, a group, and a **service** called `HTTP/app.fipsdemo.test` (that is the app's own Kerberos name).
3. It fetched a **keytab** (the app's own secret keys) into `work/ipa/app.keytab`.
4. It asked FreeIPA's **certificate authority (CA)** for two certificates: one for the web site and one for a test client.

Everything secret lands in the folder `work/`. Never share that folder.

> This is the step most likely to need help. If it fails, jump to [When FreeIPA will not start](#when-freeipa-will-not-start).

## Step 3 — Install Istio (2–3 minutes)

```bash
scripts/03-install-istio.sh
```

**What just happened:** Istio's "brain" (called `istiod`) and a **gateway** (the front door) were installed. At this point Istio uses its normal settings, not the FIPS ones.

## Step 4 — Build the non-FIPS app image (3–5 minutes)

```bash
scripts/04-build-images.sh nonfips
```

**What just happened:** Docker compiled the Java app and packed it into an image called `fipsdemo-app:1.0-nonfips`. Then kind copied the image into every node.

## Step 5 — Deploy the non-FIPS app and test it

```bash
scripts/05-deploy-nonfips.sh
```

The script deploys the **blue** pods, opens the front door, and runs the test script. The first test lines look like this:

```
[PASS ] public page opens without login
[PASS ] secure page without login -> sent to the login page (HTTP 303)
[PASS ] wrong password is refused (HTTP 401)
[PASS ] FreeIPA Kerberos login of 'alice' works
[PASS ] secure page greets alice@FIPSDEMO.TEST
[PASS ] Kerberos ticket key type is aes256-cts-hmac-sha1-96
[PASS ] app crypto profile is 'legacy'
[PASS ] login cookies are signed with HmacSHA1
```

Notice **`sha1`** in two places. That is the "before" picture.

**Look at it in a browser:**

1. Add this line to your hosts file (`/etc/hosts` on Linux and macOS):
   `127.0.0.1 app.fipsdemo.test`
2. Open `https://app.fipsdemo.test:8443`
   Your browser will warn about the certificate unless you tell it to trust `work/ipa/ca.crt`.
3. Log in as **alice** with the password from `config.env` (`DEMO_USER_PASSWORD`).

Or use the command line:

```bash
curl --cacert work/ipa/ca.crt --resolve app.fipsdemo.test:8443:127.0.0.1 https://app.fipsdemo.test:8443/status
```

### Three ways to reach the app from your own computer (localhost)

| Way | Command | Address | Goes through |
|---|---|---|---|
| **Built in** | nothing to do, the cluster was made with it | `https://app.fipsdemo.test:8443` | gateway + mesh (the real path) |
| **Simple localhost** | `scripts/07-expose-localhost.sh` | `http://localhost:8080` | straight into one app pod |
| **Gateway on another port** | `scripts/07-expose-localhost.sh gateway 9443` | `https://app.fipsdemo.test:9443` | gateway + mesh |

The **simple localhost** way needs no hosts file and no certificate, so it is the quickest look at the pages. But it skips the gateway and the mesh: no TLS, and the certificate page (`/mtls`) will always say no. It runs until you press Ctrl+C. Pick a side with `SIDE=blue` or `SIDE=green`, and another port with a second word, for example `scripts/07-expose-localhost.sh app 9090`.

Why can't the gateway simply answer to the name `localhost`? Because its certificate is made out to `app.fipsdemo.test`. A certificate is an ID card with a name on it, and the name has to match the address you typed.

All three listen only on `127.0.0.1`, which means only your own computer can reach them. `LISTEN_ADDRESS=0.0.0.0` opens the script's port to your network; do that only on a network you trust.

## Step 6 — Save the current state

```bash
scripts/10-save-state.sh --label my-first-save
```

**What just happened:** the script wrote a folder `state/<time>-my-first-save/` and a zip file next to it. Inside are all the Kubernetes objects of the demo, the Istio settings, a copy of the project, the secrets from `work/`, the logs, and a list of **SHA-256 checksums** so that any later change to a file is noticed.

> The zip holds secrets. Treat it like a house key. Add `--encrypt` to lock it with a passphrase.

## Step 7 — Upgrade to FIPS (SHA-2)

```bash
scripts/20-upgrade-to-fips.sh
```

This is the main event. The script works in **phases**, and after the risky ones there is a **gate** (a test that must pass):

| Phase | What it does | If it fails |
|---|---|---|
| 0 | Checks only: is blue healthy? are the green nodes there? does FreeIPA have SHA-2 keys for the accounts? | stops, nothing was changed |
| 1 | Saves the state (the "safe point") | stops, nothing was changed |
| 2 | Builds the FIPS image `fipsdemo-app:2.0-fips` | rolls back |
| 3 | **Expand:** adds the new things *next to* the old ones — SHA-2-only keytab copy, new cookie key, FIPS Kerberos settings, new 3072-bit TLS key and certificate | rolls back |
| 4 | Switches Istio to the FIPS TLS rules; **gate:** blue must still work | rolls back |
| 5 | Starts the **green** (FIPS) pods on the green nodes. Visitors still go to blue | rolls back |
| 6 | **Gate:** tests green through the real front door using a secret header, so no visitor sees it yet | rolls back |
| 7 | **Cut-over:** sends all visitors to green and shows the new certificate; **gate:** full test | rolls back |
| 8 | Saves the new state | — |

"Rolls back" means: the script itself puts everything back the way the safe point says, tests blue, and then stops with an error. You do not have to do anything.

At the end the test output shows the "after" picture:

```
[PASS ] Kerberos ticket key type is aes256-cts-hmac-sha384-192
[PASS ] app crypto profile is 'fips'
[PASS ] login cookies are signed with HmacSHA256
[PASS ] Linux crypto policy inside the pod is FIPS
[PASS ] the pod's keytab holds SHA-2 keys only
[WARN ] PRACTICE MODE: node kernel is not in FIPS mode. ...
```

That last `WARN` is the honest reminder from note 1.

## Step 8 — See what changed

| Thing | Before (blue) | After (green) |
|---|---|---|
| App image | `fipsdemo-app:1.0-nonfips` | `fipsdemo-app:2.0-fips` |
| Linux crypto policy inside the pod | `DEFAULT` | `FIPS` |
| Kerberos ticket key type | `aes256-cts-hmac-sha1-96` | `aes256-cts-hmac-sha384-192` |
| Keys inside the app's keytab | 4 (two SHA-1, two SHA-2) | 2 (SHA-2 only) |
| Login cookie signature | `HmacSHA1` | `HmacSHA256` |
| TLS key at the front door | RSA 2048 bits | RSA 3072 bits (new key, new certificate) |
| Istio TLS rules | normal | `fips-140-3` |
| Where the pods run | blue node pool | green node pool (FIPS kernel in a real cluster) |

The web pages show the same facts: the banner turns from blue to green, and the secure page tells you which key type your Kerberos ticket used.

## Step 9 — Practise going back (do this, it is the point)

**Fast rollback** — flips the traffic switch back to blue. Blue was never touched, so this takes seconds:

```bash
scripts/30-rollback.sh
```

**Roll forward again** — changed your mind? Flip it back to green:

```bash
scripts/31-switch-live.sh green
```

**Full rollback** — puts *everything* back the way the safe point says: green pods removed, FIPS-only secrets removed, Istio back to normal rules:

```bash
scripts/30-rollback.sh --full
```

After a full rollback you can simply run `scripts/20-upgrade-to-fips.sh` again.

## Step 10 — Finalize (only when you are sure)

Run the upgrade again so that you are on green, watch it for a while, then:

```bash
scripts/50-finalize-fips.sh
```

This is the **point of no quick return**. It removes the blue pods and their old-style secrets, empties the blue node (so even Istio itself moves to the green node), and asks FreeIPA for **brand-new, SHA-2-only keys** for the app. After that, old keytabs — also the ones inside old snapshots — no longer work. The script asks you to type `FINALIZE` first.

## Step 11 — Carry the state to another computer

```bash
scripts/10-save-state.sh --label travel --with-images --with-ipa-data --encrypt
```

- `--with-images` adds the container images, so the other computer does not need to build them.
- `--with-ipa-data` adds FreeIPA's whole data folder (users, keys, CA). Without it, the saved keytab and certificates would not match a fresh FreeIPA.
- `--encrypt` locks the zip with AES-256 and a passphrase.

On the other computer (with Docker, kind, kubectl, istioctl installed):

```bash
# if you used --encrypt, unlock it first (it asks for the passphrase):
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in <time>-travel.zip.enc -out <time>-travel.zip
unzip <time>-travel.zip
cd <time>-travel/project
scripts/40-restore-state.sh .. --new-cluster
```

The zip contains a full copy of the project, so you do not need anything else.

## Clean up

```bash
scripts/60-collect-logs.sh      # optional: gather all pod, proxy and FreeIPA logs first
scripts/90-destroy.sh           # removes the cluster and the FreeIPA container
scripts/90-destroy.sh --all     # also removes FreeIPA's data and the work/ folder
```

`logs/` and `state/` are kept on purpose. They are your records.

---

# Part 2 — Background: what all the words mean

## FIPS, in one paragraph

**FIPS 140** is a rule book from the U.S. government's standards office (NIST). It says two things. First, *which secret-code maths is allowed* (for example AES and SHA-2 are in, older or newer-but-unapproved recipes are out). Second, *the toolbox that does the maths must be checked by an independent lab* and get a certificate. A system "runs in FIPS mode" when it uses only such checked toolboxes and only the allowed maths.

Two dates matter in 2026. The older version of the rule book, **FIPS 140-2**, was retired: since **22 September 2026** all of its certificates are on NIST's "historical" list. **FIPS 140-3** is now the only active version. So when you choose products today, look for FIPS 140-3 certificates.

## SHA-1 and SHA-2

A **hash** is a fingerprint of data: put in any text, get out a short code. If the text changes even a little, the code changes completely.

- **SHA-1** is an old fingerprint recipe (from 1995). Researchers have shown how to make two different documents with the same SHA-1 fingerprint. That is bad, so it is being retired everywhere.
- **SHA-2** is the newer family: **SHA-256, SHA-384, SHA-512**. These are the ones FIPS wants you to use.

"Upgrade to FIPS SHA-2" therefore means: *everywhere a fingerprint is used to protect something, move from SHA-1 to SHA-2*. In this project that is three places you can actually see: Kerberos tickets, the app's cookie signature, and TLS.

## Why FIPS mode belongs to the *node*, not the pod

A normal computer has one **kernel** (the core of the operating system). A **container** does not bring its own kernel. It borrows the kernel of the machine it runs on. Think of flats in one building: every flat has its own furniture (its own files and programs), but they all share one foundation.

Linux FIPS mode is switched on in the kernel when the machine starts (boot option `fips=1`). You can read the switch here:

```bash
cat /proc/sys/crypto/fips_enabled     # 1 = on, 0 = off
```

A container sees the value of its **host**. You cannot turn it on for one container. That gives us two jobs:

1. **Nodes:** the machines must be started in FIPS mode.
2. **Images:** the container image must contain crypto libraries that know how to behave in FIPS mode, and must be set to the FIPS rule set.

Our FIPS image does job 2 with one command that Red Hat-family systems provide:

```bash
update-crypto-policies --set FIPS
```

That command prints a warning: *"Using 'update-crypto-policies --set FIPS' is not sufficient for FIPS compliance."* The tool itself is telling you about job 1.

## Kubernetes, pods, nodes, Docker and kind

- **Docker** runs **containers**: programs packed together with the files they need.
- **Kubernetes** is a manager for many containers on many machines. A machine is a **node**. One or more containers that belong together form a **pod**. A **Deployment** says "keep N copies of this pod running".
- **kind** means "Kubernetes IN Docker". It pretends that Docker containers are nodes. Great for practising. Because those "nodes" are containers, they all share *your computer's* kernel. That is exactly why your practice cluster cannot be in real FIPS mode unless your own computer is.

## FreeIPA, Kerberos, tickets, keytabs and key types

**FreeIPA** is an open-source **domain controller**: one place that stores users, passwords, groups and certificates. Think of the school office. (Red Hat sells the same thing as "Identity Management", IdM.)

**Kerberos** is how FreeIPA checks passwords without sending them around:

1. The app tells the Kerberos server (the **KDC**): "this is alice, here is proof made with her password."
2. If the proof is right, the KDC hands back a **ticket** — like a hall pass with a time limit.
3. A wrong password means no ticket.

Our app does one more careful thing. With alice's ticket it asks the KDC for a second ticket, *for the app itself*, and opens it with the app's own secret key. Only the real KDC knows that key. So this proves the app was not talking to a fake KDC.

The app's own secret keys live in a file called a **keytab** ("key table").

Every key has a **type** (Kerberos calls it an *enctype*). The four types a modern FreeIPA makes by default are:

| Key type | Family | Allowed under FIPS? |
|---|---|---|
| `aes256-cts-hmac-sha384-192` | SHA-2 | yes |
| `aes128-cts-hmac-sha256-128` | SHA-2 | yes |
| `aes256-cts-hmac-sha1-96` | SHA-1 | no (in the RHEL 9 FIPS policy) |
| `aes128-cts-hmac-sha1-96` | SHA-1 | no (in the RHEL 9 FIPS policy) |

This is good news for the upgrade: a modern FreeIPA already holds **both** families of keys for every user. The old pods can keep using SHA-1 keys while the new pods use SHA-2 keys. Nobody has to change at the same moment.

Two traps the project protects you from (both were proven in the tests):

- **An account with only SHA-1 keys cannot log in to a FIPS pod.** That can happen with very old accounts. The upgrade script checks the accounts first. The cure is simple: when the user changes the password once, FreeIPA makes all four key types.
- **Asking FreeIPA for a new keytab makes new keys, and every older keytab stops working.** So the upgrade never does that. It makes a *filtered copy* of the existing keytab that keeps only the SHA-2 keys. New keys are made only in the finalize step.

## Certificates and mutual TLS

A **certificate** is an ID card for a computer or a program. A **CA** (certificate authority) is the office that issues ID cards. FreeIPA has a CA built in.

**TLS** is the lock on a web connection (the "s" in https). In normal TLS only the server shows an ID card. In **mutual TLS (mTLS)** *both* sides show an ID card. This project uses it in two places:

1. **Inside the cluster:** Istio gives every pod an ID card and sets the rule "STRICT": no ID card, no talking. The app may only be called by the gateway.
2. **At the front door:** visitors *may* show a client certificate. If they do, it must come from FreeIPA's CA. The **certificate page** (`/mtls`) only opens for visitors who showed one.

## Istio: sidecar, gateway and the way out

**Istio** is a **service mesh**. It puts a small proxy program next to your app in the same pod (a **sidecar**). All network traffic of the pod goes through that proxy. This lets Istio add locks (mTLS), write logs, and make rules without changing the app.

- The **gateway** is a proxy at the front door. It ends the visitor's https connection and passes the request on.
- The **way out** ("egress"): we tell Istio `REGISTRY_ONLY`, which means *pods may only reach addresses on the list*. The list has exactly one outside entry: FreeIPA's Kerberos port 88. Everything else is refused.
- One detail: Istio's proxy handles **TCP**, not UDP. Kerberos can use either. The app's Kerberos settings say "always use TCP" so that the traffic really goes through the proxy.

**Istio and FIPS.** Since Istio 1.31 there is one setting, `COMPLIANCE_POLICY=fips-140-3`. It limits the proxies to TLS 1.2 and 1.3, FIPS-approved cipher suites and the curves P-256 and P-384. Istio copies the setting into every sidecar and gateway when they start. *Important:* this setting limits the maths. Whether the crypto library inside your Istio build has its own FIPS certificate depends on where you get Istio from. Ask your Istio vendor.

---

# Part 3 — The safe upgrade strategy

## The eight rules

1. **Never rebuild the thing that is serving visitors.** Build the new thing next to it, test it, then switch. (Blue stays, green is new.)
2. **Save before you change.** Every risky action starts with a snapshot that has checksums.
3. **One layer at a time, with a test after each.** A failed test stops the upgrade. These tests are the **gates**.
4. **Expand → migrate → contract.**
   - *Expand:* add the new things beside the old ones. Both work.
   - *Migrate:* move the visitors. Going back is still easy.
   - *Contract:* remove the old things. Do this last, and only when you are sure.
5. **Know your one-way doors.** Some steps cannot be undone quickly. Put them at the very end and make a human say yes.
6. **Roll back automatically, and practise rolling back.** A rollback you have never tried is a hope, not a plan.
7. **Write everything down.** Every script run goes to a log file. Logs travel with the snapshot.
8. **Rehearse first.** Practice mode on a laptop → a test cluster with real FIPS nodes → production.

## What changes at each layer, and how to undo it

| Layer | Non-FIPS → FIPS change | How the project does it | How to go back |
|---|---|---|---|
| **Node (kernel)** | kernel started in FIPS mode | new **green node pool**; pods are placed there with a node label | pods go back to the blue pool (it still exists) |
| **Container image** | Linux crypto policy `FIPS` | new image `2.0-fips`, same base as the old one | blue pods still run the old image |
| **App settings** | cookie signature SHA-1 → SHA-256, TLS rules | the image carries the profile, so image = mode | same as above |
| **Kerberos client** | SHA-1 key types → SHA-2 only | a second settings file; SHA-2-only **copy** of the keytab | blue keeps its own settings and keytab |
| **TLS at the front door** | new, bigger key and certificate | second secret `fipsdemo-tls-v2`; the gateway is pointed at it | point the gateway back at `fipsdemo-tls-v1` |
| **Mesh (Istio)** | `COMPLIANCE_POLICY=fips-140-3` | `istioctl install` with one extra setting, then restart the proxies | `istioctl install` without it, restart the proxies |
| **Traffic** | visitors blue → green | one line in an Istio rule | the same line, back to blue |
| **Kerberos keys (KDC)** | brand-new SHA-2-only keys | **only in the finalize step** | **one-way door** — needs a restore of FreeIPA data |
| **Old nodes** | drained and deleted | **only in the finalize step** | **one-way door** — you would have to create nodes again |
| **FreeIPA server itself** | server installed on FIPS machines | *not done by the demo scripts* — see Part 7 | — |

## Why a new node pool instead of "switching the old nodes"?

Because of the foundation-of-the-building idea from Part 2. Turning on FIPS means restarting the machine with a different kernel setting, and Red Hat recommends choosing FIPS when a system is *installed*, not afterwards. So the clean way is:

1. Add new nodes that were built in FIPS mode (the green pool).
2. Start the new pods there.
3. Move the visitors.
4. Empty the old nodes (`kubectl drain`) and delete them.

Cloud providers support exactly this pattern with FIPS node pools.

## What the gates check

The test script (`scripts/06-test.sh`) sorts its findings into three kinds:

- **PASS** – as expected.
- **FAIL** – something is broken. An upgrade stops and rolls back.
- **WARN** – worth a look, but it does not stop an upgrade. Example: "practice mode, kernel is not FIPS".

It checks the pages (public, login, secure, certificate), the crypto facts the app reports about itself, Kubernetes facts (pods ready, on the right nodes, sidecar present, strict mTLS), the TLS at the front door (certificate from FreeIPA's CA, SHA-2 signature, key size, old or non-FIPS choices refused), and that the pod cannot reach a port we did not allow.

---

# Part 4 — A tour of the project

```
k8s-fips-upgrade-demo/
├── TUTORIAL.md              this file
├── README.md                the short version
├── config.env               every setting in one place
├── app/                     the Java app
│   ├── src/demo/*.java      7 small files, no outside libraries
│   ├── web/                 the HTML pages and one CSS file
│   ├── Dockerfile.nonfips   image 1.0 (blue)
│   ├── Dockerfile.fips      image 2.0 (green)
│   └── run.sh               starts Java
├── k8s/
│   ├── kind-cluster.yaml    the 3-node cluster
│   ├── istio/               Istio install settings + the gateway
│   └── app/                 app objects, traffic rules, Kerberos settings (templates)
├── lib/
│   ├── common.sh            logging, waiting, small helpers
│   ├── platform.sh          every Docker / kind / istioctl / FreeIPA command
│   └── deploy.sh            the app's Kubernetes objects
├── scripts/                 the numbered scripts you run
├── tests/                   tests you can run yourself + the test report
├── examples/                a real saved-state zip from the author's test run (throw-away test keys only)
├── logs/                    one log file per run (made when you run things)
├── state/                   snapshots and zips (made when you run things)
└── work/                    run-time secrets: keys, keytab, certificates (made when you run things)
```

## The scripts

| Script | What it does |
|---|---|
| `00-check-tools.sh` | checks your computer, changes nothing |
| `01-create-cluster.sh` | makes the kind cluster |
| `02-start-ipa.sh` | starts FreeIPA, makes the demo accounts, keytab and certificates |
| `03-install-istio.sh` | installs Istio and the gateway |
| `04-build-images.sh [nonfips\|fips\|all]` | builds and loads the app image(s) |
| `05-deploy-nonfips.sh` | deploys blue (non-FIPS) and tests it |
| `07-expose-localhost.sh [app\|gateway] [PORT]` | opens a port on localhost that leads to the app (or to the gateway) |
| `06-test.sh [nonfips\|fips\|auto]` | the tests. `TRACK=green` peeks at one side. `TEST_MODE=direct` skips the mesh |
| `10-save-state.sh` | snapshot + zip + checksums |
| `20-upgrade-to-fips.sh` | the safe upgrade with gates and automatic rollback |
| `30-rollback.sh [--fast\|--full]` | go back to blue |
| `31-switch-live.sh blue\|green` | the traffic switch on its own |
| `40-restore-state.sh SNAPSHOT` | put a saved state back (same cluster or a new one) |
| `50-finalize-fips.sh` | remove the old side for good, rotate keys |
| `60-collect-logs.sh` | gather pod, proxy, Istio and FreeIPA logs |
| `90-destroy.sh [--all]` | remove everything |

## The Java app

It is on purpose very small and uses **only the Java that comes with the JDK** — no Maven, no downloads, nothing to patch later.

| Page | Who may see it |
|---|---|
| `/` | everyone (public page) |
| `/login` | everyone; checks the password with FreeIPA Kerberos |
| `/secure` | only after login |
| `/mtls` | only visitors who showed a client certificate from FreeIPA's CA |
| `/status` | everyone; facts about the crypto settings, as JSON |
| `/healthz` | Kubernetes uses it to see if the pod is alive |

The one switch that separates old from new is the **crypto profile**. It is baked into the image:

| | `legacy` (image 1.0) | `fips` (image 2.0) |
|---|---|---|
| Cookie signature | HmacSHA1 | HmacSHA256 |
| Java TLS rules | Java defaults | the list from the RHEL 9 FIPS policy |
| Kerberos settings file | asks for SHA-1 key types first | SHA-2 key types only |

When the app starts it runs a small **self-test**: it does a calculation whose right answer is known and refuses to start if the result is different. FIPS toolboxes do the same thing; the app copies the idea.

## Logging — where to look

| What | Where |
|---|---|
| Every script run | `logs/<time>-<script>.log` (one file per run; scripts started by another script write into the same file) |
| One line per run (start, end, exit code) | `logs/history.log` |
| App requests and logins | `kubectl -n fipsdemo logs deploy/fipsdemo-green -c app` |
| Every request through a proxy | `kubectl -n fipsdemo logs deploy/fipsdemo-green -c istio-proxy` |
| FreeIPA | `docker logs fipsdemo-ipa` |
| All of the above in one go | `scripts/60-collect-logs.sh` |

The app never logs passwords.

## What is inside a saved state

```
state/20261005T234141Z-pre-fips/
├── meta/           when, which cluster, which side was live, mesh policy, node list
├── raw/            every object exactly as it was (for "what happened?" questions)
├── restore/        every object cleaned up, ready to be applied, numbered in the right order
├── istio/          Istio install settings and the compliance policy at that moment
├── rollout/        rollout history, which images were running where
├── project/        a full copy of this project
├── secrets-work/   the run-time secrets from work/
├── logs/           the logs up to that moment
├── images/         container images            (only with --with-images)
├── ipa/            FreeIPA's data              (only with --with-ipa-data)
└── SHA256SUMS      a SHA-256 fingerprint of every file above
```

The restore script checks every fingerprint first. If even one byte was changed, it refuses to use the snapshot.

---

# Part 5 — Your options, with pros and cons

## A. How to get FIPS nodes

| Option | Good | Not so good |
|---|---|---|
| **New FIPS node pool, move pods, drain old pool** (used here) | old nodes untouched until the end; easy to go back; works the same in clouds | you pay for extra nodes for a while |
| Convert each node in place | no extra machines | each node must restart; vendor advice is to choose FIPS at install time; hard to go back |
| Whole new FIPS cluster beside the old one | cleanest separation; also the control plane is new | most work; data and DNS must move |

## B. How to move the visitors

| Option | Good | Not so good |
|---|---|---|
| **Blue/green with a preview header** (used here) | test the new side through the real front door before anyone sees it; instant switch back | needs double capacity for a while; logins reset at the switch |
| Canary (5 %, 25 %, 100 %) | problems hit few visitors first | visitors may bounce between old and new; needs sticky sessions |
| Rolling update of one Deployment | simplest | old and new are mixed during the roll; going back is another roll |

## C. Which FIPS base image

| Option | Good | Not so good |
|---|---|---|
| **Red Hat UBI 9 + Red Hat OpenJDK 25** (used here) | free to pull; same family for both images; Red Hat's Java switches to FIPS by itself on a FIPS host | counts as FIPS-validated only on RHEL hosts |
| Another vendor's FIPS image (for example Ubuntu Pro FIPS, or a hardened-image vendor) | may fit your cloud or your contract | usually needs a paid plan; check the certificate |
| Any Java image + a FIPS crypto library for Java (for example Bouncy Castle FIPS) | does not depend on the Linux in the image | more work in the app; you must wire it in and test it |

## D. Which Istio rule set

| Option | Good | Not so good |
|---|---|---|
| **`fips-140-3`** (used here) | matches today's active standard; allows TLS 1.3 | new in Istio 1.31, so less field experience |
| `fips-140-2` | in Istio since 1.21, well known | TLS 1.2 only; the standard it is named after is retired |
| A vendor's FIPS build of Istio | comes with a statement about validated crypto | cost; tied to that vendor's releases |

To try the older rule set: set `ISTIO_COMPLIANCE_POLICY=fips-140-2` in `config.env`.

## E. How to save state

| Option | Good | Not so good |
|---|---|---|
| **Snapshot zip with checksums** (used here) | simple; you can read every file; easy to carry | you must run it yourself; not for big data volumes |
| A backup tool such as Velero | schedules, volumes, object storage | one more thing to install and learn |
| GitOps (the cluster is built from a Git repository) | history and review for every change | secrets need extra care; not a backup of data |

In real projects people combine them: GitOps for the "what should be there", a backup tool for the data, and a snapshot before each risky change.

## F. Where FreeIPA lives

| Option | Good | Not so good |
|---|---|---|
| **A container next to the cluster** (used here) | quick to start for practice | fussy about Docker settings; cannot be in FIPS mode on a non-FIPS host |
| Its own virtual machines (normal for real use) | supported way; can be installed in FIPS mode | more setup |

## G. Practice clusters

| Tool | Good | Not so good |
|---|---|---|
| **kind** (used here) | fast; several nodes; used by Istio's own docs | nodes share your kernel |
| minikube | can use a virtual machine with its own kernel | heavier |
| k3d / k3s | very light | a different Kubernetes flavour |

---

# Part 6 — Best practices checklist

**Before**

- [ ] Write down *why* you need FIPS and which standard (today: FIPS 140-3).
- [ ] List every place that uses crypto: TLS, Kerberos, cookies, tokens, stored hashes, keystores.
- [ ] Check that every account already has SHA-2 Kerberos keys.
- [ ] Use the same base image family for old and new. Change one thing at a time.
- [ ] Pin versions (this project pins the Kubernetes node image by its digest).
- [ ] Rehearse the whole thing, including the rollback, on a practice cluster.

**During**

- [ ] Save state first. Keep the checksum.
- [ ] Add new things beside old things. Do not edit things that are serving visitors.
- [ ] A test after every layer. Stop on the first failure.
- [ ] Test the new side through the real front door before visitors see it.
- [ ] Keep the old side running until you are sure.

**After**

- [ ] Watch for a few days before you finalize.
- [ ] Finalize on purpose: remove the old side, rotate keys, revoke the old certificate.
- [ ] Save state again. Store the zip somewhere safe and encrypted.
- [ ] Keep the logs. Auditors ask for them.

**Always**

- [ ] Secrets never go into Git. Here they live in `work/` and in the snapshot.
- [ ] No passwords in logs.
- [ ] Least privilege: the app runs as a normal user, with a read-only file system, and may only talk to FreeIPA.

---

# Part 7 — From practice to a real FIPS system

The demo teaches the steps. A real system needs these things on top:

1. **Real FIPS nodes.** Machines started in FIPS mode, running an operating system whose crypto modules have a FIPS 140-3 certificate. Then set `REQUIRE_KERNEL_FIPS=true` in `config.env`, and set `GREEN_NODE_SELECTOR` to the label of your FIPS node pool.
2. **Images that count.** A FIPS-ready image only counts as validated on the host it was validated for. Read your vendor's statement.
3. **Test the app on a real FIPS node.** On a FIPS host, Red Hat's Java changes its crypto providers by itself. An app can behave differently there (for example with keystore files). Find that out in a test cluster, not in production.
4. **Istio.** Decide between upstream Istio with the compliance setting and a vendor's FIPS build.
5. **The FreeIPA server itself.** The demo's FreeIPA is *not* in FIPS mode. Red Hat's guidance is that FIPS mode must be switched on **before** the identity server is installed; an existing non-FIPS server is not converted. Plan new FIPS servers and a migration. This is its own project.
6. **Secrets.** Use a secrets manager instead of files in `work/`. Always encrypt snapshots.
7. **No single points.** More than one gateway pod, more than one `istiod`, more than one FreeIPA server, so that draining a node interrupts nobody.
8. **Kubernetes itself.** The control plane and the node software also use crypto. Managed Kubernetes services and some distributions offer FIPS options for them.

---

# Part 8 — When something goes wrong

First rule: **read the log**. Every script tells you its log file when it starts and when it fails.

## When FreeIPA will not start

FreeIPA runs a full `systemd` inside its container, and `systemd` must be able to write to its control group ("cgroup"). The FreeIPA container project says:

- Docker **with user-namespace remapping** (`userns-remap`): needs nothing extra.
- **Rootless** Docker: needs `--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw`.
- **Privileged** containers are not supported.

The script picks for you (`IPA_DOCKER_EXTRA_OPTS=auto`): no extra flags when remapping is on, otherwise the two flags above. If that does not work on your machine:

```bash
docker logs fipsdemo-ipa | tail -50          # what did it say?
scripts/90-destroy.sh --all                   # start clean
# then either turn on userns-remap in Docker and use:
IPA_DOCKER_EXTRA_OPTS="" scripts/02-start-ipa.sh
# or try another image:
IPA_IMAGE=quay.io/freeipa/freeipa-server:rocky-9 scripts/02-start-ipa.sh
```

Other common causes: too little memory for Docker, or a very slow disk (the first start really can take 15 minutes).

## Other problems

| What you see | Likely cause | What to do |
|---|---|---|
| `port is already allocated` when creating the cluster | something else uses port 8443 | `HOST_HTTPS_PORT=9443 scripts/01-create-cluster.sh` (and keep using that value) |
| Pods stay `Pending` | node labels missing, or not enough memory | `kubectl get nodes --show-labels`, `kubectl -n fipsdemo describe pod ...` |
| Pods show `ErrImageNeverPull` or `ImagePullBackOff` | the image was not loaded into kind | `scripts/04-build-images.sh all` |
| Login always fails | FreeIPA not reachable, or the password is wrong or expired | look at `kubectl -n fipsdemo logs deploy/fipsdemo-blue -c app`; the reason is logged |
| Login fails only on the FIPS side | the account has no SHA-2 keys | let the user change the password once |
| `curl: SSL certificate problem` | curl does not know FreeIPA's CA | add `--cacert work/ipa/ca.crt` |
| The upgrade "undid itself" | a gate failed | read the log; fix; run it again. For Istio trouble try `ISTIO_COMPLIANCE_POLICY=fips-140-2` |
| Everything broke after a reboot | FreeIPA's address inside Docker changed | run `scripts/02-start-ipa.sh` again, then `scripts/40-restore-state.sh <latest snapshot> --in-place` (it rewrites the address) |
| The test says the app is fine but the web site is not | the problem is in the mesh, not the app | compare `TEST_MODE=direct scripts/06-test.sh` (no mesh) with the normal test |

---

# Part 9 — How this was tested

The full list with results is in **`tests/TEST-REPORT.md`**. In short:

**Run for real**

- The Java app against a real MIT Kerberos server (the Kerberos software inside FreeIPA), in both profiles.
- The real scripts on a real Kubernetes 1.36 cluster: deploy, test, save state, upgrade, two upgrades that were *forced to fail* (to prove the automatic rollback), fast rollback, switch forward, full rollback, finalize with key rotation, log collection.
- The saved state: a changed snapshot was refused; both namespaces were deleted and rebuilt from the zip using the project copy inside the zip; an encrypted zip was restored, and a wrong passphrase was refused.
- Every manifest with the real `istioctl` 1.31.1 (`validate` and `analyze`), and the Istio install settings rendered with and without the FIPS policy.
- `update-crypto-policies --set FIPS` on a real AlmaLinux 9 file system (the same family as UBI 9).
- Every script through `bash -n` and `shellcheck`.

**Not run by the author**

- Anything that needs Docker, kind, Istio's running proxies, or the real FreeIPA container: building the UBI images, the gateway's TLS and mutual TLS, the "way out" lock, the FreeIPA commands, the node drain, and the `--new-cluster`, `--with-images` and `--with-ipa-data` paths.

On the test cluster those pieces were replaced by small stand-ins, which are in `tests/sandbox/` so you can see exactly what was swapped.

You can repeat two of the tests without Docker:

```bash
tests/offline-tests.sh            # syntax, shellcheck, compile, manifest checks
sudo tests/app-kerberos-test.sh   # the app against a throw-away Kerberos server
```

---

# Part 10 — Word list

| Word | Meaning |
|---|---|
| **Blue / green** | two copies of a system: blue is the one running now, green is the new one |
| **CA** | certificate authority: the office that issues certificates |
| **Certificate** | an ID card for a computer or program |
| **Cipher suite** | the set of maths recipes used for one TLS connection |
| **Container** | a program packed with the files it needs; shares the host's kernel |
| **Crypto policy** | on Red Hat-family Linux: one switch that sets the rules for all crypto libraries |
| **Cut-over** | the moment visitors are moved from old to new |
| **Drain** | politely move all pods off a node |
| **Egress / ingress** | traffic going out of / coming into the cluster |
| **Enctype** | the type of a Kerberos key |
| **FIPS 140-3** | the active U.S. standard for crypto modules |
| **FreeIPA** | open-source domain controller: users, Kerberos, certificates |
| **Gate** | a test that must pass before the next step |
| **Gateway** | the Istio proxy at the front door |
| **Hash** | a fingerprint of data |
| **HMAC** | a fingerprint made with a secret key; proves who made it |
| **Image** | the packed file a container is started from |
| **Istio** | a service mesh: proxies next to every pod |
| **KDC** | the Kerberos server |
| **Kernel** | the core of the operating system |
| **Keytab** | a file with a service's Kerberos keys |
| **kind** | "Kubernetes IN Docker" |
| **mTLS** | mutual TLS: both sides show a certificate |
| **Node** | a machine in a Kubernetes cluster |
| **Node pool** | a group of nodes of the same kind |
| **Pod** | one or more containers that belong together |
| **Realm** | a Kerberos "kingdom", written in capitals |
| **Rollback** | going back to how it was |
| **SHA-1 / SHA-2** | old / current families of hash recipes |
| **Sidecar** | the Istio proxy inside an app pod |
| **Snapshot** | a saved copy of the state at one moment |
| **Ticket** | Kerberos proof that you logged in, valid for a limited time |
| **TLS** | the lock on a network connection (https) |

---

# Part 11 — Where the facts come from

Checked in October 2026:

- **NIST, Cryptographic Module Validation Program** — FIPS 140-3 transition: FIPS 140-2 certificates moved to the historical list after 21 September 2026. `csrc.nist.gov/projects/fips-140-3-transition-effort`
- **kind releases** — v0.33.0 and its node images. `github.com/kubernetes-sigs/kind/releases`
- **Istio 1.31 change notes** — the new `fips-140-3` compliance policy and supported Kubernetes versions. `istio.io/latest/news/releases/1.31.x/announcing-1.31/change-notes/`
- **Istio documentation** — installing gateways (gateway injection) and secure gateways (mutual TLS secrets). `istio.io/latest/docs/`
- **Istio 1.31.1 release files** — the install charts were read and rendered directly to confirm how the compliance policy reaches istiod, sidecars and gateways.
- **FreeIPA container project** — image tags and the Docker notes about cgroups and user namespaces. `github.com/freeipa/freeipa-container`
- **FreeIPA source code** — default Kerberos key types, the certificate profile, and the `ipa-getkeytab` manual page. `github.com/freeipa/freeipa`
- **Red Hat documentation** — "Planning Identity Management" (FIPS and Kerberos key types) and "Configuring Red Hat build of OpenJDK 25 on RHEL with FIPS". `docs.redhat.com`
- **AlmaLinux 9.8 container file system** — the `DEFAULT` and `FIPS` crypto policy files were read directly. `github.com/AlmaLinux/container-images`
- **Red Hat OpenJDK container definitions** — the UBI 9 OpenJDK 25 images. `github.com/rh-openjdk/redhat-openjdk-containers`
