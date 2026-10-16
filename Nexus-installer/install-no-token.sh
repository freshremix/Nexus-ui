
cat > /root/nexus-manager.sh <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CF="/root/Argo/cloudflared"
APP_DIR="/root/Nexus-ui"
BASE="/root/.nexus-pro-deploy"
CF_DIR="/root/.cloudflared"
PORT="9127"
DOMAIN="spot4u.ir"
HOSTNAME="nxpr.spot4u.ir"

pause() {
  echo
  read -r -p "Press Enter to return to the menu..."
}

check_cf() {
  if [[ ! -x "$CF" ]]; then
    echo "ERROR: cloudflared binary not found: $CF"
    return 1
  fi
}

get_state_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}='\\(.*\\)'$/\\1/p" "$file" | head -n 1
}

tunnel_exists() {
  local id="$1"
  "$CF" tunnel list 2>/dev/null |
    awk 'NR>1 {print $1}' |
    grep -Fxq "$id"
}

install_nexus() {
  echo
  echo "========== INSTALL NEXUS TUNNEL =========="

  check_cf || { pause; return; }

  if [[ ! -d "$APP_DIR" ]]; then
    echo "ERROR: Nexus directory not found: $APP_DIR"
    pause
    return
  fi

  echo "Checking local Nexus application..."
  if ! curl -fsS --max-time 5 "http://127.0.0.1:$PORT/" >/dev/null; then
    echo "ERROR: Nexus is not responding on port $PORT."
    echo "Start Nexus before installing the tunnel."
    pause
    return
  fi
  echo "Local Nexus endpoint: OK"

  echo
  echo "Existing Cloudflare certificates will not be deleted."
  echo "The existing argo02 tunnel will not be modified."
  read -r -p "Continue with Cloudflare login? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    echo "Cancelled."
    pause
    return
  }

  echo
  echo "Starting browser-based Cloudflare login..."
  if ! "$CF" tunnel login; then
    echo
    echo "ERROR: Cloudflare login failed."
    echo "No tunnel will be created."
    echo "Do not delete /root/.cloudflared/cert.pem."
    echo "If the certificate already exists, login may be unnecessary"
    echo "for an existing named tunnel. Verify the correct account/zone"
    echo "before proceeding."
    pause
    return
  fi

  local stamp tunnel_name tunnel_id credentials config log pidfile
  stamp="$(date +%Y%m%d%H%M%S)"
  tunnel_name="nexus-pro-$stamp"

  echo
  echo "Creating dedicated tunnel: $tunnel_name"
  if ! "$CF" tunnel create "$tunnel_name"; then
    echo "ERROR: Tunnel creation failed."
    echo "No further setup will be attempted."
    pause
    return
  fi

  # Query the exact name and obtain its UUID.
  tunnel_id="$("$CF" tunnel list --output json 2>/dev/null |
    python3 -c '
import json,sys
name=sys.argv[1]
data=json.load(sys.stdin)
items=[x for x in data if x.get("name")==name]
print(items[0]["id"] if len(items)==1 else "")
' "$tunnel_name")" || true

  if [[ -z "$tunnel_id" ]]; then
    echo "ERROR: Could not identify the new tunnel UUID."
    echo "Check the tunnel list before retrying."
    pause
    return
  fi

  credentials="$CF_DIR/$tunnel_id.json"
  if [[ ! -f "$credentials" ]]; then
    echo "ERROR: Credentials file not found: $credentials"
    echo "Tunnel ID: $tunnel_id"
    echo "No running connector was started."
    pause
    return
  fi

  mkdir -p "$BASE/cloudflared" "$BASE/logs"
  config="$BASE/cloudflared/$tunnel_name.yml"
  log="$BASE/logs/$tunnel_name.log"
  pidfile="$BASE/$tunnel_name.pid"

  cat > "$config" <<EOF
tunnel: $tunnel_id
credentials-file: $credentials

ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:$PORT
  - service: http_status:404
EOF

  chmod 600 "$config" "$credentials"

  if ! "$CF" tunnel --config "$config" ingress validate; then
    echo "ERROR: Tunnel configuration validation failed."
    pause
    return
  fi

  cat > "$BASE/state.env" <<EOF
TUNNEL_NAME='$tunnel_name'
TUNNEL_ID='$tunnel_id'
DOMAIN='$DOMAIN'
HOSTNAME='$HOSTNAME'
PORT='$PORT'
CONFIG='$config'
LOG='$log'
PIDFILE='$pidfile'
CREDENTIALS='$credentials'
EOF
  chmod 600 "$BASE/state.env"

  echo
  echo "Tunnel created successfully."
  echo "Tunnel name: $tunnel_name"
  echo "Tunnel ID:   $tunnel_id"
  echo
  echo "Create or verify this DNS record in the Cloudflare dashboard:"
  echo "Zone:   $DOMAIN"
  echo "Type:   CNAME"
  echo "Name:   nxpr"
  echo "Target: $tunnel_id.cfargotunnel.com"
  echo "Proxy:  Proxied (orange cloud)"
  echo
  echo "Do not use 'tunnel route dns' until the correct zone/account"
  echo "has been verified."

  read -r -p "Press Enter after checking the DNS record to start the tunnel..."

  if [[ -f "$pidfile" ]]; then
    oldpid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
      echo "ERROR: This tunnel appears to be running already."
      pause
      return
    fi
  fi

  nohup "$CF" tunnel --no-autoupdate --config "$config" run \
    >> "$log" 2>&1 < /dev/null &
  local newpid=$!
  echo "$newpid" > "$pidfile"
  sleep 3

  if ! kill -0 "$newpid" 2>/dev/null; then
    echo "WARNING: The tunnel process may have exited."
    echo "Check log: $log"
    tail -n 20 "$log" 2>/dev/null || true
    pause
    return
  fi

  echo
  echo "Tunnel process started."
  echo "Local endpoint:"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
    --max-time 5 "http://127.0.0.1:$PORT/" || true
  echo
  echo "Public endpoint:"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
    --max-time 15 "https://$HOSTNAME/" || true
  echo
  echo "Log: $log"
  pause
}

remove_nexus() {
  echo
  echo "========== REMOVE NEXUS TUNNEL =========="
  echo "This removes only the tunnel recorded in the Nexus state file."
  echo "It does not remove the Nexus application, DNS record, argo02,"
  echo "webtmux, or the shared cert.pem."
  echo
  read -r -p "Type REMOVE-NEXUS to continue: " answer
  [[ "$answer" == "REMOVE-NEXUS" ]] || {
    echo "Cancelled."
    pause
    return
  }

  check_cf || { pause; return; }

  local state="$BASE/state.env"
  local tunnel_id="" tunnel_name="" pidfile="" pid=""

  if [[ -f "$state" ]]; then
    tunnel_id="$(get_state_value TUNNEL_ID "$state" || true)"
    tunnel_name="$(get_state_value TUNNEL_NAME "$state" || true)"
    pidfile="$(get_state_value PIDFILE "$state" || true)"
  fi

  if [[ -n "$pidfile" && -f "$pidfile" ]]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      echo "Stopping recorded Nexus connector process..."
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
  fi

  if [[ -n "$tunnel_id" ]]; then
    if [[ "$tunnel_id" == "31ba82dc-0a8a-4d74-be5f-2741dffdc5a3" ]]; then
      echo "SAFETY ERROR: Refusing to delete protected argo02 tunnel."
      pause
      return
    fi

    if tunnel_exists "$tunnel_id"; then
      echo "Deleting dedicated Nexus tunnel: $tunnel_name ($tunnel_id)"
      if ! "$CF" tunnel delete "$tunnel_id"; then
        echo "ERROR: Cloudflare tunnel deletion failed."
        echo "Local state and credentials were preserved."
        pause
        return
      fi
    else
      echo "Tunnel is not listed; skipping Cloudflare deletion."
    fi
  else
    echo "No valid Nexus state file found."
    echo "No Cloudflare tunnel will be deleted automatically."
  fi

  rm -rf -- "$BASE"
  echo
  echo "Nexus deployment files removed."
  echo "DNS records were not deleted; remove the nxpr record manually"
  echo "from the correct Cloudflare zone only if you no longer need it."
  pause
}

while true; do
  clear 2>/dev/null || true
  echo "=========================================="
  echo "         NEXUS PRO TUNNEL MANAGER"
  echo "=========================================="
  echo "1) Install / configure a new tunnel"
  echo "2) Remove Nexus tunnel and deployment files"
  echo "3) Exit"
  echo "------------------------------------------"
  read -r -p "Select an option [1-3]: " choice

  case "$choice" in
    1) install_nexus ;;
    2) remove_nexus ;;
    3) echo "Goodbye."; exit 0 ;;
    *) echo "Invalid option. Choose 1, 2, or 3."; sleep 1 ;;
  esac
done
SCRIPT

chmod 700 /root/nexus-manager.sh
bash -n /root/nexus-manager.sh && echo "Syntax OK"
/root/nexus-manager.sh
