import { access } from 'fs/promises';
import { fileURLToPath } from 'url';
import path from 'path';
import { patchDocsHtml } from './patch-docs-session.js';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const publicDocsDir = path.resolve(scriptDir, '../public/docs');

try {
  await access(publicDocsDir);
} catch {
  throw new Error(`No public/docs directory found at ${publicDocsDir}. Please keep your docs files in public/docs.`);
}

const patched = await patchDocsHtml(publicDocsDir);
if (patched > 0) {
  console.log(`Patched ${patched} docs HTML file(s) in ${publicDocsDir}`);
} else {
  console.log(`No docs HTML files required patching in ${publicDocsDir}`);
}
