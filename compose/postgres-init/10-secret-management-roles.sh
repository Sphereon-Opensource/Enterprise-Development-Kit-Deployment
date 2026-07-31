#!/usr/bin/env sh
set -eu

if [ -z "${SECRET_MANAGEMENT_ADMIN_DB_PASSWORD:-}" ]; then
  echo "SECRET_MANAGEMENT_ADMIN_DB_PASSWORD is required" >&2
  exit 1
fi
if [ -z "${SECRET_MANAGEMENT_TENANT_DB_PASSWORD:-}" ]; then
  echo "SECRET_MANAGEMENT_TENANT_DB_PASSWORD is required" >&2
  exit 1
fi

psql \
  --set=ON_ERROR_STOP=1 \
  --set=admin_password="${SECRET_MANAGEMENT_ADMIN_DB_PASSWORD}" \
  --set=tenant_password="${SECRET_MANAGEMENT_TENANT_DB_PASSWORD}" \
  --username "${POSTGRES_USER}" \
  --dbname "${POSTGRES_DB}" <<'SQL'
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

ALTER ROLE secret_management_admin
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS
  PASSWORD :'admin_password';
ALTER ROLE secret_management_tenant_serving
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS
  PASSWORD :'tenant_password';

GRANT CONNECT ON DATABASE :"DBNAME"
  TO secret_management_admin, secret_management_tenant_serving;
GRANT USAGE ON SCHEMA public
  TO secret_management_admin, secret_management_tenant_serving;
SQL
