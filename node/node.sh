#!/bin/bash
# Redis HA node: decides its role (primary or replica of the current primary), then runs
# redis-server and a colocated Sentinel. Runs as root so it can own the Railway volume,
# then drops to the redis user.
set -euo pipefail

: "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"
: "${REDIS_NODES:?REDIS_NODES must list every node private domain, comma separated}"
: "${RAILWAY_PRIVATE_DOMAIN:?private networking is required}"
: "${REDIS_PORT:=6379}"
: "${SENTINEL_PORT:=26379}"
: "${REDIS_MASTER_NAME:=mymaster}"
: "${SENTINEL_QUORUM:=2}"
: "${SENTINEL_DOWN_AFTER_MS:=5000}"
: "${SENTINEL_FAILOVER_TIMEOUT_MS:=30000}"
: "${SENTINEL_PARALLEL_SYNCS:=1}"
: "${REDIS_MAXMEMORY:=0}"
: "${REDIS_MAXMEMORY_POLICY:=noeviction}"
: "${REDIS_APPENDONLY:=yes}"
: "${REDIS_APPENDFSYNC:=everysec}"
: "${REDIS_EXTRA_ARGS:=}"
: "${REDIS_LOAD_MODULES:=yes}"
: "${DISCOVERY_SECONDS:=20}"
DATA=/data
SELF="$RAILWAY_PRIVATE_DOMAIN"
log() { echo "[redis-ha $(date -u +%H:%M:%S)] $*"; }
cli() { redis-cli --no-auth-warning -a "$REDIS_PASSWORD" "$@"; }

mkdir -p "$DATA" /etc/redis-ha
chown redis:redis "$DATA" /etc/redis-ha
if [ -n "$(find "$DATA" ! -user redis -print -quit)" ]; then chown -R redis:redis "$DATA"; fi

# Railway private DNS can take a moment after container start.
for i in $(seq 1 60); do getent hosts "$SELF" >/dev/null && break; sleep 1; done

IFS=',' read -ra NODES <<< "$REDIS_NODES"
CLEAN=()
for n in "${NODES[@]}"; do n="$(echo "$n" | xargs)"; n="${n%%:*}"; [ -n "$n" ] && CLEAN+=("$n"); done
NODES=("${CLEAN[@]}")
BOOTSTRAP="${NODES[0]}"

# Ask the other nodes' Sentinels who the current primary is.
discover() {
  local n out host
  for n in "${NODES[@]}"; do
    [ "$n" = "$SELF" ] && continue
    out="$(timeout 3 redis-cli --no-auth-warning -a "$REDIS_PASSWORD" -h "$n" -p "$SENTINEL_PORT" \
      SENTINEL get-master-addr-by-name "$REDIS_MASTER_NAME" 2>/dev/null || true)"
    host="$(echo "$out" | sed -n 1p | tr -d '\r')"
    if [ -n "$host" ] && [ "$host" != "(nil)" ] && ! echo "$host" | grep -qi err; then echo "$host"; return 0; fi
  done
  return 1
}

MASTER=""
deadline=$(( $(date +%s) + DISCOVERY_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if MASTER="$(discover)"; then break; fi
  MASTER=""; sleep 2
done
if [ -z "$MASTER" ]; then
  MASTER="$BOOTSTRAP"
  log "no Sentinel answered; using bootstrap primary $BOOTSTRAP"
else
  log "Sentinels report current primary: $MASTER"
fi

CONF=/etc/redis-ha/redis.conf
cat > "$CONF" <<CONF
bind * -::*
port ${REDIS_PORT}
protected-mode no
dir ${DATA}
requirepass "${REDIS_PASSWORD}"
masterauth "${REDIS_PASSWORD}"
masteruser default
replica-announce-ip ${SELF}
replica-announce-port ${REDIS_PORT}
replica-read-only yes
replica-serve-stale-data yes
repl-diskless-sync yes
repl-backlog-size 64mb
appendonly ${REDIS_APPENDONLY}
appendfsync ${REDIS_APPENDFSYNC}
save 3600 1 300 100 60 10000
maxmemory ${REDIS_MAXMEMORY}
maxmemory-policy ${REDIS_MAXMEMORY_POLICY}
tcp-keepalive 60
CONF
# Redis 8 ships JSON, Search, TimeSeries and probabilistic modules in the image; load them like the
# official entrypoint does.
if [ "$REDIS_LOAD_MODULES" = "yes" ]; then
  for m in /usr/local/lib/redis/modules/*.so; do
    [ -s "$m" ] && [ -x "$m" ] && echo "loadmodule $m" >> "$CONF"
  done
fi
if [ "$MASTER" = "$SELF" ]; then
  ROLE=primary
else
  ROLE="replica of $MASTER"
  echo "replicaof ${MASTER} ${REDIS_PORT}" >> "$CONF"
fi
chown redis:redis "$CONF"; chmod 600 "$CONF"

# Sentinel config is regenerated each boot; Sentinels rediscover peers and replicas via the primary.
SCONF=/etc/redis-ha/sentinel.conf
write_sentinel_conf() {
  local m="$1"
  cat > "$SCONF" <<SCONF
bind * -::*
port ${SENTINEL_PORT}
protected-mode no
dir /tmp
requirepass "${REDIS_PASSWORD}"
sentinel sentinel-pass "${REDIS_PASSWORD}"
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip ${SELF}
sentinel announce-port ${SENTINEL_PORT}
sentinel monitor ${REDIS_MASTER_NAME} ${m} ${REDIS_PORT} ${SENTINEL_QUORUM}
sentinel auth-pass ${REDIS_MASTER_NAME} ${REDIS_PASSWORD}
sentinel down-after-milliseconds ${REDIS_MASTER_NAME} ${SENTINEL_DOWN_AFTER_MS}
sentinel failover-timeout ${REDIS_MASTER_NAME} ${SENTINEL_FAILOVER_TIMEOUT_MS}
sentinel parallel-syncs ${REDIS_MASTER_NAME} ${SENTINEL_PARALLEL_SYNCS}
SCONF
  chown redis:redis "$SCONF"; chmod 600 "$SCONF"
}

log "node=$SELF role=$ROLE nodes=${NODES[*]} quorum=$SENTINEL_QUORUM"
# shellcheck disable=SC2086
setpriv --reuid=redis --regid=redis --init-groups redis-server "$CONF" $REDIS_EXTRA_ARGS &
REDIS_PID=$!

# Sentinel, restarted if it exits. On restart it re-discovers the current primary.
(
  sleep 2
  m="$MASTER"
  while true; do
    for i in $(seq 1 60); do getent hosts "$m" >/dev/null && break; sleep 1; done
    write_sentinel_conf "$m"
    setpriv --reuid=redis --regid=redis --init-groups redis-sentinel "$SCONF" || true
    log "sentinel exited, restarting in 3s"; sleep 3
    m="$(discover || echo "$MASTER")"
  done
) &
SENTINEL_LOOP=$!

shutdown() {
  log "SIGTERM: stopping sentinel and redis"
  kill -TERM "$SENTINEL_LOOP" 2>/dev/null || true
  pkill -TERM -x redis-sentinel 2>/dev/null || pkill -TERM -f redis-sentinel 2>/dev/null || true
  kill -TERM "$REDIS_PID" 2>/dev/null || true
  wait "$REDIS_PID" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

set +e
wait "$REDIS_PID"; rc=$?
log "redis-server exited with $rc"
pkill -TERM -f redis-sentinel 2>/dev/null
exit "$rc"
