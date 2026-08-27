#!/usr/bin/env sh
set -eu

marker=${PGDATA:-/var/lib/postgresql/data}/.edk-secret-management-roles-ready

pg_isready --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" >/dev/null 2>&1 || exit 1
[ -f "$marker" ] && exit 0

if [ -z "${SECRET_MANAGEMENT_ADMIN_DB_PASSWORD:-}" ]; then
  echo "SECRET_MANAGEMENT_ADMIN_DB_PASSWORD is required" >&2
  exit 1
fi
if [ -z "${SECRET_MANAGEMENT_TENANT_DB_PASSWORD:-}" ]; then
  echo "SECRET_MANAGEMENT_TENANT_DB_PASSWORD is required" >&2
  exit 1
fi
if [ -z "${SECRET_MANAGEMENT_RUNTIME_DB_PASSWORD:-}" ]; then
  echo "SECRET_MANAGEMENT_RUNTIME_DB_PASSWORD is required" >&2
  exit 1
fi

psql \
  --set=ON_ERROR_STOP=1 \
  --set=admin_password="${SECRET_MANAGEMENT_ADMIN_DB_PASSWORD}" \
  --set=tenant_password="${SECRET_MANAGEMENT_TENANT_DB_PASSWORD}" \
  --set=runtime_password="${SECRET_MANAGEMENT_RUNTIME_DB_PASSWORD}" \
  --username "${POSTGRES_USER}" \
  --dbname "${POSTGRES_DB}" <<'SQL'
BEGIN;
SELECT pg_advisory_xact_lock(755624362, 20250802);
SELECT format(
  'CREATE ROLE secret_management_admin LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS PASSWORD %L',
  :'admin_password'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'secret_management_admin'
)
\gexec

SELECT format(
  'CREATE ROLE secret_management_tenant_serving LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS PASSWORD %L',
  :'tenant_password'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'secret_management_tenant_serving'
)
\gexec

SELECT format(
  'CREATE ROLE secret_management_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS PASSWORD %L',
  :'runtime_password'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'secret_management_runtime'
)
\gexec

ALTER ROLE secret_management_admin
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS
  PASSWORD :'admin_password';
ALTER ROLE secret_management_tenant_serving
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS
  PASSWORD :'tenant_password';
ALTER ROLE secret_management_runtime
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS
  PASSWORD :'runtime_password';

GRANT CONNECT ON DATABASE :"DBNAME"
  TO secret_management_admin, secret_management_tenant_serving, secret_management_runtime;
GRANT USAGE ON SCHEMA public
  TO secret_management_admin, secret_management_tenant_serving, secret_management_runtime;
COMMIT;
SQL

: > "$marker"
