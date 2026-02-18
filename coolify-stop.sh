#!/bin/bash
# coolify-stop.sh — Stop ALL Coolify-managed containers
# Usage: ./coolify-stop.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${CYAN}ℹ $1${NC}"; }

echo -e "\n${YELLOW}=== Coolify — Stop All Containers ===${NC}\n"

if ! command -v docker &>/dev/null; then
    print_error "Docker is not installed or not in PATH."
    exit 1
fi

# ── Coolify core stack (via compose project label) ─────────────────────────
COOLIFY_CORE=$(docker ps --filter "label=com.docker.compose.project=coolify" -q 2>/dev/null || true)

# ── All containers managed/deployed by Coolify (custom label) ──────────────
COOLIFY_APPS=$(docker ps --filter "label=coolify.managed=true" -q 2>/dev/null || true)

ALL=$(echo -e "$COOLIFY_CORE\n$COOLIFY_APPS" | sort -u | grep -v '^$' || true)

if [ -z "$ALL" ]; then
    print_info "No running Coolify containers found."
    exit 0
fi

COUNT=$(echo "$ALL" | wc -l)
print_warning "Stopping $COUNT Coolify container(s)..."
echo

# Print names before stopping so the operator knows what was affected
docker ps --filter "label=com.docker.compose.project=coolify" \
          --filter "label=coolify.managed=true" \
          --format "  • {{.Names}} ({{.Image}})" 2>/dev/null || true

echo
docker stop $ALL

echo
print_success "All Coolify containers stopped."
print_info "To restart:  ./coolify-restart.sh"
print_info "To check:    docker ps -a --filter label=com.docker.compose.project=coolify"
