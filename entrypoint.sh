#!/bin/sh
#
# vpn-panel entrypoint.
#
# Generates credentials on first boot, writes the xray config, starts
# xray + caddy + jupyter, then supervises all three. If ANY of the three
# dies the whole container exits non-zero, so a platform never shows a
# green "Running" next to a broken service.
#
set -eu

PORT="${PORT:-8080}"
XRAY_DIR="${XRAY_DIR:-/opt/xray}"
STATE_DIR="${STATE_DIR:-/app/state}"
XRAY_CONFIG="${XRAY_CONFIG:-${STATE_DIR}/config.json}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
XRAY_LOGLEVEL="${XRAY_LOGLEVEL:-warning}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# ---------------------------------------------------------------- credentials
# Persisted in $STATE_DIR so a restart keeps the same UUID / token.
# Mount a volume on /app/state for that; without one they regenerate on
# every cold start.
gen_uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
gen_hex()  { python3 -c 'import secrets; print(secrets.token_hex(4))'; }
gen_pass() { python3 -c 'import secrets; print(secrets.token_urlsafe(18))'; }

[ -s "$STATE_DIR/vless_uuid" ]  || gen_uuid > "$STATE_DIR/vless_uuid"
[ -s "$STATE_DIR/vless_short" ] || gen_hex  > "$STATE_DIR/vless_short"
[ -s "$STATE_DIR/jup_token" ]   || gen_pass > "$STATE_DIR/jup_token"

UUID=$(cat  "$STATE_DIR/vless_uuid")
SHORT=$(cat "$STATE_DIR/vless_short")
JTOKEN=$(cat "$STATE_DIR/jup_token")
chmod 600 "$STATE_DIR"/* 2>/dev/null || true

# ---------------------------------------------------------------- xray config
cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "${XRAY_LOGLEVEL}" },
  "inbounds": [
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    },
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "grpc",
      "settings": { "serviceName": "HandlerService" }
    }
  ],
  "outbounds": [
    { "tag": "api",    "protocol": "xray",    "settings": {} },
    { "tag": "direct", "protocol": "freedom", "settings": {} },
    { "tag": "block",  "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" }
    ]
  }
}
EOF

# Fail fast on a malformed config rather than looping in a crash restart.
"$XRAY_DIR/xray" run -test -c "$XRAY_CONFIG" >/dev/null 2>&1 || {
    echo "[boot] FATAL: xray rejected $XRAY_CONFIG" >&2
    exit 1
}

# ------------------------------------------------------------------- start up
echo "[boot] port=${PORT}"

"$XRAY_DIR/xray" run -c "$XRAY_CONFIG" &
XRAY_PID=$!

caddy run --config "$CADDYFILE" --adapter caddyfile &
CADDY_PID=$!

jupyter lab \
    --ip=127.0.0.1 \
    --port=8888 \
    --no-browser \
    --allow-root \
    --ServerApp.base_url=/j/ \
    --ServerApp.token="$JTOKEN" \
    --ServerApp.password="" \
    --ServerApp.allow_origin='*' \
    &
JUP_PID=$!

# ------------------------------------------------------------------- supervise
trap 'kill -TERM 0 2>/dev/null || true' TERM INT

echo "[boot] waiting for services..."
i=0
while [ "$i" -lt 30 ]; do
    if kill -0 "$CADDY_PID" 2>/dev/null && kill -0 "$XRAY_PID" 2>/dev/null; then
        break
    fi
    i=$((i + 1))
    sleep 1
done
kill -0 "$CADDY_PID" 2>/dev/null || { echo "[boot] FATAL: caddy died" >&2; exit 1; }
kill -0 "$XRAY_PID" 2>/dev/null || { echo "[boot] FATAL: xray died" >&2; exit 1; }
echo "[boot] all services up"

# ------------------------------------------------------------------- banner
HOST="${PUBLIC_HOST:-<your-deployment-domain>}"
cat <<BANNER

  Jupyter terminal : https://${HOST}/j/?token=${JTOKEN}
  Health           : https://${HOST}/healthz

  VLESS link (paste into v2rayN / Hiddify / Nekoray):
  vless://${UUID}@${HOST}:443?path=%2Fvless&security=tls&sni=${HOST}#vpn-panel

  xray API (localhost only, stage 2 panel will use this):
  127.0.0.1:10085  service=HandlerService

BANNER

# Exit non-zero the moment any child dies, so the platform marks it crashed
# instead of leaving a zombie "Running".
while :; do
    for pid in "$XRAY_PID" "$CADDY_PID" "$JUP_PID"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "[supervisor] pid $pid exited -> terminating container" >&2
            kill -TERM "$XRAY_PID" "$CADDY_PID" "$JUP_PID" 2>/dev/null || true
            exit 1
        fi
    done
    sleep 5
done