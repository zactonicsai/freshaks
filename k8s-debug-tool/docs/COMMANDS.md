# kubectl and Helm command tutorial

This file explains the commands used underneath `k8s-doctor` and why each one is
useful.

## kubectl basics

### Current context

```bash
kubectl config current-context
```

Think of a context as a saved address book entry that says **which cluster** and
**which identity** kubectl should use.

### Cluster information

```bash
kubectl cluster-info
```

Why: confirms kubectl can reach the API server and shows important cluster
endpoints.

### Version

```bash
kubectl version -o json
```

Why: helps identify client/server version mismatch problems.

### Nodes

```bash
kubectl get nodes -o json
kubectl describe node NODE_NAME
```

Why: nodes are the computers that run Pods. A NotReady node, disk pressure, or
memory pressure can stop applications from running correctly.

### Workloads

```bash
kubectl get deployments -o json
kubectl get statefulsets -o json
kubectl get daemonsets -o json
```

Why: these objects manage Pods. Comparing desired replicas to ready replicas is
a quick health signal.

### Pods

```bash
kubectl get pods -o json
kubectl describe pod POD_NAME
```

`get` is good for structured status. `describe` gives a human-focused view with
conditions and events.

### Logs

```bash
kubectl logs POD_NAME --tail=200
kubectl logs POD_NAME -c CONTAINER --tail=200
kubectl logs POD_NAME --previous --tail=200
kubectl logs POD_NAME --since 20m
```

Why: logs explain what the application itself is doing. `--previous` is
especially useful after a container restarted because the current log may no
longer contain the crash.

### Events

```bash
kubectl get events --sort-by=.lastTimestamp
kubectl get events --all-namespaces --sort-by=.lastTimestamp
```

Events can explain:

- FailedScheduling
- FailedMount
- ImagePullBackOff
- CrashLoopBackOff
- readiness/liveness probe failures
- networking/controller problems

### Services and endpoints

```bash
kubectl get services -o json
kubectl get endpoints -o json
```

Simple analogy: a Service is the phone number; endpoints are the actual phones
that can answer. If a Service has no ready endpoints, traffic has nowhere to go.

Common check:

```bash
kubectl get service my-service -o yaml
kubectl get pods --show-labels
```

Compare the Service `selector` with Pod labels.

### NetworkPolicy

```bash
kubectl get networkpolicies -o json
```

NetworkPolicies are like firewall rules for Pod traffic. Both ingress and egress
rules can matter.

### DNS

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

Why: most applications reach Services by DNS name. If cluster DNS is unhealthy,
many unrelated applications can appear broken.

### Storage

```bash
kubectl get pvc -o json
kubectl describe pvc CLAIM_NAME
```

A PVC stuck Pending often means a StorageClass, provisioner, zone, access mode,
or capacity problem.

### Metrics

```bash
kubectl top nodes
kubectl top pods
```

Why: useful for high CPU/memory clues. These commands need the Kubernetes
Metrics API, commonly provided by Metrics Server.

### Authorization

```bash
kubectl auth can-i --list
```

Why: tells you what the current identity is allowed to do. A problem that looks
like a missing resource may actually be RBAC access denial.

## kubectl changes

### Apply a file

Preview with server validation:

```bash
kubectl apply -f deployment.yaml --dry-run=server -o yaml
```

Execute:

```bash
kubectl apply -f deployment.yaml
```

Declarative YAML is usually better for production because it can be stored in
Git and reviewed.

### Patch

Preview:

```bash
kubectl patch service my-service --type=strategic \
  -p '{"spec":{"type":"ClusterIP"}}' --dry-run=server -o yaml
```

Execute by removing the dry-run/output flags.

### Restart

```bash
kubectl rollout restart deployment/my-app
```

This updates the Pod template so the controller replaces Pods in a controlled
rollout. It is generally better than manually deleting random Pods.

### Scale

```bash
kubectl scale deployment/my-app --replicas=3
```

Use this only when another controller such as an HPA is not expected to control
the replica count, or understand that the HPA may later change it again.

### Set image

```bash
kubectl set image deployment/my-app web=example/my-app:2.0.0
```

This changes the Pod template and creates a rollout.

### Delete

```bash
kubectl delete deployment my-app
```

Deletion is destructive. The utility requires `--execute --yes` before running
this command.

## Helm commands

Helm treats a set of Kubernetes resources installed from a chart as a **release**.

### List

```bash
helm list
helm list --all-namespaces
```

Why: inventory deployed releases.

### Status

```bash
helm status RELEASE -o json
```

Why: release state, notes, and resources.

### Values

```bash
helm get values RELEASE -o yaml
helm get values RELEASE -o yaml --all
```

Why: understand the settings used to produce the release.

### Manifest

```bash
helm get manifest RELEASE
```

Why: see the Kubernetes YAML Helm rendered for the release.

### History

```bash
helm history RELEASE -o json
```

Why: see revisions so you can understand upgrades and choose a rollback target.

### Lint

```bash
helm lint ./chart -f values.yaml
```

Why: catch chart problems before talking to the cluster.

### Template

```bash
helm template RELEASE ./chart -f values.yaml
```

Why: render YAML locally without installing it.

### Install dry run

```bash
helm install RELEASE ./chart -f values.yaml --dry-run --debug
```

Important: Helm dry-run output can contain rendered Secret objects. Treat that
output as sensitive when charts create Secrets.

### Upgrade dry run

```bash
helm upgrade RELEASE ./chart -f values.yaml --dry-run --debug
```

Execute after review:

```bash
helm upgrade RELEASE ./chart -f values.yaml --wait
```

The Python utility adds a rollback safety flag based on the detected Helm major
version when it performs a real upgrade.

### Rollback

```bash
helm rollback RELEASE REVISION --wait
```

Why: move back to a previous known Helm revision.

### Uninstall

```bash
helm uninstall RELEASE
```

This removes the resources Helm associates with the release. The utility
requires `--execute --yes` before running it.

## Official documentation

- https://kubernetes.io/docs/concepts/overview/kubectl/
- https://kubernetes.io/docs/reference/kubectl/
- https://kubernetes.io/docs/tasks/debug/
- https://helm.sh/docs/
- https://helm.sh/docs/helm/
