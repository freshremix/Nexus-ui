
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_DIR="$HOME/Nexus-ui"
CF_BIN="/root/Argo/cloudflared"
STATE="$HOME/.nexus-pro-deploy"
LOG="$STATE/logs"

info() { printf '\n[INFO] %s\n' "$*"; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

trap 'echo "[ERROR] Installation failed at line $LINENO. Check the logs."' ERR

echo "=========================================="
echo "       Nexus Pro Installation Wizard"
echo "=========================================="
echo "Existing webtmux and existing tunnels will be preserved."
echo

command -v node >/dev/null || fail "Node.js is not installed."
command -v npm >/dev/null || fail "npm is not installed."
command -v curl >/dev/null || fail "curl is not installed."

node --version
npm --version

read -r -p "Enter Nexus Pro project directory [$APP_DIR]: " input
APP_DIR="${input:-$APP_DIR}"
APP_DIR="${APP_DIR/#\~/$HOME}"

[[ -f "$APP_DIR/index.js" ]] ||
  fail "index.js not found. Put the Nexus Pro application files in this directory."

cd "$APP_DIR"

[[ -f package.json ]] ||
  fail "package.json is missing. Add the correct Nexus Pro package.json first."

echo
echo "Installing Node.js dependencies..."
if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi

echo
read -r -p "Enter the local panel port [9127]: " PORT
PORT="${PORT:-9127}"

[[ "$PORT" =~ ^[0-9]+$ ]] &&
  (( PORT >= 1024 && PORT <= 65535 )) ||
  fail "Invalid port."

if command -v ss >/dev/null 2>&1 &&
   ss -lnt | awk '{print $4}' | grep -Eq "(:|\])${PORT}$"; then
  fail "Port $PORT is already in use. Choose another port and rerun."
fi

mkdir -p "$APP_DIR/logs" "$STATE" "$LOG"

if [[ -f "$APP_DIR/nexus.pid" ]]; then
  OLD_PID="$(cat "$APP_DIR/nexus.pid" 2>/dev/null || true)"
  if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    fail "Nexus may already be running with PID $OLD_PID. It was not stopped."
  fi
fi

echo
echo "Starting Nexus Pro..."
nohup env PORT="$PORT" SERVER_PORT="$PORT" HOST="127.0.0.1" \
  node "$APP_DIR/index.js" \
  >> "$APP_DIR/logs/nexus.log" 2>&1 </dev/null &

APP_PID=$!
echo "$APP_PID" > "$APP_DIR/nexus.pid"
sleep 3

kill -0 "$APP_PID" 2>/dev/null ||
  fail "Nexus exited. Inspect ~/Nexus-ui/logs/nexus.log"

read -r -p "Health endpoint path [/api/health]: " HEALTH_PATH
HEALTH_PATH="${HEALTH_PATH:-/api/health}"
[[ "$HEALTH_PATH" == /* ]] || HEALTH_PATH="/$HEALTH_PATH"

LOCAL_URL="http://127.0.0.1:$PORT$HEALTH_PATH"

if ! curl -fsS --max-time 5 "$LOCAL_URL"; then
  tail -n 50 "$APP_DIR/logs/nexus.log" || true
  fail "Local health check failed. Fix the app before connecting the domain."
fi

echo
echo "[OK] Local panel health check passed."
echo

[[ -x "$CF_BIN" ]] || {
  command -v cloudflared >/dev/null 2>&1 ||
    fail "cloudflared was not found."
  CF_BIN="$(command -v cloudflared)"
}

"$CF_BIN" --version

echo
echo "Cloudflare configuration"
echo "Use a domain already added to your Cloudflare account."
echo

read -r -p "Enter your full panel hostname (e.g. nexus.example.com): " HOSTNAME

[[ "$HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] ||
  fail "Invalid hostname."

HOSTNAME="$(printf '%s' "$HOSTNAME" | tr '[:upper:]' '[:lower:]')"

read -r -p "Name for a NEW dedicated tunnel [nexus-panel]: " TUNNEL
TUNNEL="${TUNNEL:-nexus-panel}"

[[ "$TUNNEL" =~ ^[A-Za-z0-9_-]+$ ]] ||
  fail "Invalid tunnel name."

mkdir -p "$HOME/.cloudflared" "$STATE/cloudflared"
chmod 700 "$HOME/.cloudflared" "$STATE"

if [[ ! -f "$HOME/.cloudflared/cert.pem" ]]; then
  echo
  echo "Cloudflare will display a login URL."
  echo "Open that URL and authorize the correct domain."
  "$CF_BIN" tunnel login
fi

[[ -f "$HOME/.cloudflared/cert.pem" ]] ||
  fail "Cloudflare login was not completed."

if "$CF_BIN" tunnel list 2>/dev/null |
   awk 'NR>1 {print $2}' | grep -Fxq "$TUNNEL"; then
  fail "Tunnel name already exists. Choose a new name; existing tunnels are not reused."
fi

echo
echo "Creating a dedicated Cloudflare Tunnel..."
"$CF_BIN" tunnel create "$TUNNEL"

TUNNEL_ID="$("$CF_BIN" tunnel list 2>/dev/null |
  awk -v n="$TUNNEL" 'NR>1 && $2==n {print $1; exit}')"

[[ "$TUNNEL_ID" =~ ^[0-9a-fA-F-]{36}$ ]] ||
  fail "Could not determine tunnel ID."

CREDENTIALS="$HOME/.cloudflared/$TUNNEL_ID.json"
[[ -f "$CREDENTIALS" ]] ||
  fail "Tunnel credentials file not found."

chmod 600 "$CREDENTIALS"

CONFIG="$STATE/cloudflared/$TUNNEL.yml"
[[ ! -e "$CONFIG" ]] || fail "Config already exists: $CONFIG"

cat > "$CONFIG" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CREDENTIALS
no-autoupdate: true

ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:$PORT
  - service: http_status:404
EOF

chmod 600 "$CONFIG"

echo
echo "Creating DNS route for $HOSTNAME..."
"$CF_BIN" tunnel route dns "$TUNNEL" "$HOSTNAME"

CF_LOG="$LOG/cloudflared-$TUNNEL.log"
CF_PID_FILE="$STATE/cloudflared-$TUNNEL.pid"

echo "Starting the new tunnel in the background..."
nohup "$CF_BIN" tunnel --no-autoupdate \
  --config "$CONFIG" run "$TUNNEL" \
  >> "$CF_LOG" 2>&1 </dev/null &

CF_PID=$!
echo "$CF_PID" > "$CF_PID_FILE"
sleep 5

kill -0 "$CF_PID" 2>/dev/null ||
  fail "Cloudflare Tunnel exited. Inspect $CF_LOG"

echo
echo "Checking public HTTPS..."
if curl -fsS --max-time 12 "https://$HOSTNAME$HEALTH_PATH"; then
  echo
  echo "[SUCCESS] Public health check passed."
else
  echo
  echo "[WARNING] Public check failed or DNS is still propagating."
  echo "Check the tunnel log and Cloudflare DNS before assuming it works."
fi

echo
echo "=========================================="
echo "             Installation Summary"
echo "=========================================="
echo "Panel URL:    https://$HOSTNAME"
echo "Local port:   $PORT"
echo "Tunnel:       $TUNNEL"
echo "Tunnel ID:    $TUNNEL_ID"
echo "Nexus log:    $APP_DIR/logs/nexus.log"
echo "Tunnel log:   $CF_LOG"
echo "Tunnel config:$CONFIG"
echo
echo "Existing webtmux and pre-existing tunnels were not stopped."
echo "Background processes may not survive a Sprite recycle."
