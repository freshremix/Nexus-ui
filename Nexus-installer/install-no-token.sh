
cat > /root/nexus-pro-manager.sh <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CF="/root/Argo/cloudflared"
APP="/root/Nexus-ui"
CFHOME="/root/.cloudflared"
BASE="/root/.nexus-pro-deploy"
STATE="$BASE/state.env"
DOMAIN="nxpr.spot4u.ir"
PORT="9127"
PREFIX="nexus-pro-"

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARNING] $*"; }

[[ $EUID -eq 0 ]] || die "Run this script as root."
[[ -x "$CF" ]] || die "cloudflared executable not found: $CF"
command -v curl >/dev/null 2>&1 || die "curl is required."

mkdir -p "$CFHOME"
chmod 700 "$CFHOME"

load_state() {
    TUNNEL_NAME=""
    TUNNEL_ID=""
    CFG=""
    PIDFILE=""
    LOG=""

    [[ -f "$STATE" ]] || return 0

    while IFS='=' read -r key value; do
        value="${value%$'\r'}"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"

        case "$key" in
            TUNNEL_NAME) TUNNEL_NAME="$value" ;;
            TUNNEL_ID) TUNNEL_ID="$value" ;;
            CONFIG) CFG="$value" ;;
            PID) PIDFILE="$value" ;;
        esac
    done < "$STATE"

    if [[ -n "$TUNNEL_NAME" && "$TUNNEL_NAME" =~ ^nexus-pro-[a-zA-Z0-9-]+$ ]]; then
        [[ -n "$CFG" ]] || CFG="$BASE/cloudflared/$TUNNEL_NAME.yml"
        LOG="$BASE/logs/$TUNNEL_NAME.log"
        [[ -n "$PIDFILE" && "$PIDFILE" =~ ^[0-9]+$ ]] && PIDFILE="$BASE/$TUNNEL_NAME.pid"
        [[ -n "$PIDFILE" ]] || PIDFILE="$BASE/$TUNNEL_NAME.pid"
    else
        TUNNEL_NAME=""
        TUNNEL_ID=""
        CFG=""
        PIDFILE=""
        LOG=""
    fi
}

list_nexus_tunnels() {
    local output
    output="$("$CF" tunnel list 2>&1)" || {
        echo "$output"
        return 1
    }

    echo "$output" | awk 'NR==1 || $2 ~ /^nexus-pro-/'
}

cleanup_nexus() {
    echo
    echo "=== Nexus Pro Cleanup ==="
    echo "This removes Nexus Pro tunnel resources only."
    echo "It will NOT remove argo02, cert.pem, shared Cloudflare config,"
    echo "the Nexus application directory, or DNS records."
    echo

    local output
    output="$("$CF" tunnel list 2>&1)" || {
        echo "$output"
        die "Unable to list Cloudflare tunnels. Nothing was removed."
    }

    declare -A names=()
    declare -A ids=()

    while read -r id name rest; do
        [[ "${name:-}" =~ ^nexus-pro-[a-zA-Z0-9-]+$ ]] || continue
        [[ "${id:-}" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
        names["$name"]=1
        ids["$name"]="$id"
    done <<< "$output"

    load_state
    if [[ -n "${TUNNEL_NAME:-}" && -n "${TUNNEL_ID:-}" &&
          "$TUNNEL_NAME" =~ ^nexus-pro-[a-zA-Z0-9-]+$ &&
          "$TUNNEL_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        names["$TUNNEL_NAME"]=1
        ids["$TUNNEL_NAME"]="$TUNNEL_ID"
    fi

    echo "Tunnel names selected for cleanup:"
    if ((${#names[@]} == 0)); then
        echo "  No Nexus Pro tunnels found."
    else
        printf '  %s\n' "${!names[@]}"
    fi

    echo
    read -r -p 'Type CLEAN-NEXUS to continue: ' confirm
    [[ "$confirm" == "CLEAN-NEXUS" ]] || {
        info "Cleanup cancelled."
        return 0
    }

    load_state
    if [[ -n "${PIDFILE:-}" && -f "$PIDFILE" ]]; then
        pid="$(tr -cd '0-9' < "$PIDFILE")"
        if [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]]; then
            cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
            if [[ "$cmd" == *cloudflared* && "$cmd" == *"$BASE/"* ]]; then
                info "Stopping Nexus tunnel process PID $pid"
                kill -TERM "$pid" 2>/dev/null || true
            fi
        fi
    fi

    sleep 1

    for name in "${!names[@]}"; do
        id="${ids[$name]:-}"
        [[ "$id" =~ ^[0-9a-fA-F-]{36}$ ]] || {
            warn "Skipping $name because its UUID could not be verified."
            continue
        }

        info "Deleting Cloudflare tunnel $name ($id)"
        if "$CF" tunnel delete --force "$id"; then
            rm -f -- "$CFHOME/$id.json"
        else
            warn "Could not delete tunnel $name. Check account permissions."
        fi
    done

    if [[ -d "$BASE" ]]; then
        info "Removing Nexus Pro deployment settings: $BASE"
        rm -rf -- "$BASE"
    fi

    echo
    info "Local cleanup finished."
    warn "DNS records are not deleted automatically."
    warn "The Nexus application directory and shared certificate were preserved."
    echo
    "$CF" tunnel list
}

setup_nexus() {
    echo
    echo "=== Nexus Pro Setup ==="

    [[ -d "$APP" ]] || die "Application directory not found: $APP"

    info "Checking the local Nexus application..."
    curl -fsS --max-time 5 "http://127.0.0.1:$PORT/api/health" || {
        echo
        die "Nexus application is not responding on port $PORT. Start it first."
    }
    echo

    if [[ -f "$CFHOME/cert.pem" ]]; then
        info "An existing cert.pem was found. It will not be deleted or overwritten."
        echo "The certificate file alone does not prove account or zone access."
    else
        echo "[ACTION REQUIRED] Cloudflare browser login will start."
        echo "Complete the browser authorization before returning here."
        "$CF" tunnel login || die "Cloudflare login failed. Setup stopped."
        [[ -s "$CFHOME/cert.pem" ]] || die "Login did not create cert.pem."
    fi

    info "Checking Cloudflare tunnel access..."
    "$CF" tunnel list || die "Unable to list tunnels. Setup stopped."

    local default_name
    default_name="${PREFIX}$(date +%Y%m%d%H%M%S)"
    read -r -p "New tunnel name [$default_name]: " name
    name="${name:-$default_name}"

    [[ "$name" =~ ^nexus-pro-[a-zA-Z0-9-]+$ ]] ||
        die "Invalid tunnel name. It must start with nexus-pro-."

    local output
    output="$("$CF" tunnel list)" || die "Unable to list tunnels."

    while read -r id existing rest; do
        [[ "${existing:-}" == "$name" ]] &&
            die "Tunnel name already exists. Choose another name."
    done <<< "$output"

    mkdir -p "$BASE/cloudflared" "$BASE/logs"
    chmod 700 "$BASE" "$BASE/cloudflared" "$BASE/logs"

    info "Creating tunnel: $name"
    "$CF" tunnel create "$name" || die "Tunnel creation failed."

    output="$("$CF" tunnel list)" || die "Tunnel created, but listing failed."

    local uuid=""
    while read -r id existing rest; do
        if [[ "${existing:-}" == "$name" && "${id:-}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
            uuid="$id"
            break
        fi
    done <<< "$output"

    [[ -n "$uuid" ]] || die "Tunnel UUID could not be verified."
    local creds="$CFHOME/$uuid.json"
    [[ -s "$creds" ]] || die "Tunnel credentials not found: $creds"

    local cfg="$BASE/cloudflared/$name.yml"
    local log="$BASE/logs/$name.log"
    local pidfile="$BASE/$name.pid"

    cat > "$cfg" <<EOF
tunnel: $uuid
credentials-file: $creds

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$PORT
  - service: http_status:404
EOF
    chmod 600 "$cfg"

    info "Validating tunnel configuration..."
    "$CF" tunnel --config "$cfg" ingress validate ||
        die "Tunnel configuration validation failed."

    echo
    echo "=== DNS Configuration Required ==="
    echo "Cloudflare zone: spot4u.ir"
    echo "Type:            CNAME"
    echo "Name:            nxpr"
    echo "Target:          $uuid.cfargotunnel.com"
    echo "Proxy:           Proxied (orange cloud)"
    echo
    echo "Update the existing nxpr record if one already exists."
    echo "Do not create duplicate records."
    read -r -p "After verifying DNS in the Cloudflare dashboard, press Enter: " _

    info "Starting the tunnel..."
    nohup "$CF" tunnel --config "$cfg" run "$uuid" >> "$log" 2>&1 &
    local pid=$!
    echo "$pid" > "$pidfile"

    sleep 3
    if ! kill -0 "$pid" 2>/dev/null; then
        tail -n 60 "$log" || true
        die "Tunnel process exited. Review the log above."
    fi

    cat > "$STATE" <<EOF
TUNNEL_NAME=$name
TUNNEL_ID=$uuid
HOSTNAME=$DOMAIN
CONFIG=$cfg
PID=$pid
EOF
    chmod 600 "$STATE"

    echo
    echo "=== Setup Summary ==="
    echo "Tunnel name: $name"
    echo "Tunnel UUID: $uuid"
    echo "Config:      $cfg"
    echo "Log:         $log"
    echo "PID:         $pid"
    echo
    echo "Recent tunnel log:"
    tail -n 25 "$log" || true

    echo
    echo "Testing public HTTPS endpoint..."
    curl -sS --max-time 15 -o /tmp/nexus-pro-test.txt \
        -w 'HTTP %{http_code}\n' "https://$DOMAIN/" || true
    cat /tmp/nexus-pro-test.txt 2>/dev/null || true
    echo
    echo "Useful commands:"
    echo "  tail -f '$log'"
    echo "  '$CF' tunnel list"
    echo "  curl -sS 'http://127.0.0.1:$PORT/api/health'"
}

while true; do
    echo
    echo "========================================"
    echo "       Nexus Pro Tunnel Manager"
    echo "========================================"
    echo "1) Clean up Nexus Pro tunnel settings"
    echo "2) Login / configure / start a new tunnel"
    echo "3) Check local application health"
    echo "4) List Cloudflare tunnels"
    echo "5) Exit"
    echo
    read -r -p "Choose an option [1-5]: " choice

    case "$choice" in
        1) cleanup_nexus ;;
        2) setup_nexus ;;
        3)
            curl -sS --max-time 5 "http://127.0.0.1:$PORT/api/health" || true
            echo
            ;;
        4) "$CF" tunnel list ;;
        5) echo "Goodbye."; exit 0 ;;
        *) echo "Invalid option. Choose 1, 2, 3, 4, or 5." ;;
    esac
done
BASH

chmod 700 /root/nexus-pro-manager.sh
bash -n /root/nexus-pro-manager.sh && echo "Syntax OK"
 /root/nexus-pro-manager.sh
