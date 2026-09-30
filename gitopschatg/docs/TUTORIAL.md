# Beginner Tutorial: Build a Local GitOps Factory

Think of this lab like a school cafeteria.

- **Git** is the recipe notebook.
- **Jenkins** is the cook who prepares lunch.
- **The registry** is the refrigerator where finished food is labeled and stored.
- **The GitOps repo** is the lunch board saying exactly which labeled meal should be served.
- **Argo CD** is the cafeteria manager who reads the board and puts that exact meal on the serving line.
- **Kubernetes** is the cafeteria building, tables, workers, and serving stations.

The cook does **not** decide what goes onto the serving line. Jenkins builds and labels the product, then changes the board. Argo CD reads the board and deploys it.

## Phase 1 — Check your tools

```bash
./scripts/00-prereqs.sh
```

This checks Docker, Kind, kubectl, Helm, Git, and curl.

## Phase 2 — Create the Kind cluster and local registry

```bash
./scripts/01-create-kind-registry.sh
```

What happens:

1. Docker starts a registry container named `kind-registry` on host port `5001`.
2. Kind creates a Kubernetes cluster named `gitops-lab`.
3. The registry joins Kind's Docker network.
4. Each Kind node gets a containerd `hosts.toml` mapping so a pod image named `localhost:5001/...` can be pulled from the registry container.

Check it:

```bash
kubectl cluster-info --context kind-gitops-lab
kubectl get nodes
curl http://localhost:5001/v2/
```

An empty `{}` or successful HTTP response from `/v2/` means the registry is answering.

## Phase 3 — Install the Git server

```bash
./scripts/02-install-gitea.sh
```

Gitea is like a small private GitHub/Bitbucket for the lab. The script creates an admin user named `gitadmin`.

Open it:

```bash
kubectl -n gitea port-forward svc/gitea 3000:3000
```

Then browse to `http://localhost:3000`.

## Phase 4 — Create the two Git repositories

```bash
./scripts/03-seed-gitea-repos.sh
```

The script creates:

- `app-repo`: Java code, Gradle build, Jenkinsfile, read-only Terraform check.
- `gitops-repo`: Kubernetes Deployment, Service, Namespace, and Kustomize file.

The important line in the GitOps repo is:

```yaml
newTag: bootstrap
```

Jenkins will replace only that tag.

## Phase 5 — Install Argo CD using Helm

```bash
./scripts/04-install-argocd.sh
```

Helm is like an app installer for Kubernetes. It installs all the Argo CD pieces.

At this point Argo CD exists, but the demo Application object is created later.

## Phase 6 — Install Jenkins using Helm

```bash
./scripts/05-install-jenkins.sh
```

The Jenkins Kubernetes plugin starts temporary build-agent pods. The agent has three useful containers:

- `gradle`: compile/test and Jib image build.
- `git`: checkout and GitOps commit/push.
- `terraform`: read-only provider test.

The script also creates a tiny read-only Kubernetes permission so Terraform can read the `default` namespace.

## Phase 7 — Create the Jenkins pipeline job

```bash
./scripts/06-create-jenkins-job.sh
```

The job points to `app-repo/Jenkinsfile`.

Open Jenkins:

```bash
kubectl -n jenkins port-forward svc/jenkins 8081:8080
```

Browse to `http://localhost:8081` and sign in with `admin / jenkins123`.

## Phase 8 — Register the app with Argo CD

```bash
./scripts/07-bootstrap-argocd-app.sh
```

This applies one Argo CD `Application` custom resource. That is the bootstrap pointer telling Argo CD where desired state lives. It does **not** directly apply the Java Deployment.

Argo initially sees `bootstrap`. Because no such Java image exists yet, the Pod may show `ImagePullBackOff`. That is okay for this teaching flow.

## Phase 9 — Trigger Jenkins

```bash
./scripts/08-trigger-build.sh
```

Jenkins performs this sequence:

1. Checkout application source.
2. Run `gradle clean test`.
3. Run a Terraform read-only plan against Kubernetes.
4. Make an immutable tag like `build-1-a1b2c3d`.
5. Use Jib to push the Java image to `kind-registry:5000/demo-app:<tag>`.
6. Clone `gitops-repo`.
7. Change `newTag` to the new immutable tag.
8. Commit and push.
9. Stop. Jenkins never deploys the app.

Argo CD sees the Git change and reconciles Kubernetes.

## Phase 10 — Verify each handoff

```bash
./scripts/09-status.sh
```

Useful manual checks:

```bash
# Registry tags
curl http://localhost:5001/v2/demo-app/tags/list

# GitOps desired state
kubectl -n gitea port-forward svc/gitea 3000:3000
# Then inspect gitops-repo in the browser.

# Argo app
kubectl -n argocd get application demo-app

# Deployment
kubectl -n demo-app get deploy,pod,svc

# Image actually running
kubectl -n demo-app get deploy demo-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Open the app:

```bash
kubectl -n demo-app port-forward svc/demo-app 8082:8080
curl http://localhost:8082/
curl http://localhost:8082/health
```

## Rollback exercise

Pretend build 3 is bad and build 2 was good.

Do **not** run `kubectl set image`.

Instead, change `newTag:` in the GitOps repository back to the build-2 tag and push the commit. Argo CD sees Git and rolls the cluster back.

That is GitOps: Git is the report card that says what should exist.

## Terraform exercise

From your Mac:

```bash
cd terraform/local
terraform init
terraform plan
```

The configuration only reads the `default` namespace. There are no resources. This demonstrates Kubernetes provider connectivity without creating a second deployment owner.

## Destroy the lab

```bash
./scripts/10-destroy.sh
```

Deleting the Kind cluster removes the Kubernetes lab. Deleting `kind-registry` removes the local image registry.
