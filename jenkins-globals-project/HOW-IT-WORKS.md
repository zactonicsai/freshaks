# How Global Build Variables Work

This guide explains how values in `globalVar.yaml` end up as environment variables in every Jenkins build, and how to change them so new builds get the new values.

## The short version

- `globalVar.yaml` is the single source of truth.
- `helm upgrade --install jenkins-globals ...` writes it into a ConfigMap named `jenkins-global-vars`.
- Every Jenkins agent pod loads that whole ConfigMap as environment variables when it starts.
- Each build gets a brand-new pod, so **the next build after an update sees the new values**. No Jenkins restart is needed.

## The flow

```
globalVar.yaml
     │  helm upgrade --install jenkins-globals ./jenkins-globals -f globalVar.yaml
     ▼
ConfigMap: jenkins-global-vars          (namespace: jenkins)
     │  envFrom: configMapRef            (set in jenkins-values.yaml → agent.yamlTemplate)
     ▼
Agent pod "default-xxxxx", container jnlp
     │  env vars read once, at container start
     ▼
Your pipeline:  sh 'echo $APP_ENV'
```

## The pieces

### `globalVar.yaml`: your variables

```yaml
configMapName: jenkins-global-vars

globalVars:
  APP_ENV: "dev"
  REGISTRY_URL: "registry.example.com"
  DEPLOY_REGION: "us-east-1"
  BUILD_TIMEOUT_MIN: "30"
```

Each key under `globalVars` becomes one environment variable with the same name.

### `jenkins-globals/`: the chart that makes the ConfigMap

`templates/configmap.yaml` loops over `globalVars` and writes each key into the ConfigMap's `data`. It also:

- Quotes every value, so numbers and `true`/`false` stay strings, as Kubernetes requires.
- Fails the install if a key isn't a valid env var name (letters, digits and `_`, not starting with a digit). A bad key is caught at install time instead of breaking build pods.

### `jenkins-values.yaml`: the link to Jenkins

This block is merged into the Kubernetes plugin's default pod template:

```yaml
agent:
  yamlMergeStrategy: "merge"
  yamlTemplate: |-
    apiVersion: v1
    kind: Pod
    spec:
      containers:
        - name: jnlp
          envFrom:
            - configMapRef:
                name: jenkins-global-vars
```

`envFrom` tells Kubernetes to turn every key in the ConfigMap into an env var on the `jnlp` container. You never list the variables here, so adding one only means editing `globalVar.yaml`.

## Rules to know

**Same namespace.** A pod can only read a ConfigMap in its own namespace. Agent pods run in the Jenkins controller's namespace, so `jenkins-globals` must be installed with the same `-n` as Jenkins. If not, agent pods fail with:

```
CreateContainerConfigError
Error: configmap "jenkins-global-vars" not found
```

Fix: install `jenkins-globals` into the namespace shown by `kubectl get pods -A | grep default-`.

**Values are read at pod start.** A running build keeps the values it started with. Only builds that start after the update see the change.

**Install order.** Install `jenkins-globals` before running builds. If the ConfigMap is missing, pods wait in `CreateContainerConfigError` and start on their own once it exists.

## Updating values

### Change, add or remove a variable

1. Edit `globalVar.yaml`:

   ```yaml
   globalVars:
     APP_ENV: "qa"            # changed
     REGISTRY_URL: "registry.example.com"
     DEPLOY_REGION: "us-east-1"
     BUILD_TIMEOUT_MIN: "30"
     NEW_FLAG: "true"         # added
   ```

2. Preview what will change (optional):

   ```bash
   helm template jenkins-globals ./jenkins-globals -f globalVar.yaml
   ```

3. Apply it:

   ```bash
   helm upgrade --install jenkins-globals ./jenkins-globals -n jenkins -f globalVar.yaml
   ```

4. Confirm the ConfigMap has the new values:

   ```bash
   kubectl get configmap jenkins-global-vars -n jenkins -o yaml
   ```

5. Start a build. It picks up the new values.

That's all. Don't restart Jenkins or edit `jenkins-values.yaml`.

### Check a build got the new values

In a pipeline:

```groovy
sh 'env | sort'
```

Or from the cluster while a build is running:

```bash
kubectl get pods -n jenkins
kubectl exec -n jenkins <agent-pod> -c jnlp -- env | grep APP_ENV
```

### Roll back a bad change

Helm keeps a history of every upgrade:

```bash
helm history jenkins-globals -n jenkins
helm rollback jenkins-globals <revision> -n jenkins
```

Then update `globalVar.yaml` to match, so the next upgrade doesn't bring the bad values back.

### Avoid `kubectl edit`

You can change the ConfigMap with `kubectl edit configmap jenkins-global-vars`, and new pods will see it. But the next `helm upgrade` overwrites it with whatever is in `globalVar.yaml`. Always change the file and run the Helm command.

## What needs what

| Change | Command | Jenkins restart? |
|---|---|---|
| Add, change or remove a variable | `helm upgrade --install jenkins-globals ...` | No |
| Rename the ConfigMap (`configMapName`) | Upgrade `jenkins-globals`, **and** change the name in `jenkins-values.yaml`, then `helm upgrade jenkins ...` | Handled by the upgrade |
| Change the agent pod template, image or resources | `helm upgrade jenkins jenkins/jenkins -n jenkins -f jenkins-values.yaml` | Handled by the upgrade |

## Different values per environment

Keep one file per environment and pick it at install time:

```bash
helm upgrade --install jenkins-globals ./jenkins-globals -n jenkins -f globalVar.yaml -f globalVar-prod.yaml
```

Later files override earlier ones, so `globalVar-prod.yaml` only needs the keys that differ.

## Passwords and tokens

ConfigMaps are not encrypted, and anyone who can read the namespace can read them. Don't put passwords, tokens or keys in `globalVar.yaml`. Use Jenkins credentials, or a Kubernetes Secret added to the pod template with `secretRef` alongside the `configMapRef`.
