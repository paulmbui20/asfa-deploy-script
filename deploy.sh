#!/bin/bash

# ESC Django Application - Automated Deployment Script
# This script automates the complete deployment of the ESC application on a fresh VPS

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
# ESC Deployment Configuration
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
    echo "  1) Let's Encrypt (Free, auto-renewing, requires valid domain pointing to this server)"
    echo "  2) None (Use Cloudflare SSL/TLS - Recommended for Cloudflare users)"
    read -p "Select option [1/2]: " SSL_OPTION
    SSL_OPTION=${SSL_OPTION:-2}
    
    if [ "$SSL_OPTION" = "1" ]; then
        SETUP_SSL="letsencrypt"
        if [ -n "$SSL_EMAIL" ]; then
            read -p "Email for Let's Encrypt notifications [$SSL_EMAIL]: " NEW_SSL_EMAIL
            SSL_EMAIL=${NEW_SSL_EMAIL:-$SSL_EMAIL}
        else
            read -p "Email for Let's Encrypt notifications: " SSL_EMAIL
            while [ -z "$SSL_EMAIL" ]; do
                print_warning "Email cannot be empty for Let's Encrypt"
                read -p "Email for Let's Encrypt notifications: " SSL_EMAIL
            done
        fi
        print_warning "Important: Your domain MUST be pointing to this server's IP for Let's Encrypt to work"
        print_info "Make sure you've added DNS A record: $DOMAIN_NAME → [Server IP]"
    else
        SETUP_SSL="none"
        SSL_EMAIL=""
        print_info "Will use HTTP only - Cloudflare will handle SSL"
        print_info "Set Cloudflare SSL/TLS mode to 'Flexible'"
    fi
}

# Interactive configuration
gather_config() {
    print_header "Configuration Setup"
    
    # Set default app directory first
    DEFAULT_APP_DIR="/opt/apps/esc"
    
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
        read -p "Enter your domain name (e.g., example.com): " DOMAIN_NAME
        while [ -z "$DOMAIN_NAME" ]; do
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
        while [ -z "$DOCKER_USERNAME" ]; do
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
    if [ "$EXISTING_CONFIG" = true ] && [ -n "$SETUP_SSL" ]; then
        echo
        print_info "SSL Certificate Configuration"
        echo "Current SSL setup: $SETUP_SSL"
        read -p "Keep existing SSL configuration? [Y/n]: " KEEP_SSL
        KEEP_SSL=${KEEP_SSL:-Y}
        
        if [[ "$KEEP_SSL" =~ ^[Yy]$ ]]; then
            print_info "Keeping existing SSL configuration"
        else
            configure_ssl_option
        fi
    else
        configure_ssl_option
    fi
    
    print_header "Configuration Summary"
    echo "Domain: $DOMAIN_NAME"
    echo "Docker Hub User: $DOCKER_USERNAME"
    echo "App Directory: $APP_DIR"
    echo "Create deployer user: $CREATE_USER"
    echo "Setup firewall: $SETUP_FIREWALL"
    if [ "$SETUP_SSL" = "letsencrypt" ]; then
        echo "SSL: Let's Encrypt (Email: $SSL_EMAIL)"
    else
        echo "SSL: None (Cloudflare handles SSL)"
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
    sudo apt install -y curl wget git ufw nano
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
        git clone https://github.com/andreas-tuko/esc-compose-prod.git .
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
# Redis Configuration
# ============================================
REDIS_URL=redis://redis:6379
REDIS_HOST=redis
REDIS_PASSWORD=

# ============================================
# Site Configuration
# ============================================
SITE_ID=1
SITE_NAME=$DOMAIN_NAME
SITE_URL=https://$DOMAIN_NAME

# ============================================
# Email Configuration
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
# Additional Configuration
# ============================================
ADMIN_NAME=Admin Name
ADMIN_EMAIL=admin@$DOMAIN_NAME
PYTHON_VERSION=3.13.5
EOF
    
    print_success "Environment file created"
    
    print_header "IMPORTANT: Environment Configuration"
    print_warning "Please configure your environment file now"
    read -p "Press Enter to open the editor..."
    
    nano $APP_DIR/.env.docker
    
    print_success "Environment file saved"
}

# Install and configure Nginx
install_nginx() {
    print_header "Installing and Configuring Nginx"
    
    # Install Nginx
    if command -v nginx &> /dev/null; then
        print_warning "Nginx is already installed"
    else
        sudo apt install -y nginx
        print_success "Nginx installed"
    fi
    
    # Setup SSL if Let's Encrypt is selected
    if [ "$SETUP_SSL" = "letsencrypt" ]; then
        setup_letsencrypt_ssl
    fi
    
    # Create Nginx configuration
    if [ "$SETUP_SSL" = "letsencrypt" ]; then
        create_nginx_config_with_ssl
    else
        create_nginx_config_http_only
    fi
    
    # Enable site
    sudo ln -sf /etc/nginx/sites-available/esc /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    
    # Test configuration
    sudo nginx -t
    
    if [ $? -eq 0 ]; then
        sudo systemctl restart nginx
        sudo systemctl enable nginx
        print_success "Nginx configured and started"
    else
        print_error "Nginx configuration test failed"
        exit 1
    fi
}

# Setup Let's Encrypt SSL
setup_letsencrypt_ssl() {
    print_header "Setting Up Let's Encrypt SSL"
    
    # Install certbot
    if ! command -v certbot &> /dev/null; then
        print_info "Installing Certbot..."
        sudo apt install -y certbot python3-certbot-nginx
        print_success "Certbot installed"
    fi
    
    # Stop nginx temporarily
    sudo systemctl stop nginx 2>/dev/null || true
    
    # Obtain certificate
    print_info "Obtaining SSL certificate from Let's Encrypt..."
    print_warning "Your domain must be pointing to this server's IP"
    
    sudo certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --email "$SSL_EMAIL" \
        -d "$DOMAIN_NAME" \
        -d "www.$DOMAIN_NAME"
    
    if [ $? -eq 0 ]; then
        print_success "SSL certificate obtained successfully"
        
        # Setup auto-renewal
        (sudo crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | sudo crontab -
        print_success "Auto-renewal configured (runs daily at 3 AM)"
    else
        print_error "Failed to obtain SSL certificate"
        print_warning "Falling back to HTTP-only configuration"
        SETUP_SSL="none"
    fi
}

# Create Nginx config with SSL
create_nginx_config_with_ssl() {
    print_info "Creating Nginx configuration with Let's Encrypt SSL..."
    
    sudo tee /etc/nginx/sites-available/esc > /dev/null << EOF
upstream django_app {
    server 127.0.0.1:8000;
    keepalive 64;
}

# HTTP server - redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    
    # Allow Let's Encrypt challenges
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # Redirect all other traffic to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    
    # SSL Security Settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN_NAME/chain.pem;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Logging
    access_log /var/log/nginx/esc_access.log;
    error_log /var/log/nginx/esc_error.log;

    # Client body size limit
    client_max_body_size 100M;

    # Timeouts
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;

    location / {
        proxy_pass http://django_app;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Health check endpoint
    location /health {
        access_log off;
        proxy_pass http://django_app;
        proxy_set_header Host \$host;
    }
}
EOF
}

# Create Nginx config HTTP only
create_nginx_config_http_only() {
    print_info "Creating Nginx configuration (HTTP only for Cloudflare)..."
    
    sudo tee /etc/nginx/sites-available/esc > /dev/null << EOF
upstream django_app {
    server 127.0.0.1:8000;
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Logging
    access_log /var/log/nginx/esc_access.log;
    error_log /var/log/nginx/esc_error.log;

    # Client body size limit
    client_max_body_size 100M;

    # Timeouts
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;

    location / {
        proxy_pass http://django_app;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Cloudflare real IP
        set_real_ip_from 173.245.48.0/20;
        set_real_ip_from 103.21.244.0/22;
        set_real_ip_from 103.22.200.0/22;
        set_real_ip_from 103.31.4.0/22;
        set_real_ip_from 141.101.64.0/18;
        set_real_ip_from 108.162.192.0/18;
        set_real_ip_from 190.93.240.0/20;
        set_real_ip_from 188.114.96.0/20;
        set_real_ip_from 197.234.240.0/22;
        set_real_ip_from 198.41.128.0/17;
        set_real_ip_from 162.158.0.0/15;
        set_real_ip_from 104.16.0.0/13;
        set_real_ip_from 104.24.0.0/14;
        set_real_ip_from 172.64.0.0/13;
        set_real_ip_from 131.0.72.0/22;
        real_ip_header CF-Connecting-IP;
    }

    # Health check endpoint
    location /health {
        access_log off;
        proxy_pass http://django_app;
        proxy_set_header Host \$host;
    }
}
EOF
}

# Setup systemd service
setup_systemd() {
    print_header "Setting Up Systemd Service"
    
    sudo tee /etc/systemd/system/esc.service > /dev/null << EOF
[Unit]
Description=ESC Django Application
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

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable esc.service
    
    print_success "Systemd service created and enabled"
}

# Setup firewall
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

# Create management scripts
create_management_scripts() {
    print_header "Creating Management Scripts"
    
    cat > $APP_DIR/deploy.sh << 'EOF'
#!/bin/bash
set -e
cd $(dirname "$0")
echo "Pulling latest image..."
docker pull andreastuko/esc:latest
echo "Restarting services..."
docker compose -f compose.prod.yaml down
docker compose -f compose.prod.yaml up -d
sleep 30
docker compose -f compose.prod.yaml ps
echo "Deployment complete!"
EOF
    
    chmod +x $APP_DIR/deploy.sh
    
    cat > $APP_DIR/logs.sh << 'EOF'
#!/bin/bash
cd $(dirname "$0")
docker compose -f compose.prod.yaml logs -f ${1:-}
EOF
    
    chmod +x $APP_DIR/logs.sh
    
    cat > $APP_DIR/status.sh << 'EOF'
#!/bin/bash
cd $(dirname "$0")
echo "=== Containers ==="
docker compose -f compose.prod.yaml ps
echo ""
echo "=== Nginx ==="
sudo systemctl status nginx --no-pager
EOF
    
    chmod +x $APP_DIR/status.sh
    
    print_success "Management scripts created"
}

# Start application
start_application() {
    print_header "Starting Application"
    
    cd $APP_DIR
    docker pull andreastuko/esc:latest
    docker compose -f compose.prod.yaml up -d
    
    print_info "Waiting for services..."
    sleep 60
    
    docker compose -f compose.prod.yaml ps
    print_success "Application started!"
}

# Print completion message
print_completion() {
    print_header "Installation Complete!"
    
    echo -e "${GREEN}Your ESC application is deployed!${NC}\n"
    
    if [ "$SETUP_SSL" = "letsencrypt" ]; then
        echo "Access at: https://$DOMAIN_NAME"
        echo "SSL: Let's Encrypt (auto-renewing)"
    else
        echo "Access at: http://$DOMAIN_NAME"
        echo "SSL: Configure Cloudflare SSL/TLS to 'Flexible' mode"
    fi
    
    echo ""
    echo "Management commands:"
    echo "  Deploy:  cd $APP_DIR && ./deploy.sh"
    echo "  Logs:    cd $APP_DIR && ./logs.sh"
    echo "  Status:  cd $APP_DIR && ./status.sh"
    echo ""
    
    print_warning "Log out and back in for Docker group changes"
}

# Main
main() {
    print_header "ESC Django Application - Deployment"
    
    check_sudo
    check_os
    gather_config
    update_system
    install_docker
    create_deployer_user
    setup_app_directory
    clone_repository
    docker_login
    setup_env_file
    install_nginx
    setup_systemd
    setup_firewall
    create_management_scripts
    save_config
    
    read -p "Start application now? [Y/n]: " START_NOW
    START_NOW=${START_NOW:-Y}
    
    if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
        start_application
    fi
    
    print_completion
}

main