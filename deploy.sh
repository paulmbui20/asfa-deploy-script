#!/bin/bash

# ASFA Django Application - Automated Deployment Script
# This script automates the complete deployment of the ASFA application on a fresh VPS

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print functions
print_header() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

print_step() {
    echo -e "${MAGENTA}▶ $1${NC}"
}

# Check sudo access
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        print_info "This script requires sudo privileges. You may be prompted for your password."
        sudo -v
    fi
}

# Check OS compatibility
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

# Load existing configuration if available
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

# Save configuration for future runs
save_config() {
    CONFIG_FILE="$APP_DIR/.deployment_config"
    
    cat > "$CONFIG_FILE" << EOF
# ASFA Deployment Configuration
# This file is used to remember settings for re-deployments
DOMAIN_NAME="$DOMAIN_NAME"
DOCKER_USERNAME="$DOCKER_USERNAME"
APP_DIR="$APP_DIR"
SETUP_SSL="$SETUP_SSL"
SSL_EMAIL="$SSL_EMAIL"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved for future deployments"
}

# Configure SSL option
configure_ssl_option() {
    echo
    print_info "SSL Certificate Configuration"
    echo "Choose SSL certificate option:"
    echo "  1) Let's Encrypt (Free, auto-renewing, requires valid domain)"
    echo "  2) Cloudflare Origin Certificate (Recommended for Cloudflare users)"
    echo "  3) None (HTTP only - not recommended for production)"
    read -p "Select option [1/2/3]: " SSL_OPTION
    SSL_OPTION=${SSL_OPTION:-2}
    
    if [ "$SSL_OPTION" = "1" ]; then
        SETUP_SSL="letsencrypt"
        if [ -n "$SSL_EMAIL" ]; then
            read -p "Email for Let's Encrypt notifications [$SSL_EMAIL]: " NEW_SSL_EMAIL
            SSL_EMAIL=${NEW_SSL_EMAIL:-$SSL_EMAIL}
        else
            read -p "Email for Let's Encrypt notifications: " SSL_EMAIL
            while [ -z "$SSL_EMAIL" ]; then
                print_warning "Email cannot be empty for Let's Encrypt"
                read -p "Email for Let's Encrypt notifications: " SSL_EMAIL
            done
        fi
    elif [ "$SSL_OPTION" = "2" ]; then
        SETUP_SSL="cloudflare"
        print_info "You'll need to generate a Cloudflare Origin Certificate"
        print_info "Visit: Cloudflare Dashboard > SSL/TLS > Origin Server"
    else
        SETUP_SSL="none"
        SSL_EMAIL=""
        print_warning "HTTP only mode - not recommended for production"
    fi
}

# Interactive configuration
gather_config() {
    print_header "Configuration Setup"
    
    # Set default app directory first
    DEFAULT_APP_DIR="/opt/apps/asfa"
    
    # Try to load existing configuration
    load_existing_config
    
    if [ "$EXISTING_CONFIG" = true ]; then
        print_success "Existing deployment detected!"
        echo
        echo "Previous configuration:"
        echo "  Domain: $DOMAIN_NAME"
        echo "  Docker Hub User: $DOCKER_USERNAME"
        echo "  App Directory: $APP_DIR"
        echo "  SSL: $SETUP_SSL"
        echo
        read -p "Use existing configuration? [Y/n]: " USE_EXISTING
        USE_EXISTING=${USE_EXISTING:-Y}
        
        if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
            print_info "Using saved configuration"
            
            # Still ask for Docker password (not saved for security)
            print_info "Docker Hub password required (not saved for security)"
            read -sp "Docker Hub password/token: " DOCKER_PASSWORD
            echo
            while [ -z "$DOCKER_PASSWORD" ]; do
                print_warning "Docker Hub password cannot be empty"
                read -sp "Docker Hub password/token: " DOCKER_PASSWORD
                echo
            done
            
            # Skip other questions, use existing values
            CREATE_USER="n"
            SETUP_FIREWALL="n"
            
            return 0
        else
            print_info "Reconfiguring deployment..."
        fi
    fi
    
    # Domain name
    if [ -n "$DOMAIN_NAME" ]; then
        read -p "Enter your domain name [$DOMAIN_NAME]: " NEW_DOMAIN_NAME
        DOMAIN_NAME=${NEW_DOMAIN_NAME:-$DOMAIN_NAME}
    else
        read -p "Enter your domain name (e.g., school.com): " DOMAIN_NAME
        while [ -z "$DOMAIN_NAME" ]; then
            print_warning "Domain name cannot be empty"
            read -p "Enter your domain name: " DOMAIN_NAME
        done
    fi
    
    # Docker Hub credentials
    print_info "Docker Hub credentials are required to pull the private image"
    
    if [ -n "$DOCKER_USERNAME" ]; then
        read -p "Docker Hub username [$DOCKER_USERNAME]: " NEW_DOCKER_USERNAME
        DOCKER_USERNAME=${NEW_DOCKER_USERNAME:-$DOCKER_USERNAME}
    else
        read -p "Docker Hub username: " DOCKER_USERNAME
        while [ -z "$DOCKER_USERNAME" ]; then
            print_warning "Docker Hub username cannot be empty"
            read -p "Docker Hub username: " DOCKER_USERNAME
        done
    fi
    
    read -sp "Docker Hub password/token: " DOCKER_PASSWORD
    echo
    while [ -z "$DOCKER_PASSWORD" ]; do
        print_warning "Docker Hub password cannot be empty"
        read -sp "Docker Hub password/token: " DOCKER_PASSWORD
        echo
    done
    
    # Application directory
    if [ -n "$APP_DIR" ]; then
        read -p "Application directory [$APP_DIR]: " NEW_APP_DIR
        APP_DIR=${NEW_APP_DIR:-$APP_DIR}
    else
        read -p "Application directory [$DEFAULT_APP_DIR]: " APP_DIR
        APP_DIR=${APP_DIR:-$DEFAULT_APP_DIR}
    fi
    
    # Create deployer user
    if [ "$EXISTING_CONFIG" != true ]; then
        read -p "Create a dedicated 'deployer' user? (recommended) [Y/n]: " CREATE_USER
        CREATE_USER=${CREATE_USER:-Y}
    fi
    
    # Setup firewall
    if [ "$EXISTING_CONFIG" != true ]; then
        read -p "Configure UFW firewall? (recommended) [Y/n]: " SETUP_FIREWALL
        SETUP_FIREWALL=${SETUP_FIREWALL:-Y}
    fi
    
    # SSL Configuration
    configure_ssl_option
    
    print_header "Configuration Summary"
    echo "Domain: $DOMAIN_NAME"
    echo "Docker Hub User: $DOCKER_USERNAME"
    echo "App Directory: $APP_DIR"
    echo "Create deployer user: $CREATE_USER"
    echo "Setup firewall: $SETUP_FIREWALL"
    if [ "$SETUP_SSL" = "letsencrypt" ]; then
        echo "SSL: Let's Encrypt (Email: $SSL_EMAIL)"
    elif [ "$SETUP_SSL" = "cloudflare" ]; then
        echo "SSL: Cloudflare Origin Certificate"
    else
        echo "SSL: None (HTTP only)"
    fi
    echo
    
    read -p "Proceed with installation? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Installation cancelled."
        exit 0
    fi
}

# Update system
update_system() {
    print_header "Updating System Packages"
    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y curl wget git ufw nano certbot
    print_success "System updated"
}

# Install Docker
install_docker() {
    print_header "Installing Docker"
    
    if command -v docker &> /dev/null; then
        print_warning "Docker is already installed"
        docker --version
    else
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
        
        # Add current user to docker group
        sudo usermod -aG docker $USER
        print_success "Docker installed"
    fi
    
    # Install Docker Compose plugin
    if docker compose version &> /dev/null; then
        print_warning "Docker Compose is already installed"
        docker compose version
    else
        print_info "Installing Docker Compose..."
        sudo apt install -y docker-compose-plugin
        print_success "Docker Compose installed"
    fi
}

# Create deployer user
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

# Setup application directory
setup_app_directory() {
    print_header "Setting Up Application Directory"
    
    sudo mkdir -p $APP_DIR
    sudo chown -R $USER:$USER $APP_DIR
    
    print_success "Application directory created: $APP_DIR"
}

# Clone repository
clone_repository() {
    print_header "Cloning Repository"
    
    cd $APP_DIR
    
    if [ -d ".git" ]; then
        print_warning "Repository already exists, pulling latest changes..."
        git pull
    else
        print_info "Cloning from GitHub..."
        # Replace with your actual repo URL
        read -p "Enter your repository URL: " REPO_URL
        git clone $REPO_URL .
    fi
    
    print_success "Repository cloned/updated"
}

# Docker Hub login
docker_login() {
    print_header "Logging into Docker Hub"
    
    echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
    
    if [ $? -eq 0 ]; then
        print_success "Docker Hub login successful"
    else
        print_error "Docker Hub login failed"
        exit 1
    fi
}

# Generate secure secret key
generate_secret_key() {
    python3 -c "import secrets; print(secrets.token_urlsafe(50))"
}

# Setup SSL certificates
setup_ssl_certificates() {
    print_header "Setting Up SSL Certificates"
    
    # Create SSL directory
    sudo mkdir -p $APP_DIR/nginx/ssl
    
    if [ "$SETUP_SSL" = "letsencrypt" ]; then
        setup_letsencrypt
    elif [ "$SETUP_SSL" = "cloudflare" ]; then
        setup_cloudflare_cert
    else
        print_info "Skipping SSL setup"
    fi
}

# Setup Let's Encrypt
setup_letsencrypt() {
    print_info "Setting up Let's Encrypt certificates..."
    
    # Stop any running containers temporarily
    cd $APP_DIR
    docker compose -f compose.prod.yaml down 2>/dev/null || true
    
    # Obtain certificate using standalone mode
    sudo certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --email "$SSL_EMAIL" \
        -d "$DOMAIN_NAME" \
        -d "www.$DOMAIN_NAME"
    
    if [ $? -eq 0 ]; then
        # Copy certificates to nginx directory
        sudo cp /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem $APP_DIR/nginx/ssl/
        sudo cp /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem $APP_DIR/nginx/ssl/
        sudo chown -R $USER:$USER $APP_DIR/nginx/ssl
        
        print_success "Let's Encrypt certificates installed"
        
        # Setup auto-renewal with hook to copy certs
        cat > /tmp/renew-hook.sh << 'HOOKEOF'
#!/bin/bash
cp /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem $APP_DIR/nginx/ssl/
cp /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem $APP_DIR/nginx/ssl/
docker exec asfa-nginx-1 nginx -s reload
HOOKEOF
        
        sudo mv /tmp/renew-hook.sh /etc/letsencrypt/renewal-hooks/post/copy-certs.sh
        sudo chmod +x /etc/letsencrypt/renewal-hooks/post/copy-certs.sh
        
        # Setup cron for renewal
        (sudo crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | sudo crontab -
        
        print_success "Auto-renewal configured"
    else
        print_error "Failed to obtain Let's Encrypt certificate"
        print_warning "Continuing without SSL..."
        SETUP_SSL="none"
    fi
}

# Setup Cloudflare Origin Certificate
setup_cloudflare_cert() {
    print_info "Setting up Cloudflare Origin Certificate"
    echo
    print_warning "You need to manually create an Origin Certificate in Cloudflare:"
    echo "  1. Go to your Cloudflare Dashboard"
    echo "  2. Select your domain"
    echo "  3. Go to SSL/TLS > Origin Server"
    echo "  4. Click 'Create Certificate'"
    echo "  5. Save both the certificate and private key"
    echo
    print_info "Paste the certificate content (including BEGIN/END lines):"
    print_info "Press Ctrl+D when done"
    cat > $APP_DIR/nginx/ssl/fullchain.pem
    
    print_info "Paste the private key content (including BEGIN/END lines):"
    print_info "Press Ctrl+D when done"
    cat > $APP_DIR/nginx/ssl/privkey.pem
    
    chmod 600 $APP_DIR/nginx/ssl/privkey.pem
    print_success "Cloudflare Origin Certificate installed"
}

# Setup environment file
setup_env_file() {
    print_header "Environment Configuration"
    
    if [ -f "$APP_DIR/.env.docker" ]; then
        print_warning "Environment file already exists"
        read -p "Do you want to reconfigure it? [y/N]: " RECONFIG_ENV
        
        if [[ ! "$RECONFIG_ENV" =~ ^[Yy]$ ]]; then
            print_info "Keeping existing environment file"
            return
        fi
        
        cp $APP_DIR/.env.docker $APP_DIR/.env.docker.backup.$(date +%Y%m%d_%H%M%S)
        print_info "Existing file backed up"
    fi
    
    print_step "Creating environment file with default values..."
    
    # Generate a secure secret key
    GENERATED_SECRET_KEY=$(generate_secret_key)
    
    cat > $APP_DIR/.env.docker << EOF
# ============================================================
# Django Core Settings
# ============================================================
DEBUG=False
DJANGO_SECRET_KEY=$GENERATED_SECRET_KEY
ENVIRONMENT=production
SITE_ID=1
SITE_NAME=$DOMAIN_NAME
SITE_URL=https://$DOMAIN_NAME

# ============================================================
# Allowed Hosts & CSRF
# ============================================================
ALLOWED_HOSTS=localhost,127.0.0.1,$DOMAIN_NAME,www.$DOMAIN_NAME
CSRF_ORIGINS=https://$DOMAIN_NAME,https://www.$DOMAIN_NAME

# ============================================================
# Database Configuration
# ============================================================
DATABASE_URL=postgresql://user:password@host:5432/asfa_prod

# ============================================================
# Redis Configuration
# ============================================================
REDIS_URL=redis://redis:6379/0
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=

# ============================================================
# Email Configuration
# ============================================================
EMAIL_BACKEND=django.core.mail.backends.smtp.EmailBackend
EMAIL_HOST=smtp.resend.com
EMAIL_PORT=465
EMAIL_USE_TLS=False
EMAIL_USE_SSL=True
EMAIL_HOST_USER=resend
EMAIL_HOST_PASSWORD=re_your_resend_api_key
DEFAULT_FROM_EMAIL=noreply@$DOMAIN_NAME

# ============================================================
# Cloudflare R2 Storage (Public)
# ============================================================
CLOUDFLARE_R2_ACCOUNT_ID=your-account-id
CLOUDFLARE_R2_PUBLIC_BUCKET=asfa-public
CLOUDFLARE_R2_PUBLIC_BUCKET_ENDPOINT=https://your-account-id.r2.cloudflarestorage.com
CLOUDFLARE_R2_PUBLIC_ACCESS_KEY=your-access-key
CLOUDFLARE_R2_PUBLIC_SECRET_KEY=your-secret-key
CLOUDFLARE_R2_PUBLIC_CUSTOM_DOMAIN=https://cdn.$DOMAIN_NAME

# ============================================================
# Cloudflare R2 Storage (Media/Private)
# ============================================================
CLOUDFLARE_R2_BUCKET=asfa-media
CLOUDFLARE_R2_BUCKET_ENDPOINT=https://your-account-id.r2.cloudflarestorage.com
CLOUDFLARE_R2_ACCESS_KEY=your-access-key
CLOUDFLARE_R2_SECRET_KEY=your-secret-key

# ============================================================
# Database Backups (Cloudflare R2)
# ============================================================
BACKUP_R2_ACCOUNT_ID=your-account-id
BACKUP_R2_BUCKET_NAME=asfa-backups
BACKUP_R2_REGION=auto
BACKUP_R2_ACCESS_KEY_ID=your-access-key
BACKUP_R2_SECRET_ACCESS_KEY=your-secret-key
BACKUP_R2_ENDPOINT=https://your-account-id.r2.cloudflarestorage.com

# ============================================================
# Error Tracking (Sentry)
# ============================================================
SENTRY_DSN=
SENTRY_ENVIRONMENT=production
SENTRY_TRACE_SAMPLE_RATE=0.5

# ============================================================
# Admin Configuration
# ============================================================
ADMIN_NAME=School Administrator
ADMIN_EMAIL=admin@$DOMAIN_NAME

# ============================================================
# Python Version
# ============================================================
PYTHON_VERSION=3.12

# ============================================================
# Security Headers (Production)
# ============================================================
SECURE_SSL_REDIRECT=True
SESSION_COOKIE_SECURE=True
CSRF_COOKIE_SECURE=True
SECURE_HSTS_SECONDS=31536000
SECURE_HSTS_PRELOAD=True

# ============================================================
# Logging
# ============================================================
LOG_LEVEL=INFO

# ============================================================
# Celery Configuration
# ============================================================
CELERY_TASK_TIME_LIMIT=3600
CELERY_TASK_SOFT_TIME_LIMIT=3000
CELERY_CONCURRENCY=4
CELERY_PREFETCH_MULTIPLIER=1
EOF
    
    print_success "Environment file created with default values"
    
    # Show important notice
    print_header "IMPORTANT: Environment Configuration Required"
    echo
    print_warning "The application REQUIRES proper configuration to run!"
    echo
    print_info "The nano editor will now open. Please configure:"
    echo
    echo "  ${YELLOW}⚠ REQUIRED:${NC}"
    echo "    - DATABASE_URL (PostgreSQL connection string)"
    echo "    - EMAIL_HOST_USER & EMAIL_HOST_PASSWORD"
    echo "    - Cloudflare R2 credentials (all fields)"
    echo
    echo "  ${CYAN}○ OPTIONAL:${NC}"
    echo "    - Sentry DSN (monitoring)"
    echo
    print_info "Press Ctrl+X, then Y, then Enter to save and exit"
    echo
    read -p "Press Enter to open the editor..."
    
    nano $APP_DIR/.env.docker
    
    print_success "Environment file saved"
}

# Setup systemd service
setup_systemd() {
    print_header "Setting Up Systemd Service"
    
    sudo tee /etc/systemd/system/asfa.service > /dev/null << EOF
[Unit]
Description=ASFA Django Application
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/docker compose -f compose.prod.yaml up -d
ExecStop=/usr/bin/docker compose -f compose.prod.yaml down
User=$USER
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable asfa.service
    
    print_success "Systemd service created and enabled"
}

# Setup firewall
setup_firewall() {
    if [[ "$SETUP_FIREWALL" =~ ^[Yy]$ ]]; then
        print_header "Configuring UFW Firewall"
        
        sudo ufw allow 22/tcp
        print_info "Allowed SSH (port 22)"
        
        sudo ufw allow 80/tcp
        sudo ufw allow 443/tcp
        print_info "Allowed HTTP (80) and HTTPS (443)"
        
        sudo ufw --force enable
        
        print_success "Firewall configured"
        sudo ufw status
    fi
}

# Create management scripts
create_management_scripts() {
    print_header "Creating Management Scripts"
    
    # Deploy script
    cat > $APP_DIR/deploy.sh << 'EOF'
#!/bin/bash
set -e

echo "Starting deployment..."
cd $(dirname "$0")

echo "Pulling latest image..."
docker pull acerschoolapp/acerschoolfinanceapp:latest

echo "Stopping containers..."
docker compose -f compose.prod.yaml down

echo "Starting new containers..."
docker compose -f compose.prod.yaml up -d

echo "Waiting for services to be healthy..."
sleep 30

docker compose -f compose.prod.yaml ps

echo "Deployment complete!"
EOF
    
    chmod +x $APP_DIR/deploy.sh
    
    # Logs script
    cat > $APP_DIR/logs.sh << 'EOF'
#!/bin/bash
cd $(dirname "$0")

SERVICE=${1:-all}

if [ "$SERVICE" = "all" ]; then
    docker compose -f compose.prod.yaml logs -f --tail=100
else
    docker compose -f compose.prod.yaml logs -f --tail=100 $SERVICE
fi
EOF
    
    chmod +x $APP_DIR/logs.sh
    
    # Status script
    cat > $APP_DIR/status.sh << 'EOF'
#!/bin/bash
cd $(dirname "$0")

echo "=== Container Status ==="
docker compose -f compose.prod.yaml ps
echo

echo "=== Resource Usage ==="
docker stats --no-stream

echo "=== Health Checks ==="
docker compose -f compose.prod.yaml ps --format json | grep -o '"Health":"[^"]*"' || echo "Health checks running..."
EOF
    
    chmod +x $APP_DIR/status.sh
    
    # Stop/Start scripts
    cat > $APP_DIR/stop.sh << 'EOF'
#!/bin/bash
cd $(dirname "$0")
echo "Stopping all services..."
docker compose -f compose.prod.yaml down
echo "Services stopped."
EOF
    
    chmod +x $APP_DIR/stop.sh
    
    cat > $APP_DIR/start.sh << 'EOF'
#!/bin/bash
cd $(dirname "$0")
echo "Starting all services..."
docker compose -f compose.prod.yaml up -d
echo "Waiting for health checks..."
sleep 30
docker compose -f compose.prod.yaml ps
EOF
    
    chmod +x $APP_DIR/start.sh
    
    # Reconfigure script
    cat > $APP_DIR/reconfig.sh << 'EOF'
#!/bin/bash
cd $(dirname "$0")

echo "Opening environment configuration..."
nano .env.docker

echo ""
read -p "Restart application with new configuration? [Y/n]: " RESTART
RESTART=${RESTART:-Y}

if [[ "$RESTART" =~ ^[Yy]$ ]]; then
    ./deploy.sh
else
    echo "Configuration saved. Run './deploy.sh' to apply changes."
fi
EOF
    
    chmod +x $APP_DIR/reconfig.sh
    
    # Backup script
    cat > $APP_DIR/backup.sh << 'EOF'
#!/bin/bash
cd $(dirname "$0")

echo "Creating database backup..."
docker compose -f compose.prod.yaml exec -T web python manage.py dbbackup

echo "Backup complete! Stored in R2 bucket."
EOF
    
    chmod +x $APP_DIR/backup.sh
    
    print_success "Management scripts created"
}

# Start application
start_application() {
    print_header "Starting Application"
    
    cd $APP_DIR
    
    print_info "Pulling latest Docker image..."
    docker pull acerschoolapp/acerschoolfinanceapp:latest
    
    print_info "Starting services..."
    docker compose -f compose.prod.yaml up -d
    
    print_info "Waiting for services to start (this may take 2-3 minutes)..."
    
    for i in {1..12}; do
        sleep 5
        echo -n "."
    done
    echo
    
    docker compose -f compose.prod.yaml ps
    
    WEB_HEALTH=$(docker inspect --format='{{.State.Health.Status}}' $(docker compose -f compose.prod.yaml ps -q web) 2>/dev/null || echo "starting")
    
    if [ "$WEB_HEALTH" = "healthy" ]; then
        print_success "Application started successfully!"
    else
        print_warning "Application started, health checks pending..."
        print_info "Run './logs.sh web' to monitor startup"
    fi
}

# Print completion message
print_completion() {
    print_header "Installation Complete!"
    
    echo -e "${GREEN}Your ASFA Django application is now deployed!${NC}\n"
    
    echo "Application Details:"
    echo "  Domain: https://$DOMAIN_NAME"
    echo "  App Directory: $APP_DIR"
    echo "  Environment File: $APP_DIR/.env.docker"
    echo
    
    echo "Next Steps:"
    echo
    echo "  1. Configure Cloudflare:"
    if [ "$SETUP_SSL" = "letsencrypt" ] || [ "$SETUP_SSL" = "cloudflare" ]; then
        echo "     - Set SSL/TLS mode to 'Full (strict)'"
    else
        echo "     - Set SSL/TLS mode to 'Flexible'"
    fi
    echo "     - Enable 'Always Use HTTPS'"
    echo "     - Add A record: $DOMAIN_NAME → [Your Server IP]"
    echo "     - Add A record: www.$DOMAIN_NAME → [Your Server IP]"
    echo
    
    echo "  2. Create Django superuser:"
    echo "     cd $APP_DIR"
    echo "     docker compose -f compose.prod.yaml exec web python manage.py createsuperuser"
    echo
    
    echo "  3. Create your first school tenant:"
    echo "     docker compose -f compose.prod.yaml exec web python manage.py create_tenant"
    echo
    
    echo "Management Commands:"
    echo "  Deploy/Update:     cd $APP_DIR && ./deploy.sh"
    echo "  View Logs:         cd $APP_DIR && ./logs.sh [service]"
    echo "  Check Status:      cd $APP_DIR && ./status.sh"
    echo "  Stop/Start:        cd $APP_DIR && ./stop.sh|./start.sh"
    echo "  Reconfigure:       cd $APP_DIR && ./reconfig.sh"
    echo "  Backup Database:   cd $APP_DIR && ./backup.sh"
    echo
    
    echo "Service-specific logs:"
    echo "  ./logs.sh web"
    echo "  ./logs.sh celery_worker"
    echo "  ./logs.sh celery_beat"
    echo "  ./logs.sh nginx"
    echo "  ./logs.sh redis"
    echo
    
    print_warning "IMPORTANT: You may need to log out and back in for Docker group changes"
    print_warning "           Or run: newgrp docker"
    echo
    
    print_info "Visit: https://$DOMAIN_NAME"
    print_info "(Allow 2-3 minutes for all services to be fully ready)"
    echo
}

# Main installation flow
main() {
    print_header "ASFA Django Application - Automated Deployment"
    
    check_sudo
    check_os
    gather_config
    
    update_system
    install_docker
    create_deployer_user
    setup_app_directory
    clone_repository
    docker_login
    setup_ssl_certificates
    setup_env_file
    setup_systemd
    setup_firewall
    create_management_scripts
    
    save_config
    
    print_header "Ready to Start Application"
    print_info "All configuration is complete!"
    echo
    read -p "Start the application now? [Y/n]: " START_NOW
    START_NOW=${START_NOW:-Y}
    
    if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
        start_application
    else
        print_info "Application not started. Run './start.sh' when ready."
    fi
    
    print_completion
}

# Run main
main