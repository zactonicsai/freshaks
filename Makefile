# Shortcuts. Every target just calls a script — read the script to see what happens.
.PHONY: check cluster nodes postgres ldap keycloak realm images deploy test status destroy destroy-keep all

check:     ; tools/local-check.sh
cluster:   ; scripts/01-create-cluster.sh
nodes:     ; scripts/02-setup-nodes.sh
postgres:  ; scripts/03-install-postgres.sh
ldap:      ; scripts/04-install-openldap.sh
keycloak:  ; scripts/05-install-keycloak.sh
realm:     ; scripts/06-configure-realm.sh
images:    ; scripts/07-build-images.sh
deploy:    ; scripts/08-deploy-apps.sh
test:      ; scripts/09-run-tests.sh
status:    ; scripts/10-status.sh
destroy:   ; scripts/99-destroy.sh
destroy-keep: ; scripts/99-destroy.sh --keep-cluster
all: cluster nodes postgres ldap keycloak realm images deploy test status
