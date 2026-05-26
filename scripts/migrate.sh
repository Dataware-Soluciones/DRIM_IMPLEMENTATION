#!/usr/bin/env bash
# ==================================================
# DRIM - Migration Script
# ==================================================
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-docker-compose.yml}"
NETWORK_NAME="${NETWORK_NAME:-drim-network}"

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "docker compose is not available."
  fi
}

cd "$INSTALL_DIR"
[[ -f "$DOCKER_COMPOSE_FILE" ]] || die "Compose file not found: $INSTALL_DIR/$DOCKER_COMPOSE_FILE"
[[ -f ".env" ]] || die ".env file not found in $INSTALL_DIR"

# Source .env
set -a
source .env
set +a

# Wait for DB
log_info "Verificando que drim-db este healthy..."
MAX_RETRIES=30
RETRY_INTERVAL=5
for i in $(seq 1 $MAX_RETRIES); do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' drim-db 2>/dev/null || echo "not_found")
  if [[ "$STATUS" == "healthy" ]]; then
    log_info "drim-db esta healthy."
    break
  fi
  if [[ $i -eq $MAX_RETRIES ]]; then
    die "drim-db no alcanzo estado healthy despues de $((MAX_RETRIES * RETRY_INTERVAL)) segundos."
  fi
  printf '[INFO]  Esperando a drim-db... (intento %d/%d, estado: %s)\n' "$i" "$MAX_RETRIES" "$STATUS"
  sleep $RETRY_INTERVAL
done

# DRIMBack migrations
log_info "Ejecutando migraciones de DRIMBack..."
docker run --rm \
  --network "${NETWORK_NAME}" \
  -e DB_HOST="drim-db" \
  -e DB_NAME="${DB_NAME:-DRIM}" \
  -e DB_USER="sa" \
  -e DB_PASSWORD="${DB_PASSWORD}" \
  -e FRONT_URL="${FRONT_URL}" \
  -e ASPNETCORE_ENVIRONMENT="Production" \
  datawaresit/drim-back:latest \
  dotnet DRIMBack.dll --migrate-only

if [[ $? -ne 0 ]]; then
  die "Fallo la migracion de DRIMBack."
fi
log_info "Migraciones de DRIMBack completadas."

# PM_Printer_API migrations
log_info "Ejecutando migraciones de PM_Printer_API..."
docker run --rm \
  --network "${NETWORK_NAME}" \
  -e DB_HOST="drim-db" \
  -e DB_NAME="${PM_DB_NAME:-PM_API}" \
  -e DB_USER="sa" \
  -e DB_PASSWORD="${DB_PASSWORD}" \
  -e FRONT_URL="${FRONT_URL}" \
  -e ASPNETCORE_ENVIRONMENT="Production" \
  datawaresit/drim-pm:latest \
  dotnet PM_Printer_API.dll --migrate-only

if [[ $? -ne 0 ]]; then
  die "Fallo la migracion de PM_Printer_API."
fi
log_info "Migraciones de PM_Printer_API completadas."

log_info "Todas las migraciones ejecutadas exitosamente."