cat > keycloak-dev-values.yaml <<'EOF'
command:
  - "/opt/keycloak/bin/kc.sh"
  - "start-dev"
  - "--http-port=8080"
  - "--hostname-strict=false"

extraEnv: |
  - name: KC_BOOTSTRAP_ADMIN_USERNAME
    value: admin
  - name: KC_BOOTSTRAP_ADMIN_PASSWORD
    value: admin
  - name: KEYCLOAK_ADMIN
    value: admin
  - name: KEYCLOAK_ADMIN_PASSWORD
    value: admin
  - name: KC_HOSTNAME
    value: localhost
  - name: KC_HOSTNAME_PORT
    value: "8080"
  - name: JAVA_OPTS_APPEND
    value: -Djgroups.dns.query=keycloak-keycloakx-headless

http:
  httpEnabled: true

service:
  type: ClusterIP
EOF

helm upgrade --install keycloak codecentric/keycloakx \
  --namespace "$NS" \
  --create-namespace \
  -f keycloak-dev-values.yaml


  a port-forwarding with the following commands:

export POD_NAME=$(kubectl get pods --namespace keycloak -l "app.kubernetes.io/name=keycloakx,app.kubernetes.io/instance=keycloak" -o name)
echo "Visit http://127.0.0.1:8080 to use your application"
kubectl --namespace keycloak port-forward "$POD_NAME" 8080