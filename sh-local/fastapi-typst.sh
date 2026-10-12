#!/bin/bash
set -e

# ============================================
# Setup Typst API (solo FastAPI) - pkserver
#
#   GET  /                                    ->  editor web (HTML)
#   POST /compile  { "source": "<texto typst>" }  ->  application/pdf
# ============================================

INSTALL_DIR="$HOME/Desktop/bb/typst-api"
IP="192.168.1.134"
TZ="Europe/Madrid"
API_PORT="8020"        # 8000 lo usa Portainer, 8010 la API de IA

echo "==> Creando estructura en $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/app/static
cd "$INSTALL_DIR"

# --------------------------------------------
# .env (no se sobreescribe si ya existe)
# --------------------------------------------
if [ ! -f .env ]; then
  cat > .env <<EOF
TZ=$TZ
IP=$IP
API_PORT=$API_PORT
EOF
  echo "==> .env creado"
else
  sed -i "s/^API_PORT=.*/API_PORT=$API_PORT/" .env
  echo "==> .env ya existe, se mantiene (puerto actualizado)"
fi

# --------------------------------------------
# requirements + Dockerfile + compose
# --------------------------------------------
cat > requirements.txt <<'EOF'
fastapi==0.115.*
uvicorn[standard]==0.32.*
typst>=0.13
EOF

cat > Dockerfile <<'EOF'
FROM python:3.12-slim

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Usuario sin privilegios
RUN useradd -r -u 10001 typst
USER typst

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

cat > docker-compose.yml <<'EOF'
name: typst-api

services:
  typst-api:
    build: .
    container_name: typst-api
    restart: unless-stopped
    environment:
      - TZ=${TZ}
    ports:
      - "${API_PORT}:8000"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request as u; u.urlopen('http://localhost:8000/health')"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 10s
EOF

# --------------------------------------------
# API
# --------------------------------------------
touch app/__init__.py

cat > app/main.py <<'EOF'
import asyncio
import re
import tempfile
from pathlib import Path
from typing import Literal

import typst
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, Field

MAX_SOURCE_BYTES = 1_000_000   # 1 MB de texto Typst
COMPILE_TIMEOUT = 60           # segundos
INDEX_HTML = Path(__file__).parent / "static" / "index.html"

app = FastAPI(
    title="Typst API",
    version="1.0.0",
    description="Compila texto Typst a PDF con la libreria Python `typst`.",
)


class CompileRequest(BaseModel):
    source: str = Field(..., min_length=1, description="Documento en sintaxis Typst")
    inputs: dict[str, str] = Field(
        default_factory=dict,
        description='Variables accesibles en el documento con `sys.inputs.clave`',
    )
    filename: str = Field("documento", description="Nombre del PDF devuelto (sin extension)")
    format: Literal["pdf", "png", "svg"] = "pdf"


def _compilar(source: str, inputs: dict[str, str], fmt: str):
    # Directorio temporal vacio como raiz: el documento no puede leer
    # archivos del servidor (#read, #image, #json... fuera de ese directorio).
    with tempfile.TemporaryDirectory() as root:
        return typst.compile(
            source.encode("utf-8"),
            root=root,
            format=fmt,
            sys_inputs=inputs,
        )


@app.get("/", include_in_schema=False)
async def index():
    return FileResponse(INDEX_HTML, media_type="text/html")


@app.get("/health")
async def health():
    return {"status": "ok", "typst": getattr(typst, "__version__", "unknown")}


@app.post(
    "/compile",
    responses={200: {"content": {"application/pdf": {}}}, 400: {"description": "Error de Typst"}},
)
async def compile_typst(req: CompileRequest):
    if len(req.source.encode("utf-8")) > MAX_SOURCE_BYTES:
        raise HTTPException(413, "El documento supera el tamano maximo")

    try:
        data = await asyncio.wait_for(
            asyncio.to_thread(_compilar, req.source, req.inputs, req.format),
            timeout=COMPILE_TIMEOUT,
        )
    except asyncio.TimeoutError:
        raise HTTPException(504, "Timeout compilando el documento")
    except Exception as e:  # typst lanza RuntimeError con el diagnostico
        raise HTTPException(400, f"Error de Typst: {e}")

    nombre = re.sub(r"[^A-Za-z0-9._-]+", "_", req.filename).strip("._") or "documento"
    if req.format == "pdf":
        media_type, ext = "application/pdf", "pdf"
        body = data
    elif req.format == "svg":
        media_type, ext = "image/svg+xml", "svg"
        body = data if isinstance(data, bytes) else b"".join(data)
    else:
        media_type, ext = "image/png", "png"
        body = data if isinstance(data, bytes) else data[0]

    return Response(
        content=body,
        media_type=media_type,
        headers={"Content-Disposition": f'inline; filename="{nombre}.{ext}"'},
    )
EOF

# --------------------------------------------
# Interfaz web (GET /)
# --------------------------------------------
cat > app/static/index.html <<'HTML_EOF'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Typst Editor</title>
<style>
  :root {
    --bg: #f4f5f7; --panel: #ffffff; --text: #1d2330; --muted: #5d6677;
    --border: #d9dde4; --accent: #239dad; --accent-text: #ffffff;
    --error-bg: #fdecec; --error-text: #9b1c1c; --ok: #1f7a3f;
    --editor-bg: #fbfbfc;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #14171c; --panel: #1c2027; --text: #e4e7ec; --muted: #9aa3b2;
      --border: #2e343e; --accent: #3fb6c6; --accent-text: #0d1114;
      --error-bg: #3a1d1d; --error-text: #ffb4b4; --ok: #6fd391;
      --editor-bg: #171a20;
    }
  }
  * { box-sizing: border-box; }
  [hidden] { display: none !important; }
  html, body { height: 100%; margin: 0; }
  body {
    background: var(--bg); color: var(--text);
    font: 14px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    display: flex; flex-direction: column;
  }
  header {
    display: flex; flex-wrap: wrap; align-items: center; gap: 8px;
    padding: 10px 16px; background: var(--panel); border-bottom: 1px solid var(--border);
  }
  header h1 { font-size: 16px; margin: 0 12px 0 0; }
  header .spacer { flex: 1; }
  input[type=text] {
    padding: 6px 8px; border: 1px solid var(--border); border-radius: 6px;
    background: var(--bg); color: var(--text); width: 160px;
  }
  button, .btn {
    padding: 6px 12px; border: 1px solid var(--border); border-radius: 6px;
    background: var(--panel); color: var(--text); cursor: pointer; font: inherit;
  }
  button:hover, .btn:hover { border-color: var(--accent); }
  button.primary { background: var(--accent); color: var(--accent-text); border-color: var(--accent); font-weight: 600; }
  button:disabled { opacity: .5; cursor: default; }
  main { flex: 1; display: grid; grid-template-columns: 1fr 1fr; min-height: 0; }
  .pane { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .pane + .pane { border-left: 1px solid var(--border); }
  .pane-title {
    padding: 6px 16px; font-size: 12px; color: var(--muted);
    border-bottom: 1px solid var(--border); background: var(--panel);
    display: flex; justify-content: space-between; gap: 8px;
  }
  textarea {
    flex: 1; width: 100%; resize: none; border: 0; outline: none; padding: 12px 16px;
    background: var(--editor-bg); color: var(--text); tab-size: 2;
    font: 13px/1.5 ui-monospace, "DejaVu Sans Mono", Menlo, Consolas, monospace;
  }
  iframe { flex: 1; width: 100%; border: 0; background: #888; }
  .empty { flex: 1; display: grid; place-items: center; color: var(--muted); padding: 16px; text-align: center; }
  #error {
    display: none; margin: 0; padding: 10px 16px; max-height: 35%; overflow: auto;
    background: var(--error-bg); color: var(--error-text); white-space: pre-wrap;
    font: 12px/1.4 ui-monospace, "DejaVu Sans Mono", monospace; border-top: 1px solid var(--border);
  }
  #status.ok { color: var(--ok); }
  #status.err { color: var(--error-text); }
  .drop { outline: 2px dashed var(--accent); outline-offset: -6px; }
  @media (max-width: 800px) {
    main { grid-template-columns: 1fr; grid-template-rows: 1fr 1fr; }
    .pane + .pane { border-left: 0; border-top: 1px solid var(--border); }
  }
</style>
</head>
<body>
<header>
  <h1>Typst Editor</h1>
  <label class="btn" title="Abrir un fichero .typ local">
    Subir .typ
    <input id="file" type="file" accept=".typ,.txt,text/plain" hidden>
  </label>
  <button id="saveTyp" title="Descargar el codigo fuente">Bajar .typ</button>
  <button id="example" title="Cargar el documento de ejemplo">Ejemplo</button>
  <span class="spacer"></span>
  <input id="name" type="text" value="documento" aria-label="Nombre del fichero" title="Nombre del fichero (sin extension)">
  <button id="compile" class="primary" title="Ctrl+Enter">Compilar</button>
  <button id="savePdf" disabled>Descargar PDF</button>
</header>

<main>
  <section class="pane" id="editorPane">
    <div class="pane-title"><span>Fuente Typst</span><span>Ctrl+Enter compila &middot; arrastra un .typ aqui</span></div>
    <textarea id="src" spellcheck="false" aria-label="Codigo Typst"></textarea>
    <pre id="error"></pre>
  </section>
  <section class="pane">
    <div class="pane-title"><span>Vista previa PDF</span><span id="status"></span></div>
    <div class="empty" id="placeholder"><span>Pulsa <b>Compilar</b> para ver el PDF</span></div>
    <iframe id="preview" title="Vista previa PDF" hidden></iframe>
  </section>
</main>

<script type="text/plain" id="ejemplo">#set document(title: "Documento de ejemplo")
#set page(paper: "a4", margin: 2cm, numbering: "1")
#set text(lang: "es", size: 11pt)
#set heading(numbering: "1.")
#set par(justify: true)

#align(center)[
  #text(20pt, weight: "bold")[Informe de ejemplo]
  #v(-6pt)
  #text(fill: gray)[Generado con Typst API · #datetime.today().display("[day]/[month]/[year]")]
]

= Introduccion
Esto es un documento *Typst* de ejemplo. Puedes editarlo a la izquierda y
pulsar _Compilar_ para ver el resultado. Typst admite *negrita*, _cursiva_,
`codigo en linea` y #text(fill: rgb("#239dad"))[colores].

= Listas
- Primer punto
- Segundo punto
  - Subpunto
+ Paso numerado
+ Otro paso

= Matematicas
La formula de Euler: $e^(i pi) + 1 = 0$.

$ sum_(k=1)^n k = (n(n+1)) / 2 $

= Tabla
#table(
  columns: (auto, 1fr, auto),
  align: (left, left, right),
  table.header([*Servicio*], [*Descripcion*], [*Puerto*]),
  [Jellyfin], [Multimedia], [8096],
  [n8n], [Automatizacion], [5678],
  [Typst API], [Compilacion PDF], [8020],
)

= Codigo
```python
def hola(nombre):
    return f"Hola, {nombre}"
```

#let caja(cuerpo) = block(
  fill: luma(235), inset: 10pt, radius: 4pt, width: 100%, cuerpo,
)
#caja[Las funciones propias se definen con `#let`.]
</script>

<script>
(() => {
  const $ = (id) => document.getElementById(id);
  const src = $("src"), nameInput = $("name"), status = $("status"), errorBox = $("error");
  const preview = $("preview"), placeholder = $("placeholder");
  const btnCompile = $("compile"), btnPdf = $("savePdf");
  const STORE_KEY = "typst-editor-src";
  const EXAMPLE = $("ejemplo").textContent;
  let pdfUrl = null;

  const safeName = () => (nameInput.value.trim().replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^[._]+|[._]+$/g, "") || "documento");

  function setStatus(text, cls = "") { status.textContent = text; status.className = cls; }
  function showError(msg) { errorBox.textContent = msg || ""; errorBox.style.display = msg ? "block" : "none"; }

  function download(blob, filename) {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  // Guarda el borrador en el navegador (si se puede)
  function saveDraft() { try { localStorage.setItem(STORE_KEY, src.value); } catch (e) {} }
  function loadDraft() { try { return localStorage.getItem(STORE_KEY); } catch (e) { return null; } }

  async function compile() {
    if (!src.value.trim()) { showError("El documento esta vacio."); return; }
    btnCompile.disabled = true;
    setStatus("Compilando...");
    showError("");
    const t0 = performance.now();
    try {
      const r = await fetch("compile", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ source: src.value, filename: safeName(), format: "pdf" }),
      });
      if (!r.ok) {
        let msg = "HTTP " + r.status;
        try {
          const j = await r.json();
          msg = typeof j.detail === "string" ? j.detail : JSON.stringify(j.detail, null, 2);
        } catch (e) {}
        throw new Error(msg);
      }
      const blob = await r.blob();
      if (pdfUrl) URL.revokeObjectURL(pdfUrl);
      pdfUrl = URL.createObjectURL(blob);
      preview.src = pdfUrl + "#view=FitH";
      preview.hidden = false;
      placeholder.hidden = true;
      btnPdf.disabled = false;
      setStatus(`OK · ${(blob.size / 1024).toFixed(1)} KB · ${Math.round(performance.now() - t0)} ms`, "ok");
    } catch (e) {
      showError(e.message);
      setStatus("Error", "err");
    } finally {
      btnCompile.disabled = false;
    }
  }

  function loadFile(file) {
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      src.value = reader.result;
      nameInput.value = file.name.replace(/\.[^.]+$/, "") || "documento";
      saveDraft();
      setStatus("Cargado " + file.name);
      compile();
    };
    reader.readAsText(file, "utf-8");
  }

  // Eventos
  btnCompile.onclick = compile;
  btnPdf.onclick = () => {
    if (!pdfUrl) return;
    fetch(pdfUrl).then((r) => r.blob()).then((b) => download(b, safeName() + ".pdf"));
  };
  $("saveTyp").onclick = () => download(new Blob([src.value], { type: "text/plain;charset=utf-8" }), safeName() + ".typ");
  $("file").onchange = (e) => { loadFile(e.target.files[0]); e.target.value = ""; };
  $("example").onclick = () => {
    if (src.value !== EXAMPLE && src.value.trim() && !confirm("¿Reemplazar el contenido actual por el ejemplo?")) return;
    src.value = EXAMPLE; nameInput.value = "ejemplo"; saveDraft(); compile();
  };

  src.addEventListener("input", saveDraft);
  src.addEventListener("keydown", (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); compile(); }
    else if (e.key === "Tab") {   // inserta 2 espacios en lugar de cambiar el foco
      e.preventDefault();
      const s = src.selectionStart;
      src.setRangeText("  ", s, src.selectionEnd, "end");
      saveDraft();
    }
  });

  // Arrastrar y soltar un .typ sobre el editor
  const pane = $("editorPane");
  pane.addEventListener("dragover", (e) => { e.preventDefault(); pane.classList.add("drop"); });
  pane.addEventListener("dragleave", () => pane.classList.remove("drop"));
  pane.addEventListener("drop", (e) => {
    e.preventDefault(); pane.classList.remove("drop");
    loadFile(e.dataTransfer.files[0]);
  });

  // Inicio: borrador guardado o documento de ejemplo
  const draft = loadDraft();
  src.value = draft && draft.trim() ? draft : EXAMPLE;
  if (!draft) nameInput.value = "ejemplo";
  compile();
})();
</script>
</body>
</html>
HTML_EOF

# --------------------------------------------
# Scripts de gestion
# --------------------------------------------
cat > start.sh <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
docker compose up -d --build
source .env
echo
echo "  Editor    : http://$IP:$API_PORT/"
echo "  Typst API : http://$IP:$API_PORT/compile"
echo "  Docs      : http://$IP:$API_PORT/docs"
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

cat > test.sh <<'EOF'
#!/bin/bash
# Uso: ./test.sh  ->  genera test.pdf en esta carpeta
set -e
cd "$(dirname "$0")"
source .env
curl -fsS -X POST "http://localhost:$API_PORT/compile" \
  -H "Content-Type: application/json" \
  -d '{
    "source": "#set page(paper: \"a4\")\n= Hola desde Typst\nCompilado por *FastAPI* el #datetime.today().display().\n\nVariable: #sys.inputs.at(\"nombre\", default: \"-\")",
    "inputs": {"nombre": "pkserver"},
    "filename": "test"
  }' -o test.pdf
echo "PDF generado: $(pwd)/test.pdf ($(stat -c%s test.pdf) bytes)"
EOF

chmod +x start.sh stop.sh logs.sh test.sh

cat > README.md <<EOF
# Typst API

\`POST /compile\` recibe texto Typst y devuelve el PDF compilado.

Editor web: http://$IP:$API_PORT/ (documento de ejemplo, subir/bajar \`.typ\`,
compilar y descargar el PDF).

\`\`\`bash
./start.sh     # docker compose up -d --build
./test.sh      # genera test.pdf
curl -X POST http://$IP:$API_PORT/compile \\
  -H "Content-Type: application/json" \\
  -d '{"source": "= Hola\\nTexto en *Typst*"}' -o salida.pdf
\`\`\`

Campos: \`source\` (obligatorio), \`inputs\` (variables, \`sys.inputs.clave\`),
\`filename\`, \`format\` (pdf | png | svg). Docs: http://$IP:$API_PORT/docs
EOF

echo
echo "==> Estructura creada en $INSTALL_DIR"
echo
RESP=""
if [ -t 0 ]; then
  read -r -p "¿Levantar el servicio ahora? [s/N] " RESP || RESP=""
fi
if [[ "$RESP" =~ ^[sSyY]$ ]]; then
  ./start.sh
else
  echo "Cuando quieras: cd $INSTALL_DIR && ./start.sh"
fi