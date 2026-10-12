#!/bin/bash
set -e

# ============================================
# Setup Portainer - pkserver
# ============================================

INSTALL_DIR="$HOME/Desktop/bb/portanier"
IP="192.168.1.134"
TZ="Europe/Madrid"
HTTP_PORT="9000"
HTTPS_PORT="9443"
EDGE_PORT="8000"

# Credenciales (el usuario siempre es "admin"; contraseña de 12+ caracteres)
ADMIN_PASSWORD="pppkkkpppkkk"

echo "============================================"
echo " Setup Portainer - pkserver"
echo "============================================"

# --------------------------------------------
# 1. Comprobaciones
# --------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker no está instalado." >&2
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  echo "Error: Docker Compose no está instalado." >&2
  exit 1
fi

if [ "${#ADMIN_PASSWORD}" -lt 12 ]; then
  echo "Error: ADMIN_PASSWORD debe tener al menos 12 caracteres." >&2
  exit 1
fi

# --------------------------------------------
# 2. Carpetas
# --------------------------------------------
echo "[1/5] Creando carpetas en $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/secrets"

# --------------------------------------------
# 3. Contraseña del admin
# --------------------------------------------
echo "[2/5] Guardando contraseña del admin ..."
printf '%s' "$ADMIN_PASSWORD" > "$INSTALL_DIR/secrets/portainer_password"
chmod 600 "$INSTALL_DIR/secrets/portainer_password"

if [ -n "$(ls -A "$INSTALL_DIR/data" 2>/dev/null)" ]; then
  echo "AVISO: data/ ya contiene datos. Si Portainer ya tiene un admin creado,"
  echo "       la contraseña indicada se ignorará. Para empezar de cero:"
  echo "       cd $INSTALL_DIR && $COMPOSE down && rm -rf data/*"
fi

# --------------------------------------------
# 4. Archivo .env
# --------------------------------------------
echo "[3/5] Creando .env ..."
cat > "$INSTALL_DIR/.env" <<EOF
TZ=$TZ
PORTAINER_HTTP_PORT=$HTTP_PORT
PORTAINER_HTTPS_PORT=$HTTPS_PORT
PORTAINER_EDGE_PORT=$EDGE_PORT
EOF

# --------------------------------------------
# 5. docker-compose.yml
# --------------------------------------------
echo "[4/5] Creando docker-compose.yml ..."
cat > "$INSTALL_DIR/docker-compose.yml" <<'EOF'
services:
  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: always
    command:
      - --http-enabled
      - --admin-password-file=/run/secrets/portainer_password
    security_opt:
      - no-new-privileges:true
    environment:
      - TZ=${TZ}
    ports:
      - "${PORTAINER_HTTP_PORT}:9000"
      - "${PORTAINER_HTTPS_PORT}:9443"
      - "${PORTAINER_EDGE_PORT}:8000"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
      - ./secrets/portainer_password:/run/secrets/portainer_password:ro
EOF

# --------------------------------------------
# 6. Arrancar
# --------------------------------------------
echo "[5/5] Arrancando Portainer ..."
cd "$INSTALL_DIR"
$COMPOSE up -d --force-recreate

echo ""
echo "============================================"
echo " Portainer listo"
echo "============================================"
echo " HTTP:       http://$IP:$HTTP_PORT"
echo " HTTPS:      https://$IP:$HTTPS_PORT"
echo " Usuario:    admin"
echo " Password:   (la definida en ADMIN_PASSWORD)"
echo " Carpeta:    $INSTALL_DIR"
echo " Logs:       cd $INSTALL_DIR && $COMPOSE logs -f"
echo " Parar:      cd $INSTALL_DIR && $COMPOSE down"
echo "============================================"