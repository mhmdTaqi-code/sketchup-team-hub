'use strict';
// Team Hub server — the shared "source of truth" for a SketchUp team.
// Holds accounts, projects, the current revision of every synced object,
// the full revision history, reservations (locks) and an ordered event log
// that clients replay. Live events go out over WebSocket.

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const { DatabaseSync } = require('node:sqlite');
const { WebSocketServer } = require('ws');

const VERSION = '1.0.0';
const ROOT = __dirname;
const PUBLIC_DIR = path.join(ROOT, 'public');
const DATA_DIR = path.join(ROOT, 'data');
const BLOB_DIR = path.join(DATA_DIR, 'blobs');
const CONFIG_PATH = path.join(ROOT, 'config.json');
const PLUGIN_DIR = path.join(ROOT, 'plugin');
const PLUGIN_RBZ = path.join(PLUGIN_DIR, 'su_team_hub.rbz');

// Written by tools/build-plugin.js next to the .rbz.
function pluginInfo() {
  try {
    const meta = JSON.parse(fs.readFileSync(path.join(PLUGIN_DIR, 'version.json'), 'utf8'));
    if (!fs.existsSync(PLUGIN_RBZ)) return null;
    return { version: meta.version, size: fs.statSync(PLUGIN_RBZ).size, built_at: meta.built_at,
      min_sketchup: meta.min_sketchup, download: '/download/su_team_hub.rbz' };
  } catch {
    return null;
  }
}

const DEFAULT_CONFIG = {
  host: '0.0.0.0',
  port: 8787,
  // Reservations of a user who has been offline this long are released.
  // 0 = never release automatically.
  lockTimeoutMinutes: 30,
  maxUploadMB: 300,
};

let config = { ...DEFAULT_CONFIG };
if (fs.existsSync(CONFIG_PATH)) {
  try {
    config = { ...DEFAULT_CONFIG, ...JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')) };
  } catch (e) {
    console.error('config.json is not valid JSON, using defaults:', e.message);
  }
} else {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(DEFAULT_CONFIG, null, 2));
}

fs.mkdirSync(BLOB_DIR, { recursive: true });

// ---------------------------------------------------------------- database

const db = new DatabaseSync(path.join(DATA_DIR, 'hub.db'));
db.exec(`
  PRAGMA journal_mode = WAL;
  PRAGMA foreign_keys = ON;
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    display_name TEXT NOT NULL,
    pass_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'editor',
    color TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS tokens (
    token TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client TEXT,
    created_at INTEGER NOT NULL,
    last_seen INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS projects (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    created_by INTEGER,
    created_at INTEGER NOT NULL,
    seq INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS objects (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    oid TEXT NOT NULL,
    rev INTEGER NOT NULL,
    kind TEXT NOT NULL,
    name TEXT,
    layer TEXT,
    meta TEXT NOT NULL,
    blob TEXT,
    size INTEGER,
    deleted INTEGER NOT NULL DEFAULT 0,
    updated_by INTEGER,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (project_id, oid)
  );
  CREATE TABLE IF NOT EXISTS revisions (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL,
    oid TEXT NOT NULL,
    rev INTEGER NOT NULL,
    kind TEXT,
    name TEXT,
    layer TEXT,
    meta TEXT,
    blob TEXT,
    size INTEGER,
    deleted INTEGER NOT NULL DEFAULT 0,
    user_id INTEGER,
    note TEXT,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS revisions_obj ON revisions (project_id, oid, rev);
  CREATE TABLE IF NOT EXISTS locks (
    project_id INTEGER NOT NULL,
    oid TEXT NOT NULL,
    user_id INTEGER NOT NULL,
    acquired_at INTEGER NOT NULL,
    PRIMARY KEY (project_id, oid)
  );
  CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    type TEXT NOT NULL,
    payload TEXT NOT NULL,
    user_id INTEGER,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS events_seq ON events (project_id, seq);
  CREATE TABLE IF NOT EXISTS invites (
    code TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER
  );
`);

// Migrations: a project is either a SketchUp project (objects synced through
// this server) or a Revit project (a workshared central model; this server
// coordinates live syncs, presence and backups).
{
  const cols = new Set(db.prepare('PRAGMA table_info(projects)').all().map((c) => c.name));
  if (!cols.has('kind')) db.exec("ALTER TABLE projects ADD COLUMN kind TEXT NOT NULL DEFAULT 'sketchup'");
  if (!cols.has('central_path')) db.exec('ALTER TABLE projects ADD COLUMN central_path TEXT');
  if (!cols.has('revit_version')) db.exec('ALTER TABLE projects ADD COLUMN revit_version TEXT');
}

function tx(fn) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const out = fn();
    db.exec('COMMIT');
    return out;
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
}

const q = {
  userCount: db.prepare('SELECT COUNT(*) AS n FROM users'),
  userById: db.prepare('SELECT * FROM users WHERE id = ?'),
  userByName: db.prepare('SELECT * FROM users WHERE username = ?'),
  users: db.prepare('SELECT id, username, display_name, role, color, active, created_at FROM users ORDER BY id'),
  insertUser: db.prepare(`INSERT INTO users (username, display_name, pass_hash, role, color, created_at)
                          VALUES (?, ?, ?, ?, ?, ?)`),
  tokenGet: db.prepare(`SELECT t.token, t.last_seen, u.* FROM tokens t JOIN users u ON u.id = t.user_id
                        WHERE t.token = ? AND u.active = 1`),
  tokenInsert: db.prepare('INSERT INTO tokens (token, user_id, client, created_at, last_seen) VALUES (?, ?, ?, ?, ?)'),
  tokenTouch: db.prepare('UPDATE tokens SET last_seen = ? WHERE token = ?'),
  tokenDelete: db.prepare('DELETE FROM tokens WHERE token = ?'),
  tokensDeleteUser: db.prepare('DELETE FROM tokens WHERE user_id = ?'),
  projects: db.prepare(`SELECT p.*, (SELECT COUNT(*) FROM objects o WHERE o.project_id = p.id AND o.deleted = 0) AS objects
                        FROM projects p WHERE p.archived = 0 OR ? ORDER BY p.id`),
  project: db.prepare('SELECT * FROM projects WHERE id = ?'),
  insertProject: db.prepare('INSERT INTO projects (name, created_by, created_at) VALUES (?, ?, ?)'),
  bumpSeq: db.prepare('UPDATE projects SET seq = seq + 1 WHERE id = ? RETURNING seq'),
  insertEvent: db.prepare(`INSERT INTO events (project_id, seq, type, payload, user_id, created_at)
                           VALUES (?, ?, ?, ?, ?, ?)`),
  eventsSince: db.prepare(`SELECT seq, type, payload, user_id, created_at FROM events
                           WHERE project_id = ? AND seq > ? ORDER BY seq LIMIT ?`),
  eventsRecent: db.prepare(`SELECT seq, type, payload, user_id, created_at FROM events
                            WHERE project_id = ? ORDER BY seq DESC LIMIT ?`),
  object: db.prepare('SELECT * FROM objects WHERE project_id = ? AND oid = ?'),
  objects: db.prepare('SELECT * FROM objects WHERE project_id = ? ORDER BY name, oid'),
  upsertObject: db.prepare(`INSERT INTO objects (project_id, oid, rev, kind, name, layer, meta, blob, size, deleted, updated_by, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT (project_id, oid) DO UPDATE SET rev = excluded.rev, kind = excluded.kind,
                              name = excluded.name, layer = excluded.layer, meta = excluded.meta, blob = excluded.blob,
                              size = excluded.size, deleted = excluded.deleted, updated_by = excluded.updated_by,
                              updated_at = excluded.updated_at`),
  insertRevision: db.prepare(`INSERT INTO revisions (project_id, oid, rev, kind, name, layer, meta, blob, size, deleted, user_id, note, created_at)
                              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`),
  history: db.prepare(`SELECT r.rev, r.kind, r.name, r.layer, r.blob, r.size, r.deleted, r.note, r.created_at,
                              r.user_id, u.display_name AS user_name
                       FROM revisions r LEFT JOIN users u ON u.id = r.user_id
                       WHERE r.project_id = ? AND r.oid = ? ORDER BY r.rev DESC`),
  revision: db.prepare('SELECT * FROM revisions WHERE project_id = ? AND oid = ? AND rev = ?'),
  lock: db.prepare('SELECT * FROM locks WHERE project_id = ? AND oid = ?'),
  locks: db.prepare('SELECT oid, user_id, acquired_at FROM locks WHERE project_id = ?'),
  allLocks: db.prepare('SELECT project_id, oid, user_id, acquired_at FROM locks'),
  insertLock: db.prepare('INSERT INTO locks (project_id, oid, user_id, acquired_at) VALUES (?, ?, ?, ?)'),
  deleteLock: db.prepare('DELETE FROM locks WHERE project_id = ? AND oid = ?'),
  locksOfUser: db.prepare('SELECT project_id, oid FROM locks WHERE user_id = ?'),
};

const COLORS = ['#e6194b', '#3cb44b', '#4363d8', '#f58231', '#911eb4', '#42d4f4', '#f032e6',
  '#9a6324', '#469990', '#800000', '#808000', '#000075', '#bfef45', '#fabed4'];

const now = () => Date.now();

// ---------------------------------------------------------------- auth

function hashPassword(pw) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(pw, salt, 64).toString('hex');
  return `scrypt$${salt}$${hash}`;
}

function checkPassword(pw, stored) {
  const [, salt, hash] = String(stored).split('$');
  if (!salt || !hash) return false;
  const test = crypto.scryptSync(pw, salt, 64);
  const ref = Buffer.from(hash, 'hex');
  return ref.length === test.length && crypto.timingSafeEqual(ref, test);
}

function publicUser(u) {
  if (!u) return null;
  return { id: u.id, username: u.username, display_name: u.display_name, role: u.role, color: u.color };
}

function createUser({ username, display_name, password, role }) {
  username = String(username || '').trim();
  if (!/^[\p{L}\p{N}_.-]{2,32}$/u.test(username)) throw httpError(400, 'invalid_username');
  if (!password || String(password).length < 6) throw httpError(400, 'password_too_short');
  if (!['admin', 'editor', 'viewer'].includes(role)) role = 'editor';
  if (q.userByName.get(username)) throw httpError(409, 'username_taken');
  const n = q.userCount.get().n;
  const r = q.insertUser.run(username, String(display_name || username).trim() || username,
    hashPassword(String(password)), role, COLORS[n % COLORS.length], now());
  return q.userById.get(Number(r.lastInsertRowid));
}

// Plugins older than this may not write (mixed versions corrupt the model).
const MIN_WRITER_PLUGIN = '2.0.0';

function versionLess(a, b) {
  const pa = String(a || '0').split('.').map(Number);
  const pb = String(b || '0').split('.').map(Number);
  for (let i = 0; i < 3; i++) { if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) < (pb[i] || 0); }
  return false;
}

function requireCurrentPlugin(ctx) {
  const v = ctx.req.headers['x-teamhub-plugin'];
  if (versionLess(v, MIN_WRITER_PLUGIN)) {
    throw httpError(426, 'update_required', { min: MIN_WRITER_PLUGIN, message: 'حدّث بلكن Team Hub من لوحة الفريق (زر تحديث) وأعد فتح SketchUp' });
  }
}

function authenticate(req, url) {
  let token = null;
  const h = req.headers['authorization'];
  if (h && h.startsWith('Bearer ')) token = h.slice(7).trim();
  if (!token && url) token = url.searchParams.get('token');
  if (!token) return null;
  const row = q.tokenGet.get(token);
  if (!row) return null;
  const t = now();
  if (t - row.last_seen > 60_000) q.tokenTouch.run(t, token);
  return row;
}

// ---------------------------------------------------------------- http helpers

function httpError(status, code, extra) {
  const e = new Error(code);
  e.status = status;
  e.code = code;
  e.extra = extra;
  return e;
}

function send(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': data.length,
    'Cache-Control': 'no-store',
  });
  res.end(data);
}

function readBody(req, limitBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limitBytes) {
        reject(httpError(413, 'payload_too_large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function readJson(req) {
  const buf = await readBody(req, config.maxUploadMB * 1024 * 1024);
  if (!buf.length) return {};
  try {
    return JSON.parse(buf.toString('utf8'));
  } catch {
    throw httpError(400, 'invalid_json');
  }
}

function isLocalRequest(req) {
  const a = req.socket.remoteAddress || '';
  return a === '127.0.0.1' || a === '::1' || a === '::ffff:127.0.0.1';
}

function requireRole(user, ...roles) {
  if (!user) throw httpError(401, 'unauthorized');
  if (!roles.includes(user.role)) throw httpError(403, 'forbidden');
}

function getProject(pid) {
  const p = q.project.get(Number(pid));
  if (!p) throw httpError(404, 'project_not_found');
  return p;
}

function serverAddresses() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family === 'IPv4' && !a.internal) out.push({ iface: name, address: a.address });
    }
  }
  return out;
}

// ---------------------------------------------------------------- blobs

function blobPath(sha) {
  if (!/^[a-f0-9]{64}$/.test(sha)) throw httpError(400, 'invalid_blob');
  return path.join(BLOB_DIR, sha.slice(0, 2), `${sha}.skp`);
}

function storeBlob(buf) {
  const sha = crypto.createHash('sha256').update(buf).digest('hex');
  const p = blobPath(sha);
  if (!fs.existsSync(p)) {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    const tmp = `${p}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, buf);
    fs.renameSync(tmp, p);
  }
  return sha;
}

// ---------------------------------------------------------------- live clients / events

// ws -> { user, pid, client, status, alive }
const clients = new Map();
// SketchUp clients poll /events instead of holding a socket.
// `${pid}:${uid}:${client}` -> { user, pid, client, status, at }
const pollers = new Map();
const POLL_ONLINE_MS = 12_000;
// `${pid}:${uid}` -> timestamp the user's last connection to that project closed
const offlineSince = new Map();
const serverStartedAt = now();

function userBrief(userId) {
  return publicUser(q.userById.get(userId));
}

function broadcast(pid, msg) {
  const data = JSON.stringify(msg);
  for (const [ws, c] of clients) {
    if (c.pid === pid && ws.readyState === 1) ws.send(data);
  }
}

// Persisted, ordered event. Clients replay these by seq after reconnecting.
// Long-poll waiters: SketchUp clients park a request until something happens.
const waiters = new Map(); // pid -> Set<() => void>

function wakeWaiters(pid) {
  const set = waiters.get(pid);
  if (!set || !set.size) return;
  waiters.delete(pid);
  for (const fn of set) fn();
}

function waitForEvent(pid, ms) {
  return new Promise((resolve) => {
    let set = waiters.get(pid);
    if (!set) { set = new Set(); waiters.set(pid, set); }
    const done = () => { clearTimeout(timer); set.delete(done); resolve(); };
    const timer = setTimeout(done, ms);
    set.add(done);
  });
}

function emit(pid, type, payload, userId) {
  const seq = q.bumpSeq.get(pid).seq;
  const at = now();
  q.insertEvent.run(pid, seq, type, JSON.stringify(payload), userId ?? null, at);
  const msg = { type, seq, payload, user: userId ? userBrief(userId) : null, at };
  // Broadcast after the surrounding transaction has committed.
  setImmediate(() => { broadcast(pid, msg); wakeWaiters(pid); });
  return seq;
}

function liveConnections(pid) {
  const t = now();
  const out = [];
  for (const c of clients.values()) if (c.pid === pid) out.push(c);
  for (const p of pollers.values()) if (p.pid === pid && (t - p.at < POLL_ONLINE_MS || p.pending > 0)) out.push(p);
  return out;
}

function onlineList(pid) {
  const byUser = new Map();
  for (const c of liveConnections(pid)) {
    const cur = byUser.get(c.user.id) || { ...publicUser(c.user), clients: [], status: null, apps: [] };
    cur.clients.push(c.client);
    if (c.status) cur.status = c.status;
    // e.g. { su: "SketchUp 2025", plugin: "1.1.0" } — shown next to the member.
    if (c.app) cur.apps.push(c.app);
    if (c.app && Number.isFinite(c.app.ping)) cur.ping = c.app.ping;
    byUser.set(c.user.id, cur);
  }
  return [...byUser.values()];
}

function broadcastPresence(pid) {
  broadcast(pid, { type: 'presence', online: onlineList(pid), at: now() });
}

function isOnline(pid, uid) {
  return liveConnections(pid).some((c) => c.user.id === uid);
}

function touchPoller(pid, user, client, statusText, app) {
  const key = `${pid}:${user.id}:${client}`;
  const prev = pollers.get(key);
  const status = statusText ? { text: String(statusText).slice(0, 120), oid: null } : null;
  const fresh = !prev || now() - prev.at >= POLL_ONLINE_MS;
  const changed = fresh || (prev.status?.text || null) !== (status?.text || null) || prev.app?.su !== app?.su ||
    Math.abs((prev.app?.ping ?? 0) - (app?.ping ?? 0)) > 40;
  pollers.set(key, { user, pid, client, status, app: app || prev?.app || null, at: now(), pending: prev?.pending || 0 });
  offlineSince.delete(`${pid}:${user.id}`);
  if (changed) broadcastPresence(pid);
}

// Pollers that stopped polling drop out of presence.
setInterval(() => {
  const t = now();
  for (const [key, p] of pollers) {
    if (t - p.at < POLL_ONLINE_MS || p.pending > 0) continue; // parked long-poll = still online
    pollers.delete(key);
    if (!isOnline(p.pid, p.user.id)) offlineSince.set(`${p.pid}:${p.user.id}`, p.at);
    broadcastPresence(p.pid);
  }
}, 5_000).unref();

// ---------------------------------------------------------------- object/lock logic

function serializeObject(o) {
  let meta = {};
  try { meta = JSON.parse(o.meta || '{}'); } catch { /* keep {} */ }
  return {
    oid: o.oid, rev: o.rev, kind: o.kind, name: o.name, layer: o.layer, meta,
    blob: o.blob, size: o.size, deleted: !!o.deleted, updated_by: o.updated_by, updated_at: o.updated_at,
  };
}

function acquireLocks(pid, user, oids) {
  const granted = [];
  const denied = [];
  tx(() => {
    const fresh = [];
    for (const oid of oids) {
      const l = q.lock.get(pid, oid);
      if (!l) {
        q.insertLock.run(pid, oid, user.id, now());
        granted.push(oid);
        fresh.push(oid);
      } else if (l.user_id === user.id) {
        granted.push(oid);
      } else {
        denied.push({ oid, user: userBrief(l.user_id) });
      }
    }
    if (fresh.length) emit(pid, 'lock', { oids: fresh, user_id: user.id }, user.id);
  });
  return { granted, denied };
}

function releaseLocks(pid, user, oids, { force = false, reason = 'release' } = {}) {
  const released = [];
  const denied = [];
  tx(() => {
    for (const oid of oids) {
      const l = q.lock.get(pid, oid);
      if (!l) continue;
      if (l.user_id === user.id || (force && user.role === 'admin')) {
        q.deleteLock.run(pid, oid);
        released.push(oid);
      } else {
        denied.push({ oid, user: userBrief(l.user_id) });
      }
    }
    if (released.length) emit(pid, 'unlock', { oids: released, reason }, user.id);
  });
  return { released, denied };
}

// ---------------------------------------------------------------- live edit claims
//
// While someone is working on an object it is "claimed" by them for a few
// seconds (renewed while they keep working). Everyone else sees it as
// "being edited by X" and can't change it meanwhile, so nobody's work is
// overwritten. Claims expire by themselves if a client disappears.

const CLAIM_MS = 15_000;
const claims = new Map(); // `${pid}:${oid}` -> { user_id, until }

function claimOf(pid, oid) {
  const c = claims.get(`${pid}:${oid}`);
  if (!c) return null;
  if (c.until < now()) { claims.delete(`${pid}:${oid}`); return null; }
  return c;
}

function claimList(pid) {
  const out = [];
  const t = now();
  for (const [key, c] of claims) {
    const [p, oid] = [Number(key.slice(0, key.indexOf(':'))), key.slice(key.indexOf(':') + 1)];
    if (p === pid && c.until >= t) out.push({ oid, user_id: c.user_id, until: c.until });
  }
  return out;
}

setInterval(() => {
  const t = now();
  const expired = new Map();
  for (const [key, c] of claims) {
    if (c.until >= t) continue;
    claims.delete(key);
    const pid = Number(key.slice(0, key.indexOf(':')));
    if (!expired.has(pid)) expired.set(pid, []);
    expired.get(pid).push(key.slice(key.indexOf(':') + 1));
  }
  for (const [pid, oids] of expired) tx(() => emit(pid, 'unclaim', { oids, reason: 'expired' }, null));
}, 3_000).unref();

function writeObject(pid, user, oid, body) {
  if (!/^[A-Za-z0-9_-]{6,64}$/.test(oid)) throw httpError(400, 'invalid_oid');
  return tx(() => {
    const obj = q.object.get(pid, oid);
    const lock = q.lock.get(pid, oid);
    const live = obj && !obj.deleted;
    // One editor at a time per object: a reservation, or someone currently
    // working on it (live claim), blocks everyone else.
    if (lock && lock.user_id !== user.id) {
      throw httpError(423, 'locked_by_other', { user: userBrief(lock.user_id) });
    }
    const claim = claimOf(pid, oid);
    if (claim && claim.user_id !== user.id) {
      throw httpError(423, 'being_edited', { user: userBrief(claim.user_id) });
    }
    // Never overwrite a newer version someone else saved: the client takes theirs.
    if (live && body.base_rev != null && Number(body.base_rev) < obj.rev && obj.updated_by !== user.id) {
      throw httpError(409, 'conflict', { rev: obj.rev, user: userBrief(obj.updated_by) });
    }
    let blob = obj ? obj.blob : null;
    let size = obj ? obj.size : null;
    if (typeof body.data === 'string' && body.data.length) {
      const buf = Buffer.from(body.data, 'base64');
      if (!buf.length) throw httpError(400, 'empty_data');
      blob = storeBlob(buf);
      size = buf.length;
    }
    // group: blob = its contents. definition: blob = a component definition.
    // component: an instance placed at top level; no blob, meta.def names the definition object.
    // loose: all the loose edges/faces at the top level of the model, as one piece.
    const kind = ['group', 'component', 'definition', 'loose'].includes(body.kind) ? body.kind : 'group';
    if (kind === 'component') { blob = null; size = null; }
    else if (!blob) throw httpError(400, 'data_required');
    const name = String(body.name ?? '').slice(0, 200);
    const layer = String(body.layer ?? '').slice(0, 200);
    const meta = JSON.stringify(body.meta || {});
    const rev = (obj ? obj.rev : 0) + 1;
    const t = now();
    q.upsertObject.run(pid, oid, rev, kind, name, layer, meta, blob, size, 0, user.id, t);
    q.insertRevision.run(pid, oid, rev, kind, name, layer, meta, blob, size, 0, user.id,
      body.note ? String(body.note).slice(0, 500) : null, t);
    const out = serializeObject(q.object.get(pid, oid));
    emit(pid, 'object', out, user.id);
    return out;
  });
}

function deleteObject(pid, user, oid, baseRev) {
  return tx(() => {
    let obj = q.object.get(pid, oid);
    if (obj && obj.deleted) return { ok: true, already: true };
    const lock = q.lock.get(pid, oid);
    if (lock && lock.user_id !== user.id) {
      throw httpError(423, 'locked_by_other', { user: userBrief(lock.user_id) });
    }
    const claim = claimOf(pid, oid);
    if (claim && claim.user_id !== user.id) {
      throw httpError(423, 'being_edited', { user: userBrief(claim.user_id) });
    }
    if (!obj) {
      // Never changed since the shared file was handed out: record the deletion
      // so everyone who opened that file removes it too.
      if (!/^[A-Za-z0-9_-]{6,64}$/.test(oid)) throw httpError(400, 'invalid_oid');
      obj = { rev: 0, kind: 'group', name: '', layer: '', meta: '{}', blob: null, size: null };
    }
    const rev = obj.rev + 1;
    const t = now();
    q.upsertObject.run(pid, oid, rev, obj.kind, obj.name, obj.layer, obj.meta, obj.blob, obj.size, 1, user.id, t);
    q.insertRevision.run(pid, oid, rev, obj.kind, obj.name, obj.layer, obj.meta, obj.blob, obj.size, 1, user.id, 'deleted', t);
    if (lock) {
      q.deleteLock.run(pid, oid);
      emit(pid, 'unlock', { oids: [oid], reason: 'deleted' }, user.id);
    }
    const out = serializeObject(q.object.get(pid, oid));
    emit(pid, 'object', out, user.id);
    return out;
  });
}

function revertObject(pid, user, oid, toRev, force) {
  return tx(() => {
    const obj = q.object.get(pid, oid);
    const r = q.revision.get(pid, oid, Number(toRev));
    if (!obj || !r) throw httpError(404, 'revision_not_found');
    const lock = q.lock.get(pid, oid);
    if (lock && lock.user_id !== user.id) {
      if (!force) throw httpError(423, 'locked_by_other', { user: userBrief(lock.user_id) });
      q.deleteLock.run(pid, oid);
      emit(pid, 'unlock', { oids: [oid], reason: 'revert' }, user.id);
    }
    const rev = obj.rev + 1;
    const t = now();
    q.upsertObject.run(pid, oid, rev, r.kind, r.name, r.layer, r.meta, r.blob, r.size, r.deleted, user.id, t);
    q.insertRevision.run(pid, oid, rev, r.kind, r.name, r.layer, r.meta, r.blob, r.size, r.deleted, user.id,
      `revert to r${r.rev}`, t);
    const out = serializeObject(q.object.get(pid, oid));
    emit(pid, 'object', out, user.id);
    return out;
  });
}

// Reservations of users who stayed offline too long are released, so one
// absent teammate cannot block everyone.
setInterval(() => {
  const mins = Number(config.lockTimeoutMinutes) || 0;
  if (mins <= 0) return;
  const limit = mins * 60_000;
  const t = now();
  const stale = new Map();
  for (const l of q.allLocks.all()) {
    if (isOnline(l.project_id, l.user_id)) continue;
    const since = offlineSince.get(`${l.project_id}:${l.user_id}`) ?? Math.max(serverStartedAt, l.acquired_at);
    if (t - since < limit) continue;
    const key = `${l.project_id}:${l.user_id}`;
    if (!stale.has(key)) stale.set(key, { pid: l.project_id, uid: l.user_id, oids: [] });
    stale.get(key).oids.push(l.oid);
  }
  for (const s of stale.values()) {
    const u = q.userById.get(s.uid);
    if (!u) continue;
    releaseLocks(s.pid, u, s.oids, { reason: 'timeout' });
    console.log(`released ${s.oids.length} stale reservation(s) of ${u.username} in project ${s.pid}`);
  }
}, 60_000).unref();

// ---------------------------------------------------------------- routes

const routes = [];
function route(method, pattern, handler) {
  const keys = [];
  const re = new RegExp('^' + pattern.replace(/:(\w+)/g, (_, k) => { keys.push(k); return '([^/]+)'; }) + '$');
  routes.push({ method, re, keys, handler });
}

route('GET', '/api/info', (ctx) => ({
  name: 'SketchUp Team Hub', version: VERSION, needs_setup: q.userCount.get().n === 0,
  port: config.port, addresses: serverAddresses(), lock_timeout_minutes: config.lockTimeoutMinutes,
  plugin: pluginInfo(),
  revit_plugin: revitPluginInfo(),
}));

function revitPluginInfo() {
  try {
    const meta = JSON.parse(fs.readFileSync(path.join(PLUGIN_DIR, 'revit-version.json'), 'utf8'));
    const file = path.join(PLUGIN_DIR, 'teamhub_revit.zip');
    if (!fs.existsSync(file)) return null;
    return { ...meta, size: fs.statSync(file).size, download: '/download/teamhub_revit.zip' };
  } catch {
    return null;
  }
}

// The SketchUp plugin is hosted here so every member installs/updates the
// same version, whatever SketchUp version they run.
route('GET', '/api/plugin', (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const info = pluginInfo();
  if (!info) throw httpError(404, 'plugin_not_found');
  return { ...info, data: fs.readFileSync(PLUGIN_RBZ).toString('base64') };
});

route('POST', '/api/setup', async (ctx) => {
  if (q.userCount.get().n > 0) throw httpError(409, 'already_setup');
  if (!isLocalRequest(ctx.req)) throw httpError(403, 'setup_only_from_server_machine');
  const b = await readJson(ctx.req);
  const user = createUser({ ...b, role: 'admin' });
  if (!q.projects.all(1).length) q.insertProject.run(String(b.project || 'المشروع الأول'), user.id, now());
  return { user: publicUser(user) };
});

route('POST', '/api/login', async (ctx) => {
  const b = await readJson(ctx.req);
  const u = q.userByName.get(String(b.username || '').trim());
  if (!u || !u.active || !checkPassword(String(b.password || ''), u.pass_hash)) {
    throw httpError(401, 'bad_credentials');
  }
  const token = crypto.randomBytes(32).toString('hex');
  q.tokenInsert.run(token, u.id, String(b.client || 'web').slice(0, 40), now(), now());
  return { token, user: publicUser(u) };
});

route('POST', '/api/logout', (ctx) => {
  if (ctx.user) q.tokenDelete.run(ctx.user.token);
  return { ok: true };
});

route('GET', '/api/me', (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  return { user: publicUser(ctx.user) };
});

route('PATCH', '/api/me', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const b = await readJson(ctx.req);
  if (b.password) {
    if (!checkPassword(String(b.old_password || ''), ctx.user.pass_hash)) throw httpError(403, 'bad_credentials');
    if (String(b.password).length < 6) throw httpError(400, 'password_too_short');
    db.prepare('UPDATE users SET pass_hash = ? WHERE id = ?').run(hashPassword(String(b.password)), ctx.user.id);
  }
  if (b.display_name) db.prepare('UPDATE users SET display_name = ? WHERE id = ?').run(String(b.display_name).slice(0, 60), ctx.user.id);
  return { user: publicUser(q.userById.get(ctx.user.id)) };
});

route('GET', '/api/users', (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const rows = q.users.all();
  return { users: ctx.user.role === 'admin' ? rows : rows.filter((u) => u.active).map(publicUser) };
});

route('POST', '/api/users', async (ctx) => {
  requireRole(ctx.user, 'admin');
  const b = await readJson(ctx.req);
  return { user: publicUser(createUser(b)) };
});

route('PATCH', '/api/users/:id', async (ctx) => {
  requireRole(ctx.user, 'admin');
  const id = Number(ctx.params.id);
  const u = q.userById.get(id);
  if (!u) throw httpError(404, 'user_not_found');
  const b = await readJson(ctx.req);
  if (b.display_name != null) db.prepare('UPDATE users SET display_name = ? WHERE id = ?').run(String(b.display_name).slice(0, 60), id);
  if (b.role && ['admin', 'editor', 'viewer'].includes(b.role)) {
    if (id === ctx.user.id && b.role !== 'admin') throw httpError(400, 'cannot_demote_self');
    db.prepare('UPDATE users SET role = ? WHERE id = ?').run(b.role, id);
  }
  if (b.password) {
    if (String(b.password).length < 6) throw httpError(400, 'password_too_short');
    db.prepare('UPDATE users SET pass_hash = ? WHERE id = ?').run(hashPassword(String(b.password)), id);
    q.tokensDeleteUser.run(id);
  }
  if (b.active != null) {
    if (id === ctx.user.id) throw httpError(400, 'cannot_disable_self');
    db.prepare('UPDATE users SET active = ? WHERE id = ?').run(b.active ? 1 : 0, id);
    if (!b.active) {
      q.tokensDeleteUser.run(id);
      const byProject = new Map();
      for (const l of q.locksOfUser.all(id)) {
        if (!byProject.has(l.project_id)) byProject.set(l.project_id, []);
        byProject.get(l.project_id).push(l.oid);
      }
      for (const [pid, oids] of byProject) releaseLocks(pid, ctx.user, oids, { force: true, reason: 'user_disabled' });
      for (const [ws, c] of clients) if (c.user.id === id) ws.close(4001, 'disabled');
    }
  }
  return { user: q.users.all().find((x) => x.id === id) };
});

route('GET', '/api/projects', (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const all = ctx.url.searchParams.get('all') === '1' && ctx.user.role === 'admin';
  return { projects: q.projects.all(all ? 1 : 0).map((p) => ({ ...p, online: onlineList(p.id).length, file: sharedFileInfo(p) })) };
});

route('POST', '/api/projects', async (ctx) => {
  // Any member can share a file, which creates a project for it.
  requireRole(ctx.user, 'admin', 'editor');
  const b = await readJson(ctx.req);
  const name = String(b.name || '').trim();
  if (!name) throw httpError(400, 'name_required');
  const r = q.insertProject.run(name.slice(0, 120), ctx.user.id, now());
  const id = Number(r.lastInsertRowid);
  if (b.kind === 'revit') {
    const central = String(b.central_path || '').trim();
    const version = String(b.revit_version || '').trim();
    if (!central || !/^20\d\d$/.test(version)) throw httpError(400, 'central_path_and_revit_version_required');
    db.prepare("UPDATE projects SET kind = 'revit', central_path = ?, revit_version = ? WHERE id = ?")
      .run(central.slice(0, 400), version, id);
  }
  return { project: q.project.get(id) };
});

route('PATCH', '/api/projects/:pid', async (ctx) => {
  requireRole(ctx.user, 'admin');
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  if (b.name) db.prepare('UPDATE projects SET name = ? WHERE id = ?').run(String(b.name).slice(0, 120), p.id);
  if (b.archived != null) db.prepare('UPDATE projects SET archived = ? WHERE id = ?').run(b.archived ? 1 : 0, p.id);
  return { project: q.project.get(p.id) };
});

route('GET', '/api/ping', () => ({ t: now() }));

// "Send log" button in the plugin: the last part of its sync log, kept per user.
route('POST', '/api/logs', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const b = await readJson(ctx.req);
  const dir = path.join(DATA_DIR, 'logs');
  fs.mkdirSync(dir, { recursive: true });
  const name = `${ctx.user.username}_${new Date().toISOString().replace(/[:.]/g, '-')}.log`;
  fs.writeFileSync(path.join(dir, name), String(b.text || '').slice(-2_000_000));
  return { ok: true, file: name };
});

route('POST', '/api/projects/:pid/delta', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor');
  requireCurrentPlugin(ctx);
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  const target = String(b.ctx || '');
  if (!/^[A-Za-z0-9_-]{4,64}$/.test(target)) throw httpError(400, 'invalid_ctx');
  const lock = q.lock.get(p.id, target);
  if (lock && lock.user_id !== ctx.user.id) throw httpError(423, 'locked_by_other', { user: userBrief(lock.user_id) });
  return applyDelta(p.id, ctx.user, b);
});

// Shared by the HTTP route and the WebSocket "delta" message.
function applyDelta(pid, user, b) {
  if (!['admin', 'editor'].includes(user.role)) throw httpError(403, 'forbidden');
  const target = String(b.ctx || '');
  if (!/^[A-Za-z0-9_-]{4,64}$/.test(target)) throw httpError(400, 'invalid_ctx');
  const lock = q.lock.get(pid, target);
  if (lock && lock.user_id !== user.id) throw httpError(423, 'locked_by_other', { user: userBrief(lock.user_id) });
  const rm = Array.isArray(b.rm) ? b.rm.slice(0, 20000).map(String) : [];
  const add = Array.isArray(b.add) ? b.add.slice(0, 20000) : [];
  if (!rm.length && !add.length) return { ok: true, empty: true };
  const seq = tx(() => emit(pid, 'delta', { ctx: target, rm, add, by: user.id, n: Number(b.n) || 0 }, user.id));
  return { ok: true, seq };
}

// Claim objects I'm working on (and release the ones I'm done with).
route('POST', '/api/projects/:pid/claim', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor');
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  const oids = (Array.isArray(b.oids) ? b.oids : []).map(String).slice(0, 200);
  const release = (Array.isArray(b.release) ? b.release : []).map(String).slice(0, 2000);
  const granted = [];
  const denied = [];
  const fresh = [];
  const t = now();
  for (const oid of oids) {
    const lock = q.lock.get(p.id, oid);
    const c = claimOf(p.id, oid);
    // A reservation or someone else already working on it blocks the claim.
    const blocker = (lock && lock.user_id !== ctx.user.id) ? lock.user_id : (c && c.user_id !== ctx.user.id) ? c.user_id : null;
    if (blocker) { denied.push({ oid, user: userBrief(blocker) }); continue; }
    if (!c || c.user_id !== ctx.user.id) fresh.push(oid);
    claims.set(`${p.id}:${oid}`, { user_id: ctx.user.id, until: t + CLAIM_MS });
    granted.push(oid);
  }
  const released = [];
  for (const oid of release) {
    const c = claimOf(p.id, oid);
    if (c && c.user_id === ctx.user.id) { claims.delete(`${p.id}:${oid}`); released.push(oid); }
  }
  if (fresh.length || released.length) {
    tx(() => {
      if (fresh.length) emit(p.id, 'claim', { oids: fresh, user_id: ctx.user.id }, ctx.user.id);
      if (released.length) emit(p.id, 'unclaim', { oids: released, reason: 'done' }, ctx.user.id);
    });
  }
  return { granted, denied, released, ttl_ms: CLAIM_MS };
});

// Status + ping without waiting for the long-poll to return.
route('POST', '/api/projects/:pid/presence', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  const client = String(b.client || 'sketchup').slice(0, 20);
  const app = { su: String(b.su || '').slice(0, 40), plugin: String(b.plugin || '').slice(0, 20),
    ping: b.ping != null ? Number(b.ping) : undefined };
  touchPoller(p.id, ctx.user, client, b.status || null, app);
  return { ok: true, online: onlineList(p.id) };
});

route('GET', '/api/projects/:pid/state', (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const p = getProject(ctx.params.pid);
  return {
    project: { id: p.id, name: p.name },
    seq: p.seq,
    objects: q.objects.all(p.id).map(serializeObject),
    claims: claimList(p.id),
    locks: q.locks.all(p.id),
    online: onlineList(p.id),
    users: q.users.all().map(publicUser),
  };
});

route('GET', '/api/projects/:pid/events', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const p = getProject(ctx.params.pid);
  const since = ctx.url.searchParams.get('since');
  const limit = Math.min(Number(ctx.url.searchParams.get('limit')) || 500, 5000);
  const client = ctx.url.searchParams.get('client');
  const sp = ctx.url.searchParams;
  const clientKey = client ? `${p.id}:${ctx.user.id}:${String(client).slice(0, 20)}` : null;
  if (client) {
    const app = sp.get('su') ? { su: String(sp.get('su')).slice(0, 40), plugin: String(sp.get('pv') || '').slice(0, 20),
      ping: sp.get('ping') != null ? Number(sp.get('ping')) : undefined } : null;
    touchPoller(p.id, ctx.user, String(client).slice(0, 20), sp.get('status'), app);
  }
  let rows = since != null ? q.eventsSince.all(p.id, Number(since), limit) : q.eventsRecent.all(p.id, limit).reverse();
  // Long-poll: nothing new yet → hold the request until something happens (real-time push).
  const wait = Math.min(Number(sp.get('wait')) || 0, 25);
  if (!rows.length && since != null && wait > 0) {
    const pl = clientKey && pollers.get(clientKey);
    if (pl) pl.pending = (pl.pending || 0) + 1;
    try { await waitForEvent(p.id, wait * 1000); } finally {
      const pl2 = clientKey && pollers.get(clientKey);
      if (pl2) { pl2.pending = Math.max(0, (pl2.pending || 1) - 1); pl2.at = now(); }
    }
    rows = q.eventsSince.all(p.id, Number(since), limit);
  }
  const cache = new Map();
  const brief = (id) => {
    if (id == null) return null;
    if (!cache.has(id)) cache.set(id, userBrief(id));
    return cache.get(id);
  };
  return {
    seq: q.project.get(p.id).seq,
    limit,
    claims: client ? claimList(p.id) : undefined,
    online: client ? onlineList(p.id) : undefined,
    events: rows.map((e) => ({ type: e.type, seq: e.seq, payload: JSON.parse(e.payload), user: brief(e.user_id), at: e.created_at })),
  };
});

route('POST', '/api/projects/:pid/locks', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor');
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  const oids = Array.isArray(b.oids) ? b.oids.map(String).slice(0, 2000) : [];
  return acquireLocks(p.id, ctx.user, oids);
});

route('POST', '/api/projects/:pid/unlock', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor');
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  const oids = Array.isArray(b.oids) ? b.oids.map(String).slice(0, 2000) : [];
  return releaseLocks(p.id, ctx.user, oids, { force: !!b.force, reason: b.force ? 'forced' : 'release' });
});

route('POST', '/api/projects/:pid/objects/:oid', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor');
  requireCurrentPlugin(ctx);
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  return { object: writeObject(p.id, ctx.user, ctx.params.oid, b) };
});

route('DELETE', '/api/projects/:pid/objects/:oid', (ctx) => {
  requireRole(ctx.user, 'admin', 'editor');
  requireCurrentPlugin(ctx);
  const p = getProject(ctx.params.pid);
  return { object: deleteObject(p.id, ctx.user, ctx.params.oid, ctx.url.searchParams.get('base_rev')) };
});

route('GET', '/api/projects/:pid/objects/:oid/history', (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const p = getProject(ctx.params.pid);
  return { history: q.history.all(p.id, ctx.params.oid) };
});

route('POST', '/api/projects/:pid/objects/:oid/revert', async (ctx) => {
  requireRole(ctx.user, 'admin');
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  return { object: revertObject(p.id, ctx.user, ctx.params.oid, b.rev, !!b.force) };
});

route('POST', '/api/projects/:pid/chat', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  const text = String(b.text || '').trim().slice(0, 2000);
  if (!text) throw httpError(400, 'empty');
  const seq = tx(() => emit(p.id, 'chat', { text, oid: b.oid ? String(b.oid) : null }, ctx.user.id));
  return { seq };
});

route('GET', '/api/blobs/:sha', (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const p = blobPath(ctx.params.sha);
  if (!fs.existsSync(p)) throw httpError(404, 'blob_not_found');
  const buf = fs.readFileSync(p);
  if (ctx.url.searchParams.get('b64') === '1') return { data: buf.toString('base64'), size: buf.length };
  ctx.res.writeHead(200, {
    'Content-Type': 'application/octet-stream',
    'Content-Length': buf.length,
    'Content-Disposition': `attachment; filename="${ctx.params.sha.slice(0, 12)}.skp"`,
  });
  ctx.res.end(buf);
  return undefined;
});

// ---------------------------------------------------------------- shared file
//
// Instead of downloading a project object by object, a teammate downloads the
// whole .skp once (the "shared file") and starts from it; after that only the
// objects that change travel. Upload/download go in base64 chunks so the
// SketchUp plugin never blocks on one huge request.

const FILES_DIR = path.join(DATA_DIR, 'files');
const CHUNK_MAX = 8 * 1024 * 1024;
const uploads = new Map(); // upload_id -> { pid, path, next, user }

function sharedFilePath(pid) { return path.join(FILES_DIR, `${Number(pid)}.skp`); }

function sharedFileInfo(p) {
  const f = sharedFilePath(p.id);
  if (!fs.existsSync(f)) return null;
  let meta = {};
  try { meta = JSON.parse(fs.readFileSync(`${f}.json`, 'utf8')); } catch { /* none */ }
  return { size: fs.statSync(f).size, name: meta.name || p.name, uploaded_at: meta.uploaded_at, uploaded_by: meta.uploaded_by,
    sketchup: meta.sketchup || null, chunk: 2 * 1024 * 1024 };
}

route('POST', '/api/projects/:pid/file/chunk', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor');
  requireCurrentPlugin(ctx);
  const p = getProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  const index = Number(b.index);
  const buf = Buffer.from(String(b.data || ''), 'base64');
  if (buf.length > CHUNK_MAX) throw httpError(413, 'chunk_too_large');
  fs.mkdirSync(FILES_DIR, { recursive: true });
  let up = uploads.get(b.upload_id);
  if (index === 0) {
    up = { pid: p.id, path: path.join(FILES_DIR, `upload_${crypto.randomBytes(6).toString('hex')}.part`), next: 0, user: ctx.user.id };
    fs.writeFileSync(up.path, Buffer.alloc(0));
    b.upload_id = crypto.randomBytes(9).toString('hex');
    uploads.set(b.upload_id, up);
  }
  if (!up || up.pid !== p.id || up.user !== ctx.user.id) throw httpError(400, 'unknown_upload');
  if (index !== up.next) throw httpError(409, 'wrong_chunk', { expected: up.next });
  fs.appendFileSync(up.path, buf);
  up.next += 1;
  if (b.final) {
    uploads.delete(b.upload_id);
    const dest = sharedFilePath(p.id);
    fs.renameSync(up.path, dest);
    fs.writeFileSync(`${dest}.json`, JSON.stringify({
      name: String(b.name || p.name).slice(0, 200), uploaded_at: now(), uploaded_by: ctx.user.id,
      sketchup: b.sketchup ? String(b.sketchup).slice(0, 40) : null,
    }));
    tx(() => emit(p.id, 'shared_file', { size: fs.statSync(dest).size, name: b.name || p.name }, ctx.user.id));
    return { ok: true, done: true, file: sharedFileInfo(p) };
  }
  return { ok: true, upload_id: b.upload_id, next: up.next };
});

route('GET', '/api/projects/:pid/file', (ctx) => {
  requireRole(ctx.user, 'admin', 'editor', 'viewer');
  const p = getProject(ctx.params.pid);
  const info = sharedFileInfo(p);
  if (!info) throw httpError(404, 'no_shared_file');
  const offset = ctx.url.searchParams.get('offset');
  if (offset == null) return { file: info, seq: p.seq };
  const len = Math.min(Number(ctx.url.searchParams.get('length')) || info.chunk, CHUNK_MAX);
  const fd = fs.openSync(sharedFilePath(p.id), 'r');
  try {
    const buf = Buffer.alloc(Math.max(0, Math.min(len, info.size - Number(offset))));
    fs.readSync(fd, buf, 0, buf.length, Number(offset));
    return { data: buf.toString('base64'), offset: Number(offset), length: buf.length, size: info.size };
  } finally {
    fs.closeSync(fd);
  }
});

// ---------------------------------------------------------------- invites
//
// An invite is a one-time link for a teammate. The page explains the steps and
// hands out a copy of the SketchUp plugin that already contains the server
// address and the invite code, so after installing it the teammate is signed
// in without typing anything.

const INVITE_DAYS = 14;

function randomPassword() {
  const abc = 'abcdefghjkmnpqrstuvwxyz23456789';
  return Array.from(crypto.randomBytes(10), (b) => abc[b % abc.length]).join('');
}

function createInvite(userId) {
  const code = crypto.randomBytes(9).toString('base64url');
  db.prepare('INSERT INTO invites (code, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)')
    .run(code, userId, now(), now() + INVITE_DAYS * 86_400_000);
  return code;
}

function inviteFor(code) {
  const inv = db.prepare('SELECT * FROM invites WHERE code = ?').get(String(code || ''));
  if (!inv) return null;
  const user = q.userById.get(inv.user_id);
  if (!user || !user.active) return null;
  return { ...inv, user, expired: inv.expires_at < now() };
}

// Creates the member if needed (random password) and returns an invite for them.
function inviteMember({ username, display_name, role }) {
  let user = q.userByName.get(String(username || '').trim());
  let password = null;
  if (!user) {
    password = randomPassword();
    user = createUser({ username, display_name, password, role: role || 'editor' });
  }
  return { user: publicUser(user), password, code: createInvite(user.id) };
}

route('POST', '/api/invites', async (ctx) => {
  requireRole(ctx.user, 'admin');
  const b = await readJson(ctx.req);
  const out = inviteMember(b);
  const host = ctx.req.headers.host || `localhost:${config.port}`;
  return { ...out, link: `http://${host}/invite/${out.code}` };
});

route('POST', '/api/invites/redeem', async (ctx) => {
  const b = await readJson(ctx.req);
  const inv = inviteFor(b.code);
  if (!inv) throw httpError(404, 'invite_not_found');
  if (inv.expired) throw httpError(410, 'invite_expired');
  if (inv.used_at) throw httpError(409, 'invite_used');
  db.prepare('UPDATE invites SET used_at = ? WHERE code = ?').run(now(), inv.code);
  const token = crypto.randomBytes(32).toString('hex');
  q.tokenInsert.run(token, inv.user.id, String(b.client || 'sketchup').slice(0, 40), now(), now());
  return { token, user: publicUser(inv.user) };
});

// The plugin with this invite baked in (su_team_hub/invite.json).
function personalizedPlugin(code, serverUrl) {
  const { zip, listFiles } = require(path.join(ROOT, '..', 'tools', 'zip.js'));
  const src = path.join(ROOT, '..', 'plugin');
  if (!fs.existsSync(path.join(src, 'su_team_hub.rb'))) return null;
  const files = ['su_team_hub.rb', ...listFiles(path.join(src, 'su_team_hub')).map((f) => `su_team_hub/${f}`)]
    .filter((f) => f !== 'su_team_hub/invite.json');
  const entries = files.map((name) => ({ name, data: fs.readFileSync(path.join(src, name)) }));
  entries.push({ name: 'su_team_hub/invite.json', data: Buffer.from(JSON.stringify({ server: serverUrl, code })) });
  return zip(entries);
}

function invitePage(inv, host) {
  const esc = (t) => String(t ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const name = esc(inv.user.display_name);
  const state = inv.used_at ? 'used' : inv.expired ? 'expired' : 'ok';
  const dl = `/invite/${encodeURIComponent(inv.code)}/su_team_hub.rbz`;
  return `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>دعوة Team Hub</title>
<style>
:root{--bg:#f4f5f7;--s:#fff;--t:#1c1f24;--m:#6b7280;--b:#e3e6ea;--a:#c2410c}
@media (prefers-color-scheme:dark){:root{--bg:#121417;--s:#1b1e23;--t:#e8eaed;--m:#9aa1ab;--b:#2b3038;--a:#fb923c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--t);font:15px/1.7 "Segoe UI",Tahoma,sans-serif;padding:16px}
.c{max-width:620px;margin:24px auto;background:var(--s);border:1px solid var(--b);border-radius:14px;padding:24px}
h1{font-size:22px;margin:0 0 6px}.m{color:var(--m)}ol{padding-inline-start:22px}li{margin:10px 0}
.btn{display:inline-block;background:var(--a);color:#fff;text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600;font-size:16px}
code{background:var(--bg);padding:2px 7px;border-radius:5px;direction:ltr;display:inline-block}
.warn{background:#fff6e5;color:#92400e;padding:10px 14px;border-radius:9px}
</style></head><body><div class="c">
<h1>هلا ${name} 👋</h1>
<p class="m">انعزمت تشتغل ويا الفريق على نفس موديل SketchUp.</p>
${state === 'ok' ? `
<ol>
<li><b>نزّل البلكن الخاص بيك</b> (بيه حسابك جاهز):<br><br><a class="btn" href="${dl}">⬇ تحميل البلكن</a></li>
<li>افتح <b>SketchUp</b> ← <b>Extensions</b> ← <b>Extension Manager</b> ← <b>Install Extension</b> ← اختار الملف اللي نزل.</li>
<li>تنفتح لوحة <b>Team Hub</b> وحدها وانت داخل بحسابك. اختار المشروع ودوس <b>تحميل المشروع</b>. خلص 🎉</li>
</ol>
<p class="m">البلكن يشتغل على SketchUp 2022 وأحدث. لازم يبقى Radmin VPN شغال ومتصل بشبكة الفريق.</p>
<p class="m">إذا احتجت تسجل دخول بإيدك بعدين: العنوان <code>http://${esc(host)}</code> واسم المستخدم <code>${esc(inv.user.username)}</code>.</p>`
: `<p class="warn">${state === 'used' ? 'هذي الدعوة انستخدمت من قبل. إذا تحتاج تنصب مرة ثانية، اطلب دعوة جديدة من صاحب السيرفر.' : 'هذي الدعوة خلصت مدتها. اطلب وحدة جديدة من صاحب السيرفر.'}</p>`}
</div></body></html>`;
}

// ---------------------------------------------------------------- Revit live sync
//
// Revit keeps the model in a workshared central file. Every member's add-in
// syncs with central a few seconds after they stop editing and then tells this
// server; the server tells everyone else, whose add-ins "Reload Latest".
// Over a VPN, two members syncing at the same moment is what fails most, so
// the server hands out one sync turn at a time.

const SYNC_LEASE_MS = 180_000;
const syncTurns = new Map(); // pid -> { user, until, queued_at }
const lastBackup = new Map(); // pid -> timestamp

function getRevitProject(pid) {
  const p = getProject(pid);
  if (p.kind !== 'revit') throw httpError(400, 'not_a_revit_project');
  return p;
}

route('POST', '/api/projects/:pid/revit/sync/begin', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor');
  const p = getRevitProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  if (b.revit_version && String(b.revit_version) !== String(p.revit_version)) {
    throw httpError(409, 'wrong_revit_version', { project_version: p.revit_version });
  }
  const t = now();
  const cur = syncTurns.get(p.id);
  if (cur && cur.until > t && cur.user.id !== ctx.user.id) {
    return { granted: false, holder: publicUser(cur.user), retry_ms: 1500 };
  }
  syncTurns.set(p.id, { user: ctx.user, until: t + SYNC_LEASE_MS });
  return { granted: true, lease_ms: SYNC_LEASE_MS };
});

route('POST', '/api/projects/:pid/revit/sync/end', async (ctx) => {
  requireRole(ctx.user, 'admin', 'editor');
  const p = getRevitProject(ctx.params.pid);
  const b = await readJson(ctx.req);
  const cur = syncTurns.get(p.id);
  if (cur && cur.user.id === ctx.user.id) syncTurns.delete(p.id);
  if (!b.ok) {
    return { ok: true };
  }
  const payload = {
    kind: b.kind === 'reload' ? 'reload' : 'sync',
    duration_ms: Number(b.duration_ms) || 0,
    added: Number(b.added) || 0, modified: Number(b.modified) || 0, deleted: Number(b.deleted) || 0,
    note: b.note ? String(b.note).slice(0, 200) : null,
  };
  const seq = tx(() => emit(p.id, 'revit_sync', payload, ctx.user.id));
  backupCentral(p);
  return { ok: true, seq };
});

// Copies the central model (and Revit's _backup folder next to it) into
// data/revit-backups/<project>/<time>/ — only when the central file lives on
// this PC, at most every config.revitBackupMinutes, keeping the newest N.
function centralLocalPath(p) {
  const c = String(p.central_path || '');
  if (fs.existsSync(c)) return c;
  // \\<this-pc>\<share>\file.rvt  → resolve through the share's local folder if configured
  const shares = config.revitShares || {};
  const m = /^\\\\[^\\]+\\([^\\]+)\\(.+)$/.exec(c);
  if (m && shares[m[1]]) {
    const local = path.join(shares[m[1]], m[2]);
    if (fs.existsSync(local)) return local;
  }
  return null;
}

function backupCentral(p) {
  const minutes = Number(config.revitBackupMinutes ?? 10);
  if (minutes < 0) return;
  const t = now();
  if (t - (lastBackup.get(p.id) || 0) < minutes * 60_000) return;
  const src = centralLocalPath(p);
  if (!src) return;
  lastBackup.set(p.id, t);
  // Hold the sync turn while copying, so nobody writes to central mid-copy.
  const BACKUP_USER = { id: -1, username: 'backup', display_name: 'نسخة احتياطية', role: 'admin', color: '#888888' };
  syncTurns.set(p.id, { user: BACKUP_USER, until: t + 120_000 });
  setImmediate(() => {
    try {
      const stamp = new Date(t).toISOString().replace(/[:.]/g, '-');
      const dest = path.join(DATA_DIR, 'revit-backups', String(p.id), stamp);
      fs.mkdirSync(dest, { recursive: true });
      fs.copyFileSync(src, path.join(dest, path.basename(src)));
      const bak = src.replace(/\.rvt$/i, '_backup');
      if (fs.existsSync(bak)) fs.cpSync(bak, path.join(dest, path.basename(bak)), { recursive: true });
      const root = path.dirname(dest);
      const keep = Number(config.revitBackupsKeep ?? 30);
      const all = fs.readdirSync(root).sort();
      for (const old of all.slice(0, Math.max(0, all.length - keep))) {
        fs.rmSync(path.join(root, old), { recursive: true, force: true });
      }
      console.log(`backup of "${p.name}" → ${dest}`);
    } catch (e) {
      console.error(`backup of "${p.name}" failed:`, e.message);
    } finally {
      if (syncTurns.get(p.id)?.user.id === -1) syncTurns.delete(p.id);
    }
  });
}

route('GET', '/api/projects/:pid/revit/backups', (ctx) => {
  requireRole(ctx.user, 'admin');
  const p = getRevitProject(ctx.params.pid);
  const root = path.join(DATA_DIR, 'revit-backups', String(p.id));
  const list = fs.existsSync(root) ? fs.readdirSync(root).sort().reverse() : [];
  return { central_local: centralLocalPath(p), backups: list, folder: root };
});

// ---------------------------------------------------------------- static files

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' };

function serveStatic(req, res, url) {
  let rel = decodeURIComponent(url.pathname);
  if (rel === '/' || rel === '') rel = '/index.html';
  const file = path.normalize(path.join(PUBLIC_DIR, rel));
  if (!file.startsWith(PUBLIC_DIR) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
    return;
  }
  const buf = fs.readFileSync(file);
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Content-Length': buf.length });
  res.end(buf);
}

// ---------------------------------------------------------------- server

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const fileMatch = /^\/download\/project\/(\d+)\.skp$/.exec(url.pathname);
  if (fileMatch && req.method === 'GET') {
    const user = authenticate(req, url);
    const p = q.project.get(Number(fileMatch[1]));
    if (!user || !p || !fs.existsSync(sharedFilePath(p.id))) { res.writeHead(404); res.end('not found'); return; }
    const buf = fs.readFileSync(sharedFilePath(p.id));
    const fname = encodeURIComponent((sharedFileInfo(p).name || p.name).replace(/\.skp$/i, '') + '.skp');
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': buf.length,
      'Content-Disposition': `attachment; filename*=UTF-8''${fname}` });
    res.end(buf);
    return;
  }
  const inviteMatch = /^\/invite\/([A-Za-z0-9_-]{6,40})(\/su_team_hub\.rbz)?$/.exec(url.pathname);
  if (inviteMatch && req.method === 'GET') {
    const inv = inviteFor(inviteMatch[1]);
    const host = req.headers.host || `localhost:${config.port}`;
    if (!inv) { res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }); res.end('الدعوة مو موجودة'); return; }
    if (!inviteMatch[2]) {
      const html = Buffer.from(invitePage(inv, host));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': html.length });
      res.end(html);
      return;
    }
    if (inv.used_at || inv.expired) { res.writeHead(410, { 'Content-Type': 'text/plain; charset=utf-8' }); res.end('الدعوة انستخدمت أو خلصت'); return; }
    const rbz = personalizedPlugin(inv.code, `http://${host}`);
    if (!rbz) { send(res, 404, { error: 'plugin_not_found' }); return; }
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream', 'Content-Length': rbz.length,
      'Content-Disposition': 'attachment; filename="su_team_hub.rbz"',
    });
    res.end(rbz);
    return;
  }
  const DOWNLOADS = { '/download/su_team_hub.rbz': 'su_team_hub.rbz', '/download/teamhub_revit.zip': 'teamhub_revit.zip' };
  if (DOWNLOADS[url.pathname] && req.method === 'GET') {
    // Public on purpose: a new member needs the plugin before they have an account set up.
    const file = path.join(PLUGIN_DIR, DOWNLOADS[url.pathname]);
    if (!fs.existsSync(file)) { send(res, 404, { error: 'plugin_not_found' }); return; }
    const buf = fs.readFileSync(file);
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': buf.length,
      'Content-Disposition': `attachment; filename="${DOWNLOADS[url.pathname]}"`,
    });
    res.end(buf);
    return;
  }
  if (!url.pathname.startsWith('/api/')) {
    if (req.method === 'GET') serveStatic(req, res, url);
    else send(res, 405, { error: 'method_not_allowed' });
    return;
  }

  try {
    for (const r of routes) {
      if (r.method !== req.method) continue;
      const m = r.re.exec(url.pathname);
      if (!m) continue;
      const params = {};
      r.keys.forEach((k, i) => { params[k] = decodeURIComponent(m[i + 1]); });
      const ctx = { req, res, url, params, user: authenticate(req, url) };
      const out = await r.handler(ctx);
      if (out !== undefined) send(res, 200, out);
      return;
    }
    send(res, 404, { error: 'not_found' });
  } catch (e) {
    if (e.status) {
      send(res, e.status, { error: e.code, ...(e.extra || {}) });
    } else {
      console.error(e);
      send(res, 500, { error: 'server_error', message: e.message });
    }
  }
});

const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname !== '/ws') { socket.destroy(); return; }
  const user = authenticate(req, url);
  const pid = Number(url.searchParams.get('project'));
  if (!user || !q.project.get(pid)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    const client = String(url.searchParams.get('client') || 'web').slice(0, 20);
    clients.set(ws, { user, pid, client, status: null, alive: true });
    offlineSince.delete(`${pid}:${user.id}`);
    ws.send(JSON.stringify({ type: 'hello', seq: q.project.get(pid).seq, user: publicUser(user), online: onlineList(pid) }));
    broadcastPresence(pid);

    ws.on('pong', () => { const c = clients.get(ws); if (c) c.alive = true; });
    ws.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(String(raw)); } catch { return; }
      const c = clients.get(ws);
      if (!c) return;
      c.alive = true;
      if (msg.type === 'status') {
        // Free-form "what I'm doing" line, shown next to the user in panels.
        c.status = msg.status ? { text: String(msg.status.text || '').slice(0, 120), oid: msg.status.oid || null } : null;
        if (msg.app && typeof msg.app === 'object') {
          // Revit clients report their version and their Revit (worksharing) user name.
          c.app = {
            su: String(msg.app.su || '').slice(0, 40),
            plugin: String(msg.app.plugin || '').slice(0, 20),
            revit_user: msg.app.revit_user ? String(msg.app.revit_user).slice(0, 80) : undefined,
          };
        }
        broadcastPresence(pid);
      } else if (msg.type === 'ping') {
        // t is echoed back so the client can measure its round trip (ping)
        ws.send(JSON.stringify({ type: 'pong', t: msg.t ?? null, seq: q.project.get(pid).seq }));
        if (Number.isFinite(msg.ping)) { c.app = { ...(c.app || {}), ping: msg.ping }; }
      } else if (msg.type === 'delta') {
        // Live geometry operation over the open socket (no HTTP round trip).
        let reply;
        try { throw httpError(426, 'update_required'); }
        catch (e) { reply = { type: 'ack', id: msg.id ?? null, ok: false, status: e.status || 500, error: e.code || e.message, user: e.extra?.user }; }
        ws.send(JSON.stringify(reply));
      }
    });
    ws.on('close', () => {
      clients.delete(ws);
      if (!isOnline(pid, user.id)) offlineSince.set(`${pid}:${user.id}`, now());
      broadcastPresence(pid);
    });
  });
});

setInterval(() => {
  for (const [ws, c] of clients) {
    if (!c.alive) { ws.terminate(); continue; }
    c.alive = false;
    ws.ping();
  }
}, 25_000).unref();

server.listen(config.port, config.host, () => {
  console.log(`\n  SketchUp Team Hub v${VERSION}`);
  console.log(`  Dashboard (this PC):  http://localhost:${config.port}`);
  for (const a of serverAddresses()) {
    console.log(`  ${a.iface.padEnd(22)} http://${a.address}:${config.port}`);
  }
  if (q.userCount.get().n === 0) {
    console.log(`\n  First run: open http://localhost:${config.port} on this PC to create the admin account.`);
  }
  console.log('');
});
