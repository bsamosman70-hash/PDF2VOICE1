#!/usr/bin/env bash
# deploy.sh — PDF2Voice production deployment script
# Run this on your VPS (Ubuntu 22.04+ recommended) as a non-root user with sudo.
# Usage: bash deploy.sh [--update]

set -euo pipefail

COMPOSE_FILE="docker-compose.prod.yml"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 1. Check dependencies ────────────────────────────────────────────────────
info "Checking dependencies..."
command -v docker  &>/dev/null || error "Docker not found. Install from https://docs.docker.com/engine/install/"
command -v git     &>/dev/null || error "Git not found. Run: sudo apt install -y git"

# Docker Compose v2 (plugin)
if ! docker compose version &>/dev/null; then
  error "Docker Compose v2 not found. Run: sudo apt install -y docker-compose-plugin"
fi

info "Docker $(docker --version)"
info "Docker Compose $(docker compose version)"

# ── 2. Environment file ───────────────────────────────────────────────────────
cd "$APP_DIR"

if [[ ! -f .env ]]; then
  if [[ -f env.example ]]; then
    cp env.example .env
    warn ".env created from env.example — EDIT IT before continuing!"
    warn "Required: DATABASE_URL, REDIS_URL, SECRET_KEY, AWS_*, STRIPE_*, TTS provider keys."
    warn "Then re-run this script."
    exit 1
  else
    error "No .env file found. Create one based on env.example."
  fi
fi

# Validate critical variables
source_env() {
  set -a; source .env; set +a
}
source_env

required_vars=(
  SECRET_KEY
  POSTGRES_PASSWORD
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_REGION
  S3_BUCKET_NAME
)

missing=()
for var in "${required_vars[@]}"; do
  [[ -z "${!var:-}" ]] && missing+=("$var")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  error "Missing required .env variables: ${missing[*]}"
fi

info ".env validated."

# ── 3. Pull latest code (skip on --update from CI) ───────────────────────────
if [[ "${1:-}" != "--no-pull" ]]; then
  info "Pulling latest code..."
  git pull --ff-only
fi

# ── 4. Build images ───────────────────────────────────────────────────────────
info "Building Docker images..."
docker compose -f "$COMPOSE_FILE" build --pull --no-cache

# ── 5. Start data tier first ──────────────────────────────────────────────────
info "Starting data tier (postgres, redis)..."
docker compose -f "$COMPOSE_FILE" up -d postgres redis

info "Waiting for postgres to be healthy..."
until docker compose -f "$COMPOSE_FILE" exec -T postgres \
  pg_isready -U "${POSTGRES_USER:-pdf2voice}" &>/dev/null; do
  sleep 2
done
info "Postgres ready."

# ── 6. Run migrations ─────────────────────────────────────────────────────────
info "Running database migrations..."
docker compose -f "$COMPOSE_FILE" run --rm migrate

# ── 7. Start application tier ────────────────────────────────────────────────
info "Starting application services..."
docker compose -f "$COMPOSE_FILE" up -d api worker nginx flower

# ── 8. Health check ───────────────────────────────────────────────────────────
info "Waiting for API to be healthy..."
max_attempts=30
attempt=0
until curl -sf http://localhost/api/v1/health &>/dev/null; do
  attempt=$((attempt + 1))
  [[ $attempt -ge $max_attempts ]] && error "API did not become healthy after ${max_attempts} attempts."
  sleep 3
done
info "API is healthy."

# ── 9. Show status ────────────────────────────────────────────────────────────
echo ""
info "Deployment complete!"
echo ""
docker compose -f "$COMPOSE_FILE" ps
echo ""
echo -e "${GREEN}Services:${NC}"
echo "  Frontend + API  →  http://$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "  Flower monitor  →  http://$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP'):5555"
echo "  API docs        →  http://$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')/docs"
echo ""
warn "For HTTPS, run: bash ssl-setup.sh yourdomain.com your@email.com"
