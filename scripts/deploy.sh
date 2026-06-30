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

# Preflight: validar politica de complejidad de MSSQL_SA_PASSWORD
# (SQL Server la rechaza si no cumple, y el contenedor entra en crash-loop
#  sin avisar nada util hasta que revisas el log con docker logs drim-db)
set -a
source .env
set +a
if [[ -z "${MSSQL_SA_PASSWORD:-}" ]]; then
  die "MSSQL_SA_PASSWORD no esta definido en .env."
fi
pw_len=${#MSSQL_SA_PASSWORD}
pw_categories=0
[[ "$MSSQL_SA_PASSWORD" =~ [A-Z] ]] && ((pw_categories++)) || true
[[ "$MSSQL_SA_PASSWORD" =~ [a-z] ]] && ((pw_categories++)) || true
[[ "$MSSQL_SA_PASSWORD" =~ [0-9] ]] && ((pw_categories++)) || true
[[ "$MSSQL_SA_PASSWORD" =~ [^a-zA-Z0-9] ]] && ((pw_categories++)) || true
if (( pw_len < 8 )) || (( pw_categories < 3 )); then
  die "MSSQL_SA_PASSWORD no cumple la politica de complejidad de SQL Server (minimo 8 caracteres y al menos 3 de: mayusculas, minusculas, numeros, simbolos). Corrige el .env antes de continuar."
fi

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
    log_error "drim-db no alcanzo estado healthy despues de $((MAX_RETRIES * RETRY_INTERVAL)) segundos."
    log_error "=== Diagnostico automatico ==="
    log_error "--- docker ps -a (drim-db) ---"
    docker ps -a --filter "name=drim-db" --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}" >&2 || true
    log_error "--- Espacio en disco ---"
    df -h / >&2 || true
    log_error "--- Memoria disponible ---"
    free -h >&2 || true
    log_error "--- Ultimas 60 lineas de log de drim-db ---"
    docker logs --tail 60 drim-db >&2 || true
    log_error "================================"
    die "Revisa el log de arriba. Causas tipicas: volumen de datos danado por un deploy interrumpido, MSSQL_SA_PASSWORD distinto al usado cuando se creo el volumen, disco/RAM agotados, o puerto 1434 ocupado."
  fi
  printf '[INFO]  Esperando... (intento %d/%d, estado: %s)\n' "$i" "$MAX_RETRIES" "$STATUS"
  sleep $RETRY_INTERVAL
done

# Step 2: Run migrations
log_info "=== Step 2: Ejecutando migraciones ==="
bash "$SCRIPT_DIR/migrate.sh"

# Step 3: Prepare frontend source (build context required by docker-compose.yml)
FRONT_ZIP_NAME="${FRONT_ZIP_NAME:-DRIMFront.zip}"
if [[ ! -d "frontend" ]]; then
  log_info "=== Step 3: Preparando frontend (no existe carpeta frontend/) ==="
  [[ -f "$FRONT_ZIP_NAME" ]] || die "No existe la carpeta 'frontend' ni el archivo $FRONT_ZIP_NAME para crearla. Coloca $FRONT_ZIP_NAME en $INSTALL_DIR."
  mkdir -p frontend
  unzip -o "$FRONT_ZIP_NAME" -d frontend
  log_info "Frontend extraido en ./frontend"
else
  log_info "=== Step 3: Carpeta frontend ya existe, se reutiliza ==="
fi

# Step 4: Start all services
log_info "=== Step 4: Levantando todos los servicios ==="
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