#!/bin/bash
set -e

# ============================================
# Setup ecosistema IA local - pkserver
#
#   Navegador -> Open WebUI (GUI) -> Ollama (modelo local)
# ============================================

INSTALL_DIR="$HOME/Desktop/bb/ia"
IP="192.168.1.134"
TZ="Europe/Madrid"

WEBUI_PORT="3001"      # Open WebUI (GUI) - 3000 lo usa Homepage
OLLAMA_PORT="11434"    # Ollama (modelo)

# Carpeta del sistema donde dejas tus modelos .gguf (se vigila automaticamente)
MODELS_DIR="$HOME/ias"

# Modelo que Ollama descarga solo al arrancar y queda seleccionado por defecto.
# Puede ser de Ollama (llama3.1:8b) o de Hugging Face: hf.co/<usuario>/<repo>:<cuantizacion>
# Dejalo vacio ("") si solo quieres usar los .gguf de MODELS_DIR.
MODEL="hf.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF:Q4_K_M"   # ~1 GB, prueba de concepto

# Cuenta de administrador de Open WebUI (se crea sola en el primer arranque)
ADMIN_NAME="Admin"
ADMIN_EMAIL="admin@ia.local"
ADMIN_PASSWORD="pppkkkpppkkk"      # vacio = se genera una aleatoria y se guarda en .env
ENABLE_SIGNUP="false"  # false = nadie mas puede registrarse desde la pantalla de login

echo "==> Creando estructura en $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/data/{ollama,open-webui} "$MODELS_DIR"
cd "$INSTALL_DIR"

# --------------------------------------------
# .env (no se sobreescribe si ya existe)
# --------------------------------------------
if [ ! -f .env ]; then
  SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  cat > .env <<EOF
TZ=$TZ
IP=$IP
WEBUI_PORT=$WEBUI_PORT
OLLAMA_PORT=$OLLAMA_PORT
MODEL=$MODEL
MODELS_DIR=$MODELS_DIR
WEBUI_SECRET_KEY=$SECRET
EOF
  echo "==> .env creado"
else
  # Sincroniza puertos y modelo con los de esta cabecera (el resto del .env se mantiene)
  sed -i "s/^WEBUI_PORT=.*/WEBUI_PORT=$WEBUI_PORT/; s/^OLLAMA_PORT=.*/OLLAMA_PORT=$OLLAMA_PORT/; s|^MODEL=.*|MODEL=$MODEL|" .env
  if grep -q '^MODELS_DIR=' .env; then
    sed -i "s|^MODELS_DIR=.*|MODELS_DIR=$MODELS_DIR|" .env
  else
    echo "MODELS_DIR=$MODELS_DIR" >> .env
  fi
  # Elimina restos de la antigua API (FastAPI + Typst)
  sed -i '/^API_PORT=/d; /^TYPST_VERSION=/d' .env
  echo "==> .env ya existe, se mantiene (puertos actualizados)"
fi

# Credenciales de admin: solo se anaden si faltan (no pisan lo que ya haya en .env)
if ! grep -q '^WEBUI_ADMIN_EMAIL=' .env; then
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD=$(openssl rand -hex 12 2>/dev/null || head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  cat >> .env <<EOF
WEBUI_ADMIN_NAME=$ADMIN_NAME
WEBUI_ADMIN_EMAIL=$ADMIN_EMAIL
WEBUI_ADMIN_PASSWORD=$ADMIN_PASSWORD
ENABLE_SIGNUP=$ENABLE_SIGNUP
EOF
  echo "==> Credenciales de admin anadidas a .env"
fi
chmod 600 .env

# --------------------------------------------
# docker-compose.yml
# --------------------------------------------
cat > docker-compose.yml <<'EOF'
name: ia-local

services:
  # ---------- Modelo IA local ----------
  ollama:
    image: ollama/ollama:latest
    container_name: ia-ollama
    restart: unless-stopped
    environment:
      - TZ=${TZ}
      - OLLAMA_KEEP_ALIVE=30m
    ports:
      - "${OLLAMA_PORT}:11434"
    volumes:
      - ./data/ollama:/root/.ollama
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 10s

  # ---------- Descarga del modelo (una vez) ----------
  ollama-pull:
    image: ollama/ollama:latest
    container_name: ia-ollama-pull
    restart: "no"
    depends_on:
      ollama:
        condition: service_healthy
    entrypoint: ["sh", "-c", "if [ -n \"$$MODEL\" ]; then ollama pull \"$$MODEL\"; else echo 'MODEL vacio: no se descarga nada'; fi"]
    environment:
      - OLLAMA_HOST=http://ollama:11434
      - MODEL=${MODEL}

  # ---------- Registra en Ollama los .gguf que dejes en MODELS_DIR ----------
  model-sync:
    image: ollama/ollama:latest
    container_name: ia-model-sync
    restart: unless-stopped
    depends_on:
      ollama:
        condition: service_healthy
    environment:
      - OLLAMA_HOST=http://ollama:11434
      - SYNC_INTERVAL=30
    volumes:
      - ${MODELS_DIR}:/models:ro
      - ./sync-models.sh:/sync-models.sh:ro
    entrypoint: ["bash", "/sync-models.sh"]

  # ---------- GUI ----------
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: ia-webui
    restart: unless-stopped
    depends_on:
      ollama:
        condition: service_healthy
    environment:
      - TZ=${TZ}
      - OLLAMA_BASE_URL=http://ollama:11434
      - ENABLE_OPENAI_API=false
      - WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
      - WEBUI_NAME=IA Local
      - DEFAULT_MODELS=${MODEL}
      - WEBUI_ADMIN_NAME=${WEBUI_ADMIN_NAME}
      - WEBUI_ADMIN_EMAIL=${WEBUI_ADMIN_EMAIL}
      - WEBUI_ADMIN_PASSWORD=${WEBUI_ADMIN_PASSWORD}
      - ENABLE_SIGNUP=${ENABLE_SIGNUP}
    ports:
      - "${WEBUI_PORT}:8080"
    volumes:
      - ./data/open-webui:/app/backend/data
EOF

# Override opcional para GPU NVIDIA (requiere nvidia-container-toolkit)
cat > docker-compose.gpu.yml <<'EOF'
services:
  ollama:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOF

# --------------------------------------------
# sync-models.sh: se ejecuta dentro del contenedor model-sync
# --------------------------------------------
cat > sync-models.sh <<'EOF'
#!/bin/bash
# Registra en Ollama cada .gguf de la carpeta de modelos (bucle continuo).
#  - Nombre del modelo en Open WebUI = nombre del archivo en minusculas, sin .gguf
#  - Ignora archivos modificados hace menos de 1 minuto (descargas en curso)
#  - Si existe <archivo>.Modelfile al lado, lo usa (para plantilla/parametros propios)
DIR="${MODELS_PATH:-/models}"
INTERVAL="${SYNC_INTERVAL:-30}"
declare -A fallidos

echo "[model-sync] vigilando $DIR cada ${INTERVAL}s"
while true; do
  existentes=$(ollama list 2>/dev/null | awk 'NR>1{print $1}')
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    base=$(basename "$f" .gguf)
    name=$(echo "$base" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9._-]/-/g')
    echo "$existentes" | grep -qx "${name}:latest" && continue
    key="$f:$(stat -c %Y "$f")"
    [ -n "${fallidos[$key]}" ] && continue

    tmp=$(mktemp)
    mf="${f%.gguf}.Modelfile"
    if [ -f "$mf" ]; then sed "s|^FROM .*|FROM $f|" "$mf" > "$tmp"; else echo "FROM $f" > "$tmp"; fi
    echo "[model-sync] registrando '$name' <- $f"
    if ollama create "$name" -f "$tmp"; then
      echo "[model-sync] '$name' disponible en Open WebUI"
    else
      echo "[model-sync] ERROR registrando $f (no se reintenta hasta que cambie el archivo)"
      fallidos[$key]=1
    fi
    rm -f "$tmp"
  done < <(find "$DIR" -type f -name '*.gguf' -mmin +1 2>/dev/null | sort)
  sleep "$INTERVAL"
done
EOF

# --------------------------------------------
# Scripts de gestion
# --------------------------------------------
cat > start.sh <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
FILES="-f docker-compose.yml"
if command -v nvidia-smi >/dev/null 2>&1 && docker info 2>/dev/null | grep -qi nvidia; then
  echo "==> GPU NVIDIA detectada, activando aceleracion"
  FILES="$FILES -f docker-compose.gpu.yml"
fi
# --remove-orphans elimina contenedores de servicios que ya no estan en el compose (p. ej. ia-api)
docker compose $FILES up -d --remove-orphans
source .env
echo
echo "  Open WebUI : http://$IP:$WEBUI_PORT"
echo "  Ollama     : http://$IP:$OLLAMA_PORT"
echo
echo "El modelo se descarga en segundo plano (hasta que acabe no aparece en Open WebUI):"
echo "  docker logs -f ia-ollama-pull"
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

cat > get-model.sh <<'EOF'
#!/bin/bash
# Descarga un .gguf a la carpeta de modelos. Uso:
#   ./get-model.sh https://huggingface.co/<usuario>/<repo>/resolve/main/<archivo>.gguf
# (si el repo es privado o restringido: HF_TOKEN=hf_xxx ./get-model.sh <url>)
set -e
cd "$(dirname "$0")"
source .env
URL="$1"
[ -z "$URL" ] && { echo "Uso: $0 <url-del-gguf>"; exit 1; }
FILE="$MODELS_DIR/$(basename "${URL%%\?*}")"
AUTH=()
[ -n "$HF_TOKEN" ] && AUTH=(-H "Authorization: Bearer $HF_TOKEN")
echo "==> Descargando a $FILE"
curl -L --fail -C - "${AUTH[@]}" -o "$FILE.part" "$URL"
mv "$FILE.part" "$FILE"
echo "==> Listo. En ~1-2 min aparecera en Open WebUI (docker logs -f ia-model-sync)"
EOF

chmod +x start.sh stop.sh logs.sh get-model.sh

# --------------------------------------------
# README
# --------------------------------------------
cat > README.md <<EOF
# IA local: Open WebUI + Ollama

\`\`\`
Navegador -> Open WebUI (:$WEBUI_PORT) -> Ollama (:$OLLAMA_PORT)
\`\`\`

## Uso
\`\`\`bash
./start.sh          # levanta todo (la primera vez descarga el modelo $MODEL)
./logs.sh ollama
./stop.sh
\`\`\`

- GUI: http://$IP:$WEBUI_PORT (admin creado automaticamente; usuario y contrasena en \`.env\`)
- Modelos de Ollama: \`data/ollama\` | tus .gguf: \`$MODELS_DIR\`

## Modelos propios (.gguf)
Deja cualquier \`.gguf\` en \`$MODELS_DIR\`: el servicio \`model-sync\` lo registra en Ollama
(tarda ~1-2 min tras terminar la descarga) y aparece en Open WebUI con el nombre del archivo.
\`\`\`bash
./get-model.sh https://huggingface.co/<usuario>/<repo>/resolve/main/<archivo>.gguf
docker logs -f ia-model-sync
\`\`\`
Para plantilla/parametros propios, crea \`<archivo>.Modelfile\` junto al \`.gguf\`.

## Anadir mas modelos desde Ollama
\`\`\`bash
docker exec -it ia-ollama ollama pull llama3.1:8b
docker exec -it ia-ollama ollama pull hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M
\`\`\`
EOF

echo
echo "==> Estructura creada en $INSTALL_DIR"
echo
echo "  Open WebUI : http://$IP:$WEBUI_PORT"
echo "  Modelos    : $MODELS_DIR  (deja aqui tus .gguf)"
echo "  Admin      : $(grep '^WEBUI_ADMIN_EMAIL=' .env | cut -d= -f2-)"
echo "  Password   : $(grep '^WEBUI_ADMIN_PASSWORD=' .env | cut -d= -f2-)   (guardada en $INSTALL_DIR/.env)"
echo
RESP=""
if [ -t 0 ]; then
  read -r -p "¿Levantar los servicios ahora? [s/N] " RESP || RESP=""
fi
if [[ "$RESP" =~ ^[sSyY]$ ]]; then
  ./start.sh
else
  echo "Cuando quieras: cd $INSTALL_DIR && ./start.sh"
fi