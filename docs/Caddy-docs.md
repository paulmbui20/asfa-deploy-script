# Caddy Configuration

## Directory structure

```
/opt/apps/asfa/
├── compose.prod.yaml
├── .env.docker                  ← your real secrets (never commit)
├── .env.docker.template         ← safe template to commit
└── caddy/
    ├── Caddyfile                ← active config
```
1. In Cloudflare dashboard → **SSL/TLS → Overview** → set mode to **Flexible**
2. No domain substitution needed — Caddyfile listens on `:80` for all hosts


## Common commands

```bash
# Hot-reload Caddyfile with zero downtime
docker compose -f compose.prod.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile

# Validate config before reloading
docker compose -f compose.prod.yaml exec caddy caddy validate --config /etc/caddy/Caddyfile

# List active TLS certificates
docker compose -f compose.prod.yaml exec caddy caddy list-certificates

# Tail Caddy access logs (JSON format)
docker compose -f compose.prod.yaml logs -f caddy

# Pretty-print JSON access logs
docker compose -f compose.prod.yaml logs caddy | grep -v '^$' | jq .

# Open a shell inside the Caddy container
docker compose -f compose.prod.yaml exec caddy sh
```

## Django settings required

Add these to your `.env.docker` so Django trusts the proxy headers Caddy sets:

```env
# Cloudflare mode
USE_X_FORWARDED_HOST=True
SECURE_PROXY_SSL_HEADER=HTTP_X_FORWARDED_PROTO,https

```
