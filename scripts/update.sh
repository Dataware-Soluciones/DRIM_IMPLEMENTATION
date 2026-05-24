#!/usr/bin/env bash
# ==================================================
# DRIM - Update Script (Zero downtime de BD)
# ==================================================
set -Eeuo pipefail
umask 022

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-docker-compose.yml}"
FRONT_ZIP_NAME="${FRONT_ZIP_NAME:-DRIMFront.zip}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRUNE_MODE="${PRUNE_MODE:-safe}"

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
[[ -f ".env" ]] || die ".env file not found in $INSTALL_DIR"
command -v docker >/dev/null 2>&1 || die "Docker is not installed."

# Step 1: Pull new images
log_info "=== Step 1: Descargando imagenes actualizadas ==="
docker_compose -f "$DOCKER_COMPOSE_FILE" pull drim-api pm-api || log_warn "No se pudieron descargar algunas imagenes. Continuando con las locales."

# Step 2: Update frontend source (if zip exists)
if [[ -f "$FRONT_ZIP_NAME" ]]; then
  log_info "=== Step 2: Actualizando frontend ==="
  rm -rf frontend
  mkdir -p frontend
  unzip -o "$FRONT_ZIP_NAME" -d frontend
else
  log_warn "Frontend zip no encontrado ($FRONT_ZIP_NAME). Se usara el frontend existente."
fi

# Step 3: Stop application services (DB stays running)
log_info "=== Step 3: Deteniendo servicios de aplicacion (BD sigue activa) ==="
docker_compose -f "$DOCKER_COMPOSE_FILE" stop drim-api pm-api drim-front
docker_compose -f "$DOCKER_COMPOSE_FILE" rm -f drim-api pm-api drim-front

# Step 4: Verify DB is still healthy
log_info "=== Step 4: Verificando que drim-db siga healthy ==="
STATUS=$(docker inspect --format='{{.State.Health.Status}}' drim-db 2>/dev/null || echo "not_found")
if [[ "$STATUS" != "healthy" ]]; then
  log_warn "drim-db no esta healthy (estado: $STATUS). Esperando..."
  for i in $(seq 1 30); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' drim-db 2>/dev/null || echo "not_found")
    [[ "$STATUS" == "healthy" ]] && break
    sleep 5
  done
  [[ "$STATUS" != "healthy" ]] && die "drim-db no esta healthy. Abortando."
fi
log_info "drim-db esta healthy."

# Step 5: Run migrations
log_info "=== Step 5: Ejecutando migraciones ==="
bash "$SCRIPT_DIR/migrate.sh"

# Step 6: Recreate and start services
log_info "=== Step 6: Levantando servicios actualizados ==="
docker_compose -f "$DOCKER_COMPOSE_FILE" up -d --build

log_info "Esperando 15 segundos para estabilizacion..."
sleep 15

# Step 7: Cleanup
log_info "=== Step 7: Limpieza de imagenes ==="
case "$PRUNE_MODE" in
  safe)
    log_info "Eliminando imagenes dangling y cache de build..."
    docker image prune -f || true
    docker builder prune -f || true
    ;;
  aggressive)
    log_warn "Modo agresivo: eliminando TODAS las imagenes no utilizadas."
    docker system prune -a -f || true
    ;;
  *)
    log_warn "PRUNE_MODE='$PRUNE_MODE' no reconocido. Saltando limpieza."
    ;;
esac

# Status
log_info "=== Estado de contenedores ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-127.0.0.1}"

log_info "Actualizacion completada exitosamente."
printf '\n  Frontend: http://%s:8089\n' "$SERVER_IP"
printf '  API DRIM: http://%s:8090\n' "$SERVER_IP"
printf '  API PM:   http://%s:8091\n\n' "$SERVER_IP"