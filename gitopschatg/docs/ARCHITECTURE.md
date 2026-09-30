# Architecture

## The one-way deployment rule

The important design is a one-way handoff:

```text
Source Git -> Jenkins -> Registry + Desired-State Git -> Argo CD -> Kubernetes
```

Jenkins has no application deployment command. This avoids two tools fighting over the same Deployment.

### Why two Git repositories?

`app-repo` answers: **What code should we build?**

`gitops-repo` answers: **What version should the cluster run?**

Keeping those questions separate makes rollback easy. A rollback is a Git commit that puts an older image tag back into the GitOps repository.

## Local registry naming

The host pushes/pulls through `localhost:5001`.

A process inside a pod uses the Kind registry container as `kind-registry:5000` when pushing. Kubernetes workload YAML still uses `localhost:5001/...`; Kind's containerd registry configuration redirects that name to the registry container.

## Terraform boundary

Terraform is included because it is valuable to learn the Kubernetes provider, but it is deliberately read-only here.

The CI Terraform configuration contains a Kubernetes namespace **data source**, not a resource. `terraform plan` proves the provider can authenticate to the API. It cannot replace Argo CD as an application deployer because there is nothing for Terraform to apply.

For a real environment, Terraform is a good fit for platform foundations such as cloud VPCs, managed Kubernetes clusters, IAM, DNS, and external databases. Once Kubernetes application manifests are GitOps-managed, keep them owned by Argo CD.

## Gitea instead of Bitbucket Data Center

This lab defaults to Gitea because it is free and self-hostable. If you already have a licensed Bitbucket Data Center instance or want to use Bitbucket Cloud, replace the two repository URLs and credentials; the GitOps flow remains the same.
