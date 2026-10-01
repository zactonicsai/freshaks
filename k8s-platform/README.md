# k8s-platform

Deploy the same platform and workloads to any conformant Kubernetes cluster.
Jenkins runs the pipeline, Terraform creates the cluster and installs Argo CD,
and Argo CD deploys everything else from Git.

```
config/global.yaml            versions, charts, images, Helm values: the single source of truth
config/clusters/<name>.yaml   one file per cluster: type, size, state backend, overrides
scripts/                      deploy.sh, destroy.sh, validate.sh, set-version.sh
terraform/clusters/<type>/    one driver per cluster type: main.tf + kubeconfig.sh
terraform/bootstrap/          Argo CD + the root Application (same for every type)
gitops/platform/              app of apps: one Argo CD Application per add-on and app
charts/generic-app/           one Helm chart for any container
Jenkinsfile                   plan / deploy / destroy a cluster
Jenkinsfile.release           template for app repositories: build, push, bump version in Git
```

## Quick start (local cluster)

Tools: `terraform` 1.6+ (or `tofu`), `kubectl`, `helm`, `yq` v4, `kind`, and Docker or Podman.

1. Put this folder in your own Git repository and push it.
2. Set `gitops.repoURL` in `config/global.yaml` to that repository and push again.
   Argo CD deploys what is in Git, not what is on your disk.
3. Run:

```bash
scripts/validate.sh local-docker      # offline checks, renders what Argo CD will create
scripts/deploy.sh local-docker        # cluster, Argo CD, then everything in config/
export KUBECONFIG=.build/local-docker/kubeconfig
kubectl -n argocd get applications
scripts/destroy.sh local-docker       # removes all of it again
```

Private repository: `export TF_VAR_git_username=... TF_VAR_git_token=...` before deploying.
OpenTofu: `export TF_BIN=tofu`.

## Everyday tasks

| Task | How |
| --- | --- |
| Add a workload | Add an entry under `apps:` in `config/global.yaml` and commit. |
| Release a new image | `scripts/set-version.sh <app> <tag> [digest]` and commit (see `Jenkinsfile.release`). |
| Change one cluster only | Set the same keys in `config/clusters/<name>.yaml`. Maps merge, lists and scalars replace. |
| Switch something off | `enabled: false` on the add-on or app. |
| Upgrade a chart | Change its `version` in `config/global.yaml` and commit. |
| Upgrade Argo CD | Change `gitops.argocd.chartVersion`, commit, rerun `deploy.sh`. |
| Add a cluster | Copy a file in `config/clusters/`, set `cluster.name` to the new file name, deploy. |
| Add a cluster type | New folder `terraform/clusters/<type>/` with `main.tf` and `kubeconfig.sh`, plus a `hostedAddonCatalog.<type>` entry. |
| Remove a cluster | `scripts/destroy.sh <name>` (set `cluster.protect: false` first). |

## Cluster types

| `cluster.type` | Creates | CLI on the agent | Credentials |
| --- | --- | --- | --- |
| `kind` | Local cluster on Docker or Podman (`cluster.runtime`) | `kind` | none |
| `eks` | VPC, EKS, managed node group, add-ons | `aws` | `AWS_*` or an agent role |
| `aks` | Resource group, AKS | `az` | `ARM_*` or a managed identity |
| `iks` | VPC, subnet, IBM Cloud Kubernetes Service | `ibmcloud` + `ks` plug-in | `IC_API_KEY` |
| `vks` | A Cluster object on a vSphere Supervisor | `kubectl` | Supervisor kubeconfig |
| `existing` | Nothing: uses a cluster that is already there | `kubectl` | `cluster.kubeconfig` or `SOURCE_KUBECONFIG` |

## Jenkins

- Create a Pipeline job from `Jenkinsfile`. The agent label is `platform`; it needs the tools above.
- Per cluster, store a "Secret file" credential of `KEY=VALUE` lines and name it in
  `jenkins.credentialsId` of the cluster file. Prefer short-lived identities (OIDC, agent roles).
- Clusters deployed from Jenkins need a `state:` block. The workspace is wiped after every build.
- Run one build per checkout at a time: `backend.tf.json` is generated inside the stack folders.

## Before first use

- Replace the placeholders: `gitops.repoURL`, state buckets, credential ids, VKS values.
- Check the Kubernetes versions against what your provider offers today.
- Run `terraform init` once per stack and commit the `.terraform.lock.hcl` files.
- The cloud drivers passed `validate` against current provider schemas but have not been
  applied to a live account. Run `scripts/deploy.sh <cluster> plan` and read the plan first.
