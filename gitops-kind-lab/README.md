# GitOps Lab: Kind + Helm + Argo CD + Gitea + Jenkins

Local GitOps stack on Docker. Git hosting is **Gitea Community** (MIT, free) instead of Bitbucket.

```
Developer push
    → Gitea (Git, running as a pod)
        → Jenkins webhook (CI)
            → build image
            → push to local registry
            → update image tag in Git
            → commit / push
        → Argo CD (CD) watches Git
            → deploys to Kind
```

Jenkins never deploys to Kubernetes. It only builds and writes the new image tag to Git. Argo CD is the only deployer.

## What you get

| Path | Purpose |
|---|---|
| `kind/` | Kind cluster config + extra NodePorts |
| `helm/` | Argo CD, Jenkins, optional Gitea Helm values |
| `k8s/` | Gitea Deployment (default), registry ConfigMap |
| `sample-app/` | Tiny Flask app + Dockerfile + Jenkinsfile |
| `gitops/` | Manifests Argo CD syncs |
| `scripts/` | Install, bootstrap, teardown |
| `docs/SETUP.md` | Full step-by-step |

## Requirements

- Docker Engine running
- 8–16 GB RAM (Gitea + SQLite is much lighter than Bitbucket)
- Host tools: `kind`, `kubectl`, `helm`, `argocd` CLI (optional)

Gitea is MIT-licensed community software. No Atlassian license.

## Quick start

```bash
cd gitops-kind-lab
chmod +x scripts/*.sh
./scripts/00-prereq-check.sh
./scripts/01-create-cluster.sh
./scripts/02-install-argocd.sh
./scripts/03-install-gitea.sh
./scripts/seed-image.sh
./scripts/05-bootstrap-repos.sh
./scripts/06-register-argocd-app.sh
./scripts/04-install-jenkins.sh
```

Default Gitea login: `gitea_admin` / `LabPass123!`  
UI: http://localhost:3000

Teardown:

```bash
./scripts/teardown.sh
```

## Ports on the host

| Host | Service |
|---|---|
| `localhost:3000` | Gitea HTTP |
| `localhost:2222` | Gitea SSH |
| `localhost:8081` | Argo CD UI |
| `localhost:8082` | Jenkins UI |
| `localhost:5001` | Local container registry |

## Image registry convention

| Where you are | Image reference |
|---|---|
| Host (`docker push`) | `localhost:5001/demo-app:<tag>` |
| Jenkins / pods pushing | `kind-registry:5000/demo-app:<tag>` |
| Kubernetes manifests / Argo CD | `localhost:5001/demo-app:<tag>` |

Kind remaps `localhost:5001` inside nodes to the registry container.

## Gitea clone URLs

| From | URL |
|---|---|
| Host | `http://localhost:3000/gitea_admin/demo-app.git` |
| In-cluster (Jenkins, Argo CD) | `http://gitea.gitea.svc.cluster.local:3000/gitea_admin/demo-app.git` |
