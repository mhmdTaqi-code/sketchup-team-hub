'use strict';
// Packs plugin/ into su_team_hub.rbz (a zip) and publishes it to the server:
//   dist/su_team_hub.rbz            — to hand out manually
//   server/plugin/su_team_hub.rbz   — served at /download/su_team_hub.rbz
//   server/plugin/version.json      — lets installed plugins detect updates
// Usage: node tools/build-plugin.js

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const SRC = path.join(ROOT, 'plugin');

const { zip, listFiles } = require('./zip');

const loader = fs.readFileSync(path.join(SRC, 'su_team_hub.rb'), 'utf8');
const version = (loader.match(/PLUGIN_VERSION\s*=\s*'([^']+)'/) || [])[1];
if (!version) throw new Error('PLUGIN_VERSION not found in plugin/su_team_hub.rb');

const files = ['su_team_hub.rb', ...listFiles(path.join(SRC, 'su_team_hub')).map((f) => `su_team_hub/${f}`)];
const rbz = zip(files.map((name) => ({ name, data: fs.readFileSync(path.join(SRC, name)) })));

for (const dir of [path.join(ROOT, 'dist'), path.join(ROOT, 'server', 'plugin')]) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'su_team_hub.rbz'), rbz);
}
fs.writeFileSync(path.join(ROOT, 'server', 'plugin', 'version.json'), JSON.stringify({
  version, built_at: Date.now(), min_sketchup: 2022, files: files.length,
}, null, 2));
console.log(`Team Hub plugin v${version}: ${files.length} files, ${rbz.length} bytes -> dist/ and server/plugin/`);
