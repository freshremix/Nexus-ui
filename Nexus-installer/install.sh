
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="$HOME/.nexus-pro-deploy"
LOGDIR="$BASE/logs"
CF_CONFIG_DIR="$BASE/cloudflared"
STATE="$BASE/state.env"
CF="${CF:-/root/Argo/cloudflared}"
NODE="${NODE:-/.sprite/languages/node/nvm/versions/node/v24.18.0/bin/node}"
PROJECT_DEFAULT="$HOME/Nexus-ui"
PORT_DEFAULT="9127"

mkdir -p "$LOGDIR" "$CF_CONFIG_DIR"

say() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer
    printf '%s' "$answer"
  fi
}
confirm() {
  local answer
  read -r -p "$1 Type YES to continue: " answer
  [[ "$answer" == "YES" ]]
}
valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
valid_label() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

load_state() {
  [[ -f "$STATE" ]] || return 1
  # State is written by this script; don't source arbitrary files.
  PROJECT="$(sed -n 's/^PROJECT=//p' "$STATE" | head -n1)"
  PORT="$(sed -n 's/^PORT=//p' "$STATE" | head -n1)"
  HOSTNAME="$(sed -n 's/^HOSTNAME=//p' "$STATE" | head -n1)"
  TUNNEL="$(sed -n 's/^TUNNEL=//p' "$STATE" | head -n1)"
  TUNNEL_ID="$(sed -n 's/^TUNNEL_ID=//p' "$STATE" | head -n1)"
  CONFIG="$(sed -n 's/^CONFIG=//p' "$STATE" | head -n1)"
}

save_state() {
  local tmp="$STATE.tmp"
  {
    printf 'PROJECT=%s\n' "$PROJECT"
    printf 'PORT=%s\n' "$PORT"
    printf 'HOSTNAME=%s\n' "$HOSTNAME"
    printf 'TUNNEL=%s\n' "$TUNNEL"
    printf 'TUNNEL_ID=%s\n' "$TUNNEL_ID"
    printf 'CONFIG=%s\n' "$CONFIG"
  } > "$tmp"
  mv "$tmp" "$STATE"
  chmod 600 "$STATE"
}

cleanup_install() {
  say "Cleanup mode: inspect this script's saved deployment state."
  if ! load_state; then
    warn "No saved state found. Automatic deletion is disabled to avoid deleting unrelated resources."
    printf 'No resources were removed.\n'
    return 0
  fi

  printf '\nSaved deployment:\n'
  printf 'Project: %s\nPort: %s\nHostname: %s\nTunnel: %s\nTunnel ID: %s\nConfig: %s\n' \
    "$PROJECT" "$PORT" "$HOSTNAME" "$TUNNEL" "$TUNNEL_ID" "$CONFIG"

  warn "Cleanup can stop only processes and remove files positively identified as belonging to this deployment."
  warn "DNS deletion must be confirmed against the exact Cloudflare zone; this script will not guess the zone."
  confirm "Remove this deployment's local config/state and attempt to stop its dedicated tunnel?" || {
    say "Cancelled. Nothing changed."
    return 0
  }

  # Stop only cloudflared processes explicitly using this dedicated config.
  if command -v pgrep >/dev/null 2>&1; then
    while read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$cmd" == *"$CONFIG"* && "$cmd" == *"cloudflared"* ]]; then
        kill "$pid" 2>/dev/null || true
      fi
    done < <(pgrep -f 'cloudflared.*nexus-pro-deploy' || true)
  fi

  printf '\nDNS cleanup is a separate explicit action.\n'
  printf 'Do not delete records from an assumed zone. Current hostname: %s\n' "$HOSTNAME"
  printf 'After verifying the exact zone in Cloudflare, remove its matching CNAME manually if it belongs to this deployment.\n'

  # Remove only this installer's own dedicated config and state.
  [[ -n "${CONFIG:-}" && "$CONFIG" == "$CF_CONFIG_DIR/"*.yml ]] && rm -f -- "$CONFIG"
  rm -f -- "$STATE"
  say "Local deployment state/config cleanup finished."
  say "Project files, Nexus process, DNS records, Cloudflare credentials, argo02 and webtmux were NOT deleted."
}

install_mode() {
  say "Nexus Pro deployment — interactive setup"
  say "Every value is requested for this run; no previous domain is assumed."

  PROJECT="$(ask 'Absolute path to Nexus project directory' "$PROJECT_DEFAULT")"
  [[ "$PROJECT" = /* && -d "$PROJECT" ]] || die "Project directory does not exist or is not an absolute path."
  [[ -f "$PROJECT/index.js" ]] || die "Cannot find $PROJECT/index.js"
  [[ -f "$PROJECT/package.json" ]] || die "Cannot find $PROJECT/package.json"

  PORT="$(ask 'Local panel port' "$PORT_DEFAULT")"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || die "Invalid port."

  ROOT_DOMAIN="$(ask 'Root domain managed in Cloudflare (example.com)')"
  valid_domain "$ROOT_DOMAIN" || die "Invalid root domain."
  ROOT_DOMAIN="${ROOT_DOMAIN,,}"

  SUBDOMAIN="$(ask 'Subdomain label (example: nexus; enter @ for root domain)')"
  if [[ "$SUBDOMAIN" != "@" ]]; then
    valid_label "$SUBDOMAIN" || die "Invalid subdomain label."
    SUBDOMAIN="${SUBDOMAIN,,}"
    HOSTNAME="$SUBDOMAIN.$ROOT_DOMAIN"
  else
    HOSTNAME="$ROOT_DOMAIN"
  fi

  TUNNEL="$(ask 'New unique tunnel name' "nexus-$(date +%s)")"
  valid_label "$TUNNEL" || die "Invalid tunnel name."
  [[ "$TUNNEL" != "argo02" ]] || die "Refusing to use the protected old tunnel name argo02."

  [[ -x "$CF" ]] || die "cloudflared executable not found at $CF"
  [[ -x "$NODE" ]] || {
    command -v node >/dev/null 2>&1 && NODE="$(command -v node)" || die "Node executable not found."
  }

  say "Checking local panel before starting anything..."
  if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/" -o /dev/null; then
    say "A panel already responds on port $PORT; it will not be restarted."
  else
    if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -Eq "[:.]$PORT[[:space:]]"; then
      die "Port $PORT is occupied but the panel root did not pass. Inspect the process before continuing."
    fi
    if [[ -f "$PROJECT/package-lock.json" ]]; then
      (cd "$PROJECT" && npm ci) || die "npm ci failed."
    else
      (cd "$PROJECT" && npm install) || die "npm install failed."
    fi
    say "Starting Nexus in the background..."
    mkdir -p "$PROJECT/logs"
    nohup env PORT="$PORT" SERVER_PORT="$PORT" "$NODE" "$PROJECT/index.js" \
      >> "$PROJECT/logs/nexus.log" 2>&1 < /dev/null &
    sleep 3
    curl -fsS --max-time 8 "http://127.0.0.1:$PORT/" -o /dev/null ||
      die "Nexus did not pass the local HTTP check. See $PROJECT/logs/nexus.log"
  fi

  say "Creating a dedicated Cloudflare tunnel."
  say "This step requires an existing Cloudflare login certificate in ~/.cloudflared/cert.pem."
  [[ -s "$HOME/.cloudflared/cert.pem" ]] || die "Missing $HOME/.cloudflared/cert.pem. Complete cloudflared tunnel login first."

  # Validate zone selection before creating the tunnel.
  printf '\nCloudflare zone check for: %s\n' "$ROOT_DOMAIN"
  printf 'The route command must create exactly %s, not append another domain.\n' "$HOSTNAME"
  confirm "Have you verified that $ROOT_DOMAIN is an active zone in this Cloudflare account?" ||
    die "Stopped before creating DNS/tunnel resources. Verify the correct Cloudflare account/zone."

  TUNNEL_ID="$("$CF" tunnel create "$TUNNEL" 2>&1 | tee "$LOGDIR/tunnel-create-$TUNNEL.log" | sed -nE 's/.*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}).*/\1/p' | tail -n1)"
  [[ "$TUNNEL_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Could not determine new tunnel ID. Inspect $LOGDIR/tunnel-create-$TUNNEL.log"

  CREDENTIALS="$HOME/.cloudflared/$TUNNEL_ID.json"
  [[ -s "$CREDENTIALS" ]] || die "Tunnel credentials file not found: $CREDENTIALS"

  CONFIG="$CF_CONFIG_DIR/$TUNNEL.yml"
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

  say "Validating tunnel configuration..."
  "$CF" tunnel --config "$CONFIG" ingress validate || die "Tunnel ingress validation failed."

  say "Creating DNS route for exact hostname: $HOSTNAME"
  if ! "$CF" tunnel route dns "$TUNNEL_ID" "$HOSTNAME" 2>&1 | tee "$LOGDIR/dns-$TUNNEL.log"; then
    warn "DNS route failed. Tunnel/config are preserved for inspection."
    save_state
    die "DNS setup failed. Check Cloudflare zone/account; do not rerun blindly."
  fi

  save_state
  say "Starting the dedicated tunnel..."
  nohup "$CF" tunnel --no-autoupdate --config "$CONFIG" run "$TUNNEL_ID" \
    >> "$LOGDIR/cloudflared-$TUNNEL.log" 2>&1 < /dev/null &
  sleep 4

  say "Checking DNS and HTTPS (up to 60 seconds)..."
  ok=0
  for _ in $(seq 1 12); do
    if curl -fsS --max-time 8 "https://$HOSTNAME/" -o /dev/null; then
      ok=1
      break
    fi
    sleep 5
  done

  printf '\n========== DEPLOYMENT REPORT ==========\n'
  printf 'Panel URL: https://%s/\nLocal endpoint: http://127.0.0.1:%s/\nTunnel: %s\nTunnel ID: %s\n' \
    "$HOSTNAME" "$PORT" "$TUNNEL" "$TUNNEL_ID"
  printf 'Nexus log: %s/logs/nexus.log\nTunnel log: %s/cloudflared-%s.log\nConfig: %s\n' \
    "$PROJECT" "$LOGDIR" "$TUNNEL" "$CONFIG"
  if (( ok )); then
    say "Public HTTPS verification passed."
  else
    warn "HTTPS is not verified yet. Deployment state is saved; do not reinstall."
    warn "Check DNS zone, then inspect: $LOGDIR/cloudflared-$TUNNEL.log"
  fi
}

printf '\nNEXUS PRO — SPRITE DEPLOYMENT MANAGER\n'
printf '1) Install / reinstall\n'
printf '2) Cleanup this script-managed deployment\n'
printf '3) Exit\n'
choice="$(ask 'Choose an option (1-3)')"
case "$choice" in
  1) install_mode ;;
  2) cleanup_install ;;
  3) exit 0 ;;
  *) die "Invalid option." ;;
esac
