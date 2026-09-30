# Terraform + Helm + State, Explained Like You're in Middle School (Cover-Everything Edition)

> **Who this is for:** anyone who can open a terminal. You don't need to know Terraform. Knowing a little Helm helps (the companion Helm tutorial covers it), but Part 2 reviews what you need.
> **What you'll learn:** how to make Terraform install Helm charts, why Terraform keeps a "state" file, every way to store that state safely (Azure, AWS, Google, HCP Terraform, Kubernetes itself, Postgres, GitLab, OpenTofu encryption), how state and Helm's own memory relate, and the patterns and gotchas that separate "works on my laptop" from "works for a team".
> **Current as of September 2026:** Terraform 1.15.x (1.16 in release candidate), Helm provider 3.3 (which embeds the Helm 3.20 library), Kubernetes provider 2.38 / 3.x, Helm CLI 4.x, OpenTofu 1.x.

**How to read this**

| Symbol | Meaning |
|---|---|
| 🛒 | Grocery-store way of understanding the idea |
| 🏫 | School / classroom way of understanding the idea |
| ✅ | Best practice — do this |
| ⚠️ | Gotcha — something that bites people |
| 🧪 | Try it yourself |
| 📝 | Real config you can copy |

Anything in `<angle brackets>` is a placeholder you replace.

---

## Table of contents

1. [Quick start: Terraform installs a chart, keeps state, moves state (30 minutes)](#part-1)
2. [Background: what Terraform is and how to read HCL](#part-2)
3. [State, completely](#part-3)
4. [Backends: every place you can keep state](#part-4)
5. [The Helm provider, argument by argument](#part-5)
6. [Patterns that work for teams](#part-6)
7. [Cloud setups: AKS, EKS, GKE](#part-7)
8. [Best practices](#part-8)
9. [Gotchas (the big list)](#part-9)
10. [Troubleshooting and command cheat sheet](#part-10)
11. [Glossary and field-trip exercises](#part-11)

---

<a id="part-1"></a>
## Part 1 — Quick start: Terraform installs a chart, keeps state, moves state

We start by *doing*. In 30 minutes you'll install a chart with Terraform, look inside the state file, change something, and move the state to a shared, locked location — all on your laptop, no cloud account needed.

### Step 1: install the tools

You need **Terraform** (or **OpenTofu**, its open-source twin — every command in this tutorial works with `tofu` instead of `terraform`), **kubectl**, **Helm**, **kind**, and Docker or Podman.

**macOS**

```bash
brew tap hashicorp/tap && brew install hashicorp/tap/terraform     # or: brew install opentofu
brew install kind kubectl helm
brew install --cask docker                                          # or podman
```

**Windows (PowerShell)**

```powershell
winget install HashiCorp.Terraform                                  # or: winget install OpenTofu.OpenTofu
winget install Kubernetes.kind Kubernetes.kubectl Helm.Helm Docker.DockerDesktop
```

**Linux (Debian/Ubuntu)**

```bash
# Terraform: HashiCorp's apt repo — https://developer.hashicorp.com/terraform/install has the exact commands
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
# kind / kubectl / helm: see the Helm tutorial's Part 1, or https://kind.sigs.k8s.io, https://kubernetes.io/docs/tasks/tools, https://helm.sh/docs/intro/install
```

Check:

```bash
terraform version      # Terraform v1.15.x
kind version && kubectl version --client && helm version
```

✅ Teams pin the Terraform version with a `.terraform-version` file and a tool like `tenv` or `mise`, so everyone (and CI) runs the same binary.

### Step 2: a cluster to point at

```bash
kind create cluster --name school
kubectl config current-context        # kind-school   ← Terraform will use this context name
```

🏫 Terraform is a **school secretary with a clipboard**. The clipboard lists what the school should have. The secretary compares the clipboard with reality every morning and orders whatever's missing. The cluster is the school; a chart is a class to run.

### Step 3: write the configuration

Make a folder and one file:

```bash
mkdir -p ~/tf-quickstart && cd ~/tf-quickstart
```

📝 `main.tf`

```hcl
terraform {
  required_version = ">= 1.11"                  # the Terraform CLI version this config needs
  required_providers {
    helm = {
      source  = "hashicorp/helm"                # where to download the plugin from (registry.terraform.io)
      version = "~> 3.3"                        # any 3.3.x — never leave this out
    }
  }
}

# How to reach the cluster. Same information kubectl uses.
provider "helm" {
  kubernetes = {                                # v3 provider: an attribute (=), not a block
    config_path    = "~/.kube/config"
    config_context = "kind-school"
  }
}

# One Helm release, described as a Terraform resource.
resource "helm_release" "podinfo" {
  name             = "podinfo"                  # helm release name
  repository       = "oci://ghcr.io/stefanprodan/charts"
  chart            = "podinfo"
  version          = "6.9.1"                    # chart version — pin it (check: helm show chart oci://ghcr.io/stefanprodan/charts/podinfo)
  namespace        = "demo"
  create_namespace = true

  wait    = true                                # don't return until pods are Ready
  timeout = 300                                 # seconds

  set = [                                       # the same as helm --set, as a list of objects
    { name = "replicaCount", value = "1" },
    { name = "ui.message",   value = "Hello from Terraform" },
  ]
}

output "release_status" {
  value = helm_release.podinfo.status           # "deployed" when it worked
}
```

Read it top to bottom:

1. The `terraform` block says which Terraform version and which **providers** (plugins) this configuration needs.
2. The `provider "helm"` block says how to reach the cluster.
3. The `resource "helm_release" "podinfo"` block is *one Helm release described as data*. Terraform's job is to make a release exist that matches this block. The two names (`"helm_release"` = the type, `"podinfo"` = your label) together form the resource's **address**: `helm_release.podinfo`.
4. The `output` prints something after apply.

### Step 4: `init` — download the plugin

```bash
terraform init
# Initializing the backend...
# Initializing provider plugins...
# - Installing hashicorp/helm v3.3.0...
# Terraform has created a lock file .terraform.lock.hcl to record the provider selections it made above.
```

Two new things appear: a `.terraform/` folder (the downloaded plugin — don't commit it) and `.terraform.lock.hcl` (the exact provider version and checksums — **do** commit it, like `package-lock.json`).

### Step 5: `plan` — see what would happen, change nothing

```bash
terraform plan
# Terraform will perform the following actions:
#   # helm_release.podinfo will be created
#   + resource "helm_release" "podinfo" {
#       + chart            = "podinfo"
#       + name             = "podinfo"
#       + namespace        = "demo"
#       + status           = (known after apply)
#       + version          = "6.9.1"
#       ...
# Plan: 1 to add, 0 to change, 0 to destroy.
```

`+` = create, `~` = update in place, `-` = destroy, `-/+` = destroy and recreate. **Always read the last line.** "1 to add, 0 to change, 0 to destroy" is exactly what we want.

### Step 6: `apply` — do it

```bash
terraform apply
# ... the same plan ...
# Do you want to perform these actions? Enter a value: yes
# helm_release.podinfo: Creating...
# helm_release.podinfo: Still creating... [10s elapsed]
# helm_release.podinfo: Creation complete after 24s [id=podinfo]
# Outputs:
# release_status = "deployed"
```

Check with the normal tools — Terraform used Helm's library under the hood, so Helm knows about the release:

```bash
helm list -n demo                                       # podinfo   demo   1   deployed   podinfo-6.9.1
kubectl get pods -n demo                                # podinfo-…  1/1  Running
kubectl port-forward -n demo svc/podinfo 9898:9898 &    # then:
curl -s localhost:9898 | grep message                   # "message": "Hello from Terraform"
kill %1
```

### Step 7: look at the state file (the clipboard)

A new file `terraform.tfstate` appeared. Open it:

```bash
terraform state list                       # helm_release.podinfo
terraform state show helm_release.podinfo  # every attribute Terraform recorded
jq '.resources[0].instances[0].attributes.metadata' terraform.tfstate
```

```json
{
  "app_version": "6.9.1",
  "chart": "podinfo",
  "name": "podinfo",
  "namespace": "demo",
  "revision": 1,
  "version": "6.9.1",
  "values": "{\"replicaCount\":1,\"ui\":{\"message\":\"Hello from Terraform\"}}",
  ...
}
```

🛒 This is the store's **inventory ledger**. It doesn't hold the goods; it records *what Terraform put on which shelf* so that next time it can find them again. Lose the ledger and Terraform no longer knows the release exists — it would try to create it again (and Helm would refuse, because the release is already there).

### Step 8: change something

Edit `main.tf`: change `"Hello from Terraform"` to `"Hello again"`, and `replicaCount` to `"2"`.

```bash
terraform plan
#   # helm_release.podinfo will be updated in-place
#   ~ resource "helm_release" "podinfo" {
#       ~ set = [
#           ~ { name = "replicaCount", value = "1" -> "2" },
#           ~ { name = "ui.message",   value = "Hello from Terraform" -> "Hello again" },
#         ]
#       ~ metadata = { … revision = 1 -> (known after apply) … }
# Plan: 0 to add, 1 to change, 0 to destroy.
terraform apply -auto-approve
helm history podinfo -n demo               # revision 2: "Upgrade complete"
kubectl get pods -n demo                   # 2 pods
```

Terraform ran a `helm upgrade` for you. Helm's own memory (the release Secret) now says revision 2, and Terraform's state says revision 2. **Two clipboards, and they must agree** — Part 3 is about what happens when they don't.

### Step 9: move the state somewhere shared (still no cloud account)

Local `terraform.tfstate` is fine for one person on one laptop. The moment two people (or you + CI) run Terraform, you need a **remote backend** with **locking**. The Kubernetes cluster itself can be a backend — state goes into a Secret, and a Lease object acts as the lock:

```bash
kubectl create namespace terraform-state
```

Add to `main.tf`, inside the `terraform { … }` block:

```hcl
  backend "kubernetes" {
    secret_suffix  = "quickstart"              # Secret will be named tfstate-default-quickstart
    namespace      = "terraform-state"
    config_path    = "~/.kube/config"
    config_context = "kind-school"
  }
```

Changing a backend requires re-running `init`, and Terraform offers to copy the existing state across:

```bash
terraform init -migrate-state
# Do you want to copy existing state to the new backend? Enter a value: yes
kubectl get secret -n terraform-state          # tfstate-default-quickstart   Opaque
rm terraform.tfstate terraform.tfstate.backup  # the local copies are now stale; delete them so nobody uses them
terraform plan                                 # No changes. (state was read from the Secret)
```

Watch the lock appear during an apply:

```bash
terraform apply -auto-approve &                # run in the background…
kubectl get lease -n terraform-state           # lock-tfstate-default-quickstart  ← exists only while Terraform runs
wait
```

If you open a second terminal and run `terraform plan` *during* the apply, you get **"Error acquiring the state lock"**. That's the point: one writer at a time.

🏫 One class roster on the office wall (remote state), and a "someone is editing" sign you must hang up before touching it (the lock). Anyone who walks in while the sign is up waits.

(The Kubernetes backend is convenient for clusters that own themselves, but it has a 1 MiB limit and disappears with the cluster. For real teams you'll use cloud storage or HCP Terraform — Part 4 covers every option.)

### Step 10: destroy

```bash
terraform destroy                              # plan shows "- resource"; type yes
helm list -n demo                              # empty
kind delete cluster --name school              # only when you're done with Part 1
```

### What just happened?

1. `init` downloaded the Helm provider and wrote a lock file.
2. `plan` compared **configuration** (what you want) with **state** (what Terraform did last time) and **reality** (what the cluster has) and computed a diff.
3. `apply` executed the diff by calling the Helm library, then wrote what it did into **state**.
4. Changing config produced a smaller diff → an in-place `helm upgrade`.
5. `init -migrate-state` moved the state into a shared, lockable place.
6. `destroy` planned the reverse and ran `helm uninstall`.

Everything else in this tutorial is detail about those six lines.

---

<a id="part-2"></a>
## Part 2 — Background: what Terraform is and how to read HCL

### What Terraform is

Terraform is a program that turns **descriptions** of infrastructure into **real infrastructure**, and keeps them matched. It was created by HashiCorp in 2014; HashiCorp was acquired by IBM in 2025. Its language is **HCL** (HashiCorp Configuration Language). Since a 2023 license change, the community maintains a fork called **OpenTofu** under the Linux Foundation; it reads the same files and adds a few features of its own (notably state encryption). Everything in this tutorial applies to both unless marked.

🛒 A grocery **store manager's ordering system**: you write the planogram (which products on which shelves, how many). Every morning the system checks the shelves and places orders or removals to match. You never say "go buy 3 boxes"; you say "there should be 3 boxes".

Terraform knows nothing about clouds or Kubernetes by itself. It loads **providers** — plugins that speak one API each:

| Provider | Talks to | Typical resources |
|---|---|---|
| `hashicorp/helm` | Helm's library → Kubernetes | `helm_release` (and the `helm_template` data source) |
| `hashicorp/kubernetes` | The Kubernetes API directly | `kubernetes_namespace_v1`, `kubernetes_secret_v1`, `kubernetes_manifest` |
| `hashicorp/azurerm`, `hashicorp/aws`, `hashicorp/google` | The clouds | clusters, storage accounts/buckets, IAM |
| `hashicorp/random`, `hashicorp/tls`, `hashicorp/local`, `hashicorp/http` | Nothing external | passwords, certificates, files, HTTP fetches |
| `alekc/kubectl` (community) | Kubernetes API via kubectl-like apply | `kubectl_manifest` for raw YAML |

### The three things Terraform juggles

```text
    CONFIGURATION (.tf files)         STATE (terraform.tfstate)          REALITY (the cluster / cloud)
    "what I want"                     "what I did last time, and IDs"    "what actually exists"
             \                              |                              /
              \                             |                             /
               `-------------------- terraform plan ----------------------'
                                            |
                                     a diff to apply
```

- **Configuration → State**: what's new, changed, or removed since the last apply.
- **State → Reality** (called *refresh*): has someone changed things behind Terraform's back? (drift)
- A plan is the combination. Apply executes it and rewrites state.

### HCL in twenty minutes

HCL has **blocks** (with a type and labels), **arguments** (`name = value`), and **expressions**.

```hcl
# A block: type "resource", labels "helm_release" and "cnpg", body in braces
resource "helm_release" "cnpg" {
  name      = "cnpg"                       # argument: string
  version   = "0.26.1"
  timeout   = 600                          # number
  wait      = true                         # bool
  values    = [file("values/cnpg.yaml")]   # list of strings, built with a function call
  set = [                                  # list of objects
    { name = "replicaCount", value = "1" },
  ]
  namespace = kubernetes_namespace_v1.cnpg.metadata[0].name   # a reference to another resource's attribute
}
```

**Block types you'll use**

| Block | Purpose |
|---|---|
| `terraform { required_version, required_providers, backend "x" { } / cloud { } }` | Settings for the config itself |
| `provider "helm" { … }` | Configure a plugin (may repeat with `alias = "..."` for a second cluster) |
| `resource "TYPE" "NAME" { … }` | Something Terraform creates, updates, destroys |
| `data "TYPE" "NAME" { … }` | Something Terraform only *reads* (a cluster's endpoint, an existing Secret) |
| `variable "x" { type, default, description, sensitive, validation { } }` | An input |
| `locals { a = …, b = … }` | Named intermediate values |
| `output "x" { value, sensitive }` | A result shown after apply and readable by other configs |
| `module "x" { source, version, inputs… }` | Reuse a folder of `.tf` files |
| `moved { from, to }`, `removed { from }`, `import { to, id }` | Refactoring and adoption without editing state by hand (Part 3) |
| `check "x" { assert { } }` | Post-apply assertions that warn but don't fail |
| `ephemeral "TYPE" "NAME" { }` | A value fetched at run time and **never written to state** (Terraform 1.10+) |

**Expressions and references**

```hcl
var.cluster_name                       # a variable
local.common_labels                    # a local
helm_release.cnpg.metadata.revision    # an attribute of a resource ("metadata" is a single object in provider 3.x)
data.aws_eks_cluster.this.endpoint     # an attribute of a data source
module.eks.cluster_name                # an output of a module
path.module, path.root, terraform.workspace   # built-ins
```

References create **dependencies**: Terraform builds a graph and creates things in order, in parallel where possible. When a dependency isn't visible in a reference (e.g. "install the operator before the chart that needs its CRDs"), state it: `depends_on = [helm_release.cnpg]`.

**Types**: `string`, `number`, `bool`, `list(T)`, `map(T)`, `set(T)`, `object({ a = string, b = number })`, `tuple`, `any`. Terraform converts automatically where safe (`"600"` → number) but not the other way in structural types.

**Strings and templates**

```hcl
name  = "aks-${var.env}"                                    # interpolation
value = <<-EOT
  multi-line heredoc; the "-" strips leading indentation
EOT
```

**Conditionals, loops, functions**

```hcl
replicas = var.env == "prod" ? 3 : 1                        # ternary
names    = [for r in var.releases : r.name]                 # for expression → list
by_name  = { for r in var.releases : r.name => r }          # for expression → map
enabled  = [for r in var.releases : r if r.enabled]         # filter

file("values/x.yaml")                                       # read a file
templatefile("values/x.yaml.tftpl", { domain = var.domain })   # read a file and fill ${domain}
yamlencode({ replicaCount = 2, image = { tag = "2.0.1" } })    # HCL → YAML string (great for values)
yamldecode(file("x.yaml"))                                  # YAML → HCL
jsonencode(x), jsondecode(s), base64decode(s), base64encode(s)
merge(map1, map2), lookup(map, "key", "default"), try(expr, fallback), coalesce(a, b), format("%s-%s", a, b)
length(list), keys(map), values(map), contains(list, x), join(",", list), split(",", s), trimspace(s)
```

`terraform console` lets you type any expression and see its value — the fastest way to learn these.

**`count` vs `for_each`**

```hcl
resource "helm_release" "app" {
  for_each = var.apps                        # a map: { "lunch-api" = {...}, "report-bot" = {...} }
  name     = each.key
  chart    = each.value.chart
  version  = each.value.version
}
# address: helm_release.app["lunch-api"]
```

`count = 3` gives `helm_release.app[0]`, `[1]`, `[2]`; deleting the first shifts the others and Terraform *recreates* them. `for_each` over a map keeps stable keys. ✅ Use `for_each`; use `count` only for `count = var.enabled ? 1 : 0`.

**`lifecycle`**

```hcl
resource "helm_release" "keycloak" {
  # …
  lifecycle {
    prevent_destroy       = true           # refuse any plan that would destroy this
    ignore_changes        = [values]       # stop diffing this argument (use sparingly)
    create_before_destroy = true           # order for replacements (rarely for helm_release)
    replace_triggered_by  = [kubernetes_secret_v1.db.data]   # recreate when something else changes
    precondition {
      condition     = var.env != "prod" || var.instances >= 2
      error_message = "prod needs ≥2 instances"
    }
    postcondition {
      condition     = self.status == "deployed"
      error_message = "release not deployed"
    }
  }
}
```

**`dynamic` blocks** — a loop that produces nested blocks. In the Helm provider v3, `set` is a *list attribute*, so you use a `for` expression, not `dynamic`:

```hcl
set = [for k, v in var.overrides : { name = k, value = tostring(v) }]
```

**Variables come from** (last wins): `default` in the block → `terraform.tfvars` / `*.auto.tfvars` → `-var-file=prod.tfvars` → `-var x=1` → environment `TF_VAR_x`. Mark passwords `sensitive = true` so they're hidden in plans (they still land in state — Part 3).

**Modules** are just folders. A **root module** is the folder you run `terraform apply` in; it owns one state. Child modules are called with `module "x" { source = "./modules/app" }` (local), `source = "terraform-aws-modules/eks/aws"` + `version` (registry), or a Git URL. Inputs are the module's `variable`s; results are its `output`s.

**Files Terraform reads**: every `*.tf` and `*.tf.json` in the folder (not sub-folders), in alphabetical order (order doesn't matter). Convention: `versions.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `backend.tf`.

**Environment variables that matter**

| Variable | Effect |
|---|---|
| `TF_VAR_name` | Sets `var.name` |
| `TF_LOG=DEBUG` (or `TRACE`, `INFO`), `TF_LOG_PATH` | Verbose logs; `TF_LOG_PROVIDER` for providers only |
| `TF_CLI_ARGS`, `TF_CLI_ARGS_plan` | Extra flags for every command / one command |
| `TF_PLUGIN_CACHE_DIR` | Share downloaded providers across folders (CI speed-up) |
| `TF_WORKSPACE` | Select a workspace non-interactively |
| `TF_IN_AUTOMATION` | Tells Terraform it's in CI (adjusts messages) |
| `TF_DATA_DIR` | Where `.terraform/` lives |
| `KUBE_CONFIG_PATH`, `KUBECONFIG` | Read by the Helm/Kubernetes providers when no explicit config is given |

### The commands, in the order you learn them

```bash
terraform init            # download providers/modules, set up backend (safe to re-run)
terraform fmt -recursive  # format files (CI checks with -check)
terraform validate        # syntax and types, no cloud access
terraform plan            # diff; -out=tfplan saves it; -detailed-exitcode returns 2 if changes
terraform apply           # apply (asks yes); apply tfplan applies a saved plan without asking
terraform destroy         # plan + apply the reverse
terraform show            # human-readable state (or a saved plan); -json for tooling
terraform output          # outputs; -raw for scripts; -json
terraform console         # REPL for expressions
terraform state …         # list/show/mv/rm/pull/push (Part 3)
terraform import …        # adopt existing things (Part 3)
terraform providers       # which providers, and `providers lock` for multi-platform lock files
terraform workspace …     # list/new/select (Part 3)
terraform test            # run *.tftest.hcl tests
terraform graph | dot -Tsvg > g.svg   # the dependency graph (Terraform 1.16 can also emit Mermaid)
terraform force-unlock ID # break a stuck lock (carefully)
terraform login           # HCP Terraform / private registries
```

---

<a id="part-3"></a>
## Part 3 — State, completely

### Why state exists at all

Couldn't Terraform just look at the cluster every time? Four reasons it can't:

1. **Mapping.** Your config says `helm_release.podinfo`. Reality has a Helm release named `podinfo` in namespace `demo`. Something must record that *this block* corresponds to *that release* — otherwise renaming the block, or two blocks that look alike, are ambiguous. State stores `address → real ID`.
2. **Metadata.** Dependencies between resources (needed to destroy in the right order after you've deleted a block from config), provider versions, schema versions.
3. **Performance.** For big estates, asking every API for every object on every plan is slow; state is the cache, refreshed as needed.
4. **Values not readable back.** Some things (a random password, a value the API never returns) exist only in state.

🛒 The ledger isn't the shelves. It's what lets the manager say "the third freezer is *ours*, model X, ordered on Tuesday" without re-inspecting every freezer in the building.

### What's inside a state file

State is JSON. A trimmed real one from Part 1:

```json
{
  "version": 4,                       // state file format version
  "terraform_version": "1.15.9",
  "serial": 3,                        // increments on every write; backends use it to detect stale writes
  "lineage": "0f4b3c9a-…",            // unique ID of this state's "family"; protects against pushing the wrong state
  "outputs": { "release_status": { "value": "deployed", "type": "string" } },
  "resources": [
    {
      "mode": "managed",              // "managed" = resource, "data" = data source
      "type": "helm_release",
      "name": "podinfo",
      "provider": "provider[\"registry.terraform.io/hashicorp/helm\"]",
      "instances": [
        {
          "schema_version": 1,
          "attributes": { "name": "podinfo", "namespace": "demo", "version": "6.9.1", "status": "deployed",
                          "metadata": { "revision": 2, "values": "{…}", … }, "set": [ … ], … },
          "sensitive_attributes": [ ],   // paths marked sensitive (still stored in clear text!)
          "private": "…",                // provider-private data, base64
          "dependencies": [ "kubernetes_namespace_v1.demo" ]
        }
      ]
    }
  ]
}
```

Three consequences to memorize:

- **Everything is in clear text**, including `set_sensitive` values, `random_password` results, database URLs from data sources. `sensitive = true` only hides values in *output*. State must be treated like a password file.
- **`serial` and `lineage`** are how backends refuse a stale or foreign state push.
- **`dependencies`** is why `terraform destroy` still works after you delete blocks from config.

### The two clipboards: Terraform state vs Helm's release Secret

For `helm_release`, there are two memories:

| | Terraform state | Helm release Secret (`sh.helm.release.v1.<name>.v<N>`) |
|---|---|---|
| Written by | Terraform (via the Helm library) | Helm (library or CLI) |
| Contains | The arguments you set, chart/version, revision number, status, rendered values | The full chart, values, rendered manifest, hooks, status |
| Used for | Deciding whether *your config* changed | `helm upgrade` three-way merge, `helm rollback`, `helm history` |

They must agree. Ways they drift, and what you'll see:

| What someone did | Next `terraform plan` | Fix |
|---|---|---|
| `helm upgrade --set x=1` by hand | Terraform's refresh reads the release: revision changed; it plans an update back to *your* config's values (it wins) | Put the change in config; never hand-edit |
| `helm uninstall` by hand | Refresh finds no release → plans **create** | Fine (re-creates), or `terraform state rm` if you meant to drop it |
| `terraform state rm helm_release.x` | Terraform forgets; the release keeps running | Re-adopt with `import` (below) |
| `helm rollback` by hand | Revision changed, values differ → Terraform plans an upgrade forward | Decide which is right; usually fix config and apply |
| Release stuck `pending-upgrade` (CI killed) | Apply fails: "another operation is in progress" | `helm rollback`/`uninstall` to clear (Helm side), then apply |
| Deleted the cluster | Refresh errors or finds nothing | `terraform state rm` everything, or point at a new cluster and apply |

⚠️ The Helm provider marks a release as needing replacement if you change its `name`, `namespace`, or the chart it comes from (not the version). That's a destroy-then-create — data-bearing charts lose their PVCs unless a `keep` policy protects them.

### Refresh and drift

Every `plan` first **refreshes**: for each resource in state, it asks the provider "what does this look like now?" and updates the state copy in memory. The diff is then config vs refreshed state.

```bash
terraform plan -refresh-only          # show ONLY drift (reality vs state), propose no changes
terraform apply -refresh-only         # accept the drift into state without touching reality
terraform plan -refresh=false         # skip refresh (fast; trusts state; dangerous if drift exists)
terraform plan -detailed-exitcode     # exit 0 = no changes, 1 = error, 2 = changes → use in nightly drift checks
```

🏫 Refresh is attendance: before planning the day, check which classrooms actually exist and who's in them.

### Locking

A lock prevents two applies from interleaving and corrupting state (or double-creating). Backends implement it differently (Part 4): S3 uses a `.tflock` object, Azure Blob uses a lease, GCS uses a lock object, Kubernetes uses a Lease, Postgres uses advisory locks, HCP Terraform uses its own run queue. `terraform plan` locks too (briefly) unless `-lock=false`.

```bash
terraform apply -lock-timeout=5m      # wait for the lock instead of failing immediately
terraform force-unlock <LOCK_ID>      # only after confirming no run is active (the error shows the ID, who, and when)
```

### Secrets in state, and the modern answer

Old way: `sensitive = true` (hides output only). Modern way (Terraform ≥ 1.10/1.11):

- **Ephemeral resources** (`ephemeral "vault_kv_secret_v2" …`, `ephemeral "aws_secretsmanager_secret_version" …`, `ephemeral "random_password" …`) are fetched during plan/apply and **never written to state or plan files**.
- **Write-only arguments** on resources accept ephemeral values and are also never stored. The Helm provider's `set_wo` (with `set_wo_revision` to signal "the secret changed, please re-apply") is exactly this:

```hcl
ephemeral "random_password" "kc_admin" {
  length = 24
}

resource "helm_release" "keycloak" {
  # …
  set_wo = [
    { name = "adminPassword", value = ephemeral.random_password.kc_admin.result },
  ]
  set_wo_revision = 1          # bump to force a re-send of write-only values
}
```

- The ideal: Terraform never touches secret *values* at all. Let **External Secrets Operator** pull them from a vault into Kubernetes Secrets, and pass only *names* (`existingSecret = "keycloak-admin"`) through Helm values.

OpenTofu adds **client-side state encryption** (Part 4), which protects the file at rest wherever it's stored.

### State commands you'll actually use

```bash
terraform state list                              # every address
terraform state show helm_release.podinfo         # one resource's attributes
terraform state mv helm_release.a helm_release.b  # rename in state (prefer a `moved` block — below)
terraform state rm helm_release.a                 # forget (does NOT uninstall)
terraform state pull > backup.tfstate             # download the current remote state (always before surgery)
terraform state push backup.tfstate               # upload (refuses if serial/lineage look wrong; -force overrides)
terraform state replace-provider hashicorp/kubernetes registry.example.com/mirror/kubernetes
terraform show -json | jq '.values.root_module.resources[] | .address'
```

### Refactoring safely: `moved`, `removed`, `import` blocks

Instead of hand-running `state mv/rm/import` (which nobody reviews), write intent into config and let `plan` show it:

```hcl
# Rename a resource, or move it into a module — no destroy/create
moved {
  from = helm_release.pg
  to   = module.postgres.helm_release.this
}

# Stop managing something WITHOUT destroying it (the release keeps running)
removed {
  from = helm_release.legacy_dashboard
  lifecycle { destroy = false }
}

# Adopt something that already exists (created by hand or by another tool)
import {
  to = helm_release.cnpg
  id = "cnpg-system/cnpg"          # Helm provider import ID = "<namespace>/<release-name>"
}
```

`terraform plan` shows "will be imported" / "has moved" / "will no longer be managed"; `apply` updates state; then delete the block. `terraform plan -generate-config-out=generated.tf` can even write the resource block for an `import`. (Terraform 1.12+ also supports **resource identity** import — `identity = { namespace = "cnpg-system", name = "cnpg" }` — which the Helm provider 3.x implements.)

### Workspaces

A workspace is a **separate state file for the same configuration**. `terraform workspace new prod` creates it; the backend stores it under a distinct key (local: `terraform.tfstate.d/prod/`, S3: `env:/prod/<key>`, Azure: `<key>env:prod`, GCS: `<prefix>/prod.tfstate`). `terraform.workspace` in config lets you vary things.

| Approach | Pros | Cons |
|---|---|---|
| **Workspaces** | One folder, one config, quick to add an environment | Same backend, same provider credentials, easy to apply to the wrong env (`terraform workspace show` before every command!), no per-env provider versions |
| **Folders per environment** (`live/dev`, `live/prod`) | Explicit, different backends/credentials/versions, can't confuse envs | Some duplication (mitigated by modules or Terragrunt) |
| **HCP Terraform workspaces** | Different concept: each is a full project with its own variables, runs, permissions | Tied to HCP |

✅ Most teams: folders for environments, modules for shared code. Workspaces for short-lived copies (a feature-branch test cluster).

### Backups and recovery

- Local backend: `terraform.tfstate.backup` holds the previous state.
- Remote backends: **turn on object versioning** (S3, Azure Blob, GCS). Then a bad write is an "undo": download the previous version, `terraform state push -force`.
- Before any manual state surgery: `terraform state pull > pre-surgery.tfstate`.
- HCP Terraform keeps every state version with a diff viewer.
- Catastrophe: state lost entirely → recreate it with `import` blocks for each resource. Tedious but possible; write a script.

### Splitting and joining state (moving resources between root modules)

When one root module grows too big, move resources to a new one:

1. In the new root: `import { to = helm_release.x, id = "ns/x" }`; apply.
2. In the old root: `removed { from = helm_release.x, lifecycle { destroy = false } }`; apply.

Both steps are reviewable in plans, no destroy happens, no hand-edited JSON. (Older way: `terraform state mv -state-out=…` between files, then push.)

### State performance

Each plan refreshes every resource. Thousands of resources in one state → slow plans, wide blast radius, more lock contention. Split by lifecycle (cluster / platform / apps) and by team. `-target=` limits a run to one resource, but it's for emergencies, not routine (it hides dependencies and leaves other resources stale).

---

<a id="part-4"></a>
## Part 4 — Backends: every place you can keep state

A **backend** is where Terraform reads and writes state, and how it locks. You choose it in the `terraform` block; changing it means `terraform init -migrate-state`.

🏫 Where does the office keep the master roster? In a drawer (local), on the shared drive with check-out (cloud storage + lock), or with a records clerk who tracks every version and who changed what (HCP Terraform).

### The menu

| Backend | Locking | Versioning/undo | Encryption at rest | Best for | Watch out |
|---|---|---|---|---|---|
| `local` (default) | File lock on one machine | `.backup` file only | Your disk | Learning, throwaway | Not shareable; laptops die |
| `s3` (AWS) | Native `.tflock` object (`use_lockfile = true`, Terraform ≥1.10; GA in 1.11) — DynamoDB no longer needed | S3 versioning | SSE-S3/KMS | AWS shops | Bucket must exist first; DynamoDB config is deprecated |
| `azurerm` (Azure Blob) | Blob lease (automatic) | Blob versioning/soft delete | Always (SSE), optional CMK | Azure shops | Storage account name is global; prefer Entra ID auth |
| `gcs` (Google Cloud Storage) | Lock object (automatic) | Object versioning | Always, optional CMEK | Google shops | Bucket must exist first |
| `cloud` / HCP Terraform (was Terraform Cloud) | Built in (run queue) | Every state version, UI diff | Yes, managed | Teams wanting runs, RBAC, policy, VCS integration | Free tier limits; vendor account; runs can be remote or local |
| Terraform Enterprise | Same, self-hosted | Same | Yes | Regulated enterprises | You operate it |
| `kubernetes` | Lease object | None (add your own) | Secret encryption of your cluster | Clusters that self-manage; quick starts | 1 MiB limit; gone with the cluster |
| `pg` (PostgreSQL) | Advisory locks | None (DB backups) | Your DB | Teams with a DB and no cloud storage | Table `states` in a schema; secure the connection |
| `http` | Optional `lock_address` | Depends on server | Depends on server | GitLab-managed state, custom services | Your server's problem |
| `consul` | Consul session | None | Consul ACLs | Consul users | Size limit ~512 KB |
| `oss` (Alibaba), `cos` (Tencent), `oci` (Oracle, Terraform ≥1.12) | Native | Provider-specific | Yes | Those clouds | |
| `remote` (legacy) | — | — | — | Older HCP configs | Use `cloud {}` now |

*OpenTofu* also supports the same backends, and adds **client-side state encryption** (below) so the file is unreadable even to whoever runs the storage.

### The chicken-and-egg problem (bootstrapping)

The bucket that stores state can't be created by the config that stores state in it (there's nowhere to store the state while creating the bucket). Two clean answers:

1. **A bootstrap script** with the cloud CLI (below, per cloud). Run once per account; document it in the repo.
2. **A tiny `bootstrap/` root module with local state** that creates the bucket, then either keep its local state committed to a private repo (it's one bucket) or migrate its own state into the bucket it created (`init -migrate-state`).

✅ Whichever you pick: enable versioning, block public access, restrict who can read (state has secrets), and enable access logging.

### AWS: S3 with native locking

📝 Bootstrap (once per account/region)

```bash
export AWS_REGION=us-east-1 ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="school-tfstate-$ACCOUNT"
aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
  $( [ "$AWS_REGION" != us-east-1 ] && echo --create-bucket-configuration LocationConstraint=$AWS_REGION )
aws s3api put-bucket-versioning        --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block      --bucket "$BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption        --bucket "$BUCKET" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
```

📝 `backend.tf`

```hcl
terraform {
  required_version = ">= 1.11"
  backend "s3" {
    bucket       = "school-tfstate-123456789012"
    key          = "dev/platform.tfstate"        # one key per root module per environment
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true                          # writes dev/platform.tfstate.tflock during runs
    # kms_key_id = "arn:aws:kms:…"               # optional CMK
    # assume_role = { role_arn = "arn:aws:iam::123456789012:role/terraform" }   # cross-account
  }
}
```

IAM needed by whoever runs Terraform: `s3:ListBucket` on the bucket; `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on `<key>` **and** `<key>.tflock`; `kms:Encrypt/Decrypt/GenerateDataKey` if using a CMK. ⚠️ Old tutorials say `dynamodb_table = …`; that still works but is deprecated since Terraform 1.11 — migrate by adding `use_lockfile = true`, applying once, then removing the DynamoDB settings.

### Azure: Blob Storage

📝 Bootstrap

```bash
RG=rg-school-tfstate; SA=stschooltfstate$RANDOM; LOC=eastus2
az group create -n $RG -l $LOC
az storage account create -n $SA -g $RG -l $LOC --sku Standard_GZRS --kind StorageV2 \
  --allow-blob-public-access false --min-tls-version TLS1_2
az storage container create -n tfstate --account-name $SA --auth-mode login
az storage account blob-service-properties update --account-name $SA -g $RG \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30
# RBAC for the humans/CI identity that runs Terraform:
az role assignment create --assignee <object-id> --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n $SA -g $RG --query id -o tsv)
```

📝 `backend.tf`

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-school-tfstate"
    storage_account_name = "stschooltfstate1234"
    container_name       = "tfstate"
    key                  = "dev/platform.tfstate"
    use_azuread_auth     = true          # Entra ID RBAC instead of storage account keys
    # use_oidc = true                    # GitHub Actions / Azure DevOps federated credentials
    # use_msi  = true                    # managed identity on a VM/agent
    # subscription_id / tenant_id / client_id come from ARM_* env vars or the az CLI login
  }
}
```

Locking is automatic: Terraform takes a **blob lease** on the state blob; a stuck lease is broken with `terraform force-unlock` or `az storage blob lease break`. Workspaces are stored as `<key>env:<workspace>`.

### Google Cloud: GCS

📝 Bootstrap

```bash
PROJECT=school-dev-123456; BUCKET=school-tfstate-$PROJECT
gcloud storage buckets create gs://$BUCKET --project $PROJECT --location us-central1 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://$BUCKET --versioning
# IAM: roles/storage.objectAdmin on the bucket for the identity running Terraform
```

📝 `backend.tf`

```hcl
terraform {
  backend "gcs" {
    bucket = "school-tfstate-school-dev-123456"
    prefix = "dev/platform"                      # state stored as <prefix>/default.tfstate
    # kms_encryption_key = "projects/…/cryptoKeys/tfstate"       # CMEK
    # impersonate_service_account = "terraform@school-dev.iam.gserviceaccount.com"
  }
}
```

Locking is automatic (a `.tflock` object). Credentials come from `gcloud auth application-default login`, `GOOGLE_APPLICATION_CREDENTIALS`, or Workload Identity Federation in CI.

### HCP Terraform (formerly Terraform Cloud) and Terraform Enterprise

📝

```hcl
terraform {
  cloud {
    organization = "school-district"
    workspaces {
      name = "dev-platform"              # or: tags = ["platform", "dev"] to pick from several
      # project = "School"               # optional grouping
    }
  }
}
```

```bash
terraform login              # stores an API token in ~/.terraform.d/credentials.tfrc.json
terraform init
terraform apply              # by default runs REMOTELY on HCP's workers, streaming output back
```

What you get: state storage + versioning + diffs, locking, run history, RBAC per workspace, variable sets (including sensitive vars kept out of Git), VCS-driven runs (plan on PR, apply on merge), policy-as-code (Sentinel/OPA), cost estimation, private module/provider registry, drift detection and health checks, run tasks. Execution mode can be **remote** (HCP workers — they must reach your cluster, which often means an **agent** you run inside your network) or **local** (your CI runs Terraform; HCP just holds state and locks). For clusters on private networks, *local execution* or *agents* is the usual choice.

Pros: everything a team needs, no bucket to babysit, audit trail. Cons: another vendor and account, pricing per managed resource beyond the free tier, remote workers need network access to your Kubernetes API.

### Kubernetes (state in a Secret)

```hcl
terraform {
  backend "kubernetes" {
    secret_suffix    = "platform"                 # Secret: tfstate-<workspace>-platform
    namespace        = "terraform-state"
    config_path      = "~/.kube/config"           # or in_cluster_config = true when Terraform runs as a pod
    config_context   = "kind-school"
    labels           = { team = "platform" }
  }
}
```

Lock = a `Lease` named `lock-tfstate-<workspace>-<suffix>`. Limits: Secrets max 1 MiB (state compresses poorly past a few hundred resources), no versioning unless you back the Secret up, and the state dies with the cluster — so **never** use it for the root module that creates the cluster. Good for: in-cluster operators that run Terraform, kind labs, air-gapped clusters with no object storage.

### PostgreSQL

```hcl
terraform {
  backend "pg" {
    conn_str    = "postgres://terraform@db.school.internal/terraform?sslmode=verify-full"   # or PG_CONN_STR env var
    schema_name = "school_platform"
  }
}
```

Creates table `states` (one row per workspace) and uses Postgres advisory locks. Back up the database like any other. Useful when you already run Postgres (CloudNativePG, RDS) and have no object storage — note the circularity if that Postgres is *itself* managed by this Terraform.

### HTTP (GitLab-managed state and custom servers)

```hcl
terraform {
  backend "http" {
    address        = "https://gitlab.example.com/api/v4/projects/42/terraform/state/dev-platform"
    lock_address   = "https://gitlab.example.com/api/v4/projects/42/terraform/state/dev-platform/lock"
    unlock_address = "https://gitlab.example.com/api/v4/projects/42/terraform/state/dev-platform/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    username       = "gitlab-ci-token"           # password via TF_HTTP_PASSWORD = $CI_JOB_TOKEN
  }
}
```

GitLab stores versions and shows them in the UI; locking works through the lock endpoints. The same backend talks to any server implementing GET/POST/LOCK/UNLOCK.

### OpenTofu: client-side state encryption

OpenTofu (not Terraform) can encrypt state and plan files *before* they reach the backend:

```hcl
terraform {
  encryption {
    key_provider "pbkdf2" "passphrase" {          # or aws_kms / gcp_kms / azurerm / openbao (Vault)
      passphrase = var.state_passphrase           # from an env var; never in Git
    }
    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.passphrase
    }
    state { method = method.aes_gcm.default }
    plan  { method = method.aes_gcm.default }
  }
}
```

Now even someone with read access to the bucket sees ciphertext. Losing the key = losing the state; store it in a KMS. Terraform proper relies on backend-side encryption (SSE/KMS) plus access control instead.

### Partial configuration: keep secrets and environment out of `backend.tf`

Backend blocks can't use variables. Leave values out and supply them at `init`:

```hcl
terraform {
  backend "s3" {}                                 # everything provided at init time
}
```

```bash
terraform init -backend-config=backends/dev.hcl              # a file with bucket = …, key = …
terraform init -backend-config="key=prod/platform.tfstate"   # or individual settings
terraform init -reconfigure                                  # switch settings WITHOUT migrating state
terraform init -migrate-state                                # switch AND copy state across
```

✅ One `backend.<env>.hcl` per environment in the repo (no secrets in them — credentials come from the environment), and CI passes the right one.

### Migrating between backends (the checklist)

1. Make sure nobody is running Terraform (announce; check locks).
2. `terraform state pull > before.tfstate` (backup).
3. Edit the `backend` block; run `terraform init -migrate-state`; answer `yes`.
4. `terraform plan` → "No changes."
5. Delete or archive the old state (don't leave a stale copy someone could `init` against).

### Naming keys and separating environments

```text
s3://school-tfstate-123456789012/
├── dev/cluster.tfstate
├── dev/platform.tfstate
├── dev/apps.tfstate
├── prod/cluster.tfstate
├── prod/platform.tfstate
└── prod/apps.tfstate
```

One state per root module per environment. Different environments in *different buckets or storage accounts* with different credentials if you want a hard wall (prod credentials never present in a dev pipeline). Never share one key between environments, and never point two root modules at the same key.

---

<a id="part-5"></a>
## Part 5 — The Helm provider, argument by argument

The `hashicorp/helm` provider (3.3 as of August 2026) embeds Helm's Go library (currently the Helm 3.20 SDK — its behavior doesn't change when you upgrade the `helm` CLI on your machine). It gives you one resource, `helm_release`, and one data source, `helm_template`.

🏫 The provider is a substitute teacher who knows exactly how to run the Helm lesson plan; Terraform just hands over the class list and checks the room afterwards.

### 5.1 Provider configuration

```hcl
terraform {
  required_providers {
    helm       = { source = "hashicorp/helm",       version = "~> 3.3" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }   # 3.x exists (Dec 2025); read its upgrade guide before moving — its block syntax changed too
  }
}

provider "helm" {
  kubernetes = {
    # --- pick ONE way to authenticate ---
    # 1. kubeconfig file (laptops)
    config_path    = "~/.kube/config"                # also KUBE_CONFIG_PATH env var; several paths via config_paths = [...]
    config_context = "kind-school"                   # KUBE_CTX; also config_context_auth_info / config_context_cluster

    # 2. explicit endpoint + credential (CI, cloud)
    # host                   = "https://…"           # KUBE_HOST
    # cluster_ca_certificate = base64decode(…)       # KUBE_CLUSTER_CA_CERT_DATA
    # token                  = "…"                   # KUBE_TOKEN (short-lived; from a data source, never a literal)
    # client_certificate / client_key                # mTLS (AKS local accounts)
    # username / password                            # basic auth (rare)
    # insecure = true                                # skip TLS verification (never in prod)
    # tls_server_name, proxy_url

    # 3. exec plugin: run a CLI to get a token every time (best for clouds)
    # exec = {
    #   api_version = "client.authentication.k8s.io/v1"
    #   command     = "aws"
    #   args        = ["eks", "get-token", "--cluster-name", "school-dev"]
    #   env         = { AWS_PROFILE = "school" }
    # }

    # 4. in-cluster: when Terraform itself runs as a pod, omit everything —
    #    the provider reads KUBERNETES_SERVICE_HOST/PORT and the mounted ServiceAccount token
  }

  # OCI registries that need login (or run `helm registry login` before Terraform):
  registries = [
    { url = "oci://ghcr.io", username = var.ghcr_user, password = var.ghcr_token },
  ]

  # Rarely needed:
  # helm_driver            = "secret"     # secret | configmap | memory | sql — where Helm keeps release history
  # plugins_path, registry_config_path, repository_config_path, repository_cache
  # burst_limit = 100, qps = 50           # client-side API throttling
  # debug = true
  # experiments = { manifest = true }     # store the rendered manifest in state → plans show Kubernetes-level diffs.
  #                                       # Needs cluster access at plan time (dry-run) and grows state; sensitive set
  #                                       # values are redacted, but review what lands in state. Since 3.1 also exposes `resources`.
}
```

A second cluster is a second provider with an alias:

```hcl
provider "helm" {
  alias      = "prod"
  kubernetes = { … }
}

resource "helm_release" "x" {
  provider = helm.prod
  # …
}
```

### 5.2 `helm_release` — every argument, grouped

**Identity and placement**

| Argument | Meaning | Notes |
|---|---|---|
| `name` | Release name | ≤ 53 characters; changing it = destroy + create |
| `namespace` | Where the release (and its Secret) lives | Changing it = destroy + create |
| `create_namespace` | Create the namespace if missing | Convenient; but Terraform won't manage or delete it — prefer `kubernetes_namespace_v1` |
| `description` | Free text stored on the release | Shows in `helm history` |

**Where the chart comes from**

| Argument | Meaning | Notes |
|---|---|---|
| `chart` | Chart name, local path (`./charts/x`, `../x.tgz`), or a full URL | Local paths are relative to the working directory — use `"${path.module}/charts/x"` |
| `repository` | `https://…` repo URL, or `oci://registry/path` (the part **before** the chart name) | For OCI: `repository = "oci://quay.io/strimzi-helm"`, `chart = "strimzi-kafka-operator"` |
| `version` | Chart version | **Pin it.** Empty = latest at apply time = surprise upgrades. Local charts take the version from `Chart.yaml` |
| `devel` | Allow pre-release versions when no `version` given | |
| `repository_username`, `repository_password`, `repository_ca_file`, `repository_cert_file`, `repository_key_file` | Auth/TLS for HTTP repos | Or `pass_credentials = true` to send them to redirected hosts |
| `dependency_update` | Run `helm dependency update` for local charts before install | Otherwise `charts/` must be populated already |
| `verify`, `keyring` | Verify chart provenance (`.prov`) with a GPG keyring | |

**Values (highest precedence last)**

| Argument | Meaning | Notes |
|---|---|---|
| `values` | List of YAML **strings**, merged in order | `[file("values/base.yaml"), file("values/${var.env}.yaml"), yamlencode(local.overrides)]` |
| `set` | List of `{ name, value, type }` | `type`: `auto` (default — Helm's usual type guessing), `string` (force string, like `--set-string`), `literal` (no comma/dot parsing) |
| `set_list` | `{ name, value = ["a","b"] }` | Like `--set hosts={a,b}` without quoting pain |
| `set_sensitive` | Same as `set`, hidden in plans | Still stored in state and in the Helm release Secret |
| `set_wo` + `set_wo_revision` | Write-only values: never in state or plan (Terraform ≥1.11) | Bump `set_wo_revision` to re-send |
| `reuse_values` | On upgrade, reuse the last release's values and merge new ones | Same trap as `helm upgrade --reuse-values` (ignores new chart defaults) — avoid |
| `reset_values` | On upgrade, discard the previous release's values and use only chart defaults + what you pass now (`--reset-values`) | Default `false`; rarely needed because Terraform already passes the complete set of values every time |

**Lifecycle behavior**

| Argument | Default | Meaning |
|---|---|---|
| `wait` | `true` | Wait until pods/PVCs/Services are ready (Helm's `--wait`) |
| `wait_for_jobs` | `false` | Also wait for hook Jobs |
| `timeout` | `300` | Seconds for each Helm operation; raise for operators/databases (600–900) |
| `atomic` | `false` | Roll back on failed install/upgrade (`--atomic`; the provider keeps this name even though the Helm 4 CLI renamed it) |
| `cleanup_on_fail` | `false` | Delete new resources created by a failed upgrade |
| `max_history` | `0` (unlimited) | Keep N release Secrets; set 10 to stop clutter |
| `upgrade_install` | `false` | Behave like `helm upgrade --install`: adopt an existing release with this name instead of failing |
| `take_ownership` | `false` | (3.1+) Take over resources not owned by this release (Helm's `--take-ownership`) |
| `force_update` | `false` | `--force`: delete/recreate resources on conflict — dangerous |
| `replace` | `false` | Re-use a release name that's in a deleted state |
| `recreate_pods` | `false` | Deprecated; use a checksum annotation in the chart instead |
| `skip_crds` | `false` | Don't install `crds/` |
| `disable_openapi_validation` | `false` | Skip schema validation — needed when a chart contains CRs whose CRDs aren't installed yet |
| `disable_webhooks` | `false` | Skip hooks entirely |
| `render_subchart_notes` | `true` | Include sub-chart NOTES |
| `lint` | `false` | Run `helm lint` before install |
| `postrender = { binary_path = "…", args = [] }` | — | A post-renderer (e.g. `kustomize`) run on the manifest |
| `timeouts = { create = "20m", update = "20m", delete = "10m", read = "5m" }` | — | (3.1+) Terraform-level operation timeouts, separate from Helm's `timeout` |

**What it exports (read-only attributes)**

```hcl
helm_release.x.id                     # release name
helm_release.x.status                 # deployed | failed | pending-* | …
helm_release.x.metadata.revision      # Helm revision number
helm_release.x.metadata.version       # chart version actually installed
helm_release.x.metadata.app_version
helm_release.x.metadata.chart
helm_release.x.metadata.values        # effective values as JSON (sensitive)
helm_release.x.metadata.first_deployed, .last_deployed, .notes
helm_release.x.manifest               # only with experiments.manifest
```

### 5.3 A fully-loaded example

```hcl
resource "helm_release" "cnpg" {
  name             = "cnpg"
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  version          = "0.26.1"
  namespace        = kubernetes_namespace_v1.cnpg.metadata[0].name

  wait             = true
  wait_for_jobs    = true
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true
  max_history      = 10

  values = [
    file("${path.module}/values/cnpg/base.yaml"),
    templatefile("${path.module}/values/cnpg/${var.env}.yaml.tftpl", { replicas = var.env == "prod" ? 2 : 1 }),
  ]
  set = [
    { name = "config.data.INHERITED_ANNOTATIONS", value = "school.example.com/*", type = "string" },
  ]

  lifecycle {
    precondition {
      condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", "0.26.1"))
      error_message = "Chart versions must be pinned to an exact x.y.z."
    }
  }
}
```

### 5.4 The `helm_template` data source (render without installing)

```hcl
data "helm_template" "app" {
  name       = "lunch-api"
  chart      = "${path.module}/../charts/school-app"
  version    = "1.4.2"
  namespace  = "school"
  values     = [file("${path.module}/values/lunch-api.yaml")]
  include_crds = true
  kube_version = "1.33.0"                  # pretend cluster version for Capabilities
  api_versions = ["gateway.networking.k8s.io/v1"]
  # show_only  = ["templates/deployment.yaml"]
}

output "rendered" { value = data.helm_template.app.manifest }          # one big YAML string
# also: .manifests (map of file path → YAML), .crds (list), .notes
```

Uses: write the rendered YAML to a file for review (`local_file`), feed it to `kubernetes_manifest` for objects you want Terraform to track individually, or run a policy check on it in CI. It needs no cluster.

### 5.5 Importing a release that already exists

```bash
terraform import helm_release.cnpg cnpg-system/cnpg          # "<namespace>/<name>"
```

or, reviewable in a plan (Terraform ≥1.5):

```hcl
import {
  to = helm_release.cnpg
  id = "cnpg-system/cnpg"
}
```

After import, `terraform plan` usually shows a small diff (values formatting, `wait`, `timeout` defaults); make the config match what's really installed (`helm get values cnpg -n cnpg-system --all`) until the plan is clean, *then* start changing things.

### 5.6 Where Terraform ends and Helm begins

- Terraform decides *whether* to call Helm and with which inputs.
- Helm renders, applies, waits, and records the release Secret.
- Terraform records what it asked for, the resulting revision and status.
- Hooks, `--wait` logic, three-way merges, CRD handling: all Helm's (3.20 library) behavior, exactly as if you'd typed the command.
- Things Helm can't do (create the namespace with labels, create Secrets from cloud vaults, wait for a CRD to exist) are the Kubernetes provider's or another tool's job — Part 6.

---

<a id="part-6"></a>
## Part 6 — Patterns that work for teams

### 6.1 The three-layer layout (and why one big `apply` fails)

```text
infra/
├── modules/
│   ├── cluster-aks/  cluster-eks/  cluster-gke/    # make a cluster
│   ├── platform/                                   # operators, gateway, cert-manager, ESO, monitoring
│   └── helm-app/                                   # one helm_release with our defaults
└── live/
    ├── dev/
    │   ├── cluster/     # state A  (cloud provider only)
    │   ├── platform/    # state B  (helm + kubernetes providers, reading the cluster via data sources)
    │   └── apps/        # state C  (your charts)
    └── prod/ …
```

⚠️ **The provider chicken-and-egg problem.** `provider "helm"` needs the cluster's endpoint and CA *when the plan is computed*. If the cluster is created in the same root module, those values are unknown during the first plan. Symptoms: "cannot create REST client", "the plugin must be configured", plans that quietly target `localhost:80`, or resources that only work with `-target` in two steps. Terraform's documentation explicitly warns against configuring a provider from resources in the same configuration. The layered layout removes the problem: `platform/` *reads* the cluster with a data source that exists before the plan starts.

Other reasons for layers: blast radius (`destroy` in `apps/` can't remove the cluster), speed (small states plan in seconds), permissions (app teams get `apps/`; only platform gets `cluster/`), and clean provider upgrades.

🏫 The building, the departments, and the classes are managed by different people with different keys. Same school; three clipboards.

### 6.2 Reading the cluster in `platform/` and `apps/`

Prefer **cloud data sources** over `terraform_remote_state`: they need only the cluster's name, not access to another team's state file (which contains secrets).

```hcl
# AKS
data "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = var.rg
}
# EKS
data "aws_eks_cluster" "this" { name = var.cluster_name }
# GKE
data "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.region
}
```

If you do use `terraform_remote_state`, restrict it to a few explicit outputs and remember that whoever can read it can read the whole state.

### 6.3 Namespaces, labels, and quotas belong to Terraform

```hcl
resource "kubernetes_namespace_v1" "school" {
  metadata {
    name   = "school"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "team"                               = "lunch"
    }
  }
}

resource "kubernetes_resource_quota_v1" "school" {
  metadata {
    name      = "school-quota"
    namespace = kubernetes_namespace_v1.school.metadata[0].name
  }
  spec { hard = { "requests.cpu" = "8", "requests.memory" = "16Gi", "pods" = "50" } }
}

resource "helm_release" "lunch_api" {
  namespace = kubernetes_namespace_v1.school.metadata[0].name   # the reference is the dependency
  # …
}
```

`create_namespace = true` is fine for a laptop; in a team it hides who owns the namespace and leaves it behind on destroy.

### 6.4 One module for all your app charts

📝 `modules/helm-app/main.tf`

```hcl
variable "name"      { type = string }
variable "namespace" { type = string }
variable "version"   { type = string }
variable "chart" {
  type    = string
  default = "school-app"
}
variable "values" {
  type    = list(string)
  default = []
}
variable "set" {
  type    = map(string)
  default = {}
}

resource "helm_release" "this" {
  name             = var.name
  repository       = "oci://ghcr.io/school/charts"
  chart            = var.chart
  version          = var.version
  namespace        = var.namespace
  wait             = true
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true
  max_history      = 10
  values           = var.values
  set              = [for k, v in var.set : { name = k, value = v }]
}

output "revision" { value = helm_release.this.metadata.revision }
```

📝 `live/dev/apps/main.tf`

```hcl
locals {
  apps = {
    lunch-api    = { version = "1.4.2", set = { "image.tag" = var.lunch_api_tag } }
    grade-alerts = { version = "1.4.2", set = { "image.tag" = var.grade_alerts_tag } }
    report-bot   = { version = "1.4.2", set = { "image.tag" = var.report_bot_tag } }
  }
}

module "app" {
  for_each  = local.apps
  source    = "../../../modules/helm-app"
  name      = each.key
  namespace = kubernetes_namespace_v1.school.metadata[0].name
  version   = each.value.version
  values    = [file("${path.module}/values/${each.key}.yaml")]
  set       = each.value.set
  depends_on = [helm_release.keycloak]          # module-level depends_on works since Terraform 0.13
}
```

Adding an app = adding one line to the map. Terraform address: `module.app["lunch-api"].helm_release.this`.

### 6.5 Values: files vs `templatefile` vs `yamlencode`

| Way | Example | Pros | Cons |
|---|---|---|---|
| Static file | `values = [file("values/x.yaml")]` | Reviewable YAML; same file usable with the Helm CLI | Can't reference Terraform values |
| Template file | `templatefile("values/x.yaml.tftpl", { host = var.host })` | Inject a few Terraform values | Template syntax `${}` clashes with Helm's `{{ }}` only if you put Helm templates in values (rare); escape with `$${` |
| HCL → YAML | `yamlencode({ replicaCount = 2, image = { tag = var.tag } })` | Typed, no whitespace drift, easy to compose with `merge()` | Reads less naturally; long values get unwieldy |
| `set` | `set = [{ name = "image.tag", value = var.tag }]` | Perfect for one or two dynamic values | Values are strings (use `type`), noisy for many |

✅ Common combination: a static base file, a per-env file, and `set` for the image tag CI passes in.

### 6.6 Secrets without leaking into state

Ranked from best to worst:

1. **External Secrets Operator** (installed by Terraform in `platform/`): a `ClusterSecretStore` pointing at Key Vault / Secrets Manager / Secret Manager, and `ExternalSecret` objects (in your app charts or via `kubernetes_manifest`) create the Kubernetes Secrets. Terraform passes only Secret *names* to charts (`existingSecret`). State never sees a secret value.
2. **Ephemeral + write-only** (Terraform ≥1.11): read with an `ephemeral` resource, pass through `set_wo` (Helm provider) or a write-only argument like `kubernetes_secret_v1`'s `data_wo`. Never persisted.
3. **`random_password` + `kubernetes_secret_v1`**: simple and reproducible, but both the random result and the Secret land in state — acceptable only with a private, encrypted, versioned backend.
4. **`set_sensitive`**: hidden in plan output only; in state and in the Helm release Secret.
5. **Literals in `.tf` or `.tfvars`** committed to Git: never.

### 6.7 Operators first, custom resources second (the CRD ordering problem)

Installing Strimzi and a `Kafka` CR in the same apply usually fails: `kubernetes_manifest` validates against the cluster's API *at plan time*, and the `Kafka` kind doesn't exist yet. Three ways that work:

| Option | How | Pros | Cons |
|---|---|---|---|
| **A. Wrapper chart** (recommended) | Put the `Kafka`/`Cluster`/`Keycloak` CRs in your own small chart; install it with `helm_release` in `apps/`, `depends_on` the operator release in `platform/` (or just the layer boundary) | Helm renders CRs without validating kinds at plan; values-driven; works with `helm diff` | Two releases to reason about |
| **B. `kubernetes_manifest` in a later layer** | Operator (and CRDs) in `platform/`, CRs in `apps/` | Terraform-native diffs of each CR | Plan-time cluster access; large CR schemas → noisy plans; `computed_fields` needed for fields the operator sets |
| **C. `alekc/kubectl` provider `kubectl_manifest`** | Applies YAML like `kubectl apply`, no plan-time schema validation, supports multi-doc YAML (`data.kubectl_file_documents`) | Simple; great for raw manifests like the Keycloak operator's `kubernetes.yml` | Community provider; less structured diffs |

Also: `helm_release` has `disable_openapi_validation = true` for the case where a chart contains CRs and Helm complains about unknown kinds (Helm's own validation).

### 6.8 Raw YAML from upstream (e.g. the Keycloak operator)

```hcl
data "http" "keycloak_operator" {
  url = "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${var.keycloak_version}/kubernetes/kubernetes.yml"
}

data "kubectl_file_documents" "keycloak_operator" {
  content = data.http.keycloak_operator.response_body
}

resource "kubectl_manifest" "keycloak_operator" {
  for_each           = data.kubectl_file_documents.keycloak_operator.manifests
  yaml_body          = each.value
  override_namespace = "keycloak"
  depends_on         = [kubectl_manifest.keycloak_crds]
}
```

Or vendor the files into the repo (reviewable, no network at plan time) — usually better.

### 6.9 Bootstrapping GitOps (Argo CD / Flux) from Terraform

A popular split: Terraform owns `cluster/` and `platform/` (including installing Argo CD via `helm_release`), then hands app delivery to Argo CD:

```hcl
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "8.5.4"                       # check current
  namespace  = "argocd"
  create_namespace = true
  values     = [file("${path.module}/values/argocd.yaml")]
}

# The "app of apps": one Application that points at a Git folder full of Applications
resource "kubectl_manifest" "root_app" {
  yaml_body  = file("${path.module}/argocd/root-app.yaml")
  depends_on = [helm_release.argocd]
}
```

From here, `apps/` lives in Git and Argo CD reconciles it continuously; Terraform's state stays small. Pros: drift correction, UI, per-app RBAC. Cons: two systems; Helm hooks and `lookup` behave differently under Argo CD; secrets must come from ESO/SOPS.

### 6.10 Environments: folders, workspaces, or Terragrunt

- **Folders** (`live/dev`, `live/prod`) calling shared modules: explicit and safe. The default recommendation.
- **Workspaces**: same code, switchable state; risk of applying to the wrong one; fine for ephemeral test copies.
- **Terragrunt**: a wrapper that generates backend/provider blocks and runs many root modules in dependency order (`terragrunt run-all apply`). Removes duplication at the cost of another tool. Also: Terraform Stacks (an HCP Terraform feature for deploying one configuration across many environments) and OpenTofu's `-exclude`/early variable evaluation address the same pain natively.

### 6.11 CI/CD that a team can trust

📝 `.github/workflows/platform.yaml` (GitHub Actions, OIDC to Azure; swap the login step for AWS/GCP)

```yaml
name: platform
on:
  pull_request: { paths: [infra/live/dev/platform/**, infra/modules/**] }
  push:         { branches: [main], paths: [infra/live/dev/platform/**, infra/modules/**] }
permissions: { id-token: write, contents: read, pull-requests: write }
concurrency: platform-dev                         # one run at a time per state (the lock is the backstop, not the plan)
env:
  TF_IN_AUTOMATION: "true"
  ARM_USE_OIDC: "true"
  ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
  ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
jobs:
  terraform:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: infra/live/dev/platform } }
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: 1.15.9 }
      - uses: azure/login@v2
        with: { client-id: ${{ secrets.AZURE_CLIENT_ID }}, tenant-id: ${{ secrets.AZURE_TENANT_ID }}, subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }} }
      - run: az aks install-cli                      # kubelogin for the exec plugin
      - run: terraform fmt -check -recursive
      - run: terraform init -backend-config=backend.dev.hcl -input=false
      - run: terraform validate
      - name: Plan
        id: plan
        run: terraform plan -input=false -out=tfplan -detailed-exitcode
        continue-on-error: true
      - name: Comment plan on PR
        if: github.event_name == 'pull_request'
        run: terraform show -no-color tfplan > plan.txt && gh pr comment ${{ github.event.number }} -F plan.txt
        env: { GH_TOKEN: ${{ github.token }} }
      - name: Apply (main only)
        if: github.ref == 'refs/heads/main' && steps.plan.outputs.exitcode == '2'
        run: terraform apply -input=false tfplan
```

Add: `tflint` (lint), `trivy config` or `checkov` (security), `terraform test` (module tests), and a nightly `plan -detailed-exitcode` job that alerts on drift. Never run `apply` from laptops against prod; humans review plans, pipelines apply them.

### 6.12 Testing modules

📝 `modules/helm-app/tests/basic.tftest.hcl`

```hcl
variables {
  name      = "test-app"
  namespace = "default"
  version   = "1.4.2"
}

run "plan_is_valid" {
  command = plan
  assert {
    condition     = helm_release.this.name == "test-app"
    error_message = "release name should be passed through"
  }
}
```

`terraform test` runs it (with `command = apply` it will actually install into whatever cluster the provider points at — use kind in CI).

---

<a id="part-7"></a>
## Part 7 — Cloud setups: AKS, EKS, GKE

Each cloud needs three things from Terraform's point of view: a **state backend** (Part 4), a **cluster** (`cluster/`), and a **provider configuration** that reaches it (`platform/`, `apps/`). The table, then the code.

| | Azure AKS | AWS EKS | Google GKE |
|---|---|---|---|
| State backend | `azurerm` (Blob + lease) | `s3` (+ `use_lockfile`) | `gcs` |
| CI identity | Entra ID app + federated credential (`ARM_USE_OIDC`) | IAM role with GitHub OIDC trust (`aws-actions/configure-aws-credentials`) | Workload Identity Federation (`google-github-actions/auth`) |
| Cluster resource | `azurerm_kubernetes_cluster` | `terraform-aws-modules/eks/aws` (v21) | `google_container_cluster` |
| Provider auth (exec) | `kubelogin get-token --login azurecli` (or `--login workloadidentity` in CI) | `aws eks get-token --cluster-name …` | `google_client_config` access token (no exec needed) |
| Registry for charts/images | ACR | ECR | Artifact Registry |
| Notable | Entra RBAC + `kubelogin`; `only_critical_addons_enabled` on the system pool | Access entries; EBS CSI IAM; gp3 StorageClass | Autopilot vs Standard; `gke-gcloud-auth-plugin` for kubectl |

### Azure

📝 `live/dev/platform/providers.tf`

```hcl
terraform {
  required_providers {
    azurerm    = { source = "hashicorp/azurerm",    version = "~> 4.40" }
    helm       = { source = "hashicorp/helm",       version = "~> 3.3" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
  }
  backend "azurerm" {}                       # settings in backend.dev.hcl
}

provider "azurerm" { features {} }

data "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = var.resource_group
}

locals {
  kube = data.azurerm_kubernetes_cluster.this.kube_config[0]
  exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--login", var.ci ? "workloadidentity" : "azurecli",
                   "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]   # the well-known AKS Entra server app ID
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
    exec                   = local.exec
  }
}

provider "kubernetes" {
  host                   = local.kube.host
  cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  exec {
    api_version = local.exec.api_version
    command     = local.exec.command
    args        = local.exec.args
  }
}
```

📝 `backend.dev.hcl`

```hcl
resource_group_name  = "rg-school-tfstate"
storage_account_name = "stschooltfstate1234"
container_name       = "tfstate"
key                  = "dev/platform.tfstate"
use_azuread_auth     = true
```

CI: create an app registration with a **federated credential** for `repo:school/infra:ref:refs/heads/main` (and one for `pull_request`), grant it *Storage Blob Data Contributor* on the state account, *Azure Kubernetes Service RBAC Cluster Admin* on the cluster, and set `ARM_USE_OIDC=true`. No client secret anywhere.

### AWS

📝 `live/dev/platform/providers.tf`

```hcl
terraform {
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 6.0" }
    helm       = { source = "hashicorp/helm",       version = "~> 3.3" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
  }
  backend "s3" {}
}

provider "aws" { region = var.region }

data "aws_eks_cluster" "this" { name = var.cluster_name }

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}
```

📝 `backend.dev.hcl`

```hcl
bucket       = "school-tfstate-123456789012"
key          = "dev/platform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

CI: an IAM role whose trust policy allows `token.actions.githubusercontent.com` with `sub = repo:school/infra:*`; permissions for the bucket (Part 4), `eks:DescribeCluster`, and an **EKS access entry** mapping that role to a Kubernetes group (`enable_cluster_creator_admin_permissions` covers the creator; add `access_entries` for CI).

### Google Cloud

📝 `live/dev/platform/providers.tf`

```hcl
terraform {
  required_providers {
    google     = { source = "hashicorp/google",     version = "~> 7.0" }
    helm       = { source = "hashicorp/helm",       version = "~> 3.3" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
  }
  backend "gcs" {}
}

provider "google" {
  project = var.project
  region  = var.region
}

data "google_client_config" "default" {}
data "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.region
}

provider "helm" {
  kubernetes = {
    host                   = "https://${data.google_container_cluster.this.endpoint}"
    token                  = data.google_client_config.default.access_token      # short-lived OAuth token; not stored
    cluster_ca_certificate = base64decode(data.google_container_cluster.this.master_auth[0].cluster_ca_certificate)
  }
}
```

📝 `backend.dev.hcl`

```hcl
bucket = "school-tfstate-school-dev-123456"
prefix = "dev/platform"
```

CI: a Workload Identity Pool + provider for GitHub, a service account with `roles/storage.objectAdmin` on the bucket and `roles/container.developer` on the project, and `google-github-actions/auth` with `workload_identity_provider`.

### The cluster layer, briefly

The `cluster/` root modules are the same as in the companion Helm tutorial (AKS with workload identity and a tainted system pool; EKS via the community module with Pod Identity and the EBS CSI add-on; GKE Autopilot with Gateway API enabled). Each ends with `output "cluster_name"` — the only thing the next layer needs, and it can also just be a variable.

---

<a id="part-8"></a>
## Part 8 — Best practices

### 8.1 Pin everything, in four places

```hcl
terraform {
  required_version = "~> 1.15"                                  # 1. Terraform CLI
  required_providers {
    helm = { source = "hashicorp/helm", version = "~> 3.3" }    # 2. providers (and commit .terraform.lock.hcl)
  }
}
module "eks" {
  source  = "terraform-aws-modules/eks/aws"                     # 3. modules
  version = "~> 21.0"
}
resource "helm_release" "x" { version = "0.26.1" }              # 4. charts
```

🛒 Every box on the shelf has a date. `~>` means "this minor line, any patch"; `=` means exactly this. Upgrades are deliberate PRs, with `terraform init -upgrade` and a plan you read.

### 8.2 Small states, layered by lifecycle

Cluster / platform / apps (Part 6.1). Rule of thumb: if a `terraform plan` takes more than a minute or touches more than a few hundred resources, split.

### 8.3 Remote, locked, versioned, encrypted, private state — from day one

Even for one person. Moving later is easy (`init -migrate-state`); losing a laptop's `terraform.tfstate` is not.

### 8.4 Treat state as a secret

Bucket policy or RBAC limited to the pipeline identity and a few admins. Access logging on. No `terraform_remote_state` reads from other teams unless necessary. Prefer ephemeral/write-only values and External Secrets so secrets aren't in state at all.

### 8.5 Plans are for reading

`-out=tfplan` then `apply tfplan`, so what was reviewed is what runs. In PRs, post the plan. Check the summary line and every `-/+` (replacement).

### 8.6 `-target` and `-replace` are emergency tools

They're for un-sticking a run, not for daily use. If you need `-target` routinely, your layers are wrong.

### 8.7 One writer per state

Serialize CI runs per state (GitHub `concurrency`, GitLab `resource_group`), and make the lock the backstop, not the plan. Humans plan locally; pipelines apply.

### 8.8 `wait`, `atomic`, `cleanup_on_fail`, sensible `timeout`

For every `helm_release`. Operators and databases: `timeout = 600–900`.

### 8.9 Namespaces via the Kubernetes provider

So labels, quotas, network policies and Pod Security levels are in code, and `destroy` is complete.

### 8.10 Values files next to the code, one per environment

`values/<release>/base.yaml` + `values/<release>/<env>.yaml`. Keep them stable (whitespace and key order matter to Terraform's string diff) and run `helm lint`/`helm template` on them in CI too.

### 8.11 Never edit state by hand

Use `moved`, `removed`, `import` blocks so refactors are reviewed like any other change. `terraform state` subcommands are for reading (`list`, `show`, `pull`) and rare surgery, always after a `pull` backup.

### 8.12 Refactor-safe addresses

`for_each` over maps with stable keys, not `count`. Module names and resource labels that won't need renaming (`helm_release.this` inside a module named after the app).

### 8.13 Make drift visible

A scheduled `terraform plan -detailed-exitcode` (exit code 2 = drift or pending changes) posted to chat. Hand edits with `kubectl`/`helm` get caught within a day.

### 8.14 Document the bootstrap

The commands that created the state bucket and the CI identity, in the repo's README. The one thing Terraform can't recreate for itself.

### 8.15 Prefer data sources to remote state for cross-layer facts

`data "aws_eks_cluster"` needs a name; `terraform_remote_state` needs read access to someone's secrets.

### 8.16 Keep provider credentials short-lived

`exec` plugins (`kubelogin`, `aws eks get-token`) and `google_client_config` tokens instead of static kubeconfig client certificates or long-lived tokens in variables.

### 8.17 Lint and scan in CI

`terraform fmt -check`, `terraform validate`, `tflint`, `trivy config` (or `checkov`), `terraform test` for modules, and `helm lint`/`kubeconform` for the charts you install.

### 8.18 Decide who owns what, and write it down

Terraform owns clusters, namespaces, operators, secrets plumbing. Helm (via Terraform or GitOps) owns app releases. Nothing is `kubectl edit`ed in prod. When two tools own one object, you get fights — Helm 4's server-side apply reports them as field conflicts.

---

<a id="part-9"></a>
## Part 9 — Gotchas (the big list)

Symptom → cause → fix.

### 9.1 "Error: Provider configuration not present" / plan targets `localhost:80` / "cannot create REST client"

Cluster and Helm releases in the same root module; the provider was configured from unknown values. **Fix:** layers (Part 6.1). Quick unblock: `terraform apply -target=module.eks` first, then a full apply — but then restructure.

### 9.2 "Error acquiring the state lock"

Another run is active, or one crashed. **Fix:** wait / `-lock-timeout=10m`; if truly stale, `terraform force-unlock <ID>` after confirming with the team. Azure: also `az storage blob lease break`.

### 9.3 "state snapshot was created by Terraform vX, which is newer than current"

Someone applied with a newer CLI. **Fix:** upgrade your CLI (state formats are forward-only); pin the version for everyone.

### 9.4 "Backend configuration changed" / "Backend initialization required"

You edited the backend block or `-backend-config`. **Fix:** `terraform init -migrate-state` (move state) or `-reconfigure` (just point elsewhere; be sure that's what you mean).

### 9.5 A perpetual diff on `values` every plan

Terraform diffs the values **string**. Reformatting a YAML file, `yamlencode` output ordering differences, or a file with a trailing newline that changes. **Fix:** stable files; generate with `yamlencode` consistently; `terraform plan` after a no-op apply should say "No changes". As a last resort, `lifecycle { ignore_changes = [values] }` (and lose change detection).

### 9.6 `set` value types: `"true"` became a string / `"1.10"` became `1.1`

Helm parses `set` values like `--set`. **Fix:** `type = "string"` to force strings (`--set-string`), `type = "literal"` to stop comma/dot parsing (e.g. a comma-separated list), or put the value in a values file.

### 9.7 "another operation (install/upgrade/rollback) is in progress"

A previous run was killed mid-upgrade; the Helm release is `pending-*`. Terraform can't fix Helm's memory. **Fix:** `helm history <rel> -n <ns>`; `helm rollback <rel> <good-rev>` (or `helm uninstall` if it never succeeded); then `terraform apply`.

### 9.8 "cannot re-use a name that is still in use"

A release with that name exists but Terraform's state doesn't know it (created by hand, or state was lost). **Fix:** `import` it, or set `upgrade_install = true` on the resource to adopt it on the next apply.

### 9.9 Apply hangs, then "timed out waiting for the condition"

A pod never becomes Ready (PVC Pending, probe failing, image pull error), and `wait = true`. **Fix:** look at the cluster (`kubectl describe pod`, events); fix the chart values; raise `timeout` only if it's genuinely slow (operators, databases). After the timeout, expect gotcha 9.7 on the Helm side.

### 9.10 Changing `name` or `namespace` destroys and recreates the release

They're "ForceNew". PVCs from StatefulSets survive a Helm uninstall but not the namespace's deletion. **Fix:** don't rename releases in prod; if you must, `helm.sh/resource-policy: keep` on data-bearing objects, and a `moved` block won't help (it's a different object to Helm).

### 9.11 `terraform destroy` hangs on a namespace

The namespace contains a CR (e.g. `Kafka`) whose operator was already removed, so its finalizer never completes. **Fix:** destroy `apps/` before `platform/` before `cluster/`; if stuck, remove the finalizer (`kubectl patch … --type=merge -p '{"metadata":{"finalizers":[]}}'`) knowing that skips cleanup.

### 9.12 `kubernetes_manifest` fails at plan: "no matches for kind" / "cannot determine schema"

The CRD isn't installed yet (same apply as the operator, or a different layer that hasn't run). **Fix:** operators in `platform/`, CRs in `apps/`, or use a wrapper chart / `kubectl_manifest` (Part 6.7).

### 9.13 "Provider produced inconsistent final plan" / `.version: was known, but now unknown`

Usually `version = ""` or `version = var.x` with a floating/empty value, or `experiments.manifest` with charts that generate random values at render time (checksums, passwords). **Fix:** pin exact versions; avoid the manifest experiment on charts that use `randAlphaNum`; upgrade the provider.

### 9.14 Provider 2.x → 3.x: "Unsupported block type" / "An argument named set is not expected"

The v3 provider changed `kubernetes {}`, `registry {}`, `experiments {}` blocks to `= { }` attributes, and `set {}`/`set_list {}`/`set_sensitive {}` blocks to lists of objects. **Fix:** rewrite per the upgrade guide, `terraform init -upgrade`. State is migrated automatically.

### 9.15 `values` from `file()` is relative to the wrong directory

`file("values/x.yaml")` resolves against the directory you run Terraform in; in a module that's wrong. **Fix:** `file("${path.module}/values/x.yaml")`.

### 9.16 CI: "exec plugin: exec: 'aws'/'kubelogin': executable file not found"

The `exec` credential plugin isn't installed on the runner. **Fix:** install it (`az aks install-cli`, `aws` CLI, `gke-gcloud-auth-plugin`) in the job before `terraform init`.

### 9.17 Secrets appear in plan output or state

`set` instead of `set_sensitive`/`set_wo`; `random_password` results; data sources returning kubeconfigs. **Fix:** Part 6.6; mark outputs `sensitive = true`; treat state as secret regardless.

### 9.18 Two teams, one state key

Each apply undoes the other's work ("0 to add, 4 to change" every time). **Fix:** one key per root module; never reuse.

### 9.19 `count` index shift destroys the wrong things

Removing `apps[0]` from a list moves `apps[1]` into its slot → Terraform destroys and recreates. **Fix:** `for_each` with a map; convert with a `moved` block.

### 9.20 Workspaces: applied to the wrong environment

`terraform workspace show` says `default` but you thought `prod`. **Fix:** folders per environment; if using workspaces, print the workspace in CI logs and require `TF_WORKSPACE` explicitly.

### 9.21 State file too large for the Kubernetes backend

>1 MiB Secret. **Fix:** move to object storage; `init -migrate-state`.

### 9.22 `terraform_remote_state` read fails after another team enabled OIDC-only access

You depend on someone else's state file and its permissions. **Fix:** switch to cloud data sources or explicit outputs shared through a parameter store.

### 9.23 "Chart version X not found" though it exists

Stale repository cache inside the provider's HOME, or an OCI login missing. **Fix:** `helm repo update` isn't automatic for HTTP repos in the provider — set `repository_cache` to a fresh path in CI or use OCI; for OCI, `registries` in the provider or `helm registry login` first.

### 9.24 `create_namespace = true` left namespaces behind on destroy

Terraform never owned them. **Fix:** `kubernetes_namespace_v1` resources.

### 9.25 Plan shows a change every time because `metadata` recomputes

Older provider bug patterns; in 3.x `metadata` only recomputes when the version or values change. **Fix:** upgrade the provider; pin `version`.

### 9.26 Helm 4 CLI on the laptop, Helm 3 library in the provider

Releases created by the provider don't use server-side apply until the provider moves to the Helm 4 SDK; `--rollback-on-failure` renames don't exist in the provider (it's still `atomic`). Nothing breaks — but don't expect identical behavior between `helm` on your laptop and `terraform apply`.

---

<a id="part-10"></a>
## Part 10 — Troubleshooting and command cheat sheet

### First questions when something's wrong

```bash
terraform version                              # which CLI? matches the team's pin?
terraform workspace show                       # which workspace?
terraform state pull | jq '.terraform_version, .serial, .lineage'   # which state, how recent?
kubectl config current-context                 # which cluster is kubectl on? (may differ from the provider's!)
helm list -A                                   # what Helm thinks exists; STATUS column
terraform providers                            # provider versions in use
```

### Reading a plan

| Symbol | Meaning | Ask yourself |
|---|---|---|
| `+` | create | Expected? Or did Terraform lose track of something that exists (→ import)? |
| `~` | update in place | Which attribute? If it's `values`, is it a real change or formatting? |
| `-` | destroy | Always stop and read |
| `-/+` | destroy then create ("forces replacement") | Which attribute forced it? (`# forces replacement` marker) Can you avoid it? |
| `<=` | read (data source during apply) | Fine |
| `(known after apply)` | unknown until created | Normal for new resources; suspicious for providers' config |

### Verbose logs

```bash
TF_LOG=DEBUG TF_LOG_PATH=tf.log terraform plan
TF_LOG_PROVIDER=DEBUG terraform apply          # only provider chatter (Helm/Kubernetes API calls)
```

Search the log for `helm` lines around the failure; the provider logs the equivalent Helm operation and Kubernetes API errors verbatim.

### State inspection and repair

```bash
terraform state list
terraform state show 'module.app["lunch-api"].helm_release.this'
terraform state pull > backup-$(date +%F).tfstate
terraform state rm helm_release.orphan            # forget without uninstalling
terraform import helm_release.x school/x          # adopt
terraform plan -refresh-only                      # what drifted?
terraform apply -refresh-only                     # accept drift into state
terraform state push -force backup.tfstate        # restore (lineage/serial checks bypassed — be sure)
terraform force-unlock <ID>
```

### Helm-side checks Terraform can't do for you

```bash
helm status <rel> -n <ns>
helm history <rel> -n <ns>                        # pending-*? failed?
helm get values <rel> -n <ns> --all               # what the release actually has (compare with your values files)
helm get manifest <rel> -n <ns> | kubectl apply --dry-run=server -f -
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -20
```

### The complete command list

```bash
# Setup
terraform init [-upgrade] [-reconfigure] [-migrate-state] [-backend-config=file|key=val] [-input=false]
terraform providers [lock -platform=linux_amd64 -platform=darwin_arm64]   # multi-platform lock file
terraform login / logout
# Write
terraform fmt [-check] [-recursive] [-diff]
terraform validate [-json]
terraform console
# Plan/apply
terraform plan [-out=f] [-var x=1] [-var-file=f] [-target=addr] [-replace=addr] [-refresh-only] [-refresh=false] [-destroy] [-detailed-exitcode] [-parallelism=10] [-lock-timeout=5m] [-generate-config-out=f]
terraform apply [f] [-auto-approve] [-target=…] [-replace=…] [-refresh-only]
terraform destroy [-target=…]
# Inspect
terraform show [f] [-json]
terraform output [name] [-raw] [-json]
terraform graph [-type=plan]
terraform state list|show|mv|rm|pull|push|replace-provider [-state-out=…]
terraform workspace list|new|select|delete|show
terraform import ADDR ID
terraform test [-filter=f] [-verbose]
terraform force-unlock ID
terraform get [-update]                       # download modules only
terraform query                               # (1.14+) list resources with `list` blocks
```

---

<a id="part-11"></a>
## Part 11 — Glossary and field-trip exercises

### Glossary (30 seconds each)

- **Configuration** — your `.tf` files: what you want. **State** — the ledger: what Terraform did and the IDs. **Reality** — what exists. **Plan** — the diff among the three. **Apply** — executing the plan and updating the ledger.
- **Provider** — a plugin that speaks one API. **Resource** — a thing to manage. **Data source** — a thing to read. **Module** — a folder of `.tf` files you can call. **Root module** — the folder you run `apply` in; owns one state.
- **Backend** — where state lives and how it locks. **Lock** — the "someone is editing" sign. **Workspace** — a second state for the same config. **Lineage/serial** — the state's identity and version counter.
- **Refresh** — attendance: re-reading reality into state. **Drift** — reality changed behind Terraform's back. **Import** — adopting something that exists. **`moved`/`removed`** — renaming or dropping without destroying.
- **Ephemeral value / write-only argument** — a secret that never touches state. **Sensitive** — hidden from output only.
- **`helm_release`** — one Helm release as a resource. **Release Secret** — Helm's own ledger. **Two clipboards** — Terraform state + Helm release Secret; keep them agreeing.
- **HCP Terraform** — HashiCorp's hosted state/runs/policy service (formerly Terraform Cloud). **OpenTofu** — the open-source fork; adds state encryption.

### Field trips (do them in order)

1. **Part 1 with OpenTofu** (`tofu init/plan/apply`). Note the state file format is the same.
2. **Break the lock on purpose:** start `terraform apply` in one terminal, `terraform plan` in another; read the error; find the lock (`kubectl get lease -n terraform-state` or the `.tflock` object); let the apply finish; confirm the lock is gone.
3. **Drift:** `helm upgrade podinfo … --set ui.color=#ff0000` by hand, then `terraform plan -refresh-only` and `terraform plan`. Explain the difference in what each proposes.
4. **Lose the state:** `terraform state rm helm_release.podinfo`; run `terraform plan` (it wants to create); write an `import` block; plan; apply; plan again ("No changes").
5. **Two memories:** `helm uninstall podinfo -n demo` by hand; `terraform plan`. Then `terraform state rm` and compare with just re-applying.
6. **Backend migration:** move state from the Kubernetes backend to a local file and back (`init -migrate-state` twice). Read the Secret's size in bytes.
7. **Values drift:** add a blank line to your values file; `terraform plan`. Now switch that file to `yamlencode({...})`; plan; apply; plan.
8. **`set` types:** pass `"1.10"` as a `set` value with `type = "auto"` vs `"string"`; check `helm get values`.
9. **Write-only:** replace a `set_sensitive` with `set_wo` + an `ephemeral "random_password"`; `terraform state show` — the value is gone.
10. **Layers:** split your quick-start into `cluster/` (a `kind` cluster via the `tehcyx/kind` provider or a script) and `apps/`, reading the kubeconfig by file. Destroy `apps/` without touching `cluster/`.
11. **Cloud:** bootstrap one real backend (Part 4) with the CLI script, migrate the quick-start's state into it, then delete the bucket **after** `terraform destroy`.

### Where to read next

- Terraform state: https://developer.hashicorp.com/terraform/language/state
- Backends: https://developer.hashicorp.com/terraform/language/backend
- Helm provider: https://registry.terraform.io/providers/hashicorp/helm/latest/docs (and its `docs/guides/v3-upgrade-guide.md` on GitHub)
- Kubernetes provider: https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs
- Ephemeral values and write-only arguments: https://developer.hashicorp.com/terraform/language/resources/ephemeral
- HCP Terraform: https://developer.hashicorp.com/terraform/cloud-docs
- OpenTofu state encryption: https://opentofu.org/docs/language/state/encryption/
- Terragrunt: https://terragrunt.gruntwork.io

*Versions named here (Terraform 1.15, Helm provider 3.3, Kubernetes provider 2.38/3.x, Helm 4.3) were current in September 2026. Run `terraform providers` and read release notes before pinning.*
