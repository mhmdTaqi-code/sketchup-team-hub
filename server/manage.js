'use strict';
// Server-PC helper: add a teammate without opening the dashboard.
//   node manage.js add <username> [display name]   → creates the account with a random password
//   node manage.js password <username>             → sets a new random password
// Prints the login details (server address, username, password) to hand over.
// Works while the server is running (SQLite WAL allows a second writer process).

const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');

const DB = path.join(__dirname, 'data', 'hub.db');
const COLORS = ['#e6194b', '#3cb44b', '#4363d8', '#f58231', '#911eb4', '#42d4f4', '#f032e6',
  '#9a6324', '#469990', '#800000', '#808000', '#000075', '#bfef45', '#fabed4'];

function hashPassword(pw) {
  const salt = crypto.randomBytes(16).toString('hex');
  return `scrypt$${salt}$${crypto.scryptSync(pw, salt, 64).toString('hex')}`;
}

function randomPassword() {
  const abc = 'abcdefghjkmnpqrstuvwxyz23456789';
  return Array.from(crypto.randomBytes(10), (b) => abc[b % abc.length]).join('');
}

function addresses(port) {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family === 'IPv4' && !a.internal) out.push({ name, url: `http://${a.address}:${port}` });
    }
  }
  return out.sort((x, y) => (y.url.includes('//26.') ? 1 : 0) - (x.url.includes('//26.') ? 1 : 0));
}

const [cmd, username, ...rest] = process.argv.slice(2);
if (cmd === 'token' && username) {
  // Sign a member in on this PC without their password (owner of the server only).
  const db0 = new DatabaseSync(DB);
  const u = db0.prepare('SELECT id, username, display_name, role, color FROM users WHERE username = ? AND active = 1').get(username);
  if (!u) { console.error(`"${username}" مو موجود`); process.exit(2); }
  const token = crypto.randomBytes(32).toString('hex');
  db0.prepare('INSERT INTO tokens (token, user_id, client, created_at, last_seen) VALUES (?, ?, ?, ?, ?)')
    .run(token, u.id, 'sketchup', Date.now(), Date.now());
  console.log(JSON.stringify({ token, user: { ...u } }));
  process.exit(0);
}
if (!['add', 'password'].includes(cmd) || !username) {
  console.log('usage: node manage.js add <username> [display name]\n       node manage.js password <username>');
  process.exit(1);
}

const db = new DatabaseSync(DB);
db.exec('PRAGMA busy_timeout = 5000');
const existing = db.prepare('SELECT * FROM users WHERE username = ?').get(username);
const password = randomPassword();

if (cmd === 'add') {
  if (existing) {
    console.error(`"${username}" موجود من قبل. استخدم: node manage.js password ${username}`);
    process.exit(2);
  }
  if (!/^[\p{L}\p{N}_.-]{2,32}$/u.test(username)) {
    console.error('اسم المستخدم لازم 2-32 حرف، بدون فراغات');
    process.exit(2);
  }
  const n = db.prepare('SELECT COUNT(*) AS n FROM users').get().n;
  db.prepare(`INSERT INTO users (username, display_name, pass_hash, role, color, created_at)
              VALUES (?, ?, ?, 'editor', ?, ?)`)
    .run(username, rest.join(' ') || username, hashPassword(password), COLORS[n % COLORS.length], Date.now());
} else {
  if (!existing) { console.error(`"${username}" مو موجود`); process.exit(2); }
  db.prepare('UPDATE users SET pass_hash = ? WHERE id = ?').run(hashPassword(password), existing.id);
  db.prepare('DELETE FROM tokens WHERE user_id = ?').run(existing.id);
}

let port = 8787;
try { port = require('./config.json').port || port; } catch { /* default */ }
const list = addresses(port);
console.log(JSON.stringify({ username, password, servers: list }, null, 2));
