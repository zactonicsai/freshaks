# Istio, VirtualServices and Keycloak health checks — how it works and how to debug it

Companion to `README.md`. Everything here applies to the kind setup *and* to a cloud cluster
(EKS/AKS/GKE, Big Bang); the only difference is how traffic reaches the ingress gateway
(kind host-port mapping vs. a cloud LoadBalancer + DNS). `kc-check.sh` in the repo root runs
every command in sections 5–7 for you.

```
Internet / laptop
   │  DNS: keycloak.example.com -> LoadBalancer IP          (cloud)      | localhost:8080 -> NodePort (kind)
   ▼
Istio ingress gateway pod (Envoy)        Deployment istio-gateway/public-ingressgateway
   │  Gateway  : which ports/hosts/TLS this Envoy listens on
   │  VirtualService : host+path -> which Service:port
   │  (DestinationRule : TLS/LB policy for that Service, optional)
   ▼
Service keycloak/keycloak-keycloak-http :80  ->  targetPort http (8080)
   │  Endpoints = only pods whose READINESS probe passes
   ▼
Pod keycloak-keycloak-0
   ├── [istio-proxy sidecar, if injected]  intercepts in/out traffic, mTLS
   └── keycloak        :8080 app / :9000 management (/health/*, /metrics)
            │
            └── PostgreSQL :5432
```

---

## 1. How Istio works (the parts that matter here)

**Envoy everywhere, configured by istiod.** Istio is a set of Envoy proxies. `istiod` (control
plane) watches Kubernetes Services/Endpoints plus Istio CRDs and pushes the resulting listener /
route / cluster / endpoint config (xDS) to every Envoy. Two kinds of Envoy exist:

| Envoy | Where | Job |
|---|---|---|
| **Ingress gateway** | its own Deployment (`istio-gateway/public-ingressgateway`), exposed by a Service of type LoadBalancer (cloud) or NodePort (kind) | edge proxy: terminates (or passes through) TLS and routes external requests into the mesh |
| **Sidecar** (`istio-proxy`) | injected into application pods when the namespace has `istio-injection=enabled` | transparently intercepts all pod traffic via iptables; provides mTLS, telemetry, retries, AuthorizationPolicy enforcement |

Keycloak works with or without a sidecar. Big Bang runs it **with** one (and STRICT mTLS); this repo
defaults to **without** (`ISTIO_INJECT=false`) to keep the first deploy simple. Section 4 covers what
changes when you add it.

**The CRDs you touch:**

| CRD | Scope | Think of it as |
|---|---|---|
| `Gateway` | gateway Envoy | "open port 443 for host `keycloak.example.com` using TLS secret X" — a listener. It routes nothing by itself |
| `VirtualService` | gateway and/or sidecars | "requests for host H (and path P) go to Service S port N" — the route table. Binds to a Gateway via `spec.gateways` |
| `DestinationRule` | the destination Service | connection-pool, load-balancing, outlier detection, and *client-side* TLS settings toward that Service |
| `PeerAuthentication` | namespace / workload | mTLS mode for inbound traffic to sidecars (`STRICT`, `PERMISSIVE`, `DISABLE`); can be set **per port** |
| `AuthorizationPolicy` | namespace / workload | allow/deny rules evaluated by the sidecar (Big Bang's `bb-common` generates these) |
| `ServiceEntry` | mesh | registers an external host in the mesh's service registry (needed when `outboundTrafficPolicy: REGISTRY_ONLY`, e.g. Keycloak → external LDAP/SMTP) |
| `Sidecar` | namespace | limits what config each sidecar receives (performance), rarely needed |

**Host matching.** The gateway Envoy picks a route by the HTTP `Host`/`:authority` header (or TLS SNI
for passthrough). Istio expands short names: a VirtualService host `keycloak` becomes
`keycloak.<namespace>.svc.cluster.local`, which is why `hosts: ["localhost"]` silently matches nothing
and this repo uses `"*"` on kind. In the cloud always use the FQDN.

**Readiness gates everything.** Envoy only load-balances to endpoints Kubernetes reports as ready.
A Keycloak pod whose readiness probe fails is *removed* from the Service's Endpoints → the gateway
returns `503 UH (no healthy upstream)`. So "Istio returns 503" is very often "the readiness probe is
failing" — which is why probes and routing have to be debugged together.

---

## 2. Configuring the Gateway and VirtualService

### 2.1 Gateway (edge listener)

HTTP only (this repo on kind):

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: public-ingressgateway, namespace: istio-gateway}
spec:
  selector: {istio: public-ingressgateway}   # label on the gateway *pods*, not the Service
  servers:
    - port: {number: 80, name: http, protocol: HTTP}
      hosts: ["*"]
```

Cloud, TLS terminated at the gateway (certificate from cert-manager in the **gateway namespace**):

```yaml
spec:
  selector: {istio: public-ingressgateway}
  servers:
    - port: {number: 80, name: http, protocol: HTTP}
      hosts: ["keycloak.example.com"]
      tls: {httpsRedirect: true}                      # 301 everything to https
    - port: {number: 443, name: https, protocol: HTTPS}
      hosts: ["keycloak.example.com"]
      tls:
        mode: SIMPLE
        credentialName: keycloak-example-com-tls      # kubernetes.io/tls Secret in istio-gateway ns
```

Cloud, TLS **passthrough** to Keycloak (Keycloak owns the cert; required for client-certificate / CAC
auth, this is Big Bang's `passthrough` gateway):

```yaml
    - port: {number: 443, name: tls-passthrough, protocol: TLS}
      hosts: ["keycloak.example.com"]
      tls: {mode: PASSTHROUGH}
```

Rules: `credentialName` secrets must live in the gateway's namespace; `selector` must match labels on
the gateway pods (`kubectl -n istio-gateway get pods --show-labels`); a Gateway with no matching pods
is accepted silently and routes nothing.

### 2.2 VirtualService (route)

HTTP, terminated at the gateway (this repo):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: keycloak, namespace: keycloak}
spec:
  hosts: ["keycloak.example.com"]            # "*" on kind
  gateways: ["istio-gateway/public-ingressgateway"]   # namespace/name of the Gateway
  http:
    - match: [{uri: {prefix: "/"}}]
      route:
        - destination:
            host: keycloak-keycloak-http.keycloak.svc.cluster.local
            port: {number: 80}
      timeout: 60s
      retries: {attempts: 2, perTryTimeout: 15s, retryOn: "connect-failure,refused-stream,503"}
```

Passthrough (SNI routing, no `http:` block):

```yaml
spec:
  hosts: ["keycloak.example.com"]
  gateways: ["istio-gateway/passthrough-ingressgateway"]
  tls:
    - match: [{port: 443, sniHosts: ["keycloak.example.com"]}]
      route:
        - destination: {host: keycloak-keycloak-https.keycloak.svc.cluster.local, port: {number: 8443}}
```

Same thing expressed through Big Bang's `bb-common` (what `values.yaml` has pre-filled, disabled):

```yaml
bb-common:
  istio: {enabled: true}
  routes:
    inbound:
      keycloak:
        enabled: true
        gateways: ["istio-gateway/public-ingressgateway"]
        hosts: ["keycloak.{{ .Values.global.domain }}"]
        service: keycloak-keycloak-http
        port: 80
        passthrough: {enabled: false}      # true -> SNI route on the passthrough gateway, port 8443
```

bb-common also emits the NetworkPolicy (gateway ns → pod port) and an AuthorizationPolicy, which the
hand-written VirtualService in `deploy.sh` does not — in a Big Bang cluster use the bb-common route.

### 2.3 Headers Keycloak needs from the gateway

Envoy sets `X-Forwarded-For`, `X-Forwarded-Proto` and `X-Forwarded-Host`... **not quite**: Istio's
gateway sets `X-Forwarded-For` and `X-Forwarded-Proto` but preserves the original `Host`, which is what
Keycloak needs. With `KC_PROXY_HEADERS=xforwarded` Keycloak trusts these to build its URLs
(`issuer`, redirect URIs). Verify what actually arrives with the hostname-debug page (section 6).

### 2.4 Optional DestinationRule

Only needed for mTLS-origination to Keycloak's 8443 port, or to tune pools. Example to disable sidecar
mTLS toward the management port if you ever route to it:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: {name: keycloak, namespace: keycloak}
spec:
  host: keycloak-keycloak-http.keycloak.svc.cluster.local
  trafficPolicy:
    connectionPool: {http: {http1MaxPendingRequests: 1024, http2MaxRequests: 1024}}
    outlierDetection: {consecutive5xxErrors: 5, interval: 30s, baseEjectionTime: 30s}
```

---

## 3. Keycloak health checks

### 3.1 Endpoints (Keycloak ≥ 25, management interface)

| Endpoint | Port | Meaning | Use as |
|---|---|---|---|
| `/health/started` | 9000 | server finished booting (DB schema migrated, providers loaded) | **startupProbe** |
| `/health/live` | 9000 | JVM/Quarkus process is alive | **livenessProbe** |
| `/health/ready` | 9000 | can serve requests; includes **Database** (connection pool), **Cluster** (jdbc-ping) and **Graceful shutdown** checks | **readinessProbe** |
| `/health` | 9000 | aggregate of all | dashboards only |
| `/metrics` | 9000 | Prometheus | ServiceMonitor |

Responses: `200 {"status":"UP","checks":[…]}` or `503 {"status":"DOWN","checks":[{"name":"Keycloak database connections health check","status":"DOWN"},…]}`.
The `checks[]` names tell you *which* dependency is down — always read the body, not just the code.

Requirements: `KC_HEALTH_ENABLED=true` (build-time) and `KC_METRICS_ENABLED=true` (the DB check needs
metrics). Both are rendered by the keycloakx chart from `upstream.health.enabled` /
`upstream.metrics.enabled`. The management interface inherits TLS from the main server: with
`KC_HTTPS_*` set, `:9000` is HTTPS unless `KC_HTTP_MANAGEMENT_SCHEME=http`.

### 3.2 Probe settings used in `values.yaml` and why

| Probe | Setting | Reasoning |
|---|---|---|
| startup | `/health/started`, initialDelay 30 s, period 5 s, **failureThreshold 60** (= 5 min) | first boot and every *upgrade* run Liquibase migrations; on small cloud nodes this can take minutes. Liveness is disabled until startup passes, so a long threshold is safe |
| readiness | `/health/ready`, period 10 s, failureThreshold 3 | drops the pod from the Service within ~30 s of the DB going away, re-adds it automatically |
| liveness | `/health/live`, period 15 s, failureThreshold 3, timeout 5 s | restart only on a hung JVM. **Never** point liveness at `/health/ready` — a DB blip would restart every replica |

Port is referenced **by name** (`http-internal`) so a change of `KC_HTTP_MANAGEMENT_PORT` only needs
the containerPort updated.

### 3.3 What "not Ready" looks like and what it means

| Symptom | `kubectl describe pod` shows | Cause |
|---|---|---|
| `0/1 Running`, 0 restarts, < 5 min old | `Startup probe failed: … connection refused` | still booting — normal. Watch the log for `started in …s` |
| `0/1 Running`, restarts climbing every ~5 min | `Startup probe failed` ×60 then `Killing` | boot takes longer than the threshold **or** the probe hits the wrong port/scheme/path |
| `Startup probe failed: HTTP probe failed with statuscode: 404` | — | wrong path: `KC_HTTP_MANAGEMENT_RELATIVE_PATH` / `http.managementRelativePath` doesn't match the probe path (`/auth/health/...` vs `/health/...`) |
| `… failed: … http: server gave HTTP response to HTTPS client` / `remote error: tls` | — | probe `scheme` ≠ management interface scheme (`http.internalScheme`) |
| `Readiness probe failed: HTTP probe failed with statuscode: 503` | body (via curl) has `database … DOWN` | DB unreachable / pool exhausted / wrong creds |
| `1/1 Running` but gateway gives 503 | — | Service selector / port name mismatch, or VirtualService points at wrong Service — see section 7 |
| with sidecar: `Startup probe failed: … connection refused` on `:9000` forever | — | STRICT mTLS and the probe is hitting the sidecar; exclude 9000 or let Istio rewrite probes (section 4) |

---

## 4. Running with an Istio sidecar (Big Bang / STRICT mTLS)

Kubelet probes come from the node, **not** from inside the mesh, so with STRICT mTLS a plain HTTP
probe to a sidecar-protected port is rejected. Istio solves this by rewriting `httpGet` probes to the
pilot-agent on port 15020, which forwards them to the app over localhost. This is on by default
(`sidecar.istio.io/rewriteAppHTTPProbers: "true"` or mesh-wide `values.sidecarInjectorWebhook.rewriteAppHTTPProbe`).
Check it:

```bash
kubectl -n keycloak get pod keycloak-keycloak-0 -o jsonpath='{.spec.containers[?(@.name=="keycloak")].startupProbe.httpGet}'
# rewritten:  {"path":"/app-health/keycloak/startupz","port":15020,...}
```

Alternative (what Big Bang's defaults do): keep probes direct and exclude the management port from
the sidecar — `traffic.sidecar.istio.io/excludeInboundPorts: "9000"` — or set a per-port PeerAuthentication:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: keycloak, namespace: keycloak}
spec:
  selector: {matchLabels: {app.kubernetes.io/name: keycloakx}}
  mtls: {mode: STRICT}
  portLevelMtls:
    9000: {mode: DISABLE}      # kubelet probes + Prometheus scrape
    7800: {mode: DISABLE}      # JGroups, unless KC_CACHE_EMBEDDED_MTLS_ENABLED=true
```

Also exclude/permit **7800** (JGroups cluster traffic) or enable Keycloak's own embedded mTLS, or the
replicas will never form a cluster and `/health/ready` reports the Cluster check DOWN.

---

## 5. kubectl: is Keycloak up? (run these in order)

```bash
NS=keycloak; POD=keycloak-keycloak-0; GNS=istio-gateway; GW=public-ingressgateway

# 1. pods / restarts / age
kubectl -n $NS get pods -o wide
kubectl -n $NS get sts,svc,endpoints,pvc

# 2. the probe spec the pod is actually running with (not what you think values.yaml set)
kubectl -n $NS get pod $POD -o jsonpath='{range .spec.containers[*]}{.name}{"\n  startup:   "}{.startupProbe}{"\n  readiness: "}{.readinessProbe}{"\n  liveness:  "}{.livenessProbe}{"\n"}{end}'

# 3. probe failures, in order, with the kubelet's own reason text
kubectl -n $NS describe pod $POD | sed -n '/^Events/,$p'
kubectl -n $NS get events --field-selector involvedObject.name=$POD,reason=Unhealthy --sort-by=.lastTimestamp

# 4. container state and last exit code (137 = killed by probe/OOM, 1 = Keycloak refused to start)
kubectl -n $NS get pod $POD -o jsonpath='{range .status.containerStatuses[*]}{.name}{": ready="}{.ready}{" restarts="}{.restartCount}{" state="}{.state}{" last="}{.lastState}{"\n"}{end}'

# 5. did it finish booting? (look for "started in", "Listening on", "Management interface listening on")
kubectl -n $NS logs $POD -c keycloak | grep -E "started in|Listening on|Management interface|ERROR|WARN.*hostname" | tail -20
kubectl -n $NS logs $POD -c keycloak --previous --tail=50     # only if restarts > 0

# 6. effective KC_* configuration (env + the -env Secret)
kubectl -n $NS get pod $POD -o jsonpath='{range .spec.containers[?(@.name=="keycloak")].env[*]}{.name}={.value}{"\n"}{end}' | grep ^KC_
kubectl -n $NS get secret keycloak-keycloak-env -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}' | grep -E '^KC_|^KEYCLOAK' | sed 's/PASSWORD=.*/PASSWORD=***/'

# 7. hit the health endpoints yourself, from inside the cluster, and READ THE BODY
IP=$(kubectl -n $NS get pod $POD -o jsonpath='{.status.podIP}')
kubectl -n $NS run kc-curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c "for p in started ready live; do echo \"== /health/\$p\"; curl -s -m 5 -w ' [%{http_code}]\n' http://$IP:9000/health/\$p; done; \
         echo '== /realms/master'; curl -s -m 5 -o /dev/null -w '[%{http_code}]\n' http://$IP:8080/realms/master"

# 8. same through the Service (proves selector + port mapping)
kubectl -n $NS run kc-curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://keycloak-keycloak-http.$NS.svc.cluster.local/realms/master

# 9. DB reachability from the Keycloak pod's point of view
kubectl -n $NS run pg-check --rm -it --restart=Never --image=busybox:1.37 -- nc -zv keycloak-postgresql 5432
kubectl -n $NS exec keycloak-postgresql-0 -- psql -U keycloak -d keycloak -c 'select count(*) from migration_model;'
```

Reading `/health/ready` bodies:

```
{"status":"UP","checks":[{"name":"Keycloak database connections health check","status":"UP"},
                         {"name":"Keycloak Initialized","status":"UP"}]}
{"status":"DOWN","checks":[{"name":"Keycloak database connections health check","status":"DOWN"}]}   -> DB
{"status":"DOWN","checks":[{"name":"Keycloak cluster health check","status":"DOWN"}]}                -> JGroups / 7800
{"status":"DOWN","checks":[{"name":"Keycloak Graceful shutdown","status":"DOWN"}]}                    -> pod is terminating
```

---

## 6. kubectl: hostname problems

Symptoms: admin console loads a blank page or "Keycloak is loading…"; redirects go to
`http://keycloak.dev.bigbang.mil` or to a pod IP; `invalid_redirect_uri`; OIDC `issuer` in
`/.well-known/openid-configuration` is wrong; mixed-content errors behind HTTPS.

```bash
# 1. what Keycloak thinks its URL is: the issuer must equal the public URL you use
PUB=https://keycloak.example.com          # http://localhost:8080 on kind
curl -sk $PUB/realms/master/.well-known/openid-configuration | python3 -c 'import sys,json;d=json.load(sys.stdin);print("issuer:",d["issuer"]);print("auth:",d["authorization_endpoint"]);print("token:",d["token_endpoint"])'

# 2. turn on the hostname debug page (dev/test only) and read what Keycloak derived from the request
#    values.yaml -> upstream.extraEnv: add  - {name: KC_HOSTNAME_DEBUG, value: "true"}
curl -sk $PUB/realms/master/hostname-debug           # shows hostname settings, request headers, resolved frontend/backend/admin URLs

# 3. the exact headers the gateway forwards (hostname is built from Host + X-Forwarded-Proto/Port)
kubectl -n $NS run echo --rm -it --restart=Never --image=mendhak/http-https-echo:34 --port=8080 -- true 2>/dev/null
# then temporarily point the VirtualService at the echo Service, or simply:
kubectl -n $GNS logs deploy/$GW --tail=20            # access log: authority, x-forwarded-for, upstream, response flags

# 4. common misconfigurations
kubectl -n $NS get secret keycloak-keycloak-env -o go-template='{{index .data "KC_HOSTNAME" | base64decode}}{{"\n"}}'
#   - bare hostname with a non-default public port  -> use the full URL form (https://host:port)
#   - KC_HOSTNAME=http://... but gateway terminates TLS -> https://... (and KC_PROXY_HEADERS=xforwarded)
#   - KC_HOSTNAME_STRICT=true with an unset/mismatched KC_HOSTNAME -> 403 / blank admin console
#   - KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true requires KC_HOSTNAME to be a full URL
#   - KC_HOSTNAME_ADMIN set -> admin console only on that URL; requires KC_HOSTNAME full URL
kubectl -n $NS logs $POD -c keycloak | grep -iE "hostname|proxy-headers|Possible solutions"

# 5. in-cluster callers (other services doing token introspection) with KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true
kubectl -n $NS run kc-curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://keycloak-keycloak-http.$NS.svc.cluster.local/realms/master/.well-known/openid-configuration | grep -o '"token_endpoint":"[^"]*"'
#   -> should show the in-cluster host, while the issuer stays the public one
```

---

## 7. kubectl / istioctl: Istio routing problems

```bash
# 1. config sanity — this catches 80% of VirtualService/Gateway mistakes
istioctl analyze -n $NS
istioctl analyze -n $GNS

# 2. objects
kubectl -n $GNS get gateway $GW -o yaml | sed -n '/^spec/,$p'
kubectl -n $NS  get virtualservice,destinationrule,peerauthentication,authorizationpolicy
kubectl -n $NS  get virtualservice keycloak -o yaml | sed -n '/^spec/,$p'

# 3. does the Gateway select any pods? does the Service have endpoints?
kubectl -n $GNS get pods -l istio=$GW -o wide
kubectl -n $NS  get endpoints keycloak-keycloak-http       # EMPTY = readiness failing (section 5)

# 4. what Envoy on the gateway actually programmed
GWPOD=$(kubectl -n $GNS get pod -l istio=$GW -o jsonpath='{.items[0].metadata.name}')
istioctl -n $GNS proxy-config listeners $GWPOD                      # is 0.0.0.0:8080 / :8443 there?
istioctl -n $GNS proxy-config routes    $GWPOD -o json | python3 -c 'import sys,json;[print(v["name"],"->",[d["name"] for d in v["domains"]] if False else v["domains"],"=>",[r.get("route",{}).get("cluster") for r in v["routes"]]) for l in json.load(sys.stdin) for v in l.get("virtualHosts",[])]'
istioctl -n $GNS proxy-config clusters  $GWPOD | grep keycloak      # outbound|80||keycloak-keycloak-http.keycloak.svc.cluster.local
istioctl -n $GNS proxy-config endpoints $GWPOD | grep keycloak      # HEALTHY <podIP>:8080 — if missing, endpoints are empty
istioctl -n $GNS proxy-status                                        # SYNCED for every proxy?

# 5. gateway access log: the response FLAGS column explains every 5xx
kubectl -n $GNS logs deploy/$GW --tail=50 | grep -v health
#   NR  = no route matched (host/path mismatch in VirtualService)
#   UH  = no healthy upstream (Service has no ready endpoints)
#   UF  = upstream connect failure (wrong port, NetworkPolicy, mTLS mismatch)
#   URX = retries exhausted,  UT = upstream timeout,  DC = client disconnected
#   RL  = rate limited,  UAEX = AuthorizationPolicy denied

# 6. test routing from inside the gateway pod, with an explicit Host header (bypasses DNS/LB)
kubectl -n $GNS exec deploy/$GW -- curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: keycloak.example.com' http://localhost:8080/realms/master
# 7. test from outside, forcing resolution to the LB (bypasses DNS propagation)
LB=$(kubectl -n $GNS get svc $GW -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')
curl -sk --resolve keycloak.example.com:443:$LB https://keycloak.example.com/realms/master -o /dev/null -w '%{http_code}\n'

# 8. TLS at the gateway
kubectl -n $GNS get secret keycloak-example-com-tls                  # must be in the GATEWAY namespace
istioctl -n $GNS proxy-config secret $GWPOD                          # ACTIVE / cert chain present?
openssl s_client -connect $LB:443 -servername keycloak.example.com </dev/null 2>/dev/null | openssl x509 -noout -subject -dates

# 9. mTLS / AuthorizationPolicy between gateway and keycloak (sidecar setups)
istioctl x describe pod $POD -n $NS                                  # shows VS/DR/PA/AP that apply to the pod
istioctl -n $NS proxy-config listeners $POD --port 8080 -o json | grep -i -A2 '"transportProtocol"'
kubectl -n $NS logs $POD -c istio-proxy --tail=50                    # 'RBAC: access denied' = AuthorizationPolicy
```

---

## 8. Cloud-specific wiring

| Item | kind (this repo) | Cloud |
|---|---|---|
| Gateway Service | `NodePort` 30080/30443 mapped to host 8080/8443 | `type: LoadBalancer` (+ annotations: NLB/internal, `externalTrafficPolicy: Local` to keep client IPs) |
| DNS | `localhost` | external-dns on the Gateway/Service, or a manual A/CNAME to the LB |
| TLS | none | cert-manager `Certificate` in `istio-gateway` ns → `credentialName` on the Gateway; or passthrough + `KC_HTTPS_CERTIFICATE_FILE` in the pod |
| Keycloak hostname | `KC_HOSTNAME=http://localhost:8080`, strict false | `KC_HOSTNAME=https://keycloak.example.com`, `KC_HOSTNAME_STRICT=true`, `KC_PROXY_HEADERS=xforwarded`, optionally `KC_HOSTNAME_ADMIN` on an internal-only host |
| Health exposure | `:9000` reachable in-cluster only | same; **never** route `/health` or `/metrics` through the gateway. If `KC_HTTP_MANAGEMENT_HEALTH_ENABLED=false` moves them to 8080, add a VirtualService `match` that returns 404 for `/health*` |
| Probes | direct HTTP to 9000 | same, or Istio-rewritten (section 4) |
| Internal callers | — | other workloads use `keycloak-keycloak-http.keycloak.svc` + `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` so tokens still carry the public issuer |
| Replicas | 1 | ≥2 + PodDisruptionBudget + anti-affinity; readiness must be per-pod (it is) so rolling updates never route to a booting pod |

Keycloak's `/health/ready` is the only readiness signal your LoadBalancer should care about —
configure the cloud LB health check against the gateway's own `:15021/healthz/ready`
(the istio/gateway chart exposes it as `status-port`), not against Keycloak.
