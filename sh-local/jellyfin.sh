#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$HOME/Desktop/bb/jellyfin"
MEDIA_DIR="$HOME/media"
IP="192.168.1.134"
JF_PORT="8096"

# Usuario administrador (se crea automaticamente en el asistente inicial)
JF_USER="pk"
JF_PASSWORD="pk"

# Biblioteca (mixta: peliculas, series, musica...) sobre $MEDIA_DIR del host,
# montada como /media dentro del contenedor
LIBRARY_NAME="Media"

echo "========================================"
echo " Jellyfin - Docker"
echo "========================================"
echo
echo "Directorio Jellyfin: $BASE_DIR"
echo "Directorio Media:    $MEDIA_DIR"
echo

# Comprobar Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker no está instalado."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose no está disponible."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl no está instalado."
    exit 1
fi

# Comprobar carpeta de media del host
if [ ! -d "$MEDIA_DIR" ]; then
    echo "ERROR: No existe $MEDIA_DIR"
    exit 1
fi

echo "[OK] Docker disponible"
echo "[OK] Docker Compose disponible"
echo "[OK] Media encontrado: $MEDIA_DIR"

# Crear carpetas
mkdir -p "$BASE_DIR/config"
mkdir -p "$BASE_DIR/cache"

# Crear docker-compose.yml
cat > "$BASE_DIR/docker-compose.yml" <<EOF_COMPOSE
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped

    ports:
      - "${JF_PORT}:8096"

    volumes:
      - ./config:/config
      - ./cache:/cache
      - ${MEDIA_DIR}:/media:ro

    environment:
      - TZ=Europe/Madrid
EOF_COMPOSE

echo
echo "[OK] docker-compose.yml creado"

# Entrar en la carpeta
cd "$BASE_DIR"

# Descargar imagen
echo
echo "Descargando imagen de Jellyfin..."
docker compose pull

# Arrancar
echo
echo "Arrancando Jellyfin..."
docker compose up -d

# --------------------------------------------
# Configuracion inicial via API (usuario + bibliotecas)
# --------------------------------------------
URL="http://localhost:$JF_PORT"
CLIENT='MediaBrowser Client="setup-script", Device="pkserver", DeviceId="setup-script", Version="1.0"'

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

echo
echo "Esperando a que Jellyfin responda..."
INFO=""
for _ in $(seq 1 90); do
    if INFO=$(curl -sf "$URL/System/Info/Public" 2>/dev/null); then
        break
    fi
    sleep 2
done
if [ -z "$INFO" ]; then
    echo "AVISO: Jellyfin no responde. Revisa: docker compose logs --tail 50"
    exit 1
fi

if echo "$INFO" | grep -q '"StartupWizardCompleted":true'; then
    echo "[OK] Asistente inicial ya completado (no se modifica el usuario)"
else
    echo "Completando asistente inicial (usuario $JF_USER)..."
    # Los endpoints /Startup pueden tardar unos segundos en estar listos
    for _ in $(seq 1 30); do
        curl -sf -o /dev/null "$URL/Startup/User" && break
        sleep 2
    done
    curl -sf -X POST "$URL/Startup/Configuration" -H "Content-Type: application/json" \
        -d '{"UICulture":"es","MetadataCountryCode":"ES","PreferredMetadataLanguage":"es"}'
    curl -sf -X POST "$URL/Startup/User" -H "Content-Type: application/json" \
        -d "{\"Name\":\"$(json_escape "$JF_USER")\",\"Password\":\"$(json_escape "$JF_PASSWORD")\"}"
    curl -sf -X POST "$URL/Startup/RemoteAccess" -H "Content-Type: application/json" \
        -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'
    curl -sf -X POST "$URL/Startup/Complete"
    echo "[OK] Usuario $JF_USER creado"
fi

# Login para obtener un token
TOKEN=""
for _ in $(seq 1 15); do
    AUTH=$(curl -sf -X POST "$URL/Users/AuthenticateByName" \
        -H "Content-Type: application/json" -H "Authorization: $CLIENT" \
        -d "{\"Username\":\"$(json_escape "$JF_USER")\",\"Pw\":\"$(json_escape "$JF_PASSWORD")\"}" 2>/dev/null || true)
    TOKEN=$(printf '%s' "$AUTH" | sed -n 's/.*"AccessToken":"\([^"]*\)".*/\1/p')
    [ -n "$TOKEN" ] && break
    sleep 2
done

if [ -z "$TOKEN" ]; then
    echo "AVISO: no se pudo iniciar sesión como $JF_USER; las bibliotecas no se han creado."
    echo "       Si Jellyfin ya tenía otro usuario, créalas a mano desde el panel."
else
    AUTH_HDR="$CLIENT, Token=\"$TOKEN\""
    EXISTING=$(curl -sf "$URL/Library/VirtualFolders" -H "Authorization: $AUTH_HDR" || echo "[]")
    if printf '%s' "$EXISTING" | grep -q '"/media"'; then
        echo "[OK] Ya hay una biblioteca sobre /media"
    else
        # Sin collectionType = biblioteca mixta (peliculas, series, musica...)
        NAME_Q=$(printf '%s' "$LIBRARY_NAME" | sed 's/ /%20/g')
        curl -sf -X POST "$URL/Library/VirtualFolders?name=$NAME_Q&paths=%2Fmedia&refreshLibrary=true" \
            -H "Authorization: $AUTH_HDR" -H "Content-Type: application/json" \
            -d '{"LibraryOptions":{"EnableRealtimeMonitor":true,"PreferredMetadataLanguage":"es","MetadataCountryCode":"ES"}}' \
            && echo "[OK] Biblioteca '$LIBRARY_NAME' -> $MEDIA_DIR (/media en el contenedor)" \
            || echo "AVISO: no se pudo crear la biblioteca '$LIBRARY_NAME'"
    fi
fi

# Estado
echo
echo "========================================"
echo " Estado"
echo "========================================"

docker compose ps

echo
echo "========================================"
echo " Jellyfin iniciado"
echo "========================================"
echo
echo "URL:        http://$IP:$JF_PORT"
echo "Usuario:    $JF_USER"
echo "Password:   $JF_PASSWORD"
echo
echo "Configuración:"
echo "  $BASE_DIR/config"
echo
echo "Media:"
echo "  $MEDIA_DIR  ->  /media (dentro del contenedor)"
echo
