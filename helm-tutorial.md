# Helm, Explained Like You're in Middle School (With Real, Production-Grade Examples)

> **Who this is for:** anyone who can open a terminal and type. No Kubernetes experience needed.
> **What you'll build:** a "school" on Kubernetes — a Postgres database (the record cabinet), Keycloak (the front-office ID checker), Kafka (the school intercom + mailroom), and three apps (Java, Python, Go) that use them — deployed with Helm, wired with Terraform, and running on your laptop, Azure AKS, AWS EKS, or Google GKE.
> **Current as of September 2026:** Helm 4.x (Helm 3 gets its final feature release on 9 Sept 2026 and security fixes end 10 Feb 2027), Terraform Helm provider 3.x, Strimzi 1.x, Keycloak 26.x, CloudNativePG 1.2x, Kafka 4.x.

**How to read this**

| Symbol | Meaning |
|---|---|
| 🛒 | Grocery-store way of understanding the idea |
| 🏫 | School / classroom way of understanding the idea |
| ✅ | Best practice — do this |
| ⚠️ | Gotcha — something that bites people |
| 🧪 | Try it yourself |
| 📝 | Real config you can copy |

Everything in a `code block` is something you can type or paste. Anything in `<angle brackets>` is a placeholder you replace.

---

## Table of contents

1. [Quick start: your first Helm install in 15 minutes](#part-1)
2. [Background: what Kubernetes actually is](#part-2)
3. [Background: what Helm actually is](#part-3)
4. [Anatomy of a chart](#part-4)
5. [Everyday commands](#part-5)
6. [Best practices](#part-6)
7. [Gotchas (the big list)](#part-7)
8. [Docker and Podman: building and running images](#part-8)
9. [Postgres with CloudNativePG](#part-9)
10. [Keycloak (login and single sign-on)](#part-10)
11. [Kafka with add-ons (Strimzi)](#part-11)
12. [Your own apps: Java Spring + OIDC, Python, Go](#part-12)
13. [Terraform: keeping state and installing charts](#part-13)
14. [Cloud clusters: AKS, EKS, GKE](#part-14)
15. [Putting it all together](#part-15)
16. [Troubleshooting toolbox](#part-16)
17. [Glossary and field-trip exercises](#part-17)

---

<a id="part-1"></a>
## Part 1 — Quick start: your first Helm install in 15 minutes

We start by *doing*, then we explain. Follow these steps in order.

### Step 1: install the four tools

You need a container engine (**Docker** *or* **Podman**), a tiny local Kubernetes (**kind**), the Kubernetes remote control (**kubectl**), and **Helm**.

**macOS (Homebrew):**

```bash
brew install --cask docker      # or: brew install podman && podman machine init && podman machine start
brew install kind kubectl helm
```

**Windows (winget, in PowerShell):**

```powershell
winget install Docker.DockerDesktop   # or: winget install RedHat.Podman
winget install Kubernetes.kind Kubernetes.kubectl Helm.Helm
```

**Linux (Debian/Ubuntu):**

```bash
# Docker: https://docs.docker.com/engine/install/   (or: sudo apt install podman)
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 && chmod +x kind && sudo mv kind /usr/local/bin/
# Helm 4 (official install script)
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh && ./get_helm.sh
```

Check that everything answers:

```bash
docker version      # or: podman version
kind version
kubectl version --client
helm version        # should print v4.x
```

⚠️ **Gotcha:** if `helm version` prints `v3.x`, you have an old Helm from a package manager. Helm 3 stops getting security fixes in February 2027; install Helm 4 with the script above. Helm 4 manages Helm 3 releases without any migration step.

### Step 2: create a throwaway Kubernetes cluster

```bash
kind create cluster --name school
```

If you use Podman instead of Docker:

```bash
KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --name school
```

Wait about a minute, then:

```bash
kubectl get nodes
# NAME                   STATUS   ROLES           AGE   VERSION
# school-control-plane   Ready    control-plane   60s   v1.3x.x
```

🏫 You just built an empty school building. It has a principal's office (the control plane) but no classrooms yet.

### Step 3: let Helm write a starter chart for you

```bash
helm create hello-school
```

Helm creates a folder. Look inside:

```text
hello-school/
├── Chart.yaml          # the recipe card's title, version, description
├── values.yaml         # the fill-in-the-blanks (how many copies, which image, which port)
├── charts/             # other recipes this recipe depends on (empty for now)
├── templates/          # the actual Kubernetes YAML, with blanks to fill in
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── serviceaccount.yaml
│   ├── _helpers.tpl    # reusable snippets (like a "definitions" page)
│   ├── NOTES.txt       # the message printed after install
│   └── tests/
│       └── test-connection.yaml
└── .helmignore         # files to leave out when packaging
```

🛒 A **chart** is a recipe card. `values.yaml` is the shopping list with default amounts ("2 eggs") that you can change ("make it 3 eggs") without rewriting the recipe.

### Step 4: install it

```bash
helm install hello ./hello-school --namespace demo --create-namespace
```

Read that command left to right: *"Helm, install a **release** named `hello`, using the chart in the folder `./hello-school`, into the namespace `demo`, and create that namespace if it doesn't exist."*

Watch it come alive:

```bash
kubectl get pods -n demo
# NAME                                  READY   STATUS    RESTARTS   AGE
# hello-hello-school-7b9c6d5f4b-x2kq9   1/1     Running   0          30s
```

The starter chart runs a tiny nginx web server. Open a tunnel to it and look at it in your browser:

```bash
kubectl port-forward -n demo svc/hello-hello-school 8080:80
# now open http://localhost:8080  → "Welcome to nginx!"
```

Press `Ctrl+C` to close the tunnel.

### Step 5: change something and upgrade

Open `hello-school/values.yaml` and change `replicaCount: 1` to `replicaCount: 3`. Then:

```bash
helm upgrade hello ./hello-school -n demo
kubectl get pods -n demo      # now 3 pods
helm history hello -n demo
# REVISION  UPDATED   STATUS      CHART               APP VERSION  DESCRIPTION
# 1         ...       superseded  hello-school-0.1.0  1.16.0       Install complete
# 2         ...       deployed    hello-school-0.1.0  1.16.0       Upgrade complete
```

Every install or upgrade creates a numbered **revision**. Helm remembers all of them.

You can also change a value without editing the file:

```bash
helm upgrade hello ./hello-school -n demo --set replicaCount=2
```

### Step 6: oops — roll back

```bash
helm rollback hello 1 -n demo
kubectl get pods -n demo      # back to 1 pod
helm history hello -n demo    # revision 3 = "Rollback to 1"
```

🏫 The teacher tried a new seating chart (revision 2), it was chaos, so they went back to Monday's chart (rollback to revision 1). Helm keeps every old chart in a drawer.

### Step 7: look at what Helm knows

```bash
helm list -n demo                      # what releases exist here?
helm status hello -n demo              # is it healthy? what did NOTES.txt say?
helm get values hello -n demo          # which values did I override?
helm get manifest hello -n demo        # the exact YAML Helm sent to Kubernetes
helm get values hello -n demo --all    # every value, including defaults
```

### Step 8: clean up

```bash
helm uninstall hello -n demo
kind delete cluster --name school       # only when you are completely done with Part 1
```

### What just happened?

1. `helm create` gave you a **chart** (recipe).
2. `helm install` took the recipe + `values.yaml`, filled in the blanks, produced plain Kubernetes YAML, and sent it to the cluster. That running copy is a **release**.
3. Helm saved a snapshot of everything (the chart, the values, the rendered YAML) as a Kubernetes **Secret** in the `demo` namespace named `sh.helm.release.v1.hello.v1`. That's Helm's memory. Revision 2 became `...v2`, and so on.
4. `helm upgrade` compared *what it sent last time* with *what it wants now* and with *what's in the cluster* (a "three-way merge") and applied only the differences.
5. `helm rollback` re-sent the old snapshot.

That's 90% of Helm. The rest of this tutorial is the other 10% — and the 10% is where all the real-world trouble hides.

---

<a id="part-2"></a>
## Part 2 — Background: what Kubernetes actually is

Kubernetes ("K8s") is a program that runs on a group of computers and keeps your apps running the way you described. You don't tell it *how* to do things step by step. You hand it a description ("I want 3 copies of the lunch-menu app, each with 512 MB of memory, reachable on port 80"), and it makes reality match the description, forever, even when computers crash.

🏫 Kubernetes is the whole **school district**, and it works like a very stubborn principal: you give the principal a list of classes that must exist; if a teacher gets sick, a substitute appears automatically; if a classroom floods, the class moves to another room.

Here are the Kubernetes words you'll see in every Helm chart:

| Kubernetes word | What it really is | 🏫 School version | 🛒 Grocery version |
|---|---|---|---|
| **Cluster** | The whole group of machines Kubernetes manages | The school district | The supermarket chain |
| **Node** | One machine (VM or physical) | One school building | One store |
| **Control plane** | The brain that decides what runs where | The district office + principal | Head office |
| **Container** | One packaged program with everything it needs to run | One teacher with their supplies box | A sealed meal kit |
| **Image** | The frozen, shareable file a container starts from | The teacher's training certificate — copy it to make more teachers | The meal-kit box on the warehouse shelf |
| **Registry** | Where images are stored (Docker Hub, GHCR, ECR, ACR, Artifact Registry) | The teacher-training college | The warehouse |
| **Pod** | The smallest thing Kubernetes runs: one or more containers that share a network and disk | A classroom (usually one teacher; sometimes a teacher + aide, called a "sidecar") | A shopping cart holding one or a few kits |
| **Deployment** | "Keep N identical pods running; roll out new versions gradually" | The rule "always have 3 sections of 7th-grade math" | "Always keep 3 registers open" |
| **ReplicaSet** | The thing a Deployment uses to count pods | The sign-in sheet that counts open sections | The register counter |
| **StatefulSet** | Like a Deployment, but each pod has a stable name (`db-0`, `db-1`) and its own disk | Homerooms with permanent room numbers and lockers | Freezers numbered 0, 1, 2 that keep their contents |
| **DaemonSet** | One pod on every node | A hall monitor in every building | A security camera in every store |
| **Job / CronJob** | Run once / run on a schedule | A fire drill / Friday's pop quiz | Nightly restock |
| **Service** | A stable name and IP that load-balances to pods | The front office phone number that connects you to *some* math teacher | The customer-service desk number |
| **Ingress** | Rules for HTTP traffic coming from outside (`auth.school.com → keycloak`) | The front door + hallway signs | Store entrance with aisle signs |
| **Gateway API** | The newer, more powerful replacement for Ingress | A proper reception desk with a receptionist | A store greeter who routes you |
| **ConfigMap** | Plain-text settings (not secret) | The bulletin board / the syllabus | The posted price list |
| **Secret** | Settings that must stay private (passwords, keys) | The locked grade-book cabinet | The safe |
| **PersistentVolumeClaim (PVC)** | A request for a disk that survives pod restarts | A student's locker | A freezer that keeps food when the cart is returned |
| **StorageClass** | Which *kind* of disk to hand out (fast SSD, cheap HDD) | Big locker vs small locker | Freezer vs fridge |
| **Namespace** | A folder to keep things separate | A grade level or wing (7th grade, 8th grade) | Departments (bakery, produce) |
| **ServiceAccount** | An identity for a pod | A staff ID badge | An employee badge |
| **RBAC (Role/RoleBinding)** | Who may do what | The permissions list: who may enter the office | Who has keys to the stockroom |
| **CRD (Custom Resource Definition)** | A new *kind* of object someone taught the cluster about (e.g. `Kafka`, `Cluster`) | A new kind of form the office accepts | A new kind of order form |
| **Operator** | A program that watches CRDs and does the hard work (backups, failover, upgrades) | The band director who runs the whole music program so the principal doesn't have to | The bakery manager who knows how to bake |
| **Probe (liveness/readiness/startup)** | Kubernetes' way to ask "are you alive? ready for traffic? still starting?" | Attendance: "present?" "ready to teach?" "still setting up?" | "Is this register open?" |
| **Requests / limits** | The CPU and memory a pod asks for / may not exceed | Desk space each class needs / may not exceed | Shelf space per product |

Kubernetes stores all these descriptions as YAML. A tiny app needs 3–5 YAML files; a real system needs hundreds. Writing and maintaining those by hand is where Helm comes in.

---

<a id="part-3"></a>
## Part 3 — Background: what Helm actually is

Helm is the **package manager for Kubernetes**, the way `apt`, `brew`, `winget`, `pip` and `npm` are package managers for other things. It answers three questions:

1. **How do I share a Kubernetes app so someone else can install it with one command?** → put it in a **chart**.
2. **How do I install the same app in dev, test and prod with different settings?** → one chart, different **values**.
3. **How do I upgrade or undo safely?** → **releases** and **revisions**.

### The five words you must know

| Word | Meaning | 🛒 | 🏫 |
|---|---|---|---|
| **Chart** | A folder (or `.tgz`) of templates + defaults describing one app | A recipe card | A lesson plan template |
| **Values** | The settings you can change; `values.yaml` has the defaults, you override with `-f my.yaml` or `--set` | Your shopping-list tweaks ("3 eggs, not 2") | Class size, textbook choice |
| **Release** | One installed copy of a chart, with a name, in a namespace | The dish you actually cooked tonight | Period 3 Math (one actual class) |
| **Revision** | A numbered version of a release's history | "Second attempt at the dish" | "Version 2 of the seating chart" |
| **Repository / Registry** | Where charts are published. Classic HTTP repos (`helm repo add`) or OCI registries (`oci://...`) | The aisle where recipe cards and meal kits live | The library of lesson plans |

You can install the *same chart* several times with different release names (`helm install kafka-dev ...` and `helm install kafka-test ...`). They don't interfere as long as the chart names resources using the release name (good charts do).

### Where Helm keeps its memory

Helm has no server. Everything it remembers is a **Secret** in the release's namespace: `sh.helm.release.v1.<release>.v<revision>`. Inside is the compressed chart, the values you used, and the manifest it rendered.

```bash
kubectl get secrets -n demo -l owner=helm
```

This matters for three reasons:

- If you delete that Secret, Helm forgets the release (but the pods keep running!).
- Anyone who can read Secrets in that namespace can read your release's values — including passwords you passed with `--set`. (Fix: don't pass real secrets through values; see Part 6.)
- Kubernetes Secrets max out at 1 MiB. A gigantic chart (huge CRDs in `templates/`) can hit "release size exceeds limit". (Fix: put CRDs in the `crds/` folder or install them separately; or use the SQL storage backend.)

### Helm 4 vs Helm 3 — what's different (2026)

Helm 4.0 shipped in November 2025. The important changes:

| Change | Why you care |
|---|---|
| **Server-side apply (SSA) by default for new releases** | Kubernetes tracks which tool owns which field, so Helm, `kubectl`, Argo CD and operators fight less. Releases created by Helm 3 keep using client-side apply until you pass `--server-side=true` (and `--server-side=false` forces the old way). |
| **`--atomic` → `--rollback-on-failure`, `--force` → `--force-replace`** | Old flags still work but print deprecation warnings. Update CI scripts. |
| **`--wait` uses kstatus** | Much smarter readiness detection (understands CRDs, Jobs, etc.), but needs the `watch` RBAC verb in addition to `list`. A locked-down CI service account can suddenly fail with `--wait`. |
| **Post-renderers are plugins** | `--post-renderer` takes a plugin name, not a path to an executable. |
| **`helm registry login` takes a domain, not a URL** | `helm registry login ghcr.io`, not `helm registry login https://ghcr.io/…`. |
| **Multi-document values files** | One values file can hold several YAML documents separated by `---`, merged in order. |
| **WebAssembly plugins, content-based chart cache** | Faster, safer plugins; repeated installs don't re-download. |

Helm 3 charts (`apiVersion: v2`) work unchanged in Helm 4.

### Helm compared with the alternatives

| Tool | What it is | Pros | Cons |
|---|---|---|---|
| **Plain `kubectl apply -f`** | Raw YAML | Simple, no magic | No templating, no upgrade history, no rollback, copy-paste per environment |
| **Kustomize** | Overlay patches on base YAML (built into kubectl) | No templates, easy to read, great for small tweaks | No packaging/sharing story, no release history, patching deep structures gets ugly |
| **Helm** | Templates + packaging + release history | Huge ecosystem (every major project ships a chart), rollback, values per environment | Go templates are fiddly; whitespace and quoting bite beginners |
| **Helmfile** | A file that lists many Helm releases and their values | Great for "install these 15 charts in order" | One more tool to learn |
| **Terraform Helm provider** | Install charts as Terraform resources | One workflow for cloud + cluster + apps, state, plans | Terraform's cluster-access chicken-and-egg problems (Part 13) |
| **Argo CD / Flux (GitOps)** | A controller in the cluster that continuously applies what's in Git (can render Helm charts) | Drift detection, audit trail, self-healing | Another system to run; Helm hooks and `lookup` behave differently |

In real teams these are combined: Terraform builds the cluster and installs a few "platform" charts, and Helm (directly or via Argo CD/Flux) installs the apps. Part 15 shows a layout that works.

---

<a id="part-4"></a>
## Part 4 — Anatomy of a chart

### `Chart.yaml` — the label on the recipe card

```yaml
apiVersion: v2                 # "v2" = Helm 3/4 chart format. Always v2.
name: school-app               # chart name (lowercase, dashes)
description: A generic web app chart for the school
type: application              # or "library" (a chart with only helpers, never installed alone)
version: 1.4.2                 # the CHART's version. Bump it whenever the chart changes.
appVersion: "2.0.1"            # the APP's version inside. Informational; often used as the default image tag.
kubeVersion: ">=1.30.0-0"      # refuse to install on old clusters
dependencies:                  # sub-charts this chart pulls in
  - name: cloudnative-pg
    version: "0.26.x"
    repository: https://cloudnative-pg.github.io/charts
    condition: cnpg.enabled    # only include if values say cnpg.enabled=true
```

⚠️ **Gotcha:** `version` and `appVersion` are different things. `version` is the chart (the recipe); `appVersion` is the software (the dish). Changing the container image tag is usually an `appVersion` bump *and* a chart `version` bump, because the chart's contents changed.

✅ **Best practice:** use semantic versioning for `version`: `MAJOR.MINOR.PATCH`. Breaking change to values → MAJOR; new optional value → MINOR; bug fix → PATCH.

### `values.yaml` — the fill-in-the-blanks

```yaml
replicaCount: 2

image:
  repository: ghcr.io/school/lunch-api
  tag: ""                 # empty = use Chart.appVersion
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 8080

resources:
  requests: { cpu: 250m, memory: 512Mi }
  limits:   { memory: 512Mi }        # ✅ memory limit = request; no CPU limit (see Part 6)

route:                    # Gateway API HTTPRoute (see Part 12); classic Ingress is also supported
  enabled: false
  host: ""

env: {}                   # plain settings → ConfigMap
existingSecret: ""        # name of a Secret you created outside Helm → env vars
```

Rules of the road:
- Only put things in `values.yaml` that someone might *reasonably change*. Everything else is hard-coded in templates.
- Every value should have a sensible default so `helm install` works with zero overrides.
- Document every value with a comment. Tools like `helm-docs` turn those comments into a README.

### `templates/` — Kubernetes YAML with blanks

A template is YAML with `{{ ... }}` holes. Helm fills the holes using the Go template language plus about 100 extra functions (from the "Sprig" library).

📝 A realistic `templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "school-app.fullname" . }}
  labels:
    {{- include "school-app.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "school-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        # If the ConfigMap changes, this hash changes, so pods restart. See Part 6.
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
      labels:
        {{- include "school-app.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "school-app.serviceAccountName" . }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: app
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          ports:
            - name: http
              containerPort: {{ .Values.service.port }}
          envFrom:
            - configMapRef:
                name: {{ include "school-app.fullname" . }}
            {{- with .Values.existingSecret }}
            - secretRef:
                name: {{ . }}
            {{- end }}
          livenessProbe:
            httpGet: { path: {{ .Values.probes.liveness.path }}, port: http }
          readinessProbe:
            httpGet: { path: {{ .Values.probes.readiness.path }}, port: http }
          startupProbe:
            httpGet: { path: {{ .Values.probes.liveness.path }}, port: http }
            failureThreshold: 30        # 30 × 10s = 5 minutes for slow JVMs to start
            periodSeconds: 10
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

The pieces you'll use constantly:

| Template piece | Meaning |
|---|---|
| `.Values.x.y` | A value from `values.yaml` (or an override) |
| `.Release.Name`, `.Release.Namespace` | The release name / namespace |
| `.Chart.Name`, `.Chart.Version`, `.Chart.AppVersion` | From `Chart.yaml` |
| `{{- ... -}}` | The dashes eat whitespace/newlines on that side. This is the #1 source of "why is my YAML broken" |
| `{{ include "name" . }}` | Call a named helper from `_helpers.tpl` and get its output as a string (prefer over `template`, because `include` can be piped) |
| `\| nindent 4` | Add a newline, then indent every line by 4 spaces. Use after `include`/`toYaml` |
| `\| toYaml` | Turn a values map/list into YAML |
| `\| default "x"` | Fallback if empty |
| `\| quote` | Wrap in double quotes (do this for env var values!) |
| `required "msg" .Values.x` | Fail the install with a message if the value is missing |
| `{{ if }} … {{ else }} … {{ end }}` | Conditionals. Note: `0`, `""`, `false`, empty list/map are all "false" |
| `{{ with .Values.thing }} … {{ end }}` | Run the block only if `thing` is set; inside, `.` means `thing` |
| `{{ range .Values.list }} … {{ end }}` | Loop |
| `tpl` | Render a string *from values* as a template (lets users put `{{ .Release.Name }}` in values) |
| `lookup "v1" "Secret" "ns" "name"` | Read a live object from the cluster (returns empty during `helm template` and `--dry-run=client`) |
| `sha256sum`, `b64enc`, `randAlphaNum 16`, `printf`, `trunc 63`, `trimSuffix "-"` | Everyday helpers |

### `_helpers.tpl` — reusable snippets

```yaml
{{/* Chart name, max 63 chars (Kubernetes label limit) */}}
{{- define "school-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* release-chart, unless the release already contains the chart name */}}
{{- define "school-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Standard labels every resource gets */}}
{{- define "school-app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "school-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Labels used to match pods. NEVER change these after first install (see Part 7). */}}
{{- define "school-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "school-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

### `values.schema.json` — the answer key

A JSON Schema next to `values.yaml`. Helm validates values against it on install/upgrade/lint. It turns "my typo silently did nothing" into a clear error.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["image"],
  "properties": {
    "replicaCount": { "type": "integer", "minimum": 0 },
    "image": {
      "type": "object",
      "required": ["repository"],
      "properties": {
        "repository": { "type": "string", "minLength": 1 },
        "tag": { "type": "string" },
        "pullPolicy": { "enum": ["Always", "IfNotPresent", "Never"] }
      }
    },
    "service": {
      "type": "object",
      "properties": { "port": { "type": "integer", "minimum": 1, "maximum": 65535 } }
    }
  }
}
```

### `crds/` — special folder for Custom Resource Definitions

Files in `crds/` are plain YAML (no templating). Helm installs them **once, before** the templates, and **never upgrades or deletes them**. That protects your data (deleting a CRD deletes every object of that kind!) but it means *you* must upgrade CRDs by hand when an operator's chart bumps them. See Part 7.

### `templates/NOTES.txt` — the note printed after install

```text
Your app is installed!
  kubectl port-forward -n {{ .Release.Namespace }} svc/{{ include "school-app.fullname" . }} 8080:{{ .Values.service.port }}
```

### `templates/tests/` — smoke tests

A Pod with the annotation `helm.sh/hook: test`. Run with `helm test <release>`. Great for "can the app reach the database?".

### Hooks — do something before/after

Any template with the annotation `helm.sh/hook: pre-install,pre-upgrade` (or `post-install`, `pre-delete`, `post-delete`, `post-rollback`, `test`) runs at that moment. Typical use: a Job that runs database migrations before the new version of the app starts.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "school-app.fullname" . }}-migrate
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "0"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
```

⚠️ Hook resources are **not** part of the release's normal lifecycle: `helm uninstall` won't delete them unless a delete policy says so, and GitOps tools treat hooks differently. Use `hook-delete-policy` always.

### Dependencies (sub-charts) and `Chart.lock`

```bash
helm dependency update ./my-chart     # downloads sub-charts into charts/ and writes Chart.lock
helm dependency build ./my-chart      # uses Chart.lock exactly (use this in CI)
```

Sub-chart values are nested under the sub-chart's name:

```yaml
# parent values.yaml
cloudnative-pg:
  replicaCount: 1
global:                    # "global" values are visible to every sub-chart
  imageRegistry: myregistry.azurecr.io
```

✅ Commit `Chart.lock` to Git, exactly like `package-lock.json` or `go.sum`.

### Library charts

`type: library` charts contain only helpers, never resources. One library chart (`school-common`) can hold the labels, security context, and probe snippets that all your app charts share. Part 12 uses this idea.

### Packaging and publishing (OCI is the modern way)

```bash
helm lint ./school-app                         # catch mistakes
helm package ./school-app                      # → school-app-1.4.2.tgz
helm registry login ghcr.io                    # Helm 4: domain only
helm push school-app-1.4.2.tgz oci://ghcr.io/school/charts
helm show values oci://ghcr.io/school/charts/school-app --version 1.4.2
helm install lunch oci://ghcr.io/school/charts/school-app --version 1.4.2
```

Classic HTTP repositories (`helm repo add …`) still exist and many projects use them, but OCI registries (the same place you keep container images) are where the ecosystem is heading — Strimzi, for example, deprecated its HTTP repo in favor of OCI.

✅ Sign charts and images (`cosign sign`, `helm package --sign`) and verify in CI. Supply-chain attacks on charts are real.

---

<a id="part-5"></a>
## Part 5 — Everyday commands (cheat sheet)

### Finding charts

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update                              # refresh the aisle catalogs (do this before searching!)
helm search repo cnpg                         # search repos you added
helm search repo cnpg/cluster --versions      # every version
helm search hub keycloak                      # search Artifact Hub (artifacthub.io) — the giant supermarket
helm show chart  cnpg/cluster                 # Chart.yaml
helm show values cnpg/cluster > cluster-defaults.yaml   # all defaults — read this before installing anything
helm show readme cnpg/cluster
helm pull cnpg/cluster --untar                # download & unpack so you can read the templates
```

### Installing and upgrading (the safe way)

```bash
# Install-or-upgrade (idempotent, perfect for CI), and:
#  --wait                 don't return until pods are Ready (needs list+watch RBAC in Helm 4)
#  --timeout 10m          how long to wait
#  --rollback-on-failure  if the upgrade fails, roll back automatically (was --atomic in Helm 3)
#  --version              pin the chart version. ALWAYS.
#  -f                     values files, in order; later files win
#  --set                  quick overrides; wins over -f
helm upgrade --install lunch-db cnpg/cluster \
  --version 0.3.1 \
  --namespace school --create-namespace \
  -f values/base.yaml -f values/dev.yaml \
  --set cluster.instances=1 \
  --wait --timeout 10m --rollback-on-failure
```

### Looking before you leap

```bash
helm template lunch ./school-app -f values/dev.yaml            # render locally; no cluster needed (lookup returns nothing)
helm template lunch ./school-app --debug                       # show values + rendered output, even when YAML is invalid
helm upgrade --install lunch ./school-app --dry-run=server     # render using the real cluster (lookup works), apply nothing
helm plugin install https://github.com/databus23/helm-diff     # then:
helm diff upgrade lunch ./school-app -f values/dev.yaml        # what WOULD change vs the running release
helm lint ./school-app --strict
```

✅ `helm diff` before every production upgrade. It's the single most valuable Helm plugin.

### Inspecting releases

```bash
helm list -A                          # all releases, all namespaces (status column!)
helm status lunch -n school
helm history lunch -n school
helm get values lunch -n school       # only overrides
helm get values lunch -n school --all # effective values
helm get manifest lunch -n school     # rendered YAML in the cluster
helm get hooks lunch -n school
helm get notes lunch -n school
helm get metadata lunch -n school     # chart + version + revision
```

### Undo, test, remove

```bash
helm rollback lunch 4 -n school --wait          # to revision 4
helm test lunch -n school                       # run test hooks
helm uninstall lunch -n school                  # deletes resources (except CRDs and PVCs from StatefulSets)
helm uninstall lunch -n school --keep-history   # keeps the release Secrets so you can `helm rollback` later
```

### Values precedence (lowest → highest)

1. Sub-chart `values.yaml`
2. Parent chart `values.yaml`
3. `-f first.yaml`
4. `-f second.yaml` (later `-f` wins)
5. `--set` / `--set-string` / `--set-file` / `--set-json` (last one wins)

Maps are **merged** key by key. Lists are **replaced** whole. This surprises everyone once (Part 7).

### Environment variables Helm respects

| Variable | Use |
|---|---|
| `HELM_NAMESPACE` | Default namespace |
| `KUBECONFIG`, `HELM_KUBECONTEXT` | Which cluster |
| `HELM_REGISTRY_CONFIG`, `HELM_REPOSITORY_CACHE` | Where login and cache live (set in CI to a writable path) |
| `HELM_DEBUG=1` | Verbose |
| `HELM_PLUGINS` | Plugin directory |

---

<a id="part-6"></a>
## Part 6 — Best practices

Each rule below has a *why*, a *how*, and a kid-level picture.

### 6.1 Pin every version. Never `latest`.

🛒 A meal kit with no date on the box: you don't know if it's fresh, and two kids grabbing "the latest one" get different boxes. In Kubernetes, `image: nginx` (which means `nginx:latest`) can change under you between two node restarts — and two pods of the *same* Deployment can run different code.

```bash
helm install ... --version 1.4.2                # chart version pinned
```
```yaml
image:
  repository: ghcr.io/school/lunch-api
  tag: "2.0.1"                                  # or better, a digest:
  # tag: "2.0.1@sha256:9f3c…"
```

Also pin: the Terraform provider version, the module version, the Kubernetes version of your cloud cluster, and the Helm CLI version in CI.

### 6.2 One values file per environment, layered

```text
values/
  base.yaml     # shared settings
  dev.yaml      # 1 replica, small resources, debug logging
  prod.yaml     # 3 replicas, real hostnames, no debug
```

```bash
helm upgrade --install lunch ./school-app -f values/base.yaml -f values/prod.yaml
```

🏫 The lesson plan is the same; the *class list* differs per period.

### 6.3 Never put real secrets in values files in Git

Values become a Helm Secret in the cluster *and* sit in your Git history forever. Options, best first:

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **External Secrets Operator (ESO)** | A CRD `ExternalSecret` pulls from Azure Key Vault / AWS Secrets Manager / GCP Secret Manager / Vault and creates a Kubernetes Secret | Secrets live in a real vault; rotation works; cloud-native identity | One more operator |
| **Secrets Store CSI Driver** | Mounts vault secrets as files (optionally syncs to a Secret) | Native to all three clouds | Per-pod config, more moving parts |
| **SOPS + age/KMS (helm-secrets plugin)** | Values files are encrypted in Git; decrypted at install time | Works anywhere, Git remains the source of truth | Keys to manage; CI needs decryption rights |
| **Sealed Secrets** | Encrypt with the cluster's public key; the controller decrypts | Simple, GitOps-friendly | Tied to one cluster's key |
| `--set password=…` from CI variables | Quick | Quick | Lands in the release Secret and shell history; avoid for real systems |

In your chart, reference secrets by name (`existingSecret`) and let something else create them:

```yaml
envFrom:
  - secretRef:
      name: {{ .Values.existingSecret | required "existingSecret is required" }}
```

### 6.4 Always set resource requests; set memory limit = request; avoid CPU limits

🏫 Every class needs a room big enough (request). Memory is like the room: if a class overflows, it must be moved (the pod is killed — OOMKilled). CPU is like teacher attention: it can be shared, and a hard cap just makes kids wait even when the teacher is free (CPU throttling). Most teams today set memory request = limit ("Guaranteed"-ish) and *no* CPU limit, except in strict multi-tenant clusters.

```yaml
resources:
  requests: { cpu: 500m, memory: 1Gi }
  limits:   { memory: 1Gi }
```

For JVM apps, tell the JVM about the box (Part 12): `-XX:MaxRAMPercentage=75.0`.

### 6.5 Probes: startup → readiness → liveness

- **startupProbe**: "still setting up?" Protects slow starters (JVM, Keycloak) from being killed by liveness.
- **readinessProbe**: "ready for traffic?" Failing = removed from the Service, *not* killed. Use for "DB connection lost".
- **livenessProbe**: "stuck?" Failing = restart. Keep it cheap and independent of downstream systems — never make liveness check the database, or one DB hiccup restarts your whole fleet.

### 6.6 Restart pods when config changes (checksum annotation)

Changing a ConfigMap doesn't restart pods that already read it. The standard trick (in the Deployment template above):

```yaml
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

The pod template changes → Kubernetes rolls the pods.

### 6.7 Security defaults in every chart

```yaml
securityContext:               # pod level
  runAsNonRoot: true
  runAsUser: 10001
  fsGroup: 10001
  seccompProfile: { type: RuntimeDefault }
containers:
  - securityContext:           # container level
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"] }
```

This satisfies the Kubernetes **Pod Security Standard "restricted"**, which many clusters (and GKE Autopilot) enforce. Add an `emptyDir` volume at `/tmp` when the root filesystem is read-only.

### 6.8 Use `helm upgrade --install --wait --timeout --rollback-on-failure` in CI

Idempotent, waits for health, undoes failures. Combine with `helm diff` in the pull request.

### 6.9 Namespaces: one per app or team; label them

```bash
kubectl create namespace school
kubectl label namespace school pod-security.kubernetes.io/enforce=restricted
```

`--create-namespace` is fine for dev; in prod let Terraform (or a namespace chart) own namespaces so labels, quotas and network policies are managed too.

### 6.10 Lint, test, and validate in CI

```bash
helm lint ./school-app --strict
helm template ./school-app | kubeconform -strict -summary        # validate against Kubernetes schemas
ct lint --config ct.yaml                                          # chart-testing (from the Helm project)
helm unittest ./school-app                                        # unit tests for templates (plugin)
```

### 6.11 Prefer operators for stateful things (databases, Kafka, Keycloak)

🏫 You *could* run the band program yourself from the principal's office. But a band director (operator) knows how to tune instruments, schedule rehearsals, replace broken strings and run the spring concert. Operators handle backups, failover, rolling upgrades, certificate rotation, and scaling for you. In 2026 the standard picks are:

| Need | Operator | Installed by |
|---|---|---|
| PostgreSQL | **CloudNativePG (CNPG)** | Helm chart `cnpg/cloudnative-pg` |
| Kafka | **Strimzi** | Helm chart `oci://quay.io/strimzi-helm/strimzi-kafka-operator` |
| Keycloak | **Keycloak Operator** (official) | Kubernetes manifests (wrap in a chart, or apply with Terraform) |
| TLS certificates | **cert-manager** | Helm chart `jetstack/cert-manager` |
| Secrets from vaults | **External Secrets Operator** | Helm chart `external-secrets/external-secrets` |

Bitnami's "everything in one chart" approach was the classic beginner path, but in August 2025 Bitnami moved its versioned images to a frozen `bitnamilegacy` repository, kept only `latest`-tagged development images in the free tier, and moved production images to the paid **Bitnami Secure Images** program. The chart source is still open on GitHub, but a Bitnami chart you install today may fail to pull its images unless you subscribe or override every image repository. That's why this tutorial uses operators and official images instead.

### 6.12 Treat CRDs as a separate, careful step

Install/upgrade operator CRDs explicitly (most operators publish a `crds` chart or a raw URL), then the operator, then your custom resources. Never let a `helm uninstall` of an operator delete CRDs — it would delete every database/Kafka cluster object with them.

### 6.13 Keep charts boring

- Don't template things that don't need to vary.
- Don't build a "mega chart" that installs Postgres + Kafka + Keycloak + apps as sub-charts. Upgrades become all-or-nothing and CRD ordering breaks. Use one release per component and a tool (Terraform, Helmfile, Argo CD) to order them.
- Name resources with `fullname`, so two releases of the same chart can coexist.
- Use standard labels (`app.kubernetes.io/name`, `instance`, `version`, `component`, `part-of`, `managed-by`).

### 6.14 Write down the upgrade path

For every chart you publish, keep a `CHANGELOG.md` and, for breaking changes, an "Upgrading" section in the README with the exact `helm upgrade` commands and any manual CRD steps.

---

<a id="part-7"></a>
## Part 7 — Gotchas (the big list)

Each one: **what you see → why → fix**.

### 7.1 "Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress"

**Why:** a previous `helm upgrade` was interrupted (CI job cancelled, laptop closed), leaving the release in `pending-upgrade`/`pending-install` status.
**Fix:**

```bash
helm history lunch -n school                        # find the last good revision
helm rollback lunch <good-revision> -n school       # clears the pending state
# If the release was never successfully installed:
helm uninstall lunch -n school                      # or delete the stuck secret: kubectl delete secret sh.helm.release.v1.lunch.v3 -n school
```

### 7.2 "has no deployed releases"

**Why:** the first install failed and the release is in `failed` status; `helm upgrade` refuses because there's nothing to upgrade from.
**Fix:** `helm uninstall` then install again, or `helm upgrade --install --force-replace` is *not* the answer here — clean up first.

### 7.3 Lists in values are replaced, not merged

```yaml
# base.yaml
env:
  - { name: LOG_LEVEL, value: info }
  - { name: REGION,    value: east }
# prod.yaml
env:
  - { name: LOG_LEVEL, value: warn }      # REGION is now GONE
```

**Fix:** model such settings as maps (`env: { LOG_LEVEL: info, REGION: east }`) and turn them into a list in the template with `range`.

### 7.4 `--set` turns your value into the wrong type

`--set port=8080` → integer. `--set version=1.20` → float `1.2`! `--set tag=1e3` → `1000`. `--set enabled=true` → boolean (not the string "true"). Commas split lists: `--set hosts=a.com,b.com`.
**Fix:** `--set-string version=1.20`, escape commas `\,`, or use a values file. In templates, `| quote` env var values.

### 7.5 Whitespace and `nindent`

```yaml
# WRONG: indent doesn't add the leading newline, so the first line lands on the "labels:" line
labels:
  {{ include "x.labels" . | indent 4 }}
# RIGHT
labels:
  {{- include "x.labels" . | nindent 4 }}
```

The `{{-` eats the preceding newline+spaces; `nindent` adds a fresh newline and indents *every* line. When in doubt, run `helm template … --debug` and read the output.

### 7.6 Changing selector labels breaks upgrades

`spec.selector` on Deployments/StatefulSets is immutable. If a new chart version changes `selectorLabels`, upgrade fails with "field is immutable".
**Fix:** never change selector labels once shipped; if you must, it's a delete-and-reinstall (or a new release name) — document it as a MAJOR version bump.

### 7.7 StatefulSet fields are immutable too

`volumeClaimTemplates` (disk size, storage class), `serviceName`, `podManagementPolicy` cannot be changed. Growing a database disk means editing the PVC directly (if the StorageClass allows `allowVolumeExpansion: true`), *then* updating the chart value, *then* `helm upgrade` … which still fails on the StatefulSet. Operators (CNPG, Strimzi) solve this properly by managing PVCs themselves — one more reason to use them.

### 7.8 `helm uninstall` does not delete PVCs from StatefulSets or CRDs

That's deliberate (your data!). Check with `kubectl get pvc -n school` and delete on purpose.

### 7.9 CRDs are installed once and never upgraded by Helm

Symptom: you upgraded the Strimzi/CNPG chart, but the new field you're trying to use gives "unknown field".
**Fix:** upgrade CRDs explicitly before the chart. Each operator documents how; e.g. CNPG and Strimzi ship CRDs in the chart's `crds/` folder, so:

```bash
helm pull cnpg/cloudnative-pg --version <new> --untar
kubectl apply --server-side -f cloudnative-pg/crds/          # server-side apply handles big CRDs
helm upgrade cnpg cnpg/cloudnative-pg --version <new> -n cnpg-system
```

### 7.10 Random passwords regenerate on every upgrade

Charts that do `{{ randAlphaNum 16 }}` create a new password every render → the Secret changes → the app can't log in to a database that still has the old password. Good charts use `lookup` to reuse the existing Secret, or require `existingSecret`. When you write charts: **never generate secrets in templates**; create them once (ESO, Terraform `random_password`, or a one-time Job).

### 7.11 `helm template` ≠ what the cluster gets

`helm template` has no cluster: `lookup` returns empty, `.Capabilities.APIVersions` is a guess, and hooks are rendered inline. Use `--dry-run=server` when you need cluster-aware rendering, and `--api-versions` / `--kube-version` flags for offline rendering that mimics a specific cluster.

### 7.12 Three-way merge surprises: manual `kubectl edit` changes survive until Helm touches that field

Helm compares old manifest, new manifest and live object. A field you hand-edited that the chart never sets stays as you set it. A field the chart *does* set is overwritten on the next upgrade. With Helm 4's server-side apply, Kubernetes also records field ownership, and conflicts surface as errors rather than silent overwrites — use `--force-conflicts` only when you understand who owned the field.

### 7.13 `--force-replace` (was `--force`) deletes and recreates resources

That's a delete of the Service (IP changes), of the StatefulSet, potentially of PVC-owning objects. Treat it as a last resort, never in a CI default.

### 7.14 Release Secret too big (>1 MiB)

Usually a chart that puts huge CRDs in `templates/`. Move them to `crds/` or a separate chart.

### 7.15 `--reuse-values` vs `--reset-values`

`helm upgrade` by default reuses *nothing* from the previous revision except what's in the chart defaults + what you pass now. If you passed `--set x=1` last time and don't pass it now, `x` reverts to the chart default. `--reuse-values` keeps last time's overrides (but silently ignores new chart defaults — dangerous across chart versions). ✅ Always pass the complete set of values files every time; don't rely on either flag.

### 7.16 `helm repo update` isn't automatic

"Version 0.30.0 not found" even though it was released yesterday → your local index is stale. `helm repo update` first. OCI registries don't have this problem.

### 7.17 Image pull errors after install (`ImagePullBackOff`)

Private registry without `imagePullSecrets`; wrong architecture (arm64 Mac building images for amd64 nodes — see Part 8); or a Bitnami chart pointing at images that moved to `bitnamilegacy`. `kubectl describe pod` shows the exact reason.

### 7.18 `--wait` hangs forever

A pod never becomes Ready (probe misconfigured, resources too small for the node, PVC Pending because no StorageClass). `--wait` only reports success when *everything* is Ready. Look at `kubectl get events -n <ns> --sort-by=.lastTimestamp` while it waits. In Helm 4, also check RBAC: `--wait` now needs `watch`.

### 7.19 Hooks run but the release "succeeds" even when the app is broken

A `post-install` Job that fails *does* fail the release — but `helm uninstall` doesn't clean up hook Jobs without `hook-delete-policy`, so the next install fails with "already exists". Always set `helm.sh/hook-delete-policy: before-hook-creation`.

### 7.20 The release name is inside every resource name — long names get truncated

Release + chart name > 63 chars → `fullname` truncates, sometimes producing duplicates. Keep release names short (`lunch`, not `school-lunch-api-production-v2`).

### 7.21 Rollback does not roll back CRDs, PVC data, or database schemas

Helm rollback restores Kubernetes objects, not the data your migration Job changed. Plan migrations to be backward-compatible with the previous app version (expand → migrate → contract).

### 7.22 Namespace of the release vs namespace in templates

Hard-coding `namespace: school` inside a template breaks when someone installs with `-n other`. Use `{{ .Release.Namespace }}` or omit the field.

### 7.23 Chart works in Docker Desktop, fails in the cloud

Usually: no default StorageClass on the cloud (EKS needs the EBS CSI add-on with an IAM role), Pod Security "restricted" enforced (GKE Autopilot), `LoadBalancer` Service needs cloud annotations, or the gateway/ingress class differs per cloud (`eg` for Envoy Gateway, `gke-l7-global-external-managed` on GKE, `azure-alb-external` for Application Gateway for Containers, `alb` on EKS). Part 14 lists these per cloud.

---

<a id="part-8"></a>
## Part 8 — Docker and Podman: building and running images

Helm deploys **images**; something has to build them. Docker and Podman both do, and they both run local Kubernetes for you to test on.

🛒 The container engine is the **kitchen** where meal kits (images) get assembled and sealed. Kubernetes is the store that stocks and serves them. Helm is the recipe binder the store follows.

### Docker vs Podman

| | Docker | Podman |
|---|---|---|
| Architecture | A background daemon (`dockerd`) running as root does everything | No daemon; each command is a normal process, rootless by default |
| CLI | `docker …` | `podman …` (deliberately identical: `alias docker=podman` mostly works) |
| Mac/Windows | Docker Desktop (paid for larger companies) | Podman Desktop (free, open source) + `podman machine` VM |
| Compose | `docker compose` (built in) | `podman compose` (wraps docker-compose or podman-compose) |
| Pods | No | Yes — `podman pod` and `podman kube play deployment.yaml` runs Kubernetes YAML locally |
| kind / minikube | First-class | kind: `KIND_EXPERIMENTAL_PROVIDER=podman`; minikube: `--driver=podman` |
| Image format | OCI | OCI (identical; images are interchangeable) |
| Best for | Maximum tool compatibility | Security-conscious setups, Linux servers, RHEL/Fedora shops, CI without a root daemon |

Pick either. Everything in this tutorial works with both; where a command differs, both are shown.

### Building an image

```bash
docker build -t ghcr.io/school/lunch-api:2.0.1 .
podman build -t ghcr.io/school/lunch-api:2.0.1 .
```

### Multi-architecture images (the Apple-Silicon trap)

⚠️ A laptop with an Apple M-series or other arm64 chip builds **arm64** images by default. Most cloud nodes are **amd64**. The pod starts, then dies with `exec format error`. Build for both:

```bash
# Docker (buildx)
docker buildx create --use --name multi   # once
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/school/lunch-api:2.0.1 --push .

# Podman
podman build --platform linux/amd64,linux/arm64 --manifest ghcr.io/school/lunch-api:2.0.1 .
podman manifest push --all ghcr.io/school/lunch-api:2.0.1
```

### Getting a local image into kind (no registry needed)

```bash
# Docker
kind load docker-image ghcr.io/school/lunch-api:2.0.1 --name school
# Podman
podman save -o lunch-api.tar ghcr.io/school/lunch-api:2.0.1
kind load image-archive lunch-api.tar --name school
```

Then in values: `image.pullPolicy: IfNotPresent` (with `Always`, kubelet tries the registry and fails).

For frequent rebuilds, run a local registry next to kind (the kind docs ship a script: "Local Registry") and push to `localhost:5001/lunch-api:dev`.

### Dockerfile rules that save you later

1. Multi-stage builds: build in a fat image, run in a slim one.
2. Run as a non-root user (`USER 10001`).
3. Pin base images by tag *and* digest in production.
4. `.dockerignore` (`.git`, `node_modules`, `target/`, `*.md`).
5. Order layers from least- to most-frequently changed (dependencies before source code) so rebuilds are fast.
6. Expose only what you need; add a `HEALTHCHECK` only for Compose (Kubernetes uses probes instead).

### Local cluster options

| Tool | What it is | Pros | Cons |
|---|---|---|---|
| **kind** | Kubernetes nodes as containers | Fast, multi-node, exactly upstream Kubernetes, great for CI | No built-in LoadBalancer (use `kubectl port-forward`, or the cloud-provider-kind helper) |
| **minikube** | One VM or container | Add-ons (`ingress`, `metrics-server`) with one command | Slower, single node by default |
| **k3d** | k3s in containers | Tiny and quick, has a built-in load balancer | k3s differs slightly from upstream (Traefik by default) |
| **Docker Desktop / Podman Desktop Kubernetes** | Built-in cluster | Zero setup | Single node, hard to reset selectively |

### A note on Compose

Docker/Podman Compose is fine for running Postgres + Keycloak + Kafka on your laptop for app development. But Compose files are not Helm charts and don't translate automatically (tools like `kompose` produce a rough draft at best). This tutorial goes straight to Helm so dev and prod use the same recipe.

---

<a id="part-9"></a>
## Part 9 — Postgres with CloudNativePG

🏫 Postgres is the school's **record cabinet**: grades, attendance, lunch balances. It must never lose data, must survive a fire (backups off-site), and must keep working while the cabinet is being replaced (failover).

### Options for running Postgres on Kubernetes

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Managed cloud DB** (Azure Database for PostgreSQL, Amazon RDS/Aurora, Cloud SQL) | Someone else does backups/HA/patches | Costs more, lives outside the cluster (network setup), slower to spin up in dev | Great for production if budget allows |
| **CloudNativePG operator** | CNCF project, Postgres-native replication, automatic failover, backups to object storage, `kubectl cnpg` plugin, PodMonitor for Prometheus | You run it | **Recommended in-cluster choice** |
| Other operators (Crunchy PGO, Zalando, StackGres, Percona) | Mature, feature-rich | Different licensing/model per project | Fine; CNPG has the most momentum |
| **Bitnami postgresql chart** | Easy first install (historically) | Images now legacy/paid (see 6.11); StatefulSet-based, weaker failover | Not for new setups |
| Plain StatefulSet you write yourself | Full control, zero dependencies | You write failover, backups, upgrades… | Learning only |

### Step 1: install the operator (one per cluster)

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm search repo cnpg/cloudnative-pg --versions | head -3      # pick the current version
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version <chart-version> \
  --namespace cnpg-system --create-namespace \
  --wait --rollback-on-failure
kubectl get pods -n cnpg-system                                   # cnpg-cloudnative-pg-…  Running
kubectl get crd | grep cnpg                                       # clusters, backups, scheduledbackups, poolers…
```

Optional but handy: `kubectl krew install cnpg` → `kubectl cnpg status keycloak-db -n school`.

### Step 2: describe your database as a `Cluster` (inside your own small chart)

You *can* install CNPG's `cnpg/cluster` helper chart, but writing a tiny wrapper chart of your own is the pattern you'll reuse for Keycloak and Kafka, so let's do that. Create `charts/school-postgres/`:

```text
charts/school-postgres/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── cluster.yaml
    └── scheduledbackup.yaml
```

📝 `Chart.yaml`

```yaml
apiVersion: v2
name: school-postgres
description: A CloudNativePG cluster with sane defaults
type: application
version: 0.1.0
appVersion: "17"
```

📝 `values.yaml`

```yaml
name: keycloak-db
instances: 3                # 1 in dev
storage:
  size: 20Gi
  storageClass: ""          # "" = cluster default; e.g. managed-csi (AKS), gp3 (EKS), standard-rwo (GKE)
database: keycloak
owner: keycloak
resources:
  requests: { cpu: 500m, memory: 1Gi }
  limits:   { memory: 1Gi }
parameters:
  max_connections: "200"
  shared_buffers: "256MB"
  wal_level: logical         # lets Debezium (Part 11) stream changes
backups:
  enabled: false
  objectStoreName: school-backups   # an ObjectStore resource created by the barman-cloud plugin
  schedule: "0 0 2 * * *"           # CNPG cron has SIX fields (seconds first): 02:00 every night
monitoring: true
```

📝 `templates/cluster.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ .Values.name }}
  labels:
    {{- include "school-postgres.labels" . | nindent 4 }}
spec:
  instances: {{ .Values.instances }}
  storage:
    size: {{ .Values.storage.size }}
    {{- with .Values.storage.storageClass }}
    storageClass: {{ . }}
    {{- end }}
  bootstrap:
    initdb:
      database: {{ .Values.database }}
      owner: {{ .Values.owner }}
  postgresql:
    parameters:
      {{- toYaml .Values.parameters | nindent 6 }}
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  affinity:
    enablePodAntiAffinity: true       # spread replicas over different nodes
    topologyKey: kubernetes.io/hostname
  monitoring:
    enablePodMonitor: {{ .Values.monitoring }}
  {{- if .Values.backups.enabled }}
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: {{ .Values.backups.objectStoreName }}
  {{- end }}
```

📝 `templates/scheduledbackup.yaml`

```yaml
{{- if .Values.backups.enabled }}
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: {{ .Values.name }}-nightly
spec:
  schedule: {{ .Values.backups.schedule | quote }}
  backupOwnerReference: self
  immediate: true
  cluster:
    name: {{ .Values.name }}
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
{{- end }}
```

(Add a `_helpers.tpl` with a `school-postgres.labels` helper like Part 4.)

Install it:

```bash
helm upgrade --install keycloak-db ./charts/school-postgres -n school --create-namespace \
  --set instances=1                       # dev laptop
kubectl get cluster -n school             # keycloak-db  1 instance  "Cluster in healthy state"
kubectl get pods -n school                # keycloak-db-1  Running
```

### What CNPG created for you

| Object | Purpose |
|---|---|
| Pods `keycloak-db-1`, `-2`, `-3` | Primary + streaming replicas (CNPG manages them directly, not via StatefulSet, so it can grow disks and replace nodes) |
| Service `keycloak-db-rw` | Always points at the **primary**. Apps that write use this |
| Service `keycloak-db-ro` | Replicas only (read scaling) |
| Service `keycloak-db-r` | Any instance |
| Secret `keycloak-db-app` | Keys `username`, `password`, `dbname`, `host`, `port`, `uri`, `jdbc-uri` — exactly what Keycloak and your apps need |
| PVCs `keycloak-db-1` … | The data. Survive pod deletion and `helm uninstall` |

Connect and try it:

```bash
kubectl cnpg psql keycloak-db -n school            # with the plugin, or:
kubectl exec -it -n school keycloak-db-1 -- psql -U postgres -c '\l'
```

### Backups to object storage (the fire drill)

CNPG backs up to S3, Azure Blob, or GCS through the **Barman Cloud plugin** (the built-in `barmanObjectStore` field is deprecated since CNPG 1.26 in favor of the plugin). The shape:

1. Install the plugin (its own manifests, from the `cloudnative-pg/plugin-barman-cloud` project).
2. Create an `ObjectStore` (`barmancloud.cnpg.io/v1`) pointing at your bucket with credentials from a Secret (or workload identity — no keys at all on AKS/EKS/GKE; see Part 14).
3. Set `backups.enabled=true` in the chart above.

Test a restore at least once ("bootstrap from backup" into a new `Cluster` named `keycloak-db-restore`). A backup you've never restored is a rumor, not a backup.

### Pros/cons of the wrapper-chart approach

- ✅ Values are yours; environment files stay tiny (`instances`, `storage.size`, `storageClass`).
- ✅ The same chart makes `keycloak-db`, `grades-db`, `lunch-db`.
- ⚠️ You must track CNPG API changes yourself (read CNPG release notes on upgrade).

### Postgres gotchas

- ⚠️ **PVC Pending forever** → no default StorageClass (EKS without the EBS CSI add-on is the classic). `kubectl get storageclass`.
- ⚠️ **`instances: 3` on a one-node kind cluster** works (anti-affinity is "preferred"), but on clouds with 2 nodes the third replica may wait for a node. Set `instances: 1` in dev.
- ⚠️ **Changing `bootstrap.initdb` after creation does nothing** — bootstrap runs once. New databases/users: create them with SQL (or a `Database` resource in newer CNPG) rather than editing initdb.
- ⚠️ **Major version upgrades** (17 → 18) are not a `helm upgrade`; follow CNPG's major-upgrade procedure (in-place major upgrades exist since CNPG 1.26, but read the docs and take a backup first).
- ⚠️ **Connection limits**: JVM apps with big pools × replicas can exhaust `max_connections`. Use a CNPG `Pooler` (PgBouncer) in front of `-rw` for many small apps.
- ⚠️ **Resource limits on databases**: memory limit = request, and no CPU limit — a throttled database makes everything slow.

---

<a id="part-10"></a>
## Part 10 — Keycloak (login and single sign-on)

🏫 Keycloak is the **front office**. Students and teachers show their ID once; the office hands out a **hall pass** (a token) that says who you are and what you're allowed to do. Every classroom (app) checks the hall pass instead of re-checking your ID. **OIDC (OpenID Connect)** is the standard *format* of the hall pass, so classrooms built by different companies (Java, Python, Go) can all read it.

Words you'll meet:

| Word | Meaning | 🏫 |
|---|---|---|
| **Realm** | A separate world of users, roles and apps | One school (Lincoln Middle vs Washington Middle) |
| **Client** | An app registered with Keycloak | A classroom that accepts hall passes |
| **User / Role / Group** | Who, and what they may do | Student, teacher, "7th-grade band" |
| **Access token (JWT)** | A signed, short-lived pass with claims (`sub`, `realm_access.roles`, `exp`) | The hall pass |
| **Issuer (`iss`)** | The exact URL of the realm that signed the pass | The school's stamp on the pass |
| **JWKS** | The public keys apps use to check the signature | The sample of the stamp every classroom has |
| **Authorization Code + PKCE** | How a browser app logs a human in | A student goes to the office in person |
| **Client credentials** | How a backend service gets its own token | A staff member's badge, no human involved |

### Options for running Keycloak on Kubernetes

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Official Keycloak Operator** (`k8s.keycloak.org`) | Maintained by the Keycloak team; `Keycloak` and `KeycloakRealmImport` CRDs; handles clustering, TLS, DB config, rolling upgrades | Ships as raw manifests (no official Helm chart) — you wrap them or apply with kubectl/Terraform | **Recommended** |
| **codecentric `keycloakx` chart** | Pure Helm, uses the official `quay.io/keycloak/keycloak` image, community-maintained | You configure clustering/DB yourself via env vars | Good if you want "just a chart" |
| **Bitnami keycloak chart** | Bundled Postgres option | Image/legacy issues (6.11) | Avoid for new setups |
| **Managed identity providers** (Entra ID, Cognito, Auth0, Okta) | Nothing to run | Different features, cost per user, lock-in | Consider for production if you don't need Keycloak specifics |

### Step 1: install the operator

The operator is published as plain YAML per Keycloak version. Pick the current version from `https://github.com/keycloak/keycloak-k8s-resources/releases`:

```bash
export KC_VERSION=26.7.4          # ← replace with the latest release (26.7.4 as of Sept 2026)
kubectl create namespace keycloak
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KC_VERSION}/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KC_VERSION}/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
kubectl -n keycloak apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KC_VERSION}/kubernetes/kubernetes.yml
kubectl get pods -n keycloak      # keycloak-operator-…  Running
```

⚠️ The operator watches **only the namespace it's installed in**. Put your `Keycloak` resource in that same namespace (we use `keycloak`).

*Want it in Helm anyway?* Make a wrapper chart: put the two CRD files in `crds/`, `kubernetes.yml` in `templates/` (replace the hard-coded `namespace: keycloak` with `{{ .Release.Namespace }}`), and version the chart to match `KC_VERSION`. Part 13 shows the Terraform way (`kubernetes_manifest` / `kubectl_manifest`).

### Step 2: a database for Keycloak

Use the chart from Part 9, in the `keycloak` namespace so the Secret is next to Keycloak:

```bash
helm upgrade --install keycloak-db ./charts/school-postgres -n keycloak \
  --set name=keycloak-db --set database=keycloak --set owner=keycloak --set instances=1
```

### Step 3: the `school-keycloak` chart

```text
charts/school-keycloak/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── keycloak.yaml
    ├── httproute.yaml
    └── realm-import.yaml
```

📝 `values.yaml`

```yaml
name: school-keycloak
apiVersion: k8s.keycloak.org/v2beta1        # operators older than ~26.5 only serve v2alpha1 — check:
                                             #   kubectl get crd keycloaks.k8s.keycloak.org -o jsonpath='{.spec.versions[*].name}'
instances: 2
hostname: https://auth.school.example.com    # the PUBLIC URL users see; Keycloak 25+ accepts a full URL
db:
  host: keycloak-db-rw
  port: 5432
  database: keycloak
  secretName: keycloak-db-app                # created by CNPG: keys username/password
bootstrapAdminSecret: keycloak-bootstrap-admin   # create it once: kubectl create secret generic … --from-literal=username=admin --from-literal=password=…
resources:
  requests: { cpu: 500m, memory: 1Gi }
  limits:   { memory: 1536Mi }
route:                                        # Gateway API (the replacement for Ingress; see Part 15 for the gateway itself)
  enabled: true
  host: auth.school.example.com
  gatewayName: school
  gatewayNamespace: gateways
realm:
  enabled: true
  name: school
  displayName: Lincoln Middle School
  devMode: false                  # true = allow password grant for curl testing
```

📝 `templates/keycloak.yaml`

```yaml
apiVersion: {{ .Values.apiVersion }}
kind: Keycloak
metadata:
  name: {{ .Values.name }}
spec:
  instances: {{ .Values.instances }}
  db:
    vendor: postgres
    host: {{ .Values.db.host }}
    port: {{ .Values.db.port }}
    database: {{ .Values.db.database }}
    usernameSecret: { name: {{ .Values.db.secretName }}, key: username }
    passwordSecret: { name: {{ .Values.db.secretName }}, key: password }
  hostname:
    hostname: {{ .Values.hostname }}
  http:
    httpEnabled: true            # TLS ends at the Ingress; pod speaks plain HTTP inside the cluster
  proxy:
    headers: xforwarded          # trust X-Forwarded-* from the Ingress so redirect URLs are https
  ingress:
    enabled: false               # we route traffic with our own HTTPRoute below
  bootstrapAdmin:
    user:
      secret: {{ .Values.bootstrapAdminSecret }}
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  additionalOptions:
    - name: health-enabled
      value: "true"
    - name: metrics-enabled
      value: "true"
```

📝 `templates/httproute.yaml`

```yaml
{{- if .Values.route.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .Values.name }}
spec:
  parentRefs:
    - name: {{ .Values.route.gatewayName }}          # the shared Gateway (Part 15) terminates TLS
      namespace: {{ .Values.route.gatewayNamespace }}
      sectionName: https-{{ .Values.route.host | replace "." "-" }}   # attach ONLY to this host's HTTPS listener
  hostnames: [{{ .Values.route.host | quote }}]
  rules:
    - backendRefs:
        - name: {{ .Values.name }}-service           # the operator names the Service <name>-service
          port: 8080
{{- end }}
```

*Still on classic Ingress?* Swap this file for an `Ingress` with `ingressClassName` set to whatever controller your cluster runs. But don't install **ingress-nginx** for anything new: the Kubernetes project retired it in March 2026 (no more releases or security fixes). Gateway API is the official successor.

📝 `templates/realm-import.yaml` — the whole school in one file

```yaml
{{- if .Values.realm.enabled }}
apiVersion: {{ .Values.apiVersion }}
kind: KeycloakRealmImport
metadata:
  name: {{ .Values.realm.name }}
spec:
  keycloakCRName: {{ .Values.name }}
  placeholders:                                  # secrets are read from Kubernetes Secrets, never from values
    REPORT_BOT_SECRET:
      secret: { name: report-bot-client, key: secret }
  realm:
    id: {{ .Values.realm.name }}
    realm: {{ .Values.realm.name }}
    displayName: {{ .Values.realm.displayName | quote }}
    enabled: true
    sslRequired: external
    roles:
      realm:
        - { name: teacher, description: Can post grades }
        - { name: student, description: Can read own grades }
    clients:
      # 1) The Java API. It only VALIDATES tokens; it never logs anyone in.
      - clientId: lunch-api
        enabled: true
        protocol: openid-connect
        publicClient: false
        standardFlowEnabled: false
        directAccessGrantsEnabled: false
        serviceAccountsEnabled: false
      # 2) The browser front end. Logs humans in with Authorization Code + PKCE.
      - clientId: school-portal
        enabled: true
        protocol: openid-connect
        publicClient: true
        standardFlowEnabled: true
        directAccessGrantsEnabled: {{ .Values.realm.devMode }}
        redirectUris: ["https://portal.school.example.com/*", "http://localhost:3000/*"]
        webOrigins: ["+"]
        attributes: { "pkce.code.challenge.method": "S256", "post.logout.redirect.uris": "+" }
        defaultClientScopes: [openid, profile, email, roles, lunch-api-audience]
      # 3) The Go reporting job. Machine-to-machine (client credentials).
      - clientId: report-bot
        enabled: true
        protocol: openid-connect
        publicClient: false
        serviceAccountsEnabled: true
        standardFlowEnabled: false
        secret: "$(REPORT_BOT_SECRET)"
        defaultClientScopes: [roles, lunch-api-audience]
    clientScopes:
      # Adds "aud": "lunch-api" to tokens so the API can require it
      - name: lunch-api-audience
        protocol: openid-connect
        protocolMappers:
          - name: lunch-api-audience
            protocol: openid-connect
            protocolMapper: oidc-audience-mapper
            config: { included.client.audience: lunch-api, access.token.claim: "true" }
    users:
      - username: ms.rivera
        enabled: true
        firstName: Ana
        lastName: Rivera
        email: rivera@school.example.com
        emailVerified: true
        realmRoles: [teacher]
        credentials: [{ type: password, value: change-me-on-first-login, temporary: true }]
      - username: sam.student
        enabled: true
        firstName: Sam
        lastName: Student
        realmRoles: [student]
        credentials: [{ type: password, value: change-me-on-first-login, temporary: true }]
{{- end }}
```

Install:

```bash
kubectl -n keycloak create secret generic keycloak-bootstrap-admin \
  --from-literal=username=admin --from-literal=password="$(openssl rand -base64 24)"
kubectl -n keycloak create secret generic report-bot-client \
  --from-literal=secret="$(openssl rand -hex 32)"

helm upgrade --install keycloak ./charts/school-keycloak -n keycloak \
  --set instances=1 --set route.enabled=false --set realm.devMode=true        # dev
kubectl get keycloak -n keycloak            # READY True when started
kubectl get keycloakrealmimport -n keycloak # DONE True when the realm exists
```

On a laptop without a gateway, tunnel to it and set the hostname to the tunnel:

```bash
helm upgrade --install keycloak ./charts/school-keycloak -n keycloak \
  --set instances=1 --set route.enabled=false --set realm.devMode=true \
  --set hostname=http://localhost:8080
kubectl port-forward -n keycloak svc/school-keycloak-service 8080:8080
# open http://localhost:8080/admin   (user: admin, password: from the secret)
```

### Step 4: prove it works — get a token with curl

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/realms/school/protocol/openid-connect/token \
  -d grant_type=password -d client_id=school-portal \
  -d username=ms.rivera -d password=change-me-on-first-login | jq -r .access_token)
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq .
# "iss": "http://localhost:8080/realms/school", "aud": "lunch-api", "realm_access": {"roles": ["teacher", …]}
```

(Password grant only works because `devMode: true` turned on `directAccessGrantsEnabled`. Never in prod.)

Two URLs you'll paste into every app:

- Issuer: `https://auth.school.example.com/realms/school`
- Discovery: `https://auth.school.example.com/realms/school/.well-known/openid-configuration` (lists the JWKS URL, token URL, etc.)

### Keycloak gotchas

- ⚠️ **"HTTPS required" / redirect loops** → `proxy.headers: xforwarded` missing, or the gateway/ingress isn't sending `X-Forwarded-Proto: https`. Keycloak thinks it's on plain HTTP.
- ⚠️ **Issuer mismatch** (`iss` in the token ≠ what your app expects) → the app validates tokens against `http://school-keycloak-service:8080` but users got tokens from `https://auth.school.example.com`. Keycloak 25+ puts the configured `hostname` in `iss`; apps must use the same public issuer and fetch keys internally (Part 12 shows the two-URL trick).
- ⚠️ **Realm import runs only once.** `KeycloakRealmImport` creates a realm that doesn't exist yet; it won't update an existing one. Changes later: use the admin console/API, `keycloak-config-cli`, or delete and re-import (which deletes users!).
- ⚠️ **Big headers** → `502`/`upstream sent too big header` on nginx-based proxies. Keycloak's cookies and headers are large; raise the proxy's header buffer (for old ingress-nginx installs: `nginx.ingress.kubernetes.io/proxy-buffer-size: "128k"`). Envoy-based gateways cope by default.
- ⚠️ **Slow start, liveness kills it** → the operator sets probes on the management port `9000` (`/health/live`, `/health/ready`), but if you set your own with too-short timeouts the JVM never finishes starting. Give Keycloak ≥1 GiB and a startup window of 3–5 minutes.
- ⚠️ **Two instances, sessions lost** → Keycloak 26 clusters over the database (JDBC_PING) by default, which works on any Kubernetes; if you disabled it or run behind a mesh that blocks pod-to-pod traffic, logins bounce. Check `kubectl logs` for "ISPN000094: Received new cluster view".
- ⚠️ **Admin bootstrap user is temporary** → after first login create a real admin and rotate/delete the bootstrap one; Keycloak warns about it in the console.
- ⚠️ **Realm names and client IDs are case-sensitive.**
- ⚠️ **API version drift** → `no matches for kind "Keycloak" in version "k8s.keycloak.org/v2beta1"` means your operator is older than the CRD version in your chart (or vice versa). Set `apiVersion` in values to what `kubectl api-resources --api-group=k8s.keycloak.org` reports, and keep the operator version and the chart moving together.
- ⚠️ **Delete the `KeycloakRealmImport` after it succeeds** (the docs recommend it) — it cleans up the import Job/Pod, and keeps a future `helm upgrade` from trying to re-import into an existing realm.

---

<a id="part-11"></a>
## Part 11 — Kafka with add-ons (Strimzi)

🏫 Kafka is the school **intercom + mailroom**. Anyone can *publish* an announcement to a **topic** ("lunch-orders", "attendance"). Anyone interested *subscribes* and gets every message, in order, and can re-read old ones. Messages are kept on disk for days (retention), so a classroom that was closed yesterday can catch up today.

| Kafka word | Meaning | 🏫 |
|---|---|---|
| **Broker** | A Kafka server that stores and serves messages | A mailroom |
| **Controller (KRaft)** | Brokers that keep the cluster's metadata (Kafka 4 has no ZooKeeper) | The mailroom supervisors — always an odd number so they can vote |
| **Topic** | A named stream of messages | "Lunch orders" mailbox |
| **Partition** | A topic is split into N ordered slices so many consumers can work in parallel | Mailbox slots per grade |
| **Replication factor** | How many brokers keep a copy of each partition | Photocopies kept in 3 mailrooms |
| **min.insync.replicas** | How many copies must confirm before a write counts | "Two mailrooms must stamp it" |
| **Consumer group** | A team of consumers that share a topic's partitions | A group of TAs sorting mail together |
| **Kafka Connect** | Plug-in framework to copy data in/out of Kafka without code (Debezium, S3 sink…) | The mail robot that empties the record cabinet into the mailroom |
| **Schema Registry** | Stores the *shape* of messages (Avro/JSON Schema/Protobuf) so producers and consumers agree | The official form templates |
| **Cruise Control** | Rebalances partitions across brokers | The mailroom manager evening out the load |

### Options for Kafka on Kubernetes

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Strimzi operator** (CNCF) | Kafka, node pools, topics, users, Connect, MirrorMaker2, Bridge, Cruise Control as CRDs; TLS/SCRAM/OAuth built in; rolling upgrades | You operate it; needs real disks | **Recommended** in-cluster |
| **Managed Kafka** (Confluent Cloud, Amazon MSK, Azure Event Hubs for Kafka, Aiven, Redpanda Cloud) | No brokers to run | Cost, network setup, vendor differences | Great for production if budget allows |
| **Redpanda** (Kafka-compatible, no JVM) | Simpler ops, low latency | Not Apache Kafka; own operator/licensing | Solid alternative |
| Bitnami kafka chart | Familiar values | Image/legacy issues; StatefulSet-only | Avoid for new setups |

### Step 1: install the Strimzi cluster operator

Strimzi publishes its chart to an OCI registry (its old HTTP repo is deprecated):

```bash
helm upgrade --install strimzi oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  --version 1.2.0 \
  --namespace kafka --create-namespace \
  --set watchAnyNamespace=false \
  --wait --rollback-on-failure
kubectl get pods -n kafka                  # strimzi-cluster-operator-…  Running
kubectl get crd | grep strimzi             # kafkas, kafkanodepools, kafkatopics, kafkausers, kafkaconnects, kafkaconnectors, …
```

By default the operator watches only its own namespace. Use `--set watchNamespaces="{school,kafka}"` (list) or `--set watchAnyNamespace=true` if your `Kafka` resources live elsewhere.

⚠️ Strimzi 1.0 switched its CRDs to API version `kafka.strimzi.io/v1` and dropped `v1beta2`. Upgrading an old (0.4x) install means converting resources first — read Strimzi's upgrade guide. New installs: just use `v1`.

### Step 2: the `school-kafka` chart

```text
charts/school-kafka/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── kafka.yaml           # the Kafka cluster
    ├── nodepools.yaml       # controllers + brokers
    ├── topics.yaml
    ├── users.yaml
    ├── connect.yaml         # Kafka Connect (+ Debezium build)
    ├── connectors.yaml
    ├── schema-registry.yaml # Apicurio Registry (Deployment + Service)
    └── metrics-configmap.yaml
```

📝 `values.yaml`

```yaml
name: school-kafka
kafkaVersion: "4.2.1"          # must be in your Strimzi version's supported list
dev: true                      # true = 1 combined controller+broker node, RF 1; false = 3+3, RF 3
storage:
  size: 20Gi
  storageClass: ""
  deleteClaim: false           # keep disks when the Kafka CR is deleted
resources:
  requests: { cpu: "1", memory: 2Gi }
  limits:   { memory: 2Gi }
jvmHeap: 1024m
auth:
  enabled: false               # true = TLS listener + SCRAM users + ACLs
topics:
  lunch-orders:   { partitions: 6, retentionMs: 604800000 }   # 7 days
  attendance:     { partitions: 3, retentionMs: 2592000000 }  # 30 days
  school.public.grades: { partitions: 3 }                     # filled by Debezium (Part 9's wal_level=logical)
users:
  lunch-api:  { produce: [lunch-orders], consume: [attendance], group: lunch-api }
  report-bot: { produce: [], consume: [lunch-orders, school.public.grades], group: report-bot }
connect:
  enabled: false
  image: ghcr.io/school/school-connect:1.0.0   # Strimzi builds and pushes this
  pushSecret: ghcr-push
  debeziumVersion: "3.2.0.Final"               # check https://debezium.io/releases/
schemaRegistry:
  enabled: false
  image: quay.io/apicurio/apicurio-registry:3.0.7   # pin to a current 3.x
```

📝 `templates/nodepools.yaml`

```yaml
{{- if .Values.dev }}
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: dual-role
  labels: { strimzi.io/cluster: {{ .Values.name }} }
spec:
  replicas: 1
  roles: [controller, broker]          # one node does both — dev only
  storage:
    type: jbod
    volumes:
      - { id: 0, type: persistent-claim, size: 5Gi, deleteClaim: true }
  resources: { requests: { cpu: 500m, memory: 1Gi }, limits: { memory: 1Gi } }
  jvmOptions: { -Xms: 512m, -Xmx: 512m }
{{- else }}
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: controller
  labels: { strimzi.io/cluster: {{ .Values.name }} }
spec:
  replicas: 3                          # odd number — they vote
  roles: [controller]
  storage:
    type: jbod
    volumes:
      - { id: 0, type: persistent-claim, size: 10Gi, deleteClaim: {{ .Values.storage.deleteClaim }}{{ with .Values.storage.storageClass }}, class: {{ . }}{{ end }} }
  resources: { requests: { cpu: 500m, memory: 1Gi }, limits: { memory: 1Gi } }
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: broker
  labels: { strimzi.io/cluster: {{ .Values.name }} }
spec:
  replicas: 3
  roles: [broker]
  storage:
    type: jbod
    volumes:
      - { id: 0, type: persistent-claim, size: {{ .Values.storage.size }}, deleteClaim: {{ .Values.storage.deleteClaim }}{{ with .Values.storage.storageClass }}, class: {{ . }}{{ end }} }
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  jvmOptions: { -Xms: {{ .Values.jvmHeap }}, -Xmx: {{ .Values.jvmHeap }} }
  template:
    pod:
      topologySpreadConstraints:       # spread brokers across zones/nodes
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { strimzi.io/cluster: {{ .Values.name }} } }
{{- end }}
```

📝 `templates/kafka.yaml`

```yaml
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: {{ .Values.name }}
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: {{ .Values.kafkaVersion | quote }}
    listeners:
      - name: plain                      # inside the cluster, no TLS (dev) or paired with network policy
        port: 9092
        type: internal
        tls: false
      {{- if .Values.auth.enabled }}
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication: { type: scram-sha-512 }
      {{- end }}
    {{- if .Values.auth.enabled }}
    authorization:
      type: simple                        # ACLs from KafkaUser resources
    {{- end }}
    config:
      {{- if .Values.dev }}
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
      {{- else }}
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
      {{- end }}
      auto.create.topics.enable: "false"   # topics come from KafkaTopic resources only
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef: { name: {{ .Values.name }}-metrics, key: kafka-metrics-config.yml }
  entityOperator:                          # manages KafkaTopic and KafkaUser resources
    topicOperator: {}
    userOperator: {}
  {{- if not .Values.dev }}
  cruiseControl: {}                        # enables KafkaRebalance
  kafkaExporter:                           # consumer-lag metrics for Prometheus
    topicRegex: ".*"
    groupRegex: ".*"
  {{- end }}
```

📝 `templates/topics.yaml`

```yaml
{{- range $name, $t := .Values.topics }}
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: {{ $name }}
  labels: { strimzi.io/cluster: {{ $.Values.name }} }
spec:
  partitions: {{ $t.partitions | default 3 }}
  replicas: {{ if $.Values.dev }}1{{ else }}3{{ end }}
  config:
    retention.ms: {{ $t.retentionMs | default 604800000 }}
    {{- if not $.Values.dev }}
    min.insync.replicas: 2
    {{- end }}
{{- end }}
```

📝 `templates/users.yaml` (only when `auth.enabled`)

```yaml
{{- if .Values.auth.enabled }}
{{- range $name, $u := .Values.users }}
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: {{ $name }}
  labels: { strimzi.io/cluster: {{ $.Values.name }} }
spec:
  authentication: { type: scram-sha-512 }   # Strimzi creates Secret "{{ $name }}" with password + sasl.jaas.config
  authorization:
    type: simple
    acls:
      {{- range $u.produce }}
      - resource: { type: topic, name: {{ . }}, patternType: literal }
        operations: [Describe, Write]
      {{- end }}
      {{- range $u.consume }}
      - resource: { type: topic, name: {{ . }}, patternType: literal }
        operations: [Describe, Read]
      {{- end }}
      - resource: { type: group, name: {{ $u.group }}, patternType: prefix }
        operations: [Read]
{{- end }}
{{- end }}
```

Install and watch it come up (this takes 1–3 minutes):

```bash
helm upgrade --install school-kafka ./charts/school-kafka -n kafka
kubectl get kafka -n kafka -w                 # READY True
kubectl get kafkatopic -n kafka               # lunch-orders, attendance… READY True
kubectl get pods -n kafka                     # school-kafka-dual-role-0, school-kafka-entity-operator-…
```

Send and receive a message using Strimzi's own image:

```bash
kubectl -n kafka run producer -it --rm --image=quay.io/strimzi/kafka:latest-kafka-4.2.1 -- \
  bin/kafka-console-producer.sh --bootstrap-server school-kafka-kafka-bootstrap:9092 --topic lunch-orders
# type:  {"student":"sam","item":"pizza"}   then Ctrl+C
kubectl -n kafka run consumer -it --rm --image=quay.io/strimzi/kafka:latest-kafka-4.2.1 -- \
  bin/kafka-console-consumer.sh --bootstrap-server school-kafka-kafka-bootstrap:9092 --topic lunch-orders --from-beginning
```

The address every app uses: **`school-kafka-kafka-bootstrap.kafka.svc:9092`** (plain) or `:9093` (TLS+SCRAM). Strimzi also creates `school-kafka-cluster-ca-cert` (Secret) with the CA your clients trust on the TLS listener.

### Add-on 1: Kafka Connect + Debezium (record cabinet → intercom)

Debezium watches Postgres' write-ahead log and turns every row change into a Kafka message. This is how the Python app in Part 12 learns about new grades without polling the database.

📝 `templates/connect.yaml`

```yaml
{{- if .Values.connect.enabled }}
apiVersion: kafka.strimzi.io/v1
kind: KafkaConnect
metadata:
  name: {{ .Values.name }}-connect
  annotations:
    strimzi.io/use-connector-resources: "true"   # manage connectors as KafkaConnector CRs
spec:
  version: {{ .Values.kafkaVersion | quote }}
  replicas: {{ if .Values.dev }}1{{ else }}2{{ end }}
  bootstrapServers: {{ .Values.name }}-kafka-bootstrap:9092
  config:
    group.id: {{ .Values.name }}-connect
    offset.storage.topic: connect-offsets
    config.storage.topic: connect-configs
    status.storage.topic: connect-status
    config.storage.replication.factor: -1        # -1 = use the broker default
    offset.storage.replication.factor: -1
    status.storage.replication.factor: -1
    key.converter: org.apache.kafka.connect.json.JsonConverter
    value.converter: org.apache.kafka.connect.json.JsonConverter
    # Read DB credentials from Kubernetes Secrets instead of pasting them into the connector:
    config.providers: secrets
    config.providers.secrets.class: io.strimzi.kafka.KubernetesSecretConfigProvider
  build:                                          # Strimzi builds an image with the plugins and pushes it
    output:
      type: docker
      image: {{ .Values.connect.image }}
      pushSecret: {{ .Values.connect.pushSecret }}
    plugins:
      - name: debezium-postgres
        artifacts:
          - type: tgz
            url: https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/{{ .Values.connect.debeziumVersion }}/debezium-connector-postgres-{{ .Values.connect.debeziumVersion }}-plugin.tar.gz
{{- end }}
```

📝 `templates/connectors.yaml`

```yaml
{{- if .Values.connect.enabled }}
apiVersion: kafka.strimzi.io/v1
kind: KafkaConnector
metadata:
  name: grades-cdc
  labels: { strimzi.io/cluster: {{ .Values.name }}-connect }
spec:
  class: io.debezium.connector.postgresql.PostgresConnector
  tasksMax: 1
  config:
    database.hostname: grades-db-rw.school.svc
    database.port: "5432"
    database.dbname: grades
    database.user: ${secrets:school/grades-db-app:username}
    database.password: ${secrets:school/grades-db-app:password}
    plugin.name: pgoutput                 # built into Postgres 10+; needs wal_level=logical (Part 9)
    publication.autocreate.mode: filtered
    topic.prefix: school                  # topics become school.<schema>.<table>
    table.include.list: public.grades
    snapshot.mode: initial
{{- end }}
```

The `${secrets:namespace/secret:key}` provider needs a Role that lets the Connect ServiceAccount (`school-kafka-connect-connect`) `get` that Secret. Strimzi's docs show the exact RoleBinding.

⚠️ Debezium needs a Postgres role with `REPLICATION` (and rights to create a publication). CNPG's default `app` user has neither. Add a managed role in the CNPG `Cluster` (`spec.managed.roles` with `replication: true`) or run `ALTER ROLE app WITH REPLICATION;` once, and grant `CREATE` on the database for the publication.

### Add-on 2: Schema Registry (Apicurio Registry 3)

Apicurio stores schemas in a Kafka topic (`kafkasql` storage) — no extra database — and speaks the Confluent-compatible API your Java/Python/Go serializers expect.

📝 `templates/schema-registry.yaml`

```yaml
{{- if .Values.schemaRegistry.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: schema-registry
spec:
  replicas: 1
  selector: { matchLabels: { app: schema-registry } }
  template:
    metadata: { labels: { app: schema-registry } }
    spec:
      securityContext: { runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: registry
          image: {{ .Values.schemaRegistry.image }}
          env:
            - { name: APICURIO_STORAGE_KIND, value: kafkasql }
            - { name: APICURIO_KAFKASQL_BOOTSTRAP_SERVERS, value: {{ .Values.name }}-kafka-bootstrap:9092 }
          ports: [{ name: http, containerPort: 8080 }]
          readinessProbe: { httpGet: { path: /health/ready, port: http } }
          livenessProbe:  { httpGet: { path: /health/live,  port: http } }
          resources: { requests: { cpu: 250m, memory: 768Mi }, limits: { memory: 768Mi } }
---
apiVersion: v1
kind: Service
metadata:
  name: schema-registry
spec:
  selector: { app: schema-registry }
  ports: [{ name: http, port: 8080, targetPort: http }]
{{- end }}
```

Clients use `http://schema-registry.kafka.svc:8080/apis/ccompat/v7` as their "Confluent" schema registry URL. (Apicurio also has an operator if you'd rather not manage the Deployment yourself.)

### Add-on 3: Kafka UI (Kafbat UI)

A web console to browse topics, messages, consumer lag, Connect and schemas. Kafbat UI is the maintained community continuation of the old Provectus kafka-ui, and it ships a Helm chart:

```bash
helm repo add kafbat-ui https://ui.charts.kafbat.io
helm upgrade --install kafka-ui kafbat-ui/kafka-ui -n kafka --version <check helm search> -f - <<'EOF'
yamlApplicationConfig:
  kafka:
    clusters:
      - name: school
        bootstrapServers: school-kafka-kafka-bootstrap:9092
        kafkaConnect:
          - name: school-connect
            address: http://school-kafka-connect-connect-api:8083
        schemaRegistry: http://schema-registry:8080/apis/ccompat/v7
resources:
  requests: { cpu: 200m, memory: 512Mi }
  limits:   { memory: 512Mi }
EOF
kubectl port-forward -n kafka svc/kafka-ui 8081:80    # open http://localhost:8081
```

✅ In production, put Kafka UI behind Keycloak: Kafbat UI supports OAuth2/OIDC login (`auth.type: OAUTH2` in its config) and can map Keycloak realm roles to read-only vs admin — one more "hall pass" reader. Never expose it without login; it can delete topics.

### Add-on 4: Metrics and dashboards

The `metricsConfig` above needs a ConfigMap (`templates/metrics-configmap.yaml`) with the JMX exporter rules — copy `kafka-metrics.yaml` from the Strimzi examples repo. Then, with kube-prometheus-stack installed, add a `PodMonitor` for `strimzi.io/kind: Kafka` pods and import Strimzi's Grafana dashboards (`strimzi-kafka.json`, `strimzi-kafka-exporter.json`). Consumer lag is the number one metric to alert on.

### Add-on 5: Cruise Control, MirrorMaker 2, Bridge

- **Cruise Control** (`cruiseControl: {}`): after adding brokers, create a `KafkaRebalance` resource; Strimzi runs a proposal and you approve it with an annotation. Strimzi can also auto-rebalance on scale up/down.
- **MirrorMaker 2** (`KafkaMirrorMaker2`): copy topics to a second cluster in another region for disaster recovery.
- **Kafka Bridge** (`KafkaBridge`): an HTTP API for apps that can't speak the Kafka protocol (mobile apps, curl).

### Kafka gotchas

- ⚠️ **3 brokers with `replicationFactor: 3` on a laptop** → pods Pending or OOMKilled. Use `dev: true` (1 node, RF 1).
- ⚠️ **Controllers must be an odd number** (1, 3, 5). Two controllers is worse than one.
- ⚠️ **Scaling brokers *down* fails on purpose** if partitions live on the broker being removed. Move them first (Cruise Control `KafkaRebalance` with `mode: remove-brokers`).
- ⚠️ **`deleteClaim: true` deletes your data** when the `Kafka` CR is deleted (including by `helm uninstall`). Prod: `false`.
- ⚠️ **Version bumps are two steps**: upgrade Strimzi (rolls pods once), then bump `spec.kafka.version` (rolls again), and `metadataVersion` follows. Downgrades are limited — read the Strimzi upgrade guide before every bump.
- ⚠️ **The topic operator only manages `KafkaTopic` resources.** Topics created by apps (with `auto.create.topics.enable=true`) won't appear as CRs until you create matching `KafkaTopic`s; keep auto-creation off.
- ⚠️ **External access** (clients outside the cluster) needs a listener of `type: loadbalancer` (one cloud LB per broker — costly), `nodeport`, or `ingress` (TLS passthrough). Inside the cluster, internal listeners are enough.
- ⚠️ **Small JVM heap = mysterious slowness**; too big = OOMKilled. Set `-Xmx` to about half the memory limit and leave the rest for page cache.
- ⚠️ **Time-based retention is per segment**, so messages live a little longer than `retention.ms`. Don't rely on it for compliance deletes.
- ⚠️ **Old Strimzi + ZooKeeper**: Kafka 4 removed ZooKeeper entirely; Strimzi 0.46+ only supports KRaft. Migrate ZooKeeper-based clusters with Strimzi's migration procedure *before* upgrading to Strimzi 1.x.

---

<a id="part-12"></a>
## Part 12 — Your own apps: Java Spring + OIDC, Python, Go

🏫 Three classrooms, three teachers who speak different languages (Java, Python, Go), one set of school rules (the `school-app` chart). Each teacher only fills in their class list (values).

### One chart to rule them all: `school-app`

Part 4 showed `deployment.yaml` and `_helpers.tpl`. Here are the remaining templates, condensed.

📝 `templates/configmap.yaml` — every key in `env:` becomes an environment variable

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "school-app.fullname" . }}
  labels: {{- include "school-app.labels" . | nindent 4 }}
data:
  {{- range $k, $v := .Values.env }}
  {{ $k }}: {{ tpl (toString $v) $ | quote }}     # tpl lets values reference .Release.Namespace etc.
  {{- end }}
```

📝 `templates/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "school-app.fullname" . }}
  labels: {{- include "school-app.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector: {{- include "school-app.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
```

📝 `templates/httproute.yaml` — Gateway API (preferred)

```yaml
{{- if .Values.route.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "school-app.fullname" . }}
  labels: {{- include "school-app.labels" . | nindent 4 }}
spec:
  parentRefs:
    - name: {{ .Values.route.gatewayName }}
      namespace: {{ .Values.route.gatewayNamespace }}
      sectionName: https-{{ .Values.route.host | replace "." "-" }}   # listener names come from the gateway chart (Part 15)
  hostnames: [{{ .Values.route.host | quote }}]
  rules:
    - matches: [{ path: { type: PathPrefix, value: {{ .Values.route.path | default "/" | quote }} } }]
      backendRefs:
        - name: {{ include "school-app.fullname" . }}
          port: {{ .Values.service.port }}
{{- end }}
```

📝 `templates/ingress.yaml` — classic Ingress, kept for clusters that still run an Ingress controller

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "school-app.fullname" . }}
  labels: {{- include "school-app.labels" . | nindent 4 }}
  annotations: {{- toYaml .Values.ingress.annotations | nindent 4 }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  {{- with .Values.ingress.tls }}
  tls: {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          - path: {{ .path | default "/" }}
            pathType: Prefix
            backend:
              service:
                name: {{ include "school-app.fullname" $ }}
                port: { name: http }
    {{- end }}
{{- end }}
```

📝 `templates/pdb.yaml` — never let a node drain take every replica

```yaml
{{- if gt (int .Values.replicaCount) 1 }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "school-app.fullname" . }}
spec:
  minAvailable: 1
  selector:
    matchLabels: {{- include "school-app.selectorLabels" . | nindent 6 }}
{{- end }}
```

📝 `templates/hpa.yaml`

```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "school-app.fullname" . }}
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: {{ include "school-app.fullname" . }} }
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: {{ .Values.autoscaling.targetCPU }} } }
{{- end }}
```

Add to `values.yaml`:

```yaml
probes:
  liveness:  { path: /healthz }
  readiness: { path: /readyz }
autoscaling: { enabled: false, minReplicas: 2, maxReplicas: 6, targetCPU: 70 }
serviceAccount: { create: true, annotations: {} }   # annotations → workload identity (Part 14)
route:   { enabled: false, host: "", path: /, gatewayName: school, gatewayNamespace: gateways }
ingress: { enabled: false, className: "", hosts: [], tls: [], annotations: {} }
```

Publish it once (`helm package && helm push … oci://ghcr.io/school/charts`), and every app installs with:

```bash
helm upgrade --install lunch-api oci://ghcr.io/school/charts/school-app --version 1.4.2 -n school -f apps/lunch-api/values.yaml
```

### The issuer gotcha (read this before writing any app)

Inside the cluster, Keycloak is reachable at `http://school-keycloak-service.keycloak.svc:8080`. Users get tokens from `https://auth.school.example.com`. The token says `"iss": "https://auth.school.example.com/realms/school"`. If your app is configured with the *internal* URL as issuer, every token is rejected ("iss claim is not equal to configured issuer"). If it's configured with the *external* URL only, the app makes a round trip through the internet (and your ingress) just to download signing keys, and fails on a laptop without DNS.

✅ The fix, in every language: **validate `iss` against the public issuer, but fetch the JWKS keys from the internal URL.** Each example below does exactly that.

---

### App 1 — Java Spring Boot `lunch-api` (validates Keycloak tokens, writes to Kafka)

**Stack:** Java 21 (LTS), Spring Boot 4.x, Spring Security OAuth2 Resource Server, Spring for Apache Kafka.

📝 `pom.xml` dependencies (excerpt)

```xml
<dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web</artifactId></dependency>
<dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-oauth2-resource-server</artifactId></dependency>
<dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-actuator</artifactId></dependency>
<dependency><groupId>org.springframework.kafka</groupId><artifactId>spring-kafka</artifactId></dependency>
```

📝 `src/main/resources/application.yaml`

```yaml
server:
  port: 8080
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: ${OIDC_ISSUER_URI}        # public URL — what "iss" must equal
          jwk-set-uri: ${OIDC_JWK_SET_URI}      # internal URL — where to fetch keys (skips discovery over the internet)
          audiences: lunch-api                  # token must carry aud=lunch-api (from the client scope in Part 10)
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS}
    producer:
      acks: all
      properties: { enable.idempotence: true }
management:
  endpoints.web.exposure.include: health,info,prometheus
  endpoint.health.probes.enabled: true          # /actuator/health/liveness and /readiness
  health.readinessstate.enabled: true
  health.livenessstate.enabled: true
```

📝 `SecurityConfig.java` — turn Keycloak realm roles into Spring authorities

```java
@Configuration
@EnableMethodSecurity
public class SecurityConfig {
  @Bean
  SecurityFilterChain api(HttpSecurity http) throws Exception {
    http.authorizeHttpRequests(a -> a
          .requestMatchers("/actuator/health/**").permitAll()
          .anyRequest().authenticated())
        .oauth2ResourceServer(o -> o.jwt(j -> j.jwtAuthenticationConverter(realmRoles())));
    return http.build();
  }

  private JwtAuthenticationConverter realmRoles() {
    var conv = new JwtAuthenticationConverter();
    conv.setJwtGrantedAuthoritiesConverter(jwt -> {
      Map<String, Object> realm = jwt.getClaimAsMap("realm_access");
      List<String> roles = realm == null ? List.of() : (List<String>) realm.getOrDefault("roles", List.of());
      return roles.stream().map(r -> new SimpleGrantedAuthority("ROLE_" + r)).collect(Collectors.toList());
    });
    return conv;
  }
}
```

📝 `LunchController.java`

```java
@RestController
@RequestMapping("/orders")
public class LunchController {
  private final KafkaTemplate<String, String> kafka;
  LunchController(KafkaTemplate<String, String> kafka) { this.kafka = kafka; }

  @PostMapping
  @PreAuthorize("hasAnyRole('student','teacher')")
  public Map<String, String> order(@AuthenticationPrincipal Jwt jwt, @RequestBody Map<String, String> body) {
    String student = jwt.getClaimAsString("preferred_username");
    kafka.send("lunch-orders", student, "{\"student\":\"" + student + "\",\"item\":\"" + body.get("item") + "\"}");
    return Map.of("status", "queued", "student", student);
  }
}
```

📝 `Dockerfile` (multi-stage, layered, non-root)

```dockerfile
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY mvnw pom.xml ./
COPY .mvn .mvn
RUN ./mvnw -q dependency:go-offline          # cache dependencies as their own layer
COPY src src
RUN ./mvnw -q package -DskipTests && \
    java -Djarmode=tools -jar target/*.jar extract --layers --destination extracted

FROM eclipse-temurin:21-jre
WORKDIR /app
RUN useradd -u 10001 -r app
COPY --from=build /src/extracted/dependencies/ ./
COPY --from=build /src/extracted/spring-boot-loader/ ./
COPY --from=build /src/extracted/snapshot-dependencies/ ./
COPY --from=build /src/extracted/application/ ./
USER 10001
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "lunch-api.jar"]
```

*Alternative:* `./mvnw spring-boot:build-image` uses Cloud Native Buildpacks (Paketo) — no Dockerfile, sensible JVM memory settings, SBOM included. Pros: zero Dockerfile maintenance. Cons: bigger images, less control, needs Docker/Podman socket at build time.

📝 `apps/lunch-api/values.yaml`

```yaml
image: { repository: ghcr.io/school/lunch-api, tag: "2.0.1" }
replicaCount: 2
service: { port: 8080 }
resources:
  requests: { cpu: 500m, memory: 768Mi }
  limits:   { memory: 768Mi }
probes:
  liveness:  { path: /actuator/health/liveness }
  readiness: { path: /actuator/health/readiness }
env:
  OIDC_ISSUER_URI: https://auth.school.example.com/realms/school
  OIDC_JWK_SET_URI: http://school-keycloak-service.keycloak.svc:8080/realms/school/protocol/openid-connect/certs
  KAFKA_BOOTSTRAP_SERVERS: school-kafka-kafka-bootstrap.kafka.svc:9092
  JAVA_TOOL_OPTIONS: "-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"
route:
  enabled: true
  host: lunch.school.example.com          # TLS is handled by the shared Gateway (Part 15)
```

Test it end to end (laptop version: issuer `http://localhost:8080/realms/school` in both env vars while port-forwarding Keycloak):

```bash
curl -s -X POST https://lunch.school.example.com/orders \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"item":"pizza"}'
# {"status":"queued","student":"ms.rivera"}
```

Java gotchas: ⚠️ the JVM sees the *container's* memory limit only when `MaxRAMPercentage` (or `-Xmx`) is set — otherwise it may size the heap from the node and get OOMKilled. ⚠️ Startup can take 20–60 s: use the `startupProbe` (Part 4) so liveness doesn't kill it. ⚠️ With SCRAM (`auth.enabled`), mount the Strimzi user Secret and set `spring.kafka.security.protocol=SASL_SSL`, `sasl.mechanism=SCRAM-SHA-512`, `sasl.jaas.config` from the Secret, and trust `school-kafka-cluster-ca-cert`.

---

### App 2 — Python FastAPI `grade-alerts` (validates tokens; consumes the Debezium stream)

**Stack:** Python 3.13, FastAPI, uvicorn, PyJWT (with `PyJWKClient`), aiokafka.

📝 `app.py`

```python
import asyncio, json, os
from contextlib import asynccontextmanager
import jwt
from fastapi import Depends, FastAPI, HTTPException, Request
from aiokafka import AIOKafkaConsumer

ISSUER   = os.environ["OIDC_ISSUER_URI"]                        # public: what "iss" must equal
JWKS_URL = os.environ["OIDC_JWK_SET_URI"]                       # internal: where keys come from
jwks = jwt.PyJWKClient(JWKS_URL, cache_keys=True)
app = FastAPI()
alerts: list[dict] = []

def current_user(request: Request) -> dict:
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "missing token")
    token = auth.removeprefix("Bearer ")
    try:
        key = jwks.get_signing_key_from_jwt(token).key
        return jwt.decode(token, key, algorithms=["RS256"], issuer=ISSUER, audience="lunch-api")
    except jwt.PyJWTError as e:
        raise HTTPException(401, str(e))

@app.get("/healthz")
def healthz(): return {"ok": True}

@app.get("/readyz")
def readyz(): return {"ok": True}

@app.get("/alerts")
def list_alerts(user: dict = Depends(current_user)):
    roles = user.get("realm_access", {}).get("roles", [])
    if "teacher" not in roles:
        raise HTTPException(403, "teachers only")
    return alerts

async def consume():
    consumer = AIOKafkaConsumer(
        "school.public.grades",
        bootstrap_servers=os.environ["KAFKA_BOOTSTRAP_SERVERS"],
        group_id="grade-alerts", auto_offset_reset="earliest",
        value_deserializer=lambda b: json.loads(b) if b else None)
    await consumer.start()
    try:
        async for msg in consumer:
            after = (msg.value or {}).get("payload", {}).get("after")
            if after and after.get("score", 100) < 60:
                alerts.append(after)                              # a failing grade → alert
    finally:
        await consumer.stop()

@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(consume())      # start the consumer with the app…
    yield
    task.cancel()                              # …and stop it cleanly on SIGTERM

app.router.lifespan_context = lifespan
```

📝 `Dockerfile`

```dockerfile
FROM python:3.13-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.13-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN useradd -u 10001 -r app
WORKDIR /app
COPY --from=build /install /usr/local
COPY app.py .
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

📝 `apps/grade-alerts/values.yaml`

```yaml
image: { repository: ghcr.io/school/grade-alerts, tag: "1.3.0" }
replicaCount: 1                       # a Kafka consumer group with 1 member; scale up to the partition count
service: { port: 8000 }
resources:
  requests: { cpu: 200m, memory: 256Mi }
  limits:   { memory: 256Mi }
env:
  OIDC_ISSUER_URI: https://auth.school.example.com/realms/school
  OIDC_JWK_SET_URI: http://school-keycloak-service.keycloak.svc:8080/realms/school/protocol/openid-connect/certs
  KAFKA_BOOTSTRAP_SERVERS: school-kafka-kafka-bootstrap.kafka.svc:9092
```

Python gotchas: ⚠️ `PYTHONUNBUFFERED=1` or your logs appear minutes late in `kubectl logs`. ⚠️ One uvicorn worker per pod; scale with replicas, not `--workers`, so probes and Kafka group membership stay predictable. ⚠️ `readOnlyRootFilesystem: true` breaks pip caches at runtime — install everything at build time (done above).

---

### App 3 — Go `report-bot` (machine-to-machine token, calls the Java API, verifies tokens on its own endpoint)

**Stack:** Go 1.25, `golang.org/x/oauth2/clientcredentials`, `github.com/coreos/go-oidc/v3`, `net/http`.

📝 `main.go`

```go
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2/clientcredentials"
)

func main() {
	ctx := context.Background()
	issuer := os.Getenv("OIDC_ISSUER_URI")      // public issuer, must equal "iss"
	internal := os.Getenv("OIDC_INTERNAL_URL")  // http://school-keycloak-service.keycloak.svc:8080/realms/school

	// Verify incoming tokens: keys from the internal URL, issuer check against the public one.
	keys := oidc.NewRemoteKeySet(ctx, internal+"/protocol/openid-connect/certs")
	verifier := oidc.NewVerifier(issuer, keys, &oidc.Config{ClientID: "lunch-api"}) // ClientID == expected audience

	// Get our own token (client credentials) to call the Java API.
	cc := clientcredentials.Config{
		ClientID:     "report-bot",
		ClientSecret: os.Getenv("REPORT_BOT_SECRET"),
		TokenURL:     internal + "/protocol/openid-connect/token",
	}
	client := cc.Client(ctx) // an http.Client that adds and refreshes the Bearer token automatically

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/report", func(w http.ResponseWriter, r *http.Request) {
		raw := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if _, err := verifier.Verify(r.Context(), raw); err != nil {
			http.Error(w, "unauthorized: "+err.Error(), 401)
			return
		}
		resp, err := client.Get(os.Getenv("LUNCH_API_URL") + "/orders/summary")
		if err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
	})

	srv := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { log.Println("listening on :8080"); log.Println(srv.ListenAndServe()) }()

	// Graceful shutdown: Kubernetes sends SIGTERM, then waits terminationGracePeriodSeconds (30s).
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	shutdownCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}
```

📝 `Dockerfile`

```dockerfile
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /report-bot .

FROM gcr.io/distroless/static-debian12:nonroot   # has CA certs + tzdata, no shell, runs as nonroot (65532)
COPY --from=build /report-bot /report-bot
EXPOSE 8080
ENTRYPOINT ["/report-bot"]
```

📝 `apps/report-bot/values.yaml`

```yaml
image: { repository: ghcr.io/school/report-bot, tag: "0.9.2" }
replicaCount: 2
service: { port: 8080 }
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { memory: 64Mi }
env:
  OIDC_ISSUER_URI: https://auth.school.example.com/realms/school
  OIDC_INTERNAL_URL: http://school-keycloak-service.keycloak.svc:8080/realms/school
  LUNCH_API_URL: http://lunch-api-school-app.school.svc:8080
existingSecret: report-bot-client          # created in Part 10; key "secret" → env REPORT_BOT_SECRET
```

(For that last line to work the Secret's key must be named `REPORT_BOT_SECRET`, or the chart needs a small `env.valueFrom` block. Simplest: create the Secret with `--from-literal=REPORT_BOT_SECRET=…` and reference the same Secret from the `KeycloakRealmImport` placeholder with `key: REPORT_BOT_SECRET`.)

Go gotchas: ⚠️ `FROM scratch` has no CA certificates or timezone data — HTTPS to Keycloak fails with "x509: certificate signed by unknown authority". Distroless `static` includes them. ⚠️ Set `runAsUser: 65532` in the pod security context to match distroless' `nonroot` (or leave the chart's `10001`; both are non-root). ⚠️ Handle `SIGTERM`; Go's default is to die instantly, dropping in-flight requests.

### Which language for what? (pros/cons in a Kubernetes world)

| | Java Spring Boot | Python FastAPI | Go |
|---|---|---|---|
| Image size | 250–400 MB (JRE) | 150–250 MB | 10–30 MB |
| Startup | 10–60 s (use startupProbe; consider CDS/AOT) | 1–3 s | < 1 s |
| Memory | 500 MB–1 GB typical | 100–300 MB | 20–100 MB |
| OIDC/Kafka libraries | Best in class (Spring Security, Spring Kafka) | Good (PyJWT/Authlib, aiokafka/confluent-kafka) | Good (go-oidc, franz-go/sarama) |
| Best for | Big business apps, teams that know Spring | Data, ML, quick APIs | Infra tools, high-concurrency services, tiny images |

---

<a id="part-13"></a>
## Part 13 — Terraform: keeping state and installing charts

### What Terraform is, and what "state" means

🛒 Imagine the store manager's **inventory ledger**. You write down what the shelves *should* hold ("3 freezers, 2 registers, 1 bakery oven"). Terraform reads the ledger, looks at the real store, and orders or removes exactly the difference. The ledger — the **state file** — is Terraform's memory of what it built and the IDs of every real thing, so next time it can find them again.

Terraform is **declarative** like Kubernetes, but it manages things *outside* the cluster too: the cluster itself, networks, DNS, buckets, identities — and, through the Helm provider, releases inside the cluster.

| Term | Meaning |
|---|---|
| **Provider** | A plugin that knows one API: `azurerm`, `aws`, `google`, `kubernetes`, `helm` |
| **Resource** | One thing to manage: `azurerm_kubernetes_cluster`, `helm_release` |
| **Data source** | Read-only lookup of something that exists |
| **State** | The ledger (`terraform.tfstate`) |
| **Backend** | Where the ledger is stored: local file (dev only) or remote (Azure Blob, S3, GCS) with **locking** |
| **`terraform plan`** | Show what would change. **Always read it.** |
| **`terraform apply`** | Do it |
| **Root module** | One folder = one state file = one `terraform apply` |

*Note:* **OpenTofu** is the open-source fork of Terraform (post-2023 license change) and is a drop-in replacement for everything here (`tofu plan`). The provider syntax is identical.

### Why remote state with locking is non-negotiable

Local state on a laptop means: your teammate's Terraform doesn't know what you built → it creates duplicates or destroys your work. Two people running `apply` at the same time corrupt the ledger. Remote backends fix both: one shared ledger, and a **lock** so only one person writes at a time.

🏫 One shared class roster on the office wall (remote state), and a "someone is editing" sign you must hang before touching it (the lock).

📝 Azure (Blob storage; leases give locking for free)

```hcl
terraform {
  required_version = ">= 1.11"
  backend "azurerm" {
    resource_group_name  = "rg-school-tfstate"
    storage_account_name = "stschooltfstate"      # globally unique, 3–24 lowercase chars
    container_name       = "tfstate"
    key                  = "dev/platform.tfstate" # one key per root module per environment
    use_azuread_auth     = true                   # RBAC instead of storage keys
  }
}
```

📝 AWS (S3; native locking with `use_lockfile` — DynamoDB tables are no longer needed since Terraform 1.11)

```hcl
terraform {
  required_version = ">= 1.11"
  backend "s3" {
    bucket       = "school-tfstate-123456789012"  # bucket names are global; add your account id
    key          = "dev/platform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true                            # creates dev/platform.tfstate.tflock during apply
  }
}
```

📝 Google Cloud (GCS; locking built in)

```hcl
terraform {
  required_version = ">= 1.11"
  backend "gcs" {
    bucket = "school-tfstate"
    prefix = "dev/platform"
  }
}
```

✅ Create the state bucket/storage account *outside* Terraform (a one-time script) or in its own tiny root module with local state — the chicken must come before the egg. Turn on versioning (undo a bad state write), encryption, and block public access. State contains secrets (database passwords, kubeconfig tokens) — treat the bucket like a vault.

### Layout: separate root modules for cluster, platform, and apps

```text
infra/
├── modules/
│   ├── aks-cluster/        # reusable: makes a cluster
│   ├── eks-cluster/
│   ├── gke-cluster/
│   └── platform/           # reusable: operators + ingress + cert-manager
└── live/
    ├── dev/
    │   ├── cluster/        # state: dev/cluster.tfstate
    │   ├── platform/       # state: dev/platform.tfstate  (helm_release for CNPG, Strimzi, Envoy Gateway, cert-manager, ESO)
    │   └── apps/           # state: dev/apps.tfstate      (helm_release for school-postgres, school-keycloak, school-kafka, the 3 apps)
    └── prod/
        ├── cluster/
        ├── platform/
        └── apps/
```

Why three layers instead of one big `apply`?

- ⚠️ **The provider chicken-and-egg problem.** The `helm` and `kubernetes` providers need cluster credentials *at plan time*. If the cluster is created in the same `apply`, those values are unknown during the first plan and Terraform errors or, worse, plans against the wrong cluster. Putting the cluster in its own root module, and reading it with a **data source** in the next layer, avoids this entirely.
- Blast radius: `terraform destroy` in `apps/` can't delete your cluster.
- Speed: planning 5 releases takes seconds; planning a whole cloud estate takes minutes.

(Workspaces are an alternative to `dev/` and `prod/` folders, but folders make the difference explicit and let prod use different provider versions. Most teams prefer folders — or a wrapper like Terragrunt.)

### The Helm provider (v3 syntax — blocks became attributes in 2025)

```hcl
terraform {
  required_providers {
    helm       = { source = "hashicorp/helm",       version = "~> 3.2" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
  }
}

# Example: EKS. See Part 14 for the AKS and GKE versions of this block.
data "aws_eks_cluster" "this"      { name = var.cluster_name }

provider "helm" {
  kubernetes = {                                          # v3: an attribute (=), not a block
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec = {                                              # short-lived token every run; nothing stored in state
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
    }
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {                                                  # the kubernetes provider still uses a block here
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}
```

⚠️ Helm provider **3.0 (June 2025)** changed `set { … }` blocks to `set = [ { … } ]` lists and `kubernetes { … }` to `kubernetes = { … }`. Old HCL fails to plan after the upgrade; update the syntax and run `terraform init -upgrade`. Also note the provider embeds its own Helm library (still the Helm 3 SDK in the 3.x line) — its behavior doesn't change when you upgrade the `helm` CLI on your laptop.

### `helm_release` — one resource per chart

📝 `live/dev/platform/main.tf` (excerpt)

```hcl
resource "kubernetes_namespace_v1" "cnpg" {
  metadata {
    name   = "cnpg-system"
    labels = { "pod-security.kubernetes.io/enforce" = "restricted" }
  }
}

resource "helm_release" "cnpg" {
  name       = "cnpg"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = "0.26.1"                        # PIN IT. Unpinned = surprise upgrades on every apply.
  namespace  = kubernetes_namespace_v1.cnpg.metadata[0].name

  wait            = true
  timeout         = 600
  atomic          = true                       # roll back on failure (provider attribute name unchanged)
  cleanup_on_fail = true
  max_history     = 10

  values = [file("${path.module}/values/cnpg.yaml")]

  set = [                                      # v3: a list of objects
    { name = "replicaCount", value = "1" },
  ]
}

resource "helm_release" "strimzi" {
  name       = "strimzi"
  repository = "oci://quay.io/strimzi-helm"    # OCI: repository is the registry path, chart is the name
  chart      = "strimzi-kafka-operator"
  version    = "1.2.0"
  namespace  = "kafka"
  create_namespace = true
  wait       = true
  timeout    = 600
  atomic     = true

  set = [
    { name = "watchNamespaces", value = "{school,kafka}" },   # list syntax: braces
  ]
}

# Gateway API implementation. (Don't install ingress-nginx for new clusters: retired March 2026.)
resource "helm_release" "envoy_gateway" {
  name       = "eg"
  repository = "oci://docker.io/envoyproxy"
  chart      = "gateway-helm"
  version    = "v1.6.0"                        # check the current release; the chart installs the Gateway API CRDs too
  namespace  = "envoy-gateway-system"
  create_namespace = true
  wait       = true
  atomic     = true
  values     = [file("${path.module}/values/envoy-gateway-${var.cloud}.yaml")]   # per-cloud LB annotations
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.19.1"                       # check the current release
  namespace  = "cert-manager"
  create_namespace = true
  wait       = true
  atomic     = true
  set = [
    { name = "crds.enabled",            value = "true" },
    { name = "config.enableGatewayAPI", value = "true" },   # let cert-manager issue certs for Gateway listeners
  ]
  depends_on = [helm_release.envoy_gateway]   # cert-manager needs the Gateway API CRDs to exist
}

# The Keycloak operator ships raw YAML, not a chart. Apply it with the kubernetes provider:
data "http" "keycloak_operator" {
  url = "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${var.keycloak_version}/kubernetes/kubernetes.yml"
}
# …then split the multi-document YAML and feed each doc to kubernetes_manifest, or use the
# gavinbunney/kubectl provider's kubectl_manifest which accepts multi-doc YAML directly.
# Either way: install the two CRD files first (same pattern), and remember that
# kubernetes_manifest needs the cluster reachable at PLAN time — another reason for the layered layout.
```

📝 `live/dev/apps/main.tf` (excerpt) — your own charts from the OCI registry, secrets from Terraform's random provider

```hcl
resource "random_password" "keycloak_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "keycloak_bootstrap_admin" {
  metadata {
    name      = "keycloak-bootstrap-admin"
    namespace = "keycloak"
  }
  data = { username = "admin", password = random_password.keycloak_admin.result }   # stays in state → state must be private
}

resource "helm_release" "keycloak_db" {
  name       = "keycloak-db"
  repository = "oci://ghcr.io/school/charts"
  chart      = "school-postgres"
  version    = "0.1.0"
  namespace  = "keycloak"
  wait       = true
  timeout    = 900
  values     = [file("${path.module}/values/keycloak-db.yaml")]
}

resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "oci://ghcr.io/school/charts"
  chart      = "school-keycloak"
  version    = "0.3.0"
  namespace  = "keycloak"
  wait       = true
  timeout    = 900
  values     = [file("${path.module}/values/keycloak-${var.env}.yaml")]
  set = [
    { name = "hostname", value = "https://auth.${var.domain}" },
  ]
  depends_on = [helm_release.keycloak_db, kubernetes_secret_v1.keycloak_bootstrap_admin]
}

resource "helm_release" "lunch_api" {
  name       = "lunch-api"
  repository = "oci://ghcr.io/school/charts"
  chart      = "school-app"
  version    = "1.4.2"
  namespace  = "school"
  wait       = true
  atomic     = true
  values     = [file("${path.module}/values/lunch-api.yaml")]
  set = [
    { name = "image.tag", value = var.lunch_api_image_tag },       # CI passes the tag: -var lunch_api_image_tag=2.0.1
  ]
  set_sensitive = [
    # anything here is redacted in plan output, but STILL ends up in state and in the Helm release Secret
  ]
  depends_on = [helm_release.keycloak]
}
```

Private OCI registries: log in outside Terraform (`helm registry login ghcr.io` in CI) or set `registries = [{ url = "oci://ghcr.io", username = …, password = … }]` on the provider.

### Daily workflow

```bash
cd infra/live/dev/platform
terraform init                         # download providers, connect to the backend
terraform fmt -recursive && terraform validate
terraform plan -out=tfplan             # READ IT. "1 to add, 0 to change, 0 to destroy"?
terraform apply tfplan                 # apply exactly what you saw
terraform state list                   # what's in the ledger
terraform show                         # details
```

Adopting a release that already exists (installed by hand):

```bash
terraform import helm_release.cnpg cnpg-system/cnpg        # "<namespace>/<release-name>"
```

### Terraform + Helm gotchas

- ⚠️ **"Provider configuration: unknown values"** / plans against the wrong cluster → cluster and Helm releases in the same root module. Split them (layout above) or, at minimum, use data sources + `depends_on`.
- ⚠️ **`values` drift on every plan.** Terraform compares the *strings* you pass, not rendered YAML. A reformatted values file (spaces, key order) shows as a change. Keep values files stable, and use `yamlencode(local.values)` if you build values in HCL so the output is deterministic.
- ⚠️ **Unpinned `version` = the chart upgrades whenever a new version is published**, at 2 a.m., during an unrelated apply. Pin everything: chart `version`, provider versions, module versions, Terraform version.
- ⚠️ **`wait = true` + a pod that never becomes Ready = a 10-minute timeout and a release stuck in `pending-*`**. Fix the Helm side (Part 7.1) — `terraform apply` again won't clear it.
- ⚠️ **CRDs and `kubernetes_manifest`**: a `kubernetes_manifest` resource for a `Kafka` CR fails at *plan* time if the Strimzi CRD doesn't exist yet in the cluster (the provider validates against the live API). Install operators in `platform/`, CRs in `apps/`.
- ⚠️ **Secrets in state**: `random_password`, `set_sensitive`, data sources that return credentials — all land in state in plain text. Remote state must be private, encrypted, and access-logged. Prefer External Secrets Operator so Terraform never touches the actual secret values.
- ⚠️ **`terraform destroy` order**: Terraform deletes `helm_release` resources, but not PVCs left behind by operators, and it will hang deleting a namespace that still contains a `Kafka` CR whose operator was already removed (finalizers). Destroy `apps/` first, then `platform/`, then `cluster/`.
- ⚠️ **Provider upgrades**: helm provider 2.x → 3.x is a syntax change (above). Read every provider's upgrade guide; pin with `~>` to a minor.
- ⚠️ **`create_namespace = true` hides namespace ownership** — use `kubernetes_namespace_v1` so labels/quotas are managed.
- ⚠️ **State lock stuck** after a crashed run: `terraform force-unlock <LOCK_ID>` — only after confirming nobody else is applying.

### Terraform vs Helmfile vs GitOps for the "apps" layer

| | Terraform `helm_release` | Helmfile | Argo CD / Flux |
|---|---|---|---|
| Good at | One workflow with cloud resources, secrets from `random_password`, dependency ordering | Declaring many releases + values per env in one file, `helmfile diff` | Continuous reconciliation, drift detection, UI, multi-cluster |
| Weak at | Values drift noise, plan-time cluster access, slow with many releases | No state (it just runs Helm), no cloud resources | Another control plane; Helm hooks/lookups render differently; needs Git discipline |
| Typical use | `cluster/` and `platform/` layers | Small teams' `apps/` layer | `apps/` layer at scale |

A very common split: **Terraform for cluster + platform, Argo CD (installed by Terraform) for apps.**

---

<a id="part-14"></a>
## Part 14 — Cloud clusters: AKS, EKS, GKE

🏫 So far the school ran in a shoebox on your desk (kind). Now we rent a real building from one of three landlords. The classrooms (charts) are the same; the building's plumbing (disks, doors, badges) differs.

### What differs per cloud (the table to keep on your wall)

| | **Azure AKS** | **AWS EKS** | **Google GKE** |
|---|---|---|---|
| Terraform resource | `azurerm_kubernetes_cluster` | `terraform-aws-modules/eks/aws` module (raw resources are ~15 objects) | `google_container_cluster` (Autopilot or Standard) |
| Default StorageClass | `managed-csi` (Premium SSD), `azurefile-csi` for RWX | **None usable until the EBS CSI add-on has an IAM role**; then create `gp3` | `standard-rwo` (balanced PD), `premium-rwo` |
| Gateway API | Application Gateway for Containers (`azure-alb-external`) or Envoy Gateway | AWS Load Balancer Controller (Gateway API support) / Envoy Gateway | Built-in GKE Gateway controller (`gke-l7-global-external-managed`) |
| Pod identity (no secrets for cloud APIs) | **Workload Identity**: annotate the ServiceAccount with `azure.workload.identity/client-id` + pod label `azure.workload.identity/use: "true"` | **EKS Pod Identity** (newer, simpler) or IRSA (`eks.amazonaws.com/role-arn` annotation) | **Workload Identity Federation** (on by default in Autopilot); annotate SA with `iam.gke.io/gcp-service-account` or use direct IAM binding |
| Container registry | ACR (`AcrPull` role to the kubelet identity) | ECR (node role can pull by default) | Artifact Registry (node SA needs `roles/artifactregistry.reader`) |
| Get kubeconfig | `az aks get-credentials -g rg -n aks` (+ `kubelogin` for Entra ID) | `aws eks update-kubeconfig --name school-dev` | `gcloud container clusters get-credentials school-dev --region us-central1` (+ `gke-gcloud-auth-plugin`) |
| Node autoscaling | Cluster Autoscaler (built-in) or Node Autoprovisioning (Karpenter-based) | Karpenter (recommended) or Cluster Autoscaler | Autopilot does it; Standard uses Node Auto-Provisioning |
| Version support | ~1 year per minor; auto-upgrade channels | 14 months standard, then paid "extended support" | Release channels (Rapid/Regular/Stable) |
| Watch out for | System node pool taints; `LoadBalancer` needs `service.beta.kubernetes.io/azure-load-balancer-*` annotations for internal LBs | IP exhaustion (VPC CNI uses one IP per pod), EBS CSI IAM, the `aws-auth`/access-entries switch | Autopilot rejects privileged pods and rewrites resource requests; Standard needs you to size nodes |

### Azure AKS

📝 `live/dev/cluster/main.tf`

```hcl
terraform {
  required_providers { azurerm = { source = "hashicorp/azurerm", version = "~> 4.40" } }
}
provider "azurerm" { features {} }

resource "azurerm_resource_group" "school" {
  name     = "rg-school-dev"
  location = "eastus2"
}

resource "azurerm_kubernetes_cluster" "school" {
  name                = "aks-school-dev"
  location            = azurerm_resource_group.school.location
  resource_group_name = azurerm_resource_group.school.name
  dns_prefix          = "school-dev"
  kubernetes_version  = "1.33"                  # az aks get-versions -l eastus2 -o table
  automatic_upgrade_channel = "patch"

  oidc_issuer_enabled       = true              # Workload Identity: pods get Entra ID identities, no stored secrets
  workload_identity_enabled = true

  default_node_pool {                           # "system" pool: only Kubernetes' own add-ons
    name                         = "system"
    vm_size                      = "Standard_D4s_v5"
    auto_scaling_enabled         = true         # azurerm 4.x name (was enable_auto_scaling in 3.x)
    min_count                    = 2
    max_count                    = 4
    only_critical_addons_enabled = true         # taints the pool so apps land on the "apps" pool
    upgrade_settings { max_surge = "33%" }
  }

  identity { type = "SystemAssigned" }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"              # pods don't eat VNet IPs
    network_data_plane  = "cilium"
    network_policy      = "cilium"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true                   # kubectl access = Entra ID + Azure RBAC
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.school.id
  vm_size               = "Standard_D8s_v5"
  zones                 = ["1", "2", "3"]
  auto_scaling_enabled  = true
  min_count             = 2
  max_count             = 10
}

resource "azurerm_container_registry" "school" {
  name                = "acrschooldev"          # globally unique, alphanumeric only
  resource_group_name = azurerm_resource_group.school.name
  location            = azurerm_resource_group.school.location
  sku                 = "Standard"
}

resource "azurerm_role_assignment" "acr_pull" {   # nodes may pull images: no imagePullSecrets needed
  scope                = azurerm_container_registry.school.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.school.kubelet_identity[0].object_id
}
```

📝 `live/dev/platform/providers.tf` (reads the cluster; never creates it)

```hcl
data "azurerm_kubernetes_cluster" "school" {
  name                = "aks-school-dev"
  resource_group_name = "rg-school-dev"
}

provider "helm" {
  kubernetes = {
    host                   = data.azurerm_kubernetes_cluster.school.kube_config[0].host
    cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.school.kube_config[0].cluster_ca_certificate)
    exec = {                                          # Entra ID login via kubelogin; works for humans (az login) and CI (workload identity)
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "kubelogin"
      args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
    }
  }
}
```

Give the CNPG backups (Part 9) and External Secrets a badge instead of a key: create a `azurerm_user_assigned_identity`, an `azurerm_federated_identity_credential` bound to `system:serviceaccount:<ns>:<sa>` on the cluster's OIDC issuer, and annotate the ServiceAccount in values: `serviceAccount.annotations: { azure.workload.identity/client-id: <client-id> }`.

AKS gotchas: ⚠️ Forgetting `only_critical_addons_enabled` means Kafka brokers get scheduled on the system pool and fight CoreDNS for CPU. ⚠️ A `LoadBalancer` Service is public by default; add `service.beta.kubernetes.io/azure-load-balancer-internal: "true"` for internal. ⚠️ Changing `vm_size` on the default pool recreates the cluster (create a new pool instead). ⚠️ `kube_config` with Azure RBAC only works with `kubelogin`; install it (`az aks install-cli`).

### AWS EKS

📝 `live/dev/cluster/main.tf`

```hcl
terraform {
  required_providers { aws = { source = "hashicorp/aws", version = "~> 6.0" } }
}
provider "aws" { region = "us-east-1" }

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"
  name            = "school-dev"
  cidr            = "10.0.0.0/16"
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]     # big: VPC CNI gives every pod an IP
  public_subnets  = ["10.0.100.0/24", "10.0.101.0/24", "10.0.102.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true                                              # dev; one per AZ in prod
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }                 # load balancer controller finds subnets by tag
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"                    # v21 renamed inputs (cluster_name→name, cluster_version→kubernetes_version, cluster_addons→addons)
  name               = "school-dev"
  kubernetes_version = "1.33"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access                   = true          # restrict with endpoint_public_access_cidrs in prod
  enable_cluster_creator_admin_permissions = true          # whoever runs terraform can kubectl (access entries, not aws-auth)

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    aws-ebs-csi-driver     = {}                            # disks for Postgres/Kafka — needs the IAM role below
  }

  eks_managed_node_groups = {
    apps = {
      instance_types = ["m6i.large"]
      min_size       = 2
      max_size       = 6
      desired_size   = 3
    }
  }
}

# Give the EBS CSI driver permission to create volumes (Pod Identity, no OIDC trust policies to hand-write)
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"                                          # check the current release
  name                      = "ebs-csi"
  attach_aws_ebs_csi_policy = true
  associations = {
    ebs = { cluster_name = module.eks.cluster_name, namespace = "kube-system", service_account = "ebs-csi-controller-sa" }
  }
}

resource "aws_ecr_repository" "lunch_api" {
  name                 = "school/lunch-api"
  image_tag_mutability = "IMMUTABLE"                          # a tag can never be re-pushed with different bits
  image_scanning_configuration { scan_on_push = true }
}
```

📝 `live/dev/platform/providers.tf`

```hcl
data "aws_eks_cluster" "school" { name = "school-dev" }

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.school.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.school.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", "school-dev"]
    }
  }
}
```

📝 The one manifest every EKS cluster needs before Postgres/Kafka: a `gp3` default StorageClass (put it in `platform/` with `kubernetes_manifest`, or a tiny chart)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations: { storageclass.kubernetes.io/is-default-class: "true" }
provisioner: ebs.csi.aws.com
parameters: { type: gp3, encrypted: "true" }
volumeBindingMode: WaitForFirstConsumer          # pick the AZ where the pod lands
allowVolumeExpansion: true
```

EKS gotchas: ⚠️ PVCs `Pending` forever = EBS CSI add-on without an IAM role, or no default StorageClass (the legacy in-tree `gp2` class may still be marked default — remove the annotation). ⚠️ "Too many pods" on small instances: VPC CNI limits pods per node by ENI count; enable prefix delegation or use bigger nodes. ⚠️ Node groups don't auto-scale by themselves; install Karpenter (chart `oci://public.ecr.aws/karpenter/karpenter`) or Cluster Autoscaler. ⚠️ Pushing to ECR needs `aws ecr get-login-password | docker login`; images must exist in the *same region* as the cluster (or use replication).

### Google GKE

📝 `live/dev/cluster/main.tf` (Autopilot: Google runs the nodes; you pay per pod request)

```hcl
terraform {
  required_providers { google = { source = "hashicorp/google", version = "~> 7.0" } }
}
provider "google" {
  project = "school-dev-123456"
  region  = "us-central1"
}

resource "google_compute_network" "school" {
  name                    = "school-dev"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "school" {
  name          = "school-dev-nodes"
  network       = google_compute_network.school.id
  ip_cidr_range = "10.10.0.0/20"
  region        = "us-central1"
  secondary_ip_range { range_name = "pods",     ip_cidr_range = "10.20.0.0/16" }
  secondary_ip_range { range_name = "services", ip_cidr_range = "10.30.0.0/20" }
}

resource "google_container_cluster" "school" {
  name                = "school-dev"
  location            = "us-central1"            # regional = 3 zones
  enable_autopilot    = true
  deletion_protection = false                    # true in prod

  network    = google_compute_network.school.id
  subnetwork = google_compute_subnetwork.school.id
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }
  release_channel { channel = "REGULAR" }
  gateway_api_config { channel = "CHANNEL_STANDARD" }   # built-in Gateway API controller
}

resource "google_artifact_registry_repository" "school" {
  location      = "us-central1"
  repository_id = "school"
  format        = "DOCKER"
}
```

📝 `live/dev/platform/providers.tf`

```hcl
data "google_client_config" "default" {}
data "google_container_cluster" "school" {
  name     = "school-dev"
  location = "us-central1"
}

provider "helm" {
  kubernetes = {
    host                   = "https://${data.google_container_cluster.school.endpoint}"
    token                  = data.google_client_config.default.access_token   # short-lived; from gcloud auth / CI identity
    cluster_ca_certificate = base64decode(data.google_container_cluster.school.master_auth[0].cluster_ca_certificate)
  }
}
```

Autopilot vs Standard:

| | Autopilot | Standard |
|---|---|---|
| Pros | No nodes to manage, pay per pod, hardened defaults, Workload Identity on | Full control (node sizes, privileged pods, DaemonSets, GPUs, custom kernels) |
| Cons | Rejects privileged containers and host mounts; enforces minimum requests and rounds them up; some operators need tweaks | You size, patch and pay for nodes even when idle |
| Use when | Web apps, APIs, most operators (CNPG, Strimzi work with appropriate resources) | Kafka at high throughput with local SSDs, GPU workloads, anything needing host access |

GKE gotchas: ⚠️ `kubectl` needs the `gke-gcloud-auth-plugin` component (`gcloud components install gke-gcloud-auth-plugin`). ⚠️ Autopilot bumps pod requests to its minimums (e.g. 250m CPU / 512 MiB per pod) — your bill and your `helm diff` both notice. ⚠️ Regional clusters cost a control-plane fee per cluster; zonal is cheaper for dev. ⚠️ Deleting a cluster with `deletion_protection = true` (the default) fails until you flip it and apply first.

### Workload identity in one picture (all three clouds)

```text
Pod ──uses──▶ ServiceAccount (annotation: which cloud identity)
                │
                ▼ signed Kubernetes token
      Cloud IAM trusts the cluster's OIDC issuer ──▶ short-lived cloud credential
                │
                ▼
      CNPG backups → object storage, ESO → secret manager, apps → queues/buckets
```

🏫 The pod's badge (ServiceAccount) is recognized by the landlord's security desk (cloud IAM), so no one carries a photocopied master key (a stored access key) around.

---

<a id="part-15"></a>
## Part 15 — Putting it all together

### Install order (and why)

```text
1. cluster/      Terraform: the building, node pools, registry, state backend already exists
2. platform/     Terraform helm_release, in this order (depends_on):
     a. Gateway API implementation (Envoy Gateway / cloud gateway)  ─┐ needed by cert-manager's Gateway support
     b. cert-manager (+ ClusterIssuer)                                ─┘
     c. External Secrets Operator (+ ClusterSecretStore)
     d. CloudNativePG operator
     e. Strimzi operator
     f. Keycloak operator (raw manifests)
     g. Monitoring (kube-prometheus-stack) — optional but do it
3. apps/         Terraform or Argo CD, in this order:
     a. namespaces + the shared Gateway + ExternalSecrets that create app Secrets
     b. school-postgres ×2 (keycloak-db, grades-db)
     c. school-keycloak (waits for its DB)
     d. school-kafka (+ Connect, Kafka UI, schema registry)
     e. lunch-api → grade-alerts → report-bot
```

🛒 You don't stock shelves before the building has power, and you don't open the registers before the shelves are stocked.

### The shared Gateway (one front door for the whole school)

📝 `charts/school-gateway/templates/gateway.yaml` — installed once in `apps/` (namespace `gateways`)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: {{ .Values.gatewayClassName }}          # "eg" for Envoy Gateway; a cloud class on GKE/AKS/EKS
spec:
  controllerName: {{ .Values.controllerName }}  # gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: school
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod   # cert-manager issues a cert per HTTPS listener hostname
spec:
  gatewayClassName: {{ .Values.gatewayClassName }}
  listeners:
    - name: http                                 # HTTP-01 challenges + redirects
      protocol: HTTP
      port: 80
      allowedRoutes: { namespaces: { from: All } }
    {{- range .Values.hosts }}
    - name: https-{{ . | replace "." "-" }}
      protocol: HTTPS
      port: 443
      hostname: {{ . | quote }}
      tls:
        mode: Terminate
        certificateRefs: [{ name: {{ . | replace "." "-" }}-tls }]
      allowedRoutes: { namespaces: { from: All } }   # HTTPRoutes in keycloak/school/kafka namespaces may attach
    {{- end }}
```

```yaml
# values.yaml
gatewayClassName: eg
controllerName: gateway.envoyproxy.io/gatewayclass-controller
hosts: [auth.school.example.com, lunch.school.example.com, alerts.school.example.com, kafka-ui.school.example.com]
```

📝 `charts/school-gateway/templates/redirect.yaml` — plain HTTP becomes a 301 to HTTPS

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https
spec:
  parentRefs: [{ name: school, sectionName: http }]
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect: { scheme: https, statusCode: 301 }
```

The `HTTPRoute`s in Parts 10 and 12 attach with `sectionName: https-<host-with-dashes>`, matching the listener names generated above. ⚠️ If a route omits `sectionName`, it also attaches to the `http` listener, and because a route with a specific hostname beats the redirect route (which has none), your app would quietly be served over plain HTTP. Always name the listener. Point DNS at the Gateway's address: `kubectl get gateway school -n gateways` shows it.

### Environment values, side by side

| Setting | dev (kind) | staging (cloud) | prod (cloud) |
|---|---|---|---|
| `school-postgres` instances | 1 | 2 | 3 + backups enabled |
| `school-kafka` `dev` | true (1 node) | false (3+3, small) | false (3 controllers, 3–6 brokers, `deleteClaim: false`) |
| `school-keycloak` instances | 1, `hostname=http://localhost:8080`, `devMode=true` | 2, real hostname | 2–3, real hostname, `devMode=false` |
| Apps `replicaCount` | 1 | 2 | 2+ with HPA and PDB |
| Secrets | `kubectl create secret` by hand | External Secrets Operator | External Secrets Operator + rotation |
| Gateway | `route.enabled=false`, port-forward | Envoy Gateway / cloud gateway, Let's Encrypt staging | Cloud gateway, Let's Encrypt prod, WAF |

### CI/CD: a GitHub Actions workflow that builds, pushes, and deploys

📝 `.github/workflows/lunch-api.yaml`

```yaml
name: lunch-api
on:
  push:
    branches: [main]
    paths: [apps/lunch-api/**, charts/school-app/**]
permissions:
  contents: read
  packages: write
  id-token: write                      # OIDC → cloud credentials, no long-lived keys in GitHub
jobs:
  build-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
      - id: meta
        run: echo "tag=2.0.${{ github.run_number }}" >> "$GITHUB_OUTPUT"
      - uses: docker/build-push-action@v6
        with:
          context: apps/lunch-api
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ghcr.io/school/lunch-api:${{ steps.meta.outputs.tag }}
      - uses: azure/setup-helm@v4               # installs a pinned Helm CLI
        with: { version: v4.3.0 }
      - name: Lint and render
        run: |
          helm lint charts/school-app --strict
          helm template lunch-api charts/school-app -f apps/lunch-api/values.yaml --set image.tag=${{ steps.meta.outputs.tag }} > /tmp/rendered.yaml
      - uses: azure/login@v2                     # or aws-actions/configure-aws-credentials / google-github-actions/auth
        with: { client-id: ${{ secrets.AZURE_CLIENT_ID }}, tenant-id: ${{ secrets.AZURE_TENANT_ID }}, subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }} }
      - run: az aks get-credentials -g rg-school-staging -n aks-school-staging && kubelogin convert-kubeconfig -l azurecli
      - name: Deploy
        run: |
          helm plugin install https://github.com/databus23/helm-diff || true
          helm diff upgrade lunch-api charts/school-app -n school -f apps/lunch-api/values.yaml --set image.tag=${{ steps.meta.outputs.tag }}
          helm upgrade --install lunch-api charts/school-app -n school \
            -f apps/lunch-api/values.yaml --set image.tag=${{ steps.meta.outputs.tag }} \
            --wait --timeout 10m --rollback-on-failure
          helm test lunch-api -n school
```

If Terraform owns the `apps/` layer instead, the last step becomes `terraform apply -var lunch_api_image_tag=…`; if Argo CD owns it, the workflow just commits the new tag to the values file and Argo CD does the rest.

### GitOps in one paragraph

With **Argo CD** or **Flux**, nothing in CI touches the cluster. A controller inside the cluster watches a Git repo, renders your charts (`helm template` under the hood), applies them, and keeps re-applying — so a hand-made `kubectl edit` gets reverted, and the Git log is your audit trail. Terraform installs Argo CD in `platform/`; an `Application`/`ApplicationSet` per chart replaces the `helm_release`s in `apps/`. Trade-offs: Helm hooks become sync phases, `lookup` doesn't work (no cluster access during render), and secrets need ESO/SOPS since values are in Git.

---

<a id="part-16"></a>
## Part 16 — Troubleshooting toolbox

🏫 When a classroom is in chaos, the principal doesn't guess — they walk over and look. These are the "walk over and look" commands.

```bash
# Where am I?
kubectl config current-context && kubectl get nodes -o wide

# What did Helm do?
helm list -A                                   # STATUS: deployed / failed / pending-upgrade?
helm status <rel> -n <ns>
helm history <rel> -n <ns>
helm get manifest <rel> -n <ns> | kubectl apply --dry-run=server -f -   # would the cluster even accept it?

# Why isn't my pod running?
kubectl get pods -n <ns> -o wide
kubectl describe pod <pod> -n <ns>             # Events at the bottom: ImagePullBackOff? Pending (no node/PVC)? probe failures?
kubectl logs <pod> -n <ns> --previous          # logs of the container that just crashed
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -20

# Disks
kubectl get pvc,pv -n <ns>                     # Pending = no StorageClass or CSI driver problem
kubectl get storageclass

# Networking
kubectl get svc,endpointslices -n <ns>         # a Service with no endpoints = selector labels don't match / pods not Ready
kubectl run tmp -it --rm --image=curlimages/curl -n <ns> -- curl -sv http://lunch-api-school-app:8080/actuator/health
kubectl get gateway,httproute -A               # Accepted/Programmed conditions

# Operators
kubectl get cluster -n <ns>                    # CNPG
kubectl cnpg status keycloak-db -n <ns>
kubectl get kafka,kafkanodepool,kafkatopic,kafkauser -n kafka
kubectl get keycloak,keycloakrealmimport -n keycloak
kubectl logs -n cnpg-system deploy/cnpg-cloudnative-pg | tail -50
kubectl logs -n kafka deploy/strimzi-cluster-operator | grep -i error | tail

# Resources
kubectl top pods -n <ns>                       # needs metrics-server
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].lastState}'   # OOMKilled?

# Helm rendering problems
helm template <rel> ./chart -f values.yaml --debug 2>&1 | head -50
helm lint ./chart --strict
```

Decoding the five most common pod states:

| State | Meaning | First thing to check |
|---|---|---|
| `Pending` | Nowhere to run | `describe`: insufficient cpu/memory, PVC Pending, taints/tolerations |
| `ImagePullBackOff` | Can't fetch the image | tag typo, private registry auth, wrong architecture, Bitnami legacy move |
| `CrashLoopBackOff` | Starts then dies | `logs --previous`; missing env var/Secret; wrong command; DB unreachable |
| `Running` but `0/1 READY` | Readiness probe failing | probe path/port; app still starting; downstream dependency down |
| `OOMKilled` | Used more memory than its limit | raise limit, fix JVM flags, check for leaks |

---

<a id="part-17"></a>
## Part 17 — Glossary and field-trip exercises

### Glossary (the 30-second version)

- **Chart** — recipe. **Values** — the tweakable amounts. **Release** — a cooked dish. **Revision** — attempt number. **Repository/registry** — where recipes live.
- **Template** — YAML with `{{ }}` blanks. **Helper** — a named reusable snippet. **Hook** — "run this before/after". **Sub-chart** — a recipe inside a recipe.
- **CRD** — a new kind of form. **Operator** — the department head who processes that form. **CR** — one filled-in form (`Cluster`, `Kafka`, `Keycloak`).
- **OIDC** — the standard hall pass. **Issuer** — the office that stamped it. **JWKS** — the stamp samples. **Realm** — one school's worth of users. **Client** — an app that accepts passes.
- **Topic/partition/consumer group** — mailbox / slots / a team sorting mail. **KRaft** — Kafka running without ZooKeeper. **Connect** — the mail robot. **Schema registry** — the official forms.
- **Terraform state** — the inventory ledger. **Backend** — where the ledger is kept. **Lock** — the "someone is editing" sign. **Root module** — one ledger, one `apply`.
- **Workload identity** — the pod's badge that the cloud's security desk recognizes.
- **Gateway API** — the modern front door, replacing Ingress (ingress-nginx retired March 2026).

### Field trips (do these in order)

1. **Part 1 again, but with Podman.** Note every place the commands differ.
2. **Break it on purpose:** in `hello-school/values.yaml` set `image.tag: "does-not-exist"`, upgrade with `--wait --timeout 1m --rollback-on-failure`, and watch Helm roll back. Then look at `helm history`.
3. **Values surgery:** write `values/dev.yaml` and `values/prod.yaml` for `hello-school`; render both with `helm template` and `diff` the outputs.
4. **Write the schema:** add a `values.schema.json` that rejects `replicaCount: -1`. Prove it with `helm lint`.
5. **Postgres:** install `school-postgres` with 1 instance, create a table, `helm uninstall`, reinstall with the same name — is your table still there? (Yes: PVCs survived.) Now delete the PVC and repeat.
6. **Keycloak:** import the realm, get a token with curl, decode it at jwt.io, and find `iss`, `aud`, `realm_access.roles`.
7. **Kafka:** produce 10 lunch orders, then start a second consumer in the same group. Who gets which partitions? (`kafka-consumer-groups.sh --describe`)
8. **The issuer gotcha, live:** set `OIDC_JWK_SET_URI` in `lunch-api` to the *public* URL on your laptop and watch it fail; switch back.
9. **Terraform:** put `hello-school` in a `helm_release`, `terraform apply`, then change a value with plain `helm upgrade` and run `terraform plan`. What does Terraform want to do?
10. **Cloud:** stand up one of the three clusters with the `cluster/` root module, then destroy it before bedtime (they cost money).

### Where to read next

- Helm docs: https://helm.sh/docs — especially "Chart Best Practices" and "Helm 4 Overview"
- Artifact Hub (find charts, see their values and security reports): https://artifacthub.io
- CloudNativePG: https://cloudnative-pg.io/docs
- Strimzi: https://strimzi.io/docs
- Keycloak operator: https://www.keycloak.org/guides#operator
- Gateway API: https://gateway-api.sigs.k8s.io ; Envoy Gateway: https://gateway.envoyproxy.io
- Terraform Helm provider: https://registry.terraform.io/providers/hashicorp/helm
- External Secrets Operator: https://external-secrets.io
- Kubernetes pod security standards: https://kubernetes.io/docs/concepts/security/pod-security-standards

*Versions named in this tutorial (Helm 4.3, Strimzi 1.2, Keycloak 26.7, Helm provider 3.2, etc.) were current in September 2026. Always run `helm search repo <chart> --versions` and read the release notes before pinning.*
