# Jenkins on Kubernetes with Global Build Variables

Every Jenkins build pod gets the variables in `globalVar.yaml` as environment variables.

## How it works

1. The `jenkins-globals` chart turns `globalVar.yaml` into a ConfigMap named `jenkins-global-vars`.
2. `jenkins-values.yaml` merges an `envFrom` entry for that ConfigMap into the default agent pod template.
3. Each build runs in a new agent pod, so it reads the current ConfigMap values at start.

## Project layout

```
jenkins-values.yaml              # values for the official jenkins/jenkins chart
globalVar.yaml                   # your global variables (edit this)
jenkins-globals/
  Chart.yaml
  values.yaml                    # defaults (empty)
  templates/configmap.yaml       # builds the ConfigMap, validates key names
```

## Prerequisites

- A Kubernetes cluster and `kubectl` configured for it (`kubectl get nodes` works)
- Helm 3

## Install

Both releases must be in the same namespace. These steps use `jenkins`.

### 1. Create the namespace

```bash
kubectl create namespace jenkins
```

### 2. Add the Jenkins Helm repo

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update
```

 kubectl port-forward svc/jenkins 8081:8080

### 3. Preview the ConfigMap (optional)

```bash
helm template jenkins-globals ./jenkins-globals -f globalVar.yaml
```

### 4. Install the global variables first

The ConfigMap must exist before any build pod starts.

```bash
helm upgrade --install jenkins-globals ./jenkins-globals \
  -n jenkins -f globalVar.yaml
```

Check it:

```bash
kubectl get configmap jenkins-global-vars -n jenkins -o yaml
```

### 5. Install Jenkins

```bash
helm upgrade --install jenkins jenkins/jenkins \
  -n jenkins -f jenkins-values.yaml
```

Wait for the controller to be ready:

```bash
kubectl rollout status statefulset/jenkins -n jenkins
kubectl get pods -n jenkins
```

## Open Jenkins

The service is a NodePort. Find the port:

```bash
kubectl get svc jenkins -n jenkins
```

Then browse to `http://<node-ip>:<node-port>`. To get a node IP:

```bash
kubectl get nodes -o wide
```

Or use a port-forward and browse to http://localhost:8080:

```bash
kubectl port-forward svc/jenkins 8080:8080 -n jenkins
```

Admin login is set in `jenkins-values.yaml` (`admin` / `admin`). To read it from the cluster:

```bash
kubectl get secret jenkins -n jenkins \
  -o jsonpath="{.data.jenkins-admin-password}" | base64 -d; echo
```

Change this password before using the setup for anything real.

## Use the variables in a pipeline

```groovy
pipeline {
  agent any
  stages {
    stage('Show globals') {
      steps {
        sh 'echo "APP_ENV=$APP_ENV REGISTRY_URL=$REGISTRY_URL"'
      }
    }
  }
}
```

## Verify a build pod has the variables

Start a build, then while it runs:

```bash
kubectl get pods -n jenkins -l jenkins/jenkins-jenkins-agent=true
kubectl exec -n jenkins <agent-pod-name> -c jnlp -- env | sort
```

## Change a variable

1. Edit `globalVar.yaml`.
2. Apply it:

   ```bash
   helm upgrade --install jenkins-globals ./jenkins-globals \
     -n jenkins -f globalVar.yaml
   ```

The next build uses the new values. Jenkins does not need a restart.

Key names must be valid environment variable names: letters, digits and underscores, not starting with a digit. An invalid key makes the install fail with a clear message.

## Upgrade Jenkins settings

After editing `jenkins-values.yaml`:

```bash
helm upgrade jenkins jenkins/jenkins -n jenkins -f jenkins-values.yaml
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Agent pod stuck in `CreateContainerConfigError` | The ConfigMap is missing or in another namespace: `kubectl get cm jenkins-global-vars -n jenkins` |
| Variables missing in the build | `kubectl describe pod <agent-pod> -n jenkins` and look for `envFrom` on the `jnlp` container |
| Controller not starting | `kubectl logs statefulset/jenkins -n jenkins -c jenkins` |
| Pod events | `kubectl get events -n jenkins --sort-by=.lastTimestamp` |

## Uninstall

```bash
helm uninstall jenkins -n jenkins
helm uninstall jenkins-globals -n jenkins
kubectl delete namespace jenkins
```

Deleting the namespace also removes the Jenkins home volume claim and all job data.
