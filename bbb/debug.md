**Prefer the simple path first (no image changes). Use environment variables for logging + Kubernetes HTTP probes for health/endpoint verification.** Wrapping `kc.sh` is only needed for extra custom logic, and you can do that without rebuilding the image by mounting a script.

### 1. Debug / Error Logging (no wrapper required)

Keycloak (Quarkus distribution) exposes logging via environment variables:

```yaml
env:
  - name: KC_LOG_LEVEL
    value: "DEBUG"          # or "INFO,org.keycloak:DEBUG,org.hibernate:INFO" etc.
  - name: KC_LOG_CONSOLE_LEVEL
    value: "DEBUG"          # controls console handler specifically
  # Optional remote Java debug (recent versions)
  - name: KC_DEBUG
    value: "true"
  - name: KC_DEBUG_PORT
    value: "8787"
  - name: KC_VERBOSE
    value: "true"
```

These map to the `--log-level` / console settings. Restart the pod and check `kubectl logs`. For more fine-grained control you can also use category-specific vars (`KC_LOG_LEVEL_ORG_KEYCLOAK=DEBUG`).

### 2. Verify Keycloak is up and endpoints work (recommended: K8s probes)

Official docs recommend **HTTP probes** (kubelet does the HTTP GET from outside the container). This works even when the pod is hardened and has no `curl`/`wget`/network tools.

Enable health endpoints:

```yaml
env:
  - name: KC_HEALTH_ENABLED
    value: "true"
  # Optional: KC_METRICS_ENABLED=true
```

Note: `health-enabled` is a build-time option. On a non-optimized image it is applied at start. For fully optimized production images (`start --optimized`) you usually need it baked in via `kc.sh build --health-enabled=true` (which does require a custom image).

Example probes (management port is **9000** by default in modern Keycloak):

```yaml
ports:
  - name: management
    containerPort: 9000
startupProbe:
  httpGet:
    path: /health/started
    port: 9000
    scheme: HTTP          # use HTTPS if you forced TLS on management
  failureThreshold: 60    # generous for slow starts
  periodSeconds: 5
  timeoutSeconds: 5
readinessProbe:
  httpGet:
    path: /health/ready
    port: 9000
    scheme: HTTP
  periodSeconds: 10
  failureThreshold: 3
livenessProbe:
  httpGet:
    path: /health/live
    port: 9000
    scheme: HTTP
  periodSeconds: 20
  failureThreshold: 3
```

Endpoints:
- `/health/started` – startup probe
- `/health/ready` – ready to serve traffic
- `/health/live` – process is alive
- `/health` – overall

If you use a relative path (`KC_HTTP_RELATIVE_PATH` or management relative path) adjust the probe paths accordingly. Probes failing show up in `kubectl describe pod` events and logs.

### 3. Wrapping `kc.sh` without modifying the image

If you still want a wrapper (extra pre-start logic, custom log lines, or an internal health wait), mount a script via ConfigMap and override the command. Official images have a shell and the entrypoint is `/opt/keycloak/bin/kc.sh`.

**ConfigMap example:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-wrapper
data:
  entrypoint.sh: |
    #!/bin/bash
    set -e
    echo "=== Keycloak wrapper starting ==="
    echo "Log level: ${KC_LOG_LEVEL:-default}"
    # Optional: pure-bash health wait after start (no curl needed)
    # background the real process then poll
    /opt/keycloak/bin/kc.sh "$@" &
    KC_PID=$!
    # Simple /dev/tcp check (bash feature, works on most images)
    for i in {1..60}; do
      if { echo -e 'HEAD /health/ready HTTP/1.0\r\n\r\n' >&0; } 0<>/dev/tcp/127.0.0.1/9000 2>/dev/null; then
        echo "Health endpoint responded"
        break
      fi
      sleep 5
    done
    wait $KC_PID
```

**In the Deployment container:**
```yaml
command: ["/bin/bash", "/opt/wrapper/entrypoint.sh"]
args: ["start"]   # or start-dev, start --optimized, etc.
volumeMounts:
  - name: wrapper
    mountPath: /opt/wrapper
volumes:
  - name: wrapper
    configMap:
      name: keycloak-wrapper
      defaultMode: 0755
```

**Critical**: use `exec` in the wrapper (or the background + wait pattern carefully) so Keycloak receives signals properly and becomes the main process. The official docs show the pure-bash `/dev/tcp` pattern exactly for this reason (no curl in the hardened image).

### When to modify the image
- You need an optimized production image with health/metrics permanently enabled.
- You want `curl` or other tools permanently.
- You want a permanent custom entrypoint.
- Ultra-hardened / distroless images that have no shell at all.

For most debug and verification needs, **env vars + Kubernetes probes** are sufficient, simpler, and stay compatible with the hardened image. Start there, then add a mounted wrapper only if you need extra logic.
