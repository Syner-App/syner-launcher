#!/usr/bin/env bash
# Creates or updates every Secret the syner chart reads, from the root .env (the same
# values docker-compose.prod.yml uses). Idempotent: run it again after changing .env.
# It never prints the values. docker-hub-key (image pulls) is managed separately
set -euo pipefail

ENV_FILE="${1:-$(cd "$(dirname "$0")/.." && pwd)/.env}"
[ -f "$ENV_FILE" ] || { echo "No existe $ENV_FILE" >&2; exit 1; }

# Parsed instead of sourced: values such as AUTH_DATABASE_URL contain '&'
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  key="${line%%=*}"
  value="${line#*=}"
  value="${value%\"}"; value="${value#\"}"
  export "$key=$value"
done < "$ENV_FILE"

# kubectl create --dry-run | apply: creates the Secret or updates it in place
apply_secret() {
  local name="$1"; shift
  kubectl create secret generic "$name" "$@" --dry-run=client -o yaml | kubectl apply -f -
}

# Postgres: <x>-db for the StatefulSet, <x>-ms for the microservice and its migration Job.
# DATABASE_URL uses the app role (RLS applies); MIGRATE_DATABASE_URL the table owner
for db in products orders finance; do
  prefix=$(echo "$db" | tr '[:lower:]' '[:upper:]')_DB
  user_var="${prefix}_USER"; pass_var="${prefix}_PASSWORD"; name_var="${prefix}_NAME"
  app_user_var="${prefix}_APP_USER"; app_pass_var="${prefix}_APP_PASSWORD"
  user="${!user_var}"; pass="${!pass_var}"; name="${!name_var}"
  app_user="${!app_user_var}"; app_pass="${!app_pass_var}"
  host="$db-db:5432"

  apply_secret "$db-db" \
    --from-literal=POSTGRES_USER="$user" \
    --from-literal=POSTGRES_PASSWORD="$pass" \
    --from-literal=POSTGRES_DB="$name" \
    --from-literal=APP_DB_USER="$app_user" \
    --from-literal=APP_DB_PASSWORD="$app_pass"

  apply_secret "$db-ms" \
    --from-literal=DATABASE_URL="postgresql://$app_user:$app_pass@$host/$name?schema=public" \
    --from-literal=MIGRATE_DATABASE_URL="postgresql://$user:$pass@$host/$name?schema=public" \
    --from-literal=RABBITMQ_URL="$RABBITMQ_URL"
done

apply_secret auth-secrets \
  --from-literal=DATABASE_URL="$AUTH_DATABASE_URL" \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --from-literal=SUPERADMIN_NAME="$SUPERADMIN_NAME" \
  --from-literal=SUPERADMIN_EMAIL="$SUPERADMIN_EMAIL" \
  --from-literal=SUPERADMIN_PASSWORD="$SUPERADMIN_PASSWORD"

apply_secret client-gateway \
  --from-literal=RABBITMQ_URL="$RABBITMQ_URL"
