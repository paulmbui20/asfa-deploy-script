#!/bin/bash
# coolify-restart.sh — Restart ALL Coolify-managed containers
# Usage: ./coolify-restart.sh [--stop-only]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${CYAN}ℹ $1${NC}"; }

echo -e "\n${BLUE}=== Coolify — Restart All Containers ===${NC}\n"

if ! command -v docker &>/dev/null; then
    print_error "Docker is not installed or not in PATH."
    exit 1
fi

# ── Collect all Coolify containers (running OR stopped) ────────────────────
COOLIFY_CORE=$(docker ps -a --filter "label=com.docker.compose.project=coolify" -q 2>/dev/null || true)
COOLIFY_APPS=$(docker ps -a --filter "label=coolify.managed=true" -q 2>/dev/null || true)
ALL=$(echo -e "$COOLIFY_CORE\n$COOLIFY_APPS" | sort -u | grep -v '^$' || true)

if [ -z "$ALL" ]; then
    print_info "No Coolify containers found (running or stopped)."
    exit 0
fi

COUNT=$(echo "$ALL" | wc -l)

# ── Stop phase ─────────────────────────────────────────────────────────────
print_warning "Stopping $COUNT Coolify container(s)..."
echo

docker ps -a \
    --filter "label=com.docker.compose.project=coolify" \
    --format "  • {{.Names}} [{{.Status}}]" 2>/dev/null || true
docker ps -a \
    --filter "label=coolify.managed=true" \
    --format "  • {{.Names}} [{{.Status}}]" 2>/dev/null || true

echo
# Only stop containers that are actually running
RUNNING=$(docker ps --filter "label=com.docker.compose.project=coolify" \
                    --filter "label=coolify.managed=true" -q 2>/dev/null || true)
RUNNING=$(echo -e "$RUNNING" | sort -u | grep -v '^$' || true)
[ -n "$RUNNING" ] && docker stop $RUNNING || print_info "No running containers to stop."
print_success "Stop phase complete."

# Early exit if --stop-only flag passed
if [ "${1:-}" = "--stop-only" ]; then
    print_info "Stopped only (--stop-only flag set). Not restarting."
    exit 0
fi

# ── Brief pause so ports are released ─────────────────────────────────────
sleep 2

# ── Start phase ────────────────────────────────────────────────────────────
print_warning "Starting $COUNT Coolify container(s)..."
echo

docker start $ALL

echo
print_success "All Coolify containers restarted."
echo
print_info "Check status:  docker ps --filter label=com.docker.compose.project=coolify"
print_info "Coolify logs:  docker logs coolify --tail 50 -f"
print_info "To stop all:   ./coolify-stop.sh"
