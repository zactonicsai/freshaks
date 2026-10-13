# Adding Global Build Variables to an Existing Jenkins Helm Install

Oct 12, 2026 · @Zachary Lewis

## Overview

You are adding one thing to an existing Jenkins Helm install: an `envFrom` entry that loads the `jenkins-global-vars` ConfigMap into every Jenkins agent pod. The hard part is not the snippet. It is finding the exact place in **your** values that produces **your** agent pods, then proving the change lands there before anything is deployed.

The snippet being added:

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

Why placement matters: Helm values never become agent pods directly. They pass through four layers, and the change has to survive each one.

1. **Helm values** (`agent.*`, `additionalAgents.*`, `controller.JCasC.*`) are rendered by the chart into a **JCasC ConfigMap**.
2. The Jenkins controller reads that ConfigMap with the Configuration as Code plugin and builds the **Kubernetes cloud**.
3. The cloud holds one or more **pod templates**, each with a name, a label and raw pod YAML.
4. When a build asks for a label, the Kubernetes plugin creates an **agent pod** from the matching template, merged with anything the Jenkinsfile adds.

&#91;embedded content: from values to agent pod · 5 layers, plus the globals ConfigMap\]

Each layer has its own check. Steps 2 to 7 walk down the left column and the right column before deploy; only layer 5 needs a real build.

The review in this guide walks those layers in order: what is deployed now, how your chart version turns values into templates, which templates your builds really use, where the snippet goes, and how to prove the rendered output carries it. Every check up to Step 7 is read-only or a dry run. Nothing is installed or changed until you choose to run the final `helm upgrade`.

| Step | Question it answers | Changes anything? |
| --- | --- | --- |
| 1. Find the install | Which namespace, release and tool own Jenkins? | No |
| 2. Pull what is deployed | What values, chart version and manifests are live? | No |
| 3. Read how agents are built | Which values turn into pod templates in this chart version? | No |
| 4. Identify the agents | Which templates, labels and containers do builds use? | No |
| 5. Decide where to place it | Which file and key gets the snippet? | Local file only |
| 6. Verify without deploying | Does the rendered output carry `envFrom` everywhere it should? | No (dry runs) |
| 7. Prepare the ConfigMap | Will `jenkins-global-vars` exist in the right namespace? | No (dry runs) |

## Prerequisites

You need read access to the Jenkins namespace and a few command-line tools. None of the steps need write access until the final deploy.

| Tool | Used for | Check it works |
| --- | --- | --- |
| `kubectl` | Reading pods, ConfigMaps, labels; server-side dry runs | `kubectl version` and `kubectl get ns` |
| `helm` 3.x | Reading releases, values, manifests; rendering templates | `helm version` |
| `yq` v4 (mikefarah) | Pulling one key or document out of YAML | `yq --version` shows `v4.x` |
| `jq` | Reading `helm ... -o json` output | `jq --version` |
| `diff` | Comparing deployed vs proposed manifests | built in |
| `helm-diff` plugin (optional) | One-command preview of an upgrade | `helm plugin list` |

Install `helm-diff` if you want it:

```bash
helm plugin install https://github.com/databus23/helm-diff
```

Permissions you need, all read-only except the optional server dry run:

```bash
kubectl auth can-i get pods -n jenkins
kubectl auth can-i get configmaps -n jenkins
kubectl auth can-i get secrets -n jenkins     # helm stores release data in secrets
kubectl auth can-i create pods -n jenkins     # only for the server dry run in Step 6; no pod is created
```

Make a working folder so every file you pull sits in one place and can be attached to a change review:

```bash
mkdir -p jenkins-review && cd jenkins-review
export NS=jenkins          # replace once you find the real namespace in Step 1
export REL=jenkins         # replace once you find the real release name in Step 1
```

The rest of this guide uses `$NS` and `$REL` so every command can be pasted as is.

## Step 1: Find the Jenkins install

Before editing anything, confirm the namespace, the release name and what tool owns the release. Editing the wrong file, or a file a GitOps tool will overwrite, is the most common way this change fails.

### 1.1 Find the namespace and controller

```bash
kubectl get pods -A | grep -i jenkins
kubectl get statefulsets -A | grep -i jenkins
```

The official chart runs the controller as a StatefulSet, so the controller pod is usually `<release>-0`, for example `jenkins-0`. The first column is the namespace. Set it:

```bash
export NS=<namespace from the output>
```

### 1.2 Find the Helm release

```bash
helm list -A | grep -i jenkins
helm list -n $NS
```

Read three columns: `NAME` (the release name), `CHART` (for example `jenkins-5.7.x`, which is the chart version) and `APP VERSION` (the Jenkins version). Set the release:

```bash
export REL=<NAME from the output>
```

### 1.3 Find out what manages the release

The same Helm chart can be deployed four ways. Each one means the values live somewhere different, so check before you edit.

```bash
# Labels and annotations on the controller say who created it
kubectl get statefulset -n $NS -o yaml | yq '.items[].metadata | {"name": .name, "labels": .labels, "annotations": .annotations}'

# Helm release records (present for plain Helm and Flux)
kubectl get secrets -n $NS -l owner=helm

# GitOps controllers
kubectl get applications.argoproj.io -A 2>/dev/null | grep -i jenkins
kubectl get helmreleases.helm.toolkit.fluxcd.io -A 2>/dev/null | grep -i jenkins
```

| What you see | Managed by | Where to make the change |
| --- | --- | --- |
| `helm list` shows it, no Argo or Flux objects | Plain Helm (CLI or CI job) | The values file(s) passed with `-f` in the install script or pipeline |
| `argocd.argoproj.io/instance` label, an Argo `Application`, and **no** entry in `helm list` | Argo CD (renders with `helm template`, no Helm release) | Git repo and path in the Application's `spec.source.helm.valueFiles` or `values` |
| A Flux `HelmRelease`, and `helm list` shows it | Flux | The `HelmRelease` `spec.values` / `valuesFrom` in Git |
| None of the above, `app.kubernetes.io/managed-by: Helm` missing | Raw manifests or another tool | Edit the JCasC config those manifests carry (Case F in Step 5) |

For Argo CD, read where the values come from:

```bash
kubectl get application <app-name> -n argocd -o yaml | yq '.spec.source, .spec.sources'
```

For Flux:

```bash
kubectl get helmrelease <name> -n <flux-ns> -o yaml | yq '.spec.chart, .spec.values, .spec.valuesFrom'
```

### 1.4 Find every values file in use

Helm merges every `-f` file in order, and later files win. You must know all of them, because the `agent` block may be split across files.

- Search the install script, CI job, Makefile or `helmfile.yaml` for `-f`, `--values` and `--set`.
- In Git, search for files that contain `agent:` and `JCasC:`:

```bash
grep -rln --include='*.yaml' -e '^agent:' -e 'JCasC:' .
```

Write down the files and their order. You will compare them with what Helm reports in Step 2.

## Step 2: Pull what is deployed

Save the live state to files. These are the baseline you will diff against, and they settle any doubt about which values are really in effect.

### 2.1 Chart version and history

```bash
helm history $REL -n $NS
helm list -n $NS -o json | jq -r '.[] | select(.name==env.REL) | .chart, .app_version'
```

Set the chart version (the part after `jenkins-` in the `CHART` column):

```bash
export CHART_VERSION=$(helm list -n $NS -o json | jq -r '.[] | select(.name==env.REL) | .chart' | sed 's/^jenkins-//')
echo $CHART_VERSION
```

Always render with this exact version. Key names under `agent` have changed between chart versions, so values that work on one version can be silently ignored on another.

### 2.2 The values you supplied

```bash
helm get values $REL -n $NS -o yaml > 01-user-values.yaml
```

This is the merged result of every `-f` file and `--set` from the last install or upgrade. It does not say which file each key came from, so compare it with the files you listed in Step 1.4. If they disagree, the cluster has values your files don't, and someone ran an upgrade from a different source. Settle that before you continue.

### 2.3 All computed values

```bash
helm get values $REL -n $NS --all -o yaml > 02-all-values.yaml
```

This adds every chart default to your values. Use it to read the **effective** setting of any key, for example:

```bash
yq '.agent | {"enabled": .enabled, "componentName": .componentName, "sideContainerName": .sideContainerName, "yamlMergeStrategy": .yamlMergeStrategy, "yamlTemplate": .yamlTemplate, "podName": .podName, "defaultsProviderTemplate": .defaultsProviderTemplate}' 02-all-values.yaml
yq '.controller.JCasC.defaultConfig' 02-all-values.yaml
yq '.additionalAgents | keys' 02-all-values.yaml
yq '.agent.podTemplates | keys' 02-all-values.yaml
```

A key that prints `null` does not exist in your chart version. Do not add it.

### 2.4 The deployed manifests

```bash
helm get manifest $REL -n $NS > 03-deployed-manifest.yaml
yq -N '.kind + "/" + .metadata.name' 03-deployed-manifest.yaml | sort
```

The second command lists every object the release created. Look for one or more ConfigMaps with `jcasc` or `config` in the name. The one that holds the cloud is usually `<release>-jenkins-jcasc-config`.

### 2.5 The chart's own defaults and source

```bash
helm repo add jenkins https://charts.jenkins.io 2>/dev/null; helm repo update jenkins
helm show values jenkins/jenkins --version $CHART_VERSION > 04-chart-defaults.yaml
helm pull jenkins/jenkins --version $CHART_VERSION --untar --untardir chart-src
```

`04-chart-defaults.yaml` holds the comments that document each `agent` key. `chart-src/jenkins/templates/` holds the templates that turn those keys into JCasC. You will read both in Step 3.

At the end of Step 2 the folder should hold:

| File | What it is |
| --- | --- |
| `01-user-values.yaml` | Your merged values, as deployed |
| `02-all-values.yaml` | Your values plus every chart default |
| `03-deployed-manifest.yaml` | Every Kubernetes object the release created |
| `04-chart-defaults.yaml` | The chart's documented defaults for this version |
| `chart-src/jenkins/` | The chart source for this version |

## Step 3: Read how the chart builds agent pods

The chart turns `agent.*` values into a Kubernetes cloud inside a JCasC ConfigMap. Reading that rendered ConfigMap, not the values file, is how you see exactly what Jenkins receives.

### 3.1 The values that shape agent pods

Check each of these in `02-all-values.yaml` and confirm its comment in `04-chart-defaults.yaml`, since names can differ by chart version.

| Value | Default | What it controls | Why it matters here |
| --- | --- | --- | --- |
| `agent.enabled` | `true` | Whether the chart writes a Kubernetes cloud at all | `false` means no agent settings from Helm reach Jenkins |
| `controller.JCasC.defaultConfig` | `true` | Whether the chart writes its default JCasC, which holds the cloud | `false` means the cloud comes from somewhere else (Case E) |
| `agent.podName` | `default` | Name of the default pod template; agent pods are named `<podName>-<random>` | Your `default-3gnzq` pods come from this template |
| `agent.componentName` | `jenkins-agent` | Builds the template label `<release>-<componentName>` | Tells you which label builds ask for |
| `agent.sideContainerName` | `jnlp` | Name of the agent container in the pod | The snippet's `- name:` must match it exactly |
| `agent.yamlTemplate` | empty | Raw pod YAML added to the default template | Where the snippet goes in most installs |
| `agent.yamlMergeStrategy` | `override` | How this template's YAML combines with a parent template's YAML | Use `merge` so inherited YAML is kept |
| `agent.envVars` | empty | Static env vars on the agent container | Fixed values only; cannot read a ConfigMap |
| `agent.podTemplates` | empty | Extra templates written as raw JCasC | Each one needs its own change (Case D) |
| `additionalAgents` | empty | Extra templates that start from `agent.*` | Inherit `yamlTemplate` unless they set their own (Case C) |
| `agent.defaultsProviderTemplate` | empty | A template whose settings apply to all templates in the cloud | Present in newer chart versions; an option for broad coverage |
| `controller.JCasC.configScripts` | empty | Your own JCasC files | May define or override clouds (Case E) |

### 3.2 Pull the JCasC ConfigMap out of the deployed manifest

List the ConfigMaps the release created, then find the one that holds `clouds:`:

```bash
yq 'select(.kind=="ConfigMap") | .metadata.name' 03-deployed-manifest.yaml
yq 'select(.kind=="ConfigMap") | select(.data[] | test("clouds:")) | .metadata.name' 03-deployed-manifest.yaml
```

Set it and list its keys:

```bash
export CM=$REL-jenkins-jcasc-config      # use the name the command printed
yq 'select(.kind=="ConfigMap" and .metadata.name==strenv(CM)) | .data | keys' 03-deployed-manifest.yaml
```

The key is usually `jcasc-default-config.yaml`. Extract it to its own file:

```bash
export KEY=jcasc-default-config.yaml
yq 'select(.kind=="ConfigMap" and .metadata.name==strenv(CM)) | .data[strenv(KEY)]' 03-deployed-manifest.yaml > 05-deployed-jcasc.yaml
```

### 3.3 Read the cloud and its pod templates

```bash
# Cloud-level settings: name, namespace, defaults template
yq '.jenkins.clouds[].kubernetes | {"name": .name, "namespace": .namespace, "defaultsProviderTemplate": .defaultsProviderTemplate}' 05-deployed-jcasc.yaml

# One line per pod template
yq '.jenkins.clouds[].kubernetes.templates[] | {"name": .name, "label": .label, "inheritFrom": .inheritFrom, "yamlMergeStrategy": .yamlMergeStrategy, "containers": [.containers[].name]}' 05-deployed-jcasc.yaml

# The raw pod YAML carried by the default template
yq '.jenkins.clouds[].kubernetes.templates[] | select(.name=="default") | .yaml' 05-deployed-jcasc.yaml
```

How to read the output:

- **`name`** is the template name and the prefix of agent pod names.
- **`label`** is what a Jenkinsfile asks for with `agent { label '...' }`.
- **`containers`** are defined by structured fields (image, resources). The template's **`yaml`** is combined with them, and a container in `yaml` with the same name is merged into the structured one. That is why the snippet only names `jnlp` and adds `envFrom`, without an image.
- **`inheritFrom`** names parent templates. With **`yamlMergeStrategy: merge`**, a child keeps the parent's YAML and adds its own. With **`override`** (the default), the child's YAML replaces the parent's, and an inherited `envFrom` is lost.
- **`namespace`** on the cloud is where agent pods run. The `jenkins-global-vars` ConfigMap must be in this namespace. If it is empty, pods run in the controller's namespace.

### 3.4 Confirm Jenkins loaded the same config

The manifest is what Helm sent. Confirm the controller is running it:

```bash
kubectl get configmap $CM -n $NS -o yaml | yq '.data[strenv(KEY)]' > 06-live-jcasc.yaml
diff 05-deployed-jcasc.yaml 06-live-jcasc.yaml && echo "live ConfigMap matches the release"

kubectl exec -n $NS $REL-0 -c jenkins -- ls /var/jenkins_home/casc_configs
```

In the Jenkins UI, **Manage Jenkins → Configuration as Code → View Configuration** shows the config Jenkins actually applied. If it differs from the ConfigMap, someone changed the cloud by hand in the UI or JCasC reload is failing. Find out which before relying on Helm values.

### 3.5 See how this chart version writes the template (optional)

```bash
grep -rn -e yamlTemplate -e yamlMergeStrategy -e sideContainerName -e additionalAgents chart-src/jenkins/templates/ | head -40
```

This shows the exact template code that copies your values into JCasC. It is the final word if the docs and your results disagree.

## Step 4: Identify the Jenkins agents

The goal of this step is a short list of every pod template your builds really use, the container each build step runs in, and the namespace the pods land in. The snippet only helps the templates and containers it reaches.

### 4.1 List the templates Jenkins knows about

From the files you already pulled:

```bash
yq '.jenkins.clouds[].kubernetes.templates[] | .name + "  label=" + .label' 05-deployed-jcasc.yaml
```

In the Jenkins UI, **Manage Jenkins → Clouds → kubernetes → Pod Templates** shows the same list. Open each template and read **Labels**, **Containers**, **Inherit from** and **Raw YAML for the Pod**. A template that is in the UI but not in `05-deployed-jcasc.yaml` was added by hand or by another JCasC file, and Helm values will not reach it.

### 4.2 Find which templates builds ask for

Builds pick a template by label, or define their own pod in the Jenkinsfile. Search your pipeline repositories and shared libraries:

```bash
grep -rn -E "agent\s*\{|label\s+'|label\s+\"|node\s*\(|podTemplate\s*\(|kubernetes\s*\{|inheritFrom|yamlFile" --include=Jenkinsfile* --include=*.groovy .
```

Sort what you find into three groups:

| Jenkinsfile pattern | Pod comes from | Gets the change from Helm values? |
| --- | --- | --- |
| `agent any`, `agent { label 'jenkins-jenkins-agent' }`, `node { }` | A cloud template, matched by label | Yes, if that template carries the snippet |
| `agent { kubernetes { inheritFrom 'default' ... } }` or `podTemplate(inheritFrom: 'default')` | Pipeline pod built on top of a cloud template | Yes, if the pipeline merges YAML (Case G) |
| `agent { kubernetes { yaml '''...''' } }` with no `inheritFrom` | Pipeline pod only | Not reliably. Treat as Case G |

Agents that are not Kubernetes pods (static VMs, SSH agents, the built-in node) never get the change. List them separately if builds run there.

### 4.3 Find live agent pods

Agent pods only exist while a build runs. Watch for them while any normal build runs. This does not change anything:

```bash
kubectl get pods -n $NS -w
```

The Kubernetes plugin labels every agent pod with the label it was created for, which separates agents from the controller:

```bash
kubectl get pods -A -L jenkins/label --show-labels | grep -v '^kube-system'
kubectl get pods -A -l jenkins/label            # agent pods only, in every namespace
kubectl get pods -n $NS -l app.kubernetes.io/component=jenkins-controller   # the controller
```

The chart's default template also adds the label `jenkins/<release>-<componentName>=true`, so for a release named `jenkins`:

```bash
kubectl get pods -A -l jenkins/jenkins-jenkins-agent=true
```

The namespace column of agent pods is the namespace that needs the `jenkins-global-vars` ConfigMap. If it differs from the controller's namespace, the cloud has a `namespace` set (Step 3.3).

### 4.4 Capture one agent pod as the baseline

While a build runs, save its pod spec. This is the "before" picture for the review:

```bash
export POD=<agent pod name, for example default-3gnzq>
export AGENT_NS=<its namespace>
kubectl get pod $POD -n $AGENT_NS -o yaml > 07-agent-pod-before.yaml

# Containers, and whether each one already has env or envFrom
yq '.spec.containers[] | {"name": .name, "image": .image, "env": [.env[].name], "envFrom": .envFrom}' 07-agent-pod-before.yaml

# Labels and annotations; the annotations usually include the build URL
yq '.metadata.labels, .metadata.annotations' 07-agent-pod-before.yaml
```

No cluster access while a build runs? The Kubernetes plugin prints the full pod YAML at the top of the build's **Console Output** by default. Copy it from there.

### 4.5 Note which container each build step runs in

`envFrom` is set per container. Steps run in `jnlp` unless the Jenkinsfile wraps them in `container('name') { ... }`.

```bash
grep -rn "container(" --include=Jenkinsfile* --include=*.groovy .
```

Jenkins usually passes the agent's environment to steps in other containers too, but this is not guaranteed for every plugin version or step type. If builds run steps in containers other than `jnlp`, plan to add `envFrom` to those containers as well, and confirm in Step 6.

### 4.6 Write down the inventory

Fill in one row per template before moving on. It tells you exactly where Step 5 must place the snippet.

| Template name | Label | Defined in | Containers that run steps | Agent namespace | Used by |
| --- | --- | --- | --- | --- | --- |
| `default` | `jenkins-jenkins-agent` | `agent.*` | `jnlp` | `jenkins` | `agent any` jobs |
|  |  |  |  |  |  |

## Step 5: Decide where to place it

Use your Step 4 inventory to pick the case that matches each template. Most installs are Case A or B. Many need more than one case, for example B for the default template plus G for a few Jenkinsfiles.

| Case | What you found | Where the snippet goes |
| --- | --- | --- |
| A | Default template only, `agent.yamlTemplate` empty | Add `yamlMergeStrategy` and `yamlTemplate` under the existing `agent:` key |
| B | `agent.yamlTemplate` already set | Merge `envFrom` into the existing YAML string |
| C | Entries under `additionalAgents` | Nothing if they inherit `yamlTemplate`; otherwise inside each entry |
| D | Entries under `agent.podTemplates` | Inside each template's `yaml`, or make it inherit from `default` |
| E | Cloud defined in `controller.JCasC.configScripts`, or `defaultConfig: false` | Inside the template `yaml` in that JCasC |
| F | Jenkins not deployed by Helm | The JCasC source those manifests load |
| G | Jenkinsfile defines its own pod | In the Jenkinsfile, with `inheritFrom` or its own `envFrom` |

Rules that apply to every case:

- **One `agent:` key per file.** If the file already has `agent:`, add the new keys under it. A second `agent:` block either fails to parse or silently replaces the first.
- **The last file wins for strings.** Helm merges maps, but replaces strings and lists whole. If `agent.yamlTemplate` is set in `values.yaml` and again in `values-prod.yaml`, only the later one counts. Edit the one Helm actually uses, as `01-user-values.yaml` shows.
- **Match the container name.** `- name: jnlp` must equal `agent.sideContainerName` (Step 3.1). A wrong name adds a second container with no image, and every agent pod fails.
- **No image needed.** The YAML is merged into the container the template already defines, so name plus `envFrom` is enough.
- **Indentation inside `|-`.** The pod YAML is a string. Keep its own two-space indentation consistent, and keep the whole block indented under `yamlTemplate:`.

### Case A: no existing `yamlTemplate`

Before:

```yaml
agent:
  enabled: true
  resources:
    limits:
      cpu: "1"
      memory: "1Gi"
```

After:

```yaml
agent:
  enabled: true
  resources:
    limits:
      cpu: "1"
      memory: "1Gi"
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

### Case B: `yamlTemplate` already set

Keep everything that is there and add one list entry. Three variants:

1. **`jnlp` already listed, no `envFrom`**: add `envFrom` to it.
2. **`jnlp` already has `envFrom`**: add one more `- configMapRef:` item to that list.
3. **Only other containers or no `containers` list**: add a `- name: jnlp` item with `envFrom`.

Before (variant 1):

```yaml
agent:
  yamlTemplate: |-
    apiVersion: v1
    kind: Pod
    spec:
      nodeSelector:
        pool: build
      containers:
        - name: jnlp
          securityContext:
            runAsUser: 1000
```

After:

```yaml
agent:
  yamlMergeStrategy: "merge"
  yamlTemplate: |-
    apiVersion: v1
    kind: Pod
    spec:
      nodeSelector:
        pool: build
      containers:
        - name: jnlp
          securityContext:
            runAsUser: 1000
          envFrom:
            - configMapRef:
                name: jenkins-global-vars
```

If a sidecar container also runs build steps, give it the same `envFrom` in the same YAML.

### Case C: `additionalAgents`

Each entry starts from the `agent.*` values, so it picks up `yamlTemplate` and `yamlMergeStrategy` unless it sets its own. Check:

```bash
yq '.additionalAgents | to_entries | .[] | {"agent": .key, "ownYamlTemplate": (.value.yamlTemplate != null), "sideContainerName": .value.sideContainerName}' 01-user-values.yaml
```

For each entry with `ownYamlTemplate: true`, add `envFrom` inside that entry's `yamlTemplate`, using that entry's container name:

```yaml
additionalAgents:
  maven:
    podName: maven
    customJenkinsLabels: [maven]
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

### Case D: `agent.podTemplates`

These are raw JCasC strings written straight into the cloud, so `agent.yamlTemplate` does not reach them. Pick one of two fixes per template:

1. Add `inheritFrom: "default"` and `yamlMergeStrategy: "merge"` so it inherits the default template's YAML.
2. Or add the `envFrom` to its own `yaml:`.

```yaml
agent:
  podTemplates:
    python: |
      - name: python
        label: jenkins-python
        inheritFrom: "default"
        yamlMergeStrategy: "merge"
        containers:
          - name: python
            image: python:3.12
            command: "/bin/sh -c"
            args: "cat"
            ttyEnabled: true
        yaml: |-
          spec:
            containers:
              - name: python
                envFrom:
                  - configMapRef:
                      name: jenkins-global-vars
```

Here `inheritFrom` covers `jnlp`, and the `yaml` covers the `python` container that runs the steps.

### Case E: cloud in your own JCasC

If `05-deployed-jcasc.yaml` has no `clouds:` but the UI shows a cloud, or `controller.JCasC.defaultConfig` is `false`, find the cloud in your own scripts:

```bash
yq '.controller.JCasC.configScripts | to_entries | .[] | select(.value | test("clouds:")) | .key' 01-user-values.yaml
```

Edit the template's `yaml` and `yamlMergeStrategy` inside that script:

```yaml
controller:
  JCasC:
    configScripts:
      k8s-cloud: |
        jenkins:
          clouds:
            - kubernetes:
                name: kubernetes
                templates:
                  - name: default
                    label: jenkins-agent
                    yamlMergeStrategy: "merge"
                    yaml: |-
                      spec:
                        containers:
                          - name: jnlp
                            envFrom:
                              - configMapRef:
                                  name: jenkins-global-vars
```

Two cloud definitions with the same name, one from the chart and one from your scripts, conflict. Keep only one.

### Case F: not deployed by Helm

Find the ConfigMap or file that holds the JCasC (`kubectl get cm -n $NS | grep -i casc`), and edit its template `yaml` as in Case E, in the repo that owns it. Editing in **Manage Jenkins → Clouds** works only until the next JCasC reload overwrites it, so don't use the UI as the fix.

### Case G: pods defined in a Jenkinsfile

Make the pipeline pod build on the default template and merge YAML, so it inherits `envFrom` for `jnlp`. Add `envFrom` to any container where steps run:

```groovy
pipeline {
  agent {
    kubernetes {
      inheritFrom 'default'
      yamlMergeStrategy merge()
      yaml '''
spec:
  containers:
    - name: maven
      image: maven:3.9-eclipse-temurin-17
      command: ["sleep"]
      args: ["infinity"]
      envFrom:
        - configMapRef:
            name: jenkins-global-vars
'''
    }
  }
  stages {
    stage('Build') {
      steps {
        container('maven') { sh 'echo $APP_ENV' }
      }
    }
  }
}
```

For scripted pipelines, the same options are `podTemplate(inheritFrom: 'default', yamlMergeStrategy: merge(), yaml: ...)`.

## Step 6: Verify without deploying

Render the chart twice, once with today's values and once with your change, then prove three things: every template from Step 4 carries `envFrom`, nothing else changed, and the cluster would accept the resulting pod. All commands here are local renders or dry runs.

### 6.1 Check the edited file

Work on a copy of the real values file(s), in the same order Helm uses them. This guide calls the edited file `proposed-values.yaml`.

```bash
# The file parses as YAML
yq '.' proposed-values.yaml > /dev/null && echo "valid YAML"

# Exactly one top-level agent: key
grep -c '^agent:' proposed-values.yaml          # must print 1

# The embedded pod YAML parses, and the container name matches sideContainerName
yq '.agent.yamlTemplate' proposed-values.yaml | yq '.spec.containers[] | {"name": .name, "envFrom": .envFrom}'
yq '.agent.sideContainerName // "jnlp"' proposed-values.yaml
```

### 6.2 Render current and proposed the same way

Diffing a render against `helm get manifest` shows noise, such as checksums and generated passwords. Render both sides with the same command, so the diff shows only your change.

```bash
helm template $REL jenkins/jenkins --version $CHART_VERSION -n $NS \
  -f 01-user-values.yaml > 08-rendered-current.yaml

helm template $REL jenkins/jenkins --version $CHART_VERSION -n $NS \
  -f 01-user-values.yaml -f proposed-values.yaml > 09-rendered-proposed.yaml
```

If the real install passes several files or `--set` flags, pass the same ones in the same order and add your edited file in its proper place. For Argo CD, use the Application's value files; for Flux, the `HelmRelease` values.

### 6.3 Check every pod template in the proposed JCasC

```bash
yq 'select(.kind=="ConfigMap" and .metadata.name==strenv(CM)) | .data[strenv(KEY)]' 09-rendered-proposed.yaml > 10-proposed-jcasc.yaml

for t in $(yq '.jenkins.clouds[].kubernetes.templates[].name' 10-proposed-jcasc.yaml); do
  echo "=== template: $t"
  T=$t yq '.jenkins.clouds[].kubernetes.templates[] | select(.name==strenv(T)) | {"label": .label, "inheritFrom": .inheritFrom, "yamlMergeStrategy": .yamlMergeStrategy}' 10-proposed-jcasc.yaml
  T=$t yq '.jenkins.clouds[].kubernetes.templates[] | select(.name==strenv(T)) | .yaml' 10-proposed-jcasc.yaml \
    | yq '.spec.containers[] | {"container": .name, "envFrom": .envFrom}'
done
```

What a passing default template looks like:

```yaml
=== template: default
label: jenkins-jenkins-agent
inheritFrom: null
yamlMergeStrategy: merge
container: jnlp
envFrom:
  - configMapRef:
      name: jenkins-global-vars
```

For every template in your Step 4 inventory, one of these must be true:

- Its own `yaml` has `envFrom` with `jenkins-global-vars` on each container that runs steps.
- Or it has `inheritFrom` pointing at a template that does, **and** `yamlMergeStrategy: merge`.

A template with `inheritFrom` but `override` (or no strategy) fails the check. Its own YAML replaces the parent's, and the inherited `envFrom` is lost.

### 6.4 Diff to prove nothing else changed

```bash
diff -u 08-rendered-current.yaml 09-rendered-proposed.yaml
diff -u 05-deployed-jcasc.yaml 10-proposed-jcasc.yaml
```

Expected: the only changes are the added `yamlMergeStrategy` and `envFrom` lines inside the JCasC ConfigMap. Review anything else:

- A change to the controller **StatefulSet** (often a checksum annotation) means the controller pod restarts on upgrade. Plan the deploy for a quiet time.
- Changes you did not make mean `01-user-values.yaml` and your files differ (Step 2.2). Resolve that first.
- No change at all means the snippet sits under a key this chart version ignores. Recheck Step 3.1.

### 6.5 Preview against the live release (optional)

With the `helm-diff` plugin, compare the live release with the proposed values in one command. It changes nothing:

```bash
helm diff upgrade $REL jenkins/jenkins --version $CHART_VERSION -n $NS \
  -f 01-user-values.yaml -f proposed-values.yaml --context 5
```

Or have the API server validate the full upgrade without saving it:

```bash
helm upgrade $REL jenkins/jenkins --version $CHART_VERSION -n $NS \
  -f 01-user-values.yaml -f proposed-values.yaml --dry-run=server > 12-upgrade-dryrun.txt
```

`--dry-run=server` needs Helm 3.13 or later; older versions use `--dry-run`. The output can contain secrets, so don't paste it into tickets or chat.

### 6.6 Validate the agent pod the cluster would get

Turn the template's pod YAML into a full test pod and ask the API server to validate it. A server dry run runs schema checks and admission policies (Pod Security, Kyverno, Gatekeeper) without creating anything.

```bash
yq '.jenkins.clouds[].kubernetes.templates[] | select(.name=="default") | .yaml' 10-proposed-jcasc.yaml > 11-default-template-pod.yaml

yq -i '.apiVersion = "v1" | .kind = "Pod" | .metadata.name = "envfrom-dryrun-test" |
  (.spec.containers[] | select(.name == "jnlp")).image = "jenkins/inbound-agent:latest"' 11-default-template-pod.yaml

kubectl apply --dry-run=server -n $AGENT_NS -f 11-default-template-pod.yaml
```

Expected: `pod/envfrom-dryrun-test created (server dry run)`. Nothing is created. A schema error here (for example `envFrom` at the wrong indent level) is the same error the plugin would hit at build time.

A server dry run does **not** check that the ConfigMap exists. That is the next step. Repeat the test for each template, and for pod YAML copied from Case G Jenkinsfiles.

### 6.7 What Step 6 cannot prove

Two things only happen at build time: the Kubernetes plugin's merge of inherited templates and Jenkinsfile YAML, and the env a step sees inside a non-`jnlp` container. Both are confirmed by one test build after the deploy (After deploy, below).

## Step 7: Prepare and verify the ConfigMap

The snippet only references `jenkins-global-vars`. If that ConfigMap is missing from the agent namespace when a build starts, the pod stops in `CreateContainerConfigError`. Check it without installing anything.

### 7.1 Render the globals chart

```bash
helm template jenkins-globals ./jenkins-globals -n $AGENT_NS -f globalVar.yaml > 13-globals.yaml
yq '.metadata.name, .data' 13-globals.yaml
```

The render fails with a clear message if any key is not a valid environment variable name.

### 7.2 Check the names match

```bash
yq '.configMapName' globalVar.yaml                                   # must be jenkins-global-vars
yq '.agent.yamlTemplate' proposed-values.yaml | grep -A1 configMapRef  # must name the same ConfigMap
```

### 7.3 Check the target namespace

The ConfigMap must live where agent pods run (`$AGENT_NS` from Step 4.3), which is not always the controller's namespace.

```bash
kubectl get ns $AGENT_NS
kubectl get configmap jenkins-global-vars -n $AGENT_NS     # NotFound is fine before the first install
helm list -n $AGENT_NS | grep jenkins-globals              # already installed?
```

### 7.4 Validate it on the server

```bash
kubectl apply --dry-run=server -n $AGENT_NS -f 13-globals.yaml
helm upgrade --install jenkins-globals ./jenkins-globals -n $AGENT_NS -f globalVar.yaml --dry-run=server
```

### 7.5 Check for name clashes

The Kubernetes plugin sets its own variables on the agent container with `env`, and `env` always wins over `envFrom`. A global variable with the same name is silently ignored. Others, such as `PATH` or `HOME`, would replace a value the image needs.

```bash
yq '.globalVars | keys | .[]' globalVar.yaml | grep -E '^(JENKINS_|PATH$|HOME$|HOSTNAME$|BUILD_|JOB_|WORKSPACE$|NODE_|EXECUTOR_)' \
  && echo "rename these keys" || echo "no clashes"
```

Also compare against the `env` names recorded in `07-agent-pod-before.yaml` (Step 4.4).

### 7.6 Install order for the real deploy

When the review is approved, install the ConfigMap first and Jenkins second. The other order lets a build start before the ConfigMap exists.

1. `helm upgrade --install jenkins-globals ./jenkins-globals -n $AGENT_NS -f globalVar.yaml`
2. `helm upgrade $REL jenkins/jenkins --version $CHART_VERSION -n $NS -f <your values files, in order>`

For Argo CD or Flux, merge the two changes in that order, or give the ConfigMap an earlier sync wave.

## Review checklist

Tick every item before approving the deploy. Attach the numbered files from the `jenkins-review` folder to the change record as evidence.

- [ ] Namespace, release name and owning tool (Helm, Argo CD, Flux) confirmed (Step 1)
- [ ] Every values file and its order identified, and it matches `01-user-values.yaml` (Steps 1.4, 2.2)
- [ ] Chart version recorded and used for every render (Step 2.1)
- [ ] `agent.enabled` is `true`, and the cloud comes from the chart or from a known JCasC file (Step 3.1)
- [ ] Live JCasC matches the release, with no hand edits in the UI (Step 3.4)
- [ ] Inventory lists every template, label, step container and agent namespace in use (Step 4.6)
- [ ] The case for each template chosen, and the snippet placed accordingly (Step 5)
- [ ] One `agent:` key per file; container name matches `sideContainerName` (Step 6.1)
- [ ] Every template in use shows `envFrom` directly, or through `inheritFrom` with `merge` (Step 6.3)
- [ ] Diff shows only the intended JCasC change; any StatefulSet change understood (Step 6.4)
- [ ] Test pod accepted by `kubectl apply --dry-run=server` for each template (Step 6.6)
- [ ] ConfigMap renders, name matches, target namespace confirmed, no key clashes (Step 7)
- [ ] Deploy order agreed: ConfigMap first, then Jenkins (Step 7.6)
- [ ] Rollback noted: `helm rollback $REL <revision> -n $NS` and the current revision from `helm history`

## After deploy: confirm on a real build

One test build confirms the parts no dry run can: the plugin's template merge and the env each step really sees.

1. Confirm Jenkins reloaded the new cloud config:

   ```bash
   kubectl get configmap $CM -n $NS -o yaml | yq '.data[strenv(KEY)]' | diff - 10-proposed-jcasc.yaml && echo "ConfigMap updated"
   kubectl logs -n $NS $REL-0 -c config-reload --tail=20
   ```

   In the UI, **Manage Jenkins → Clouds → kubernetes → Pod Templates → default → Raw YAML for the Pod** should show the `envFrom` block.
2. Run a test pipeline on each template label in your inventory:

   ```groovy
   pipeline {
     agent { label 'jenkins-jenkins-agent' }
     stages {
       stage('Check globals') {
         steps {
           sh 'env | sort | grep -E "^(APP_ENV|REGISTRY_URL|DEPLOY_REGION|BUILD_TIMEOUT_MIN)="'
         }
       }
     }
   }
   ```

   For templates with extra containers, repeat the `sh` step inside `container('<name>') { }`.
3. While it runs, compare the new pod with the baseline:

   ```bash
   kubectl get pods -n $AGENT_NS -l jenkins/label -w
   kubectl get pod <new-agent-pod> -n $AGENT_NS -o yaml > 14-agent-pod-after.yaml
   diff <(yq '.spec.containers[] | {"name": .name, "envFrom": .envFrom}' 07-agent-pod-before.yaml) \
        <(yq '.spec.containers[] | {"name": .name, "envFrom": .envFrom}' 14-agent-pod-after.yaml)
   kubectl exec -n $AGENT_NS <new-agent-pod> -c jnlp -- env | grep APP_ENV
   ```
4. Check the build's **Console Output**. The pod YAML printed at the top should include the `envFrom` block.

If an agent pod sticks in `CreateContainerConfigError`, run `kubectl describe pod <pod> -n $AGENT_NS`. The ConfigMap is missing from that namespace; see Troubleshooting.

## Troubleshooting and gotchas

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Agent pod `CreateContainerConfigError`, `configmap "jenkins-global-vars" not found` | ConfigMap missing from the agent namespace, or installed in another one | `kubectl get pods -A -l jenkins/label` for the namespace, then install `jenkins-globals` there |
| `namespaces "jenkins" not found` on install | Namespace not created | `kubectl create namespace jenkins`, or add `--create-namespace` |
| Render shows no change in the JCasC | Snippet under a key this chart version ignores, or overridden by a later `-f` file | Check the key in `04-chart-defaults.yaml`; check which file sets `agent.yamlTemplate` last |
| Agent pod fails with a container that has no image | `- name:` in the YAML does not match the real container name | Use the value of `agent.sideContainerName` |
| Default template works, other labels lack the variables | Those templates use `override`, or are `agent.podTemplates` / Jenkinsfile pods | Apply Case C, D or G; check with Step 6.3 |
| Variable missing only inside `container('x')` steps | `envFrom` set on `jnlp` only | Add `envFrom` to container `x` too |
| Variable present but with a different value | Same name also set with `env`, which wins over `envFrom` | Rename the global variable (Step 7.5) |
| UI shows `envFrom`, then it disappears | JCasC reload replaced a hand edit | Make the change in Helm values or JCasC, not the UI |
| ConfigMap updated but builds see old values | Build started before the update | Start a new build; env is read at pod start |
| Helm values changed, Jenkins cloud unchanged | Config reload sidecar not running, or JCasC errors | `kubectl logs -n $NS $REL-0 -c config-reload`; check the controller log for JCasC errors |
| `helm list` is empty but Jenkins is running | Deployed by Argo CD or plain manifests | Make the change in Git (Step 1.3) |
| `yq` errors on commands in this guide | Python `yq` (v2/v3) installed instead of mikefarah `yq` v4 | Install `yq` v4 and check `yq --version` |

Gotchas worth repeating:

- **Strings replace, maps merge.** Two values files that both set `agent.yamlTemplate` do not combine. The later one wins whole.
- **ConfigMaps are not secret.** Don't put passwords or tokens in `globalVar.yaml`. Use Jenkins credentials or a Kubernetes Secret with `secretRef`.
- **Same namespace, always.** A pod can only read a ConfigMap in its own namespace.

## Command reference

| Purpose | Command | Changes anything? |
| --- | --- | --- |
| List releases in all namespaces | `helm list -A` | No |
| Release history and revisions | `helm history $REL -n $NS` | No |
| Values you supplied | `helm get values $REL -n $NS -o yaml` | No |
| Values plus chart defaults | `helm get values $REL -n $NS --all -o yaml` | No |
| Deployed manifests | `helm get manifest $REL -n $NS` | No |
| Chart defaults for a version | `helm show values jenkins/jenkins --version $CHART_VERSION` | No |
| Download chart source | `helm pull jenkins/jenkins --version $CHART_VERSION --untar` | Local files only |
| Render locally | `helm template $REL jenkins/jenkins --version $CHART_VERSION -n $NS -f ...` | No |
| Preview an upgrade | `helm diff upgrade $REL jenkins/jenkins --version $CHART_VERSION -n $NS -f ...` | No |
| Validate an upgrade on the server | `helm upgrade ... --dry-run=server` | No |
| Agent pods, all namespaces | `kubectl get pods -A -l jenkins/label` | No |
| Controller pod | `kubectl get pods -n $NS -l app.kubernetes.io/component=jenkins-controller` | No |
| Save a pod spec | `kubectl get pod <pod> -n <ns> -o yaml` | No |
| Containers and envFrom of a pod | `kubectl get pod <pod> -n <ns> -o yaml \| yq '.spec.containers[] \| {"name": .name, "envFrom": .envFrom}'` | No |
| Why a pod won't start | `kubectl describe pod <pod> -n <ns>` | No |
| Recent events | `kubectl get events -n <ns> --sort-by=.lastTimestamp` | No |
| Live JCasC ConfigMap | `kubectl get configmap $CM -n $NS -o yaml` | No |
| JCasC files in the controller | `kubectl exec -n $NS $REL-0 -c jenkins -- ls /var/jenkins_home/casc_configs` | No |
| Validate a manifest on the server | `kubectl apply --dry-run=server -f <file>` | No |
| Show what an apply would change | `kubectl diff -f <file>` | No |
| Install or update the globals | `helm upgrade --install jenkins-globals ./jenkins-globals -n <agent-ns> -f globalVar.yaml` | **Yes** |
| Upgrade Jenkins | `helm upgrade $REL jenkins/jenkins --version $CHART_VERSION -n $NS -f ...` | **Yes** |
| Roll back Jenkins | `helm rollback $REL <revision> -n $NS` | **Yes** |
