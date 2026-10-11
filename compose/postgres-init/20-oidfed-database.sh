#!/usr/bin/env sh
# Creates the OpenID Federation library's own database on the tenant PostgreSQL server with two roles. `oidfed` owns
# the schema; the platform connects with it and applies the library's migrations. `oidfed_runtime` may only read and
# write data; the tenant authorization server connects with it and verifies the schema instead of migrating it.
# Idempotent. Init scripts run only on a fresh volume; run this script manually for an existing volume.
# docker compose -f docker-compose.yml -f docker-compose.gateway.yml -f docker-compose.federation.yml exec tenant-postgres sh /docker-entrypoint-initdb.d/20-oidfed-database.sh
set -eu

pg_isready --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" >/dev/null 2>&1 || exit 1

if [ -z "${OIDFED_DB_PASSWORD:-}" ] || [ -z "${OIDFED_RUNTIME_DB_PASSWORD:-}" ]; then
  echo "OIDFED_DB_PASSWORD and OIDFED_RUNTIME_DB_PASSWORD are required" >&2
  exit 1
fi

psql --set=ON_ERROR_STOP=1 --set=oidfed_password="${OIDFED_DB_PASSWORD}" \
  --set=runtime_password="${OIDFED_RUNTIME_DB_PASSWORD}" \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
SELECT format('CREATE ROLE oidfed LOGIN PASSWORD %L', :'oidfed_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'oidfed') \gexec
SELECT format('CREATE ROLE oidfed_runtime LOGIN PASSWORD %L', :'runtime_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'oidfed_runtime') \gexec
SELECT 'CREATE DATABASE oidfed OWNER oidfed'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'oidfed') \gexec
SQL

# Data privileges for the runtime role, on the tables that exist and on every table the owner creates later.
psql --set=ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname oidfed <<'SQL'
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE oidfed TO oidfed_runtime;
GRANT USAGE ON SCHEMA public TO oidfed_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO oidfed_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO oidfed_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE oidfed IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO oidfed_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE oidfed IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO oidfed_runtime;
SQL
