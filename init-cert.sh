#!/usr/bin/env bash
# Emite el primer certificado de Let's Encrypt para la IP pública de la VM (perfil
# shortlived, ~6 días) y levanta el stack con nginx. Después lo renueva solo el servicio
# certbot. Solo hace falta correrlo una vez, o si se borra certbot/.
# Uso: ./init-cert.sh [--staging]
set -euo pipefail

cd "$(dirname "$0")"

COMPOSE_FILE="docker-compose.prod.yml"

# Solo las variables que hacen falta: .env tiene valores con & sin comillas y no se
# puede cargar con source
env_value() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2-; }
PUBLIC_IP="$(env_value PUBLIC_IP)"
CERTBOT_EMAIL="$(env_value CERTBOT_EMAIL)"

: "${PUBLIC_IP:?PUBLIC_IP falta en .env}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL falta en .env}"

STAGING=()
if [[ "${1:-}" == "--staging" ]]; then
  STAGING=(--staging)
fi

mkdir -p certbot/conf certbot/www

# certbot --standalone necesita el puerto 80 libre
echo "==> Bajando nginx y syner-app para liberar el puerto 80"
docker compose -f "$COMPOSE_FILE" --profile https stop nginx syner-app 2>/dev/null || true

echo "==> Emitiendo el certificado para $PUBLIC_IP"
docker compose -f "$COMPOSE_FILE" --profile https run --rm -p 80:80 --entrypoint certbot certbot \
  certonly --standalone \
  --cert-name syner \
  --ip-address "$PUBLIC_IP" \
  --preferred-profile shortlived \
  --email "$CERTBOT_EMAIL" --agree-tos --no-eff-email \
  --non-interactive "${STAGING[@]}"

echo "==> Levantando el stack con nginx"
docker compose -f "$COMPOSE_FILE" --profile https up -d

echo "==> Listo: https://$PUBLIC_IP"
