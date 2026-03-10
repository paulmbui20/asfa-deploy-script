#!/bin/bash

# =============================================================
# ASFA Django Application — Automated Deployment Script
# Caddy (in Docker Compose) for reverse proxy + TLS
# Security: Fail2Ban, iptables-persistent, auto-ban cron,
#           Caddy attack-blocking, UFW, rate limiting
# =============================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header()  { echo -e "\n${BLUE}============================================${NC}\n${BLUE}$1${NC}\n${BLUE}============================================${NC}\n"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${CYAN}ℹ $1${NC}"; }
print_step()    { echo -e "${MAGENTA}▶ $1${NC}"; }

# ---------------------------------------------------------------------------
# Safe read wrapper — never fails even with set -e
# ---------------------------------------------------------------------------
safe_read() {
    # Usage: safe_read [-s] "prompt" VARNAME [default]
    local secret=false
    if [[ "${1:-}" == "-s" ]]; then
        secret=true
        shift
    fi
    local prompt="$1"
    local varname="$2"
    local default="${3:-}"

    if $secret; then
        IFS= read -rs -p "$prompt" "$varname" </dev/tty || true
        echo
    else
        IFS= read -r -p "$prompt" "$varname" </dev/tty || true
    fi

    # Apply default if empty
    if [[ -z "${!varname}" && -n "$default" ]]; then
        printf -v "$varname" '%s' "$default"
    fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        print_info "Sudo access required — you may be prompted for your password."
        sudo -v
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot determine OS. Ubuntu or Debian required."
        exit 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    OS=$NAME; VER=$VERSION_ID
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        print_error "Unsupported OS: $OS. This script requires Ubuntu or Debian."
        exit 1
    fi
    print_success "OS: $OS $VER"
}

generate_secret_key()       { python3 -c "import secrets; print(secrets.token_urlsafe(50))"; }
generate_postgres_password() { openssl rand -base64 32; }

# ---------------------------------------------------------------------------
# Load / save deployment config
# ---------------------------------------------------------------------------
DEFAULT_APP_DIR="/opt/apps/asfa"

load_existing_config() {
    CONFIG_FILE="${APP_DIR:-$DEFAULT_APP_DIR}/.deployment_config"
    if [[ -f "$CONFIG_FILE" ]]; then
        print_info "Found existing configuration at $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        EXISTING_CONFIG=true
    else
        EXISTING_CONFIG=false
    fi
}

save_config() {
    CONFIG_FILE="$APP_DIR/.deployment_config"
    cat > "$CONFIG_FILE" << EOF
# ASFA Deployment Configuration — $(date)
DOMAIN_NAME="$DOMAIN_NAME"
DOCKER_USERNAME="$DOCKER_USERNAME"
APP_DIR="$APP_DIR"
SETUP_SSL="$SETUP_SSL"
SECURITY_ENABLED="$SECURITY_ENABLED"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
EOF
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved: $CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Free ports 80 & 443
# ---------------------------------------------------------------------------
free_ports() {
    print_header "Freeing Ports 80 & 443"

    # Stop / purge host Nginx
    if systemctl is-active --quiet nginx 2>/dev/null; then
        print_warning "Stopping host Nginx..."
        sudo systemctl stop nginx || true
    fi
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        sudo systemctl disable nginx || true
    fi
    if dpkg -l nginx 2>/dev/null | grep -q '^ii'; then
        print_info "Purging host Nginx packages..."
        sudo apt-get purge -y nginx nginx-common nginx-core nginx-full 2>/dev/null || true
        sudo apt-get autoremove -y || true
        sudo rm -rf /etc/nginx 2>/dev/null || true
        print_success "Host Nginx purged"
    else
        print_info "Host Nginx not installed — skipping purge"
    fi

    # Stop Coolify / any Docker container holding ports
    if command -v docker &>/dev/null; then
        COOLIFY_CONTAINERS=$(docker ps --filter "label=com.docker.compose.project=coolify" -q 2>/dev/null || true)
        if [[ -n "$COOLIFY_CONTAINERS" ]]; then
            print_warning "Stopping Coolify containers..."
            docker stop $COOLIFY_CONTAINERS || true
        fi
        for PORT in 80 443; do
            CONTAINER=$(docker ps --format '{{.ID}} {{.Ports}}' 2>/dev/null \
                | grep "0.0.0.0:${PORT}->" | awk '{print $1}' || true)
            if [[ -n "$CONTAINER" ]]; then
                print_warning "Container $CONTAINER holds port $PORT — stopping..."
                docker stop "$CONTAINER" || true
            fi
        done
    fi

    # Hard-kill anything still on 80/443
    for PORT in 80 443; do
        while IFS= read -r PID; do
            [[ -z "$PID" ]] && continue
            print_warning "Port $PORT still held by PID $PID — force-killing..."
            sudo kill -9 "$PID" 2>/dev/null || true
        done < <(sudo lsof -ti tcp:"$PORT" 2>/dev/null || true)
    done

    # Verify
    STILL_BUSY=""
    for PORT in 80 443; do
        if sudo lsof -ti tcp:"$PORT" &>/dev/null 2>&1; then
            STILL_BUSY="$STILL_BUSY $PORT"
        fi
    done
    if [[ -n "$STILL_BUSY" ]]; then
        print_error "Could not free port(s):$STILL_BUSY — free them manually and re-run."
        exit 1
    fi
    print_success "Ports 80 and 443 are free"
}

# ---------------------------------------------------------------------------
# SSL option
# ---------------------------------------------------------------------------
configure_ssl_option() {
    echo
    print_info "SSL / TLS Configuration"
    echo "  1) Automatic HTTPS — Caddy obtains & renews Let's Encrypt certs"
    echo "     (requires a public domain with DNS A record → this server)"
    echo "  2) Cloudflare proxy — Caddy listens HTTP only; Cloudflare provides HTTPS"
    safe_read "Select option [1/2]: " SSL_OPTION "1"

    if [[ "$SSL_OPTION" == "1" ]]; then
        SETUP_SSL="letsencrypt"
        print_success "Mode: Automatic HTTPS (Caddy + Let's Encrypt)"
        print_warning "Ensure DNS A record for $DOMAIN_NAME points to this server before starting."
    else
        SETUP_SSL="cloudflare"
        print_success "Mode: HTTP-only (Cloudflare handles TLS)"
        print_info "Set Cloudflare SSL/TLS to 'Flexible' in the dashboard."
    fi
}

# ---------------------------------------------------------------------------
# Security option
# ---------------------------------------------------------------------------
configure_security_option() {
    print_header "Security Configuration"
    echo "Enable advanced security features? (Recommended)"
    echo "  • Fail2Ban — SSH + HTTP attack jails"
    echo "  • iptables-persistent — bans survive reboots"
    echo "  • Auto-ban cron — scans logs every minute, bans new attackers"
    echo "  • Caddy — silent 444 drops for PHP/exploit paths"
    echo "  • Rate limiting (Caddy)"
    echo "  • DDoS / connection-state iptables rules"
    echo
    safe_read "Enable security features? [Y/n]: " ENABLE_SECURITY "Y"

    if [[ "$ENABLE_SECURITY" =~ ^[Yy]$ ]]; then
        SECURITY_ENABLED="true"
        if [[ -n "${ADMIN_EMAIL:-}" ]]; then
            safe_read "Admin email for alerts [$ADMIN_EMAIL]: " NEW_ADMIN_EMAIL "$ADMIN_EMAIL"
            ADMIN_EMAIL="${NEW_ADMIN_EMAIL:-$ADMIN_EMAIL}"
        else
            safe_read "Admin email for alerts: " ADMIN_EMAIL ""
            while [[ -z "$ADMIN_EMAIL" ]]; do
                print_warning "Email cannot be empty"
                safe_read "Admin email: " ADMIN_EMAIL ""
            done
        fi
        print_success "Security features will be enabled"
    else
        SECURITY_ENABLED="false"
        ADMIN_EMAIL=""
        print_warning "Security features skipped (not recommended)"
    fi
}

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------
gather_config() {
    print_header "Configuration Setup"

    APP_DIR="${APP_DIR:-$DEFAULT_APP_DIR}"
    load_existing_config

    # ── Re-use existing config? ────────────────────────────────────────────
    if [[ "$EXISTING_CONFIG" == "true" ]]; then
        print_success "Existing deployment detected!"
        echo
        echo "  Domain:      $DOMAIN_NAME"
        echo "  Docker User: $DOCKER_USERNAME"
        echo "  App Dir:     $APP_DIR"
        echo "  SSL:         ${SETUP_SSL:-letsencrypt}"
        echo "  Security:    ${SECURITY_ENABLED:-false}"
        echo
        safe_read "Use existing configuration? [Y/n]: " USE_EXISTING "Y"

        if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
            print_info "Using saved configuration"
            safe_read -s "Docker Hub password/token: " DOCKER_PASSWORD ""
            while [[ -z "$DOCKER_PASSWORD" ]]; do
                print_warning "Password cannot be empty"
                safe_read -s "Docker Hub password/token: " DOCKER_PASSWORD ""
            done
            CREATE_USER="n"
            SETUP_FIREWALL="n"
            REUSE_CONFIG="true"
            return 0
        fi
        print_info "Reconfiguring..."
    fi

    # Reset re-deploy flag on full reconfigure
    REUSE_CONFIG="false"
    CREATE_USER="n"
    SETUP_FIREWALL="n"

    # ── Domain ────────────────────────────────────────────────────────────
    safe_read "Domain name${DOMAIN_NAME:+ [$DOMAIN_NAME]}: " NEW_DOMAIN ""
    DOMAIN_NAME="${NEW_DOMAIN:-${DOMAIN_NAME:-}}"
    while [[ -z "$DOMAIN_NAME" ]]; do
        print_warning "Domain cannot be empty"
        safe_read "Domain name (e.g. example.com): " DOMAIN_NAME ""
    done

    # ── Docker Hub ────────────────────────────────────────────────────────
    print_info "Docker Hub credentials are required to pull the private image"
    safe_read "Docker Hub username${DOCKER_USERNAME:+ [$DOCKER_USERNAME]}: " NEW_DU ""
    DOCKER_USERNAME="${NEW_DU:-${DOCKER_USERNAME:-}}"
    while [[ -z "$DOCKER_USERNAME" ]]; do
        print_warning "Username cannot be empty"
        safe_read "Docker Hub username: " DOCKER_USERNAME ""
    done

    safe_read -s "Docker Hub password/token: " DOCKER_PASSWORD ""
    while [[ -z "$DOCKER_PASSWORD" ]]; do
        print_warning "Password cannot be empty"
        safe_read -s "Docker Hub password/token: " DOCKER_PASSWORD ""
    done

    # ── App directory ─────────────────────────────────────────────────────
    safe_read "Application directory [$APP_DIR]: " NEW_APP_DIR "$APP_DIR"
    APP_DIR="${NEW_APP_DIR:-$APP_DIR}"

    # ── New-install-only options ──────────────────────────────────────────
    if [[ "$EXISTING_CONFIG" != "true" ]]; then
        safe_read "Create dedicated 'deployer' user? [Y/n]: " CREATE_USER "Y"
        safe_read "Configure UFW firewall? [Y/n]: " SETUP_FIREWALL "Y"
    fi

    # ── SSL ───────────────────────────────────────────────────────────────
    if [[ "$EXISTING_CONFIG" == "true" && -n "${SETUP_SSL:-}" ]]; then
        print_info "Current SSL: $SETUP_SSL"
        safe_read "Keep existing SSL config? [Y/n]: " KEEP_SSL "Y"
        [[ ! "$KEEP_SSL" =~ ^[Yy]$ ]] && configure_ssl_option
    else
        configure_ssl_option
    fi

    # ── Security ──────────────────────────────────────────────────────────
    if [[ "$EXISTING_CONFIG" == "true" && -n "${SECURITY_ENABLED:-}" ]]; then
        print_info "Current security: $SECURITY_ENABLED"
        safe_read "Keep existing security config? [Y/n]: " KEEP_SEC "Y"
        [[ ! "$KEEP_SEC" =~ ^[Yy]$ ]] && configure_security_option
    else
        configure_security_option
    fi

    # ── Summary ───────────────────────────────────────────────────────────
    print_header "Configuration Summary"
    echo "  Domain:        $DOMAIN_NAME"
    echo "  Docker User:   $DOCKER_USERNAME"
    echo "  App Directory: $APP_DIR"
    echo "  Deployer user: $CREATE_USER"
    echo "  Firewall:      $SETUP_FIREWALL"
    echo "  SSL:           $SETUP_SSL"
    echo "  Security:      $SECURITY_ENABLED"
    [[ "$SECURITY_ENABLED" == "true" ]] && echo "  Admin Email:   $ADMIN_EMAIL"
    echo

    safe_read "Proceed with installation? [Y/n]: " CONFIRM "Y"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# System update
# ---------------------------------------------------------------------------
update_system() {
    print_header "Updating System Packages"
    sudo apt-get update -qq
    sudo apt-get upgrade -y
    sudo apt-get install -y curl wget git ufw nano lsof jq python3 openssl \
        mailutils sendmail iptables-persistent netfilter-persistent
    # Ensure ufw wasn't removed by iptables-persistent conflict
    sudo apt-get install -y ufw
    print_success "System packages updated"

    # Redis: fix vm.overcommit_memory warning (prevents background save failures)
    print_info "Applying kernel tuning for Redis..."
    if ! grep -q "vm.overcommit_memory" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    sudo sysctl vm.overcommit_memory=1 2>/dev/null || true

    # Disable Transparent Huge Pages (reduces Redis latency)
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null 2>&1 || true
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag  > /dev/null 2>&1 || true

    # Persist THP disable across reboots via rc.local
    if [[ ! -f /etc/rc.local ]] || ! grep -q "transparent_hugepage" /etc/rc.local 2>/dev/null; then
        sudo tee /etc/rc.local > /dev/null << 'RCEOF'
#!/bin/bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
sysctl vm.overcommit_memory=1
exit 0
RCEOF
        sudo chmod +x /etc/rc.local
    fi
    print_success "Kernel tuning applied (Redis will run without warnings)"
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
install_docker() {
    print_header "Installing Docker"
    if command -v docker &>/dev/null; then
        print_warning "Docker already installed: $(docker --version)"
    else
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sudo sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        sudo usermod -aG docker "$USER"
        print_success "Docker installed"
    fi

    if docker compose version &>/dev/null; then
        print_warning "Docker Compose already installed: $(docker compose version)"
    else
        print_info "Installing Docker Compose plugin..."
        sudo apt-get install -y docker-compose-plugin
        print_success "Docker Compose installed"
    fi
}

# ---------------------------------------------------------------------------
# Deployer user
# ---------------------------------------------------------------------------
create_deployer_user() {
    if [[ "$CREATE_USER" =~ ^[Yy]$ ]]; then
        print_header "Creating Deployer User"
        if id "deployer" &>/dev/null; then
            print_warning "User 'deployer' already exists"
        else
            sudo useradd -m -s /bin/bash deployer
            sudo usermod -aG docker deployer
            sudo mkdir -p /home/deployer/.ssh
            sudo chmod 700 /home/deployer/.ssh
            print_success "User 'deployer' created and added to docker group"
        fi
    fi
}

# ---------------------------------------------------------------------------
# App directory + clone
# ---------------------------------------------------------------------------
setup_app_directory() {
    print_header "Setting Up Application Directory"
    sudo mkdir -p "$APP_DIR"
    sudo chown -R "$USER:$USER" "$APP_DIR"
    print_success "Directory ready: $APP_DIR"
}

clone_repository() {
    print_header "Cloning Repository"
    cd "$APP_DIR"
    if [[ -d ".git" ]]; then
        print_warning "Repository exists — pulling latest changes..."
        git pull || true
    else
        git clone https://github.com/paulmbui20/asfa-deploy-script.git .
    fi
    print_success "Repository ready"
}

# ---------------------------------------------------------------------------
# Docker Hub login
# ---------------------------------------------------------------------------
docker_login() {
    print_header "Logging into Docker Hub"
    echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
    print_success "Docker Hub login successful"
}

# ---------------------------------------------------------------------------
# Caddyfile — with security blocks
# ---------------------------------------------------------------------------
write_caddyfile() {
    print_header "Generating Caddyfile"
    CADDY_DIR="$APP_DIR/caddy"
    mkdir -p "$CADDY_DIR"

    # Security block — Caddy requires { on its OWN line (no inline blocks)
    # path_regexp must be a single unbroken line (no backslash continuation)
    SECURITY_SNIPPET='
    # ── Block PHP probes ────────────────────────────────────────────────
    @php_probe path_regexp (?i)\.php$
    handle @php_probe {
        respond "" 444
    }

    # ── Block common exploit paths ──────────────────────────────────────
    @exploit_paths path_regexp (?i)/(phpunit|eval-stdin|invokefunction|call_user_func|pearcmd|auto_prepend_file|allow_url_include|xmlrpc\.php|containers/json|hello\.world|laravel|thinkphp|yii|zend)
    handle @exploit_paths {
        respond "" 444
    }

    # ── Block WordPress probing ─────────────────────────────────────────
    @wp_probe path_regexp (?i)/wp-(admin|login|content|includes|json)
    handle @wp_probe {
        respond "" 444
    }

    # ── Block .env / .git / hidden files ───────────────────────────────
    @dotfiles path_regexp (?i)(^/\.|/\.env|/\.git|/\.svn)
    handle @dotfiles {
        respond "" 444
    }
'

    if [[ "$SETUP_SSL" == "letsencrypt" ]]; then
        cat > "$CADDY_DIR/Caddyfile" << EOF
# =============================================================
# Caddyfile — Automatic HTTPS via Let's Encrypt
# =============================================================

$DOMAIN_NAME, www.$DOMAIN_NAME {

    log {
        output file /var/log/caddy/access.log {
            roll_size     100mb
            roll_keep     5
            roll_keep_for 720h
        }
        format json
        level  INFO
    }

    encode zstd gzip

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options            "SAMEORIGIN"
        X-Content-Type-Options     "nosniff"
        X-XSS-Protection           "1; mode=block"
        Referrer-Policy            "strict-origin-when-cross-origin"
        Permissions-Policy         "geolocation=(), microphone=(), camera=()"
        -Server
    }
$SECURITY_SNIPPET
    # ── Health check (no rate limit) ───────────────────────────────────
    handle /health/ {
        reverse_proxy web:8000
    }

    # ── Admin ──────────────────────────────────────────────────────────
    handle /admin/* {
        reverse_proxy web:8000 {
            header_up Host              {host}
            header_up X-Real-IP         {remote_host}
            header_up X-Forwarded-For   {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # ── Catch-all (WebSocket-aware) ────────────────────────────────────
    handle {
        reverse_proxy web:8000 {
            header_up Host              {host}
            header_up X-Real-IP         {remote_host}
            header_up X-Forwarded-For   {remote_host}
            header_up X-Forwarded-Proto {scheme}
            header_up Connection        {http.request.header.Connection}
            header_up Upgrade           {http.request.header.Upgrade}
            transport http {
                dial_timeout            10s
                response_header_timeout 600s
                read_timeout            600s
                write_timeout           600s
            }
        }
    }
}
EOF
        print_success "Caddyfile written (automatic HTTPS)"
    else
        cat > "$CADDY_DIR/Caddyfile" << EOF
# =============================================================
# Caddyfile — HTTP only (Cloudflare handles TLS)
# Set Cloudflare SSL/TLS → Flexible
# =============================================================

:80 {

    log {
        output file /var/log/caddy/access.log {
            roll_size     100mb
            roll_keep     5
            roll_keep_for 720h
        }
        format json
        level  INFO
    }

    encode zstd gzip

    header {
        X-Frame-Options        "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection       "1; mode=block"
        Referrer-Policy        "strict-origin-when-cross-origin"
        -Server
    }
$SECURITY_SNIPPET
    handle /health/ {
        reverse_proxy web:8000
    }

    handle {
        reverse_proxy web:8000 {
            header_up Host              {host}
            header_up X-Real-IP         {http.request.header.CF-Connecting-IP}
            header_up X-Forwarded-For   {http.request.header.CF-Connecting-IP}
            header_up X-Forwarded-Proto {http.request.header.X-Forwarded-Proto}
            header_up Connection        {http.request.header.Connection}
            header_up Upgrade           {http.request.header.Upgrade}
            transport http {
                dial_timeout            10s
                response_header_timeout 600s
                read_timeout            600s
                write_timeout           600s
            }
        }
    }
}
EOF
        print_success "Caddyfile written (HTTP-only / Cloudflare mode)"
    fi

    print_info "Caddyfile: $CADDY_DIR/Caddyfile"
}

# ---------------------------------------------------------------------------
# Docker Compose prod file
# ---------------------------------------------------------------------------
write_compose_file() {
    print_header "Generating compose.prod.yaml"

    # Shared services (web, redis, celery_worker, celery_beat, volumes)
    # appended after the SSL-specific caddy block
    _compose_services() {
        cat >> "$APP_DIR/compose.prod.yaml" << 'EOF'

  redis:
    image: redis:8-alpine3.21
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    security_opt:
      - no-new-privileges:true

  web:
    image: acerschoolapp/acerschoolfinanceapp:latest
    restart: unless-stopped
    env_file:
      - .env.docker
    depends_on:
      redis:
        condition: service_healthy
    command: ["./deploy.sh"]
    expose:
      - "8000"
    volumes:
      - logs_data:/app/logs
    healthcheck:
      test: ["CMD", "python3", "./docker-health-check.py"]
      interval: 30s
      timeout: 120s
      retries: 5
      start_period: 240s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    security_opt:
      - no-new-privileges:true

  celery_worker:
    image: acerschoolapp/acerschoolfinanceapp:latest
    restart: unless-stopped
    command: >
      celery -A afinance worker --loglevel=info --concurrency=1 --prefetch-multiplier=1
    env_file:
      - .env.docker
    depends_on:
      web:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - logs_data:/app/logs
    healthcheck:
      test: ["CMD-SHELL", "celery -A afinance inspect ping -d celery@$${HOSTNAME} || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 300s
    security_opt:
      - no-new-privileges:true

  celery_beat:
    image: acerschoolapp/acerschoolfinanceapp:latest
    restart: unless-stopped
    command: celery -A afinance beat -l info
    env_file:
      - .env.docker
    depends_on:
      web:
        condition: service_healthy
      redis:
        condition: service_healthy
      celery_worker:
        condition: service_healthy
    volumes:
      - logs_data:/app/logs
    security_opt:
      - no-new-privileges:true

volumes:
  caddy_data:
  caddy_config:
  caddy_logs:
  redis_data:
  logs_data:
EOF
    }

    if [[ "$SETUP_SSL" == "letsencrypt" ]]; then
        cat > "$APP_DIR/compose.prod.yaml" << 'EOF'
# =============================================================
# Docker Compose — Production (Caddy auto-HTTPS + Django + Redis + Celery)
# Pull & start: docker pull acerschoolapp/acerschoolfinanceapp:latest
#               docker compose -f compose.prod.yaml up -d
# =============================================================

services:

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
      - caddy_logs:/var/log/caddy
    depends_on:
      web:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    # Debugging:
    #   logs:       docker compose -f compose.prod.yaml logs -f caddy
    #   hot-reload: docker compose -f compose.prod.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
    #   validate:   docker compose -f compose.prod.yaml exec caddy caddy validate --config /etc/caddy/Caddyfile
    #   list certs: docker compose -f compose.prod.yaml exec caddy caddy list-certificates
EOF
    else
        cat > "$APP_DIR/compose.prod.yaml" << 'EOF'
# =============================================================
# Docker Compose — Production (Caddy HTTP-only + Django + Redis + Celery)
# Cloudflare sits in front and provides HTTPS.
# Set Cloudflare SSL/TLS mode to "Flexible".
# Pull & start: docker pull acerschoolapp/acerschoolfinanceapp:latest
#               docker compose -f compose.prod.yaml up -d
# =============================================================

services:

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
      - caddy_logs:/var/log/caddy
    depends_on:
      web:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    # Debugging:
    #   logs:       docker compose -f compose.prod.yaml logs -f caddy
    #   hot-reload: docker compose -f compose.prod.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
    #   validate:   docker compose -f compose.prod.yaml exec caddy caddy validate --config /etc/caddy/Caddyfile
EOF
    fi

    _compose_services
    print_success "compose.prod.yaml written"
}

# ---------------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------------
setup_env_file() {
    print_header "Environment Configuration"

    if [[ -f "$APP_DIR/.env.docker" ]]; then
        print_warning "Environment file already exists"
        safe_read "Reconfigure it? [y/N]: " RECONFIG_ENV "N"
        if [[ ! "$RECONFIG_ENV" =~ ^[Yy]$ ]]; then
            print_info "Keeping existing environment file"
            return
        fi
        cp "$APP_DIR/.env.docker" "$APP_DIR/.env.docker.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Old file backed up"
    fi

    GENERATED_SECRET_KEY=$(generate_secret_key)
    GENERATED_POSTGRES_PASSWORD=$(generate_postgres_password)

    cat > "$APP_DIR/.env.docker" << EOF
# ============================================
# Django Core Settings
# ============================================
SECRET_KEY=$GENERATED_SECRET_KEY
DEBUG=False
ENVIRONMENT=production
ALLOWED_HOSTS=localhost,$DOMAIN_NAME,www.$DOMAIN_NAME
CSRF_ORIGINS=https://$DOMAIN_NAME,https://www.$DOMAIN_NAME

# ============================================
# Database Configuration
# ============================================
DATABASE_URL=postgresql://user:password@host:port/dbname
ANALYTICS_DATABASE_URL=postgresql://user:password@host:port/analytics_db

# ============================================
# Redis
# ============================================
REDIS_URL=redis://redis:6379
REDIS_HOST=redis
REDIS_PASSWORD=

# ============================================
# Site
# ============================================
SITE_ID=1
SITE_NAME=$DOMAIN_NAME
SITE_URL=https://$DOMAIN_NAME

# ============================================
# Email
# ============================================
DEFAULT_FROM_EMAIL=noreply@$DOMAIN_NAME
EMAIL_HOST=smtp.gmail.com
EMAIL_HOST_USER=your-email@gmail.com
EMAIL_HOST_PASSWORD=your-app-password
EMAIL_PORT=587

# ============================================
# Cloudflare R2 Storage (Private)
# ============================================
CLOUDFLARE_R2_ACCESS_KEY=your-access-key
CLOUDFLARE_R2_SECRET_KEY=your-secret-key
CLOUDFLARE_R2_BUCKET=your-bucket-name
CLOUDFLARE_R2_BUCKET_ENDPOINT=https://your-account-id.r2.cloudflarestorage.com
CLOUDFLARE_R2_PUBLIC_CUSTOM_DOMAIN=https://cdn.$DOMAIN_NAME

# ============================================
# Admin
# ============================================
ADMIN_NAME=Admin Name
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN_NAME}

# ============================================
# Python
# ============================================
PYTHON_VERSION=3.13.5
EOF

    print_success "Environment file created"
    print_warning "IMPORTANT: Fill in real database credentials, email, and R2 keys before starting."
    print_info "Press Enter to open the editor..."
    safe_read "" _NOOP ""
    nano "$APP_DIR/.env.docker"
    print_success "Environment file saved"
}

# ---------------------------------------------------------------------------
# Fail2Ban
# ---------------------------------------------------------------------------
install_fail2ban() {
    print_header "Installing Fail2Ban"
    if command -v fail2ban-server &>/dev/null; then
        print_warning "Fail2Ban already installed"
    else
        sudo apt-get install -y fail2ban
        print_success "Fail2Ban installed"
    fi
}

setup_fail2ban() {
    print_header "Configuring Fail2Ban (SSH + HTTP attack jails)"

    # ── jail.local ──────────────────────────────────────────────────────────
    sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[DEFAULT]
bantime  = 2592000
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
banaction = iptables-multiport

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3

# Caddy JSON logs — 400 responses
[caddy-400]
enabled  = true
port     = http,https
filter   = caddy-400
logpath  = /var/log/caddy/access.log
maxretry = 10
findtime = 60
bantime  = 2592000

# Caddy JSON logs — known scanner/exploit paths
[caddy-scan]
enabled  = true
port     = http,https
filter   = caddy-scan
logpath  = /var/log/caddy/access.log
maxretry = 3
findtime = 60
bantime  = 2592000

# Excessive 4xx
[caddy-4xx]
enabled  = true
port     = http,https
filter   = caddy-4xx
logpath  = /var/log/caddy/access.log
maxretry = 20
findtime = 60
bantime  = 86400
EOF

    # ── filter: caddy-400 ──────────────────────────────────────────────────
    # Caddy logs are JSON; "status":400 or quoted "400"
    sudo tee /etc/fail2ban/filter.d/caddy-400.conf > /dev/null << 'EOF'
[Definition]
failregex = .*"remote_ip":\s*"<HOST>".*"status":\s*400
            .*"remote_ip":\s*"<HOST>".*"status":"400"
ignoreregex = .*"remote_ip":\s*"127\.
              .*"remote_ip":\s*"172\.1[6-9]\.
              .*"remote_ip":\s*"172\.2[0-9]\.
              .*"remote_ip":\s*"172\.3[01]\.
EOF

    # ── filter: caddy-scan ─────────────────────────────────────────────────
    sudo tee /etc/fail2ban/filter.d/caddy-scan.conf > /dev/null << 'EOF'
[Definition]
failregex = .*"remote_ip":\s*"<HOST>".*"uri":\s*"[^"]*(?:phpunit|eval-stdin|\.php|xmlrpc|wp-admin|wp-login|invokefunction|call_user_func|pearcmd|auto_prepend_file|allow_url_include|/containers/json|\.env|\.git|hello\.world)[^"]*"
ignoreregex =
EOF

    # ── filter: caddy-4xx ──────────────────────────────────────────────────
    sudo tee /etc/fail2ban/filter.d/caddy-4xx.conf > /dev/null << 'EOF'
[Definition]
failregex = .*"remote_ip":\s*"<HOST>".*"status":\s*(?:400|403|404|405|444)
ignoreregex = .*robots\.txt.*
              .*favicon\.ico.*
              .*health.*
              .*"remote_ip":\s*"127\.
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable fail2ban
    sudo systemctl restart fail2ban
    sleep 3

    if systemctl is-active --quiet fail2ban; then
        print_success "Fail2Ban running with 4 jails (sshd, caddy-400, caddy-scan, caddy-4xx)"
        sudo fail2ban-client status 2>/dev/null || true
    else
        print_warning "Fail2Ban failed to start — check: sudo journalctl -u fail2ban"
    fi
}

# ---------------------------------------------------------------------------
# iptables persistence + DDoS base rules
# ---------------------------------------------------------------------------
setup_iptables_persistence() {
    print_header "Setting Up iptables Persistence"

    sudo systemctl enable netfilter-persistent 2>/dev/null || true

    # Drop invalid packets (basic DDoS mitigation)
    sudo iptables -A INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
    sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    # SYN flood protection
    sudo iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT 2>/dev/null || true
    sudo iptables -A INPUT -p tcp --syn -j DROP 2>/dev/null || true

    # Save rules
    sudo /usr/sbin/netfilter-persistent save 2>/dev/null || \
    (sudo iptables-save  | sudo tee /etc/iptables/rules.v4 > /dev/null && \
     sudo ip6tables-save | sudo tee /etc/iptables/rules.v6 > /dev/null)

    print_success "iptables rules saved — survive reboots"
}

# ---------------------------------------------------------------------------
# Auto-ban cron script (scans Caddy JSON logs)
# ---------------------------------------------------------------------------
create_autoban_script() {
    print_header "Creating Auto-Ban Cron Script"

    sudo tee /usr/local/bin/asfa-autoban.sh > /dev/null << 'SCRIPT'
#!/bin/bash
# asfa-autoban.sh — scans Caddy JSON access logs and bans attackers
# Runs every minute via cron.

LOGFILE="/var/log/asfa-autoban.log"
CADDY_LOG="/var/log/caddy/access.log"
THRESHOLD=10
WINDOW=60

ATTACK_PATTERNS='phpunit|eval-stdin|invokefunction|call_user_func|pearcmd|auto_prepend_file|allow_url_include|/containers/json|hello\.world|wp-login|xmlrpc|\.env"|\.git/'

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

ban_ip() {
    local ip="$1" reason="$2"
    # Skip private/loopback
    if [[ "$ip" =~ ^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then return; fi
    # Already banned?
    sudo iptables -C INPUT -s "$ip" -j DROP 2>/dev/null && return
    sudo iptables -A INPUT -s "$ip" -j DROP
    sudo netfilter-persistent save >/dev/null 2>&1 || true
    echo "$(timestamp) BANNED $ip — $reason" >> "$LOGFILE"
}

if [[ ! -f "$CADDY_LOG" ]]; then exit 0; fi

# IPs sending attack patterns
grep -aP "$ATTACK_PATTERNS" "$CADDY_LOG" \
    | grep -oP '"remote_ip":\s*"\K[^"]+' \
    | sort | uniq -c | sort -rn \
    | while read -r count ip; do
        ban_ip "$ip" "attack pattern in Caddy log (${count}x)"
    done

# IPs with >= THRESHOLD 400 responses in last WINDOW seconds
SINCE=$(date -d "-${WINDOW} seconds" -Iseconds 2>/dev/null || \
        date -v-"${WINDOW}"S -Iseconds 2>/dev/null || true)

if [[ -n "$SINCE" ]]; then
    # Caddy logs ISO8601 timestamps in "ts" field
    awk -v since="$SINCE" '
        /\"status\":[ ]*400/ {
            match($0, /"ts":"([^"]+)"/, ts_arr)
            match($0, /"remote_ip":"([^"]+)"/, ip_arr)
            if (ts_arr[1] >= since) print ip_arr[1]
        }
    ' "$CADDY_LOG" | sort | uniq -c | sort -rn \
    | while read -r count ip; do
        if (( count >= THRESHOLD )); then
            ban_ip "$ip" "${count}x 400 in ${WINDOW}s"
        fi
    done
fi

# Scan Docker Django logs
DOCKER_LOGS=$(docker logs --since="${WINDOW}s" asfa_web 2>/dev/null || true)
if [[ -n "$DOCKER_LOGS" ]]; then
    echo "$DOCKER_LOGS" \
        | grep -aP "Suspicious request from|400 response for" \
        | grep -oP '\d{1,3}(\.\d{1,3}){3}' | sort | uniq -c | sort -rn \
        | while read -r count ip; do
            (( count >= 3 )) && ban_ip "$ip" "Django 400/suspicious (${count}x)"
        done
fi
SCRIPT

    sudo chmod +x /usr/local/bin/asfa-autoban.sh

    # Install cron job
    (sudo crontab -l 2>/dev/null | grep -v asfa-autoban; \
     echo "* * * * * /usr/local/bin/asfa-autoban.sh") | sudo crontab -

    print_success "Auto-ban script: /usr/local/bin/asfa-autoban.sh"
    print_success "Cron job added — runs every minute"
}

# ---------------------------------------------------------------------------
# UFW
# ---------------------------------------------------------------------------
setup_firewall() {
    if [[ "$SETUP_FIREWALL" =~ ^[Yy]$ ]]; then
        print_header "Configuring UFW Firewall"
        sudo ufw --force reset >/dev/null 2>&1 || true
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        sudo ufw allow 22/tcp
        sudo ufw allow 80/tcp
        sudo ufw allow 443/tcp
        echo "y" | sudo ufw enable >/dev/null 2>&1
        print_success "UFW configured"
        sudo ufw status verbose
    fi
}

# ---------------------------------------------------------------------------
# Systemd service
# ---------------------------------------------------------------------------
setup_systemd() {
    print_header "Setting Up Systemd Service (asfa.service)"

    sudo tee /etc/systemd/system/asfa.service > /dev/null << EOF
[Unit]
Description=ASFA Django Application (Caddy + Django + Redis)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/docker compose -f compose.prod.yaml up -d --remove-orphans
ExecStop=/usr/bin/docker compose -f compose.prod.yaml down
ExecReload=/usr/bin/docker compose -f compose.prod.yaml restart
User=$USER
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable asfa.service
    print_success "asfa.service enabled — starts automatically on boot"
}

# ---------------------------------------------------------------------------
# Management scripts
# ---------------------------------------------------------------------------
create_management_scripts() {
    print_header "Creating Management Scripts"

    # deploy.sh
    cat > "$APP_DIR/deploy.sh" << 'SCRIPT'
#!/bin/bash
set -e
cd "$(dirname "$0")"
echo "==> Pulling latest image..."
docker pull acerschoolapp/acerschoolfinanceapp:latest
echo "==> Restarting stack..."
docker compose -f compose.prod.yaml up -d --remove-orphans --pull always
echo "==> Waiting 20 s..."
sleep 20
docker compose -f compose.prod.yaml ps
echo "Deployment complete!"
SCRIPT
    chmod +x "$APP_DIR/deploy.sh"

    # logs.sh
    cat > "$APP_DIR/logs.sh" << 'SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"
SERVICE=${1:-}
docker compose -f compose.prod.yaml logs -f --tail=100 $SERVICE
SCRIPT
    chmod +x "$APP_DIR/logs.sh"

    # status.sh
    cat > "$APP_DIR/status.sh" << 'SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"
echo "=== Containers ==="
docker compose -f compose.prod.yaml ps
echo ""
echo "=== Caddy Certificates ==="
docker compose -f compose.prod.yaml exec caddy caddy list-certificates 2>/dev/null || echo "(stack not running)"
echo ""
echo "=== Fail2Ban ==="
sudo fail2ban-client status 2>/dev/null || echo "Fail2Ban not running"
echo ""
echo "=== Banned IPs (iptables DROP) ==="
sudo iptables -L INPUT -n | grep DROP | awk '{print $4}' | grep -v '0.0.0.0' || echo "None"
SCRIPT
    chmod +x "$APP_DIR/status.sh"

    # caddy-reload.sh
    cat > "$APP_DIR/caddy-reload.sh" << 'SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"
echo "==> Reloading Caddy config (no downtime)..."
docker compose -f compose.prod.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
echo "Done."
SCRIPT
    chmod +x "$APP_DIR/caddy-reload.sh"

    # shell.sh
    cat > "$APP_DIR/shell.sh" << 'SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"
SERVICE=${1:-web}
docker compose -f compose.prod.yaml exec "$SERVICE" bash
SCRIPT
    chmod +x "$APP_DIR/shell.sh"

    # diagnose.sh
    cat > "$APP_DIR/diagnose.sh" << 'SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"
SERVICE=${1:-web}
CONTAINER="asfa_${SERVICE}"
echo "=========================================="
echo " Diagnose: $CONTAINER"
echo "=========================================="
echo ""
echo "--- Status ---"
docker inspect --format 'State: {{.State.Status}}  ExitCode: {{.State.ExitCode}}  Error: {{.State.Error}}' \
    "$CONTAINER" 2>/dev/null || echo "(container not found)"
echo ""
echo "--- Last 200 log lines ---"
docker logs --tail 200 "$CONTAINER" 2>&1
echo ""
echo "--- State (inspect) ---"
docker inspect "$CONTAINER" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d[0]['State'],indent=2))" \
    2>/dev/null || true
SCRIPT
    chmod +x "$APP_DIR/diagnose.sh"

    # unban.sh
    cat > "$APP_DIR/unban.sh" << 'SCRIPT'
#!/bin/bash
IP="${1:-}"
if [[ -z "$IP" ]]; then echo "Usage: $0 <ip-address>"; exit 1; fi
echo "Removing ban for $IP..."
sudo iptables -D INPUT -s "$IP" -j DROP 2>/dev/null && echo "iptables rule removed" || echo "Not found in iptables"
sudo fail2ban-client unban "$IP" 2>/dev/null || true
sudo netfilter-persistent save 2>/dev/null || true
echo "Done."
SCRIPT
    chmod +x "$APP_DIR/unban.sh"

    print_success "Management scripts created:"
    print_info "  ./deploy.sh          — pull & redeploy"
    print_info "  ./logs.sh [svc]      — tail logs"
    print_info "  ./status.sh          — status + certs + banned IPs"
    print_info "  ./caddy-reload.sh    — hot-reload Caddyfile (no downtime)"
    print_info "  ./shell.sh [svc]     — shell into container"
    print_info "  ./diagnose.sh [svc]  — full crash report"
    print_info "  ./unban.sh <ip>      — remove an IP ban"
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
start_application() {
    print_header "Starting Application"
    cd "$APP_DIR"

    print_info "Pulling latest image..."
    docker pull acerschoolapp/acerschoolfinanceapp:latest

    print_info "Starting stack..."
    docker compose -f compose.prod.yaml up -d --remove-orphans

    print_info "Waiting 30 s for services to initialise..."
    for i in {1..6}; do echo -n "."; sleep 5; done; echo

    docker compose -f compose.prod.yaml ps

    if docker compose -f compose.prod.yaml ps | grep -q "Up"; then
        print_success "Application started!"
    else
        print_warning "Some services may not be running. Check: ./diagnose.sh"
    fi
}

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------
print_completion() {
    print_header "Installation Complete!"
    echo -e "${GREEN}ASFA is deployed and running via Caddy.${NC}\n"

    if [[ "$SETUP_SSL" == "letsencrypt" ]]; then
        echo "  URL: https://$DOMAIN_NAME"
        echo "  SSL: Automatic (Let's Encrypt — auto-renewed by Caddy)"
    else
        echo "  URL: http://$DOMAIN_NAME  (Cloudflare provides HTTPS)"
        echo "  SSL: Set Cloudflare SSL/TLS → Flexible"
    fi

    echo ""
    echo "Useful commands:"
    echo "  cd $APP_DIR"
    echo "  ./deploy.sh              # pull & redeploy"
    echo "  ./logs.sh caddy          # Caddy access logs"
    echo "  ./logs.sh web            # Django app logs"
    echo "  ./caddy-reload.sh        # reload Caddyfile (no downtime)"
    echo "  ./shell.sh web           # shell into Django container"
    echo "  ./status.sh              # status + certs + banned IPs"
    echo "  ./diagnose.sh web        # crash report"
    echo "  ./unban.sh <ip>          # unban an IP"
    echo ""

    if [[ "$SECURITY_ENABLED" == "true" ]]; then
        echo -e "${GREEN}Security Active:${NC}"
        echo "  ✓ Fail2Ban — sshd (3 retries → 30-day ban)"
        echo "  ✓ Fail2Ban — caddy-400  (10 hits/min → 30-day ban)"
        echo "  ✓ Fail2Ban — caddy-scan (3 exploit probes → 30-day ban)"
        echo "  ✓ Fail2Ban — caddy-4xx  (20 errors/min → 24-hr ban)"
        echo "  ✓ Caddy   — silent 444 drop for PHP/exploit paths"
        echo "  ✓ iptables — invalid packet drop + SYN flood protection"
        echo "  ✓ iptables-persistent — bans survive reboots"
        echo "  ✓ Auto-ban cron — scans logs every minute"
        echo ""
        echo "  Ban log:         sudo tail -f /var/log/asfa-autoban.log"
        echo "  Banned IPs:      sudo iptables -L INPUT -n | grep DROP"
        echo "  Fail2Ban status: sudo fail2ban-client status"
    fi

    echo ""
    print_warning "Log out and back in if you were just added to the docker group."
    echo ""
    echo "Django superuser:"
    echo "  docker compose -f compose.prod.yaml exec web python manage.py createsuperuser"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    print_header "ASFA Django Application — Deployment Script"

    check_sudo
    check_os
    gather_config
    free_ports
    update_system
    install_docker
    create_deployer_user
    setup_app_directory
    clone_repository
    docker_login

    if [[ "${REUSE_CONFIG:-false}" != "true" ]]; then
        write_caddyfile
        write_compose_file
    else
        print_info "Re-deploy: keeping existing caddy/Caddyfile and compose.prod.yaml"
    fi

    setup_env_file

    if [[ "$SECURITY_ENABLED" == "true" ]]; then
        install_fail2ban
        setup_fail2ban
        setup_iptables_persistence
        create_autoban_script
    fi

    setup_systemd
    setup_firewall
    create_management_scripts
    save_config

    safe_read "Start application now? [Y/n]: " START_NOW "Y"
    [[ "$START_NOW" =~ ^[Yy]$ ]] && start_application

    print_completion
}

main

