Here's the full setup. I'm using two charts, `istio` and `codecentric/keycloakx` (which uses the official Keycloak image), and plain kubectl manifests for Postgres with the official `postgres` image. I'm avoiding the Bitnami charts because Bitnami moved most of its free images behind a paywall in 2025, so those charts often fail to pull images now.

The design works like this:
- The `db` namespace has no Istio label, so the Postgres pod gets no sidecar.
- The `keycloak` namespace also has no label. Only the Keycloak pod opts in, using the pod label `sidecar.istio.io/inject: "true"`.
- Ingress goes through the Istio ingress gateway: localhost:8080 → NodePort 30080 → Keycloak.
- Egress is handled by an Istio `Sidecar` resource. It locks the Keycloak pod to REGISTRY_ONLY and lets it reach only Postgres.
- Every username and password is admin / admin, for both the Keycloak admin and the database.

## Step 1: Recreate the kind cluster with a port mapping

The gateway needs a host port, and kind can only add port mappings when a cluster is created. Save this as `kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
```

```bash
kind delete cluster --name mycluster
kind create cluster --name mycluster --config kind-config.yaml
kubectl config use-context kind-mycluster
```

## Step 2: Download the Helm charts locally

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo add codecentric https://codecentric.github.io/helm-charts
helm repo update

mkdir charts
helm pull istio/base          --untar --untardir charts
helm pull istio/istiod        --untar --untardir charts
helm pull istio/gateway       --untar --untardir charts
helm pull codecentric/keycloakx --untar --untardir charts
```

You now have `charts/base`, `charts/istiod`, `charts/gateway` and `charts/keycloakx` on disk. Every install below uses these local folders.

## Step 3: Install Istio from the local charts

```bash
kubectl create namespace istio-system
helm install istio-base ./charts/base -n istio-system --wait
helm install istiod ./charts/istiod -n istio-system --wait
```

Save the following as `gateway-values.yaml`:

```yaml
service:
  type: NodePort
  ports:
    - name: status-port
      port: 15021
      targetPort: 15021
    - name: http2
      port: 80
      targetPort: 80
      nodePort: 30080
```

```bash
kubectl create namespace istio-ingress
helm install istio-ingressgateway ./charts/gateway -n istio-ingress -f gateway-values.yaml --wait
```

## Step 4: Deploy Postgres with kubectl (no sidecar)

Save this as `postgres.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: db
stringData:
  POSTGRES_USER: admin
  POSTGRES_PASSWORD: admin
  POSTGRES_DB: keycloak
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: db
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgres-secret
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "admin", "-d", "keycloak"]
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: db
spec:
  selector:
    app: postgres
  ports:
    - name: tcp-postgres
      port: 5432
      targetPort: 5432
```

The port name `tcp-postgres` matters. It tells Istio to treat the connection as raw TCP, because Postgres is a server-first protocol and protocol sniffing breaks it.

```bash
kubectl apply -f postgres.yaml
kubectl rollout status deployment/postgres -n db
```

## Step 5: Install Keycloak from the local chart (sidecar on this pod only)

Save this as `keycloak-values.yaml`:

```yaml
command:
  - "/opt/keycloak/bin/kc.sh"
  - "start"
  - "--http-enabled=true"
  - "--http-port=8080"
  - "--hostname-strict=false"
  - "--proxy-headers=xforwarded"
  - "--health-enabled=true"
  - "--cache=local"

http:
  relativePath: "/"

database:
  vendor: postgres
  hostname: postgres.db.svc.cluster.local
  port: 5432
  database: keycloak
  username: admin
  password: admin

extraEnv: |
  - name: KC_BOOTSTRAP_ADMIN_USERNAME
    value: admin
  - name: KC_BOOTSTRAP_ADMIN_PASSWORD
    value: admin

podLabels:
  app: keycloak
  sidecar.istio.io/inject: "true"

podAnnotations:
  proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
```

Here's what the key settings do:
- `sidecar.istio.io/inject` puts the sidecar on this pod only.
- `holdApplicationUntilProxyStarts` stops Keycloak from trying to reach Postgres before the sidecar is ready.
- `--cache=local` keeps a single replica from needing cluster discovery traffic.
- `KC_BOOTSTRAP_ADMIN_*` creates admin/admin on first startup. This works with Keycloak 26+. Older versions used `KEYCLOAK_ADMIN` and `KEYCLOAK_ADMIN_PASSWORD` instead.

```bash
kubectl create namespace keycloak
helm install keycloak ./charts/keycloakx -n keycloak -f keycloak-values.yaml
```

## Step 6: Istio ingress and egress rules for Keycloak

Save this as `keycloak-istio.yaml`:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: keycloak-gateway
  namespace: keycloak
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: keycloak
  namespace: keycloak
spec:
  hosts:
    - "*"
  gateways:
    - keycloak-gateway
  http:
    - route:
        - destination:
            host: keycloak-keycloakx-http.keycloak.svc.cluster.local
            port:
              number: 80
---
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: keycloak-egress
  namespace: keycloak
spec:
  workloadSelector:
    labels:
      app: keycloak
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
  egress:
    - hosts:
        - "db/postgres.db.svc.cluster.local"
        - "istio-system/*"
```

The `Sidecar` resource is the egress control. The Keycloak pod can only reach Postgres and the Istio control plane, and anything else outbound is blocked.

First confirm the Keycloak service name, because the VirtualService has to match it:

```bash
kubectl get svc -n keycloak
```

The service should be `keycloak-keycloakx-http` on port 80. If yours has a different name, edit the `host:` line in the VirtualService. Then apply the rules:

```bash
kubectl apply -f keycloak-istio.yaml
```

## Step 7: Verify

```bash
kubectl get pods -n db         # postgres   1/1  (no sidecar)
kubectl get pods -n keycloak   # keycloak   2/2  (keycloak + istio-proxy)
kubectl logs -n keycloak keycloak-keycloakx-0 -c keycloak | grep -i -E "postgres|started|admin"
```

Then open http://localhost:8080 and log in with admin / admin.

## Troubleshooting

- **Keycloak shows `1/1` instead of `2/2`:** the sidecar wasn't injected. Run `kubectl get pod keycloak-keycloakx-0 -n keycloak --show-labels` to check the label, and make sure istiod was running before you installed Keycloak.
- **Database connection errors in the Keycloak logs:** first check that Postgres is ready. Then check that the service port name is `tcp-postgres`, and that the Sidecar's `hosts` entry matches `db/postgres.db.svc.cluster.local`.
- **Pod stuck restarting:** Keycloak takes 1–2 minutes to build on first start, and the probes can kill it before it's done. Watch the logs with `kubectl logs -f ... -c keycloak`.

If you later want Keycloak to reach something outside the cluster, such as an external identity provider, add a `ServiceEntry` for that host and list it in the Sidecar's `egress.hosts`. Otherwise REGISTRY_ONLY blocks it.