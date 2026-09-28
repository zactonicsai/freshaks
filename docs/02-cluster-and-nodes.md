# 02 · The cluster and the nodes (the building and the rooms)

## Background: what is Kubernetes, really?

Imagine a school. The **building** is the cluster. **Classrooms** are the nodes — actual computers (virtual
machines in Azure). **Students doing jobs** are pods — one running program each (a Keycloak, a Postgres, a Java
store). The **principal's office** is the *control plane*: it decides which student sits in which room, notices when
someone is sick (a crashed pod) and sends in a replacement. On AKS Azure runs the principal's office for you, for free;
you only pay for classrooms.

**Hallways** are namespaces. They keep things tidy and let you say "everything in the `data` hallway" in one word.
We use four:

| Namespace | Who lives there |
|-----------|-----------------|
| `identity` | Keycloak, OpenLDAP |
| `data` | Postgres |
| `apps` | java-store, python-deli (and any new service you add) |
| `testing` | the inspector Jobs |

## Node pools: why two?

`scripts/01-create-cluster.sh` creates the cluster with one **system** node pool. Kubernetes itself needs a few helper
pods (DNS, metrics, the ingress controller). `scripts/02-setup-nodes.sh` adds a **user** node pool named `apps` with the
label `workload=apps`.

Why separate them? Same reason a school keeps the boiler room away from classrooms: if an app eats all the memory,
the cluster's own helpers keep running. In `helm/keycloak/values-generated.yaml` you will see
`nodeSelector: {workload: apps}` — that is how we say "Keycloak, please sit in an apps classroom".

Sizes are in `00-config.sh`:

```bash
export SYSTEM_NODE_COUNT=1;  export SYSTEM_NODE_VM_SIZE="Standard_D2s_v3"   # 2 vCPU, 8 GB
export APPS_NODE_COUNT=2;    export APPS_NODE_VM_SIZE="Standard_D2s_v3"
```

Keycloak likes ~1 GB of memory; the Java app ~600 MB; everything else is small. Two D2s_v3 nodes leave room to add
services. `Standard_B2s` is cheaper but slower to start.

## The front door: ingress-nginx

Pods have private addresses that change. To reach them from the internet you need one stable public IP and a
greeter who reads the host name and forwards the request. That greeter is **ingress-nginx**, installed by Helm in
script 02. Each app then publishes an `Ingress` object ("send `java.<ip>.nip.io` to service `java-store`, port 80").

Two settings we pass to the chart matter:

* `controller.config.use-forwarded-headers=true` — the greeter tells the app the original scheme/host in
  `X-Forwarded-Proto` / `X-Forwarded-Host` headers, so redirects back from Keycloak land on the right URL.
* the Azure health-probe path annotation — so the Azure load balancer can check the greeter is alive.

## Certificates (optional but recommended): cert-manager

With `ENABLE_TLS=true`, script 02 installs **cert-manager** and a `ClusterIssuer` called `letsencrypt-prod`.
From then on any Ingress with the annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` gets a real
certificate automatically (Let's Encrypt proves you own the name by fetching `http://<host>/.well-known/...`).
`scripts/lib/common.sh` (`ingress_vars`) adds that annotation and the `tls:` block to every ingress when TLS is on.

Pros: real https, browsers happy, Keycloak can require SSL. Cons: Let's Encrypt has rate limits (5 certs per
host per week) — don't destroy/recreate the cluster ten times in a day with TLS on.

## How the scripts talk to Azure

Everything is the Azure CLI (`az`). The key commands, so you recognise them:

```bash
az group create --name freshmart-rg --location eastus
az acr create --name <unique> --resource-group freshmart-rg --sku Basic
az aks create --name freshmart-aks --resource-group freshmart-rg --node-count 1 --attach-acr <unique> ...
az aks nodepool add --cluster-name freshmart-aks --name apps --labels workload=apps --node-count 2
az aks get-credentials --name freshmart-aks --resource-group freshmart-rg
```

`--attach-acr` gives the cluster permission to pull images from your registry — no image-pull secrets needed.

## Handy commands

```bash
kubectl get nodes -L workload,agentpool          # which rooms exist and their labels
kubectl get pods -A                              # every student in every hallway
kubectl -n apps describe pod <name>              # why is this pod unhappy?
kubectl -n identity logs deploy/keycloak -f      # watch the front office start
az aks stop --name freshmart-aks -g freshmart-rg # pause the cluster (stops most of the bill), 'start' to resume
```
