const express = require('express');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const http = require('http');
const net = require('net');
const WebSocket = require('ws');

const app = express();
const PORT = Number(process.env.PORT || process.env.SERVER_PORT || 8080);
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const DB_FILE = path.join(DATA_DIR, 'nexus-data.json');
const PUBLIC_DIR = path.join(__dirname, 'public');
fs.mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });

function initialData() {
  return {
    users: [],
    settings: { panelName: 'NEXUS', wsPath: '/ws', host: process.env.PROXY_HOST || '', address: process.env.PROXY_ADDRESS || process.env.PROXY_HOST || '', port: Number(process.env.PROXY_PORT || 443), tls: true },
    usage: { note: 'WebSocket VLESS traffic is counted by this Node.js backend.', totalBytes: 0 },
    security: null
  };
}
function readData() {
  try {
    const d = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
    const base = initialData();
    return { ...base, ...d, settings: { ...base.settings, ...(d.settings || {}) } };
  } catch { return initialData(); }
}
function writeData(data) {
  const tmp = DB_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, DB_FILE);
  try { fs.chmodSync(DB_FILE, 0o600); } catch {}
}
if (!fs.existsSync(DB_FILE)) writeData(initialData());

app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Frame-Options', 'DENY');
  next();
});

const sessions = new Map();
function safeEqual(a, b) {
  const aa = Buffer.from(String(a || '')); const bb = Buffer.from(String(b || ''));
  return aa.length === bb.length && crypto.timingSafeEqual(aa, bb);
}
function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString('hex');
}
function cookieValue(req, name) {
  for (const part of (req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i > -1 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim());
  }
  return '';
}
function makeSecretPath() { return '/' + crypto.randomBytes(24).toString('base64url'); }
function getSecurity() { return readData().security; }
function isSecureRequest(req) { return req.secure || req.headers['x-forwarded-proto'] === 'https'; }
function setSessionCookie(req, res, token, clear = false) {
  const s = getSecurity();
  const cookiePath = s && s.adminPath ? s.adminPath + '/' : '/';
  res.setHeader('Set-Cookie', `nexus_session=${clear ? '' : token}; HttpOnly; SameSite=Strict; Path=${cookiePath}; ${clear ? 'Max-Age=0; ' : ''}${isSecureRequest(req) ? 'Secure' : ''}`);
}
function auth(req, res, next) {
  const token = cookieValue(req, 'nexus_session');
  if (token && sessions.has(token)) return next();
  return res.status(401).json({ error: 'Authentication required' });
}

const setupHtml = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>NEXUS · First-run setup</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:20px;background:radial-gradient(ellipse at 20% 0%,#282052 0,transparent 45%),radial-gradient(ellipse at 100% 90%,#073444 0,transparent 35%),#080b14;color:#eef2ff;font:15px/1.6 Inter,system-ui,-apple-system,"Segoe UI",sans-serif}.card{width:min(520px,100%);padding:30px;border:1px solid #27334a;border-radius:22px;background:#101626eF;box-shadow:0 25px 90px #0005}.brand{display:flex;align-items:center;gap:13px}.logo{width:48px;height:48px;display:grid;place-items:center;border-radius:15px;background:linear-gradient(135deg,#8b5cf6,#22d3ee);color:#070a12;font-size:23px;font-weight:900}.brand h1{margin:0;letter-spacing:.2em;font-size:21px}.muted{color:#8b98b7}.eyebrow{color:#a78bfa;text-transform:uppercase;letter-spacing:.2em;font-size:10px;font-weight:800;margin-top:28px}h2{font-size:27px;line-height:1.2;margin:8px 0 10px}label{display:block;font-size:12px;margin:16px 0 7px;color:#cbd5e1}input{width:100%;background:#080e1b;border:1px solid #2a354c;border-radius:11px;padding:13px;color:#eef2ff;outline:none}input:focus{border-color:#8b5cf6;box-shadow:0 0 0 3px #8b5cf622}button{width:100%;margin-top:20px;border:0;border-radius:11px;padding:13px;color:#080b14;font-weight:800;background:linear-gradient(135deg,#a78bfa,#22d3ee);cursor:pointer}.error{color:#fda4af;font-size:12px;margin-top:12px}.note{font-size:12px;color:#8b98b7;margin-top:18px}.result{display:none;margin-top:18px;padding:14px;border:1px solid #275c57;background:#10312e;border-radius:12px;overflow-wrap:anywhere}.result a{color:#67e8f9}.result button{background:#1a2236;color:#eef2ff;margin-top:10px}.small{font-size:11px;color:#8b98b7}</style></head><body><main class="card"><div class="brand"><div class="logo">N</div><div><h1>NEXUS</h1><div class="muted small">SECURE CONTROL CENTER</div></div></div><div class="eyebrow">FIRST-RUN CONFIGURATION</div><h2 id="title">Create your administrator</h2><p class="muted" id="desc">Choose a strong admin password. NEXUS will generate a private access path and save both settings for future restarts.</p><form id="setupForm"><label for="password">Admin password</label><input id="password" type="password" minlength="12" autocomplete="new-password" placeholder="At least 12 characters" required><label for="confirm">Confirm password</label><input id="confirm" type="password" minlength="12" autocomplete="new-password" placeholder="Repeat password" required><button id="submit">Initialize NEXUS →</button></form><div id="error" class="error"></div><div id="result" class="result"><strong>Setup complete</strong><p>Your private panel URL:</p><a id="panelUrl"></a><button type="button" id="copy">Copy private URL</button><p class="small">Save this URL now. The root address will no longer open the dashboard. The password and path remain unchanged across restarts as long as the data file is preserved.</p></div><p class="note">No environment password is required. Use HTTPS and keep your private URL confidential. A hidden URL is an extra layer, not a replacement for your password.</p></main><script>
const $=id=>document.getElementById(id);fetch('/__nexus_setup/status',{cache:'no-store'}).then(r=>r.json()).then(d=>{if(d.initialized){$('title').textContent='NEXUS is already configured';$('desc').textContent='The setup has already been completed. Open your saved private panel URL to sign in.';$('setupForm').style.display='none';$('error').textContent='For security, this page will not reveal the private URL again.'}}).catch(()=>{});
$('setupForm').addEventListener('submit',async e=>{e.preventDefault();$('error').textContent='';const p=$('password').value;if(p!==$('confirm').value){$('error').textContent='Passwords do not match.';return}if(p.length<12){$('error').textContent='Use at least 12 characters.';return}try{const r=await fetch('/__nexus_setup/initialize',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:p})});const d=await r.json();if(!r.ok)throw Error(d.error||'Setup failed');$('setupForm').style.display='none';$('title').textContent='Your private panel is ready';$('desc').textContent='Save the private URL below. It will remain the same after a restart.';$('panelUrl').href=d.url;$('panelUrl').textContent=d.url;$('result').style.display='block'}catch(err){$('error').textContent=err.message}});$('copy').onclick=async()=>{try{await navigator.clipboard.writeText($('panelUrl').href);$('copy').textContent='Copied'}catch{prompt('Copy your private URL',$('panelUrl').href)}};
</script></body></html>`;

app.get('/__nexus_setup/status', (req, res) => res.json({ initialized: !!getSecurity() }));
app.post('/__nexus_setup/initialize', (req, res) => {
  const d = readData();
  if (d.security) return res.status(409).json({ error: 'NEXUS has already been initialized.' });
  const password = String(req.body.password || '');
  if (password.length < 12) return res.status(400).json({ error: 'Choose a password with at least 12 characters.' });
  if (password.length > 256) return res.status(400).json({ error: 'Password is too long.' });
  const salt = crypto.randomBytes(16).toString('hex');
  const adminPath = makeSecretPath();
  d.security = { passwordSalt: salt, passwordHash: hashPassword(password, salt), adminPath, createdAt: new Date().toISOString() };
  writeData(d);
  const base = `${req.headers['x-forwarded-proto'] === 'https' || req.secure ? 'https' : 'http'}://${req.get('host')}`;
  res.status(201).json({ ok: true, url: base + adminPath + '/' });
});
app.get('/', (req, res) => {
  if (getSecurity()) return res.status(404).type('text').send('Not found');
  res.type('html').send(setupHtml);
});
app.get('/index.html', (req, res) => {
  if (getSecurity()) return res.status(404).type('text').send('Not found');
  res.type('html').send(setupHtml);
});

const panel = express.Router();
panel.use(express.json({ limit: '64kb' }));
panel.post('/api/login', (req, res) => {
  const d = readData(); const s = d.security;
  if (!s) return res.status(503).json({ error: 'First-run setup is required at the main subdomain.' });
  const supplied = String(req.body.password || '');
  const actual = hashPassword(supplied, s.passwordSalt);
  if (!safeEqual(actual, s.passwordHash)) return res.status(401).json({ error: 'Invalid password' });
  const token = crypto.randomBytes(32).toString('hex'); sessions.set(token, Date.now());
  setSessionCookie(req, res, token); res.json({ ok: true });
});
panel.post('/api/logout', auth, (req, res) => { sessions.delete(cookieValue(req, 'nexus_session')); setSessionCookie(req, res, '', true); res.json({ ok: true }); });
panel.get('/api/state', auth, (req, res) => {
  const d = readData();
  const panelHost = getPanelHostname(req);
  const effectiveSettings = { ...d.settings, host: panelHost, address: panelHost };
  const users = d.users.map(u => ({ ...u, wsLink: makeLink(u, effectiveSettings, panelHost) }));
  res.json({ panelName: 'NEXUS', users, settings: effectiveSettings, usage: d.usage, backend: { connected: true, label: 'NEXUS WS backend enabled', message: 'WebSocket backend is attached to the Node.js HTTP server. External reachability depends on cPanel proxy/WebSocket support.' } });
});
panel.post('/api/users', auth, (req, res) => {
  const name = String(req.body.name || '').trim().slice(0, 60); const quotaGB = Number(req.body.quotaGB); const days = Number(req.body.days);
  if (!name) return res.status(400).json({ error: 'Enter a user name.' });
  if (!Number.isFinite(quotaGB) || quotaGB < .1 || quotaGB > 100000) return res.status(400).json({ error: 'Quota must be between 0.1 and 100000 GB.' });
  if (!Number.isInteger(days) || days < 1 || days > 3650) return res.status(400).json({ error: 'Validity must be 1–3650 days.' });
  const d = readData(); const now = new Date(); const expires = new Date(now.getTime() + days * 86400000).toISOString();
  const u = { id: crypto.randomUUID ? crypto.randomUUID() : crypto.randomBytes(16).toString('hex'), name, uuid: crypto.randomUUID ? crypto.randomUUID() : crypto.randomBytes(16).toString('hex'), quotaGB, usedBytes: 0, createdAt: now.toISOString(), expiresAt: expires, enabled: true };
  d.users.unshift(u); writeData(d); const panelHost = getPanelHostname(req); res.status(201).json({ ...u, wsLink: makeLink(u, { ...d.settings, host: panelHost, address: panelHost }, panelHost) });
});
panel.patch('/api/users/:id', auth, (req, res) => {
  const d = readData(); const u = d.users.find(x => x.id === req.params.id); if (!u) return res.status(404).json({ error: 'User not found.' });
  if (typeof req.body.enabled === 'boolean') u.enabled = req.body.enabled;
  if (req.body.name !== undefined) u.name = String(req.body.name).trim().slice(0, 60) || u.name;
  if (req.body.quotaGB !== undefined) { const n = Number(req.body.quotaGB); if (!Number.isFinite(n) || n < .1 || n > 100000) return res.status(400).json({ error: 'Invalid quota.' }); u.quotaGB = n; }
  if (req.body.resetUsage === true) u.usedBytes = 0; writeData(d); res.json({ ok: true });
});
panel.delete('/api/users/:id', auth, (req, res) => { const d = readData(); const before = d.users.length; d.users = d.users.filter(u => u.id !== req.params.id); if (d.users.length === before) return res.status(404).json({ error: 'User not found.' }); writeData(d); res.json({ ok: true }); });
panel.patch('/api/settings', auth, (req, res) => {
  const d = readData();
  // Address, Host and SNI are always derived from the current public panel hostname.
  if (req.body.port !== undefined) { const p = Number(req.body.port); if (!Number.isInteger(p) || p < 1 || p > 65535) return res.status(400).json({ error: 'Invalid port.' }); d.settings.port = p; }
  writeData(d); res.json({ ok: true });
});
function getPanelHostname(req) {
  // Use the hostname on the current request so moving the app to another subdomain
  // automatically updates Server/Address, Host and SNI for every generated link.
  const raw = String(req.hostname || req.get('host') || '').trim().toLowerCase();
  const hostname = raw.replace(/:\d+$/, '').replace(/[^a-z0-9.-]/g, '');
  return hostname && hostname.length <= 253 ? hostname : '';
}
function makeLink(user, settings, panelHostname = '') {
  const domain = panelHostname || settings.host || '';
  const address = domain;
  const query = new URLSearchParams();
  query.set('encryption', 'none');
  query.set('security', settings.tls ? 'tls' : 'none');
  if (settings.tls) { query.set('sni', domain); query.set('insecure', '0'); query.set('allowInsecure', '0'); }
  query.set('type', 'ws');
  query.set('host', domain);
  query.set('path', settings.wsPath || '/ws');
  return `vless://${user.uuid}@${address}:${settings.port}?${query.toString()}#${encodeURIComponent('NEXUS-' + user.name + '-WS')}`;
}
panel.get('/health', (req, res) => res.json({ ok: true, app: 'NEXUS', mode: 'prototype' }));
panel.use((req, res, next) => {
  if (req.method !== 'GET') return next();
  fs.readFile(path.join(PUBLIC_DIR, 'index.html'), 'utf8', (err, html) => {
    if (err) return res.status(500).send('Unable to load NEXUS interface.');
    const base = req.nexusBase || '';
    res.type('html').send(html.replaceAll('__NEXUS_BASE__', base));
  });
});

app.use((req, res, next) => {
  const s = getSecurity();
  if (!s) return next();
  const base = s.adminPath;
  if (req.path === base || req.path === base + '/') {
    if (req.path === base) return res.redirect(308, base + '/');
  }
  if (req.path === base || req.path.startsWith(base + '/')) { req.nexusBase = base; req.url = req.url.slice(base.length) || '/'; return panel(req, res, next); }
  if (req.path.startsWith('/__nexus_setup/')) return next();
  return res.status(404).type('text').send('Not found');
});
app.use((req, res) => {
  if (!getSecurity() && (req.path === '/' || req.path === '/index.html')) return res.type('html').send(setupHtml);
  res.status(404).type('text').send('Not found');
});
// VLESS over WebSocket backend. TLS is expected to terminate at the hosting provider's HTTPS proxy.
const server = http.createServer(app);
const wss = new WebSocket.Server({ noServer: true, maxPayload: 2 * 1024 * 1024 });
const pendingUsage = new Map();
let flushBusy = false;
function addUsage(userId, bytes) {
  if (!bytes || bytes < 0) return;
  pendingUsage.set(userId, (pendingUsage.get(userId) || 0) + bytes);
}
function flushUsage() {
  if (flushBusy || pendingUsage.size === 0) return;
  flushBusy = true;
  try {
    const d = readData();
    for (const [id, amount] of pendingUsage.entries()) {
      const u = d.users.find(x => x.id === id);
      if (u) u.usedBytes = Number(u.usedBytes || 0) + amount;
    }
    d.usage.totalBytes = d.users.reduce((sum, u) => sum + Number(u.usedBytes || 0), 0);
    pendingUsage.clear(); writeData(d);
  } catch (e) { console.error('Usage flush failed:', e.message); }
  finally { flushBusy = false; }
}
const usageTimer = setInterval(flushUsage, 1500);
if (usageTimer.unref) usageTimer.unref();
function accountAllowed(u) {
  return !!u && u.enabled && Date.parse(u.expiresAt) > Date.now() && Number(u.usedBytes || 0) < Number(u.quotaGB) * 1024 ** 3;
}
function parseVlessHeader(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 24) throw new Error('VLESS header too short');
  const version = buf[0];
  const id = crypto.randomUUID ? null : null;
  const uuid = [...buf.subarray(1, 17)].map(b => b.toString(16).padStart(2, '0')).join('');
  const addonLen = buf[17];
  let i = 18 + addonLen;
  if (buf.length < i + 4) throw new Error('VLESS request incomplete');
  const command = buf[i++];
  if (command !== 1) throw new Error('Only VLESS TCP command is supported');
  const port = buf.readUInt16BE(i); i += 2;
  const atyp = buf[i++];
  let host;
  if (atyp === 1) {
    if (buf.length < i + 4) throw new Error('IPv4 address incomplete');
    host = [...buf.subarray(i, i + 4)].join('.'); i += 4;
  } else if (atyp === 2) {
    if (buf.length < i + 1) throw new Error('Domain length missing');
    const len = buf[i++];
    if (buf.length < i + len) throw new Error('Domain incomplete');
    host = buf.subarray(i, i + len).toString('utf8'); i += len;
  } else if (atyp === 3) {
    if (buf.length < i + 16) throw new Error('IPv6 address incomplete');
    const parts = [];
    for (let j = 0; j < 16; j += 2) parts.push(buf.readUInt16BE(i + j).toString(16));
    host = parts.join(':'); i += 16;
  } else throw new Error('Unsupported address type');
  if (!host || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid destination');
  return { version, uuid, host, port, payload: buf.subarray(i) };
}
server.on('upgrade', (req, socket, head) => {
  let pathname;
  try { pathname = new URL(req.url, 'http://localhost').pathname; } catch { socket.destroy(); return; }
  const d = readData();
  if (pathname !== (d.settings.wsPath || '/ws')) { socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n'); socket.destroy(); return; }
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
});
wss.on('connection', ws => {
  let stream = null, dest = null, user = null, finished = false;
  const closeAll = () => { if (finished) return; finished = true; try { if (stream) stream.destroy(); } catch {} try { if (dest) dest.destroy(); } catch {} try { if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) ws.close(); } catch {} };
  ws.once('message', (raw, isBinary) => {
    try {
      const req = parseVlessHeader(Buffer.from(raw));
      const d = readData(); user = d.users.find(u => String(u.uuid).replace(/-/g, '').toLowerCase() === req.uuid.toLowerCase());
      if (!accountAllowed(user)) { ws.close(1008, 'User disabled, expired, or quota exhausted'); return; }
      const remaining = Math.max(0, Number(user.quotaGB) * 1024 ** 3 - Number(user.usedBytes || 0));
      ws.send(Buffer.from([req.version, 0]));
      stream = WebSocket.createWebSocketStream(ws, { encoding: null });
      dest = net.connect({ host: req.host, port: req.port });
      let sentInitial = false;
      dest.once('connect', () => {
        if (req.payload.length) { dest.write(req.payload); addUsage(user.id, req.payload.length); sentInitial = true; }
        stream.on('data', chunk => {
          const current = readData().users.find(u => u.id === user.id);
          const used = Number(current?.usedBytes || 0) + (pendingUsage.get(user.id) || 0);
          const max = Number(current?.quotaGB || 0) * 1024 ** 3;
          if (!accountAllowed(current) || used + chunk.length > max) { if (max > used) addUsage(user.id, max - used); closeAll(); return; }
          addUsage(user.id, chunk.length);
        });
        dest.on('data', chunk => {
          const current = readData().users.find(u => u.id === user.id);
          const used = Number(current?.usedBytes || 0) + (pendingUsage.get(user.id) || 0);
          const max = Number(current?.quotaGB || 0) * 1024 ** 3;
          if (!accountAllowed(current) || used + chunk.length > max) { if (max > used) addUsage(user.id, max - used); closeAll(); return; }
          addUsage(user.id, chunk.length);
        });
        stream.pipe(dest).on('error', closeAll);
        dest.pipe(stream).on('error', closeAll);
      });
      dest.on('error', closeAll); dest.on('close', closeAll); stream.on('error', closeAll); ws.on('close', closeAll); ws.on('error', closeAll);
    } catch (e) { console.error('WS/VLESS request rejected:', e.message); closeAll(); }
  });
  ws.on('error', () => closeAll());
});
server.listen(PORT, '0.0.0.0', () => console.log(`NEXUS listening on port ${PORT}; WS path /ws; first-run setup at /`));
process.on('SIGTERM', () => { flushUsage(); server.close(() => process.exit(0)); });
process.on('SIGINT', () => { flushUsage(); server.close(() => process.exit(0)); });
