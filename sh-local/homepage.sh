#!/bin/bash
set -e

# ============================================
# Setup Homepage Dashboard - pkserver
# ============================================

INSTALL_DIR="$HOME/Desktop/bb/Homepage"
IP="192.168.1.134"
IP="localhost"
HOSTNAME="pkserver"
PORT="3000"            # puerto por defecto de Homepage (80/443 quedan libres)

echo "==> Creando estructura en $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/config"
cd "$INSTALL_DIR"

# --------------------------------------------
# docker-compose.yml
# --------------------------------------------
cat > docker-compose.yml << EOF
services:
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    ports:
      - "${PORT}:3000"
    environment:
      HOMEPAGE_ALLOWED_HOSTS: "${HOSTNAME}:${PORT},${HOSTNAME}.local:${PORT},${IP}:${PORT},localhost:${PORT}"
    volumes:
      - ./config:/app/config
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped
EOF

# --------------------------------------------
# config/docker.yaml
# --------------------------------------------
cat > config/docker.yaml << EOF
my-docker:
  socket: /var/run/docker.sock
EOF

# --------------------------------------------
# config/services.yaml
# --------------------------------------------
cat > config/services.yaml << EOF
- Multimedia:
    - Jellyfin:
        href: http://${IP}:8096
        description: "pk / pk / Puerto 8096"
        icon: jellyfin
        server: my-docker
        container: jellyfin

- IoT ThingsBoard:
    - ThingsBoard (Internet):
        href: https://VatiaCo.duckdns.org/home
        description: "Acceso publico HTTPS / pk@pkserver.local / pk"
        icon: thingsboard

    - ThingsBoard:
        href: https://${IP}
        description: "pk@pkserver.local / pk (admin) · cliente@pkserver.local / pk (Panel simulador) · cec@pkserver.local / cec (Comunidad Energética Churriana) / HTTPS 443, HTTP 8080"
        icon: thingsboard
        server: my-docker
        container: iot-thingsboard

    - Node-RED:
        href: http://${IP}:1880
        description: "pk / pk / Puerto 1880"
        icon: node-red
        server: my-docker
        container: iot-nodered

    - Mosquitto:
        description: "pk / pk / MQTT 1883 LAN · wss://VatiaCo.duckdns.org/mqtt (TB MQTT 1884)"
        icon: mosquitto
        server: my-docker
        container: iot-mosquitto

    - PostgreSQL:
        description: "pk / pk / solo 127.0.0.1:5433"
        icon: postgres
        server: my-docker
        container: iot-postgres

    - MQTT Explorer:
        href: http://${IP}:4000
        description: "GUI de Mosquitto / pk / pk / Puerto 4000"
        icon: mqtt-explorer
        server: my-docker
        container: iot-mqtt-explorer

    - Adminer:
        href: http://${IP}:8081/?pgsql=127.0.0.1%3A5433&username=pk&db=thingsboard
        description: "GUI de PostgreSQL (sistema PostgreSQL, ya preseleccionado) / pk / pk / BD thingsboard"
        icon: adminer
        server: my-docker
        container: iot-adminer

    - Caddy:
        href: https://${IP}
        description: "HTTPS 443 -> ThingsBoard"
        icon: caddy
        server: my-docker
        container: iot-caddy

- Inteligencia Artificial:
    - Open WebUI:
        href: http://${IP}:3001
        description: "admin@ia.local / pppkkkpppkkk / Puerto 3001"
        icon: open-webui
        server: my-docker
        container: ia-webui

    - IA API (FastAPI):
        href: http://${IP}:8010/docs
        description: "Sin autenticacion / Puerto 8010"
        icon: fastapi
        server: my-docker
        container: ia-api

    - Ollama:
        href: http://${IP}:11434
        description: "Sin autenticacion / Puerto 11434"
        icon: ollama
        server: my-docker
        container: ia-ollama

- Automatizacion:
    - n8n:
        href: http://${IP}:5678
        description: "admin@pkserver.local / pppkkkpppkkkA1@ / Puerto 5678"
        icon: n8n
        server: my-docker
        container: n8n

    - Typst API:
        href: http://${IP}:8020/
        description: "Editor web, sin autenticacion / Puerto 8020"
        icon: fastapi
        server: my-docker
        container: typst-api

- Web:
    - VatiaCo (proman):
        href: http://${IP}:8030
        description: "Web Astro, sin autenticacion / Puerto 8030"
        icon: astro
        server: my-docker
        container: proman-web

- Administracion:
    - Portainer:
        href: https://${IP}:9443
        description: "admin / pppkkkpppkkk / Puerto 9443 (HTTPS)"
        icon: portainer
        server: my-docker
        container: portainer
EOF

echo "==> Estructura creada:"
find "$INSTALL_DIR" -maxdepth 2

# --------------------------------------------
# Arrancar el contenedor
# --------------------------------------------
echo "==> Arrancando Homepage..."
docker compose up -d --force-recreate

echo "==> Esperando a que arranque..."
sleep 15

echo "==> Comprobando..."
if curl -sf -I "http://${HOSTNAME}:${PORT}" > /dev/null 2>&1 || curl -sf -I "http://${IP}:${PORT}" > /dev/null 2>&1; then
    echo "✅ Homepage funcionando. Abre http://${IP}:${PORT} o http://${HOSTNAME}:${PORT}"
else
    echo "⚠️  No responde todavia. Revisa con: docker compose logs --tail 30"
fi
