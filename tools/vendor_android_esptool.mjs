// Vendoring is a generated-asset operation. Never downloads "latest" and never
// patches the official engine; the small native shim is reviewed separately.
// node tools/vendor_android_esptool.mjs --check
// node tools/vendor_android_esptool.mjs --download
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import zlib from 'node:zlib';

const target = new URL('../android/app/src/main/assets/esptool/', import.meta.url);
const version = '0.7.0';
const tarUrl = `https://registry.npmjs.org/esptool-js/-/esptool-js-${version}.tgz`;
const integrity = '9wHuW/s9t4Vs6HKcr3pra3gbRVWwaN0eabMWodWH4KEJHEYZxgmWwZ3s0F4xcWVCZOc/L98bGZ4uWoZvR8KBKA==';
const files = {
  'bundle.js': { sha: '00ebe6fb0b202976d3e2a3c6b9a6bd438c26a81d2af6739c95ac276a64c1a84e', tar: 'package/bundle.js' },
  'LICENSE.esptool': { sha: '1c25f29242785d63e9adb0be7fdc137551dfbbc0756b622fcd26d9cd7de3a4f3', tar: 'package/LICENSE' },
  'LICENSE.pako': { sha: 'a04665b3b2de56c66730c1f720f528175739e4104f79073614aa611da1e85539', url: 'https://raw.githubusercontent.com/nodeca/pako/2.1.0/LICENSE' },
  'LICENSE.atob-lite': { sha: '435a6722c786b0a56fbe7387028f1d9d3f3a2d0fb615bb8fee118727c3f59b7b', url: 'https://raw.githubusercontent.com/hughsk/atob-lite/master/LICENSE.md' },
  'LICENSE.usb-serial': { sha: '6f467d3d79c5d31734881fb83e082e84512bde05d3f7893e0e8373fd0d2b5d2c', url: 'https://raw.githubusercontent.com/mik3y/usb-serial-for-android/8e694372dee4531d140766df7af3189d3d9531c5/LICENSE.txt' },
};
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
async function get(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error(`HTTP ${response.status} from ${url}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > 2 * 1024 * 1024) throw new Error('Unexpectedly large vendored asset');
  return bytes;
}
function tarFile(tar, wanted) {
  let found;
  for (let offset = 0; offset + 512 <= tar.length;) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every(value => value === 0)) break;
    const name = header.subarray(0, 100).toString().split('\0')[0];
    const size = parseInt(header.subarray(124, 136).toString().replace(/\0/g, '').trim(), 8);
    if (!Number.isSafeInteger(size) || size < 0 || offset + 512 + size > tar.length) throw new Error('Malformed upstream tarball');
    if (name === wanted) {
      if (found || (header[156] !== 0 && header[156] !== 48)) throw new Error('Duplicate or non-regular tar entry');
      found = tar.subarray(offset + 512, offset + 512 + size);
    }
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  if (!found) throw new Error(`Upstream tarball lacks ${wanted}`);
  return found;
}
if (process.argv.includes('--download')) {
  const archive = await get(tarUrl);
  if (crypto.createHash('sha512').update(archive).digest('base64') !== integrity) throw new Error('Pinned npm integrity mismatch');
  const tar = zlib.gunzipSync(archive, { maxOutputLength: 2 * 1024 * 1024 });
  const generated = new Map();
  for (const [name, pin] of Object.entries(files)) {
    const bytes = pin.tar ? tarFile(tar, pin.tar) : await get(pin.url);
    if (sha(bytes) !== pin.sha) throw new Error(`Pinned SHA256 mismatch: ${name}`);
    generated.set(name, bytes);
  }
  // Only replace the known generated files after every fetched hash passes.
  await fs.mkdir(target, { recursive: true });
  for (const [name, bytes] of generated) await fs.writeFile(new URL(name, target), bytes);
}
for (const [name, pin] of Object.entries(files)) {
  if (sha(await fs.readFile(new URL(name, target))) !== pin.sha) throw new Error(`Vendored asset checksum mismatch: ${name}`);
}
const provenance = JSON.parse(await fs.readFile(new URL('PROVENANCE.json', target), 'utf8'));
if (provenance.version !== version || provenance.bundle_sha256 !== files['bundle.js'].sha || provenance.npm_integrity !== `sha512-${integrity}`) {
  throw new Error('Vendored asset provenance does not match compiled pins');
}
console.log(`Verified offline esptool-js ${version} bundle and all license notices.`);
