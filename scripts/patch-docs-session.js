import { readdir, readFile, writeFile, stat } from 'fs/promises';
import path from 'path';

async function walkHtmlFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const entryPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...await walkHtmlFiles(entryPath));
    } else if (entry.isFile() && entry.name.toLowerCase().endsWith('.html')) {
      files.push(entryPath);
    }
  }
  return files;
}

function patchContent(content) {
  const beforeGuard = "const SESSION_KEY = 'excelData';\n\nfunction urlBase(sufijo) {";
  const afterGuard = "const SESSION_KEY = 'excelData';\nconst SESSION_KEY_DOC_PREFIX = `${SESSION_KEY}:`;\n\nfunction getSessionKey() {\n  return `${SESSION_KEY_DOC_PREFIX}${location.pathname}`;\n}\n\nfunction guardarEnSesion() {\n  const key = getSessionKey();\n  sessionStorage.setItem(key, JSON.stringify(datos));\n  sessionStorage.setItem(SESSION_KEY, JSON.stringify(datos));\n}\n\nfunction urlBase(sufijo) {";

  const beforeLoad = "    if (forzarReset) {\n      // Reinicio explícito (botón \"Recargar inputs\"): descartamos la sesión\n      // y volvemos a pedir los valores de fábrica al servidor.\n      sessionStorage.removeItem(SESSION_KEY);\n    } else {\n      // Carga de página: si ya hay una sesión (edición previa), la reutilizamos\n      // en vez de pisarla. El reinicio desde /i solo ocurre la primera vez\n      // (cuando todavía no existe nada guardado en sessionStorage).\n      const sessionRaw = sessionStorage.getItem(SESSION_KEY);\n      if (sessionRaw) {\n        datos = JSON.parse(sessionRaw);\n        cargadoDeSesion = true;\n      }\n    }";
  const afterLoad = "    if (forzarReset) {\n      // Reinicio explícito (botón \"Recargar inputs\"): descartamos la sesión\n      // y volvemos a pedir los valores de fábrica al servidor.\n      sessionStorage.removeItem(getSessionKey());\n      sessionStorage.removeItem(SESSION_KEY);\n    } else {\n      // Carga de página: si ya hay una sesión (edición previa), la reutilizamos\n      // en vez de pisarla. El reinicio desde /i solo ocurre la primera vez\n      // (cuando todavía no existe nada guardado en sessionStorage).\n      const sessionRaw = sessionStorage.getItem(getSessionKey());\n      if (sessionRaw) {\n        datos = JSON.parse(sessionRaw);\n        cargadoDeSesion = true;\n        guardarEnSesion();\n      }\n    }";

  let patched = content;

  if (content.includes(beforeGuard) && content.includes(beforeLoad)) {
    patched = patched.replace(beforeGuard, afterGuard);
    patched = patched.replace(beforeLoad, afterLoad);
  }

  const duplicateAfterMostrarEstado = "function mostrarEstado(mensaje, tipo) {\n  const el = document.getElementById('estado');\n  el.textContent = mensaje;\n  el.className = tipo || '';\n}\n\nfunction guardarEnSesion() {\n  sessionStorage.setItem(SESSION_KEY, JSON.stringify(datos));\n}\n\n// ==========================================\n";
  if (patched.includes(duplicateAfterMostrarEstado)) {
    patched = patched.replace(duplicateAfterMostrarEstado, "function mostrarEstado(mensaje, tipo) {\n  const el = document.getElementById('estado');\n  el.textContent = mensaje;\n  el.className = tipo || '';\n}\n\n// ==========================================\n");
  }

  return patched;
}

export async function patchDocsHtml(rootDir) {
  const htmlFiles = await walkHtmlFiles(rootDir);
  let patchedCount = 0;
  for (const filePath of htmlFiles) {
    const raw = await readFile(filePath, 'utf8');
    const patched = patchContent(raw);
    if (patched !== raw) {
      await writeFile(filePath, patched, 'utf8');
      patchedCount += 1;
    }
  }
  return patchedCount;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const defaultRoot = path.resolve(process.cwd(), '../public/docs');
  const rootDir = process.argv[2] || defaultRoot;
  const count = await patchDocsHtml(rootDir);
  console.log(`Patched ${count} docs HTML file(s) in ${rootDir}`);
}
