# ASFA Deployment Checklist

Use this checklist to ensure a smooth deployment.

## Pre-Deployment

### Server Preparation
- [ ] Fresh Ubuntu 20.04+ or Debian 11+ VPS provisioned
- [ ] Root/sudo access confirmed
- [ ] Server IP address noted
- [ ] SSH access tested
- [ ] Minimum 2GB RAM, 2 CPU cores

### Domain & DNS
- [ ] Domain registered
- [ ] DNS pointing to server IP (can take up to 48 hours)
- [ ] Cloudflare account created
- [ ] Domain added to Cloudflare

### External Services Setup

#### PostgreSQL Database
- [ ] PostgreSQL server installed (can be same VPS or external)
- [ ] Database created: `asfa_prod`
- [ ] Database user created with full permissions
- [ ] Connection string ready: `postgresql://user:pass@host:5432/asfa_prod`
- [ ] Connection tested from server

#### Cloudflare R2 Storage
- [ ] R2 enabled on Cloudflare account
- [ ] Three buckets created:
  - [ ] `asfa-public` (for static files)
  - [ ] `asfa-media` (for media files)
  - [ ] `asfa-backups` (for database backups)
- [ ] R2 API token created with read/write permissions
- [ ] Access credentials saved securely

#### Email Service (Resend)
- [ ] Resend account created (https://resend.com)
- [ ] Domain verified in Resend
- [ ] API key generated
- [ ] Test email sent successfully

#### Docker Hub
- [ ] Docker Hub account confirmed
- [ ] Access to private image: `acerschoolapp/acerschoolfinanceapp:latest`
- [ ] Personal access token created (recommended over password)

## During Deployment

### Initial Setup
- [ ] SSH into server: `ssh root@your-server-ip`
- [ ] Download deployment script
- [ ] Make script executable: `chmod +x deploy.sh`
- [ ] Run script: `./deploy.sh`

### Configuration Prompts
- [ ] Domain name entered correctly
- [ ] Docker Hub credentials entered
- [ ] App directory confirmed: `/opt/apps/asfa`
- [ ] Deployer user creation: Yes
- [ ] UFW firewall setup: Yes
- [ ] SSL option selected (Let's Encrypt or Cloudflare)

### Environment Configuration
- [ ] Database URL configured
- [ ] Email credentials entered (Resend API key)
- [ ] Cloudflare R2 credentials for all three buckets
- [ ] Secret key auto-generated (don't change)
- [ ] Allowed hosts include your domain
- [ ] CSRF origins include https://yourdomain.com
- [ ] All required fields filled (marked REQUIRED in comments)
- [ ] Configuration saved (Ctrl+X, Y, Enter)

### SSL Setup (if using Cloudflare Origin)
- [ ] Cloudflare Dashboard opened: SSL/TLS > Origin Server
- [ ] Origin Certificate created (15-year validity)
- [ ] Certificate PEM copied and pasted when prompted
- [ ] Private key copied and pasted when prompted
- [ ] Certificates saved in `nginx/ssl/` directory

### Application Start
- [ ] Containers started successfully
- [ ] Health checks passing (wait 2-3 minutes)
- [ ] All services showing as "healthy"

## Post-Deployment

### Cloudflare Configuration
- [ ] DNS records created:
  - [ ] A record: `@` → server IP
  - [ ] A record: `www` → server IP  
  - [ ] A record: `*` → server IP (wildcard for tenants)
- [ ] SSL/TLS mode set to "Full (strict)"
- [ ] "Always Use HTTPS" enabled
- [ ] Automatic HTTPS Rewrites: On
- [ ] Minimum TLS version: 1.2

### Application Setup
- [ ] Django superuser created:
  ```bash
  cd /opt/apps/asfa
  docker compose -f compose.prod.yaml exec web python manage.py createsuperuser
  ```
- [ ] First school tenant created:
  ```bash
  docker compose -f compose.prod.yaml exec web python manage.py create_tenant
  ```
- [ ] Admin panel accessible: `https://yourdomain.com/admin/`
- [ ] Login with superuser credentials successful

### Testing
- [ ] Website loads: `https://yourdomain.com`
- [ ] No SSL errors in browser
- [ ] Health endpoint works: `https://yourdomain.com/health/`
- [ ] Admin panel loads and login works
- [ ] Test email functionality
- [ ] Test file upload (should go to R2)
- [ ] Test creating a school tenant with subdomain
- [ ] Subdomain access works: `https://schoolname.yourdomain.com`

### Monitoring
- [ ] Check all service logs: `./logs.sh`
- [ ] Verify no errors in nginx logs: `./logs.sh nginx`
- [ ] Check web service: `./logs.sh web`
- [ ] Verify celery workers: `./logs.sh celery_worker`
- [ ] Status check: `./status.sh`
- [ ] Resource usage acceptable: `docker stats`

### Backups
- [ ] Test manual backup: `./backup.sh`
- [ ] Verify backup appears in R2 bucket
- [ ] Setup automated daily backups:
  ```bash
  crontab -e
  # Add: 0 2 * * * /opt/apps/asfa/backup.sh
  ```

### Security
- [ ] UFW firewall enabled and configured
- [ ] Only ports 22, 80, 443 open
- [ ] SSH key-based authentication enabled (disable password auth)
- [ ] Strong passwords set for:
  - [ ] Database
  - [ ] Django superuser
  - [ ] Server user account
- [ ] Cloudflare WAF considered/enabled
- [ ] Rate limiting verified in nginx

### Documentation
- [ ] Server IP address documented
- [ ] Domain and DNS settings documented
- [ ] All credentials stored securely (use password manager)
- [ ] Deployment date recorded
- [ ] Initial configuration backed up

## Maintenance Setup

### Monitoring
- [ ] Setup monitoring alerts (optional: UptimeRobot, Pingdom)
- [ ] Email notifications for downtime configured
- [ ] Log rotation verified: `/var/log/nginx/`

### Updates
- [ ] Update procedure tested
- [ ] Rollback plan documented
- [ ] Maintenance window planned for future updates

### Team Access
- [ ] SSH keys added for team members
- [ ] Admin accounts created for team
- [ ] Documentation shared with team
- [ ] Management scripts location shared

## Troubleshooting Resources

If issues occur, check:
1. Logs: `./logs.sh [service]`
2. Status: `./status.sh`
3. Container health: `docker compose -f compose.prod.yaml ps`
4. Nginx config: `docker exec asfa-nginx-1 nginx -t`
5. Database connectivity: Check DATABASE_URL
6. Cloudflare SSL settings: Must be "Full (strict)"

## Success Criteria

Your deployment is successful when:
- ✅ Website loads over HTTPS without errors
- ✅ Admin panel accessible and functional
- ✅ Email sending works
- ✅ File uploads work (going to R2)
- ✅ Background tasks processing (Celery)
- ✅ All health checks passing
- ✅ Backups working
- ✅ No errors in logs
- ✅ Multi-tenant subdomains working

## Emergency Contacts

- **Hosting Provider**: [Your VPS provider support]
- **DNS/Cloudflare**: support@cloudflare.com
- **Database**: [Your database provider support]
- **Team Lead**: [Contact info]

## Rollback Plan

If deployment fails:
```bash
cd /opt/apps/asfa
./stop.sh
# Restore previous configuration if needed
git checkout previous-commit
./deploy.sh
```

## Notes

- Initial deployment typically takes 15-30 minutes
- DNS propagation can take up to 48 hours
- SSL certificate issuance may take a few minutes
- First container start is slower (downloading images)
- Health checks need 2-3 minutes to pass

---

**Remember**: Test everything in a staging environment first!

## Deployment Date: _________________
## Deployed By: _________________
## Server IP: _________________
## Domain: _________________