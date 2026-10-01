#!/usr/bin/env bash
# Construye las imágenes de producción servicio por servicio y levanta el stack.
# Uso: ./build-prod.sh [--no-up]
set -euo pipefail

cd "$(dirname "$0")"

COMPOSE_FILE="docker-compose.prod.yml"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

SERVICES=(
  auth-migrate
  auth-ms
  products-migrate
  products-ms
  orders-migrate
  orders-ms
  finance-migrate
  finance-ms
  client-gateway
)

build_service() {
  local service="$1"
  local attempt
  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    echo "==> [$service] build (intento $attempt/$MAX_ATTEMPTS)"
    if docker compose -f "$COMPOSE_FILE" build "$service"; then
      echo "==> [$service] OK"
      return 0
    fi
    echo "==> [$service] falló"
  done
  return 1
}

for service in "${SERVICES[@]}"; do
  if ! build_service "$service"; then
    echo "ERROR: no se pudo construir $service después de $MAX_ATTEMPTS intentos" >&2
    exit 1
  fi
done

if [[ "${1:-}" == "--no-up" ]]; then
  echo "==> Build terminado (sin levantar el stack)"
  exit 0
fi

echo "==> docker compose -f $COMPOSE_FILE up -d"
docker compose -f "$COMPOSE_FILE" up -d
