#!/usr/bin/env bash
# ==================================================
# DRIM - Deploy Script (Primera implementacion)
# ==================================================
set -Eeuo pipefail
umask 022

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-docker-compose.yml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*"; }
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
[[ -f "$DOCKER_COMPOSE_FILE" ]] || die "Compose file not found: $DOCKER_COMPOSE_FILE"
[[ -f ".env" ]] || die ".env file not found. Create one from .env.example"
command -v docker >/dev/null 2>&1 || die "Docker is not installed."

# Step 1: Start database only
log_info "=== Step 1: Levantando base de datos ==="
docker_compose -f "$DOCKER_COMPOSE_FILE" up -d drim-db

log_info "Esperando a que drim-db este healthy..."
MAX_RETRIES=60
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
  printf '[INFO]  Esperando... (intento %d/%d, estado: %s)\n' "$i" "$MAX_RETRIES" "$STATUS"
  sleep $RETRY_INTERVAL
done

# Step 2: Run migrations
log_info "=== Step 2: Ejecutando migraciones ==="
bash "$SCRIPT_DIR/migrate.sh"

# Step 3: Start all services
log_info "=== Step 3: Levantando todos los servicios ==="
docker_compose -f "$DOCKER_COMPOSE_FILE" up -d --build

log_info "Esperando 15 segundos para estabilizacion..."
sleep 15

# Status
log_info "=== Estado de contenedores ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-127.0.0.1}"

log_info "Deploy completado exitosamente."
printf '\n  Frontend: http://%s:8089\n' "$SERVER_IP"
printf '  API DRIM: http://%s:8090\n' "$SERVER_IP"
printf '  API PM:   http://%s:8091\n\n' "$SERVER_IP"