# Kubernetes debugging tutorial — simple mental model

## The grocery-store analogy

Imagine a Kubernetes cluster is a grocery company.

- **Cluster** = the whole grocery company.
- **Node** = one store building.
- **Pod** = a worker station inside the store.
- **Container** = a worker doing one job at that station.
- **Deployment** = the manager who makes sure the right number of worker stations exist.
- **Service** = the customer-service phone number that routes callers to available workers.
- **Endpoint** = one worker station currently able to answer.
- **Ingress** = the front entrance from outside the company.
- **NetworkPolicy** = rules saying which rooms may talk to which rooms.
- **ConfigMap** = ordinary instruction sheet.
- **Secret** = locked envelope containing passwords or keys.
- **PVC** = claim ticket for storage space.
- **Helm chart** = a reusable store-opening kit.
- **Helm release** = one installed copy of that kit.

The goal of troubleshooting is to move from the outside inward instead of
randomly changing things.

## A repeatable debugging order

### Step 1: Am I talking to the correct cluster?

```bash
kubectl config current-context
kubectl cluster-info
```

With the utility:

```bash
k8s-doctor doctor
```

If this fails, do not start changing Pods. First fix kubeconfig, credentials,
VPN/network routing, or the selected context.

### Step 2: Are the store buildings healthy?

```bash
kubectl get nodes
```

Look for `Ready`. If a node is NotReady, inspect it:

```bash
kubectl describe node NODE_NAME
```

Common clues are DiskPressure, MemoryPressure, PIDPressure, and networking
conditions.

### Step 3: Did the manager create enough worker stations?

```bash
kubectl get deployments
kubectl get statefulsets
kubectl get daemonsets
```

A Deployment that wants 3 replicas but has only 1 ready means the next question
is: **why are the missing Pods not ready?**

### Step 4: Which Pod is unhappy?

```bash
kubectl get pods
```

Common states:

- `Pending`: not scheduled or waiting for something such as storage.
- `ImagePullBackOff`: image could not be downloaded.
- `CrashLoopBackOff`: application repeatedly starts and crashes.
- `Running` but `0/1 Ready`: process exists, but readiness has not passed.

Use:

```bash
k8s-doctor -n NAMESPACE pod POD_NAME
```

That combines status, describe output, events, current logs, previous logs, and
referenced ConfigMap/Secret checks.

### Step 5: What does the application say?

```bash
kubectl logs POD_NAME --tail=200
```

If the container restarted:

```bash
kubectl logs POD_NAME --previous --tail=200
```

This is like asking the worker what happened instead of only asking the manager.

### Step 6: What does Kubernetes say happened around the Pod?

```bash
kubectl describe pod POD_NAME
kubectl get events --sort-by=.lastTimestamp
```

Typical questions:

- Could Kubernetes schedule it?
- Could it pull the image?
- Could it mount the volume?
- Did health checks fail?
- Was the container killed for memory use?

### Step 7: Can traffic reach the Pod?

Start with the Service:

```bash
kubectl get service my-service -o yaml
kubectl get endpoints my-service -o yaml
```

If there are no endpoint addresses, compare:

```bash
kubectl get pods --show-labels
```

with the Service selector.

Think of it this way: the phone number exists, but the directory has no worker
listed to answer it.

### Step 8: Is DNS working?

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

If many applications suddenly cannot find service names, DNS is a strong place
to inspect.

### Step 9: Is a network rule blocking traffic?

```bash
kubectl get networkpolicies
```

Check both ends of a connection. An egress policy can block the sender, and an
ingress policy can block the receiver.

### Step 10: Is storage ready?

```bash
kubectl get pvc
kubectl describe pvc CLAIM_NAME
```

A Pending PVC can keep a Pod Pending.

### Step 11: Is configuration present?

A Pod can reference ConfigMaps and Secrets. The focused Pod report identifies
many of those references and checks whether they exist.

```bash
k8s-doctor -n NAMESPACE pod POD_NAME
```

Review a Secret without printing values:

```bash
k8s-doctor -n NAMESPACE secret SECRET_NAME
```

### Step 12: Did Helm install what I think it installed?

```bash
k8s-doctor -n NAMESPACE helm status RELEASE
k8s-doctor -n NAMESPACE helm values RELEASE --all-values
k8s-doctor -n NAMESPACE helm manifest RELEASE
k8s-doctor -n NAMESPACE helm history RELEASE
```

This answers four different questions:

1. Is Helm happy with the release?
2. Which values were used?
3. Which Kubernetes objects were rendered?
4. Which revision changes happened over time?

## Safe change workflow

Use this order when possible:

1. Observe current state.
2. Save/export the relevant YAML or Helm values.
3. Make one small change.
4. Dry-run/render it.
5. Execute it.
6. Watch rollout/status/events/logs.
7. Roll back if the change makes things worse.

Example manifest change:

```bash
k8s-doctor -n demo apply deployment.yaml
```

If preview looks correct:

```bash
k8s-doctor -n demo apply deployment.yaml --execute
```

Example Helm upgrade:

```bash
k8s-doctor -n demo helm upgrade my-app ./chart -f values.yaml
```

Then:

```bash
k8s-doctor -n demo helm upgrade my-app ./chart -f values.yaml --execute
```

## Common mistakes and what to check

### Pod is Pending

Check:

- events;
- node capacity/taints;
- nodeSelector/affinity;
- PVC status;
- resource requests.

### CrashLoopBackOff

Check:

- current logs;
- previous logs;
- container command/args;
- environment variables;
- ConfigMaps/Secrets;
- liveness probe behavior;
- memory limit / OOM termination.

### ImagePullBackOff

Check:

- image name and tag;
- registry reachability;
- imagePullSecrets;
- permissions;
- typo in registry/repository name.

### Service responds with connection failure

Check:

- Service selector;
- Pod labels;
- endpoints;
- targetPort vs containerPort/application port;
- readiness probe;
- NetworkPolicy.

### Ingress returns 404/502/503

Check:

- Ingress class/controller;
- host/path rule;
- backend Service name/port;
- Service endpoints;
- readiness;
- controller logs/events.

### Helm upgrade failed

Check:

```bash
helm status RELEASE
helm history RELEASE
helm get values RELEASE --all
helm get manifest RELEASE
kubectl get events --sort-by=.lastTimestamp
```

Do not immediately uninstall the release. First understand whether a rollback is
safer and preserves the known-good configuration.

## Practice exercises

### Exercise 1

A Deployment says `READY 1/3`.

Question: which two objects should you inspect next?

Suggested answer: Pods and Events. Then inspect logs/describe for the unhealthy
Pods.

### Exercise 2

A Service exists, but requests time out and its endpoint object has no addresses.

Question: what should you compare?

Suggested answer: Service selectors and Pod labels, plus Pod readiness.

### Exercise 3

A Pod restarted five times and is currently Running.

Question: which special log flag is useful?

Suggested answer: `kubectl logs POD --previous`.

### Exercise 4

A Helm upgrade just failed.

Question: what should you inspect before uninstalling?

Suggested answer: `helm status`, `helm history`, release values, rendered
manifest, Kubernetes events, and the failing workloads.
