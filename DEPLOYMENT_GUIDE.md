# ASFA Deployment Guide

## Prerequisites

- Fresh Ubuntu/Debian VPS (20.04 LTS or newer recommended)
- Root or sudo access
- Domain name pointing to your server IP
- Docker Hub account with access to the private image
- Cloudflare account (for R2 storage and SSL)

## Quick Start

### 1. Upload Script to GitHub

Create a new public repository (e.g., `asfa-deployment`) and push the deployment script:

```bash
git init
git add deploy.sh
git commit -m "Initial deployment script"
git branch -M main
git remote add origin https://github.com/paulmbui20/asfa-deploy-script.git
git push -u origin main
```

### 2. Prepare Your Server

SSH into your VPS:

```bash
ssh root@your-server-ip
```

### 3. Run the Deployment Script

```bash
# Download the script
curl -O https://raw.githubusercontent.com/paulmbui20/asfa-deploy-script/main/deploy.sh

# Make it executable
chmod +x deploy.sh

# Run it
./deploy.sh
```

### 4. Follow the Interactive Prompts

The script will ask you for:

- **Domain name**: e.g., `school.com`
- **Docker Hub credentials**: Username and password/token
- **Application directory**: Default is `/opt/apps/asfa`
- **Create deployer user**: Recommended (Y)
- **Setup firewall**: Recommended (Y)
- **SSL Certificate option**:
  - Option 1: Let's Encrypt (requires domain to be pointing to server)
  - Option 2: Cloudflare Origin Certificate (recommended)
  - Option 3: None (HTTP only)

### 5. Configure Environment Variables

The script will open nano editor. Configure these REQUIRED fields:

```env
# Database
DATABASE_URL=postgresql://user:pass@host:5432/asfa_prod

# Email (for Resend)
EMAIL_HOST_PASSWORD=re_your_resend_api_key

# Cloudflare R2 - Public bucket (for static files)
CLOUDFLARE_R2_ACCOUNT_ID=your-account-id
CLOUDFLARE_R2_PUBLIC_ACCESS_KEY=your-access-key
CLOUDFLARE_R2_PUBLIC_SECRET_KEY=your-secret-key
CLOUDFLARE_R2_PUBLIC_BUCKET=asfa-public
CLOUDFLARE_R2_PUBLIC_CUSTOM_DOMAIN=https://cdn.school.com

# Cloudflare R2 - Private bucket (for media files)
CLOUDFLARE_R2_ACCESS_KEY=your-access-key
CLOUDFLARE_R2_SECRET_KEY=your-secret-key
CLOUDFLARE_R2_BUCKET=asfa-media

# Cloudflare R2 - Backups
BACKUP_R2_ACCESS_KEY_ID=your-backup-access-key
BACKUP_R2_SECRET_ACCESS_KEY=your-backup-secret-key
BACKUP_R2_BUCKET_NAME=asfa-backups
```

## SSL Setup Options

### Option 1: Let's Encrypt (Free)

**Requirements:**
- Domain must be pointing to your server IP
- Ports 80 and 443 must be open

**Pros:**
- Free and trusted by all browsers
- Auto-renewal configured

**Cons:**
- Requires domain to be fully propagated
- May fail if domain isn't pointing to server

### Option 2: Cloudflare Origin Certificate (Recommended)

**Steps:**
1. Choose option 2 during setup
2. Go to Cloudflare Dashboard → SSL/TLS → Origin Server
3. Click "Create Certificate"
4. Copy the certificate and private key
5. Paste when prompted by the script

**Pros:**
- Works even if domain isn't fully propagated
- 15-year validity
- Pairs perfectly with Cloudflare proxy

**Cons:**
- Only trusted when traffic goes through Cloudflare
- Manual creation required

**Cloudflare SSL Settings:**
- Go to SSL/TLS → Overview
- Set mode to **"Full (strict)"**
- Enable "Always Use HTTPS"

### Option 3: HTTP Only

Only use for testing. Not recommended for production.

## Post-Deployment Steps

### 1. Create Django Superuser

```bash
cd /opt/apps/asfa
docker compose -f compose.prod.yaml exec web python manage.py createsuperuser
```

### 2. Create Your First School Tenant

```bash
docker compose -f compose.prod.yaml exec web python manage.py create_tenant
```

Follow the prompts to create your first school.

### 3. Configure Cloudflare (if using)

**DNS Records:**
```
A     @           your-server-ip
A     www         your-server-ip
A     *           your-server-ip (for multi-tenant)
CNAME cdn         your-r2-custom-domain
```

**SSL/TLS Settings:**
- Mode: Full (strict)
- Always Use HTTPS: On
- Automatic HTTPS Rewrites: On
- Minimum TLS Version: 1.2

**Firewall:**
- Consider enabling "Under Attack Mode" if needed
- Set up rate limiting rules

## Management Commands

After deployment, navigate to your app directory:

```bash
cd /opt/apps/asfa
```

### Daily Operations

```bash
# View all logs
./logs.sh

# View specific service logs
./logs.sh web
./logs.sh celery_worker
./logs.sh nginx

# Check status
./status.sh

# Restart application
./deploy.sh
```

### Maintenance

```bash
# Stop application
./stop.sh

# Start application
./start.sh

# Update configuration
./reconfig.sh

# Backup database
./backup.sh
```

### Docker Commands

```bash
# Execute Django management commands
docker compose -f compose.prod.yaml exec web python manage.py [command]

# Access Django shell
docker compose -f compose.prod.yaml exec web python manage.py shell

# Run migrations
docker compose -f compose.prod.yaml exec web python manage.py migrate

# Collect static files (if needed locally)
docker compose -f compose.prod.yaml exec web python manage.py collectstatic --noinput

# View real-time logs
docker compose -f compose.prod.yaml logs -f
```

## Troubleshooting

### Application Won't Start

Check logs:
```bash
./logs.sh web
```

Common issues:
- Database connection failed (check DATABASE_URL)
- Redis connection failed (ensure redis container is running)
- Missing environment variables

### SSL Certificate Issues

**Let's Encrypt failed:**
- Ensure domain is pointing to server
- Check ports 80/443 are open
- Verify no other service is using port 80

**Cloudflare Origin Certificate:**
- Ensure certificate files are in `nginx/ssl/`
- Check file permissions (should be readable)
- Verify Cloudflare SSL mode is "Full (strict)"

### 502 Bad Gateway

Usually means Django isn't responding:
```bash
./logs.sh web
docker compose -f compose.prod.yaml ps
```

Check if web container is healthy.

### Performance Issues

```bash
# Check resource usage
docker stats

# Check container health
docker compose -f compose.prod.yaml ps

# Restart specific service
docker compose -f compose.prod.yaml restart web
```

## Updating the Application

When a new version is released:

```bash
cd /opt/apps/asfa
./deploy.sh
```

This will:
1. Pull the latest image
2. Stop old containers
3. Start new containers
4. Wait for health checks

## Backup & Recovery

### Automated Backups

Backups are automatically stored in Cloudflare R2:

```bash
# Manual backup
./backup.sh
```

### Restore from Backup

```bash
# List available backups
docker compose -f compose.prod.yaml exec web python manage.py listbackups

# Restore a specific backup
docker compose -f compose.prod.yaml exec web python manage.py dbrestore --input-filename=backup-name.dump
```

## Monitoring

### Check Application Health

```bash
# Via command
./status.sh

# Via web
curl https://yourschool.com/health/
```

### View Metrics

```bash
# Container stats
docker stats

# Disk usage
df -h

# Memory usage
free -h
```

## Security Best Practices

1. **Keep system updated:**
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

2. **Monitor logs regularly:**
   ```bash
   ./logs.sh | grep -i error
   ```

3. **Backup regularly:**
   ```bash
   # Setup daily backup cron
   crontab -e
   # Add: 0 2 * * * /opt/apps/asfa/backup.sh
   ```

4. **Use strong passwords** for:
   - Database
   - Django admin
   - Server SSH

5. **Enable Cloudflare WAF** if using Cloudflare

## Getting Help

If you encounter issues:

1. Check the logs: `./logs.sh`
2. Verify configuration: `cat .env.docker`
3. Check service status: `./status.sh`
4. Review this guide's troubleshooting section

## File Structure

```
/opt/apps/asfa/
├── compose.prod.yaml
├── .env.docker
├── nginx/
│   ├── nginx.conf
│   └── ssl/
│       ├── fullchain.pem
│       └── privkey.pem
├── deploy.sh
├── logs.sh
├── status.sh
├── start.sh
├── stop.sh
├── reconfig.sh
├── backup.sh
└── .deployment_config
```

## Environment Variables Reference

See the sample.env file in your repository for all available configuration options.

**Critical variables:**
- `DATABASE_URL` - PostgreSQL connection
- `DJANGO_SECRET_KEY` - Auto-generated, keep secure
- `ALLOWED_HOSTS` - Your domain names
- `CLOUDFLARE_R2_*` - R2 storage credentials
- `EMAIL_*` - Email service configuration

## Notes

- SSL certificates are stored in `nginx/ssl/` directory
- Logs are persisted in Docker volumes
- Database backups go to R2 bucket
- Static/media files are served from R2 CDN
- Multi-tenant: Each school gets a subdomain
- Health checks ensure zero-downtime deployments