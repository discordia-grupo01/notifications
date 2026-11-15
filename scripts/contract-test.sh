#!/usr/bin/env bash
# Prueba de contrato: levanta notifications contra Mongo y RabbitMQ locales y corre
# Schemathesis con openapi.yaml. Sale con 0 solo si no encuentra desvios.
#
# Configuracion por variables de entorno (sin argumentos):
#   APP_PORT               puerto del servicio (18087)
#   MONGO_URL              Mongo de prueba; el host debe ser localhost/127.0.0.1
#   RABBITMQ_URL           RabbitMQ de prueba; el host debe ser localhost/127.0.0.1
#   CONTRACT_APP_MODE      host (mix run, por defecto) o docker (contenedor elixir:1.16)
#   CONTRACT_MAX_EXAMPLES  casos por operacion (50)
#   CONTRACT_SEED          semilla (1)
#   CONTRACT_REPORT_DIR    carpeta del reporte (contract-report)
#   SCHEMATHESIS_BIN       ejecutable de Schemathesis (.contract-venv, o el del PATH)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_PORT="${APP_PORT:-18087}"
MONGO_URL="${MONGO_URL:-mongodb://localhost:55527/notifications_contract}"
RABBITMQ_URL="${RABBITMQ_URL:-amqp://guest:guest@localhost:55517}"
CONTRACT_APP_MODE="${CONTRACT_APP_MODE:-host}"
CONTRACT_MAX_EXAMPLES="${CONTRACT_MAX_EXAMPLES:-50}"
CONTRACT_SEED="${CONTRACT_SEED:-1}"
CONTRACT_REPORT_DIR="${CONTRACT_REPORT_DIR:-contract-report}"
CONTRACT_READY_TIMEOUT="${CONTRACT_READY_TIMEOUT:-600}"
APP_CONTAINER="contract-notifications-app"
USER_ID="00000000-0000-4000-8000-000000000001"
BASE_URL="http://127.0.0.1:${APP_PORT}"

log() { echo "[contract] $*"; }
die() { echo "[contract] ERROR: $*" >&2; exit 1; }

# Host de una URL (mongodb://u:p@host:1234/db, amqp://...). Vacio si no se puede leer.
url_host() {
  local rest="${1#*://}"
  rest="${rest%%/*}"
  rest="${rest##*@}"
  rest="${rest%%:*}"
  echo "$rest"
}

# Proteccion contra produccion: solo se acepta una base y un broker locales.
guard_local() {
  local name="$1" url="$2" host
  host="$(url_host "$url")"
  case "$host" in
    localhost | 127.0.0.1) ;;
    *) die "$name apunta a '$host': la prueba de contrato solo corre contra localhost/127.0.0.1" ;;
  esac
  case "$url" in
    mongodb+srv://*) die "$name usa mongodb+srv: no es un Mongo local" ;;
  esac
}

guard_local MONGO_URL "$MONGO_URL"
guard_local RABBITMQ_URL "$RABBITMQ_URL"
case "$CONTRACT_APP_MODE" in host | docker) ;; *) die "CONTRACT_APP_MODE debe ser host o docker" ;; esac

# Schemathesis
if [ -z "${SCHEMATHESIS_BIN:-}" ]; then
  if [ -x ".contract-venv/bin/schemathesis" ]; then
    SCHEMATHESIS_BIN=".contract-venv/bin/schemathesis"
  elif [ -x ".contract-venv/Scripts/schemathesis.exe" ]; then
    SCHEMATHESIS_BIN=".contract-venv/Scripts/schemathesis.exe"
  elif command -v schemathesis > /dev/null 2>&1; then
    SCHEMATHESIS_BIN="schemathesis"
  else
    die "no encuentro schemathesis: python -m venv .contract-venv && .contract-venv/bin/pip install schemathesis==4.33.4"
  fi
fi

# Python del mismo entorno que Schemathesis (trae PyYAML), para medir la cobertura.
case "$SCHEMATHESIS_BIN" in
  */Scripts/*) PY_VENV="$(dirname "$SCHEMATHESIS_BIN")/python.exe" ;;
  */bin/*) PY_VENV="$(dirname "$SCHEMATHESIS_BIN")/python" ;;
  *) PY_VENV="python3" ;;
esac
[ -x "$PY_VENV" ] || PY_VENV="python3"

# JWT sin firma valida: el servicio solo lee el sub (Notifications.Auth.Token no verifica la firma).
b64url() { base64 | tr -d '=\n' | tr '+/' '-_'; }
TOKEN="$(printf '{"alg":"none","typ":"JWT"}' | b64url).$(printf '{"sub":"%s"}' "$USER_ID" | b64url).contract"

APP_PID=""
cleanup() {
  local status=$?
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" > /dev/null 2>&1 || true
    wait "$APP_PID" > /dev/null 2>&1 || true
  fi
  if [ "$CONTRACT_APP_MODE" = "docker" ]; then
    docker rm -f "$APP_CONTAINER" > /dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# Lo que el servicio recibe: valores de juguete y nada que pueda mandar un push ni sacar datos.
# EXPO_PUSH_URL apunta a un puerto cerrado por si algun evento intentara un envio.
APP_ENV=(
  "MIX_ENV=prod"
  "PORT=$APP_PORT"
  "SECRET_KEY_BASE=contract-test-secret-key-base-contract-test-secret-key-base-0123456789abcdef"
  "CHECK_ORIGIN=false"
  "LOG_LEVEL=warning"
  "EXPO_PUSH_URL=http://127.0.0.1:1/push"
  # Clave VAPID de juguete (32 bytes en 0x01, no es un secreto): solo para que
  # GET /push/vapid-public-key responda 200. En la corrida no hay eventos, asi que no sale ningun push.
  "VAPID_PRIVATE_KEY=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
  "VAPID_SUBJECT=mailto:contract@example.test"
  "HISTORY_RETENTION_DAYS=0"
)
UNSET_ENV=(EXPO_ACCESS_TOKEN PUSH_MAX_DEVICES PUSH_ALLOWED_HOSTS
  OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS LOG_SHIP_URL LOG_SHIP_API_KEY
  TS_AUTHKEY)

if docker ps -a --format '{{.Names}}' 2> /dev/null | grep -qx "$APP_CONTAINER"; then
  docker rm -f "$APP_CONTAINER" > /dev/null
fi

mkdir -p "$CONTRACT_REPORT_DIR"
APP_LOG="$CONTRACT_REPORT_DIR/app.log"

if [ "$CONTRACT_APP_MODE" = "host" ]; then
  log "arrancando el servicio con mix en el puerto $APP_PORT"
  (
    for name in "${UNSET_ENV[@]}"; do unset "$name"; done
    export MONGO_URL RABBITMQ_URL
    for pair in "${APP_ENV[@]}"; do export "$pair"; done
    exec mix run --no-halt
  ) > "$APP_LOG" 2>&1 &
  APP_PID=$!
else
  # En docker el contenedor llega al host por host.docker.internal; las URLs ya pasaron el guard.
  container_url() { echo "$1" | sed -e 's#@localhost#@host.docker.internal#' -e 's#//localhost#//host.docker.internal#' -e 's#@127.0.0.1#@host.docker.internal#' -e 's#//127.0.0.1#//host.docker.internal#'; }
  log "arrancando el servicio en el contenedor $APP_CONTAINER (puerto $APP_PORT)"
  docker_env=()
  for pair in "${APP_ENV[@]}"; do docker_env+=(-e "$pair"); done
  docker_env+=(-e "PORT=4000")
  MSYS_NO_PATHCONV=1 docker run -d --name "$APP_CONTAINER" \
    -p "127.0.0.1:${APP_PORT}:4000" \
    -v "$(pwd -W 2> /dev/null || pwd):/app" \
    -v contract-notifications-deps:/app/deps \
    -v contract-notifications-build:/app/_build \
    -w /app "${docker_env[@]}" \
    -e "MONGO_URL=$(container_url "$MONGO_URL")" \
    -e "RABBITMQ_URL=$(container_url "$RABBITMQ_URL")" \
    elixir:1.16 sh -c "mix local.hex --force && mix local.rebar --force && mix deps.get && mix run --no-halt" \
    > /dev/null
fi

app_alive() {
  if [ "$CONTRACT_APP_MODE" = "host" ]; then
    kill -0 "$APP_PID" > /dev/null 2>&1
  else
    [ "$(docker inspect -f '{{.State.Running}}' "$APP_CONTAINER" 2> /dev/null)" = "true" ]
  fi
}

show_app_log() {
  if [ "$CONTRACT_APP_MODE" = "docker" ]; then
    docker logs "$APP_CONTAINER" > "$APP_LOG" 2>&1 || true
  fi
  grep -v '"status":4[0-9][0-9]' "$APP_LOG" | tail -n 15 >&2 || true
}

log "esperando /readyz (hasta ${CONTRACT_READY_TIMEOUT}s; la primera compilacion tarda)"
waited=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/readyz" 2> /dev/null || true)" = "200" ]; do
  if ! app_alive; then
    show_app_log
    die "el servicio se cayo antes de quedar listo"
  fi
  if [ "$waited" -ge "$CONTRACT_READY_TIMEOUT" ]; then
    show_app_log
    die "el servicio no quedo listo en ${CONTRACT_READY_TIMEOUT}s"
  fi
  sleep 2
  waited=$((waited + 2))
done
log "servicio listo"

# Siembra un servidor, un canal y una membresia para que settings llegue al 200: con mongosh
# local si hay; si no, dentro del contenedor de contract-deps-up; si no, con la imagen mongo.
log "sembrando datos de prueba en Mongo"
if command -v mongosh > /dev/null 2>&1; then
  mongosh "$MONGO_URL" --quiet --file scripts/contract/seed.js > /dev/null
elif docker ps --format '{{.Names}}' 2> /dev/null | grep -qx contract-notifications-mongo; then
  docker exec -i contract-notifications-mongo mongosh --quiet "mongodb://localhost:27017/${MONGO_URL##*/}" < scripts/contract/seed.js > /dev/null
else
  docker run --rm --network host -v "$(pwd):/work" mongo:7 mongosh "$MONGO_URL" --quiet --file /work/scripts/contract/seed.js > /dev/null
fi

log "corriendo Schemathesis ($CONTRACT_MAX_EXAMPLES casos por operacion, semilla $CONTRACT_SEED)"
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
set +e
# Un hook fija el servidor y el canal sembrados en la mitad de los casos (ver hooks.py).
export SCHEMATHESIS_HOOKS=scripts.contract.hooks PYTHONPATH="$ROOT"
# unsupported_method queda afuera: Cowboy responde 501 a TRACE (no el 405 que exige) antes de llegar
# a Phoenix, y con los demas metodos no declarados Phoenix ya responde 404. Ver schemathesis.toml.
"$SCHEMATHESIS_BIN" --config-file scripts/contract/schemathesis.toml run openapi.yaml \
  --url "$BASE_URL" \
  --header "Authorization: Bearer $TOKEN" \
  --exclude-checks unsupported_method \
  --max-examples "$CONTRACT_MAX_EXAMPLES" \
  --seed "$CONTRACT_SEED" \
  --workers 1 \
  --report junit,har --report-dir "$CONTRACT_REPORT_DIR" \
  --no-color
status=$?
set -e

# Cobertura de camino feliz: cuantas operaciones del contrato obtuvieron un 2xx real.
if [ "$status" -eq 0 ]; then
  "$PY_VENV" scripts/contract/coverage.py openapi.yaml "$CONTRACT_REPORT_DIR"/har-*.json || status=$?
fi

if [ "$status" -ne 0 ]; then
  show_app_log
  log "Schemathesis encontro desvios (reporte en $CONTRACT_REPORT_DIR)"
fi
exit "$status"
