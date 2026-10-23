// Builds the source images for @capacitor/assets from icon-512.png: assets/icon-only.png (1024),
// assets/splash.png and assets/splash-dark.png (2732). The background is the colour of the icon itself
// (dark indigo), so the rounded corners of the web icon disappear. iOS needs a square icon without transparency.
import sharp from 'sharp';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = join(root, 'icon-512.png');
const out = join(root, 'assets');
mkdirSync(out, { recursive: true });

// Background colour: a pixel inside the rounded square, away from the moon.
const { data } = await sharp(src).extract({ left: 250, top: 40, width: 1, height: 1 }).raw().toBuffer({ resolveWithObject: true });
const bg = { r: data[0], g: data[1], b: data[2], alpha: 1 };
console.log('background rgb(' + bg.r + ', ' + bg.g + ', ' + bg.b + ')');

async function onBackground(size, iconSize, file) {
  const icon = await sharp(src).resize(iconSize, iconSize).toBuffer();
  const offset = Math.round((size - iconSize) / 2);
  await sharp({ create: { width: size, height: size, channels: 4, background: bg } })
    .composite([{ input: icon, left: offset, top: offset }])
    .flatten({ background: bg })
    .png()
    .toFile(join(out, file));
}
await onBackground(1024, 1024, 'icon-only.png');
await onBackground(2732, 720, 'splash.png');
await onBackground(2732, 720, 'splash-dark.png');
console.log('Wrote assets/icon-only.png, splash.png, splash-dark.png');
