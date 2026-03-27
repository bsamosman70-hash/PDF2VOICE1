#!/usr/bin/env bash
# ssl-setup.sh — Add free HTTPS (Let's Encrypt) to PDF2Voice using Certbot + nginx
# Usage: bash ssl-setup.sh yourdomain.com your@email.com
#
# Prerequisites:
#   • deploy.sh already run successfully (nginx container is running on port 80)
#   • DNS A record for yourdomain.com points to this server's public IP
#   • Port 80 and 443 open in your firewall

set -euo pipefail

DOMAIN="${1:-}"
EMAIL="${2:-}"

[[ -z "$DOMAIN" ]] && { echo "Usage: bash ssl-setup.sh <domain> <email>"; exit 1; }
[[ -z "$EMAIL" ]]  && { echo "Usage: bash ssl-setup.sh <domain> <email>"; exit 1; }

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$APP_DIR/nginx/certs"
mkdir -p "$CERTS_DIR"

# Install certbot if not present
if ! command -v certbot &>/dev/null; then
  echo "[INFO] Installing certbot..."
  sudo apt-get update -q
  sudo apt-get install -y certbot
fi

# Stop nginx temporarily to free port 80 for certbot standalone challenge
echo "[INFO] Stopping nginx container for ACME challenge..."
docker compose -f "$APP_DIR/docker-compose.prod.yml" stop nginx

# Obtain certificate
echo "[INFO] Requesting certificate for $DOMAIN..."
sudo certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN"

# Copy certs to project directory (nginx container reads from here via volume)
CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
sudo cp "$CERT_PATH/fullchain.pem" "$CERTS_DIR/fullchain.pem"
sudo cp "$CERT_PATH/privkey.pem"   "$CERTS_DIR/privkey.pem"
sudo chown "$USER:$USER" "$CERTS_DIR/"*.pem
chmod 600 "$CERTS_DIR/privkey.pem"

# Write HTTPS nginx config
cat > "$APP_DIR/nginx/default.conf" << NGINX
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    root /usr/share/nginx/html;
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript;

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    location /api/ {
        proxy_pass http://api:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        client_max_body_size 512m;
    }

    location ~ ^/(docs|redoc|openapi\.json) {
        proxy_pass http://api:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location = /health.txt {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}
NGINX

# Update docker-compose.prod.yml to mount certs and expose 443
# (patch the nginx service ports)
if ! grep -q "443:443" "$APP_DIR/docker-compose.prod.yml"; then
  sed -i 's|      - "80:80"|      - "80:80"\n      - "443:443"|' "$APP_DIR/docker-compose.prod.yml"
fi

# Add certs volume to nginx service if not already present
if ! grep -q "nginx/certs" "$APP_DIR/docker-compose.prod.yml"; then
  sed -i '/depends_on:/{ /- api/{ N; s/\(    depends_on:\n      - api\)/\1\n    volumes:\n      - .\/nginx\/certs:\/etc\/nginx\/certs:ro/ } }' \
    "$APP_DIR/docker-compose.prod.yml" || true
fi

# Rebuild + restart nginx with the new config
echo "[INFO] Rebuilding nginx with HTTPS config..."
docker compose -f "$APP_DIR/docker-compose.prod.yml" build --no-cache nginx
docker compose -f "$APP_DIR/docker-compose.prod.yml" up -d nginx

# Set up auto-renewal cron
CRON_CMD="0 3 * * * certbot renew --quiet && cp $CERT_PATH/fullchain.pem $CERTS_DIR/fullchain.pem && cp $CERT_PATH/privkey.pem $CERTS_DIR/privkey.pem && docker compose -f $APP_DIR/docker-compose.prod.yml restart nginx"
(crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_CMD") | crontab -

echo ""
echo "[OK] HTTPS is now live at https://$DOMAIN"
echo "[OK] Certificate auto-renewal scheduled via cron."
