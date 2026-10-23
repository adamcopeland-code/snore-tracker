// Copies the web files from the repo root into www/ (the Capacitor webDir).
// The root files stay the single source of truth. www/ is gitignored.
import { cpSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'www');
// sw.js is not needed in the native app (the app skips service worker registration).
const files = ['index.html', 'manifest.webmanifest', 'icon-180.png', 'icon-192.png', 'icon-512.png'];

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
for (const f of files) {
  if (!existsSync(join(root, f))) throw new Error('Missing web file: ' + f);
  cpSync(join(root, f), join(out, f));
}
console.log('Copied ' + files.length + ' files to www/');
