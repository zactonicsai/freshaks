#!/usr/bin/env bash
# =============================================================================
# install-all.sh — run every install step in order (about 25 to 35 minutes).
# Each step is its own script with its own log file; if one fails, fix the
# cause and run install-all.sh again: finished steps are safe to repeat.
# Usage: ./scripts/install/install-all.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# --- Tools and Azure sign-in ---------------------------------------------------
# Check that az, kubectl, helm, openssl, curl (and docker) are installed.
run_script install/00-check-prereqs.sh
# Sign in, select the subscription, register providers, check quota.
run_script install/01-azure-login.sh

# --- Azure resources -----------------------------------------------------------
# Resource group that holds everything.
run_script install/02-create-resource-group.sh
# Container registry for the application images.
run_script install/03-create-acr.sh
# Static, zone-redundant public IP for the ingress gateway.
run_script install/04-create-public-ip.sh
# AKS cluster with the old Kubernetes version and a three-zone system pool.
run_script install/05-create-aks-cluster.sh
# Three-zone user pool for the workloads.
run_script install/06-add-user-nodepool.sh
# Let the cluster use the static public IP.
run_script install/07-grant-network-role.sh
# Download the kubeconfig into the project folder.
run_script install/08-get-credentials.sh

# --- Cluster basics ------------------------------------------------------------
# Namespaces (with the Istio injection label where needed).
run_script install/09-create-namespaces.sh
# NFS server pod (or Azure Files) and the two shared volumes.
run_script install/10-install-nfs-storage.sh

# --- Istio (old version) ---------------------------------------------------------
# CRDs.
run_script install/11-install-istio-base.sh
# Control plane, two replicas.
run_script install/12-install-istiod.sh
# Revision tag "stable".
run_script install/13-set-revision-tag.sh
# Private CA and wildcard certificate.
run_script install/14-create-tls-certificate.sh
# Ingress gateway behind the static public IP.
run_script install/15-install-ingress-gateway.sh
# Egress gateway.
run_script install/16-install-egress-gateway.sh
# mTLS, authorization rules, allowed egress host.
run_script install/17-apply-mesh-policies.sh

# --- Workloads (old versions) ----------------------------------------------------
# Passwords and Kubernetes secrets.
run_script install/18-create-secrets.sh
# PostgreSQL on NFS storage.
run_script install/19-install-postgres.sh
# Keycloak, two pods, realm "demo" with test users.
run_script install/20-install-keycloak.sh
# Build and push the two application images.
run_script install/21-build-push-images.sh "${APP_VERSION_OLD}"
# Deploy the two applications, two pods each.
run_script install/22-deploy-apps.sh
# Gateway, VirtualServices, DestinationRules.
run_script install/23-apply-routing.sh

# --- Checks ----------------------------------------------------------------------
# Public endpoints, redirects, access rules.
run_script install/24-smoke-test.sh
# Full OIDC login with a test user, single sign-on, shared notes, egress.
run_script tools/test-login.sh
# Print the URLs and the test logins.
run_script tools/show-urls.sh
