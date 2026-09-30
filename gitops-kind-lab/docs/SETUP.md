# Step-by-step setup

## 1. Prerequisites

Install Docker, then:

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.30.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# argocd CLI (optional)
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd && sudo mv argocd /usr/local/bin/
```

macOS: `brew install kind kubectl helm argocd`.

Run `./scripts/00-prereq-check.sh`.

## 2. Cluster + local registry

```bash
./scripts/01-create-cluster.sh
kubectl get nodes
```

This creates:

- Docker registry `kind-registry` published on `127.0.0.1:5001`
- Kind cluster named `gitops`
- containerd rewrite so pods can pull `localhost:5001/...`

## 3. Install Argo CD with Helm

```bash
./scripts/02-install-argocd.sh
```

UI: http://localhost:8081

Initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Login user: `admin`.

If the CLI is installed:

```bash
argocd login localhost:8081 --username admin --password '<password>' --insecure
```

## 4. Install Bitbucket as a pod

```bash
./scripts/03-install-bitbucket.sh
```

Wait until the pod is Ready (first pull + JVM start can take several minutes):

```bash
kubectl -n scm get pods -w
```

Open http://localhost:7990

Complete the setup wizard:

1. Choose **Standalone** (not Data Center cluster).
2. Internal H2 database is acceptable for this lab.
3. Create admin user (example: `admin` / `admin`).
4. Create a project, e.g. `DEMO`.
5. Create two repositories:
   - `demo-app` (application source)
   - `demo-gitops` (manifests Argo CD watches)
6. Create an **HTTP access token** (personal or repo) with read + write on both repos.

Clone URLs from inside the cluster look like:

```
http://bitbucket.scm.svc.cluster.local:7990/scm/demo/demo-app.git
http://bitbucket.scm.scm.svc.cluster.local:7990/scm/demo/demo-gitops.git
```

From the host:

```
http://localhost:7990/scm/demo/demo-app.git
```

Exact path depends on the project key Bitbucket assigns (often `DEMO`).

## 5. Push starter content into Bitbucket

From the host, after the wizard:

```bash
export BB_USER=admin
export BB_PASS='your-token-or-password'
export BB_PROJECT=DEMO   # project key

git clone http://${BB_USER}:${BB_PASS}@localhost:7990/scm/${BB_PROJECT}/demo-app.git /tmp/demo-app
cp -a sample-app/. /tmp/demo-app/
cd /tmp/demo-app
git add .
git commit -m "Initial app + Jenkinsfile"
git push origin master   # or main — match Bitbucket default

git clone http://${BB_USER}:${BB_PASS}@localhost:7990/scm/${BB_PROJECT}/demo-gitops.git /tmp/demo-gitops
cp -a gitops/. /tmp/demo-gitops/
cd /tmp/demo-gitops
# Edit demo-app/deployment.yaml if your project key differs
git add .
git commit -m "Initial GitOps manifests"
git push origin master
```

Or run `./scripts/05-bootstrap-repos.sh` after exporting `BB_USER`, `BB_PASS`, and `BB_PROJECT`.

## 6. Point Argo CD at Bitbucket

HTTP Bitbucket in this lab has no trusted TLS. Mark the repo insecure.

UI: Settings → Repositories → Connect Repo

- URL: `http://bitbucket.scm.svc.cluster.local:7990/scm/DEMO/demo-gitops.git`
- Username + password or HTTP access token
- Skip server verification

CLI:

```bash
argocd repo add http://bitbucket.scm.svc.cluster.local:7990/scm/DEMO/demo-gitops.git \
  --username admin \
  --password "$BB_PASS" \
  --insecure-skip-server-verification
```

Create the Application:

```bash
./scripts/06-register-argocd-app.sh
# or
kubectl apply -f gitops/argocd/application.yaml
```

Edit `gitops/argocd/application.yaml` so `repoURL` matches your project key before apply.

Argo CD should sync `demo-app` into namespace `apps`.

## 7. Install Jenkins with Helm

```bash
./scripts/04-install-jenkins.sh
```

UI: http://localhost:8082

Admin password:

```bash
kubectl -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

User: `admin`.

### Jenkins credentials

Create:

| ID | Type | Use |
|---|---|---|
| `bitbucket-http` | Username + password | Clone/push Bitbucket |
| `registry-none` | optional | Local registry has no auth |

### Jenkins Kubernetes cloud

The official chart already installs the Kubernetes plugin and a service account. Confirm **Manage Jenkins → Clouds → kubernetes** exists.

Agents use the pod template in `helm/jenkins-values.yaml` (`kaniko` + `git` containers).

### Multibranch or Pipeline job

1. New Item → Pipeline
2. Definition: Pipeline script from SCM
3. SCM: Git
4. Repo: `http://bitbucket.scm.svc.cluster.local:7990/scm/DEMO/demo-app.git`
5. Credentials: `bitbucket-http`
6. Script path: `Jenkinsfile`

### Bitbucket webhook (optional)

Repository settings → Webhooks → `http://jenkins.jenkins.svc.cluster.local:8080/bitbucket-hook/`

Install the Bitbucket plugin if you use that trigger. Poll SCM also works for a lab.

## 8. What the pipeline does

`sample-app/Jenkinsfile`:

1. Checkout `demo-app`
2. Kaniko builds and pushes `kind-registry:5000/demo-app:<BUILD_NUMBER>-<GIT_COMMIT>`
3. Clone `demo-gitops`
4. `sed` the image tag in `demo-app/deployment.yaml`
5. Commit and push to Bitbucket
6. Argo CD sees the commit and rolls out the new image

Do **not** `kubectl apply` from Jenkins.

## 9. Verify end-to-end

```bash
# after a green Jenkins build
kubectl -n apps get deploy,pods,svc
kubectl -n apps describe deploy demo-app | grep Image
argocd app get demo-app
```

Change `sample-app/app.py`, push to `demo-app`, run the job, watch Argo CD sync.

## 10. Common failures

| Symptom | Fix |
|---|---|
| Image pull `localhost:5001` fails | Re-run registry hosts.toml step in `01-create-cluster.sh`; confirm `docker network connect kind kind-registry` |
| Kaniko cannot reach registry | Push target must be `kind-registry:5000`, not `localhost:5001` |
| Argo CD cannot clone Bitbucket | Use in-cluster DNS + `--insecure-skip-server-verification` |
| Bitbucket pending forever | Give the pod 2–4 GB; check `kubectl -n scm logs sts/bitbucket` or the deployment logs |
| Jenkins agent pending | Chart RBAC / default SA; `kubectl -n jenkins get sa,rolebinding` |
| Argo CD OutOfSync after push | Confirm you pushed the **gitops** repo, not only the app repo |

## 11. Teardown

```bash
./scripts/teardown.sh
```

Removes the Kind cluster and the `kind-registry` container. PVCs die with the cluster.
