#!/bin/sh
# Runs once, when a Postgres container (orders-db, products-db) initializes an empty data
# directory (/docker-entrypoint-initdb.d). It creates the role the microservice connects
# with: not a superuser and without BYPASSRLS, so the tenant_isolation RLS policies apply to
# it. Migrations keep running as POSTGRES_USER, which owns the tables; the default
# privileges below give the app role CRUD on every table and sequence it creates later.
# An existing data directory is never touched: to apply this, start from an empty one
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v owner="$POSTGRES_USER" -v app_user="$APP_DB_USER" -v app_password="$APP_DB_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";
SQL
