#!/bin/bash
set -e

# ============================================
# Setup proman (web Astro) en Docker - pkserver
#
# La carpeta del proyecto NO se modifica: se usa solo como contexto
# de build (lectura). El Dockerfile y la config viven en INSTALL_DIR.
# La imagen compila el sitio (npm ci + npm run build) y lo sirve con nginx.
# Para publicar cambios del proyecto basta con volver a ejecutar este script.
# ============================================

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/proman"
INSTALL_DIR="$HOME/Desktop/bb/proman-web"
IP="192.168.1.134"
WEB_PORT="8030"        # 8000 Portainer, 8010 IA, 8020 Typst

if [ ! -f "$SRC_DIR/package.json" ]; then
  echo "ERROR: no se encuentra el proyecto Astro en $SRC_DIR" >&2
  exit 1
fi

echo "==> Creando estructura en $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# --------------------------------------------
# Dockerfile (multi-stage: build con Node, servir con nginx)
# --------------------------------------------
cat > Dockerfile <<'EOF'
FROM node:20-alpine AS build
# ffprobe lo usa scripts/generate-video-manifest.mjs (prebuild)
RUN apk add --no-cache ffmpeg bash
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
EOF

# Ignore propio de este Dockerfile (BuildKit): no hace falta tocar el proyecto
cat > Dockerfile.dockerignore <<'EOF'
node_modules
dist
.astro
.git
.claude
.env
.env.*
zz
py
sh
EOF

# nginx.conf se monta como volumen (el contexto de build es el proyecto)
cat > nginx.conf <<'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml text/plain;

    location / {
        try_files $uri $uri/ $uri.html =404;
    }

    # El service worker no debe quedarse en cache
    location = /sw.js {
        add_header Cache-Control "no-cache";
    }

    location /_astro/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }
}
EOF

# --------------------------------------------
# docker-compose.yml
#   context  -> carpeta del proyecto (solo lectura)
# --------------------------------------------
cat > docker-compose.yml <<EOF
name: proman-web

services:
  proman-web:
    build:
      context: ${SRC_DIR}
      dockerfile: ${INSTALL_DIR}/Dockerfile
    image: proman-web:latest
    container_name: proman-web
    restart: unless-stopped
    ports:
      - "${WEB_PORT}:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOF

# --------------------------------------------
# Scripts de gestion
# --------------------------------------------
cat > start.sh <<EOF
#!/bin/bash
set -e
cd "\$(dirname "\$0")"
docker compose up -d --build
echo
echo "  proman : http://$IP:$WEB_PORT"
EOF

cat > stop.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
docker compose down
EOF

cat > logs.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
docker compose logs -f --tail=100 "$@"
EOF

chmod +x start.sh stop.sh logs.sh

# --------------------------------------------
# Construir y arrancar
# --------------------------------------------
echo "==> Construyendo imagen desde $SRC_DIR (puede tardar la primera vez)..."
./start.sh

echo "==> Comprobando..."
for _ in $(seq 1 15); do
  if curl -sf -o /dev/null "http://localhost:$WEB_PORT/"; then
    echo "✅ proman funcionando en http://$IP:$WEB_PORT"
    exit 0
  fi
  sleep 1
done
echo "⚠️  No responde todavia. Revisa con: cd $INSTALL_DIR && ./logs.sh"
