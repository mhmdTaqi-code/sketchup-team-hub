'use strict';
// Team Hub dashboard: login, live project overview, objects + history,
// activity feed, team and project management.

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];

const S = {
  token: localStorageGet('hub_token'),
  user: null,
  projects: [],
  pid: Number(localStorageGet('hub_project')) || null,
  state: null,
  users: new Map(),
  events: [],
  ws: null,
  wsRetry: 0,
};

function localStorageGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
function localStorageSet(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch { /* private mode */ } }

const ERRORS = {
  bad_credentials: 'اسم المستخدم أو كلمة السر غلط',
  username_taken: 'اسم المستخدم مستخدم من قبل',
  invalid_username: 'اسم المستخدم لازم يكون 2-32 حرف بدون فراغات',
  password_too_short: 'كلمة السر لازم 6 أحرف أو أكثر',
  locked_by_other: 'العنصر محجوز من عضو ثاني',
  forbidden: 'ما عندك صلاحية',
  setup_only_from_server_machine: 'الإعداد الأول يصير من جهاز السيرفر بس',
};
const ROLE = { admin: 'مدير', editor: 'مصمم', viewer: 'مشاهد' };
const KIND = { group: 'مجموعة', component: 'مكوّن', definition: 'تعريف مكوّن' };

async function api(method, path, body) {
  const r = await fetch(path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(S.token ? { Authorization: `Bearer ${S.token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await r.json().catch(() => ({}));
  if (r.status === 401 && path !== '/api/login') { logout(); }
  if (!r.ok) {
    const e = new Error(ERRORS[data.error] || data.error || `HTTP ${r.status}`);
    e.data = data;
    throw e;
  }
  return data;
}

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.add('hidden'), 3500);
}

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmtTime = (t) => t ? new Date(t).toLocaleString('ar-IQ', { dateStyle: 'short', timeStyle: 'short' }) : '';
const fmtSize = (n) => n == null ? '' : n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : `${(n / 1048576).toFixed(1)} MB`;
const userName = (id) => S.users.get(id)?.display_name || '—';
const userDot = (id) => `<span class="dot" style="background:${esc(S.users.get(id)?.color || '#999')}"></span>`;

// ---------------------------------------------------------------- boot

async function boot() {
  const info = await fetch('/api/info').then((r) => r.json());
  if (info.needs_setup) {
    showAuth();
    const local = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
    $('#setup-form').classList.toggle('hidden', !local);
    $('#setup-remote').classList.toggle('hidden', local);
    return;
  }
  if (S.token) {
    try {
      S.user = (await api('GET', '/api/me')).user;
      return startApp();
    } catch { /* fall through to login */ }
  }
  showAuth();
  $('#login-form').classList.remove('hidden');
}

function showAuth() {
  $('#auth').classList.remove('hidden');
  $('#app').classList.add('hidden');
}

$('#setup-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const f = Object.fromEntries(new FormData(ev.target));
  try {
    await api('POST', '/api/setup', f);
    const r = await api('POST', '/api/login', { username: f.username, password: f.password, client: 'web' });
    S.token = r.token; S.user = r.user; localStorageSet('hub_token', r.token);
    startApp();
  } catch (e) { $('[data-error]', ev.target).textContent = e.message; }
});

$('#login-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const f = Object.fromEntries(new FormData(ev.target));
  try {
    const r = await api('POST', '/api/login', { ...f, client: 'web' });
    S.token = r.token; S.user = r.user; localStorageSet('hub_token', r.token);
    startApp();
  } catch (e) { $('[data-error]', ev.target).textContent = e.message; }
});

function logout() {
  if (S.token) fetch('/api/logout', { method: 'POST', headers: { Authorization: `Bearer ${S.token}` } }).catch(() => {});
  S.token = null; localStorageSet('hub_token', null);
  if (S.ws) { S.ws.onclose = null; S.ws.close(); }
  location.reload();
}
$('#logout').addEventListener('click', logout);

async function startApp() {
  $('#auth').classList.add('hidden');
  $('#app').classList.remove('hidden');
  $('#me').textContent = `${S.user.display_name} · ${ROLE[S.user.role]}`;
  $$('[data-admin]').forEach((el) => el.classList.toggle('hidden', S.user.role !== 'admin'));
  await loadProjects();
  renderConnect();
}

async function loadProjects() {
  S.projects = (await api('GET', `/api/projects${S.user.role === 'admin' ? '?all=1' : ''}`)).projects;
  const active = S.projects.filter((p) => !p.archived);
  if (!active.find((p) => p.id === S.pid)) S.pid = active[0]?.id || null;
  $('#project-select').innerHTML = active.map((p) => `<option value="${p.id}" ${p.id === S.pid ? 'selected' : ''}>${esc(p.name)}</option>`).join('');
  renderProjects();
  if (S.pid) await openProject(S.pid);
}

$('#project-select').addEventListener('change', (e) => openProject(Number(e.target.value)));

async function openProject(pid) {
  S.pid = pid;
  localStorageSet('hub_project', String(pid));
  const [state, ev] = await Promise.all([
    api('GET', `/api/projects/${pid}/state`),
    api('GET', `/api/projects/${pid}/events?limit=300`),
  ]);
  S.state = state;
  S.users = new Map(state.users.map((u) => [u.id, u]));
  S.events = ev.events;
  connectWs();
  renderAll();
  if (S.user.role === 'admin') loadUsers();
}

// ---------------------------------------------------------------- live

function connectWs() {
  if (S.ws) { S.ws.onclose = null; S.ws.close(); }
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/ws?token=${S.token}&project=${S.pid}&client=web`);
  S.ws = ws;
  ws.onopen = () => { S.wsRetry = 0; setConn(true); };
  ws.onclose = () => {
    setConn(false);
    const delay = Math.min(15000, 1000 * 2 ** S.wsRetry++);
    setTimeout(() => { if (S.ws === ws) connectWs(); }, delay);
  };
  ws.onmessage = (m) => handleEvent(JSON.parse(m.data));
}

function setConn(on) {
  const c = $('#conn');
  c.textContent = on ? 'متصل مباشر' : 'غير متصل';
  c.className = `pill ${on ? 'on' : 'off'}`;
}

async function handleEvent(e) {
  const st = S.state;
  if (!st) return;
  if (e.type === 'hello') {
    st.online = e.online;
    // Missed events while disconnected → reload the full state.
    if (e.seq !== st.seq) return openProject(S.pid);
    return renderAll();
  }
  if (e.type === 'presence') { st.online = e.online; return renderOverview(); }
  if (e.type === 'pong') return;
  if (e.seq) st.seq = e.seq;
  if (e.user && !S.users.has(e.user.id)) S.users.set(e.user.id, e.user);
  S.events.push(e);
  if (S.events.length > 500) S.events.shift();
  if (e.type === 'object') {
    const i = st.objects.findIndex((o) => o.oid === e.payload.oid);
    if (i >= 0) st.objects[i] = e.payload; else st.objects.push(e.payload);
  } else if (e.type === 'lock') {
    for (const oid of e.payload.oids) {
      st.locks = st.locks.filter((l) => l.oid !== oid);
      st.locks.push({ oid, user_id: e.payload.user_id, acquired_at: e.at });
    }
  } else if (e.type === 'unlock') {
    st.locks = st.locks.filter((l) => !e.payload.oids.includes(l.oid));
  }
  renderAll();
}

// ---------------------------------------------------------------- render

function renderAll() {
  renderOverview();
  renderObjects();
  renderActivity();
}

function objName(oid) {
  const o = S.state.objects.find((x) => x.oid === oid);
  return o ? (o.name || `(${KIND[o.kind] || o.kind} بدون اسم)`) : oid;
}

function renderOverview() {
  const st = S.state;
  const live = st.objects.filter((o) => !o.deleted);
  const total = live.reduce((a, o) => a + (o.size || 0), 0);
  $('#stats').innerHTML = [
    [live.length, 'عنصر بالمشروع'],
    [st.online.length, 'متصل هسه'],
    [st.locks.length, 'عنصر محجوز'],
    [fmtSize(total) || '0 B', 'حجم المشروع'],
  ].map(([v, l]) => `<div class="stat"><b>${esc(v)}</b><span>${l}</span></div>`).join('');

  $('#online').innerHTML = st.online.length ? st.online.map((u) => `
    <li><span class="dot" style="background:${esc(u.color)}"></span>
      <div><b>${esc(u.display_name)}</b> <span class="muted">${(u.apps || []).length ? u.apps.map((a) => esc(a.su) + (a.plugin ? ' · ' + esc(a.plugin) : '')).join('، ') : u.clients.includes('sketchup') ? 'SketchUp' : 'المتصفح'}</span>
      ${u.status?.text ? `<div class="status">${esc(u.status.text)}</div>` : ''}</div></li>`).join('')
    : '<li class="empty">محد متصل</li>';

  const byUser = new Map();
  for (const l of st.locks) {
    if (!byUser.has(l.user_id)) byUser.set(l.user_id, []);
    byUser.get(l.user_id).push(l.oid);
  }
  $('#lock-summary').innerHTML = byUser.size ? [...byUser].map(([uid, oids]) => `
    <li>${userDot(uid)}<div><b>${esc(userName(uid))}</b> — ${oids.length} عنصر
      <div class="muted">${oids.slice(0, 6).map((o) => esc(objName(o))).join('، ')}${oids.length > 6 ? '…' : ''}</div></div></li>`).join('')
    : '<li class="empty">ماكو حجوزات</li>';

  const chats = S.events.filter((e) => e.type === 'chat').slice(-100);
  const box = $('#chat');
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
  box.innerHTML = chats.length ? chats.map((e) => `
    <div class="msg"><b style="color:${esc(e.user?.color)}">${esc(e.user?.display_name)}</b><time>${fmtTime(e.at)}</time><div>${esc(e.payload.text)}</div></div>`).join('')
    : '<div class="empty">ماكو رسائل بعد</div>';
  if (atBottom) box.scrollTop = box.scrollHeight;
}

function renderObjects() {
  const st = S.state;
  const filter = $('#obj-filter').value.trim().toLowerCase();
  const showDeleted = $('#obj-deleted').checked;
  const locks = new Map(st.locks.map((l) => [l.oid, l]));
  const rows = st.objects
    .filter((o) => showDeleted || !o.deleted)
    .filter((o) => !filter || `${o.name} ${o.layer}`.toLowerCase().includes(filter))
    .sort((a, b) => b.updated_at - a.updated_at);
  $('#obj-rows').innerHTML = rows.length ? rows.map((o) => {
    const l = locks.get(o.oid);
    const canForce = l && S.user.role === 'admin';
    return `<tr class="${o.deleted ? 'deleted' : ''}">
      <td>${esc(o.name || '—')}</td>
      <td>${KIND[o.kind] || o.kind}</td>
      <td>${esc(o.layer || '—')}</td>
      <td class="num">r${o.rev}</td>
      <td>${esc(userName(o.updated_by))} <span class="muted">${fmtTime(o.updated_at)}</span></td>
      <td>${l ? `<span class="tag">${userDot(l.user_id)}${esc(userName(l.user_id))}</span>` : '<span class="muted">متاح</span>'}</td>
      <td>
        <button class="btn small" data-history="${esc(o.oid)}">السجل</button>
        ${canForce ? `<button class="btn small danger" data-force="${esc(o.oid)}">فك الحجز</button>` : ''}
      </td></tr>`;
  }).join('') : '<tr><td colspan="7" class="empty">ماكو عناصر. افتح SketchUp وارفع المشروع من البلكن.</td></tr>';
}

$('#obj-filter').addEventListener('input', renderObjects);
$('#obj-deleted').addEventListener('change', renderObjects);

$('#obj-rows').addEventListener('click', async (ev) => {
  const h = ev.target.closest('[data-history]');
  const f = ev.target.closest('[data-force]');
  if (h) return showHistory(h.dataset.history);
  if (f && confirm('فك حجز هذا العنصر؟ إذا العضو بعده يعدل عليه، تعديلاته اللي ما انرفعت تضيع.')) {
    try { await api('POST', `/api/projects/${S.pid}/unlock`, { oids: [f.dataset.force], force: true }); toast('انفك الحجز'); }
    catch (e) { toast(e.message); }
  }
});

async function showHistory(oid) {
  const { history } = await api('GET', `/api/projects/${S.pid}/objects/${encodeURIComponent(oid)}/history`);
  const cur = S.state.objects.find((o) => o.oid === oid);
  $('#history-title').textContent = `سجل: ${objName(oid)}`;
  $('#history-rows').innerHTML = history.map((h) => `<tr class="${h.deleted ? 'deleted' : ''}">
    <td class="num">r${h.rev}</td><td>${esc(h.user_name || '—')}</td><td>${fmtTime(h.created_at)}</td>
    <td class="num">${fmtSize(h.size)}</td><td>${esc(h.note || '')}</td>
    <td>
      ${h.blob ? `<a class="btn small" href="/api/blobs/${h.blob}?token=${S.token}">تحميل .skp</a>` : ''}
      ${S.user.role === 'admin' && cur && h.rev !== cur.rev ? `<button class="btn small" data-revert="${h.rev}">رجوع لهاي النسخة</button>` : ''}
    </td></tr>`).join('');
  $('#history-rows').onclick = async (ev) => {
    const b = ev.target.closest('[data-revert]');
    if (!b) return;
    if (!confirm(`نرجع العنصر للنسخة r${b.dataset.revert}؟ راح تتحدث عند كل الفريق.`)) return;
    try {
      await api('POST', `/api/projects/${S.pid}/objects/${encodeURIComponent(oid)}/revert`, { rev: Number(b.dataset.revert), force: true });
      toast('رجع العنصر للنسخة المختارة');
      $('#history-dialog').close();
    } catch (e) { toast(e.message); }
  };
  $('#history-dialog').showModal();
}

function describe(e) {
  const who = `<b style="color:${esc(e.user?.color)}">${esc(e.user?.display_name || 'النظام')}</b>`;
  const p = e.payload;
  switch (e.type) {
    case 'object': return p.deleted ? `${who} حذف «${esc(p.name || p.oid)}»` : p.rev === 1
      ? `${who} أضاف «${esc(p.name || p.oid)}»` : `${who} عدّل «${esc(p.name || p.oid)}» (r${p.rev})`;
    case 'lock': return `${who} حجز ${p.oids.length > 1 ? `${p.oids.length} عناصر` : `«${esc(objName(p.oids[0]))}»`}`;
    case 'unlock': {
      const why = { timeout: ' (انتهى الوقت)', forced: ' (بواسطة المدير)', deleted: '', revert: ' (رجوع نسخة)' }[p.reason] || '';
      return `${who} فك حجز ${p.oids.length > 1 ? `${p.oids.length} عناصر` : `«${esc(objName(p.oids[0]))}»`}${why}`;
    }
    case 'chat': return `${who}: ${esc(p.text)}`;
    default: return `${who} ${esc(e.type)}`;
  }
}

function renderActivity() {
  const items = S.events.slice(-300).reverse();
  $('#activity').innerHTML = items.length ? items.map((e) => `<li><span>${describe(e)}</span><time>${fmtTime(e.at)}</time></li>`).join('')
    : '<li class="empty">ماكو نشاط بعد</li>';
}

$('#chat-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const input = ev.target.text;
  const text = input.value.trim();
  if (!text) return;
  try { await api('POST', `/api/projects/${S.pid}/chat`, { text }); input.value = ''; }
  catch (e) { toast(e.message); }
});

// ---------------------------------------------------------------- team

async function loadUsers() {
  const { users } = await api('GET', '/api/users');
  for (const u of users) S.users.set(u.id, { ...S.users.get(u.id), ...u });
  $('#user-rows').innerHTML = users.map((u) => `<tr>
    <td><span class="tag"><span class="dot" style="background:${esc(u.color)}"></span>${esc(u.display_name)}</span></td>
    <td class="mono">${esc(u.username)}</td>
    <td><select data-role="${u.id}" ${u.id === S.user.id ? 'disabled' : ''}>
      ${Object.entries(ROLE).map(([k, v]) => `<option value="${k}" ${u.role === k ? 'selected' : ''}>${v}</option>`).join('')}
    </select></td>
    <td>${u.active ? 'فعّال' : '<span class="muted">موقوف</span>'}</td>
    <td>
      <button class="btn small" data-pass="${u.id}">تغيير كلمة السر</button>
      ${u.id !== S.user.id ? `<button class="btn small ${u.active ? 'danger' : ''}" data-active="${u.id}" data-to="${u.active ? 0 : 1}">${u.active ? 'إيقاف' : 'تفعيل'}</button>` : ''}
    </td></tr>`).join('');
}

$('#user-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const f = Object.fromEntries(new FormData(ev.target));
  try {
    await api('POST', '/api/users', f);
    ev.target.reset();
    $('[data-error]', ev.target).textContent = '';
    toast(`انضاف ${f.display_name}`);
    loadUsers();
  } catch (e) { $('[data-error]', ev.target).textContent = e.message; }
});

$('#user-rows').addEventListener('change', async (ev) => {
  const s = ev.target.closest('[data-role]');
  if (!s) return;
  try { await api('PATCH', `/api/users/${s.dataset.role}`, { role: s.value }); toast('تغيّرت الصلاحية'); }
  catch (e) { toast(e.message); loadUsers(); }
});

$('#user-rows').addEventListener('click', async (ev) => {
  const p = ev.target.closest('[data-pass]');
  const a = ev.target.closest('[data-active]');
  try {
    if (p) {
      const pw = prompt('كلمة السر الجديدة (6 أحرف أو أكثر):');
      if (!pw) return;
      await api('PATCH', `/api/users/${p.dataset.pass}`, { password: pw });
      toast('تغيّرت كلمة السر');
    } else if (a) {
      const to = a.dataset.to === '1';
      if (!to && !confirm('إيقاف هذا العضو؟ راح يطلع من كل الأجهزة وتنفك حجوزاته.')) return;
      await api('PATCH', `/api/users/${a.dataset.active}`, { active: to });
      loadUsers();
    }
  } catch (e) { toast(e.message); }
});

// ---------------------------------------------------------------- projects

function renderProjects() {
  $('#project-list').innerHTML = S.projects.map((p) => `<li>
    <div class="grow"><b>${esc(p.name)}</b> <span class="muted">${p.kind === 'revit' ? `Revit ${esc(p.revit_version)} · <span class="mono">${esc(p.central_path)}</span>` : `SketchUp · ${p.objects} عنصر`} · ${p.online} متصل${p.archived ? ' · مؤرشف' : ''}</span></div>
    <button class="btn small" data-rename="${p.id}">تغيير الاسم</button>
    <button class="btn small" data-archive="${p.id}" data-to="${p.archived ? 0 : 1}">${p.archived ? 'استرجاع' : 'أرشفة'}</button>
  </li>`).join('');
}

$('#project-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  try {
    const { project } = await api('POST', '/api/projects', { name: ev.target.name.value });
    ev.target.reset();
    S.pid = project.id;
    await loadProjects();
    toast('انشأ المشروع');
  } catch (e) { toast(e.message); }
});

$('#project-list').addEventListener('click', async (ev) => {
  const r = ev.target.closest('[data-rename]');
  const a = ev.target.closest('[data-archive]');
  try {
    if (r) {
      const name = prompt('الاسم الجديد:');
      if (!name) return;
      await api('PATCH', `/api/projects/${r.dataset.rename}`, { name });
    } else if (a) {
      await api('PATCH', `/api/projects/${a.dataset.archive}`, { archived: a.dataset.to === '1' });
    } else return;
    await loadProjects();
  } catch (e) { toast(e.message); }
});

// ---------------------------------------------------------------- connect info

async function renderConnect() {
  const info = await fetch('/api/info').then((r) => r.json());
  const list = info.addresses.map((a) => {
    const radmin = a.address.startsWith('26.') || /radmin/i.test(a.iface);
    return `<li><b>http://${esc(a.address)}:${info.port}</b> <span class="muted">${esc(a.iface)}${radmin ? ' — Radmin VPN ✓' : ''}</span></li>`;
  });
  $('#addresses').innerHTML = list.join('') || '<li class="empty">ماكو شبكة</li>';
  const pl = info.plugin;
  $('#plugin-box').innerHTML = pl
    ? `<a class="btn primary" href="${pl.download}" download>تحميل البلكن (Team Hub ${esc(pl.version)})</a>
       <span class="muted">${fmtSize(pl.size)} · يشتغل على SketchUp ${pl.min_sketchup} وأحدث (2024، 2025، 2026…)</span>`
    : '<span class="muted">البلكن مو مرفوع على السيرفر. شغّل tools/build-plugin.js</span>';
  const rv = info.revit_plugin;
  $('#plugin-box').innerHTML += rv
    ? `<div style="width:100%;margin-top:8px"><a class="btn primary" href="${rv.download}" download>تحميل إضافة Revit (Team Hub ${esc(rv.version)})</a>
       <span class="muted">${fmtSize(rv.size)} · Revit ${rv.revit.join(' و ')} · فك الضغط وشغّل install.cmd</span></div>`
    : '';
}

// ---------------------------------------------------------------- tabs

$('#tabs').addEventListener('click', (ev) => {
  const b = ev.target.closest('button[data-tab]');
  if (!b) return;
  $$('#tabs button').forEach((x) => x.classList.toggle('active', x === b));
  $$('main > section').forEach((s) => s.classList.toggle('hidden', s.dataset.view !== b.dataset.tab));
  if (b.dataset.tab === 'connect') renderConnect();
});

boot().catch((e) => { document.body.textContent = `تعذر الاتصال بالسيرفر: ${e.message}`; });
