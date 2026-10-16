# Jenkins on Kubernetes with Helm, Istio, Agent Pods, JCasC, Seed Jobs & PostgreSQL

**A complete, beginner-friendly tutorial (October 2026 edition)**

> **Who is this for?** Anyone who can type commands in a terminal and has a Kubernetes cluster to play with. Every idea is explained from scratch, so you do not need to be an expert. If you already know Jenkins, skip to the parts you need.

---

## Table of contents

1. [Background: what are all these things?](#1-background-what-are-all-these-things)
2. [Helm background: what it is, how it works, and how the Jenkins chart uses it](#2-helm-background-what-it-is-how-it-works-and-how-the-jenkins-chart-uses-it)
3. [Quick start: one working example in 10 steps](#3-quick-start-one-working-example-in-10-steps)
4. [The Helm chart in depth: every important field explained](#4-the-helm-chart-in-depth-every-important-field-explained)
5. [Istio: Gateway, VirtualService, and the agent-pod trap](#5-istio-gateway-virtualservice-and-the-agent-pod-trap)
6. [Agent pods: how Jenkins builds things inside Kubernetes](#6-agent-pods-how-jenkins-builds-things-inside-kubernetes)
7. [Configuration as Code (JCasC): environments, credentials, settings](#7-configuration-as-code-jcasc-environments-credentials-settings)
8. [Admin, users, and permissions](#8-admin-users-and-permissions)
9. [Default jobs and pipelines with Job DSL](#9-default-jobs-and-pipelines-with-job-dsl)
10. [PostgreSQL: deploying it, using it in jobs, and upgrading it](#10-postgresql-deploying-it-using-it-in-jobs-and-upgrading-it)
11. [Upgrading: chart, Jenkins, plugins, Java](#11-upgrading-chart-jenkins-plugins-java)
12. [Testing your setup](#12-testing-your-setup)
13. [Key gotchas (read this twice)](#13-key-gotchas-read-this-twice)
14. [Best practices checklist](#14-best-practices-checklist)
15. [Pros and cons of every big choice](#15-pros-and-cons-of-every-big-choice)
16. [Complete reference `values.yaml`](#16-complete-reference-valuesyaml)
17. [Cheat sheet of commands](#17-cheat-sheet-of-commands)

---

## 1. Background: what are all these things?

Think of building software like running a bakery.

| Thing | What it really is | Bakery version |
|---|---|---|
| **Jenkins** | A program that runs jobs for you: compile code, run tests, build container images, deploy. It has a web page you click around in and a huge plugin store. | The head baker who reads recipes and tells helpers what to do. |
| **Kubernetes** | A system that runs containers (tiny packaged programs) across many computers and keeps them alive. | The kitchen with lots of ovens and counters. |
| **Helm** | A package manager for Kubernetes. A **chart** is a template bundle; a **release** is one installed copy; **values** are the knobs you turn. | A recipe box. The chart is the recipe, values are "double the sugar". |
| **Istio** | A "service mesh": it puts a tiny proxy next to every pod so you can control traffic, add TLS, and route web requests. A **Gateway** is the front door; a **VirtualService** says "requests for jenkins.example.com go to the Jenkins pod". | The shop's front door and the sign that says which counter to go to. |
| **Jenkins controller** | The main Jenkins pod (web UI, job definitions, scheduling). Old name: "master". | Head baker. |
| **Jenkins agent** | A worker that runs a job. In Kubernetes, each build gets its own **agent pod** that is created, does the work, and is deleted. | A temporary helper hired per cake. |
| **JCasC** | *Jenkins Configuration as Code*. A YAML file that configures everything (security, credentials, tools, clouds) so you never click through settings pages. | The written house rules. |
| **Job DSL** | A Groovy script that *creates jobs*. Combined with JCasC, Jenkins can start with all your jobs already present. | A list of standard recipes every new baker must know. |
| **Pipeline / Jenkinsfile** | A job written as code (`stages`, `steps`) usually stored in your repository. | The recipe itself. |
| **PostgreSQL** | A popular open-source SQL database. **Jenkins does not use a database for itself** (it stores everything in files inside `JENKINS_HOME`). You usually want Postgres for *the apps you test and deploy*, for tools next to Jenkins (SonarQube, Nexus, etc.), or as a test database inside agent pods. | The walk-in fridge the recipes need, not the baker's notebook. |

### How the pieces fit together

```
Internet ──▶ Istio Gateway ──▶ VirtualService ──▶ Service "jenkins" :8080 ──▶ Jenkins controller pod
                                                                                   │
                                                                                   │ creates pods via Kubernetes API
                                                                                   ▼
                                                                        agent pod 1  agent pod 2  agent pod 3
                                                                        (jnlp + build containers)
                                                                                   │
                                                                                   ▼
                                                                        PostgreSQL (CloudNativePG cluster)
```

### Versions used in this tutorial (verify before you copy)

- Helm chart: `jenkins/jenkins` **5.9.x** (the 5.x series; OCI install supported since 5.6.0).
- Jenkins: **2.568.x LTS** (released July 2026) or newer. Important: **Jenkins 2.555.1 and later require Java 21 or 25** – Java 17 images no longer work.
- Istio: 1.2x, any recent release.
- PostgreSQL: 17 (16 for the upgrade demo).
- Kubernetes: 1.30+.

Check the real latest numbers with:

```bash
helm search repo jenkins/jenkins --versions | head
```

---

## 2. Helm background: what it is, how it works, and how the Jenkins chart uses it

### 2.1 What problem does Helm solve?

Installing anything real on Kubernetes means writing many YAML files: a Deployment or StatefulSet, a Service, a ServiceAccount, Roles, ConfigMaps, Secrets, a PersistentVolumeClaim, probes, and more. Jenkins alone needs about fifteen. Keeping those files in sync by hand, copying them for dev/staging/prod, and remembering what you changed last month quickly becomes a mess.

Helm fixes this by treating an application as a **package**:

- Someone (the chart maintainers) writes the YAML once as **templates** with placeholders.
- You supply only the **values** that differ for you (hostname, image tag, memory).
- Helm merges them, sends the result to Kubernetes, and remembers what it sent so it can upgrade, diff, and roll back later.

Think of it as `apt`/`brew`/`npm` for Kubernetes: `helm install jenkins jenkins/jenkins` is the Kubernetes equivalent of `apt install jenkins`.

### 2.2 Vocabulary

| Term | Meaning | In this tutorial |
|---|---|---|
| **Chart** | A folder (or `.tgz`) of templates + metadata. The *recipe*. | `jenkins/jenkins` |
| **Chart version** | SemVer of the chart itself (`version:` in `Chart.yaml`). Bumps whenever templates or defaults change. | `5.9.40` |
| **App version** | Version of the software the chart installs (`appVersion:`). Informational only; the chart uses it as the default image tag. | `2.568.x` |
| **Repository** | An HTTP index of charts (`index.yaml` + tarballs). | `https://charts.jenkins.io` |
| **OCI registry** | Charts stored like container images (`oci://ghcr.io/...`). The modern alternative to repos. | `oci://ghcr.io/jenkinsci/helm-charts/jenkins` |
| **Values** | Your configuration, YAML. Defaults live in the chart's `values.yaml`; you override with `-f` files or `--set`. | `values.yaml`, `values-prod.yaml` |
| **Release** | One installed copy of a chart in one namespace, with a name. | release `jenkins` in namespace `jenkins` |
| **Revision** | Each install/upgrade/rollback increments the release's revision number. | `helm history jenkins` |
| **Hook** | A manifest that runs at a lifecycle point (`pre-install`, `post-upgrade`, `test`). | the chart's `helm test` pod |
| **Subchart / dependency** | A chart bundled inside another (`Chart.yaml` → `dependencies:`). | not used by the Jenkins chart |
| **Library chart** | Shared template helpers, not installable alone. | – |

### 2.3 A little history: Helm 2 vs Helm 3

- **Helm 2 (2016–2020)** needed a cluster-side component called **Tiller** with cluster-admin rights. It was a security headache and is dead. Any tutorial mentioning `helm init` or Tiller is obsolete.
- **Helm 3 (2019→)** is a pure client; it talks to the Kubernetes API with *your* kubeconfig and stores release state in Secrets in the release namespace (`sh.helm.release.v1.<name>.v<revision>`). Charts use `apiVersion: v2` in `Chart.yaml`. The Jenkins chart requires Helm 3.
- **Helm 3.8+** added first-class OCI support; the Jenkins chart publishes to GHCR since chart 5.6.0.
- **Helm 4 (late 2025)** is the next major; the CLI is largely compatible, but check the release notes if your distribution ships it.

### 2.4 What is inside a chart

```
jenkins/
├── Chart.yaml            # name, version, appVersion, description, maintainers
├── values.yaml           # all defaults, heavily commented (this is your reference)
├── VALUES.md             # generated table of every value
├── CHANGELOG.md          # what changed per chart version
├── UPGRADING.md          # breaking-change notes for 2.x→3.x→4.x→5.x
├── README.md
└── templates/
    ├── _helpers.tpl      # named template functions (fullname, labels, …)
    ├── jenkins-controller-statefulset.yaml
    ├── jenkins-controller-svc.yaml
    ├── jenkins-agent-svc.yaml
    ├── config.yaml       # ConfigMap holding plugins list + apply_config.sh
    ├── jcasc-config.yaml # one ConfigMap per JCasC script
    ├── secret.yaml, secret-additional.yaml, secret-claims.yaml
    ├── rbac.yaml, service-account.yaml, service-account-agent.yaml
    ├── home-pvc.yaml
    ├── networkpolicy.yaml
    ├── jenkins-controller-ingress.yaml, ...-servicemonitor.yaml, ...-networkpolicy.yaml
    ├── tests/test-config.yaml, tests/jenkins-test.yaml   # helm test hook
    └── NOTES.txt         # the text printed after install
```

Read any of it with `helm pull jenkins/jenkins --untar` – it is the fastest way to answer "what does field X actually do?".

### 2.5 How templating works

Templates are Kubernetes YAML with **Go template** expressions in `{{ }}`. A simplified slice of the controller StatefulSet:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ template "jenkins.fullname" . }}
  namespace: {{ template "jenkins.namespace" . }}
  labels:
    {{- include "jenkins.labels" . | nindent 4 }}
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: jenkins
          image: "{{ .Values.controller.image.repository }}:{{ .Values.controller.image.tag | default .Chart.AppVersion }}-{{ .Values.controller.image.tagLabel }}"
          resources:
            {{- toYaml .Values.controller.resources | nindent 12 }}
          env:
            - name: JAVA_OPTS
              value: {{ tpl .Values.controller.javaOpts . | quote }}
{{- if .Values.persistence.enabled }}
  volumeClaimTemplates: ...
{{- end }}
```

The main objects available inside templates:

| Object | Contains |
|---|---|
| `.Values` | Your merged values (chart defaults ← `-f` files ← `--set`). |
| `.Release` | `.Name`, `.Namespace`, `.Revision`, `.IsInstall`, `.IsUpgrade`. |
| `.Chart` | `Chart.yaml` fields (`.Chart.AppVersion`, `.Chart.Version`). |
| `.Capabilities` | Kubernetes version and available APIs (`.Capabilities.APIVersions.Has "monitoring.coreos.com/v1"`). |
| `.Files` | Non-template files in the chart. |

Useful functions you'll see in the Jenkins chart: `include`/`template` (call a helper), `default`, `quote`, `toYaml`, `nindent`, `tpl` (render a value that itself contains `{{ }}` – that is why `controller.ingress.hostName`, `controller.admin.existingSecret` and, since 5.9.39, `controller.javaOpts` can reference other values), `required`, `lookup` (read a live object), `b64enc`, `sha256sum` (used to add a checksum annotation so pods restart when a ConfigMap changes).

### 2.6 Values precedence (who wins)

From weakest to strongest:

1. The chart's own `values.yaml`.
2. `-f values.yaml`
3. `-f values-prod.yaml` (later files override earlier ones, key by key, **deep-merged for maps, replaced for lists**).
4. `--set key=value` / `--set-string` / `--set-file`.
5. `--reuse-values` (on upgrade) re-injects the previous release's values underneath whatever you pass now – a frequent source of "why is that old setting still here?".

The list-vs-map rule matters for Jenkins: `controller.installPlugins` is a **list**, so an overlay file that sets it *replaces* the whole list; `controller.JCasC.configScripts` is a **map**, so overlays can add or override individual scripts and keep the rest.

Inspect the result before and after:

```bash
helm template jenkins jenkins/jenkins -f values.yaml > rendered.yaml   # render locally, no cluster needed
helm install jenkins jenkins/jenkins -f values.yaml --dry-run --debug  # render against the cluster, don't apply
helm get values jenkins -n jenkins          # values you supplied
helm get values jenkins -n jenkins --all    # supplied + chart defaults
helm get manifest jenkins -n jenkins        # exactly what was applied
```

### 2.7 The release lifecycle

```
helm install  ──▶ revision 1 ──▶ helm upgrade ──▶ revision 2 ──▶ helm upgrade ──▶ revision 3
                                                                      │
                                                   helm rollback 2 ──▶ revision 4 (same manifests as 2)
```

- **install**: renders templates, runs `pre-install` hooks, creates objects, runs `post-install` hooks, stores revision 1.
- **upgrade**: renders again, computes a **three-way merge** between the last manifest, the new manifest, and the live object (so manual `kubectl edit` changes that don't conflict survive), applies, stores a new revision. `--atomic` rolls back automatically on failure; `--wait` blocks until pods are Ready; `--timeout` bounds that.
- **rollback**: re-applies an earlier revision's *manifests*. It does **not** touch data in PVCs – your `JENKINS_HOME`, already-upgraded plugins, or a Postgres data directory stay as they are. This is the single most misunderstood thing about Helm.
- **uninstall**: deletes everything the release created **except** objects annotated `helm.sh/resource-policy: keep` (we put that on the Jenkins PVC). `--keep-history` retains the release record so you can `helm rollback` after an uninstall.
- **history / status**: `helm history`, `helm status`, `helm list -A`.

Helm stores each revision as a Secret in the namespace. Large charts with many revisions bloat etcd; cap with `--history-max 10` (default is 10 in Helm 3).

### 2.8 Hooks and tests

The Jenkins chart ships a `helm test` hook: a pod that `curl`s the login page. Hooks are ordinary manifests with annotations:

```yaml
metadata:
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
    "helm.sh/hook-weight": "0"
```

Other hook points: `pre-install`, `post-install`, `pre-upgrade`, `post-upgrade`, `pre-rollback`, `post-rollback`, `pre-delete`, `post-delete`. A common pattern for your own wrapper chart is a `post-upgrade` Job that triggers the Jenkins `seed` job through the API.

### 2.9 Repositories vs OCI

| | HTTP repository | OCI registry |
|---|---|---|
| Add | `helm repo add jenkins https://charts.jenkins.io` + `helm repo update` | none – reference directly |
| Install | `helm install jenkins jenkins/jenkins --version 5.9.40` | `helm install jenkins oci://ghcr.io/jenkinsci/helm-charts/jenkins --version 5.9.40` |
| Pros | Widely supported, `helm search repo` works | Same auth/proxy/scanning as container images, works in air-gapped registries (Harbor, ECR, ACR), immutable digests, signable with cosign |
| Cons | Separate credential handling, index can get huge | No `helm search`; need Helm ≥ 3.8 |

Mirror into your own registry for production: `helm pull jenkins/jenkins --version 5.9.40` then `helm push jenkins-5.9.40.tgz oci://registry.corp/charts`.

### 2.10 Chart versioning and what a bump means

The Jenkins chart follows SemVer strictly:

- **Patch** (5.9.39 → 5.9.40): plugin/image default bumps, template fixes. Safe.
- **Minor** (5.8 → 5.9): new values, new features. Backward compatible.
- **Major** (4.x → 5.x): removed or renamed values. `UPGRADING.md` lists them; the chart's `checkDeprecation: true` makes `helm upgrade` *fail* with a clear message if you still use a removed key (for example the old `master.*` block from 2.x or `controller.backup` from 4.x).

Always read the changelog across every version you skip, because a patch bump can still raise the default Jenkins image to a new LTS line (and in 2026 that can mean a Java 17 → 21 change).

### 2.11 Where secrets go

Helm is not a secrets manager. Choices, best first:

1. **Reference existing Secrets** (`controller.admin.existingSecret`, `controller.additionalExistingSecrets`) created by External Secrets Operator, Sealed Secrets, or your platform.
2. **Secrets Store CSI driver** (`controller.secretClaims`) for Vault / AWS / Azure / GCP.
3. **helm-secrets plugin + SOPS**: encrypted `secrets.yaml` files decrypted at `helm upgrade` time.
4. Plain values files – only for throwaway labs.

Never commit a values file containing `admin.password`.

### 2.12 Tooling around Helm you will meet

| Tool | What it adds |
|---|---|
| `helm-diff` plugin | `helm diff upgrade …` shows a coloured diff before you apply. Install it today. |
| `helm lint` / `helm template` + `kubeconform` | Validate a chart and its rendered output in CI. |
| **Helmfile** | Declarative list of many releases with environments; one `helmfile apply` installs Istio + Jenkins + CNPG in order. |
| **Argo CD / Flux** | GitOps: the cluster pulls your `values.yaml` from git and keeps the release in sync. Flux's `HelmRelease` CRD and Argo's Application both support `valuesFiles`, OCI sources, and post-sync hooks. The Jenkins chart has explicit fixes for Flux revision reconciliation. |
| **Kustomize** | Not a replacement – many teams render Helm then patch with Kustomize (`helmCharts:` field or Argo's "Helm + Kustomize" mode). |
| **Chart-testing (`ct`)** | Lints and installs charts in CI; what the Jenkins chart repo uses. |
| `helm-unittest` | Unit tests for templates. |

### 2.13 Helm vs the alternatives for installing Jenkins

| Approach | Pros | Cons |
|---|---|---|
| **Official Helm chart** (this tutorial) | Maintained by the Jenkins project, ~15 manifests for you, JCasC built in, SemVer changelog, GitOps-friendly | Still a single controller; you own backups |
| Raw `kubectl apply` manifests | Total control, no tooling | You maintain everything; no versioning/rollback |
| Kustomize only | Simple patching, in kubectl | No templating logic, no release history |
| **Jenkins Kubernetes Operator** | CRD-driven, reconciles drift, restores from backup | Smaller community, more opinionated, lags newer Jenkins features |
| CloudBees CI (commercial) | HA controllers, support, RBAC at scale | Licence cost |

### 2.14 Helm best practices for this setup

- One **git repo per environment set**: `values.yaml` + overlays + `istio.yaml` + `app-db.yaml`; the Helm release is driven only from git (ideally by Argo CD/Flux).
- Always pass `--version`; never float on "latest chart".
- Run `helm diff` in a pull request pipeline (yes, a Jenkins job can lint the Jenkins values file).
- Use `helm upgrade --install --atomic --wait --timeout 15m` in automation so a failed upgrade self-rolls-back.
- Keep `checkDeprecation: true`.
- Annotate stateful objects with `helm.sh/resource-policy: keep`.
- Store your own wrapper/umbrella chart in OCI if you need to bundle Jenkins with your pod-template ConfigMaps, NetworkPolicies, or Istio resources: a 10-line `Chart.yaml` with `dependencies: [{ name: jenkins, version: 5.9.40, repository: https://charts.jenkins.io }]` plus your extra templates.

---

## 3. Quick start: one working example in 10 steps

Goal: a Jenkins reachable at `https://jenkins.example.com` through Istio, with Kubernetes agent pods, an admin user, two normal users, a seed job that creates a sample pipeline, and a Postgres database the pipeline talks to.

### Step 1 – Prerequisites

```bash
kubectl version --short        # cluster reachable
helm version                   # Helm 3.12+
istioctl version               # Istio installed (istioctl install --set profile=default)
```

If you don't have a cluster: `kind create cluster` or `minikube start --cpus 4 --memory 8g` works fine for learning.

### Step 2 – Create the namespace and turn on Istio injection

```bash
kubectl create namespace jenkins
kubectl label namespace jenkins istio-injection=enabled
```

This label means every pod in `jenkins` gets an Istio sidecar proxy automatically. We will *turn it off again for agent pods* later (see the gotcha in section 5).

### Step 3 – Add the Helm repo

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update
# or, if your company blocks Helm repos, use OCI:
# helm pull oci://ghcr.io/jenkinsci/helm-charts/jenkins --version 5.9.40
```

### Step 4 – Create the admin secret (never put passwords in values files)

```bash
kubectl -n jenkins create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password="$(openssl rand -base64 24)"
```

The chart looks for exactly these two keys: `jenkins-admin-user` and `jenkins-admin-password` (you can rename the keys with `controller.admin.userKey` / `passwordKey`).

### Step 5 – Write `values.yaml`

Save this as `values.yaml`. It is explained line by line in section 4; for now just notice the comments.

```yaml
controller:
  image:
    repository: docker.io/jenkins/jenkins
    tag: "2.568.3-jdk21"          # Java 21 is REQUIRED since 2.555.1
  jenkinsUrl: https://jenkins.example.com
  admin:
    existingSecret: jenkins-admin  # created in Step 4
  serviceType: ClusterIP           # Istio will route to the Service
  ingress:
    enabled: false                 # we use an Istio VirtualService instead

  installPlugins:
    - kubernetes
    - workflow-aggregator
    - git
    - configuration-as-code
  additionalPlugins:
    - job-dsl
    - matrix-auth
    - credentials-binding
    - pipeline-stage-view
    - prometheus
  installLatestPlugins: true       # fine for learning; pin versions in production

  resources:
    requests: { cpu: "500m", memory: "1Gi" }
    limits:   { cpu: "2",    memory: "4Gi" }
  javaOpts: "-XX:MaxRAMPercentage=70 -Djenkins.install.runSetupWizard=false"

  sidecars:
    configAutoReload:
      enabled: true                # live-reload JCasC on changes

  JCasC:
    defaultConfig: true
    securityRealm: |-
      local:
        allowsSignup: false
        users:
          - id: "${chart-admin-username}"
            name: "Jenkins Admin"
            password: "${chart-admin-password}"
          - id: "alice"
            name: "Alice Developer"
            password: "${alice-password}"
          - id: "bob"
            name: "Bob Viewer"
            password: "${bob-password}"
    authorizationStrategy: |-
      globalMatrix:
        entries:
          - user:
              name: "${chart-admin-username}"
              permissions: ["Overall/Administer"]
          - user:
              name: "alice"
              permissions:
                - "Overall/Read"
                - "Job/Build"
                - "Job/Cancel"
                - "Job/Read"
                - "Job/Workspace"
          - user:
              name: "bob"
              permissions: ["Overall/Read", "Job/Read"]
          - group:
              name: "authenticated"
              permissions: ["Overall/Read"]
    configScripts:
      welcome: |
        jenkins:
          systemMessage: "Welcome to the team Jenkins. Managed by Helm + JCasC. Do not click 'Save' on System settings; edit git instead."
          numExecutors: 0
          globalNodeProperties:
            - envVars:
                env:
                  - key: ENVIRONMENT
                    value: "dev"
                  - key: PG_HOST
                    value: "app-db-rw.jenkins.svc"
                  - key: PG_DB
                    value: "appdb"
      seed-jobs: |
        jobs:
          - script: >
              pipelineJob('hello-k8s') {
                description('Sample pipeline that runs in a Kubernetes agent pod and talks to Postgres')
                definition {
                  cps {
                    sandbox(true)
                    script('''
                      pipeline {
                        agent {
                          kubernetes {
                            inheritFrom 'default'
                            yaml """
                              apiVersion: v1
                              kind: Pod
                              spec:
                                containers:
                                - name: psql
                                  image: postgres:17
                                  command: ['sleep']
                                  args: ['infinity']
                            """
                          }
                        }
                        stages {
                          stage('Hello') {
                            steps { sh 'echo Hello from $NODE_NAME in env $ENVIRONMENT' }
                          }
                          stage('DB check') {
                            steps {
                              container('psql') {
                                withCredentials([usernamePassword(credentialsId: 'app-db', usernameVariable: 'PGUSER', passwordVariable: 'PGPASSWORD')]) {
                                  sh 'psql -h $PG_HOST -d $PG_DB -c "select version();"'
                                }
                              }
                            }
                          }
                        }
                      }
                    ''')
                  }
                }
              }

  # Pull extra secrets into the ${...} variables JCasC can use
  additionalExistingSecrets:
    - name: jenkins-users
      keyName: alice-password
    - name: jenkins-users
      keyName: bob-password

agent:
  enabled: true
  image:
    repository: jenkins/inbound-agent
    tag: "3327.v868139a_d00e0-2-jdk21"     # pick a current tag from Docker Hub
  namespace: jenkins
  podName: default
  customJenkinsLabels: [ "k8s", "linux" ]
  resources:
    requests: { cpu: "250m", memory: "512Mi" }
    limits:   { cpu: "1",    memory: "1Gi" }
  websocket: true                 # agents connect over HTTPS, no port 50000 needed
  podRetention: Never
  idleMinutes: 0
  connectTimeout: 100
  annotations:
    sidecar.istio.io/inject: "false"   # the single most important Istio line in this file

persistence:
  enabled: true
  size: 20Gi
  # storageClass: fast-ssd

rbac:
  create: true
serviceAccount:
  create: true
```

### Step 6 – Create the user password secret

```bash
kubectl -n jenkins create secret generic jenkins-users \
  --from-literal=alice-password="alice123!" \
  --from-literal=bob-password="bob123!"
```

### Step 7 – Install Jenkins

```bash
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --version 5.9.40 \
  -f values.yaml \
  --wait --timeout 10m
```

`--install` means "install if missing, upgrade if present"; using this one command for both makes scripts idempotent.

Watch it start:

```bash
kubectl -n jenkins get pods -w
kubectl -n jenkins logs -f sts/jenkins -c jenkins
```

### Step 8 – Istio Gateway + VirtualService

Save as `istio.yaml` and apply:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: jenkins-gw
  namespace: jenkins
spec:
  selector:
    istio: ingressgateway          # the default Istio ingress pods
  servers:
    - port: { number: 443, name: https, protocol: HTTPS }
      hosts: [ "jenkins.example.com" ]
      tls:
        mode: SIMPLE
        credentialName: jenkins-tls   # a kubernetes.io/tls secret in istio-system
    - port: { number: 80, name: http, protocol: HTTP }
      hosts: [ "jenkins.example.com" ]
      tls:
        httpsRedirect: true
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: jenkins
  namespace: jenkins
spec:
  hosts: [ "jenkins.example.com" ]
  gateways: [ "jenkins/jenkins-gw" ]
  http:
    - match:
        - uri: { prefix: "/" }
      route:
        - destination:
            host: jenkins.jenkins.svc.cluster.local
            port: { number: 8080 }
      timeout: 0s                 # Jenkins has long-running requests (console log streaming)
      retries:
        attempts: 0               # never replay a POST to Jenkins
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: jenkins
  namespace: jenkins
spec:
  host: jenkins.jenkins.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
    connectionPool:
      http:
        idleTimeout: 1h           # keep WebSocket agent connections alive
```

```bash
kubectl apply -f istio.yaml
# Find the external IP of the gateway, point DNS (or /etc/hosts) at it:
kubectl -n istio-system get svc istio-ingressgateway
```

Create the TLS secret (`cert-manager` is the normal way; for a demo use a self-signed cert):

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/CN=jenkins.example.com" \
  -keyout tls.key -out tls.crt
kubectl -n istio-system create secret tls jenkins-tls --key tls.key --cert tls.crt
```

### Step 9 – PostgreSQL with CloudNativePG

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.0.yaml
```

```yaml
# app-db.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: app-db
  namespace: jenkins
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17
  storage: { size: 5Gi }
  bootstrap:
    initdb:
      database: appdb
      owner: app
      secret: { name: app-db-user }
---
apiVersion: v1
kind: Secret
metadata:
  name: app-db-user
  namespace: jenkins
type: kubernetes.io/basic-auth
stringData:
  username: app
  password: app-secret-pw
```

```bash
kubectl apply -f app-db.yaml
kubectl -n jenkins get cluster app-db -w     # wait for "Cluster in healthy state"
```

CloudNativePG creates Services named `app-db-rw` (read-write), `app-db-ro`, `app-db-r`. That is why `PG_HOST` was `app-db-rw.jenkins.svc` in the values file.

Now add the DB credential to Jenkins through JCasC (add this to `configScripts`):

```yaml
      credentials: |
        credentials:
          system:
            domainCredentials:
              - credentials:
                  - usernamePassword:
                      scope: GLOBAL
                      id: "app-db"
                      username: "app"
                      password: "${app-db-password}"
```

and expose the secret:

```yaml
  additionalExistingSecrets:
    - name: app-db-user
      keyName: password     # becomes ${app-db-user-password}
```

(The variable name is `<secretName>-<keyName>`, so use `${app-db-user-password}` in the credential above.) Run `helm upgrade` again.

### Step 10 – Log in and run the job

1. Open `https://jenkins.example.com`, log in as `admin` with the password from Step 4:
   `kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d`
2. You should see the job **hello-k8s** already there (the seed job made it).
3. Click **Build Now**. Watch `kubectl -n jenkins get pods` – a pod named `default-xxxxx` appears, runs, and disappears.
4. The console output ends with the Postgres version string. 🎉

You now have the whole stack. The rest of this tutorial explains *why* each piece looks the way it does and what else you can turn on.

---

## 4. The Helm chart in depth: every important field explained

The chart has four top-level blocks: `controller`, `agent` (plus `additionalAgents`), `persistence`, and cluster plumbing (`rbac`, `serviceAccount`, `networkPolicy`, `serviceAccountAgent`). Get the full annotated list any time with:

```bash
helm show values jenkins/jenkins --version 5.9.40 > default-values.yaml
```

### 4.1 `controller.*` – the Jenkins pod itself

| Field | What it does | Default | Notes / gotcha |
|---|---|---|---|
| `image.repository`, `image.tag`, `image.tagLabel` | Which Jenkins image to run. If `tag` is empty the chart uses `appVersion` + `tagLabel` (e.g. `jdk21`). | LTS from the chart | **Pin it.** Never rely on `latest`. Must be a Java 21+ image for Jenkins ≥ 2.555.1. |
| `imagePullPolicy`, `imagePullSecretName` | Pull behaviour and registry secret. | `Always` | Set `IfNotPresent` for air-gapped. |
| `admin.username`, `admin.password` | Inline admin creds (chart generates a random password if empty). | `admin` / random | Prefer `admin.existingSecret`. |
| `admin.existingSecret`, `admin.userKey`, `admin.passwordKey` | Read admin creds from a Secret. | – | Keys default to `jenkins-admin-user` / `jenkins-admin-password`. |
| `admin.createSecret` | Whether the chart creates its own secret. | `true` | Set `false` when using `existingSecret`. |
| `jenkinsUrl` | The public URL Jenkins believes it has. Used in links, emails, and **agent connection**. | derived | Behind Istio you **must** set this to the gateway host. |
| `jenkinsUriPrefix` | Serve under a sub-path like `/jenkins`. | `""` | Must match your VirtualService `prefix`. |
| `jenkinsAdminEmail` | Admin address in system config. | – | |
| `numExecutors`, `executorMode` | Executors on the controller. | `0`, `NORMAL` | Keep **0** in production so builds never run on the controller. |
| `serviceType`, `servicePort`, `targetPort`, `nodePort`, `serviceAnnotations` | How the Service is exposed. | `ClusterIP`, `8080` | Keep `ClusterIP` with Istio. |
| `agentListenerPort`, `agentListenerEnabled`, `agentListenerServiceType` | The JNLP/TCP port agents use (50000). | `50000`, enabled, `ClusterIP` | Not needed when `agent.websocket: true`. |
| `ingress.*`, `secondaryingress.*` | Standard Kubernetes Ingress. | disabled | Leave disabled with Istio (or use Gateway API). |
| `installPlugins` | Core plugin list the image must have. | kubernetes, workflow-aggregator, git, configuration-as-code | Overrides defaults; listing replaces the whole list. |
| `additionalPlugins` | Plugins to add *on top of* `installPlugins`. | `[]` | The right place for your extras. |
| `installLatestPlugins` | Resolve `name` entries to latest. | `true` | For production set `false` and use `name:version`. |
| `installLatestSpecifiedPlugins` | Even with versions, pull latest. | `false` | |
| `overwritePlugins` | Delete plugin dir on each start and reinstall from list. | `false` | `true` guarantees the list is the truth; slower start. |
| `overwritePluginsFromImage` | Copy plugins bundled in a custom image. | `true` | Relevant when you build your own image with plugins baked in. |
| `initializeOnce` | Run the init container only on first boot. | `false` | Speeds restarts; combine with a custom image. |
| `javaOpts` | Extra JVM flags. | – | Use `-XX:MaxRAMPercentage` rather than `-Xmx`. Since chart 5.9.39 you can use `{{ }}` templates here. |
| `jenkinsOpts` | Extra Jenkins launcher flags (`--httpPort`, `--prefix`). | – | |
| `containerEnv`, `containerEnvFrom` | Environment vars for the controller. | – | Good for proxies, TZ, `CASC_RELOAD_TOKEN`. |
| `resources` | CPU/memory. | 50m/256Mi req, 2/4Gi lim | Jenkins is memory-hungry; 2–4 GiB real-world minimum. |
| `healthProbes`, `probes.*` | Liveness/readiness/startup. | enabled | Raise `startupProbe.failureThreshold` for big plugin sets. |
| `podSecurityContext`, `containerSecurityContext`, `runAsUser`, `fsGroup` | Linux user/group. | 1000/1000 | Needed so the PVC is writable. |
| `sidecars.configAutoReload.*` | Sidecar that watches ConfigMaps labelled for JCasC and tells Jenkins to reload. | enabled | Reload uses a token; the sidecar sets it up. |
| `sidecars.additionalSidecarContainers` | Your own sidecars (e.g. log shipper). | – | |
| `customInitContainers` | Extra init containers (e.g. fetch secrets, warm caches). | – | |
| `initScripts` / `initConfigMap` | Groovy scripts run at startup (old way, pre-JCasC). | – | Prefer JCasC; use only for things JCasC can't do. |
| `JCasC.defaultConfig` | Generate the base JCasC (kube cloud, admin, URL). | `true` | Almost always keep true. |
| `JCasC.configScripts` | Map of name → YAML. Each becomes a ConfigMap and is merged. | – | Your main configuration surface. |
| `JCasC.securityRealm` | YAML for who users are. | local admin | |
| `JCasC.authorizationStrategy` | YAML for what they can do. | `loggedInUsersCanDoAnything` | Change this before going live. |
| `JCasC.configUrls` | Pull JCasC from URLs. | – | Alternative to configScripts. |
| `JCasC.overwriteConfiguration` | Delete `casc_configs` dir on each start. | `false` | |
| `additionalExistingSecrets` | Mount keys from existing Secrets as `${secret-key}` variables. | – | Variable name = `<secret>-<key>`. |
| `additionalSecrets` | Inline secrets (don't). | – | |
| `secretClaims` | Secrets Store CSI driver (Vault, AWS SM, Azure KV). | – | Best for enterprise. |
| `existingSecret` | Older single-secret approach. | – | |
| `csrf.defaultCrumbIssuer.*` | CSRF protection, `proxyCompatability`. | enabled | Set `proxyCompatability: true` behind Istio/NAT. |
| `prometheus.*` | Create a ServiceMonitor / scrape config. | disabled | Needs the `prometheus` plugin. |
| `podAnnotations`, `podLabels`, `nodeSelector`, `tolerations`, `affinity`, `priorityClassName`, `topologySpreadConstraints` | Standard scheduling knobs. | – | Put the controller on a dedicated node pool. |
| `statefulSetAnnotations`, `statefulSetLabels`, `updateStrategy` | StatefulSet tweaks. | `RollingUpdate` | |
| `terminationGracePeriodSeconds` | Time to finish shutdown. | 30 | Raise if builds take time to quiesce. |
| `cloudName` | Name of the Kubernetes cloud in JCasC. | `kubernetes` | Matters for `inheritFrom`/`cloud:` in pipelines. |
| `testEnabled` | Create `helm test` pod. | `true` | |
| `backup.*` | **Removed in chart 5.0**. | – | Use Velero / PVC snapshots / `thinBackup` plugin. |

### 4.2 `agent.*` – the default Kubernetes pod template

| Field | Meaning | Default |
|---|---|---|
| `enabled` | Create the Kubernetes cloud + default pod template. | `true` |
| `image.repository`, `image.tag` | The JNLP agent image. | `jenkins/inbound-agent` |
| `namespace` | Where agent pods run (can be a different namespace). | release ns |
| `podName` | Name of the default template (you reference it with `inheritFrom`). | `default` |
| `customJenkinsLabels` | Labels so `agent { label 'k8s' }` picks this template. | – |
| `resources` | CPU/mem of the `jnlp` container. | 512m/512Mi |
| `alwaysPullImage` | Pull every time. | `false` |
| `privileged`, `runAsUser`, `runAsGroup`, `restrictedPssSecurityContext` | Security. `restrictedPssSecurityContext: true` makes pods pass the *restricted* Pod Security Standard. | – |
| `websocket` | Connect over the HTTP(S) port instead of TCP 50000. | `false` → set **true** with Istio |
| `directConnection` | Skip HTTP handshake; needs port 50000 reachable. | `false` |
| `jenkinsUrl`, `jenkinsTunnel` | Override how agents reach the controller (in-cluster addresses). | derived |
| `connectTimeout` | Seconds to wait for the agent to connect. | 100 |
| `idleMinutes` | Keep a finished pod around for reuse. | 0 |
| `podRetention` | `Never`, `OnFailure`, `Always`, `Default`. | `Never` |
| `containerCap` | Max agent pods for this cloud. | 10 |
| `maxRequestsPerHostStr` | Parallel API requests to the Kubernetes API. | 32 |
| `waitForPodSec` | Seconds to wait before pod is considered failed. | 600 |
| `retentionTimeout` | Minutes before an *unused* cloud is cleaned. | 5 |
| `workspaceVolume` | `emptyDirWorkspaceVolume`, `dynamicPVC`, `hostPath`, `nfs`, `pvc`. | emptyDir |
| `volumes`, `envVars`, `annotations`, `nodeSelector`, `tolerations` | Pod template settings. | – |
| `additionalContainers` | Extra containers in the default template (e.g. docker, kaniko, psql). | – |
| `podTemplates` | **Map of extra named pod templates** (YAML strings). | – |
| `yamlTemplate` | Raw pod YAML merged into the template. | – |
| `yamlMergeStrategy`, `inheritYamlMergeStrategy` | `override` or `merge`. | `override` |
| `defaultsProviderTemplate` | Template every other template inherits from. | – |
| `serviceAccount` / `serviceAccountAgent.*` | SA used by agent pods. | default |
| `jnlpregistry` | Registry prefix for the agent image. | – |
| `skipTlsVerify`, `usageRestricted`, `showRawYaml`, `disableDefaultAgent` | Misc cloud options. | – |
| `garbageCollection.*` | Delete orphaned agent pods. | disabled → enable it |

`additionalAgents:` is a map where each key is another full pod template that **inherits** from `agent` and overrides fields (e.g. a `maven` template, a `node` template).

### 4.3 `persistence.*`

| Field | Meaning |
|---|---|
| `enabled` | Use a PVC for `JENKINS_HOME`. `false` = everything lost on restart. |
| `existingClaim` | Reuse a PVC you made (good for migrations). |
| `storageClass`, `size`, `accessMode` | Volume spec. RWO is fine (one controller). |
| `annotations`, `labels` | e.g. `helm.sh/resource-policy: keep` so `helm uninstall` keeps data. |
| `volumes`, `mounts` | Extra volumes/mounts on the controller (CA bundles, shared caches). |
| `dataSource` | Clone from a VolumeSnapshot. |

### 4.4 Plumbing

- `rbac.create`: ClusterRole/Role so Jenkins can create pods. `rbac.readSecrets: true` lets the Kubernetes Credentials Provider plugin read Secrets.
- `serviceAccount.*` / `serviceAccountAgent.*`: annotate with IAM roles (`eks.amazonaws.com/role-arn`, `iam.gke.io/gcp-service-account`).
- `networkPolicy.enabled`: locks traffic to the controller; add `internalAgents` / `externalAgents` selectors.
- `checkDeprecation`: fails install if you use removed values. Keep `true`.

---

## 5. Istio: Gateway, VirtualService, and the agent-pod trap

### 5.1 Why a VirtualService instead of Ingress?

| | Kubernetes Ingress | Istio Gateway + VirtualService | Gateway API (Istio implements it) |
|---|---|---|---|
| Pros | Simple, widely known | Rich routing, retries, mTLS, canary, header rewrite, built-in observability | Standard, portable across meshes, future direction |
| Cons | Limited features, controller-specific annotations | Istio-specific CRDs, learning curve | Newer, fewer examples |

If you already run Istio, use its resources – mixing Ingress controllers and Istio ingress is confusing.

### 5.2 The resources, explained

- **Gateway**: binds hostnames and ports to the Istio ingress pods. `tls.mode: SIMPLE` = normal HTTPS. `credentialName` must be a secret **in the namespace of the ingress gateway** (usually `istio-system`).
- **VirtualService**: "for host X, send to Service Y port Z". Key Jenkins-specific settings:
  - `timeout: 0s` – disable the 15 s default; Jenkins streams logs, uploads artifacts, and some pages take a while.
  - `retries.attempts: 0` – Istio retries safe-looking requests; a replayed `POST /job/x/build` would start two builds.
  - WebSocket is auto-upgraded by Istio; nothing special needed.
- **DestinationRule** (optional): connection-pool idle timeouts so WebSocket agents are not killed; `tls.mode: ISTIO_MUTUAL` if you enforce strict mTLS in the mesh.
- **Sub-path** example (`https://tools.example.com/jenkins`): set `controller.jenkinsUriPrefix: /jenkins`, `controller.jenkinsUrl: https://tools.example.com/jenkins`, and match `uri: { prefix: "/jenkins" }` with **no** rewrite.

### 5.3 Jenkins behind a proxy

Jenkins shows "It appears that your reverse proxy set up is broken" when `X-Forwarded-*` headers are wrong. Istio's Envoy sets them correctly as long as `jenkinsUrl` matches what users type. Also set:

```yaml
controller:
  csrf:
    defaultCrumbIssuer:
      enabled: true
      proxyCompatability: true
```

### 5.4 The agent-pod trap (most common Istio + Jenkins problem)

An agent pod has a `jnlp` container (plus your build containers). When the job finishes, these containers exit. **But the Istio sidecar (`istio-proxy`) never exits on its own**, so the pod sits in `NotReady`/`Running` forever, Jenkins waits, and your cluster fills up with zombies. Three fixes, best first:

1. **Don't inject the sidecar into agent pods** (recommended). Agent pods talk only to the controller over WebSocket/HTTPS and to the internet; they rarely need the mesh.
   ```yaml
   agent:
     annotations:
       sidecar.istio.io/inject: "false"
   ```
   If your mesh uses **STRICT** mTLS and the controller is in the mesh, add a `PeerAuthentication` with `mtls.mode: PERMISSIVE` for the controller's port 8080 (or the jenkins namespace) so sidecar-less agents can connect.
2. **Keep the sidecar but let it exit**: add `proxy.istio.io/config: '{ "holdApplicationUntilProxyStarts": true }'` so the jnlp container doesn't start before networking is ready, and have your pipeline's last step call `curl -sf -XPOST http://127.0.0.1:15020/quitquitquit`. Fragile.
3. **Istio ambient mode** (no sidecars at all; ztunnel handles L4). If your Istio is ambient, the trap disappears – just label the namespace `istio.io/dataplane-mode=ambient`.

Second Istio gotcha: when agents use the **TCP 50000** port and the controller has a sidecar, Envoy must know it's TCP, not HTTP. Name the port `tcp-agent` or just use `agent.websocket: true`, which is simpler and firewall-friendly.

---

## 6. Agent pods: how Jenkins builds things inside Kubernetes

### 6.1 What happens when you click "Build"

1. The pipeline says `agent { kubernetes { ... } }` (or a label matching a pod template).
2. The **Kubernetes plugin** asks the Kubernetes API to create a Pod with a `jnlp` container plus any you listed.
3. The `jnlp` container starts, reads `JENKINS_URL`, `JENKINS_SECRET`, `JENKINS_AGENT_NAME` env vars (injected by the plugin) and connects back to the controller (WebSocket in our setup).
4. Steps run; `container('name') { }` switches which container executes `sh`.
5. Pod is deleted (`podRetention: Never`) or kept for debugging (`OnFailure`).

### 6.2 Pod templates in `values.yaml` (reusable, admin-controlled)

```yaml
agent:
  podTemplates:
    maven: |
      - name: maven
        label: maven
        inheritFrom: default
        serviceAccount: jenkins-agent
        containers:
          - name: maven
            image: maven:3.9-eclipse-temurin-21
            command: "sleep"
            args: "infinity"
            resourceRequestCpu: "500m"
            resourceRequestMemory: "1Gi"
            resourceLimitMemory: "3Gi"
        volumes:
          - persistentVolumeClaim:
              claimName: maven-cache
              mountPath: /root/.m2
    kaniko: |
      - name: kaniko
        label: kaniko
        containers:
          - name: kaniko
            image: gcr.io/kaniko-project/executor:debug
            command: "sleep"
            args: "infinity"
        volumes:
          - secretVolume:
              secretName: registry-creds
              mountPath: /kaniko/.docker

additionalAgents:
  node:
    podName: node
    customJenkinsLabels: [ "node" ]
    image:
      repository: node
      tag: "22"
    command: "sleep"
    args: "infinity"
    sideContainerName: node     # the main build container name
    resources:
      requests: { cpu: "300m", memory: "512Mi" }
```

Use in a pipeline:

```groovy
pipeline {
  agent { label 'maven' }
  stages {
    stage('Build') {
      steps { container('maven') { sh 'mvn -B verify' } }
    }
  }
}
```

### 6.3 Pod templates inside the Jenkinsfile (developer-controlled)

```groovy
pipeline {
  agent {
    kubernetes {
      cloud 'kubernetes'          // controller.cloudName
      inheritFrom 'default'
      defaultContainer 'go'
      yaml '''
        apiVersion: v1
        kind: Pod
        metadata:
          annotations:
            sidecar.istio.io/inject: "false"
        spec:
          serviceAccountName: jenkins-agent
          containers:
          - name: go
            image: golang:1.23
            command: [sleep]
            args: [infinity]
            resources:
              requests: { cpu: 500m, memory: 1Gi }
          - name: pg
            image: postgres:17
            env:
            - { name: POSTGRES_PASSWORD, value: test }
            - { name: POSTGRES_DB, value: testdb }
            ports: [{ containerPort: 5432 }]
      '''
      idleMinutes 5
      podRetention onFailure()
      showRawYaml false
    }
  }
  options { timeout(time: 30, unit: 'MINUTES') }
  stages {
    stage('Wait for DB') {
      steps { sh 'until pg_isready -h 127.0.0.1; do sleep 1; done' }
    }
    stage('Test') {
      steps { sh 'DATABASE_URL=postgres://postgres:test@127.0.0.1/testdb go test ./...' }
    }
  }
}
```

Every container in a pod shares `localhost`, so the `go` container reaches Postgres at `127.0.0.1:5432`. This is the cleanest way to get a throw-away database per build.

### 6.4 Scripted style (`podTemplate` step)

```groovy
podTemplate(inheritFrom: 'default', containers: [
  containerTemplate(name: 'python', image: 'python:3.12', command: 'sleep', args: 'infinity')
]) {
  node(POD_LABEL) {
    container('python') { sh 'python --version' }
  }
}
```

### 6.5 Controlling agent pods

| Need | How |
|---|---|
| Limit total concurrent builds | `agent.containerCap` (per cloud) or Kubernetes `ResourceQuota` on the agent namespace. |
| Run agents in another namespace | `agent.namespace: ci-agents`; chart creates the Role there if `rbac.create`. |
| Let agents deploy to the cluster | `serviceAccountAgent.create: true` + a Role/ClusterRole binding; reference it with `serviceAccount:` in the template. |
| Give agents cloud IAM | Annotate `serviceAccountAgent` with the IAM role; `kubectl` / `aws` inside containers just work. |
| Debug a failed build pod | `podRetention: OnFailure` and `kubectl exec` into it; delete afterwards. |
| Speed up repeated builds | `idleMinutes: 10` (reuse pod) + PVC or `dynamicPVC` workspace volume. |
| Clean orphans after controller restarts | `agent.garbageCollection.enabled: true`, `timeout: 300`. |
| Non-root/PSS restricted | `agent.restrictedPssSecurityContext: true` and images that run as non-root. |
| Private registry for agent image | `agent.jnlpregistry: registry.corp/` and `imagePullSecrets`. |
| Windows agents | Separate cloud with `windows` tolerations/nodeSelector; the plugin supports it. |

---

## 7. Configuration as Code (JCasC): environments, credentials, settings

### 7.1 How the chart wires it

Each entry under `controller.JCasC.configScripts` becomes a ConfigMap labelled `jenkins-jenkins-config: "true"`. The `config-reload` sidecar watches those ConfigMaps, writes them to `/var/jenkins_home/casc_configs/`, and POSTs to `/reload-configuration-as-code/?casc-reload-token=…`. So: **edit values → helm upgrade → Jenkins reloads without restarting** (plugins and JVM settings still need a restart).

Secrets are referenced as `${name}` and resolved from:

1. Environment variables on the controller container (`containerEnv`, `containerEnvFrom`).
2. Files in `/run/secrets/` – that is where `additionalExistingSecrets` and `secretClaims` land, as `<secret>-<key>`.
3. Vault / AWS / Azure if you install those JCasC secret-source plugins.

### 7.2 "Conformal / per-environment" configuration

You said "conformal env" – I read that as *a conformant, consistent environment configuration*: every Jenkins (dev, staging, prod) is built from the same values file, with only a small overlay that differs. Here is the pattern:

```
jenkins/
├── values.yaml             # shared, everything from Step 5
├── values-dev.yaml         # small overlay
├── values-staging.yaml
└── values-prod.yaml
```

`values-prod.yaml`:

```yaml
controller:
  jenkinsUrl: https://jenkins.prod.example.com
  resources:
    requests: { cpu: "2", memory: "6Gi" }
    limits:   { cpu: "4", memory: "8Gi" }
  installLatestPlugins: false      # pinned in prod
  JCasC:
    configScripts:
      welcome: |
        jenkins:
          systemMessage: "PRODUCTION Jenkins – changes only via git"
          globalNodeProperties:
            - envVars:
                env:
                  - { key: ENVIRONMENT, value: "prod" }
                  - { key: PG_HOST,     value: "app-db-rw.prod-db.svc" }
agent:
  containerCap: 50
persistence:
  size: 100Gi
  storageClass: premium-ssd
```

Install with layered files – later files win:

```bash
helm upgrade --install jenkins jenkins/jenkins -n jenkins -f values.yaml -f values-prod.yaml
```

Ways to give jobs environment-specific values (choose one or mix):

| Method | Where | Pros | Cons |
|---|---|---|---|
| `globalNodeProperties.envVars` (JCasC) | Every build sees `$ENVIRONMENT` | Simplest | Visible to every job; not secret |
| Global credentials (JCasC) | `withCredentials` in pipeline | Secret, auditable | Need plugin bindings |
| Kubernetes Secrets/ConfigMaps mounted in pod templates | Agent containers | Native K8s, rotate without Jenkins | Only inside containers |
| Kubernetes Credentials Provider plugin | Secrets labelled `jenkins.io/credentials-type` appear as Jenkins credentials automatically | GitOps-friendly, no JCasC edits | Needs `rbac.readSecrets: true` |
| Shared library `vars/env.groovy` | Pipeline code | Logic, defaults, validation | More code to maintain |

### 7.3 Useful JCasC blocks

```yaml
      system: |
        jenkins:
          numExecutors: 0
          mode: EXCLUSIVE
          quietPeriod: 5
          scmCheckoutRetryCount: 2
          disabledAdministrativeMonitors:
            - "jenkins.diagnostics.ControllerExecutorsNoAgents"
          markupFormatter:
            rawHtml: { disableSyntaxHighlighting: false }
          crumbIssuer:
            standard: { excludeClientIPFromCrumb: true }
          remotingSecurity: { enabled: true }
        security:
          globalJobDslSecurityConfiguration:
            useScriptSecurity: false        # trust seed scripts that come from values.yaml
          scriptApproval:
            approvedSignatures: []
          queueItemAuthenticator:
            authenticators:
              - global: { strategy: triggeringUsersAuthorizationStrategy }
        unclassified:
          location:
            url: "${JENKINS_URL}"
            adminAddress: "jenkins@example.com"
          globalLibraries:
            libraries:
              - name: "shared"
                defaultVersion: "main"
                implicit: true
                retriever:
                  modernSCM:
                    scm:
                      git:
                        remote: "https://github.com/example/jenkins-shared-lib.git"
                        credentialsId: "github-token"
          timestamper:
            allPipelines: true
          buildDiscarders:
            configuredBuildDiscarders:
              - "jobBuildDiscarder"
              - simpleBuildDiscarder:
                  discarder:
                    logRotator: { numToKeepStr: "30", artifactNumToKeepStr: "5" }
        tool:
          git:
            installations:
              - { name: Default, home: git }
          jdk:
            installations:
              - name: "jdk21"
                properties:
                  - installSource:
                      installers:
                        - adoptOpenJdkInstaller: { id: "jdk-21.0.4+7" }
```

### 7.4 Finding the exact YAML for any setting

Open `https://jenkins.example.com/manage/configuration-as-code/` → **View Configuration** shows the current live YAML, and **Documentation** lists every field every installed plugin supports. Configure something by hand once, copy its YAML, put it in `configScripts`.

---

## 8. Admin, users, and permissions

### 8.1 Security realm (who are you?)

| Realm | JCasC key | Use when |
|---|---|---|
| Local users | `local:` | Small teams, labs, break-glass admin |
| LDAP / Active Directory | `ldap:` / `activeDirectory:` | Corporate directory |
| GitHub / GitLab OAuth | `github:` / `gitlab:` | Dev teams on those platforms |
| OpenID Connect (Okta, Keycloak, Entra, Google) | `oic:` | Modern SSO, MFA |
| SAML | `saml:` | Enterprise SSO |

Local example with three users was in Step 5. Here is OIDC (plugin `oic-auth`):

```yaml
    securityRealm: |-
      oic:
        clientId: "jenkins"
        clientSecret: "${oidc-client-secret}"
        serverConfiguration:
          wellKnown:
            wellKnownOpenIDConfigurationUrl: "https://sso.example.com/realms/corp/.well-known/openid-configuration"
            scopesOverride: "openid email profile groups"
        userNameField: "preferred_username"
        groupsFieldName: "groups"
        escapeHatchEnabled: true
        escapeHatchUsername: "${chart-admin-username}"
        escapeHatchSecret: "${chart-admin-password}"
```

`escapeHatch` gives you a local admin login at `/securityRealm/escapeHatch` if SSO breaks. Always keep one.

### 8.2 Authorization strategy (what can you do?)

**Matrix (`matrix-auth` plugin)** – simple, per user/group:

```yaml
    authorizationStrategy: |-
      globalMatrix:
        entries:
          - group: { name: "jenkins-admins", permissions: ["Overall/Administer"] }
          - group:
              name: "developers"
              permissions: ["Overall/Read","Job/Build","Job/Cancel","Job/Read","Job/Workspace","Run/Replay","View/Read"]
          - group: { name: "authenticated", permissions: ["Overall/Read"] }
```

**Role-based (`role-strategy` plugin)** – scales to many teams, supports folder-pattern roles:

```yaml
    authorizationStrategy: |-
      roleBased:
        roles:
          global:
            - name: admin
              permissions: ["Overall/Administer"]
              entries: [{ group: "jenkins-admins" }]
            - name: reader
              permissions: ["Overall/Read", "Job/Read", "View/Read"]
              entries: [{ group: "authenticated" }]
          items:
            - name: team-payments
              pattern: "payments/.*"
              permissions: ["Job/Build","Job/Cancel","Job/Configure","Job/Create","Job/Read","Job/Workspace","Run/Replay"]
              entries: [{ group: "payments-devs" }]
```

Common permission strings: `Overall/Administer`, `Overall/Read`, `Overall/SystemRead`, `Job/Build`, `Job/Cancel`, `Job/Configure`, `Job/Create`, `Job/Delete`, `Job/Discover`, `Job/Read`, `Job/Workspace`, `Run/Delete`, `Run/Replay`, `Run/Update`, `View/Configure`, `View/Create`, `View/Delete`, `View/Read`, `Credentials/View`, `Agent/Build`, `Agent/Configure`, `SCM/Tag`.

### 8.3 Users created for *testing* jobs

Create a `ci-tester` user with only `Job/Build` + `Job/Read` on a `tests/` folder, and a `release-bot` service user whose API token is what your pipelines call Jenkins with. Create tokens in JCasC-safe way: log in as the user once → *Configure* → *API Token*, or script it:

```bash
# from inside the controller pod (groovy via script console or CLI)
jenkins-cli -auth admin:$ADMIN_TOKEN -s https://jenkins.example.com groovy = <<'EOF'
def u = hudson.model.User.getById('release-bot', false)
def t = u.getProperty(jenkins.security.ApiTokenProperty).tokenStore.generateNewToken('bootstrap')
println t.plainValue
EOF
```

### 8.4 Password rules

- Admin password lives only in the Secret; rotate it by editing the Secret and running `helm upgrade` (JCasC reapplies the local realm).
- JCasC **owns** the local realm: a password changed by hand in the UI is reset on the next reload. That is a feature for admin, a surprise for users – tell them, or use SSO.

---

## 9. Default jobs and pipelines with Job DSL

### 9.1 Three ways to ship default jobs

| Method | How | Pros | Cons |
|---|---|---|---|
| **A. Job DSL inside JCasC** (`jobs:` block, used in Step 5) | Groovy inline in `values.yaml` | Zero extra repos, present at first boot | Values file grows; Groovy in YAML quoting pain |
| **B. Seed job + DSL repo** | JCasC creates *one* `seed` freestyle job that checks out `jenkins-jobs` git repo and runs `jobs/**/*.groovy` | Scales, reviewable, dry-run in PRs | Needs a repo + credentials; first run must be triggered |
| **C. Organization folders / multibranch** | JCasC creates a `githubOrganization` or `gitLabBrowser` folder; every repo with a `Jenkinsfile` auto-appears | Jobs follow repos; least maintenance | Needs SCM API access; less control |

Most real setups use **B + C**: one seed job, plus org folders.

### 9.2 Seed job (method B)

```yaml
      seed: |
        jobs:
          - script: >
              freeStyleJob('seed') {
                description('Creates all jobs from the jenkins-jobs repo. Run after every merge.')
                logRotator { numToKeep(20) }
                scm {
                  git {
                    remote { url('https://github.com/example/jenkins-jobs.git'); credentials('github-token') }
                    branch('main')
                  }
                }
                triggers { scm('H/10 * * * *') }
                steps {
                  jobDsl {
                    targets('jobs/**/*.groovy')
                    removedJobAction('DELETE')
                    removedViewAction('DELETE')
                    lookupStrategy('SEED_JOB')
                    failOnMissingPlugin(true)
                    unstableOnDeprecation(true)
                  }
                }
              }
              queue('seed')
```

`removedJobAction('DELETE')` makes the repo the single source of truth – delete a file, the job disappears. `queue('seed')` triggers it right after creation.

### 9.3 Job DSL examples for the repo

`jobs/folders.groovy`

```groovy
folder('payments') { description('Payments team') }
folder('tests')    { description('Playground jobs for testing the CI setup') }
```

`jobs/pipeline-from-scm.groovy`

```groovy
pipelineJob('payments/api-build') {
  parameters {
    choiceParam('ENV', ['dev','staging','prod'], 'Target environment')
    booleanParam('RUN_DB_MIGRATIONS', false)
  }
  properties {
    disableConcurrentBuilds()
    pipelineTriggers { triggers { cron { spec('H 2 * * 1-5') } } }
  }
  definition {
    cpsScm {
      scm { git { remote { url('https://github.com/example/payments-api.git'); credentials('github-token') }; branch('*/main') } }
      scriptPath('Jenkinsfile')
      lightweight(true)
    }
  }
}
```

`jobs/multibranch.groovy`

```groovy
multibranchPipelineJob('payments/api') {
  branchSources {
    github {
      id('payments-api')
      repoOwner('example'); repository('payments-api')
      scanCredentialsId('github-token')
      buildOriginBranch(true); buildOriginPRMerge(true)
    }
  }
  orphanedItemStrategy { discardOldItems { numToKeep(10) } }
  triggers { periodicFolderTrigger { interval('1h') } }
}
```

`jobs/tests/smoke.groovy` – a tiny job every new user can run to prove agents work:

```groovy
pipelineJob('tests/smoke-agent') {
  definition { cps { sandbox(true); script('''
    pipeline {
      agent { label 'k8s' }
      stages { stage('ok') { steps { sh 'uname -a && echo AGENT_OK' } } }
    }
  ''') } }
}
```

Full DSL reference: `https://jenkins.example.com/plugin/job-dsl/api-viewer/index.html` (generated for *your* plugin set).

### 9.4 A fuller declarative pipeline template

```groovy
pipeline {
  agent { label 'maven' }
  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 45, unit: 'MINUTES')
    disableConcurrentBuilds()
  }
  environment {
    REGISTRY = 'registry.example.com/payments'
    IMAGE    = "${REGISTRY}/api:${GIT_COMMIT.take(8)}"
  }
  parameters { choice(name: 'ENV', choices: ['dev','staging','prod']) }
  stages {
    stage('Build')  { steps { container('maven') { sh 'mvn -B -DskipTests package' } } }
    stage('Test')   { steps { container('maven') { sh 'mvn -B test' } }
                      post { always { junit 'target/surefire-reports/*.xml' } } }
    stage('Image')  { steps { container('kaniko') { sh "/kaniko/executor --context . --destination ${IMAGE}" } } }
    stage('Deploy') {
      when { expression { params.ENV != 'prod' || env.BRANCH_NAME == 'main' } }
      steps {
        withCredentials([file(credentialsId: "kubeconfig-${params.ENV}", variable: 'KUBECONFIG')]) {
          sh "helm upgrade --install api ./chart --set image=${IMAGE} -n payments-${params.ENV}"
        }
      }
    }
  }
  post {
    failure { slackSend channel: '#ci', message: "FAILED ${JOB_NAME} #${BUILD_NUMBER}" }
  }
}
```

---

## 10. PostgreSQL: deploying it, using it in jobs, and upgrading it

### 10.1 Clearing up a common confusion

Jenkins itself keeps **no database**. Jobs, builds, users, credentials – all are XML/JSON files under `JENKINS_HOME` on the PVC. You do not "connect Jenkins to Postgres". You use Postgres for:

1. Applications your pipelines test/deploy (integration tests).
2. Tools you install next to Jenkins (SonarQube, Nexus, Harbor, Keycloak all want Postgres).
3. Optional plugins that store data in SQL (e.g. `database` + `database-postgresql` plugins used by a few reporting plugins).

### 10.2 Deployment options

| Option | Pros | Cons |
|---|---|---|
| **CloudNativePG operator** (used in Step 9) | Backups, PITR, replicas, rolling minor upgrades, in-place major upgrades (1.26+), declarative | Operator to run |
| Zalando / Crunchy operators | Mature, feature-rich | Heavier |
| Bitnami `postgresql` chart | One-line install, familiar | Since late 2025 Bitnami moved free images to "legacy"; pin image tags or use their secure images |
| Managed (RDS, Cloud SQL, Azure DB) | Zero ops | Cost, network path from agents |
| Postgres *container inside the agent pod* | Throw-away, parallel-safe, no state | Only for tests |

### 10.3 Giving jobs database access

- Test DB per build → sidecar container in the pod template (section 6.3).
- Shared dev DB → Jenkins credential `app-db` + `PG_HOST` env var (Step 5), plus a `NetworkPolicy` that allows the agent namespace to reach port 5432.
- Migrations → run them from a pipeline using `flyway` / `liquibase` / `alembic` containers, with `disableConcurrentBuilds()` and a `lock('db-migrate')` step (plugin `lockable-resources`).

### 10.4 Managing Postgres *from* Jenkins (admin pipelines)

```groovy
pipelineJob('ops/pg-backup') {
  triggers { cron('H 3 * * *') }
  definition { cps { sandbox(true); script('''
    pipeline {
      agent { kubernetes { yaml """
        apiVersion: v1
        kind: Pod
        metadata: { annotations: { sidecar.istio.io/inject: "false" } }
        spec:
          containers:
          - name: pg
            image: postgres:17
            command: [sleep]; args: [infinity]
      """ } }
      stages {
        stage('dump') { steps { container('pg') {
          withCredentials([usernamePassword(credentialsId: 'app-db', usernameVariable: 'PGUSER', passwordVariable: 'PGPASSWORD')]) {
            sh 'pg_dump -h app-db-rw.jenkins.svc -Fc appdb > appdb-$(date +%F).dump'
            archiveArtifacts artifacts: '*.dump', fingerprint: true
          }
        } } }
      }
    }
  ''') } }
}
```

(Real backups should go to object storage – CloudNativePG's `backup:` with S3/GCS/Azure does this natively.)

### 10.5 Upgrading PostgreSQL versions

**Minor versions (17.2 → 17.4):** on-disk format unchanged; just bump the image. With CloudNativePG: edit `imageName`, the operator performs a rolling restart (replicas first, then switchover). Zero/near-zero downtime.

**Major versions (16 → 17):** data files are *incompatible*; you must convert.

| Method | How | Downtime | Pros / cons |
|---|---|---|---|
| **Logical dump/restore** | `pg_dump` from old → `pg_restore` into new cluster | Minutes–hours | Simplest, works everywhere; slow for big DBs |
| **`pg_upgrade` (in place)** | CloudNativePG ≥ 1.26: change `imageName` major, operator runs `pg_upgrade` for you (`spec.postgresql.majorVersionUpgrade`-style flow) | Short | Fast; needs free disk; test first |
| **Logical replication / `import` bootstrap** | New CNPG cluster with `bootstrap.initdb.import` from old; cut over DNS | Seconds at cutover | Best for large DBs; more moving parts |
| **Managed service upgrade** | Cloud console/API | Provider-defined | No control |

Pipeline for the dump/restore path, written as a job so it's repeatable:

```groovy
pipelineJob('ops/pg-major-upgrade') {
  parameters { stringParam('NEW_CLUSTER', 'app-db-17') }
  definition { cps { sandbox(true); script('''
    pipeline {
      agent { kubernetes { yaml """
        apiVersion: v1
        kind: Pod
        metadata: { annotations: { sidecar.istio.io/inject: "false" } }
        spec:
          serviceAccountName: jenkins-agent
          containers:
          - { name: pg, image: postgres:17, command: [sleep], args: [infinity] }
          - { name: kubectl, image: bitnami/kubectl:1.31, command: [sleep], args: [infinity] }
      """ } }
      stages {
        stage('Create new cluster') { steps { container('kubectl') { sh """
          cat <<EOF | kubectl apply -f -
          apiVersion: postgresql.cnpg.io/v1
          kind: Cluster
          metadata: { name: ${params.NEW_CLUSTER}, namespace: jenkins }
          spec:
            instances: 1
            imageName: ghcr.io/cloudnative-pg/postgresql:17
            storage: { size: 5Gi }
            bootstrap: { initdb: { database: appdb, owner: app, secret: { name: app-db-user } } }
          EOF
          kubectl -n jenkins wait cluster/${params.NEW_CLUSTER} --for=condition=Ready --timeout=10m
        """ } } }
        stage('Copy data') { steps { container('pg') {
          withCredentials([usernamePassword(credentialsId: 'app-db', usernameVariable: 'PGUSER', passwordVariable: 'PGPASSWORD')]) {
            sh """
              pg_dump -h app-db-rw.jenkins.svc -Fc appdb -f appdb.dump
              pg_restore -h ${params.NEW_CLUSTER}-rw.jenkins.svc -d appdb --no-owner --role=app appdb.dump
              psql -h ${params.NEW_CLUSTER}-rw.jenkins.svc -d appdb -c "ANALYZE;"
            """
          }
        } } }
        stage('Verify') { steps { container('pg') {
          withCredentials([usernamePassword(credentialsId: 'app-db', usernameVariable: 'PGUSER', passwordVariable: 'PGPASSWORD')]) {
            sh """
              OLD=\\$(psql -h app-db-rw.jenkins.svc -d appdb -tAc "select count(*) from pg_tables")
              NEW=\\$(psql -h ${params.NEW_CLUSTER}-rw.jenkins.svc -d appdb -tAc "select count(*) from pg_tables")
              [ "\\$OLD" = "\\$NEW" ] || { echo table count mismatch; exit 1; }
            """
          }
        } } }
        stage('Cut over') {
          input { message "Switch PG_HOST to ${params.NEW_CLUSTER}?" ok "Do it" }
          steps { echo "Update values-*.yaml PG_HOST and helm upgrade; then delete old cluster after soak." }
        }
      }
    }
  ''') } }
}
```

**Major-upgrade gotchas**

- Extensions (`postgis`, `pg_stat_statements`) must exist in the new image at a compatible version.
- Collation changes between OS/glibc versions can silently corrupt indexes → run `REINDEX` after upgrade or use ICU collations.
- Old PVCs cannot be reused by a newer major – that is why a *new* cluster is created.
- Keep the old cluster for a soak period before deleting.

---

## 11. Upgrading: chart, Jenkins, plugins, Java

Four different things can change. Upgrade them one at a time so you know what broke.

### 11.1 Before any upgrade

```bash
helm -n jenkins get values jenkins > current-values.yaml          # what is really deployed
helm -n jenkins history jenkins                                    # revision list
kubectl -n jenkins get pvc                                         # name of JENKINS_HOME PVC
# snapshot the PVC (CSI VolumeSnapshot) or:
kubectl -n jenkins exec sts/jenkins -c jenkins -- tar czf - /var/jenkins_home > jenkins-home-$(date +%F).tgz
helm diff upgrade jenkins jenkins/jenkins -n jenkins -f values.yaml --version NEW   # plugin: helm diff
```

Read the chart changelog for every version you skip over: `https://github.com/jenkinsci/helm-charts/releases` and `charts/jenkins/CHANGELOG.md`. Major chart versions have migration docs (`UPGRADING.md`, e.g. 4→5 removed `controller.backup`, renamed image fields).

### 11.2 Upgrade the chart version

```bash
helm repo update
helm upgrade jenkins jenkins/jenkins -n jenkins -f values.yaml --version 5.9.40 --wait
kubectl -n jenkins rollout status sts/jenkins
```

If something is wrong: `helm rollback jenkins <previous revision> -n jenkins`. Note that rollback restores manifests, **not** `JENKINS_HOME` – that's what the snapshot is for.

### 11.3 Upgrade Jenkins itself

Change `controller.image.tag`, e.g. `2.568.3-jdk21` → `2.581.1-jdk21`. Rules:

- Go LTS → LTS; read "Upgrading to Jenkins LTS x.y" guides on jenkins.io.
- **Java**: 2.555.1+ needs Java 21/25; if your image tag ends in `jdk17` the pod will crash-loop with an `UnsupportedClassVersionError`. Also update `agent.image.tag` to a `jdk21` inbound agent, and `remoting.jar` minimums (2.555 raised it) – old custom agent images stop connecting.
- Plugins compiled against a newer core won't load on an older core. Upgrade core first, then plugins.
- Jenkins ≥ 2.5xx ships a redesigned Manage Jenkins UI; custom Groovy init scripts that scrape pages may break.

### 11.4 Upgrade plugins (the usual cause of trouble)

Production pattern:

```yaml
controller:
  installLatestPlugins: false
  overwritePlugins: true
  installPlugins:
    - kubernetes:4360.v55a_4a_c5d6c5c
    - workflow-aggregator:608.v67378e9d3db_1
    - git:5.8.0
    - configuration-as-code:1990.v2fa_3cd5d1b_5c
  additionalPlugins:
    - job-dsl:1.92
    - matrix-auth:3.2.6
```

Workflow to bump:

1. In a **staging Jenkins**, go to *Manage Jenkins → Plugins → Updates*, note the versions, or use the plugin-installation-manager tool: `java -jar jenkins-plugin-manager.jar --jenkins-version 2.568.3 --plugin-file plugins.txt --available-updates`.
2. Update the pinned versions in values, `helm upgrade` staging, run the smoke jobs (section 12).
3. Promote the same values file to prod.

Alternative: **bake plugins into your own image** (`FROM jenkins/jenkins:2.568.3-jdk21` + `jenkins-plugin-cli --plugins ...`) and set `installPlugins: []`, `initializeOnce: true`. Faster startups, immutable, but you must rebuild the image to change anything.

### 11.5 Upgrade Istio

`istioctl upgrade` or canary revisions (`istio.io/rev`). Restart the Jenkins StatefulSet afterwards so the controller gets the new sidecar: `kubectl -n jenkins rollout restart sts/jenkins`. Agent pods pick it up automatically (they're new pods each time).

### 11.6 Zero-downtime? Mostly no

Jenkins is a single-process StatefulSet; an upgrade means ~1–3 minutes of outage. Running builds on agent pods **survive** if the controller comes back within the agent reconnect window (set `-Dhudson.slaves.ChannelPinger.pingIntervalSeconds` / WebSocket reconnect) – but console output may be lost and `input` steps resume. Schedule upgrades in a quiet window and put Jenkins in **Prepare for Shutdown** first (`/manage/prepareShutdown` or `jenkins-cli quiet-down`).

---

## 12. Testing your setup

| Test | Command / action | Expect |
|---|---|---|
| Helm's own test | `helm test jenkins -n jenkins` | `Phase: Succeeded` (hits the UI with curl) |
| JCasC loaded cleanly | `kubectl -n jenkins logs sts/jenkins -c jenkins \| grep -i "casc"` | "Configuration as Code ... loaded" with no `ConfiguratorException` |
| Istio route | `curl -skI https://jenkins.example.com/login` | `HTTP/2 200`, header `server: istio-envoy` |
| Agent connectivity | run `tests/smoke-agent` | `AGENT_OK` in console, pod created & deleted |
| WebSocket agents | `kubectl -n jenkins logs <agent-pod> -c jnlp` | "Connected" via WebSocket, no port-50000 errors |
| Users & permissions | log in as `bob` → try to build | 403 on Build, can read |
| Secrets not leaked | `kubectl -n jenkins get cm -o yaml \| grep -i password` | nothing; passwords only via `${...}` |
| DB reachable from agent | run `hello-k8s` | prints Postgres version |
| Reload works | change `systemMessage`, `helm upgrade` | message changes within ~60 s, no pod restart |
| Restart survives | `kubectl -n jenkins delete pod jenkins-0` | jobs, users, build history still present |
| Istio mTLS | `istioctl x describe pod jenkins-0 -n jenkins` | shows policies; agents still connect |
| Load | run 10 builds at once | pods ≤ `containerCap`, controller RAM below limit (`kubectl top pod`) |

Automate the first eight in a `ci-selftest` pipeline triggered after every `helm upgrade` (e.g. from your GitOps tool's post-sync hook).

---

## 13. Key gotchas (read this twice)

1. **Istio sidecar on agent pods never exits** → zombie pods. Annotate `sidecar.istio.io/inject: "false"` (section 5.4).
2. **Java 21 required** from Jenkins 2.555.1. Images ending in `-jdk17` crash-loop.
3. **`jenkinsUrl` wrong** → broken links, agents trying to connect to `jenkins.jenkins.svc` from outside, CSRF "crumb" errors.
4. **Istio default 15 s timeout and automatic retries** → truncated console logs, duplicated POSTs. Set `timeout: 0s`, `retries.attempts: 0`.
5. **`installPlugins` replaces the default list** – if you set it, you must include `kubernetes`, `workflow-aggregator`, `git`, `configuration-as-code` yourself.
6. **`helm rollback` does not roll back `JENKINS_HOME`** (plugins already upgraded on disk). Snapshot the PVC.
7. **JCasC reload overwrites manual changes**: anything you click in *Manage Jenkins* that JCasC also defines is lost on reload. Good discipline; surprising at first.
8. **Secret variable naming**: `additionalExistingSecrets` exposes `${<secretName>-<keyName>}`. Dashes, not underscores; names are case-sensitive.
9. **fsGroup / permissions** on the PVC: if the pod logs `Permission denied` on `/var/jenkins_home`, set `controller.podSecurityContext.fsGroup: 1000` or fix the volume's ownership.
10. **Agent `containerCap` is per cloud**, not per template. Big fan-out jobs can starve others; use separate clouds or ResourceQuotas.
11. **`agent.namespace` different from release namespace** needs the Role created there (`rbac.create: true` handles it) **and** NetworkPolicies that allow agent → controller 8080.
12. **Strict mTLS + no sidecar on agents** = agents cannot reach the controller. Add a `PeerAuthentication` PERMISSIVE for the controller or keep sidecars with the exit hack.
13. **Port 50000 through Istio** must be declared TCP (`appProtocol: tcp` / port name `tcp-*`) or just use WebSocket.
14. **Memory**: the JVM default heap is 25 % of the container limit. Use `-XX:MaxRAMPercentage=70` and give the controller ≥ 4 GiB for anything beyond a toy.
15. **Plugin "latest" in production** drifts every restart with `installLatestPlugins: true`. Pin.
16. **Script security**: Job DSL seed scripts from untrusted repos run as admin. Keep `useScriptSecurity: true` for repo-based seeds and only disable it for inline values-file DSL.
17. **Postgres major upgrades don't reuse PVCs.** Dump/restore or operator-assisted `pg_upgrade`, never swap the image tag alone.
18. **Bitnami chart changes (2025)**: many default images moved; pin `image.tag` and `image.registry` or use CloudNativePG.
19. **Helm `--wait` with a long startup**: raise `--timeout` and `startupProbe.failureThreshold`; otherwise Helm marks the release failed while Jenkins is still installing plugins.
20. **`persistence.enabled: false` in a demo, forgotten in prod** → everything vanishes on the first pod restart.

---

## 14. Best practices checklist

- [ ] Pin chart version, Jenkins image tag, agent image tag, and plugin versions.
- [ ] All secrets in Kubernetes Secrets / CSI driver; none in `values.yaml`; `values.yaml` in git.
- [ ] `numExecutors: 0` on the controller; everything builds in agent pods.
- [ ] `agent.websocket: true`; agents without Istio sidecar; `garbageCollection` on.
- [ ] Istio VirtualService: `timeout: 0s`, no retries, TLS at the gateway, `httpsRedirect`.
- [ ] Authorization set to matrix or role-based before the first external user logs in; keep an escape-hatch admin.
- [ ] JCasC + Job DSL for *everything*; UI is read-only in practice.
- [ ] Separate dev/staging/prod with overlay values files; promote the same file.
- [ ] PVC with `helm.sh/resource-policy: keep`, scheduled snapshots, restore tested once.
- [ ] Prometheus plugin + ServiceMonitor; alert on queue length and controller memory.
- [ ] Resource requests/limits on every pod template; `ResourceQuota` on the agent namespace.
- [ ] Upgrade order: snapshot → chart → core → agent image → plugins → smoke tests → prod.
- [ ] Postgres via an operator with backups to object storage; per-build test DBs as sidecars.

---

## 15. Pros and cons of every big choice

| Choice | Option A | Option B |
|---|---|---|
| **Expose Jenkins** | Istio VirtualService – rich routing, mTLS, observability; Istio-specific | Ingress/Gateway API – simpler, portable; fewer features |
| **Agent transport** | WebSocket – only HTTPS, proxy-friendly, no 50000; slight overhead | TCP 50000 – classic, a bit faster; extra port and Istio TCP config |
| **Pod templates** | In `values.yaml` – admin control, consistent; needs a Helm upgrade to change | In Jenkinsfile – dev freedom, lives with code; can be abused |
| **Plugins** | Installed at boot from list – easy to change; slower start, needs internet | Baked into custom image – fast, immutable, air-gap friendly; rebuild per change |
| **Users** | Local realm – zero dependencies; passwords in Jenkins, no MFA | OIDC/LDAP – SSO, MFA, groups; depends on IdP, needs escape hatch |
| **Permissions** | Matrix – simple to read; gets long with many teams | Role-strategy – scalable, folder patterns; more concepts |
| **Default jobs** | Job DSL in values – one file; messy Groovy-in-YAML | Seed job + repo – reviewable, scalable; extra repo and bootstrap step |
| **Postgres** | Operator (CNPG) – backups/HA/upgrades handled; operator to manage | Plain chart/StatefulSet – minimal; you do everything by hand |
| **Postgres major upgrade** | Dump/restore – simple, portable; slow, downtime | In-place/operator `pg_upgrade` – fast; needs testing and disk |
| **Jenkins HA** | Single StatefulSet – simple, supported; minutes of downtime per upgrade | CloudBees CI / multiple controllers – HA; licence or complexity |

---

## 16. Complete reference `values.yaml`

A production-leaning file combining everything above (replace hosts, images, and secret names):

```yaml
controller:
  image:
    repository: docker.io/jenkins/jenkins
    tag: "2.568.3-jdk21"
  imagePullPolicy: IfNotPresent
  jenkinsUrl: https://jenkins.example.com
  jenkinsAdminEmail: jenkins@example.com
  admin:
    existingSecret: jenkins-admin
    createSecret: false
  numExecutors: 0
  executorMode: EXCLUSIVE
  serviceType: ClusterIP
  servicePort: 8080
  agentListenerEnabled: false          # websocket agents
  ingress: { enabled: false }

  installLatestPlugins: false
  overwritePlugins: true
  installPlugins:
    - kubernetes:4360.v55a_4a_c5d6c5c
    - workflow-aggregator:608.v67378e9d3db_1
    - git:5.8.0
    - configuration-as-code:1990.v2fa_3cd5d1b_5c
  additionalPlugins:
    - job-dsl:1.92
    - matrix-auth:3.2.6
    - role-strategy:759.v6ff17b_6bd7d4
    - credentials-binding:687.v619cb_15e923f
    - kubernetes-credentials-provider:1.262.v2a_8c6e1c1c38
    - pipeline-stage-view:2.34
    - prometheus:813.v3b_2b_15b_02d20
    - timestamper:1.28
    - lockable-resources:1327.ved786b_a_197e0
    - oic-auth:4.512.v9c9c8c0a_2e46
    - slack:752.ve3f3d6f3a_8d0

  resources:
    requests: { cpu: "1", memory: "4Gi" }
    limits:   { cpu: "4", memory: "8Gi" }
  javaOpts: >-
    -XX:MaxRAMPercentage=70
    -XX:+UseG1GC
    -Djenkins.install.runSetupWizard=false
    -Dhudson.model.DirectoryBrowserSupport.CSP=
    -Duser.timezone=America/Chicago
  containerEnv:
    - { name: TZ, value: America/Chicago }

  healthProbes: true
  probes:
    startupProbe: { failureThreshold: 60, periodSeconds: 10 }
  podSecurityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, runAsNonRoot: true }
  nodeSelector: { workload: ci }
  tolerations:
    - { key: ci, operator: Equal, value: "true", effect: NoSchedule }

  csrf:
    defaultCrumbIssuer: { enabled: true, proxyCompatability: true }
  prometheus:
    enabled: true
    serviceMonitorNamespace: monitoring

  sidecars:
    configAutoReload: { enabled: true }

  additionalExistingSecrets:
    - { name: jenkins-users,  keyName: alice-password }
    - { name: jenkins-users,  keyName: bob-password }
    - { name: app-db-user,    keyName: password }
    - { name: github-token,   keyName: token }
    - { name: oidc-client,    keyName: secret }

  JCasC:
    defaultConfig: true
    securityRealm: |-
      local:
        allowsSignup: false
        users:
          - { id: "${chart-admin-username}", name: "Admin", password: "${chart-admin-password}" }
          - { id: "alice", name: "Alice", password: "${jenkins-users-alice-password}" }
          - { id: "bob",   name: "Bob",   password: "${jenkins-users-bob-password}" }
    authorizationStrategy: |-
      roleBased:
        roles:
          global:
            - { name: admin,  permissions: ["Overall/Administer"], entries: [{ user: "${chart-admin-username}" }] }
            - { name: dev,    permissions: ["Overall/Read","Job/Build","Job/Cancel","Job/Read","Job/Workspace","Run/Replay","View/Read"], entries: [{ user: alice }] }
            - { name: reader, permissions: ["Overall/Read","Job/Read","View/Read"], entries: [{ group: authenticated }] }
          items:
            - { name: tests-folder, pattern: "tests/.*", permissions: ["Job/Build","Job/Configure","Job/Create","Job/Read"], entries: [{ user: bob }] }
    configScripts:
      system: |
        jenkins:
          systemMessage: "Managed by Helm + JCasC – edit git, not this UI."
          globalNodeProperties:
            - envVars:
                env:
                  - { key: ENVIRONMENT, value: "dev" }
                  - { key: PG_HOST, value: "app-db-rw.jenkins.svc" }
                  - { key: PG_DB, value: "appdb" }
        security:
          globalJobDslSecurityConfiguration: { useScriptSecurity: false }
        unclassified:
          location: { url: "https://jenkins.example.com", adminAddress: "jenkins@example.com" }
          timestamper: { allPipelines: true }
      credentials: |
        credentials:
          system:
            domainCredentials:
              - credentials:
                  - usernamePassword: { scope: GLOBAL, id: app-db, username: app, password: "${app-db-user-password}" }
                  - string: { scope: GLOBAL, id: github-token, secret: "${github-token-token}" }
      seed: |
        jobs:
          - script: >
              folder('tests')
              freeStyleJob('seed') {
                scm { git { remote { url('https://github.com/example/jenkins-jobs.git'); credentials('github-token') }; branch('main') } }
                triggers { scm('H/10 * * * *') }
                steps { jobDsl { targets('jobs/**/*.groovy'); removedJobAction('DELETE'); removedViewAction('DELETE') } }
              }
              pipelineJob('tests/smoke-agent') {
                definition { cps { sandbox(true); script('pipeline { agent { label "k8s" } stages { stage("ok") { steps { sh "echo AGENT_OK" } } } }') } }
              }
              queue('seed')

agent:
  enabled: true
  image: { repository: jenkins/inbound-agent, tag: "3327.v868139a_d00e0-2-jdk21" }
  namespace: jenkins
  podName: default
  customJenkinsLabels: [ "k8s", "linux" ]
  websocket: true
  podRetention: Never
  idleMinutes: 0
  containerCap: 25
  connectTimeout: 100
  resources:
    requests: { cpu: "250m", memory: "512Mi" }
    limits:   { cpu: "1", memory: "1Gi" }
  annotations:
    sidecar.istio.io/inject: "false"
  restrictedPssSecurityContext: true
  garbageCollection: { enabled: true, timeout: 300 }
  podTemplates:
    maven: |
      - name: maven
        label: maven
        inheritFrom: default
        containers:
          - { name: maven, image: "maven:3.9-eclipse-temurin-21", command: sleep, args: infinity, resourceRequestCpu: 500m, resourceRequestMemory: 1Gi, resourceLimitMemory: 3Gi }

serviceAccountAgent:
  create: true
  name: jenkins-agent
rbac:
  create: true
  readSecrets: true
serviceAccount:
  create: true
persistence:
  enabled: true
  size: 50Gi
  annotations: { helm.sh/resource-policy: keep }
networkPolicy:
  enabled: true
  internalAgents:
    allowed: true
    namespaceLabels: { kubernetes.io/metadata.name: jenkins }
checkDeprecation: true
```

---

## 17. Cheat sheet of commands

```bash
# Install / upgrade / rollback
helm upgrade --install jenkins jenkins/jenkins -n jenkins -f values.yaml -f values-dev.yaml --version 5.9.40 --wait --timeout 15m
helm history jenkins -n jenkins
helm rollback jenkins 3 -n jenkins
helm diff upgrade jenkins jenkins/jenkins -n jenkins -f values.yaml      # needs helm-diff plugin
helm show values jenkins/jenkins --version 5.9.40 | less

# Secrets
kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo

# Logs & debugging
kubectl -n jenkins logs -f sts/jenkins -c jenkins
kubectl -n jenkins logs sts/jenkins -c config-reload
kubectl -n jenkins get pods -l jenkins/jenkins-jenkins-agent=true       # agent pods
kubectl -n jenkins describe pod <agent-pod>
istioctl analyze -n jenkins
istioctl proxy-config routes deploy/istio-ingressgateway -n istio-system | grep jenkins

# JCasC
curl -X POST -u admin:$TOKEN "https://jenkins.example.com/reload-configuration-as-code/?casc-reload-token=$CASC_RELOAD_TOKEN"
# or via UI: Manage Jenkins → Configuration as Code → Reload existing configuration

# Jenkins CLI
curl -sO https://jenkins.example.com/jnlpJars/jenkins-cli.jar
java -jar jenkins-cli.jar -s https://jenkins.example.com -auth admin:$TOKEN version
java -jar jenkins-cli.jar -s https://jenkins.example.com -auth admin:$TOKEN build tests/smoke-agent -s -v
java -jar jenkins-cli.jar -s https://jenkins.example.com -auth admin:$TOKEN quiet-down   # before upgrades

# Postgres (CloudNativePG)
kubectl cnpg status app-db -n jenkins                # kubectl plugin
kubectl cnpg psql app-db -n jenkins
kubectl cnpg backup app-db -n jenkins

# Uninstall (keeps the PVC if resource-policy: keep)
helm uninstall jenkins -n jenkins
```

---

### Where to look next

- Chart source, `VALUES.md`, `CHANGELOG.md`, `UPGRADING.md`: `github.com/jenkinsci/helm-charts/tree/main/charts/jenkins`
- Kubernetes plugin docs: `github.com/jenkinsci/kubernetes-plugin`
- JCasC demos: `github.com/jenkinsci/configuration-as-code-plugin/tree/master/demos`
- Job DSL API viewer: `<your-jenkins>/plugin/job-dsl/api-viewer/`
- Istio traffic management: `istio.io/latest/docs/tasks/traffic-management/`
- CloudNativePG: `cloudnative-pg.io/documentation/`
- Jenkins LTS changelog & upgrade guides: `jenkins.io/changelog-stable/`, `jenkins.io/doc/upgrade-guide/`

*Plugin version numbers and image tags in this document are examples – always take the exact current values from the update center and Docker Hub before applying.*
