
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# NEXUS PANEL AND CLOUDFLARE MANAGER
# ============================================================

CLOUDFLARED="/root/Argo/cloudflared"
SPRITE="/.sprite/bin/sprite-env"
NODE="/.sprite/languages/node/nvm/versions/node/v24.18.0/bin/node"
NPM="/.sprite/languages/node/nvm/versions/node/v24.18.0/bin/npm"
GIT="/usr/bin/git"

BASE="/root/nexus-manager"
PROFILES="$BASE/cloudflare-profiles"
CONFIGS="$BASE/tunnel-configs"
INSTALLS="$BASE/installs"
GITHUB_REPO="https://github.com/freshremix/Nexus-ui.git"

PROFILE=""
TUNNEL_NAME=""
TUNNEL_ID=""
INSTALL_NAME=""
INSTALL_DIR=""
APP_DIR=""
PANEL_PORT=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
RESET='\033[0m'

mkdir -p "$PROFILES" "$CONFIGS" "$INSTALLS"
chmod 700 "$BASE" "$PROFILES" "$CONFIGS" "$INSTALLS"

title() {
    clear 2>/dev/null || true
    printf "${CYAN}${BOLD}==============================================\n"
    printf "          NEXUS CLOUDFLARE MANAGER\n"
    printf "==============================================${RESET}\n"
}

success() { printf "${GREEN}[OK]${RESET} %s\n" "$*"; }
warning() { printf "${YELLOW}[WARNING]${RESET} %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
info()    { printf "${CYAN}[INFO]${RESET} %s\n" "$*"; }

pause() {
    printf '\n'
    read -r -p "Press Enter to continue..." _ || true
}

die() {
    error "$*"
    return 1
}

valid_name() {
    [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,100}$ ]]
}

valid_domain() {
    [[ "${1:-}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

check_tools() {
    [[ -x "$CLOUDFLARED" ]] || die "cloudflared not found: $CLOUDFLARED"
    [[ -x "$SPRITE" ]] || die "Sprite CLI not found: $SPRITE"
    [[ -x "$NODE" ]] || die "Node.js not found: $NODE"
    [[ -x "$NPM" ]] || die "npm not found: $NPM"
    [[ -x "$GIT" ]] || die "Git not found: $GIT"
}

# Use the known working npm binary with a clean environment.
run_npm() {
    local workdir="$1"
    shift

    (
        cd "$workdir"
        env -i \
            HOME=/root \
            USER=root \
            LOGNAME=root \
            PATH="/.sprite/languages/node/nvm/versions/node/v24.18.0/bin:/usr/local/bin:/usr/bin:/bin" \
            TMPDIR=/tmp \
            CI=true \
            npm_config_update_notifier=false \
            npm_config_fund=false \
            npm_config_audit=false \
            "$NPM" "$@"
    )
}

profile_path() {
    printf '%s/%s' "$PROFILES" "$1"
}

profile_cert() {
    printf '%s/.cloudflared/cert.pem' "$(profile_path "$1")"
}

profile_cli() {
    local profile="$1"
    shift

    local cert
    cert="$(profile_cert "$profile")"
    [[ -s "$cert" ]] || die "Cloudflare login required for profile: $profile"

    env \
        HOME="$(profile_path "$profile")" \
        TUNNEL_ORIGIN_CERT="$cert" \
        "$CLOUDFLARED" "$@"
}

# ============================================================
# CLOUDFLARE PROFILES
# ============================================================

choose_profile() {
    local p
    local found=0

    printf '\n'
    printf "${CYAN}Available Cloudflare profiles:${RESET}\n"

    for p in "$PROFILES"/*; do
        [[ -d "$p" ]] || continue
        found=1

        if [[ -s "$p/.cloudflared/cert.pem" ]]; then
            printf "  ${GREEN}%s [logged in]${RESET}\n" "$(basename "$p")"
        else
            printf "  ${YELLOW}%s [login required]${RESET}\n" "$(basename "$p")"
        fi
    done

    (( found == 1 )) || warning "No local profiles found."

    read -r -p "Profile name: " PROFILE
    valid_name "$PROFILE" || die "Invalid profile name."
    [[ -s "$(profile_cert "$PROFILE")" ]] || die "Profile is not logged in. Use option 4."
}

login_profile() {
    local dir cert answer

    read -r -p "Profile name: " PROFILE
    valid_name "$PROFILE" || die "Invalid profile name."

    dir="$(profile_path "$PROFILE")"
    cert="$dir/.cloudflared/cert.pem"

    mkdir -p "$dir/.cloudflared"
    chmod 700 "$dir" "$dir/.cloudflared"

    if [[ -s "$cert" ]]; then
        warning "This profile already has a certificate."
        read -r -p "Run login again? [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 0
    fi

    info "Open the URL printed by cloudflared and authorize access."
    HOME="$dir" "$CLOUDFLARED" tunnel login

    if [[ -s "$cert" ]]; then
        chmod 600 "$cert"
        success "Cloudflare login completed: $PROFILE"
    else
        die "Login certificate was not found at: $cert"
    fi
}

# ============================================================
# SPRITE SERVICES
# ============================================================

list_services() {
    printf '\n'
    printf "${CYAN}Sprite services:${RESET}\n"
    "$SPRITE" services list
}

check_service() {
    local service_name
    read -r -p "Sprite service name: " service_name
    [[ -n "$service_name" ]] || die "Service name is required."
    "$SPRITE" services get "$service_name"
}

# ============================================================
# TUNNEL HELPERS
# ============================================================

tunnels_json() {
    profile_cli "$PROFILE" tunnel list --output json
}

find_tunnel_id_by_name() {
    local json="$1"
    local name="$2"

    printf '%s' "$json" | "$NODE" -e '
        let s = "";
        process.stdin.on("data", d => s += d);
        process.stdin.on("end", () => {
            try {
                const list = JSON.parse(s);
                const t = list.find(x => x.name === process.argv[1]);
                if (t) process.stdout.write(t.id || t.uuid || "");
            } catch {
                process.exitCode = 1;
            }
        });
    ' "$name"
}

print_tunnels() {
    local json="$1"

    printf '%s' "$json" | "$NODE" -e '
        let s = "";
        process.stdin.on("data", d => s += d);
        process.stdin.on("end", () => {
            try {
                const list = JSON.parse(s);
                if (!Array.isArray(list) || !list.length) {
                    console.log("No tunnels found.");
                    return;
                }
                for (const t of list) {
                    console.log(`${t.name || "(unnamed)"} | ${t.id || t.uuid || "NO_UUID"}`);
                }
            } catch {
                console.error("Could not parse tunnel list.");
                process.exitCode = 1;
            }
        });
    '
}

list_tunnels() {
    choose_profile
    printf '\n'
    profile_cli "$PROFILE" tunnel list
}

select_existing_tunnel() {
    local json

    json="$(tunnels_json)" || die "Unable to retrieve tunnel list."

    printf '\n'
    print_tunnels "$json"

    read -r -p "Enter exact tunnel name: " TUNNEL_NAME
    valid_name "$TUNNEL_NAME" || die "Invalid tunnel name."

    TUNNEL_ID="$(find_tunnel_id_by_name "$json" "$TUNNEL_NAME")"
    [[ -n "$TUNNEL_ID" ]] || die "Tunnel not found."

    success "Selected tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
}

configure_tunnel() {
    local hostname="$1"
    local port="$2"
    local credentials config

    valid_domain "$hostname" || die "Invalid hostname."
    valid_port "$port" || die "Invalid port."

    credentials="$(profile_path "$PROFILE")/.cloudflared/$TUNNEL_ID.json"

    if [[ ! -s "$credentials" && -s "/root/.cloudflared/$TUNNEL_ID.json" ]]; then
        credentials="/root/.cloudflared/$TUNNEL_ID.json"
    fi

    [[ -s "$credentials" ]] || die "Tunnel credentials not found: $TUNNEL_ID"

    config="$CONFIGS/$TUNNEL_ID.yml"

    if [[ -e "$config" ]]; then
        cp -p "$config" "$config.backup.$(date +%Y%m%d-%H%M%S)"
        success "Existing configuration backed up."
    fi

    cat > "$config" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $credentials
ingress:
  - hostname: $hostname
    service: http://127.0.0.1:$port
  - service: http_status:404
EOF

    chmod 600 "$config"
    success "Configuration saved: $config"
}

route_dns_safely() {
    local hostname="$1"
    local output

    info "Creating DNS route for $hostname"

    if output="$(profile_cli "$PROFILE" tunnel route dns "$TUNNEL_ID" "$hostname" 2>&1)"; then
        printf '%s\n' "$output"
        return 0
    fi

    printf '%s\n' "$output"
    warning "DNS routing failed. Verify the DNS record and selected tunnel manually."
    return 1
}

create_tunnel_service() {
    local port="$1"
    local service_name="nexus-tunnel-$port"
    local config="$CONFIGS/$TUNNEL_ID.yml"

    [[ -s "$config" ]] || die "Tunnel configuration not found."

    if "$SPRITE" services get "$service_name" >/dev/null 2>&1; then
        warning "Service already exists: $service_name"
        warning "Existing service will not be overwritten."
        "$SPRITE" services get "$service_name"
        return 0
    fi

    info "Creating Sprite tunnel service: $service_name"

    "$SPRITE" services create "$service_name" \
        --cmd "$CLOUDFLARED" \
        --args "tunnel,--no-autoupdate,--config,$config,run" \
        --dir "$BASE" \
        --duration 5s \
        --no-stream

    "$SPRITE" services get "$service_name"
}

configure_existing_tunnel_flow() {
    local hostname port

    choose_profile
    select_existing_tunnel

    read -r -p "Hostname: " hostname
    valid_domain "$hostname" || die "Invalid hostname."

    read -r -p "Local service port [9129]: " port
    port="${port:-9129}"
    valid_port "$port" || die "Invalid port."

    configure_tunnel "$hostname" "$port"
    route_dns_safely "$hostname" || return 1
    create_tunnel_service "$port"
}

create_new_tunnel_flow() {
    local new_name hostname port json answer

    choose_profile

    read -r -p "New tunnel name: " new_name
    valid_name "$new_name" || die "Invalid tunnel name."

    json="$(tunnels_json)" || die "Unable to retrieve tunnel list."
    [[ -z "$(find_tunnel_id_by_name "$json" "$new_name")" ]] ||
        die "Tunnel already exists. Use option 3."

    warning "A new remote Cloudflare tunnel will be created."
    read -r -p "Type CREATE to confirm: " answer
    [[ "$answer" == "CREATE" ]] || {
        info "Creation cancelled."
        return 0
    }

    profile_cli "$PROFILE" tunnel create "$new_name"

    json="$(tunnels_json)" || die "Could not refresh tunnel list."
    TUNNEL_ID="$(find_tunnel_id_by_name "$json" "$new_name")"
    [[ -n "$TUNNEL_ID" ]] || die "Could not find new tunnel UUID."

    TUNNEL_NAME="$new_name"
    success "Created tunnel: $TUNNEL_NAME ($TUNNEL_ID)"

    read -r -p "Hostname: " hostname
    valid_domain "$hostname" || die "Invalid hostname."

    read -r -p "Local service port [9129]: " port
    port="${port:-9129}"
    valid_port "$port" || die "Invalid port."

    configure_tunnel "$hostname" "$port"
    route_dns_safely "$hostname" || return 1
    create_tunnel_service "$port"
}

delete_tunnel_flow() {
    local json tunnel_name tunnel_id answer

    choose_profile
    json="$(tunnels_json)" || die "Unable to retrieve tunnel list."
    print_tunnels "$json"

    read -r -p "Exact tunnel name to delete: " tunnel_name
    valid_name "$tunnel_name" || die "Invalid tunnel name."

    tunnel_id="$(find_tunnel_id_by_name "$json" "$tunnel_name")"
    [[ -n "$tunnel_id" ]] || die "Tunnel not found."

    warning "This permanently deletes remote tunnel: $tunnel_name ($tunnel_id)"
    warning "Local configurations, DNS records, and Sprite services are not removed."

    read -r -p "Type DELETE to confirm: " answer
    [[ "$answer" == "DELETE" ]] || {
        info "Deletion cancelled."
        return 0
    }

    profile_cli "$PROFILE" tunnel delete "$tunnel_id"
    success "Tunnel deletion command completed."
}

show_tunnel_info() {
    choose_profile
    select_existing_tunnel
    profile_cli "$PROFILE" tunnel info "$TUNNEL_ID"
}

delete_profile_flow() {
    local dir answer

    printf '\n'
    printf "${CYAN}Local Cloudflare profiles:${RESET}\n"

    for dir in "$PROFILES"/*; do
        [[ -d "$dir" ]] || continue
        printf '  %s\n' "$(basename "$dir")"
    done

    read -r -p "Exact profile name to delete locally: " PROFILE
    valid_name "$PROFILE" || die "Invalid profile name."

    dir="$(profile_path "$PROFILE")"
    [[ -d "$dir" ]] || die "Profile not found."

    warning "This deletes local profile credentials: $dir"
    warning "It does not delete remote tunnels or DNS records."

    read -r -p "Type DELETE to confirm: " answer
    [[ "$answer" == "DELETE" ]] || {
        info "Deletion cancelled."
        return 0
    }

    rm -rf -- "$dir"
    success "Local profile removed."
}

# ============================================================
# NEXUS INSTALLATION
# ============================================================

choose_install_name() {
    local default_name="$1"

    read -r -p "Install name [$default_name]: " INSTALL_NAME
    INSTALL_NAME="${INSTALL_NAME:-$default_name}"

    valid_name "$INSTALL_NAME" || die "Invalid install name."
}

find_app_directory() {
    local root="$1"
    local candidate

    for candidate in "$root" "$root/Nexus-ui" "$root/app" "$root/server"; do
        if [[ -f "$candidate/package.json" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    find "$root" -maxdepth 4 -type f -name package.json -print -quit |
        sed 's#/package.json$##'
}

install_nexus_panel() {
    local default_name="nexus-pro-9129"
    local repository_dir package_file start_script
    local service_name data_dir answer entrypoint

    printf '\n'
    printf "${MAGENTA}${BOLD}==============================================\n"
    printf "              NEXUS PANEL INSTALL\n"
    printf "==============================================${RESET}\n"

    choose_install_name "$default_name"

    INSTALL_DIR="$INSTALLS/$INSTALL_NAME"
    repository_dir="$INSTALL_DIR/repository"
    data_dir="$INSTALL_DIR/data"
    service_name="$INSTALL_NAME"

    if [[ -e "$INSTALL_DIR" ]]; then
        warning "Installation directory already exists: $INSTALL_DIR"
        read -r -p "Use the existing directory without deleting it? [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] ||
            die "Choose another installation name or inspect the directory manually."
    else
        mkdir -p "$INSTALL_DIR"
    fi

    read -r -p "Panel port [9129]: " PANEL_PORT
    PANEL_PORT="${PANEL_PORT:-9129}"
    valid_port "$PANEL_PORT" || die "Invalid panel port."

    # Reuse an existing valid source tree, even if .git is absent.
    # Never delete a non-Git directory or the data directory automatically.
    if [[ -d "$repository_dir/.git" ]]; then
        warning "Git checkout already exists."
        read -r -p "Pull latest changes from GitHub? [y/N]: " answer

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            "$GIT" -C "$repository_dir" pull --ff-only
        fi
    elif [[ -f "$repository_dir/package.json" && -f "$repository_dir/index.js" ]]; then
        warning "Existing application source found without .git."
        info "Reusing existing source; no files will be deleted."
    elif [[ ! -e "$repository_dir" ]]; then
        info "Cloning repository from GitHub..."
        "$GIT" clone "$GITHUB_REPO" "$repository_dir"
    else
        error "Repository path exists but is not a Git checkout or recognized app."
        error "No files were deleted. Inspect: $repository_dir"
        return 1
    fi

    success "Source directory is available."

    APP_DIR="$(find_app_directory "$repository_dir")"
    [[ -n "$APP_DIR" && -f "$APP_DIR/package.json" ]] ||
        die "Could not locate package.json in the repository."

    package_file="$APP_DIR/package.json"
    entrypoint="$APP_DIR/index.js"

    [[ -f "$entrypoint" ]] || {
        error "Expected entrypoint not found: $entrypoint"
        error "This installer currently supports applications with index.js."
        return 1
    }

    printf '\n'
    success "Application source: $APP_DIR"

    info "Checking Node.js and npm with a clean environment..."
    "$NODE" -v
    run_npm "$APP_DIR" -v

    mkdir -p "$data_dir"
    chmod 700 "$INSTALL_DIR" "$data_dir"

    info "Installing Node.js dependencies..."

    if [[ -f "$APP_DIR/package-lock.json" ]]; then
        run_npm "$APP_DIR" ci --no-audit --no-fund
    else
        run_npm "$APP_DIR" install --no-audit --no-fund
    fi

    success "Dependency installation completed."

    start_script="$("$NODE" -e '
        const fs = require("fs");
        const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (p.scripts && p.scripts.start) process.stdout.write(p.scripts.start);
    ' "$package_file")"

    if [[ -z "$start_script" ]]; then
        die "No start script found in package.json."
    fi

    info "Detected start script: $start_script"
    info "Direct entrypoint selected: $entrypoint"

    if "$SPRITE" services get "$service_name" >/dev/null 2>&1; then
        warning "Sprite service already exists: $service_name"
        warning "Existing service was not modified."
        warning "Use another install name or inspect the existing service manually."
        return 1
    fi

    warning "The panel service will be created on port $PANEL_PORT."
    warning "No existing Sprite service will be stopped or deleted."

    read -r -p "Type INSTALL to create the panel service: " answer
    [[ "$answer" == "INSTALL" ]] || {
        info "Cancelled. Source and data directory remain in place."
        return 0
    }

    # Sprite expects one comma-separated --env argument.
    # Use the actual detected application directory and entrypoint.
    "$SPRITE" services create "$service_name" \
        --cmd "$NODE" \
        --args "$entrypoint" \
        --dir "$APP_DIR" \
        --env "PORT=$PANEL_PORT,DATA_DIR=$data_dir" \
        --duration 5s \
        --no-stream

    printf '\n'
    "$SPRITE" services get "$service_name"

    printf '\n'
    info "Checking local HTTP response..."
    if curl -sS --max-time 5 -o /dev/null \
        -w 'HTTP status: %{http_code}\n' \
        "http://127.0.0.1:$PANEL_PORT/"; then
        success "HTTP endpoint responded."
    else
        warning "No HTTP response yet. Check the service state and logs."
    fi

    success "Panel service creation command completed."
    warning "Cloudflare DNS and tunnel configuration were not changed."
}

# ============================================================
# PANEL CHECKS AND INSTALLATIONS
# ============================================================

check_nexus_panel() {
    local service_name port status

    read -r -p "Panel Sprite service name: " service_name
    [[ -n "$service_name" ]] || die "Service name is required."

    "$SPRITE" services get "$service_name"

    read -r -p "Local panel port to test [9129]: " port
    port="${port:-9129}"
    valid_port "$port" || die "Invalid port."

    info "Testing local HTTP endpoint on port $port..."

    if status="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 8 "http://127.0.0.1:$port/")"; then
        success "HTTP status: $status"
    else
        error "Local HTTP check failed."
        return 1
    fi
}

list_nexus_installations() {
    local dir found=0

    printf '\n'
    printf "${CYAN}NEXUS installations:${RESET}\n"

    for dir in "$INSTALLS"/*; do
        [[ -d "$dir" ]] || continue
        found=1

        printf '\n'
        printf "${GREEN}Name:${RESET} %s\n" "$(basename "$dir")"
        printf "Path: %s\n" "$dir"
        [[ -d "$dir/repository" ]] && echo "Repository: present" ||
            echo "Repository: not found"
        [[ -d "$dir/data" ]] && echo "Data directory: present" ||
            echo "Data directory: not found"
    done

    (( found == 1 )) || warning "No NEXUS installation directories found."
}

# ============================================================
# MAIN MENU
# ============================================================

main() {
    check_tools

    local choice

    while true; do
        title

        printf "${WHITE}1)${RESET}  List Sprite services\n"
        printf "${WHITE}2)${RESET}  List Cloudflare tunnels\n"
        printf "${WHITE}3)${RESET}  Configure an existing tunnel\n"
        printf "${WHITE}4)${RESET}  Login to a Cloudflare profile\n"
        printf "${WHITE}5)${RESET}  Create a new Cloudflare tunnel\n"
        printf "${WHITE}6)${RESET}  Check a Sprite service\n"
        printf "${WHITE}7)${RESET}  Delete a Cloudflare tunnel\n"
        printf "${WHITE}8)${RESET}  Show information for a tunnel\n"
        printf "${WHITE}9)${RESET}  Delete a local Cloudflare profile\n"
        printf "${MAGENTA}10)${RESET} Install NEXUS panel from GitHub\n"
        printf "${MAGENTA}11)${RESET} Check NEXUS panel\n"
        printf "${MAGENTA}12)${RESET} List NEXUS installations\n"
        printf "${RED}0)${RESET}  Exit\n"
        printf "${CYAN}----------------------------------------------${RESET}\n"

        read -r -p "Select: " choice || exit 0

        # Guard each action so an error returns to the menu instead
        # of terminating the manager under set -e.
        case "$choice" in
            1)  list_services || warning "Could not list services."; pause ;;
            2)  list_tunnels || warning "Could not list tunnels."; pause ;;
            3)  configure_existing_tunnel_flow || warning "Tunnel configuration failed."; pause ;;
            4)  login_profile || warning "Cloudflare login failed."; pause ;;
            5)  create_new_tunnel_flow || warning "Tunnel creation failed."; pause ;;
            6)  check_service || warning "Service check failed."; pause ;;
            7)  delete_tunnel_flow || warning "Tunnel deletion failed."; pause ;;
            8)  show_tunnel_info || warning "Could not show tunnel information."; pause ;;
            9)  delete_profile_flow || warning "Profile deletion failed."; pause ;;
            10) install_nexus_panel || warning "Panel installation did not complete."; pause ;;
            11) check_nexus_panel || warning "Panel check failed."; pause ;;
            12) list_nexus_installations || warning "Could not list installations."; pause ;;
            0)  exit 0 ;;
            *)  warning "Invalid option."; sleep 1 ;;
        esac
    done
}

main "$@"
