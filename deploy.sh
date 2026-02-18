#!/bin/bash

# ASFA Django Application - Automated Deployment Script
# Uses Caddy (in Docker Compose) instead of host Nginx for simpler, developer-friendly setup

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}\n"
}
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${CYAN}ℹ $1${NC}"; }
print_step()    { echo -e "${MAGENTA}▶ $1${NC}"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        print_info "This script requires sudo privileges. You may be prompted for your password."
        sudo -v
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            print_error "This script is designed for Ubuntu or Debian. Detected: $OS"
            exit 1
        fi
        print_success "OS Check: $OS $VER"
    else
        print_error "Cannot determine OS. This script requires Ubuntu or Debian."
        exit 1
    fi
}

load_existing_config() {
    CONFIG_FILE="$DEFAULT_APP_DIR/.deployment_config"
    if [ -f "$CONFIG_FILE" ]; then
        print_info "Found existing configuration"
        source "$CONFIG_FILE"
        EXISTING_CONFIG=true
    else
        EXISTING_CONFIG=false
    fi
}

save_config() {
    CONFIG_FILE="$APP_DIR/.deployment_config"
    cat > "$CONFIG_FILE" << EOF
# ASFA Deployment Configuration
DOMAIN_NAME="$DOMAIN_NAME"
DOCKER_USERNAME="$DOCKER_USERNAME"
APP_DIR="$APP_DIR"
SETUP_SSL="$SETUP_SSL"
SSL_EMAIL="$SSL_EMAIL"
EOF
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved"
}

# ---------------------------------------------------------------------------
# Remove / disable host Nginx if present
# ---------------------------------------------------------------------------

remove_host_nginx() {
    print_header "Removing / Disabling Host Nginx"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        print_warning "Nginx is running — stopping it..."
        sudo systemctl stop nginx
    fi

    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        sudo systemctl disable nginx
        print_success "Nginx disabled from startup"
    fi

    # Release port 80/443 so Caddy (in Docker) can bind them
    if dpkg -l nginx 2>/dev/null | grep -q '^ii'; then
        print_info "Purging nginx packages..."
        sudo apt-get purge -y nginx nginx-common nginx-core nginx-full 2>/dev/null || true
        sudo apt-get autoremove -y
        print_success "Nginx purged"
    else
        print_info "Nginx package not found — nothing to purge"
    fi

    # Extra safety: kill anything still on 80/443
    for PORT in 80 443; do
        PID=$(sudo lsof -ti tcp:"$PORT" 2>/dev/null || true)
        if [ -n "$PID" ]; then
            print_warning "Port $PORT still in use by PID $PID — killing..."
            sudo kill -9 $PID 2>/dev/null || true
        fi
    done

    print_success "Host Nginx removed — ports 80 and 443 are free"
}

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------

configure_ssl_option() {
    echo
    print_info "SSL / TLS Configuration"
    echo "  1) Automatic HTTPS — Caddy obtains & renews Let's Encrypt certs for you"
    echo "     (requires a public domain with a DNS A record pointing to this server)"
    echo "  2) Cloudflare proxy — Caddy listens on HTTP only; Cloudflare provides HTTPS"
    read -p "Select option [1/2]: " SSL_OPTION
    SSL_OPTION=${SSL_OPTION:-1}

    if [ "$SSL_OPTION" = "1" ]; then
        SETUP_SSL="letsencrypt"
        SSL_EMAIL=""   # Caddy manages certs fully — no email required
        print_success "Mode: Automatic HTTPS (Caddy + Let's Encrypt)"
        print_info  "Caddy will obtain and auto-renew the certificate — nothing else needed."
        print_warning "Ensure your DNS A record points $DOMAIN_NAME to this server's IP before starting."
    else
        SETUP_SSL="cloudflare"
        SSL_EMAIL=""
        print_success "Mode: HTTP only (Cloudflare handles TLS)"
        print_info "Set Cloudflare SSL/TLS encryption mode to 'Flexible' in the Cloudflare dashboard."
    fi
}

gather_config() {
    print_header "Configuration Setup"

    DEFAULT_APP_DIR="/opt/apps/asfa"
    load_existing_config

    if [ "$EXISTING_CONFIG" = true ]; then
        print_success "Existing deployment detected!"
        echo
        echo "  Domain:      $DOMAIN_NAME"
        echo "  Docker User: $DOCKER_USERNAME"
        echo "  App Dir:     $APP_DIR"
        echo "  SSL:         $SETUP_SSL"
        echo
        read -p "Use existing configuration? [Y/n]: " USE_EXISTING
        USE_EXISTING=${USE_EXISTING:-Y}

        if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
            print_info "Using saved configuration"
            read -sp "Docker Hub password/token: " DOCKER_PASSWORD
            echo
            while [ -z "$DOCKER_PASSWORD" ]; do
                print_warning "Password cannot be empty"
                read -sp "Docker Hub password/token: " DOCKER_PASSWORD
                echo
            done
            CREATE_USER="n"
            SETUP_FIREWALL="n"
            return 0
        fi
        print_info "Reconfiguring..."
    fi

    # Domain
    if [ -n "$DOMAIN_NAME" ]; then
        read -p "Domain name [$DOMAIN_NAME]: " NEW_DOMAIN_NAME
        DOMAIN_NAME=${NEW_DOMAIN_NAME:-$DOMAIN_NAME}
    else
        read -p "Domain name (e.g. example.com): " DOMAIN_NAME
        while [ -z "$DOMAIN_NAME" ]; do
            print_warning "Domain cannot be empty"
            read -p "Domain name: " DOMAIN_NAME
        done
    fi

    # Docker Hub
    print_info "Docker Hub credentials are required to pull the private image"
    if [ -n "$DOCKER_USERNAME" ]; then
        read -p "Docker Hub username [$DOCKER_USERNAME]: " NEW_DOCKER_USERNAME
        DOCKER_USERNAME=${NEW_DOCKER_USERNAME:-$DOCKER_USERNAME}
    else
        read -p "Docker Hub username: " DOCKER_USERNAME
        while [ -z "$DOCKER_USERNAME" ]; do
            print_warning "Username cannot be empty"
            read -p "Docker Hub username: " DOCKER_USERNAME
        done
    fi

    read -sp "Docker Hub password/token: " DOCKER_PASSWORD
    echo
    while [ -z "$DOCKER_PASSWORD" ]; do
        print_warning "Password cannot be empty"
        read -sp "Docker Hub password/token: " DOCKER_PASSWORD
        echo
    done

    # App directory
    if [ -n "$APP_DIR" ]; then
        read -p "Application directory [$APP_DIR]: " NEW_APP_DIR
        APP_DIR=${NEW_APP_DIR:-$APP_DIR}
    else
        read -p "Application directory [$DEFAULT_APP_DIR]: " APP_DIR
        APP_DIR=${APP_DIR:-$DEFAULT_APP_DIR}
    fi

    if [ "$EXISTING_CONFIG" != true ]; then
        read -p "Create a dedicated 'deployer' user? (recommended) [Y/n]: " CREATE_USER
        CREATE_USER=${CREATE_USER:-Y}
        read -p "Configure UFW firewall? (recommended) [Y/n]: " SETUP_FIREWALL
        SETUP_FIREWALL=${SETUP_FIREWALL:-Y}
    fi

    # SSL
    if [ "$EXISTING_CONFIG" = true ] && [ -n "$SETUP_SSL" ]; then
        echo
        print_info "Current SSL: $SETUP_SSL"
        read -p "Keep existing SSL config? [Y/n]: " KEEP_SSL
        KEEP_SSL=${KEEP_SSL:-Y}
        [[ ! "$KEEP_SSL" =~ ^[Yy]$ ]] && configure_ssl_option
    else
        configure_ssl_option
    fi

    print_header "Configuration Summary"
    echo "  Domain:          $DOMAIN_NAME"
    echo "  Docker User:     $DOCKER_USERNAME"
    echo "  App Directory:   $APP_DIR"
    echo "  Deployer user:   ${CREATE_USER:-n}"
    echo "  Firewall:        ${SETUP_FIREWALL:-n}"
    echo "  SSL:             $SETUP_SSL"
    echo

    read -p "Proceed with installation? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { print_info "Cancelled."; exit 0; }
}

# ---------------------------------------------------------------------------
# System & Docker
# ---------------------------------------------------------------------------

update_system() {
    print_header "Updating System Packages"
    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y curl wget git ufw nano lsof
    print_success "System updated"
}

install_docker() {
    print_header "Installing Docker"

    if command -v docker &>/dev/null; then
        print_warning "Docker already installed: $(docker --version)"
    else
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
        sudo usermod -aG docker "$USER"
        print_success "Docker installed"
    fi

    if docker compose version &>/dev/null; then
        print_warning "Docker Compose already installed: $(docker compose version)"
    else
        print_info "Installing Docker Compose plugin..."
        sudo apt install -y docker-compose-plugin
        print_success "Docker Compose installed"
    fi
}

create_deployer_user() {
    if [[ "$CREATE_USER" =~ ^[Yy]$ ]]; then
        print_header "Creating Deployer User"
        if id "deployer" &>/dev/null; then
            print_warning "User 'deployer' already exists"
        else
            sudo useradd -m -s /bin/bash deployer
            sudo usermod -aG docker deployer
            print_success "User 'deployer' created"
        fi
    fi
}

setup_app_directory() {
    print_header "Setting Up Application Directory"
    sudo mkdir -p "$APP_DIR"
    sudo chown -R "$USER:$USER" "$APP_DIR"
    print_success "Directory ready: $APP_DIR"
}

clone_repository() {
    print_header "Cloning Repository"
    cd "$APP_DIR"
    if [ -d ".git" ]; then
        print_warning "Repository exists — pulling latest changes..."
        git pull
    else
        git clone https://github.com/paulmbui20/asfa-deploy-script.git .
    fi
    print_success "Repository ready"
}

docker_login() {
    print_header "Logging into Docker Hub"
    echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
    print_success "Docker Hub login successful"
}

# ---------------------------------------------------------------------------
# Caddyfile generation
# ---------------------------------------------------------------------------

generate_secret_key() {
    python3 -c "import secrets; print(secrets.token_urlsafe(50))"
}

write_caddyfile() {
    print_header "Generating Caddyfile"

    CADDY_DIR="$APP_DIR/caddy"
    mkdir -p "$CADDY_DIR"

    if [ "$SETUP_SSL" = "letsencrypt" ]; then
        # Caddy handles HTTPS automatically — just name the site
        cat > "$CADDY_DIR/Caddyfile" << EOF
# =============================================================
# Caddyfile — automatic HTTPS via Let's Encrypt
# Caddy version: latest (defined in compose.prod.yaml)
# =============================================================

$DOMAIN_NAME, www.$DOMAIN_NAME {

    # ---------- Logging ----------
    log {
        output file /var/log/caddy/access.log {
            roll_size     100mb
            roll_keep     5
            roll_keep_for 720h
        }
        format json
        level  INFO
    }

    # ---------- Compression ----------
    encode zstd gzip

    # ---------- Security headers ----------
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options            "SAMEORIGIN"
        X-Content-Type-Options     "nosniff"
        X-XSS-Protection           "1; mode=block"
        Referrer-Policy            "strict-origin-when-cross-origin"
        Permissions-Policy         "geolocation=(), microphone=(), camera=()"
        -Server
    }

    # ---------- Rate limiting (requires caddy-ratelimit plugin) ----------
    # Uncomment if you build Caddy with xcaddy + rate-limit module:
    # rate_limit {
    #     zone api_limit {
    #         key   {remote_host}
    #         events 100
    #         window 1m
    #     }
    # }

    # ---------- Health check (no auth) ----------
    handle /health/ {
        reverse_proxy web:8000
    }

    # ---------- Admin — tighter timeouts ----------
    handle /admin/* {
        reverse_proxy web:8000 {
            header_up Host              {host}
            header_up X-Real-IP         {remote_host}
            header_up X-Forwarded-For   {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # ---------- WebSocket-aware catch-all ----------
    handle {
        reverse_proxy web:8000 {
            header_up Host              {host}
            header_up X-Real-IP         {remote_host}
            header_up X-Forwarded-For   {remote_host}
            header_up X-Forwarded-Proto {scheme}

            # WebSocket upgrade
            header_up Connection {http.request.header.Connection}
            header_up Upgrade    {http.request.header.Upgrade}

            # Generous timeouts for long-running requests
            transport http {
                dial_timeout       10s
                response_header_timeout 600s
                read_timeout       600s
                write_timeout      600s
            }
        }
    }
}
EOF
        print_success "Caddyfile written (automatic HTTPS)"

    else
        # Cloudflare in front → Caddy only needs to answer HTTP
        cat > "$CADDY_DIR/Caddyfile" << EOF
# =============================================================
# Caddyfile — HTTP only (Cloudflare handles TLS)
# Set Cloudflare SSL/TLS to "Flexible" mode
# Caddy version: latest (defined in compose.prod.yaml)
# =============================================================

:80 {
    # Uncomment to restrict to your domain name (optional):
    # @wronghost not host $DOMAIN_NAME www.$DOMAIN_NAME
    # abort @wronghost

    # ---------- Logging ----------
    log {
        output file /var/log/caddy/access.log {
            roll_size     100mb
            roll_keep     5
            roll_keep_for 720h
        }
        format json
        level  INFO
    }

    # ---------- Compression ----------
    encode zstd gzip

    # ---------- Security headers ----------
    header {
        X-Frame-Options        "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection       "1; mode=block"
        Referrer-Policy        "strict-origin-when-cross-origin"
        -Server
    }

    # ---------- Health check ----------
    handle /health/ {
        reverse_proxy web:8000
    }

    # ---------- Cloudflare real-IP restoration ----------
    # Caddy's trusted_proxies block tells Caddy which upstream IPs to trust
    # for the X-Forwarded-For / CF-Connecting-IP headers.

    # ---------- Catch-all (WebSocket aware) ----------
    handle {
        reverse_proxy web:8000 {
            header_up Host              {host}
            # Use Cloudflare's real-IP header when available
            header_up X-Real-IP         {http.request.header.CF-Connecting-IP}
            header_up X-Forwarded-For   {http.request.header.CF-Connecting-IP}
            header_up X-Forwarded-Proto {http.request.header.X-Forwarded-Proto}

            # WebSocket upgrade
            header_up Connection {http.request.header.Connection}
            header_up Upgrade    {http.request.header.Upgrade}

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

    print_info "Caddyfile location: $CADDY_DIR/Caddyfile"
}

# ---------------------------------------------------------------------------
# Docker Compose prod file with Caddy
# ---------------------------------------------------------------------------

write_compose_file() {
    print_header "Generating compose.prod.yaml"

    # Shared bottom section written once to avoid duplication
    _write_compose_bottom() {
        cat >> "$APP_DIR/compose.prod.yaml" << 'EOF'

  # ----- Django application -----
  web:
    image: acerschoolapp/acerschoolfinanceapp:latest
    container_name: asfa_web
    restart: unless-stopped
    env_file:
      - .env.docker
    environment:
      - PYTHONUNBUFFERED=1
    depends_on:
      - redis
    networks:
      - asfa_net
    expose:
      - "8000"
    # Debugging:
    #   shell:      docker compose -f compose.prod.yaml exec web bash
    #   management: docker compose -f compose.prod.yaml exec web python manage.py <cmd>

  # ----- Redis -----
  redis:
    image: redis:7-alpine
    container_name: asfa_redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    networks:
      - asfa_net
    # Debugging:
    #   redis-cli:  docker compose -f compose.prod.yaml exec redis redis-cli

volumes:
  caddy_data:    # persists TLS certificates across restarts
  caddy_config:
  caddy_logs:
  redis_data:

networks:
  asfa_net:
    driver: bridge
EOF
    }

    if [ "$SETUP_SSL" = "letsencrypt" ]; then
        # Ports 80 + 443 (TCP + UDP for HTTP/3)
        cat > "$APP_DIR/compose.prod.yaml" << 'EOF'
# =============================================================
# Docker Compose — Production (Caddy auto-HTTPS + Django + Redis)
# =============================================================

services:

  # ----- Caddy reverse proxy (automatic HTTPS via Let's Encrypt) -----
  caddy:
    image: caddy:latest
    container_name: asfa_caddy
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
    networks:
      - asfa_net
    depends_on:
      - web
    # Debugging:
    #   logs:        docker compose -f compose.prod.yaml logs -f caddy
    #   hot-reload:  docker compose -f compose.prod.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
    #   list certs:  docker compose -f compose.prod.yaml exec caddy caddy list-certificates
    #   validate:    docker compose -f compose.prod.yaml exec caddy caddy validate --config /etc/caddy/Caddyfile
EOF
    else
        # Cloudflare mode — port 80 only
        cat > "$APP_DIR/compose.prod.yaml" << 'EOF'
# =============================================================
# Docker Compose — Production (Caddy HTTP-only + Django + Redis)
# Cloudflare sits in front and provides HTTPS.
# Set Cloudflare SSL/TLS mode to "Flexible".
# =============================================================

services:

  # ----- Caddy reverse proxy (HTTP only — Cloudflare handles TLS) -----
  caddy:
    image: caddy:latest
    container_name: asfa_caddy
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
      - caddy_logs:/var/log/caddy
    networks:
      - asfa_net
    depends_on:
      - web
    # Debugging:
    #   logs:       docker compose -f compose.prod.yaml logs -f caddy
    #   hot-reload: docker compose -f compose.prod.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
    #   validate:   docker compose -f compose.prod.yaml exec caddy caddy validate --config /etc/caddy/Caddyfile
EOF
    fi

    # Append shared services / volumes / networks
    _write_compose_bottom

    print_success "compose.prod.yaml written"
}

# ---------------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------------

setup_env_file() {
    print_header "Environment Configuration"

    if [ -f "$APP_DIR/.env.docker" ]; then
        print_warning "Environment file already exists"
        read -p "Reconfigure it? [y/N]: " RECONFIG_ENV
        if [[ ! "$RECONFIG_ENV" =~ ^[Yy]$ ]]; then
            print_info "Keeping existing environment file"
            return
        fi
        cp "$APP_DIR/.env.docker" "$APP_DIR/.env.docker.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Old file backed up"
    fi

    GENERATED_SECRET_KEY=$(generate_secret_key)

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
# Cloudflare R2 Storage
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
ADMIN_EMAIL=admin@$DOMAIN_NAME
PYTHON_VERSION=3.13.5
EOF

    print_success "Environment file created"

    print_header "IMPORTANT: Edit your environment file"
    print_warning "Fill in real database credentials, email settings, R2 keys, etc."
    read -p "Press Enter to open the editor..."
    nano "$APP_DIR/.env.docker"
    print_success "Environment file saved"
}

# ---------------------------------------------------------------------------
# Systemd (manages Docker Compose stack)
# ---------------------------------------------------------------------------

setup_systemd() {
    print_header "Setting Up Systemd Service"

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

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable asfa.service
    print_success "Systemd service enabled (asfa.service)"
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

setup_firewall() {
    if [[ "$SETUP_FIREWALL" =~ ^[Yy]$ ]]; then
        print_header "Configuring UFW Firewall"
        sudo ufw allow 22/tcp
        sudo ufw allow 80/tcp
        sudo ufw allow 443/tcp
        sudo ufw --force enable
        print_success "Firewall configured"
        sudo ufw status
    fi
}

# ---------------------------------------------------------------------------
# Management scripts
# ---------------------------------------------------------------------------

create_management_scripts() {
    print_header "Creating Management Scripts"

    # deploy.sh
    cat > "$APP_DIR/deploy.sh" << 'SCRIPT'
#!/bin/bash
# Pull latest image and restart the stack
set -e
cd "$(dirname "$0")"
echo "==> Pulling latest image..."
docker pull acerschoolapp/acerschoolfinanceapp:latest
echo "==> Restarting stack..."
docker compose -f compose.prod.yaml up -d --remove-orphans --pull always
echo "==> Waiting 20 s for services to settle..."
sleep 20
docker compose -f compose.prod.yaml ps
echo "Deployment complete!"
SCRIPT
    chmod +x "$APP_DIR/deploy.sh"

    # logs.sh — tail any service (default: all)
    cat > "$APP_DIR/logs.sh" << 'SCRIPT'
#!/bin/bash
# Usage: ./logs.sh [service]   e.g. ./logs.sh caddy
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
echo "=== Caddy certificates ==="
docker compose -f compose.prod.yaml exec caddy caddy list-certificates 2>/dev/null || echo "(stack not running)"
SCRIPT
    chmod +x "$APP_DIR/status.sh"

    # caddy-reload.sh — hot-reload Caddyfile without restart
    cat > "$APP_DIR/caddy-reload.sh" << 'SCRIPT'
#!/bin/bash
# Hot-reload Caddyfile (no downtime)
cd "$(dirname "$0")"
echo "==> Reloading Caddy config..."
docker compose -f compose.prod.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
echo "Done."
SCRIPT
    chmod +x "$APP_DIR/caddy-reload.sh"

    # shell.sh — quick shell into any container
    cat > "$APP_DIR/shell.sh" << 'SCRIPT'
#!/bin/bash
# Usage: ./shell.sh [service]   default: web
cd "$(dirname "$0")"
SERVICE=${1:-web}
docker compose -f compose.prod.yaml exec "$SERVICE" bash
SCRIPT
    chmod +x "$APP_DIR/shell.sh"

    print_success "Management scripts created:"
    print_info "  ./deploy.sh          — pull & redeploy"
    print_info "  ./logs.sh [service]  — tail logs"
    print_info "  ./status.sh          — status + cert info"
    print_info "  ./caddy-reload.sh    — hot-reload Caddyfile"
    print_info "  ./shell.sh [service] — open shell in container"
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

start_application() {
    print_header "Starting Application"
    cd "$APP_DIR"
    docker pull acerschoolapp/acerschoolfinanceapp:latest
    docker compose -f compose.prod.yaml up -d --remove-orphans
    print_info "Waiting 30 s for services to initialise..."
    sleep 30
    docker compose -f compose.prod.yaml ps
    print_success "Application started!"
}

print_completion() {
    print_header "Installation Complete!"

    echo -e "${GREEN}ASFA is deployed and running via Caddy.${NC}\n"

    if [ "$SETUP_SSL" = "letsencrypt" ]; then
        echo "  URL:  https://$DOMAIN_NAME"
        echo "  SSL:  Automatic via Let's Encrypt (auto-renewed by Caddy)"
    else
        echo "  URL:  http://$DOMAIN_NAME  (Cloudflare provides HTTPS)"
        echo "  SSL:  Set Cloudflare SSL/TLS → Flexible"
    fi

    echo ""
    echo "Useful commands:"
    echo "  cd $APP_DIR"
    echo "  ./deploy.sh              # pull & redeploy"
    echo "  ./logs.sh caddy          # Caddy access logs"
    echo "  ./logs.sh web            # Django app logs"
    echo "  ./caddy-reload.sh        # reload Caddyfile (no downtime)"
    echo "  ./shell.sh web           # shell into Django container"
    echo "  ./shell.sh caddy         # shell into Caddy container"
    echo "  ./status.sh              # overall status + certs"
    echo ""
    echo "Caddy debugging inside the container:"
    echo "  docker compose -f compose.prod.yaml exec caddy caddy list-certificates"
    echo "  docker compose -f compose.prod.yaml exec caddy caddy validate --config /etc/caddy/Caddyfile"
    echo ""

    print_warning "Log out and back in if you were just added to the docker group."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    print_header "ASFA Django Application — Deployment (Caddy Edition)"

    check_sudo
    check_os
    gather_config
    update_system
    remove_host_nginx        # <-- removes / kills host nginx before anything binds ports
    install_docker
    create_deployer_user
    setup_app_directory
    clone_repository
    docker_login
    write_caddyfile          # generates caddy/Caddyfile
    write_compose_file       # generates compose.prod.yaml with Caddy service
    setup_env_file
    setup_systemd
    setup_firewall
    create_management_scripts
    save_config

    read -p "Start application now? [Y/n]: " START_NOW
    START_NOW=${START_NOW:-Y}
    [[ "$START_NOW" =~ ^[Yy]$ ]] && start_application

    print_completion
}

main
