#!/usr/bin/env sh
# Creates the dedicated Keycloak role and database on platform-postgres. Runs from
# /docker-entrypoint-initdb.d on first initialisation of the data volume, so an
# existing project must be reset (down --volumes) before the Keycloak overlay is
# added; every statement is idempotent so a re-run is harmless.
set -eu

if [ -z "${KEYCLOAK_DB_PASSWORD:-}" ]; then
  echo "KEYCLOAK_DB_PASSWORD is required" >&2
  exit 1
fi

psql \
  --set=ON_ERROR_STOP=1 \
  --set=keycloak_password="${KEYCLOAK_DB_PASSWORD}" \
  --username "${POSTGRES_USER}" \
  --dbname "${POSTGRES_DB}" <<'SQL'
SELECT format(
  'CREATE ROLE keycloak LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L',
  :'keycloak_password'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'keycloak'
)
\gexec

ALTER ROLE keycloak
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD :'keycloak_password';

SELECT 'CREATE DATABASE keycloak OWNER keycloak'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_catalog.pg_database WHERE datname = 'keycloak'
)
\gexec

-- Keycloak owns its database outright. The secret-management roles are never
-- admitted to it and the keycloak role never reaches the platform database.
REVOKE CONNECT ON DATABASE keycloak FROM PUBLIC;
GRANT CONNECT ON DATABASE keycloak TO keycloak;
SQL
