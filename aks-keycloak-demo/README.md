# Keycloak login on Azure Kubernetes (AKS) with Istio, locked to one IP address

This project builds a small, safe login system on Azure with one command, and removes it with one command.

- `./create.sh` builds everything (about 15–20 minutes).
- `./verify.sh` checks that it works.
- `./destroy.sh` deletes everything so the bill stops.

It is written so a middle school student can follow it. Every command is explained in plain words.

---

## 1. What you will build

```
                      THE INTERNET
                           |
        only 68.32.112.68 gets past this line
                           |
   +-----------------------v------------------------+
   | Azure firewall rule on the load balancer       |   Lock A (Azure)
   +-----------------------+------------------------+
                           |
   +-----------------------v------------------------+
   | Istio ingress gateway  (the front door, HTTPS) |   Lock B (Istio)
   +-----------+------------------------+-----------+
               |                        |
   +-----------v---------+   +----------v-----------+
   | Java app  [sidecar] |-->| Keycloak   [sidecar] |   Lock C (sidecars)
   | /  /private  /group |   | the login server     |
   +---------------------+   +----------+-----------+
                                        |
                             +----------v-----------+
                             | Postgres   [sidecar] |
                             | the database         |
                             +----------------------+
```

| Piece | What it does |
|---|---|
| **AKS cluster** | A group of computers in Azure that runs our programs. |
| **Istio** | A helper that puts a tiny guard (a "sidecar") next to every program. Guards check ID cards and encrypt traffic. |
| **Ingress gateway** | The single front door from the internet into the cluster. |
| **Keycloak** | The login server. It shows the login page and knows the users and groups. |
| **Postgres** | The database where Keycloak saves its data. |
| **Java app** | A tiny website with three pages (see below). |

### The three pages

| Page | Who can see it |
|---|---|
| `/` (public) | Anyone who can reach the site. No login. |
| `/private` | Anyone who is logged in (alice, bob or carol). |
| `/group` | Only logged-in users in the group **managers** (alice and bob). Carol gets a "Not allowed" page. |

### The users that are made for you

| User | Group | `/private` | `/group` |
|---|---|---|---|
| alice | managers | yes | yes |
| bob | managers | yes | yes |
| carol | (none) | yes | **no** |
| admin | Keycloak administrator (not an app user) | – | – |

Passwords are random. `create.sh` makes them and saves them in the file `.secrets.env` on your computer.

---

## 2. Quick start

```bash
# 1. Log in to Azure (a browser window opens).
az login

# 2. Go into the project folder.
cd aks-keycloak-demo

# 3. Build everything.
./create.sh

# 4. See the passwords.
cat .secrets.env

# 5. Open the app address that create.sh printed, for example:
#       https://app.20.1.2.3.nip.io
#    Your browser warns about the certificate. Click "Advanced", then continue.
#    (It warns once for the app and once for Keycloak. That is expected.)

# 6. When you are done, delete everything.
./destroy.sh
```

Try this once it is up:

1. Open `/`. It opens with no login.
2. Click **Private**. You are sent to Keycloak. Log in as `carol`. You see the private page.
3. Click **Group**. Carol sees "Not allowed".
4. Click **Log out**. Log in as `alice`. Now **Group** opens.

---

## 3. What you need first

| Tool | Why | How to get it |
|---|---|---|
| An Azure subscription | Where everything runs | You need the **Owner** role (or Contributor plus User Access Administrator). See gotcha 9. |
| Azure CLI (`az`) 2.57.0 or newer | Talks to Azure | <https://learn.microsoft.com/cli/azure/install-azure-cli> — update with `az upgrade` |
| `kubectl` | Talks to the cluster | `az aks install-cli` |
| `openssl`, `curl`, `sed`, `bash` | Small helpers | Already on macOS and Linux. On Windows use WSL. |

You do **not** need Docker or Java on your computer. The app is built in Azure.

**Where to run it:** run the scripts from the computer whose internet address is `68.32.112.68`. Check with:

```bash
curl https://api.ipify.org
```

If it prints a different address, see gotcha 1.

---

## 4. Settings (`config.sh`)

| Setting | Default | Meaning |
|---|---|---|
| `RESOURCE_GROUP` | `rg-keycloak-demo` | The Azure "box" that holds everything. |
| `LOCATION` | `centralus` | Which Azure data center. |
| `CLUSTER_NAME` | `aks-keycloak-demo` | Name of the cluster. |
| `NODE_COUNT` / `NODE_VM_SIZE` | `1` / `auto` | How many computers, and how big. `auto` picks the cheapest 4-CPU size your quota allows. |
| `NODE_DISK_GB` | `32` | Size of the node's own disk. 32 is the cheapest tier. |
| `ALLOWED_IP` | `68.32.112.68` | The one address allowed to reach Keycloak. |
| `LOCK_APP_TO_ALLOWED_IP` | `true` | `true`: the app is also locked to that address. `false`: the app's pages are open to everyone, Keycloak stays locked. |
| `KEYCLOAK_VERSION` | `26.7.0` | Which Keycloak to run. |

Change one just for a single run like this: `LOCATION=eastus2 ./create.sh`

> **A choice I made for you.** You asked to give access to Keycloak only to `68.32.112.68`. Since nobody can log in without reaching Keycloak, I also locked the app to that address by default (the safest reading). If you want the public page to be truly public, set `LOCK_APP_TO_ALLOWED_IP=false` and run `./create.sh` again.

---

## 5. Words to know

| Word | Simple meaning |
|---|---|
| **Resource group** | A box in Azure. Delete the box, and everything in it is deleted. |
| **Cluster** | A team of computers that work as one. |
| **Node** | One computer in the team. |
| **Pod** | One running program in the cluster. |
| **Namespace** | A folder inside the cluster. |
| **Service** | A fixed name for a pod, like a phone book entry. |
| **Secret** | A locked note in the cluster that holds a password. |
| **Container image** | A program packed in a box, ready to run. |
| **Registry (ACR)** | A shelf where images are stored. |
| **Sidecar** | A small guard program Istio puts next to each pod. All traffic goes through the guard. |
| **mTLS** | Two guards show each other ID cards, then talk in secret code. |
| **Ingress gateway** | The front door from the internet into the cluster. |
| **OIDC (OpenID Connect)** | The standard way for an app to say "Keycloak, please log this person in for me". |
| **Realm** | One Keycloak "world" with its own users and groups. Ours is called `demo`. |
| **Token** | A signed note from Keycloak that says "this is alice, she is in managers". |
| **CIDR `/32`** | "Exactly this one address." `68.32.112.68/32` is one address, no neighbors. |

### How a login works

1. You open `/private` in the app.
2. The app says: "I don't know you. Go ask Keycloak." Your browser is sent to Keycloak.
3. You type your name and password **into Keycloak** (the app never sees your password).
4. Keycloak sends your browser back to the app with a one-time **code**.
5. The app quietly shows that code to Keycloak (inside the cluster) and gets a **token** back.
6. The token says who you are and which groups you are in. The app opens the page, or says "Not allowed".

---

## 6. What `create.sh` does, step by step

Each step shows the main command and what it means.

### Step 0 — Check tools

```bash
command -v az                                  # is the "az" program installed?
az version --query '"azure-cli"' --output tsv  # which version is it?
az account show                                # am I logged in?
curl https://api.ipify.org                     # what is my internet address?
```

`--query` picks one piece out of the answer. `--output tsv` prints it as plain text.

### Step 1 — Turn on Azure features

```bash
az provider register --namespace Microsoft.ContainerService --wait
```

A new subscription has many features switched off. This switches on the ones we need (Kubernetes, registry, network, computers, disks). `--wait` means "don't go on until it is ready".

### Step 2 — Make the resource group

```bash
az group create --name rg-keycloak-demo --location centralus --tags purpose=keycloak-demo
```

Makes the box. `--tags` sticks a label on it so you remember what it is for.

### Step 3 — Make the container registry

```bash
az acr create --resource-group rg-keycloak-demo --name <unique-name> --sku Basic --admin-enabled false
```

- `--sku Basic` — the cheapest size.
- `--admin-enabled false` — no shared password. The cluster uses its own identity instead.
- The name must be unique in all of Azure, so the script adds a number to the end.

### Step 4 — Make the cluster with Istio

First the script picks a node size. Azure gives each subscription a **quota**: the most CPUs you may use, counted per VM family and per region. A new subscription often has a quota of 0 for some families.

```bash
az vm list-usage --location centralus --query "[].[name.value, currentValue, limit]" --output tsv
```

This prints one line per family: its name, how many CPUs you use now, and your limit. The script walks through a list of 4-CPU sizes, cheapest first, and takes the first one with 4 free CPUs.

Then it makes the cluster:

```bash
az aks create \
  --resource-group rg-keycloak-demo \
  --name aks-keycloak-demo \
  --location centralus \
  --node-count 1 \
  --node-vm-size Standard_B4ms \
  --node-osdisk-size 32 \
  --tier free \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --enable-managed-identity \
  --enable-asm \
  --attach-acr <registry-name> \
  --no-ssh-key \
  --api-server-authorized-ip-ranges 68.32.112.68/32
```

| Flag | Meaning |
|---|---|
| `--node-count 1` | One worker computer (the cheapest that works). |
| `--node-vm-size` | 4 CPUs and 16 GB memory. The script picks the cheapest size you have quota for. |
| `--node-osdisk-size 32` | A small 32 GB disk for the node. Smaller disk, smaller bill. |
| `--tier free` | Don't pay for the control room. Fine for a demo. |
| `--network-plugin azure` + `overlay` | Azure's recommended way to give pods addresses. |
| `--enable-managed-identity` | The cluster gets its own Azure ID. No passwords to leak. |
| `--enable-asm` | Install the Istio add-on. (asm = Azure Service Mesh.) |
| `--attach-acr` | Let the cluster pull images from our registry. |
| `--no-ssh-key` | Nobody can SSH into the nodes. We never need to. |
| `--api-server-authorized-ip-ranges` | Only your address may use `kubectl`. **Only added when you run the script from `ALLOWED_IP`.** |

### Step 5 — Connect `kubectl`

```bash
az aks get-credentials --resource-group rg-keycloak-demo --name aks-keycloak-demo --overwrite-existing
kubectl get nodes
```

The first command saves the cluster's address and a login key in `~/.kube/config`. The second lists the nodes to prove it works.

### Step 6 — Turn on the front door

```bash
az aks mesh enable-ingress-gateway \
  --resource-group rg-keycloak-demo --name aks-keycloak-demo \
  --ingress-gateway-type external

az aks show --resource-group rg-keycloak-demo --name aks-keycloak-demo \
  --query 'serviceMeshProfile.istio.revisions[0]' --output tsv
```

The first command adds a gateway with a public IP. The second asks, "which Istio version (revision) did you install?" The answer looks like `asm-1-27`. We need it in Step 9.

### Step 7 — Lock the front door

```bash
kubectl patch service aks-istio-ingressgateway-external -n aks-istio-ingress \
  --type merge --patch '{"spec":{"externalTrafficPolicy":"Local"}}'

kubectl annotate service aks-istio-ingressgateway-external -n aks-istio-ingress \
  service.beta.kubernetes.io/azure-allowed-ip-ranges=68.32.112.68/32 --overwrite
```

- `externalTrafficPolicy: Local` keeps the visitor's **real** address. Without it every visitor looks like one of our own nodes, and Istio could not tell who is who.
- The annotation is a note to Azure: "at the firewall, only let this address in." (Lock A)

### Step 8 — Find the public IP and make website names

```bash
kubectl get service aks-istio-ingressgateway-external -n aks-istio-ingress \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

If the answer is `20.1.2.3`, the names become `app.20.1.2.3.nip.io` and `keycloak.20.1.2.3.nip.io`.
**nip.io** is a free service: any name ending in `.1.2.3.4.nip.io` points to `1.2.3.4`. No domain to buy.

### Step 9 — Make the namespace with sidecars

```bash
kubectl apply --filename .rendered/00-namespace.yaml
```

`kubectl apply` means "make the cluster look like this file". The file has the label `istio.io/rev: asm-1-27`. That label tells Istio to add a sidecar to every pod in the namespace.

### Step 10 — Make passwords and Secrets

```bash
openssl rand -hex 16        # prints 32 random characters

kubectl create secret generic postgres-credentials --namespace demo \
  --from-literal=username=keycloak --from-literal=password=... \
  --dry-run=client --output yaml | kubectl apply --filename -
```

- `openssl rand` makes a random password. No password is ever written in the code.
- `--dry-run=client --output yaml | kubectl apply` means "write the Secret as text, then apply it". This works the first time **and** when you run the script again.
- The Keycloak setup file (`keycloak/realm-template.json`) is filled in with the passwords and stored as a Secret too.

### Step 11 — Make the HTTPS certificate

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
  -keyout tls.key -out tls.crt -subj "/CN=app.20.1.2.3.nip.io" \
  -addext "subjectAltName=DNS:app.20.1.2.3.nip.io,DNS:keycloak.20.1.2.3.nip.io"

kubectl create secret tls demo-tls --namespace aks-istio-ingress --cert tls.crt --key tls.key ...
```

A certificate lets the browser encrypt what you type. Ours is **self-signed** (we made it ourselves), so the browser warns you once. See the options table in section 10 for a real one.

### Step 12 — Build the Java app in Azure

```bash
az acr build --registry <registry-name> --image demo-app:<date-time> ./app
```

Uploads the `app` folder. Azure builds the image using `app/Dockerfile` and puts it on the registry shelf.

### Step 13 — Put everything in the cluster

```bash
kubectl apply --filename .rendered/50-istio-security.yaml   # the locks FIRST
kubectl apply --filename .rendered/10-postgres.yaml
kubectl apply --filename .rendered/20-keycloak.yaml
kubectl apply --filename .rendered/30-app.yaml
kubectl rollout status deployment/keycloak --namespace demo --timeout=600s
kubectl apply --filename .rendered/40-istio-gateway.yaml    # the door signs LAST
```

`rollout status` waits until the pods are healthy. The locks go on first and the door signs last, so Keycloak is never reachable without its locks.

### Step 14 — Check

Runs `./verify.sh` (section 8).

---

## 7. The files

```
aks-keycloak-demo/
├── config.sh                  settings shared by all scripts
├── create.sh                  build everything
├── verify.sh                  check everything (changes nothing)
├── destroy.sh                 delete everything
├── k8s/
│   ├── 00-namespace.yaml      the "demo" folder, with the sidecar label
│   ├── 10-postgres.yaml       database + 5 GB disk
│   ├── 20-keycloak.yaml       login server, connected to Postgres
│   ├── 30-app.yaml            the Java app
│   ├── 40-istio-gateway.yaml  front door: HTTPS + which name goes where
│   └── 50-istio-security.yaml the locks (IP rule, mTLS, who-may-talk-to-whom)
├── keycloak/
│   └── realm-template.json    realm "demo", group, users, login client
└── app/
    ├── Dockerfile             how to build the image
    ├── pom.xml                the app's parts list (Spring Boot 4.1.1, Java 21)
    └── src/main/...           3 small Java files + settings
```

Files in `k8s/` and `keycloak/` contain placeholders like `__KC_HOST__`. `create.sh` copies them to `.rendered/` with the real values filled in.

### The five locks in `50-istio-security.yaml`

| Lock | Where | Rule |
|---|---|---|
| 1 `keycloak-ip-allowlist` | Ingress gateway | If you are **not** `68.32.112.68`, you may only ask for the app's name. Everything else (Keycloak) gets **403**. |
| 2 `PeerAuthentication` | Namespace `demo` | Every pod must use mTLS. A pod with no sidecar cannot get in. |
| 3 `keycloak-allow` | Keycloak's sidecar | Only the gateway and the Java app may talk to Keycloak. |
| 4 `postgres-allow` | Postgres's sidecar | Only Keycloak may talk to the database. |
| 5 `app-allow` | App's sidecar | Only the gateway may talk to the app. |

Together with the Azure firewall note (Lock A), a stranger has to get past three layers to reach Keycloak.

---

## 8. Checking it yourself

```bash
./verify.sh
```

It prints `PASS` or `FAIL` for each check: pods healthy, sidecars present, locks in place, pages answer.

Checks by hand:

```bash
# All pods should show READY 2/2 (the program + its sidecar).
kubectl get pods --namespace demo

# Prove the sidecar lock: start a pod with NO sidecar and try to reach Keycloak.
# Expected: "connection reset by peer". The guard refused it.
kubectl run probe --rm -it --restart=Never --image=curlimages/curl --namespace default \
  -- curl -sS -m 5 http://keycloak.demo.svc.cluster.local:8080/

# Prove the IP lock: from a phone on mobile data (not Wi-Fi), open the Keycloak
# address. It should time out (or show 403 if LOCK_APP_TO_ALLOWED_IP=false).
```

### Common jobs

```bash
# Add a user: open https://keycloak.<ip>.nip.io/admin, log in as admin,
# pick realm "demo" > Users > Add user. Put them in "managers" under Groups.

# Change the allowed IP: edit ALLOWED_IP in config.sh, then
./create.sh
# and, if the kubectl lock is on, also:
az aks update --resource-group rg-keycloak-demo --name aks-keycloak-demo \
  --api-server-authorized-ip-ranges <new-ip>/32

# Look at logs
kubectl logs --namespace demo deployment/keycloak
kubectl logs --namespace demo deployment/app
kubectl logs --namespace aks-istio-ingress --selector istio=aks-istio-ingressgateway-external
```

---

## 9. Deleting everything

```bash
./destroy.sh          # asks you to type the resource group name
./destroy.sh --yes    # does not ask
```

| Step | Command | Meaning |
|---|---|---|
| 1 | `az group exists --name rg-keycloak-demo` | Is the box still there? Prints `true` or `false`. |
| 1 | `az group delete --name rg-keycloak-demo --yes` | Delete the box and everything in it: cluster, registry, load balancer, public IP, disks. `--yes` = don't ask again. It waits until done (5–10 minutes). |
| 2 | `az group exists --name MC_rg-keycloak-demo_aks-keycloak-demo_centralus` | AKS keeps the nodes in a hidden helper box. This checks that it is gone too. |
| 3 | `kubectl config delete-context`, `delete-cluster`, `delete-user` | Remove the dead cluster from `kubectl` on your computer. |
| 4 | `rm -f .secrets.env; rm -rf .rendered` | Delete the local passwords and certificate. |

The Postgres data is deleted too and **cannot be brought back**.
Azure may leave a group called `NetworkWatcherRG`. Azure makes that by itself, it is free, and it is not part of this demo.

---

## 10. Best practices used, and the choices behind them

### What this demo does right

- **No passwords in code.** All are random and live in Kubernetes Secrets and a private local file.
- **Three layers of IP locking**: Azure firewall, Istio gateway rule, and the `kubectl` API lock.
- **Zero trust inside the cluster**: strict mTLS, and each sidecar lets in only the callers it needs.
- **Pods do not run as root**, cannot gain extra powers, and have memory limits.
- **Keycloak runs in production mode** (`start`, not `start-dev`) with a real database.
- **Safe login flow**: authorization code + PKCE, a secret client, exact redirect address, token issuer checked, password guessing slowed down (brute force protection).
- **HTTPS only**; plain HTTP is redirected.
- **Pinned versions** (`keycloak:26.7.0`, `postgres:17`), not `latest`.
- **Scripts can be run again** without breaking anything.

### Keeping the bill small

This is already the smallest setup that works:

| Choice | Why it is cheap |
|---|---|
| 1 node, 4 CPUs, burstable "B" size if your quota allows | Burstable sizes cost less because they are meant for programs that are mostly idle, like this demo. |
| 32 GB node disk | The cheapest disk tier. The default (128 GB) costs about four times more. |
| `--tier free` | No charge for the cluster's control room. |
| Registry `Basic` | The cheapest registry. |

Why not 2 CPUs? The Istio add-on insists on 2 copies of istiod and 2 copies of the gateway. With Keycloak, Postgres, the app and Azure's own helper pods, a 2-CPU node is full before everything has started.

**The biggest saver: switch it off when you are not using it.**

```bash
# Stop: the node is turned off and you stop paying for it. Data is kept.
az aks stop  --resource-group rg-keycloak-demo --name aks-keycloak-demo

# Start again later (about 5 minutes), then check:
az aks start --resource-group rg-keycloak-demo --name aks-keycloak-demo
./verify.sh
```

While stopped you still pay a little for the disks, the public IP and the registry. If `verify.sh` shows a new gateway IP after a start, the website names have changed; run `./destroy.sh` and `./create.sh` for a clean start.

### Shortcuts taken to keep it simple (fix these for real use)

| Shortcut | For real use |
|---|---|
| Self-signed certificate | A real domain + a real certificate (cert-manager with a DNS check, or Azure Key Vault). |
| nip.io names | Your own DNS name. |
| Postgres as one pod, no backups | Azure Database for PostgreSQL Flexible Server. |
| One node; one Keycloak, one app copy | Three or more nodes; two or more copies; Keycloak clustering; shared sessions for the app. |
| Users have fixed passwords | Set passwords as "temporary" so users must change them; add two-step login. |
| Temporary `admin` user | Create a permanent admin, then delete the temporary one (Keycloak shows a banner about this). |
| Secrets in Kubernetes | Azure Key Vault with the Secrets Store CSI driver. |
| Images pulled from Docker Hub / Quay | Copy them into your own registry with `az acr import`. |
| `--tier free`, local `kubectl` key | Standard tier, Microsoft Entra ID login, `--disable-local-accounts`. |

### Options, with pros and cons

**How to install Istio**

| Option | Pros | Cons |
|---|---|---|
| **AKS Istio add-on** (used here) | One flag. Microsoft updates and supports it. | Fewer knobs. Must use the `istio.io/rev` label. Only some settings can be changed. |
| Install Istio yourself (Helm/istioctl) | Every feature, any version. | You do all upgrades and fixes yourself. |

**Where to put the IP lock**

| Option | Pros | Cons |
|---|---|---|
| **Azure firewall note on the load balancer** (used) | Bad traffic never enters the cluster. | All-or-nothing for the whole gateway. |
| **Istio rule at the gateway** (used) | Can lock one website name (Keycloak) and leave another open. | Needs `externalTrafficPolicy: Local` to see real addresses. |
| Istio rule at the Keycloak sidecar | Closest to the app. | Sidecar sees the gateway's address, not the visitor's, so it needs extra header setup. |

Using two layers means one mistake does not open the door.

**HTTPS certificate**

| Option | Pros | Cons |
|---|---|---|
| **Self-signed** (used) | Free, instant, works with an IP lock. | Browser warning. |
| Let's Encrypt, HTTP check | Free, trusted. | Needs port 80 open to the whole internet, which fights the IP lock. |
| Let's Encrypt, DNS check | Free, trusted, works with an IP lock. | You must own a domain. |

**Where the app checks the login**

| Option | Pros | Cons |
|---|---|---|
| **Inside the app** (used, Spring Security) | Simple. The app knows the user and groups. | Each app needs login code. |
| At the mesh (Istio + oauth2-proxy) | Apps need no login code. | More parts to run and understand. |

**Database**

| Option | Pros | Cons |
|---|---|---|
| **Postgres pod** (used, as asked) | Simple, cheap, all in one place. | You handle backups and upgrades. One pod = one point of failure. |
| Azure managed Postgres | Backups, updates and failover done for you. | Costs more; more network setup. |

**Sidecar or ambient mode**

| Option | Pros | Cons |
|---|---|---|
| **Sidecars** (used, as asked) | Well known; fully supported by the AKS add-on. | One extra container per pod. |
| Ambient (no sidecars) | Less memory per pod. | Newer; check whether your AKS add-on version supports it. |

---

## 11. Troubleshooting

| What you see | Why | Fix |
|---|---|---|
| Browser: "Your connection is not private" | Self-signed certificate. Expected. | Click **Advanced** → continue. Do it once for the app name and once for the Keycloak name. |
| The site never loads (times out) | Your address is not `ALLOWED_IP`. | `curl https://api.ipify.org`. If it changed, see "Change the allowed IP" in section 8. |
| Keycloak shows `RBAC: access denied` (403) | Istio's gateway rule blocked you: wrong address, or the gateway cannot see real addresses. | Check your address. Check `kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress -o jsonpath='{.spec.externalTrafficPolicy}'` prints `Local`. |
| Browser cannot find `app.x.x.x.x.nip.io` | Your router or DNS filter blocks nip.io names. | Add two lines to your hosts file: `<ip> app.<ip>.nip.io` and `<ip> keycloak.<ip>.nip.io`. |
| Pods show `1/1`, not `2/2` | No sidecar. The namespace label is wrong. | `kubectl get ns demo --show-labels` must show `istio.io/rev=asm-...`. Then `kubectl rollout restart deployment --namespace demo`. |
| Keycloak pod keeps restarting | Often the database password does not match (you deleted `.secrets.env` but kept the cluster). | `kubectl logs -n demo deployment/keycloak`. To start clean: `kubectl delete statefulset postgres -n demo; kubectl delete pvc data-postgres-0 -n demo; ./create.sh` |
| You edited the realm file but nothing changed | Keycloak imports the realm only when it does not exist yet. | Change it in the admin console, or wipe the database (line above). |
| Keycloak: `Invalid parameter: redirect_uri` | The gateway's IP changed, so the app's name changed. Keycloak still has the old name. | Admin console → realm `demo` → Clients → `demo-app` → fix the addresses. Or wipe the database and re-run. |
| App after login: `invalid_token_response` / 401 | The client secret in the app and in Keycloak are different. | Same cause as above (old realm, new secret). Wipe the database and re-run. |
| App pod: `ImagePullBackOff` | The cluster may not pull from the registry. | `az aks check-acr --resource-group rg-keycloak-demo --name aks-keycloak-demo --acr <name>.azurecr.io`, then `az aks update ... --attach-acr <name>`. Needs Owner role. |
| Postgres pod: `ImagePullBackOff`, `toomanyrequests` | Docker Hub's download limit. | Wait an hour, or copy the image: `az acr import --name <acr> --source docker.io/library/postgres:17` and change the image name. |
| `az acr build` fails: `TasksOperationsNotAllowed` | Some free and student subscriptions cannot build in the cloud. | Build on your computer with Docker: `az acr login --name <acr>`, `docker build`, `docker push`. |
| `ErrCode_InsufficientVCPUQuota`, or "No size ... has 4 free CPUs" | Your quota for that VM family in that region is used up or 0. | With `NODE_VM_SIZE=auto` the script avoids this by itself. If no size fits: try another region (`LOCATION=eastus2 ./create.sh`), or ask for more in the Azure portal under **Quotas → Compute** (4 CPUs in one family). See your quota: `az vm list-usage --location centralus --output table`. |
| `az aks create`: VM size not available in this region | Quota is fine, but Azure does not offer that size to you there. | Name another size: `NODE_VM_SIZE=Standard_D4s_v3 ./create.sh`, or try another `LOCATION`. |
| Pods stay `Pending` | The node is full. | `kubectl describe pod <name> -n demo` shows why. Use a bigger size or `NODE_COUNT=2` (on a new cluster). |
| `unrecognized arguments: --enable-asm` | Azure CLI is too old. | `az upgrade` |
| `kubectl` suddenly times out | The API lock is on and your address changed. | `az aks update --resource-group rg-keycloak-demo --name aks-keycloak-demo --api-server-authorized-ip-ranges <new-ip>/32` |
| `upstream connect error` / 503 from the gateway | The pod behind it is not ready yet, or a sidecar rule blocks the gateway. | `kubectl get pods -n demo`; wait for `2/2`. Check gateway logs (section 8). |
| Login goes round in circles | You opened the site by IP or with `http://`, or have stale cookies. | Use the exact `https://app.<ip>.nip.io` name. Try a private window. |
| `destroy.sh` says a helper group still exists | Azure was slow. | Run the `az group delete` command it prints. |

---

## 12. Key gotchas

1. **You must be at `68.32.112.68` to use it.** The scripts can run from anywhere, but only that address can open the pages. If you run `create.sh` from somewhere else (for example Azure Cloud Shell), it skips the `kubectl` API lock and warns you. Add the lock later with the `az aks update` command in section 8.
2. **Home internet addresses can change.** If your provider gives you a new address, you are locked out. Change `ALLOWED_IP` and re-run.
3. **On AKS, `istio-injection=enabled` does nothing.** You must label the namespace `istio.io/rev=asm-X-Y`. The script reads the right value for you.
4. **`externalTrafficPolicy` must be `Local`.** If it is `Cluster`, Istio sees a node's address for every visitor and blocks everyone.
5. **The certificate Secret lives in `aks-istio-ingress`,** not in `demo`. The gateway can only read Secrets in its own namespace.
6. **Keycloak has two addresses.** The browser uses the public `https://keycloak...` name. The app uses the inside name `http://keycloak.demo.svc.cluster.local:8080`. Both must lead to a Keycloak that stamps the **same public name** in its tokens. That is what `KC_HOSTNAME` does. If `KC_HOSTNAME` and the app's `KEYCLOAK_PUBLIC_URL` differ, login fails.
7. **The realm is imported once.** Later changes to `realm-template.json` are ignored until the database is wiped.
8. **Postgres sets its password once,** the first time it starts on an empty disk. That is why `.secrets.env` is kept between runs. Don't delete it while the cluster is alive.
9. **`--attach-acr` needs the Owner role** (or User Access Administrator), because it hands out a permission.
10. **A new Azure disk is not empty.** It has a `lost+found` folder, and Postgres refuses to start there. The `PGDATA` setting points it to a sub-folder.
11. **Port names matter to Istio.** `http` means web traffic, `tcp-postgres` means plain TCP. A wrong name can break the database connection.
12. **Self-signed certificates and Let's Encrypt's HTTP check do not mix with an IP lock.** Let's Encrypt must reach you from the open internet. Use the DNS check instead.
13. **The AKS add-on only lets you change some gateway settings.** The IP note and `externalTrafficPolicy` are on the supported list. Other edits may be undone by Azure.
14. **Keycloak only fixes security bugs in its newest release.** Check for a newer version before real use and update `KEYCLOAK_VERSION`.
15. **It costs money while it runs.** One 4-CPU node, a load balancer, a public IP and a registry add up to very roughly 4–5 US dollars a day (my estimate; check the Azure pricing calculator). Run `./destroy.sh` when you are done. See section 10, "Keeping the bill small".
16. **You cannot go below 4 CPUs.** The AKS Istio add-on always runs 2 copies of istiod and 2 copies of the gateway, and Azure does not allow fewer. That does not fit on a 2-CPU node next to Keycloak.
17. **One node means no spare.** If the node restarts, everything is down for a few minutes. Fine for a demo, not for real use.

---

## 13. What was tested, and what was not

| Checked | How |
|---|---|
| Scripts | `shellcheck` reports no problems. All three were run from start to finish against stand-in `az`/`kubectl` commands: first run, second run (finished steps are skipped, passwords kept), and destroy. |
| Keycloak setup | The realm file was loaded into a real Keycloak 26.7.0 with a real Postgres, using the same settings as `20-keycloak.yaml`. alice gets the `managers` group in her token, carol does not, a wrong password is refused, a login without PKCE is refused, and a wrong redirect address is refused. |
| YAML and JSON | All files parse. No placeholder is left unfilled after rendering. |
| Java code | Every Spring class and method used was checked against the Spring Security 7.1 and Spring Boot 4.1.1 source code. |

| **Not** checked | Why |
|---|---|
| A real run on Azure | I had no Azure subscription to run it in. The first real run is the true test. |
| Compiling the Java app | The build tool's download site was not reachable where I worked. The first `az acr build` (Step 12) is the first compile. If it fails, the error will name the file and line. |
| Postgres 17 in the cluster | The local test used Postgres 16. |

---

## Sources

- [Deploy the Istio add-on for AKS](https://learn.microsoft.com/azure/aks/istio-deploy-addon)
- [Istio add-on ingress gateways for AKS](https://learn.microsoft.com/azure/aks/istio-deploy-ingress)
- [Istio add-on performance and scaling (minimum 2 replicas)](https://learn.microsoft.com/azure/aks/istio-scale)
- [Istio add-on ingress gateway troubleshooting](https://learn.microsoft.com/troubleshoot/azure/azure-kubernetes/extensions/istio-add-on-ingress-gateway)
- [Keycloak releases](https://versionlog.com/keycloak/) and [Keycloak downloads](https://www.keycloak.org/downloads)
- [Spring Boot 4.1.1 release note](https://spring.io/blog/2026/08/20/spring-boot-4-1-1-available-now/)
