#!/bin/bash
set -e

# ============================================
# Setup n8n - pkserver
# ============================================

INSTALL_DIR="$HOME/Desktop/bb/n8n"
IP="192.168.1.134"
TZ="Europe/Madrid"
N8N_PORT="5678"

# Cuenta de propietario (se crea automáticamente al arrancar)
# La contraseña necesita 8+ caracteres, 1 mayúscula y 1 número
OWNER_EMAIL="admin@pkserver.local"
OWNER_FIRSTNAME="Admin"
OWNER_LASTNAME="PK"
OWNER_PASSWORD="pppkkkpppkkkA1@"

echo "============================================"
echo " Setup n8n - pkserver"
echo "============================================"

# --------------------------------------------
# 1. Comprobaciones
# --------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker no está instalado." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl no está instalado." >&2
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

if [ "${#OWNER_PASSWORD}" -lt 8 ] || ! [[ "$OWNER_PASSWORD" =~ [A-Z] ]] || ! [[ "$OWNER_PASSWORD" =~ [0-9] ]]; then
  echo "Error: OWNER_PASSWORD debe tener 8+ caracteres, una mayúscula y un número." >&2
  exit 1
fi

# --------------------------------------------
# 2. Carpetas
# --------------------------------------------
echo "[1/7] Creando carpetas en $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/files"

# El contenedor de n8n corre como usuario "node" (uid 1000)
if [ "$(id -u)" != "1000" ]; then
  echo "      Ajustando permisos (uid 1000) con sudo ..."
  sudo chown -R 1000:1000 "$INSTALL_DIR/data" "$INSTALL_DIR/files"
fi

# --------------------------------------------
# 3. Clave de cifrado (se genera una vez y se conserva)
# --------------------------------------------
echo "[2/7] Preparando clave de cifrado ..."
if [ -f "$INSTALL_DIR/.env" ] && grep -q '^N8N_ENCRYPTION_KEY=' "$INSTALL_DIR/.env"; then
  ENC_KEY=$(grep '^N8N_ENCRYPTION_KEY=' "$INSTALL_DIR/.env" | cut -d= -f2-)
  echo "      Reutilizando clave existente."
else
  ENC_KEY=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  echo "      Clave nueva generada."
fi

# --------------------------------------------
# 4. Archivo .env
# --------------------------------------------
echo "[3/7] Creando .env ..."
cat > "$INSTALL_DIR/.env" <<EOF
TZ=$TZ
N8N_HOST=$IP
N8N_PORT=$N8N_PORT
N8N_ENCRYPTION_KEY=$ENC_KEY
EOF
chmod 600 "$INSTALL_DIR/.env"

# --------------------------------------------
# 5. Dockerfile (n8n + Typst) y docker-compose.yml
# --------------------------------------------
echo "[4/7] Creando Dockerfile y docker-compose.yml ..."
cat > "$INSTALL_DIR/Dockerfile" <<'EOF'
# Etapa 1: descargar el binario de Typst (estático, musl)
FROM alpine:3.20 AS typst
RUN apk add --no-cache curl xz \
 && A="$(uname -m)" \
 && curl -fsSL "https://github.com/typst/typst/releases/latest/download/typst-${A}-unknown-linux-musl.tar.xz" \
    | tar -xJ -C /tmp \
 && mv /tmp/typst-*/typst /usr/local/bin/typst \
 && /usr/local/bin/typst --version

# Etapa 2: n8n con Typst incluido
FROM n8nio/n8n:latest
COPY --from=typst /usr/local/bin/typst /usr/local/bin/typst
EOF

cat > "$INSTALL_DIR/docker-compose.yml" <<'EOF'
services:
  n8n:
    build:
      context: .
      dockerfile: Dockerfile
    image: n8n-typst:local
    container_name: n8n
    restart: always
    ports:
      - "${N8N_PORT}:5678"
    environment:
      - TZ=${TZ}
      - GENERIC_TIMEZONE=${TZ}
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - WEBHOOK_URL=http://${N8N_HOST}:${N8N_PORT}/
      - N8N_SECURE_COOKIE=false
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_RUNNERS_ENABLED=true
      - N8N_DIAGNOSTICS_ENABLED=false
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      # Habilitar el nodo "Execute Command" (desactivado por defecto en versiones recientes)
      - NODES_EXCLUDE=[]
      # Carpeta permitida para los nodos de lectura/escritura de ficheros
      - N8N_RESTRICT_FILE_ACCESS_TO=/files
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./data:/home/node/.n8n
      - ./files:/files
EOF

# --------------------------------------------
# 6. Workflow: red + informe PDF con Typst (sin credenciales)
# --------------------------------------------
echo "[5/7] Creando workflow de red + PDF con Typst ..."
cat > "$INSTALL_DIR/files/workflow_red_basico.json" <<'EOF'
{
  "id": "redBasico001",
  "name": "Acceso a la red + PDF Typst",
  "active": false,
  "nodes": [
    {
      "parameters": {},
      "id": "a1b2c3d4-0001-4000-8000-000000000001",
      "name": "Ejecutar manualmente",
      "type": "n8n-nodes-base.manualTrigger",
      "typeVersion": 1,
      "position": [
        0,
        200
      ]
    },
    {
      "parameters": {
        "url": "https://api.ipify.org?format=json",
        "options": {}
      },
      "id": "a1b2c3d4-0002-4000-8000-000000000002",
      "name": "IP publica",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [
        240,
        200
      ]
    },
    {
      "parameters": {
        "url": "https://www.boe.es/rss/boe.php",
        "options": {
          "response": {
            "response": {
              "responseFormat": "file",
              "outputPropertyName": "data"
            }
          }
        }
      },
      "id": "a1b2c3d4-0003-4000-8000-000000000003",
      "name": "Sumario BOE (RSS)",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [
        480,
        200
      ]
    },
    {
      "parameters": {
        "jsCode": "const ip = $('IP publica').first().json.ip || 'desconocida';\n\n// Leer el feed como bytes y decodificarlo con su codificación real (BOE puede venir en ISO-8859-1)\nconst buf = await this.helpers.getBinaryDataBuffer(0, 'data');\nconst head = buf.subarray(0, 200).toString('latin1');\nconst m = head.match(/encoding=[\"']([^\"']+)[\"']/i);\nconst enc = ((m && m[1]) || 'utf-8').toLowerCase();\nconst isLatin = /8859-1|latin|1252/.test(enc);\nconst xml = buf.toString(isLatin ? 'latin1' : 'utf8').replace(/^﻿/, '');\n\nconst esc = (s) => String(s).replace(/\\\\/g, '\\\\\\\\').replace(/\"/g, '\\\\\"');\nconst clean = (s) => s.replace(/<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>/g, '$1').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '\"').replace(/&#39;/g, \"'\").trim();\nconst items = (xml.match(/<item[\\s\\S]*?<\\/item>/g) || []).slice(0, 15).map((it) => {\n  const t = (it.match(/<title>([\\s\\S]*?)<\\/title>/) || [])[1] || '(sin título)';\n  const l = (it.match(/<link>([\\s\\S]*?)<\\/link>/) || [])[1] || '';\n  return { title: clean(t), link: clean(l) };\n});\nconst fecha = new Date().toLocaleString('es-ES', { timeZone: 'Europe/Madrid' });\nlet typ = '';\ntyp += '#set page(paper: \"a4\", margin: 2cm)\\n';\ntyp += '#set text(size: 11pt, lang: \"es\")\\n';\ntyp += '= Informe de acceso a la red\\n\\n';\ntyp += 'Generado: #\"' + esc(fecha) + '\"\\n\\n';\ntyp += '== IP pública del servidor\\n\\n';\ntyp += '#\"' + esc(ip) + '\"\\n\\n';\ntyp += '== Sumario BOE (RSS)\\n\\n';\nif (items.length === 0) typ += '_No se encontraron elementos en el feed._\\n';\nfor (const i of items) {\n  typ += '+ #link(\"' + esc(i.link) + '\")[#\"' + esc(i.title) + '\"]\\n';\n}\nreturn [{ json: { b64: Buffer.from(typ, 'utf8').toString('base64'), items: items.length, encoding: enc } }];"
      },
      "id": "a1b2c3d4-0004-4000-8000-000000000004",
      "name": "Generar documento Typst",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [
        720,
        200
      ]
    },
    {
      "parameters": {
        "command": "=echo '{{ $json.b64 }}' | base64 -d > /files/informe_red.typ && typst compile /files/informe_red.typ /files/informe_red.pdf"
      },
      "id": "a1b2c3d4-0005-4000-8000-000000000005",
      "name": "Compilar con Typst",
      "type": "n8n-nodes-base.executeCommand",
      "typeVersion": 1,
      "position": [
        960,
        200
      ]
    },
    {
      "parameters": {
        "operation": "read",
        "fileSelector": "/files/informe_red.pdf",
        "options": {}
      },
      "id": "a1b2c3d4-0006-4000-8000-000000000006",
      "name": "Leer PDF",
      "type": "n8n-nodes-base.readWriteFile",
      "typeVersion": 1,
      "position": [
        1200,
        200
      ]
    }
  ],
  "connections": {
    "Ejecutar manualmente": {
      "main": [
        [
          {
            "node": "IP publica",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "IP publica": {
      "main": [
        [
          {
            "node": "Sumario BOE (RSS)",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Sumario BOE (RSS)": {
      "main": [
        [
          {
            "node": "Generar documento Typst",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Generar documento Typst": {
      "main": [
        [
          {
            "node": "Compilar con Typst",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Compilar con Typst": {
      "main": [
        [
          {
            "node": "Leer PDF",
            "type": "main",
            "index": 0
          }
        ]
      ]
    }
  },
  "settings": {
    "executionOrder": "v1"
  }
}
EOF

# --------------------------------------------
# 7. Construir imagen y arrancar
# --------------------------------------------
echo "[6/7] Construyendo imagen (n8n + Typst) y arrancando ..."
cd "$INSTALL_DIR"
$COMPOSE up -d --build

# --------------------------------------------
# 8. Cuenta de propietario + importar workflow
# --------------------------------------------
echo "[7/7] Creando cuenta de propietario e importando workflow ..."

echo -n "      Esperando a que n8n responda "
READY=0
for i in $(seq 1 60); do
  if curl -sf "http://localhost:$N8N_PORT/healthz" >/dev/null 2>&1; then
    READY=1
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

if [ "$READY" != "1" ]; then
  echo "AVISO: n8n no respondió a tiempo. Revisa: cd $INSTALL_DIR && $COMPOSE logs"
  echo "       Podrás crear la cuenta desde http://$IP:$N8N_PORT"
else
  json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

  PAYLOAD=$(printf '{"email":"%s","firstName":"%s","lastName":"%s","password":"%s"}' \
    "$(json_escape "$OWNER_EMAIL")" \
    "$(json_escape "$OWNER_FIRSTNAME")" \
    "$(json_escape "$OWNER_LASTNAME")" \
    "$(json_escape "$OWNER_PASSWORD")")

  HTTP_CODE=$(curl -s -o /tmp/n8n_setup.json -w '%{http_code}' \
    -X POST "http://localhost:$N8N_PORT/rest/owner/setup" \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" || true)

  if [ "$HTTP_CODE" = "200" ]; then
    echo "      Cuenta de propietario creada."
  else
    echo "AVISO: no se pudo crear la cuenta automáticamente (HTTP $HTTP_CODE)."
    echo "       Respuesta: $(cat /tmp/n8n_setup.json 2>/dev/null)"
    echo "       Si ya existía un propietario, es normal. Si no, créalo en"
    echo "       http://$IP:$N8N_PORT"
  fi
  rm -f /tmp/n8n_setup.json

  # Importar el workflow (se sobrescribe si se vuelve a ejecutar el script)
  if docker exec n8n n8n import:workflow --input=/files/workflow_red_basico.json >/dev/null 2>&1; then
    echo "      Workflow 'Acceso a la red + PDF Typst' importado."
  else
    echo "AVISO: no se pudo importar el workflow automáticamente."
    echo "       Impórtalo a mano en n8n: menú ... > Import from file >"
    echo "       $INSTALL_DIR/files/workflow_red_basico.json"
  fi
fi

echo ""
echo "============================================"
echo " n8n listo"
echo "============================================"
echo " URL:        http://$IP:$N8N_PORT"
echo " Email:      $OWNER_EMAIL"
echo " Password:   (la definida en OWNER_PASSWORD)"
echo " Carpeta:    $INSTALL_DIR"
echo " Ficheros:   $INSTALL_DIR/files  (en n8n: /files)"
echo " Workflow:   'Acceso a la red + PDF Typst' (pulsa Execute workflow)"
echo " PDF:        $INSTALL_DIR/files/informe_red.pdf"
echo " Logs:       cd $INSTALL_DIR && $COMPOSE logs -f"
echo " Parar:      cd $INSTALL_DIR && $COMPOSE down"
echo ""
echo " Guarda copia de $INSTALL_DIR/.env: sin la"
echo " clave de cifrado no podrás recuperar credenciales."
echo "============================================"