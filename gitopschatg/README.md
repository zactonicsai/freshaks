# Local GitOps Lab: Kind + Gitea + Jenkins + Argo CD

This project builds a complete local GitOps learning lab on Docker Desktop.

## Architecture rule

**Jenkins builds. Git records the desired version. Argo CD deploys.**

Jenkins is deliberately prevented from deploying the application. It may run Gradle tests, build/push the container image, and validate Terraform, but it does **not** run `kubectl apply`, `helm upgrade`, or `terraform apply` for the application.

| Piece | Job |
|---|---|
| Docker | Runs the Kind node and local OCI registry |
| Kind | Local Kubernetes cluster |
| Helm | Installs Argo CD and Jenkins |
| Gitea pod | Free self-hosted Git server for the app repo and GitOps repo |
| `localhost:5001` | Registry address used by Kind workload manifests |
| Jenkins | Test/build image, push image, update GitOps image tag |
| Argo CD | Watches GitOps repo and is the only app deployer |
| Gradle | Builds and tests the Java sample app |
| Terraform | Demonstrates read-only Kubernetes provider connectivity; no app resources |

## Data flow

```text
Developer
   |
   | git push
   v
Gitea: app-repo ----------------------+
                                      |
                                      v
                                 Jenkins
                             Gradle test/build
                                      |
                     Jib pushes OCI image
                                      |
                                      v
                         kind-registry:5000
                         localhost:5001
                                      |
                     Jenkins edits ONLY newTag
                                      |
                                      v
Gitea: gitops-repo -------------------+
   |                                  |
   | Argo CD polls Git                |
   v                                  |
Argo CD ------------------------------+
   |
   | kubectl-style reconciliation done by Argo CD
   v
Kubernetes Deployment -> demo-app Pod(s)
```

## Fast start

Prerequisites on macOS: Docker Desktop, `kind`, `kubectl`, `helm`, `git`, `curl`, and optionally `terraform` for the local Terraform exercise.

```bash
cd gitops-kind-lab

./scripts/00-prereqs.sh
./scripts/01-create-kind-registry.sh
./scripts/02-install-gitea.sh
./scripts/03-seed-gitea-repos.sh
./scripts/04-install-argocd.sh
./scripts/05-install-jenkins.sh
./scripts/06-create-jenkins-job.sh
./scripts/07-bootstrap-argocd-app.sh
./scripts/08-trigger-build.sh
./scripts/09-status.sh
```

The first Argo sync can show an image pull error until Jenkins finishes the first build and updates the GitOps repository. That is intentional: Jenkins produces the image and desired tag; Argo CD then makes the cluster match Git.

## Open the tools

Run each command in its own terminal.

```bash
# Gitea
kubectl -n gitea port-forward svc/gitea 3000:3000
# http://localhost:3000

# Argo CD
kubectl -n argocd port-forward svc/argocd-server 8080:80
# http://localhost:8080

# Jenkins
kubectl -n jenkins port-forward svc/jenkins 8081:8080
# http://localhost:8081

# Demo app after Argo sync
kubectl -n demo-app port-forward svc/demo-app 8082:8080
# http://localhost:8082
```

Lab users/passwords are intentionally simple and must not be reused outside a disposable local lab:

- Gitea: `gitadmin` / `gitadmin123`
- Jenkins: `admin` / `jenkins123`
- Argo CD: user `admin`; get the generated password with `./scripts/09-status.sh`

## What Jenkins is allowed to do

Allowed:

1. Checkout `app-repo`.
2. Run Gradle tests.
3. Run a Terraform **read-only plan** that proves the Kubernetes provider can reach the cluster.
4. Use Jib to build/push `demo-app:<tag>` to the local registry.
5. Clone `gitops-repo`.
6. Change `newTag:` in `environments/local/kustomization.yaml`.
7. Commit and push that Git change.

Not allowed:

- `kubectl apply`
- `kubectl set image`
- `helm upgrade` for the application
- `terraform apply` for the application
- direct Kubernetes Deployment edits

## Folder map

```text
gitops-kind-lab/
├── argocd/                 # Argo CD Helm values + Application CR
├── docs/                   # Architecture and beginner tutorial
├── gitea/                  # Free Git server Kubernetes manifest
├── jenkins/                # Jenkins Helm values, RBAC and job XML
├── kind/                   # Kind config
├── scripts/                # Numbered setup/test/destroy scripts
├── seed/
│   ├── app-repo/           # Java/Gradle app + Jenkinsfile + Terraform CI check
│   └── gitops-repo/        # Desired Kubernetes state watched by Argo CD
├── terraform/local/        # Local read-only Kubernetes provider example
└── tests/                   # Static architecture guard tests
```

Read `docs/TUTORIAL.md` for the full grocery-store/school explanation.
