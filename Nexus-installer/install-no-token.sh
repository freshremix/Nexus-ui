
#!/usr/bin/env bash
set -Eeuo pipefail

# Nexus Pro installer for Fly.io Sprites
# Cloudflare Tunnel login; no API Token required.
# Existing argo02 and webtmux are never modified.

CLOUDFLARED="/root/Argo/cloudflared"
PROJECT="/root/Nexus-ui"
BASE="/root/.nexus-pro-deploy"
STATE="$BASE/state.env"

say() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ask() {
  local prompt="$1" default="$2" answer
  read -r -p "$prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
}

[[ $EUID -eq 0 ]] || fail "Run this script as root."
[[ -x "$CLOUDFLARED" ]] || fail "cloudflared not found at $CLOUDFLARED"
[[ -d "$PROJECT" ]] || fail "Project directory not found: $PROJECT"
command -v curl >/dev/null || fail "curl is required."
command -v python3 >/dev/null || fail "python3 is required."

mkdir -p "$BASE/logs" "$BASE/cloudflared"

say "=== Nexus Pro | Cloudflare Tunnel Installer ==="
echo "This installer does not use an API Token."
echo "It will not modify argo02 or webtmux."
echo

if [[ -f "$STATE" ]]; then
  echo "An existing deployment state file was found:"
  echo "$STATE"
  echo "Use the existing deployment or back it up and inspect it first."
  exit 1
fi

DOMAIN="$(ask 'Enter your root domain (example: spot4u.ir)' 'spot4u.ir')"
DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN%.}"

[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
  || fail "Invalid domain format."
[[ "$DOMAIN" == *.* ]] || fail "Enter a complete domain name."

SUBDOMAIN="$(ask 'Enter your subdomain label (example: nxpr)' 'nxpr')"
SUBDOMAIN="${SUBDOMAIN,,}"
[[ "$SUBDOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
  || fail "Invalid subdomain label."

HOSTNAME="$SUBDOMAIN.$DOMAIN"
PORT="$(ask 'Enter the local Nexus Pro port' '9127')"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || fail "Invalid port."

SERVICE="http://127.0.0.1:$PORT"
TUNNEL_NAME="nexus-pro-$(date +%Y%m%d%H%M%S)"
CONFIG="$BASE/cloudflared/$TUNNEL_NAME.yml"
LOG="$BASE/logs/$TUNNEL_NAME.log"
PIDFILE="$BASE/$TUNNEL_NAME.pid"

echo
echo "Review your settings:"
echo "  Domain:       $DOMAIN"
echo "  Public host:  $HOSTNAME"
echo "  Local service:$SERVICE"
echo "  Tunnel name:  $TUNNEL_NAME"
echo
read -r -p "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || fail "Cancelled."

say "Checking the local Nexus Pro service..."
if ! curl -fsS --max-time 5 "$SERVICE/" >/dev/null; then
  echo "Warning: $SERVICE did not return a successful HTTP response."
  read -r -p "Continue anyway? Type YES: " CONTINUE
  [[ "$CONTINUE" == "YES" ]] || fail "Start Nexus Pro and run this installer again."
fi

say "Step 1/5: Cloudflare login"
echo "A browser URL will appear. Open it and authorize the correct domain."
echo "Select $DOMAIN if it is listed."
echo "Do not select a different domain."
"$CLOUDFLARED" tunnel login

[[ -s /root/.cloudflared/cert.pem ]] \
  || fail "Cloudflare login did not produce /root/.cloudflared/cert.pem"

say "Step 2/5: Creating a new tunnel"
CREATE_OUTPUT="$("$CLOUDFLARED" tunnel create "$TUNNEL_NAME" 2>&1)" || {
  printf '%s\n' "$CREATE_OUTPUT"
  fail "Tunnel creation failed. No existing tunnel was deleted."
}
printf '%s\n' "$CREATE_OUTPUT"

TUNNEL_ID="$(printf '%s\n' "$CREATE_OUTPUT" |
  grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' |
  head -n 1 || true)"

[[ "$TUNNEL_ID" =~ ^[0-9a-f-]{36}$ ]] \
  || fail "Could not identify the new tunnel UUID. Inspect the output above."

CREDENTIALS="/root/.cloudflared/$TUNNEL_ID.json"
[[ -s "$CREDENTIALS" ]] \
  || fail "Tunnel credentials file not found: $CREDENTIALS"

say "Step 3/5: Writing tunnel configuration"
cat > "$CONFIG" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CREDENTIALS

ingress:
  - hostname: $HOSTNAME
    service: $SERVICE
  - service: http_status:404
EOF

chmod 600 "$CONFIG"

say "Step 4/5: DNS setup — manual dashboard method"
echo
echo "To avoid creating a DNS record in the WRONG Cloudflare zone,"
echo "this installer will NOT run 'tunnel route dns' automatically."
echo
echo "Open Cloudflare Dashboard and select the $DOMAIN zone."
echo "Create this DNS record:"
echo
echo "  Type:    CNAME"
echo "  Name:    $SUBDOMAIN"
echo "  Target:  $TUNNEL_ID.cfargotunnel.com"
echo "  Proxy:   Proxied (orange cloud)"
echo
echo "Make sure the selected zone is exactly: $DOMAIN"
echo "Do not create the record under eagerrunner.ir unless that is your intended domain."
read -r -p "After creating/verifying the record, type YES: " DNS_OK
[[ "$DNS_OK" == "YES" ]] || {
  echo "Tunnel and configuration created, but not started."
  echo "Finish DNS setup, then rerun only after checking the files in $BASE."
  exit 1
}

say "Step 5/5: Saving deployment state"
cat > "$STATE" <<EOF
TUNNEL_NAME='$TUNNEL_NAME'
TUNNEL_ID='$TUNNEL_ID'
DOMAIN='$DOMAIN'
HOSTNAME='$HOSTNAME'
PORT='$PORT'
CONFIG='$CONFIG'
LOG='$LOG'
PIDFILE='$PIDFILE'
CREDENTIALS='$CREDENTIALS'
EOF
chmod 600 "$STATE"

say "Starting Cloudflare Tunnel"
nohup "$CLOUDFLARED" tunnel --config "$CONFIG" run "$TUNNEL_ID" \
  >> "$LOG" 2>&1 </dev/null &
echo $! > "$PIDFILE"
sleep 2

if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  say "Installation commands completed."
  echo "Panel URL: https://$HOSTNAME"
  echo "Tunnel log: $LOG"
  echo "State file: $STATE"
  echo
  echo "Check tunnel logs with:"
  echo "tail -n 50 '$LOG'"
else
  echo "Tunnel may have failed to start. Check:"
  echo "tail -n 80 '$LOG'"
  exit 1
fi
