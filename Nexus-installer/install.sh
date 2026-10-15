
cat > install.sh <<'INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Nexus Pro installer for Fly.io Sprites.
# Existing Nexus processes and existing Cloudflare tunnel configs are preserved.

APP_DEFAULT="$HOME/Nexus-ui"
NODE_DEFAULT="/.sprite/languages/node/nvm/versions/node/v24.18.0/bin"
CF_DEFAULT="/root/Argo/cloudflared"
STATE="$HOME/.nexus-pro-deploy"
LOGDIR="$STATE/logs"
mkdir -p "$LOGDIR"
chmod 700 "$STATE" "$LOGDIR"

APP=""
PORT=""
HOSTNAME=""
TUNNEL=""
NODE=""
NPM=""
CF=""
APP_PID=""
CF_PID=""
CONFIG=""

info() { printf '\n[INFO] %s\n' "$*"; }
ok()   { printf '\n[ OK ] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

ask() {
  local answer
  read -r -p "$1 [$2]: " answer
  printf '%s' "${answer:-$2}"
}

on_error() {
  local rc=$?
  printf '\n[ERROR] Script failed (exit code %s).\n' "$rc" >&2
  printf 'Check logs under: %s\n' "$LOGDIR" >&2
  if [[ -n "${APP:-}" && -f "$APP/logs/nexus.log" ]]; then
    tail -n 25 "$APP/logs/nexus.log" >&2 || true
  fi
  exit "$rc"
}
trap on_error ERR

valid_host() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

health_check() {
  local url="$1"
  curl -fsS --connect-timeout 2 --max-time 5 "$url" >/dev/null 2>&1
}

echo "================================================"
echo "       Nexus Pro - Sprite Deployment Wizard"
echo "================================================"
echo "This wizard uses English prompts."
echo "Existing webtmux and old Cloudflare tunnel configs"
echo "will not intentionally be stopped or overwritten."
echo

# Use a timeout so a broken Node launcher cannot hang the wizard forever.
command -v timeout >/dev/null 2>&1 ||
  die "The 'timeout' command is required."

info "Locating the Sprite Node.js installation."

if [[ -x "$NODE_DEFAULT/node" ]]; then
  NODE="$NODE_DEFAULT/node"
elif command -v node >/dev/null 2>&1; then
  NODE="$(command -v node)"
else
  die "Node.js was not found."
fi

NODE_VERSION="$(timeout 8s "$NODE" --version 2>&1)" ||
  die "Node.js did not return its version within 8 seconds. Check the executable: $NODE"
[[ "$NODE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] ||
  die "Unexpected Node.js version output: $NODE_VERSION"

NODE_DIR="$(dirname "$NODE")"
export PATH="$NODE_DIR:$PATH"

info "Node.js: $NODE_VERSION"
info "Node executable: $NODE"

if [[ -x "$NODE_DIR/npm" ]]; then
  NPM="$NODE_DIR/npm"
elif command -v npm >/dev/null 2>&1; then
  NPM="$(command -v npm)"
else
  die "npm was not found."
fi

NPM_VERSION="$(timeout 8s "$NPM" --version 2>&1)" ||
  die "npm did not respond within 8 seconds."
info "npm: $NPM_VERSION"

APP="$(ask 'Nexus Pro project directory' "$APP_DEFAULT")"
APP="${APP/#\~/$HOME}"
[[ -d "$APP" ]] || die "Project directory does not exist: $APP"

PORT="$(ask 'Nexus local port' '9127')"
[[ "$PORT" =~ ^[0-9]+$ ]] &&
  (( PORT >= 1024 && PORT <= 65535 )) ||
  die "Invalid port number."

HEALTH_PATH="$(ask 'Nexus health endpoint' '/api/health')"
[[ "$HEALTH_PATH" == /* ]] || HEALTH_PATH="/$HEALTH_PATH"
LOCAL_URL="http://127.0.0.1:$PORT$HEALTH_PATH"

mkdir -p "$APP/logs"

# Reuse the current healthy panel instead of starting a duplicate.
if health_check "$LOCAL_URL"; then
  ok "An existing Nexus instance is already healthy."
  info "Keeping the current process untouched."
  curl -fsS --max-time 5 "$LOCAL_URL" || true
  printf '\n'
else
  warn "No healthy Nexus instance detected at $LOCAL_URL."

  [[ -f "$APP/index.js" ]] ||
    die "index.js not found in $APP"
  [[ -f "$APP/package.json" ]] ||
    die "package.json not found. The installer will not invent project dependencies."

  cd "$APP"

  if [[ ! -d node_modules ]]; then
    info "Installing project dependencies."
    if [[ -f package-lock.json ]]; then
      timeout 600s "$NPM" ci --no-audit --no-fund \
        > "$LOGDIR/npm-install.log" 2>&1 ||
        { tail -n 60 "$LOGDIR/npm-install.log"; die "npm ci failed."; }
    else
      timeout 600s "$NPM" install --no-audit --no-fund \
        > "$LOGDIR/npm-install.log" 2>&1 ||
        { tail -n 60 "$LOGDIR/npm-install.log"; die "npm install failed."; }
    fi
  else
    info "node_modules exists; checking the installed Express module."
    if ! timeout 8s "$NODE" -e "require('express')" >/dev/null 2>&1; then
      warn "Express is not available. Installing package dependencies."
      if [[ -f package-lock.json ]]; then
        timeout 600s "$NPM" ci --no-audit --no-fund \
          > "$LOGDIR/npm-install.log" 2>&1 ||
          { tail -n 60 "$LOGDIR/npm-install.log"; die "Dependency installation failed."; }
      else
        timeout 600s "$NPM" install --no-audit --no-fund \
          > "$LOGDIR/npm-install.log" 2>&1 ||
          { tail -n 60 "$LOGDIR/npm-install.log"; die "Dependency installation failed."; }
      fi
    fi
  fi

  # Refuse to occupy a port already owned by another service.
  if command -v ss >/dev/null 2>&1 &&
     ss -lnt | awk '{print $4}' | grep -Eq "(:|\])${PORT}$"; then
    die "Port $PORT is occupied, but the Nexus health check failed. No process was stopped."
  fi

  # Do not source .env automatically: it may contain secrets or override
  # runtime settings. The app must honor PORT or its documented config.
  APP_LOG="$APP/logs/nexus.log"
  info "Starting Nexus Pro in the background."
  nohup env PORT="$PORT" SERVER_PORT="$PORT" \
    "$NODE" "$APP/index.js" >> "$APP_LOG" 2>&1 </dev/null &
  APP_PID=$!
  printf '%s\n' "$APP_PID" > "$APP/nexus.pid"

  healthy=0
  for _ in {1..15}; do
    if health_check "$LOCAL_URL"; then
      healthy=1
      break
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      break
    fi
    sleep 2
  done

  if (( healthy == 0 )); then
    tail -n 70 "$APP_LOG" || true
    die "Nexus did not pass its local health check. Fix the app before configuring the domain."
  fi
  ok "Nexus local health check passed."
fi

echo
info "Finding cloudflared."

if [[ -x "$CF_DEFAULT" ]]; then
  CF="$CF_DEFAULT"
elif command -v cloudflared >/dev/null 2>&1; then
  CF="$(command -v cloudflared)"
else
  die "cloudflared not found. Expected $CF_DEFAULT or a cloudflared command in PATH."
fi

timeout 10s "$CF" --version ||
  die "cloudflared did not return its version."

echo
echo "Cloudflare domain setup"
echo "Use a hostname belonging to a zone already added to your Cloudflare account."
echo

HOSTNAME="$(ask 'Full panel hostname (example: nexus.example.com)' '')"
valid_host "$HOSTNAME" || die "Invalid hostname: $HOSTNAME"
HOSTNAME="$(printf '%s' "$HOSTNAME" | tr '[:upper:]' '[:lower:]')"

TUNNEL="$(ask 'NEW dedicated tunnel name' 'nexus-pro-panel')"
[[ "$TUNNEL" =~ ^[a-zA-Z0-9_-]+$ ]] ||
  die "Tunnel name may contain only letters, digits, underscores and hyphens."

CF_HOME="$HOME/.cloudflared"
mkdir -p "$CF_HOME" "$STATE/cloudflared"
chmod 700 "$CF_HOME" "$STATE/cloudflared"

# Existing global tunnel config is deliberately never edited.
if [[ ! -f "$CF_HOME/cert.pem" ]]; then
  echo
  echo "Cloudflare login is required."
  echo "Open the URL printed below and authorize the correct domain."
  "$CF" tunnel login
fi
[[ -f "$CF_HOME/cert.pem" ]] ||
  die "Cloudflare login certificate not found at $CF_HOME/cert.pem"

# Refuse to reuse an existing tunnel name.
TUNNEL_LIST="$LOGDIR/tunnel-list.txt"
"$CF" tunnel list > "$TUNNEL_LIST" 2>&1 ||
  die "Unable to list Cloudflare tunnels. Check Cloudflare login."

if awk -v n="$TUNNEL" 'NR>1 && $2==n {found=1} END {exit !found}' "$TUNNEL_LIST"; then
  die "Tunnel '$TUNNEL' already exists. Choose a NEW name; no existing tunnel was modified."
fi

info "Creating a dedicated Cloudflare tunnel: $TUNNEL"
"$CF" tunnel create "$TUNNEL" > "$LOGDIR/tunnel-create.log" 2>&1 ||
  { cat "$LOGDIR/tunnel-create.log"; die "Tunnel creation failed."; }

"$CF" tunnel list > "$TUNNEL_LIST" 2>&1 ||
  die "Unable to refresh tunnel list."

TUNNEL_ID="$(awk -v n="$TUNNEL" 'NR>1 && $2==n {print $1; exit}' "$TUNNEL_LIST")"
[[ "$TUNNEL_ID" =~ ^[0-9a-fA-F-]{36}$ ]] ||
  die "Could not determine the new tunnel ID. Check $TUNNEL_LIST"

CREDENTIALS="$CF_HOME/$TUNNEL_ID.json"
[[ -f "$CREDENTIALS" ]] ||
  die "Tunnel credentials not found: $CREDENTIALS"
chmod 600 "$CREDENTIALS"

CONFIG="$STATE/cloudflared/$TUNNEL.yml"
[[ ! -e "$CONFIG" ]] ||
  die "A deployment config already exists at $CONFIG. It was not overwritten."

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

info "Creating DNS route for $HOSTNAME"
"$CF" tunnel route dns "$TUNNEL_ID" "$HOSTNAME" ||
  die "DNS route creation failed. Check whether this hostname already has a DNS record or whether the zone is authorized."

CF_LOG="$LOGDIR/cloudflared-$TUNNEL.log"
CF_PID_FILE="$STATE/cloudflared-$TUNNEL.pid"

# Do not launch a duplicate tunnel if this deployment's PID is still alive.
if [[ -f "$CF_PID_FILE" ]]; then
  old_cf_pid="$(cat "$CF_PID_FILE" 2>/dev/null || true)"
  if [[ "$old_cf_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_cf_pid" 2>/dev/null; then
    die "This installer's tunnel process is already running (PID $old_cf_pid)."
  fi
fi

info "Starting the new dedicated tunnel."
nohup "$CF" tunnel --no-autoupdate --config "$CONFIG" run "$TUNNEL_ID" \
  >> "$CF_LOG" 2>&1 </dev/null &
CF_PID=$!
printf '%s\n' "$CF_PID" > "$CF_PID_FILE"

sleep 4
kill -0 "$CF_PID" 2>/dev/null ||
  { tail -n 60 "$CF_LOG" || true; die "Cloudflare tunnel process exited."; }

echo
info "Waiting for public HTTPS. DNS propagation can take time."
PUBLIC_OK=0
for _ in {1..12}; do
  if health_check "https://$HOSTNAME$HEALTH_PATH"; then
    PUBLIC_OK=1
    break
  fi
  sleep 5
done

echo
echo "================================================"
echo "                 Deployment Report"
echo "================================================"
echo "Panel URL:       https://$HOSTNAME"
echo "Local endpoint:  $LOCAL_URL"
echo "Tunnel name:     $TUNNEL"
echo "Tunnel ID:       $TUNNEL_ID"
echo "Nexus log:       $APP/logs/nexus.log"
echo "Tunnel log:      $CF_LOG"
echo "Tunnel config:   $CONFIG"
echo "Deployment logs: $LOGDIR"

if (( PUBLIC_OK == 1 )); then
  ok "Public HTTPS health check passed."
  curl -fsS --max-time 8 "https://$HOSTNAME$HEALTH_PATH" || true
  printf '\n'
else
  warn "Public HTTPS check did not pass yet. Installation is NOT fully verified."
  echo "Inspect tunnel log:"
  echo "  tail -n 80 '$CF_LOG'"
  echo "Test public endpoint:"
  echo "  curl -v --max-time 15 'https://$HOSTNAME$HEALTH_PATH'"
fi

echo
echo "Existing webtmux and the old Cloudflare config were not intentionally changed."
echo "Background processes may not survive a Sprite recycle."
INSTALLER

chmod 700 install.sh
bash -n install.sh && echo "Syntax check passed."
INSTALLER

bash install.sh
