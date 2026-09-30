# GitOps Lab: Kind + Helm + Argo CD + Bitbucket + Jenkins

Local GitOps stack on Docker:

```
Developer push
    → Bitbucket (Git, running as a pod)
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
| `helm/` | Argo CD and Jenkins Helm values |
| `k8s/` | Bitbucket Deployment, registry ConfigMap |
| `sample-app/` | Tiny Flask app + Dockerfile + Jenkinsfile |
| `gitops/` | Manifests Argo CD syncs |
| `scripts/` | Install, bootstrap, teardown |
| `docs/SETUP.md` | Full step-by-step |

## Requirements

- Docker Engine running
- 16 GB RAM recommended (8 GB will struggle)
- Host tools: `kind`, `kubectl`, `helm`, `argocd` CLI (optional)
- Atlassian Bitbucket Server/Data Center image is commercial. Fine for a personal lab; not a production license.

## Quick start

```bash
cd gitops-kind-lab
chmod +x scripts/*.sh
./scripts/00-prereq-check.sh
./scripts/01-create-cluster.sh
./scripts/02-install-argocd.sh
./scripts/03-install-bitbucket.sh
# Finish Bitbucket setup wizard at http://localhost:7990
./scripts/04-install-jenkins.sh
# Then follow docs/SETUP.md to create repos, tokens, and the first pipeline run
```

Teardown:

```bash
./scripts/teardown.sh
```

## Ports on the host

| Host | Service |
|---|---|
| `localhost:7990` | Bitbucket HTTP |
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
