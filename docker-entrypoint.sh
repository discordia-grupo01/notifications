#!/bin/sh
set -e

if [ -n "$TS_AUTHKEY" ]; then
  TS_SOCKET=/tmp/tailscaled.sock
  RABBITMQ_TS_PORT="${RABBITMQ_TS_PORT:-5672}"
  RABBITMQ_LOCAL_PORT="${RABBITMQ_LOCAL_PORT:-5672}"

  if [ -z "$RABBITMQ_TS_HOST" ]; then
    echo "TS_AUTHKEY definido pero falta RABBITMQ_TS_HOST (IP o nombre Tailscale del RabbitMQ)" >&2
    exit 1
  fi

  tailscaled --tun=userspace-networking --state=mem: --socket="$TS_SOCKET" &

  for _ in $(seq 1 40); do
    [ -S "$TS_SOCKET" ] && break
    sleep 0.5
  done

  tailscale --socket="$TS_SOCKET" up \
    --authkey="$TS_AUTHKEY" \
    --hostname="${TS_HOSTNAME:-discordia-notifications}" \
    --timeout=60s \
    || echo "tailscale up fallo: arranco igual, el consumidor de RabbitMQ reintenta" >&2

  socat "TCP-LISTEN:${RABBITMQ_LOCAL_PORT},bind=127.0.0.1,fork,reuseaddr" \
    "EXEC:tailscale --socket=${TS_SOCKET} nc ${RABBITMQ_TS_HOST} ${RABBITMQ_TS_PORT}" &
fi

exec /app/bin/notifications "$@"
