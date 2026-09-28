#!/bin/bash
# Runs ONCE, the very first time the Postgres data disk is empty.
# It creates one database + user for Keycloak and one for the grocery apps.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
  CREATE USER keycloak WITH PASSWORD '$KC_DB_PASSWORD';
  CREATE DATABASE keycloak OWNER keycloak;
  CREATE USER grocery WITH PASSWORD '$APP_DB_PASSWORD';
  CREATE DATABASE grocery OWNER grocery;
EOSQL
echo "databases keycloak + grocery created"
