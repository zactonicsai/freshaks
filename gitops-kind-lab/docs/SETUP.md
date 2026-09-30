# Step-by-step setup (Gitea Community)

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

## 3. Install Argo CD with Helm

```bash
./scripts/02-install-argocd.sh
```

UI: http://localhost:8081

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

User: `admin`.

```bash
argocd login localhost:8081 --username admin --password '<password>' --insecure
```

## 4. Install Gitea (community, free)

Default path is a single pod + SQLite (`k8s/gitea.yaml`):

```bash
./scripts/03-install-gitea.sh
```

UI: http://localhost:3000
User: `gitea_admin`
Password: `LabPass123!`

The script creates the admin user and two repos:

- `gitea_admin/demo-app`
- `gitea_admin/demo-gitops`

Optional: official Gitea Helm chart instead of the raw Deployment:

```bash
helm repo add gitea-charts https://dl.gitea.com/charts/
helm upgrade --install gitea gitea-charts/gitea \
  -n gitea --create-namespace \
  -f helm/gitea-values.yaml
```

If you use the Helm chart, the HTTP service name may be `gitea-http` instead of `gitea`. Update clone URLs in the Jenkinsfile and Argo CD Application.

## 5. Seed the first image + push starter Git content

```bash
./scripts/seed-image.sh
./scripts/05-bootstrap-repos.sh
```

Override credentials if you changed them:

```bash
GITEA_USER=gitea_admin GITEA_PASS='LabPass123!' ./scripts/05-bootstrap-repos.sh
```

## 6. Point Argo CD at Gitea

```bash
./scripts/06-register-argocd-app.sh
```

Or CLI:

```bash
argocd repo add http://gitea.gitea.svc.cluster.local:3000/gitea_admin/demo-gitops.git \
  --username gitea_admin \
  --password 'LabPass123!' \
  --insecure-skip-server-verification
```

Argo CD syncs `demo-app` into namespace `apps`.

## 7. Install Jenkins with Helm

```bash
./scripts/04-install-jenkins.sh
```

UI: http://localhost:8082

```bash
kubectl -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

### Jenkins credentials

| ID | Type | Use |
|---|---|---|
| `gitea-http` | Username + password | `gitea_admin` / `LabPass123!` |

### Pipeline job

1. New Item → Pipeline
2. Definition: Pipeline script from SCM
3. SCM Git URL: `http://gitea.gitea.svc.cluster.local:3000/gitea_admin/demo-app.git`
4. Credentials: `gitea-http`
5. Branch: `main`
6. Script path: `Jenkinsfile`

### Optional webhook

Gitea repo `demo-app` → Settings → Webhooks → Add webhook

- URL: `http://jenkins.jenkins.svc.cluster.local:8080/gitea-webhook/post`
- Triggers: Push

Install the Gitea plugin if you use that trigger. Poll SCM is enough for a lab.

## 8. What the pipeline does

1. Checkout `demo-app`
2. Kaniko builds and pushes `kind-registry:5000/demo-app:<BUILD>-<sha>`
3. Clone `demo-gitops`
4. Update `demo-app/deployment.yaml` image to `localhost:5001/demo-app:<tag>`
5. Commit and push to Gitea
6. Argo CD rolls out the new image

Do **not** `kubectl apply` from Jenkins.

## 9. Verify

```bash
kubectl -n apps get deploy,pods,svc
kubectl -n apps describe deploy demo-app | grep Image
argocd app get demo-app
```

Change `sample-app/app.py`, push to `demo-app`, run Jenkins, watch Argo CD sync.

## 10. Common failures

| Symptom | Fix |
|---|---|
| Image pull `localhost:5001` fails | Re-run registry step in `01-create-cluster.sh`; `docker network connect kind kind-registry` |
| Kaniko cannot reach registry | Destination must be `kind-registry:5000` |
| Argo CD cannot clone | In-cluster URL `gitea.gitea.svc.cluster.local:3000` + insecure HTTP |
| Gitea `/api/healthz` not ready | Wait; first pull of `gitea/gitea` can take a few minutes |
| 401 on git push | Use `gitea_admin` / `LabPass123!` and confirm the user exists (`03` script) |
| Helm Gitea service name differs | Chart uses `gitea-http`; update Jenkinsfile + Application `repoURL` |

## 11. Teardown

```bash
./scripts/teardown.sh
```
