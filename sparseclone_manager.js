/**
 * sparseclone_manager.js  SparseClone Manager Server (Node.js)
 * ============================================================
 * Serves the GUI and persists profiles/schedules to JSON files
 * in the same directory as this script.
 *
 * Usage:
 *   node sparseclone_manager.js              # default port 7890
 *   node sparseclone_manager.js --port 8080
 *   node sparseclone_manager.js --no-browser
 *
 * Requirements:
 *   Node.js 16+ (no npm install needed  stdlib only)
 *
 * Files created alongside this script:
 *   sparseclone_profiles.json     Oracle Environment profiles
 *   sparseclone_schedules.json    Scheduler definitions
 */

'use strict';

const http     = require('http');
const fs       = require('fs');
const path     = require('path');
const url      = require('url');
const crypto   = require('crypto');
const { execSync, spawn } = require('child_process');

//  Scheduler daemon proxy
// All /api/scheduler/* requests are forwarded to sparseclone_scheduler.py.
// Change SCHED_DAEMON_PORT if you start the Python daemon on a different port.
const SCHED_DAEMON_HOST = process.env.SCHED_DAEMON_HOST || '127.0.0.1';
const SCHED_DAEMON_PORT = parseInt(process.env.SCHED_DAEMON_PORT || '7891');

// Tracks the daemon child process when started from the GUI
let _schedulerProc = null;

function startSchedulerDaemon(res) {
  if (_schedulerProc && !_schedulerProc.killed) {
    res.end(JSON.stringify({ ok: false, error: 'Daemon already running (PID ' + _schedulerProc.pid + ')' }));
    return;
  }
  const scriptPath = path.join(__dirname, 'sparseclone_scheduler.py');
  if (!fs.existsSync(scriptPath)) {
    res.end(JSON.stringify({ ok: false, error: 'sparseclone_scheduler.py not found beside sparseclone_manager.js' }));
    return;
  }
  try {
    _schedulerProc = spawn('python3', [scriptPath, '--port', String(SCHED_DAEMON_PORT)], {
      detached: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    _schedulerProc.stdout.on('data', d => process.stdout.write('[SCHED] ' + d));
    _schedulerProc.stderr.on('data', d => process.stderr.write('[SCHED] ' + d));
    _schedulerProc.on('exit', (code) => {
      console.log('[SCHED] Daemon exited with code', code);
      _schedulerProc = null;
    });
    res.end(JSON.stringify({ ok: true, pid: _schedulerProc.pid }));
  } catch(e) {
    res.end(JSON.stringify({ ok: false, error: e.message }));
  }
}

function stopSchedulerDaemon(res) {
  if (!_schedulerProc || _schedulerProc.killed) {
    _schedulerProc = null;
    res.end(JSON.stringify({ ok: false, error: 'No daemon process managed by this server' }));
    return;
  }
  try {
    _schedulerProc.kill('SIGTERM');
    res.end(JSON.stringify({ ok: true }));
  } catch(e) {
    res.end(JSON.stringify({ ok: false, error: e.message }));
  }
}

function proxyToScheduler(req, res, bodyBuf) {
  return new Promise((resolve) => {
    const headers = { 'Content-Type': 'application/json' };
    if (bodyBuf && bodyBuf.length) headers['Content-Length'] = String(bodyBuf.length);
    const options = {
      hostname: SCHED_DAEMON_HOST,
      port:     SCHED_DAEMON_PORT,
      path:     req.url,          // preserve full path + query string
      method:   req.method,
      headers,
    };
    const pr = http.request(options, (dr) => {
      let raw = '';
      dr.on('data', c => raw += c);
      dr.on('end', () => {
        res.writeHead(dr.statusCode, {
          'Content-Type':                'application/json',
          'Access-Control-Allow-Origin': '*',
        });
        res.end(raw);
        resolve();
      });
    });
    pr.on('error', (e) => {
      console.warn(`  [PROXY] Scheduler daemon unreachable (${SCHED_DAEMON_HOST}:${SCHED_DAEMON_PORT}): ${e.message}`);
      res.writeHead(503, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
      res.end(JSON.stringify({ ok: false, error: `Scheduler daemon offline — is sparseclone_scheduler.py running on port ${SCHED_DAEMON_PORT}?` }));
      resolve();
    });
    if (bodyBuf && bodyBuf.length) pr.write(bodyBuf);
    pr.end();
  });
}

//  Config 
// APP_DIR  = code files (baked into image, read-only)
// DATA_DIR = persistent state (bind-mounted from host via -v /host/data:/data)
const APP_DIR  = __dirname;
const DATA_DIR = process.env.DATA_DIR || APP_DIR;   // falls back to same dir in dev

// Ensure DATA_DIR exists (safe no-op if already present)
try { fs.mkdirSync(DATA_DIR, { recursive: true }); } catch {}

const HTML_FILE         = path.join(APP_DIR,  'exadata_sparseclone_gui.html');
const SCRIPT_FILE       = path.join(APP_DIR,  'exadata_sparseclone_create_v6.sh');
const PROFILES_FILE     = path.join(DATA_DIR, 'sparseclone_profiles.json');
const SCHEDULES_FILE    = path.join(DATA_DIR, 'sparseclone_schedules.json');
const CONF_FILE         = path.join(DATA_DIR, 'sparse_clone.conf');
const SSH_SETTINGS_FILE = path.join(DATA_DIR, 'sparseclone_ssh.json');
const USERS_FILE        = path.join(DATA_DIR, 'sparseclone_users.json');

// Legacy alias so remaining BASE_DIR refs still work
const BASE_DIR          = DATA_DIR;
const RUN_SCRIPT_FILE   = path.join(APP_DIR,  'run_sparseclone.sh');
const RUN_LOG_DIR       = path.join(DATA_DIR, 'logs', 'runs');
try { fs.mkdirSync(RUN_LOG_DIR, { recursive: true }); } catch {}

// ─────────────────────────────────────────────────────────────────────────────
// Auth — PBKDF2 password hashing, session tokens, user CRUD
// ─────────────────────────────────────────────────────────────────────────────

const SESSION_TTL_MS  = 8 * 60 * 60 * 1000;   // 8 hours
const PBKDF2_ITERS    = 100_000;
const PBKDF2_KEYLEN   = 64;
const PBKDF2_DIGEST   = 'sha512';

// In-memory session store:  token → { username, role, expiresAt }
const _sessions = new Map();

function _hashPassword(password, salt) {
  return crypto.pbkdf2Sync(password, salt, PBKDF2_ITERS, PBKDF2_KEYLEN, PBKDF2_DIGEST).toString('hex');
}

function hashPassword(password) {
  const salt = crypto.randomBytes(32).toString('hex');
  const hash = _hashPassword(password, salt);
  return { hash, salt };
}

function verifyPassword(password, hash, salt) {
  return _hashPassword(password, salt) === hash;
}

function readUsers() {
  try {
    if (fs.existsSync(USERS_FILE)) {
      const data = JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
      return Array.isArray(data) ? data : [];
    }
  } catch (e) { console.error('[AUTH] Could not read users file:', e.message); }
  return [];
}

function writeUsers(users) {
  const tmp = USERS_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(users, null, 2), 'utf8');
  fs.renameSync(tmp, USERS_FILE);
}

function createToken() {
  return crypto.randomBytes(48).toString('hex');
}

function createSession(username, role) {
  const token = createToken();
  _sessions.set(token, { username, role, expiresAt: Date.now() + SESSION_TTL_MS });
  return token;
}

function getSession(token) {
  if (!token) return null;
  const sess = _sessions.get(token);
  if (!sess) return null;
  if (Date.now() > sess.expiresAt) { _sessions.delete(token); return null; }
  return sess;
}

function destroySession(token) {
  _sessions.delete(token);
}

function getTokenFromReq(req) {
  const cookie = req.headers.cookie || '';
  const m = cookie.match(/(?:^|;\s*)sc_session=([^;]+)/);
  if (m) return m[1];
  const auth = req.headers['authorization'] || '';
  if (auth.startsWith('Bearer ')) return auth.slice(7);
  return null;
}

function requireAuth(req, res) {
  const token = getTokenFromReq(req);
  const sess  = getSession(token);
  if (!sess) {
    sendJson(res, { ok: false, error: 'Unauthorized', code: 'UNAUTH' }, 401);
    return null;
  }
  return sess;
}

function requireAdmin(req, res) {
  const sess = requireAuth(req, res);
  if (!sess) return null;
  if (sess.role !== 'admin') {
    sendJson(res, { ok: false, error: 'Forbidden — admin role required', code: 'FORBIDDEN' }, 403);
    return null;
  }
  return sess;
}

// Seed default admin on first run if no users exist
function ensureDefaultAdmin() {
  const users = readUsers();
  if (users.length === 0) {
    console.log('[AUTH] No users found — first-run setup required via /api/auth/register-first');
  }
}

//  Run state (single concurrent job) 
let _runState = {
  running:   false,
  pid:       null,
  startedAt: null,
  exitCode:  null,
  log:       [],          // full log lines for late-joining clients
  sseClients: [],         // active SSE response objects
  logFile:   null,        // path to on-disk log file for this run
};

function pushLog(line) {
  _runState.log.push(line);
  // write to disk log file
  if (_runState.logFile) {
    try { fs.appendFileSync(_runState.logFile, line + '\n'); } catch {}
  }
  // fan-out to all connected SSE clients
  _runState.sseClients.forEach(client => {
    try { client.write(`data: ${JSON.stringify(line)}\n\n`); } catch { /* ignore */ }
  });
}

//  CLI args 
const args       = process.argv.slice(2);
const PORT       = (() => { const i = args.indexOf('--port'); return i !== -1 ? parseInt(args[i+1]) || 7890 : 7890; })();
const HOST       = (() => { const i = args.indexOf('--host'); return i !== -1 ? args[i+1] : '127.0.0.1'; })();
const NO_BROWSER = args.includes('--no-browser');

//  File helpers 
// Strip Windows CR characters from a buffer and return a clean Buffer
function stripCRLF(buf) {
  // Remove all \r (carriage return) characters — handles both \r\n and lone \r
  const str = buf.toString('binary').replace(/\r/g, '');
  return Buffer.from(str, 'binary');
}

function readJson(filePath, fallback) {
  try {
    if (fs.existsSync(filePath)) {
      return JSON.parse(fs.readFileSync(filePath, 'utf8'));
    }
  } catch (e) {
    console.error(`  [WARN] Could not read ${path.basename(filePath)}: ${e.message}`);
  }
  return fallback;
}

function writeJson(filePath, data) {
  const tmp = filePath + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), 'utf8');
  fs.renameSync(tmp, filePath);   // atomic on POSIX
}

// ── Profile config file generation ───────────────────────────────────────────
// Each saved profile gets its own sparse_clone.conf written to DATA_DIR/profiles/
const PROFILES_CONF_DIR = path.join(DATA_DIR, 'profiles');
try { fs.mkdirSync(PROFILES_CONF_DIR, { recursive: true }); } catch {}

function profileConfPath(name) {
  // Sanitise name to a safe filename
  const safe = name.replace(/[^a-zA-Z0-9_\-\.]/g, '_');
  return path.join(PROFILES_CONF_DIR, `${safe}.conf`);
}

function generateConfFromProfile(name, profileData) {
  const d  = profileData || {};
  const v  = (key, fallback = '') => (d[key] != null && String(d[key]).trim() !== '') ? String(d[key]).trim() : fallback;
  const now = new Date().toISOString();

  // Build SCRIPT_FLAGS from stored flag booleans
  const flags = [];
  if (d.FLAG_SKIP_SHUTDOWN)       flags.push('--skip-shutdown');
  if (d.IS_CDB)                   flags.push('--cdb');
  if (d.FLAG_FORCE)               flags.push('--force');
  if (d.FLAG_SNAP_INDEX_EXPLICIT) flags.push('--snap-index ' + v('SNAP_INDEX', '0'));

  const asmMethod = v('ASM_EXEC_METHOD', 'sudo');
  const isSsh     = asmMethod === 'ssh';

  const lines = [
    `# ============================================================`,
    `# sparse_clone.conf — generated by SparseClone Manager`,
    `# Profile  : ${name}`,
    `# Generated: ${now}`,
    `# Usage    : ./exadata_sparseclone_create_v6.sh --config ${profileConfPath(name)}`,
    `# ============================================================`,
    ``,
    `# Runtime Flags`,
    `SCRIPT_FLAGS="${flags.join(' ')}"`,
    ``,
    `# Test Master Database`,
    `TM_DB_NAME="${v('TM_DB_NAME', 'TESTMASTER')}"`,
    `TM_DB_UNIQUE_NAME="${v('TM_DB_UNIQUE_NAME', 'TESTMASTER')}"`,
    `TM_ORACLE_SID="${v('TM_ORACLE_SID', 'TESTMASTER1')}"`,
    `TM_DATA_DG="${v('TM_DATA_DG', '+DATA')}"`,
    ``,
    `# Snapshot (Clone) Database`,
    `SNAP_DB_NAME="${v('SNAP_DB_NAME', 'SNAPTEST')}"`,
    `SNAP_DB_UNIQUE_NAME="${v('SNAP_DB_UNIQUE_NAME', 'SNAPTEST')}"`,
    `SNAP_ORACLE_SID="${v('SNAP_ORACLE_SID', 'SNAPTEST1')}"`,
    `SNAP_SPARSE_DG="${v('SNAP_SPARSE_DG', '+SPARSE')}"`,
    `SNAP_DATA_DG="${v('SNAP_DATA_DG', '+DATA')}"`,
  ];

  const scf = v('SNAP_CONTROL_FILE');
  if (scf) lines.push(`SNAP_CONTROL_FILE="${scf}"`);

  lines.push(
    ``,
    `# Redo Logs & Temp`,
    `REDO_SIZE="${v('REDO_SIZE', '100M')}"`,
    `REDO_BLOCKSIZE="${v('REDO_BLOCKSIZE', '512')}"`,
    `REDO_GROUPS="${v('REDO_GROUPS', '2')}"`,
    `TEMP_SIZE="${v('TEMP_SIZE', '10G')}"`,
    `SNAP_INDEX="${v('SNAP_INDEX', '0')}"`,
    `IS_CDB="${d.IS_CDB ? 'true' : 'false'}"`,
    ``,
    `# Oracle Environment`,
    `ORACLE_HOME="${v('ORACLE_HOME', '/u01/app/oracle/product/19.0.0/dbhome_1')}"`,
    `ORACLE_BASE="${v('ORACLE_BASE', '/u01/app/oracle')}"`,
    `ORACLE_USER="${v('ORACLE_USER', 'oracle')}"`,
  );

  const wd = v('WORK_DIR'); if (wd) lines.push(`WORK_DIR="${wd}"`);
  const ad = v('ADUMP_DIR'); if (ad) lines.push(`ADUMP_DIR="${ad}"`);

  lines.push(
    ``,
    `# Grid Infrastructure & ASM`,
    `GRID_HOME="${v('GRID_HOME', '/u01/app/grid/product/19.0.0/grid')}"`,
    `GRID_USER="${v('GRID_USER', 'grid')}"`,
    `ASM_SID="${v('ASM_SID', '+ASM1')}"`,
    `ASM_EXEC_METHOD="${asmMethod}"`,
  );

  if (isSsh) {
    lines.push(`ASM_SSH_KEY="${v('ASM_SSH_KEY', '/home/oracle/.ssh/id_rsa')}"`);
    lines.push(`ASM_SSH_HOST="${v('ASM_SSH_HOST', 'localhost')}"`);
  }

  // Refresh params (stored in profile if user was on refresh page)
  const sdb = v('SOURCE_DB_NAME'); const ssl = v('SNAP_SID_LIST');
  if (sdb || ssl) {
    lines.push(``, `# Refresh Parameters`);
    if (sdb) lines.push(`SOURCE_DB_NAME="${sdb}"`);
    if (ssl) lines.push(`SNAP_SID_LIST="${ssl}"`);
    const rm = v('REFRESH_METHOD'); if (rm) lines.push(`REFRESH_METHOD="${rm}"`);
    const svc = v('SOURCE_SERVICE'); if (svc) lines.push(`SOURCE_SERVICE="${svc}"`);
    const rch = v('RMAN_CHANNELS'); if (rch) lines.push(`RMAN_CHANNELS="${rch}"`);
  }

  const lf = v('LOGFILE'); if (lf) lines.push(``, `# Logging`, `LOGFILE="${lf}"`);

  return lines.join('\n');
}

// ── run_sparseclone.sh generator ─────────────────────────────────────────────
// Writes the Docker-local SSH wrapper to APP_DIR/run_sparseclone.sh.
// Returns null on success, or an error string on failure.
function _generateRunScript() {
  try {
    const ssh = readSshSettings();
    if (!ssh.sshHost || !ssh.sshUser) {
      return 'SSH host and user must be configured in Server & Connection settings';
    }

    const remoteScript = (ssh.scriptDir || '/home/oracle/sparseclone').replace(/\/$/, '')
      + '/exadata_sparseclone_create_v6.sh';
    const sshPort  = ssh.sshPort && String(ssh.sshPort) !== '22' ? `-p ${ssh.sshPort}` : '';
    const sshKey   = ssh.sshKey  ? `-i "${ssh.sshKey}"` : '';
    const sshOpts  = [
      '-o StrictHostKeyChecking=no',
      '-o ConnectTimeout=15',
      '-o BatchMode=yes',
      '-o LogLevel=ERROR',
      '-o ServerAliveInterval=30',
      '-o ServerAliveCountMax=3',
      '-o KexAlgorithms=ecdh-sha2-nistp256,curve25519-sha256,diffie-hellman-group14-sha256',
      sshPort, sshKey,
    ].filter(Boolean).join(' ');

    // Remote config path = scriptDir/sparse_clone.conf (always SCP'd there by deployAll)
    const remoteConf = (ssh.scriptDir || '/home/oracle/sparseclone').replace(/\/$/, '') + '/sparse_clone.conf';

    const script = [
      '#!/bin/bash',
      '# run_sparseclone.sh — Docker-local SSH wrapper',
      '# Auto-generated by SparseClone Manager on ' + new Date().toISOString(),
      '# Executes exadata_sparseclone_create_v6.sh on the target Exadata via SSH.',
      '',
      'set -euo pipefail',
      '',
      '# Parse extra flags (--refresh etc.) — --config consumed; remote path is baked in',
      'EXTRA_FLAGS=""',
      'while [[ $# -gt 0 ]]; do',
      '  case "$1" in',
      '    --config) shift 2 ;;',
      '    *)        EXTRA_FLAGS="$EXTRA_FLAGS $1"; shift ;;',
      '  esac',
      'done',
      '',
      `SSH_TARGET="${ssh.sshUser}@${ssh.sshHost}"`,
      `REMOTE_SCRIPT="${remoteScript}"`,
      `REMOTE_CONFIG="${remoteConf}"`,
      `SSH_BIN="$(command -v ssh || echo /usr/bin/ssh)"`,
      '',
      // CONF_FLAGS intentionally empty — SCRIPT_FLAGS must not be baked in at generation
      // time because the default conf may have --step N from a single-step run.
      // Flags are always passed via EXTRA_FLAGS by the caller instead.
      'CONF_FLAGS=""',
      '',
      'echo "[INFO] SSH target   : $SSH_TARGET"',
      'echo "[INFO] Remote script: $REMOTE_SCRIPT"',
      'echo "[INFO] Remote config: $REMOTE_CONFIG"',
      // SCRIPT_FLAGS echo removed — CONF_FLAGS is always empty
      '[[ -n "$EXTRA_FLAGS" ]] && echo "[INFO] Extra flags  : $EXTRA_FLAGS"',
      `echo "[CMD] ssh ${sshOpts} -tt $SSH_TARGET /bin/bash $REMOTE_SCRIPT --config $REMOTE_CONFIG $CONF_FLAGS$EXTRA_FLAGS"`,
      '',
      `exec "$SSH_BIN" ${sshOpts} -tt "$SSH_TARGET" /bin/bash "$REMOTE_SCRIPT" --config "$REMOTE_CONFIG" $CONF_FLAGS$EXTRA_FLAGS`,
    ].join('\n');

    fs.writeFileSync(RUN_SCRIPT_FILE, script, { mode: 0o755 });
    console.log(`[RUN] Generated run_sparseclone.sh → ${RUN_SCRIPT_FILE}`);
    return null;
  } catch (err) {
    console.error('[RUN] Failed to generate run_sparseclone.sh:', err.message);
    return err.message;
  }
}

// Also expose as an API endpoint so deploy can trigger it
// (called automatically on execute if missing, or explicitly via /api/run/generate-script)


//  HTTP helpers 
function sendJson(res, data, status = 200) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type':  'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Access-Control-Allow-Origin': '*',
  });
  res.end(body);
}

function sendOk(res, extra = {}) {
  sendJson(res, { ok: true, ...extra });
}

function sendError(res, msg, status = 400) {
  sendJson(res, { ok: false, error: msg }, status);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => { data += chunk; if (data.length > 1e6) req.destroy(); });
    req.on('end',  () => { try { resolve(data ? JSON.parse(data) : {}); } catch { resolve({}); } });
    req.on('error', reject);
  });
}

function readBodyBinary(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end',  () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

//  SSH helper 
function sshCmd(cfg, remoteCmd) {
  // Returns a shell command string for ssh execution  uses resolved SSH_BIN full path
  const keyPart = cfg.sshKey ? `-i "${cfg.sshKey}"` : '';
  const portPart = cfg.sshPort && cfg.sshPort !== 22 ? `-p ${cfg.sshPort}` : '';
  return `"${SSH_BIN}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o KexAlgorithms=ecdh-sha2-nistp256,curve25519-sha256,diffie-hellman-group14-sha256 ${keyPart} ${portPart} ${cfg.sshUser}@${cfg.sshHost} "${remoteCmd.replace(/"/g, '\\"')}"`;
}

function scpCmd(cfg, localFile, remotePath) {
  const keyPart = cfg.sshKey ? `-i "${cfg.sshKey}"` : '';
  const portPart = cfg.sshPort && cfg.sshPort !== 22 ? `-P ${cfg.sshPort}` : '';
  return `"${SCP_BIN}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o KexAlgorithms=ecdh-sha2-nistp256,curve25519-sha256,diffie-hellman-group14-sha256 ${keyPart} ${portPart} "${localFile}" ${cfg.sshUser}@${cfg.sshHost}:"${remotePath}"`;
}

// Full PATH so ssh/scp are found inside Docker/Alpine containers
const EXEC_ENV = {
  ...process.env,
  PATH: '/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin:' + (process.env.PATH || ''),
};

// Resolve ssh/scp binary  Alpine puts them in /usr/bin
function findBin(name) {
  const candidates = ['/usr/bin/' + name, '/usr/local/bin/' + name, '/bin/' + name];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch {}
  }
  return name; // fallback  let shell find it
}

const SSH_BIN = findBin('ssh');
const SCP_BIN = findBin('scp');

function execCmd(cmd) {
  return new Promise((resolve) => {
    const { exec } = require('child_process');
    exec(cmd, { timeout: 30000, env: EXEC_ENV }, (err, stdout, stderr) => {
      resolve({ ok: !err, stdout: stdout || '', stderr: stderr || '', code: err ? (err.code || 1) : 0 });
    });
  });
}

//  Request handler 
async function handleRequest(req, res) {
  const { pathname } = url.parse(req.url);
  const p = (pathname || '/').replace(/\/$/, '') || '/';
  const method = req.method.toUpperCase();

  // CORS pre-flight
  if (method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin':  '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    return res.end();
  }

  //  Scheduler daemon start/stop (handled locally — not proxied)
  if (p === '/api/scheduler/start' && method === 'POST') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    startSchedulerDaemon(res);
    return;
  }
  if (p === '/api/scheduler/stop' && method === 'POST') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    stopSchedulerDaemon(res);
    return;
  }

  //  Proxy /api/scheduler/* → Python sparseclone_scheduler.py daemon
  if (p.startsWith('/api/scheduler/') || p.startsWith('/api/scheduler')) {
    const bodyBuf = method === 'POST' ? await readBodyBinary(req) : null;
    return proxyToScheduler(req, res, bodyBuf);
  }

  // Parse body once. For binary uploads keep raw buffer; otherwise parse JSON.
  let body = {};
  let _rawBodyBuf = null;
  if (method === 'POST') {
    const ct = req.headers['content-type'] || '';
    if (ct.includes('application/octet-stream')) {
      _rawBodyBuf = await readBodyBinary(req);
    } else {
      try { body = await readBody(req); } catch { body = {}; }
    }
  }

  // ── Auth endpoints (no session required for login/register-first/status) ────
  if (p === '/api/auth/status') {
    const token = getTokenFromReq(req);
    const sess  = getSession(token);
    const users = readUsers();
    return sendJson(res, {
      loggedIn:    !!sess,
      username:    sess ? sess.username : null,
      role:        sess ? sess.role : null,
      needsSetup:  users.length === 0,
    });
  }

  if (p === '/api/auth/login' && method === 'POST') {
    const { username, password } = body;
    if (!username || !password) return sendError(res, 'Username and password required');
    const users = readUsers();
    const user  = users.find(u => u.username.toLowerCase() === username.toLowerCase());
    if (!user || !verifyPassword(password, user.hash, user.salt)) {
      return sendJson(res, { ok: false, error: 'Invalid credentials' }, 401);
    }
    // Update lastLogin
    user.lastLogin = new Date().toISOString();
    writeUsers(users);
    const token = createSession(user.username, user.role);
    res.setHeader('Set-Cookie', `sc_session=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800`);
    return sendOk(res, { username: user.username, role: user.role, token });
  }

  if (p === '/api/auth/logout' && method === 'POST') {
    const token = getTokenFromReq(req);
    destroySession(token);
    res.setHeader('Set-Cookie', 'sc_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
    return sendOk(res, { message: 'Logged out' });
  }

  if (p === '/api/auth/register-first' && method === 'POST') {
    // Only allowed when no users exist yet (first-run bootstrap)
    const users = readUsers();
    if (users.length > 0) return sendJson(res, { ok: false, error: 'Setup already complete. Use admin panel to add users.' }, 403);
    const { username, password, confirmPassword } = body;
    if (!username || !password) return sendError(res, 'Username and password required');
    if (password !== confirmPassword) return sendError(res, 'Passwords do not match');
    if (password.length < 8) return sendError(res, 'Password must be at least 8 characters');
    if (!/^[a-zA-Z0-9_.-]{3,32}$/.test(username)) return sendError(res, 'Username must be 3–32 alphanumeric characters');
    const { hash, salt } = hashPassword(password);
    writeUsers([{ username, hash, salt, role: 'admin', createdAt: new Date().toISOString(), lastLogin: null }]);
    const token = createSession(username, 'admin');
    res.setHeader('Set-Cookie', `sc_session=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800`);
    console.log('[AUTH] First admin account created:', username);
    return sendOk(res, { username, role: 'admin', token });
  }

  if (p === '/api/auth/change-password' && method === 'POST') {
    const sess = requireAuth(req, res);
    if (!sess) return;
    const { currentPassword, newPassword, confirmPassword } = body;
    if (!currentPassword || !newPassword) return sendError(res, 'Current and new passwords required');
    if (newPassword !== confirmPassword) return sendError(res, 'Passwords do not match');
    if (newPassword.length < 8) return sendError(res, 'Password must be at least 8 characters');
    const users = readUsers();
    const user  = users.find(u => u.username === sess.username);
    if (!user || !verifyPassword(currentPassword, user.hash, user.salt)) {
      return sendJson(res, { ok: false, error: 'Current password is incorrect' }, 401);
    }
    const { hash, salt } = hashPassword(newPassword);
    user.hash = hash; user.salt = salt;
    writeUsers(users);
    return sendOk(res, { message: 'Password changed successfully' });
  }

  // ── Admin-only user management ────────────────────────────────────────────
  if (p === '/api/users' && method === 'GET') {
    if (!requireAdmin(req, res)) return;
    const users = readUsers().map(u => ({ username: u.username, role: u.role, createdAt: u.createdAt, lastLogin: u.lastLogin }));
    return sendJson(res, users);
  }

  if (p === '/api/users/create' && method === 'POST') {
    if (!requireAdmin(req, res)) return;
    const { username, password, role = 'viewer' } = body;
    if (!username || !password) return sendError(res, 'Username and password required');
    if (password.length < 8) return sendError(res, 'Password must be at least 8 characters');
    if (!/^[a-zA-Z0-9_.-]{3,32}$/.test(username)) return sendError(res, 'Username must be 3–32 alphanumeric characters');
    if (!['admin', 'viewer'].includes(role)) return sendError(res, 'Role must be admin or viewer');
    const users = readUsers();
    if (users.find(u => u.username.toLowerCase() === username.toLowerCase())) {
      return sendError(res, 'Username already exists');
    }
    const { hash, salt } = hashPassword(password);
    users.push({ username, hash, salt, role, createdAt: new Date().toISOString(), lastLogin: null });
    writeUsers(users);
    console.log('[AUTH] User created:', username, 'role:', role);
    return sendOk(res, { username, role });
  }

  if (p === '/api/users/update' && method === 'POST') {
    const sess = requireAdmin(req, res);
    if (!sess) return;
    const { username, role, newPassword, confirmPassword } = body;
    if (!username) return sendError(res, 'username required');
    const users = readUsers();
    const user  = users.find(u => u.username === username);
    if (!user) return sendError(res, 'User not found');
    // Prevent demoting the last admin
    if (role && role !== 'admin' && user.role === 'admin') {
      const adminCount = users.filter(u => u.role === 'admin').length;
      if (adminCount <= 1) return sendError(res, 'Cannot demote the last admin');
    }
    if (role) user.role = role;
    if (newPassword) {
      if (newPassword !== confirmPassword) return sendError(res, 'Passwords do not match');
      if (newPassword.length < 8) return sendError(res, 'Password must be at least 8 characters');
      const { hash, salt } = hashPassword(newPassword);
      user.hash = hash; user.salt = salt;
    }
    writeUsers(users);
    return sendOk(res, { username: user.username, role: user.role });
  }

  if (p === '/api/users/delete' && method === 'POST') {
    const sess = requireAdmin(req, res);
    if (!sess) return;
    const { username } = body;
    if (!username) return sendError(res, 'username required');
    if (username === sess.username) return sendError(res, 'Cannot delete your own account');
    const users   = readUsers();
    const target  = users.find(u => u.username === username);
    if (!target) return sendError(res, 'User not found');
    if (target.role === 'admin' && users.filter(u => u.role === 'admin').length <= 1) {
      return sendError(res, 'Cannot delete the last admin account');
    }
    writeUsers(users.filter(u => u.username !== username));
    console.log('[AUTH] User deleted:', username, 'by:', sess.username);
    return sendOk(res, { deleted: username });
  }

  //  GET routes 
  if (method === 'GET') {

    if (p === '/api/profiles') {
      return sendJson(res, readProfiles());
    }

    // Returns { profileName: "/abs/path/to/profile.conf", ... } for all known profiles
    if (p === '/api/profiles/conf-paths') {
      const profiles = readProfiles();
      const result = {};
      Object.keys(profiles).forEach(name => { result[name] = profileConfPath(name); });
      return sendJson(res, result);
    }

    if (p === '/api/schedules') {
      const data = readJson(SCHEDULES_FILE, []);
      return sendJson(res, Array.isArray(data) ? data : []);
    }

    //  Run status 
    if (p === '/api/run/status') {
      const ssh = readSshSettings();
      return sendJson(res, {
        running:      _runState.running,
        pid:          _runState.pid,
        startedAt:    _runState.startedAt,
        exitCode:     _runState.exitCode,
        logLines:     _runState.log.length,
        confExists:   fs.existsSync(CONF_FILE),
        scriptExists: fs.existsSync(SCRIPT_FILE),
        mode:         ssh.mode || 'local',
        sshHost:      ssh.sshHost || '',
        scriptDir:    ssh.scriptDir || BASE_DIR,
      });
    }

    //  Check script exists (local or remote) 
    if (p === '/api/run/check-script') {
      const ssh = readSshSettings();
      const isSSH = ssh.mode === 'ssh' && ssh.sshHost && ssh.sshUser && ssh.scriptDir;
      if (isSSH) {
        const remotePath = ssh.scriptDir.replace(/\/$/, '') + '/' + path.basename(SCRIPT_FILE);
        const result = await execCmd(sshCmd(ssh, `test -f "${remotePath}" && stat -c "%s bytes" "${remotePath}" && echo EXISTS`));
        const exists = result.stdout.includes('EXISTS');
        const sizeMatch = result.stdout.match(/(\d+ bytes)/);
        return sendJson(res, { exists, path: remotePath, size: sizeMatch ? sizeMatch[1] : null, mode: 'ssh' });
      } else {
        const exists = fs.existsSync(SCRIPT_FILE);
        let size = null;
        if (exists) { try { size = fs.statSync(SCRIPT_FILE).size + ' bytes'; } catch {} }
        return sendJson(res, { exists, path: SCRIPT_FILE, size, mode: 'local' });
      }
    }

    //  SSH settings GET 
    if (p === '/api/ssh/settings') {
      return sendJson(res, readSshSettings());
    }

    //  SSE log stream: GET /api/run/stream 
    if (p === '/api/run/stream') {
      res.writeHead(200, {
        'Content-Type':  'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection':    'keep-alive',
        'Access-Control-Allow-Origin': '*',
      });
      res.flushHeaders();

      // Replay existing log so late-joiners see full history
      _runState.log.forEach(line => res.write(`data: ${JSON.stringify(line)}\n\n`));

      // If job already finished, send done immediately
      if (!_runState.running && _runState.exitCode !== null) {
        res.write(`event: done\ndata: ${JSON.stringify({ exitCode: _runState.exitCode })}\n\n`);
        return res.end();
      }

      // Keep alive ping every 15s
      const ping = setInterval(() => { try { res.write(': ping\n\n'); } catch {} }, 15000);

      _runState.sseClients.push(res);
      req.on('close', () => {
        clearInterval(ping);
        _runState.sseClients = _runState.sseClients.filter(c => c !== res);
      });
      return; // keep connection open
    }

    if (p === '/api/status') {
      return sendJson(res, {
        ok: true,
        server: 'sparseclone_manager.js',
        node: process.version,
        profiles_file:   PROFILES_FILE,
        schedules_file:  SCHEDULES_FILE,
        ssh_file:        SSH_SETTINGS_FILE,
        profiles_exist:  fs.existsSync(PROFILES_FILE),
        schedules_exist: fs.existsSync(SCHEDULES_FILE),
        ssh_exist:       fs.existsSync(SSH_SETTINGS_FILE),
        data_dir:        DATA_DIR,
        app_dir:         APP_DIR,
        profiles_count:  Object.keys(readProfiles()).length,
      });
    }

    if (['/','index.html','/exadata_sparseclone_gui.html'].includes(p)) {
      if (!fs.existsSync(HTML_FILE)) {
        res.writeHead(404); return res.end('HTML file not found: ' + HTML_FILE);
      }
      const html = fs.readFileSync(HTML_FILE);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': html.length });
      return res.end(html);
    }

    res.writeHead(404); return res.end('Not found: ' + p);
  }

  //  POST routes 
  if (method === 'POST') {

    //  Deploy: write myenv.conf to server disk 
    if (p === '/api/run/deploy') {
      const { content, filename } = body;
      if (!content) return sendError(res, 'content is required');
      const destFile = path.join(DATA_DIR, filename || 'sparse_clone.conf');
      if (!destFile.startsWith(DATA_DIR) || !destFile.endsWith('.conf')) {
        return sendError(res, 'Invalid filename — must be a .conf file');
      }
      fs.writeFileSync(destFile, content.replace(/\r\n/g, '\n').replace(/\r/g, '\n'), 'utf8');

      // If SSH mode, also SCP the conf to remote host
      const ssh = readSshSettings();
      if (ssh.mode === 'ssh' && ssh.sshHost && ssh.sshUser && ssh.scriptDir) {
        const remotePath = ssh.scriptDir.replace(/\/$/, '') + '/' + (filename || 'sparse_clone.conf');
        await execCmd(sshCmd(ssh, `mkdir -p "${ssh.scriptDir}"`));
        const result = await execCmd(scpCmd(ssh, destFile, remotePath));
        if (!result.ok) {
          return sendError(res, `Local write OK but SCP failed: ${result.stderr.trim() || result.stdout.trim()}`);
        }
        console.log(`  [DEPLOY] SCP'd ${filename || 'sparse_clone.conf'}  ${ssh.sshUser}@${ssh.sshHost}:${remotePath}`);
        return sendOk(res, { path: remotePath, bytes: content.length, scp: true });
      }

      console.log(`  [DEPLOY] Wrote ${path.basename(destFile)} (${content.length} bytes)`);
      return sendOk(res, { path: destFile, bytes: content.length, scp: false });
    }

    //  Upload / SCP script file 
    if (p === '/api/run/upload-script') {
      const ssh      = readSshSettings();
      const fileName = (body && body.filename) || 'exadata_sparseclone_create_v6.sh';
      if (!fileName.endsWith('.sh')) return sendError(res, 'Only .sh files allowed');

      // serverSide:true  SCP the .sh already on the Node.js host to remote
      if (body && body.serverSide) {
        const localPath = path.join(BASE_DIR, fileName);
        if (!fs.existsSync(localPath)) {
          return sendError(res, `Script not found on server at ${localPath}. Place ${fileName} beside sparseclone_manager.js.`);
        }
        // Strip CRLF on local copy before SCP
        const localBuf = stripCRLF(fs.readFileSync(localPath));
        fs.writeFileSync(localPath, localBuf, { mode: 0o755 });
        if (!ssh.mode || ssh.mode === 'local') {
          return sendOk(res, { ok: true, local: localPath, scp: false, message: 'Local mode — script already on host' });
        }
        const remotePath = ssh.scriptDir.replace(/\/$/, '') + '/' + fileName;
        await execCmd(sshCmd(ssh, `mkdir -p "${ssh.scriptDir}"`));
        const scpResult = await execCmd(scpCmd(ssh, localPath, remotePath));
        if (!scpResult.ok) return sendError(res, `Script SCP failed: ${scpResult.stderr.trim() || 'check SSH key/permissions'}`);
        await execCmd(sshCmd(ssh, `chmod +x "${remotePath}" && sed -i 's/\r//' "${remotePath}"`));
        console.log(`  [SCP] ${fileName} -> ${ssh.sshUser}@${ssh.sshHost}:${remotePath}`);
        return sendOk(res, { ok: true, local: localPath, remote: remotePath, scp: true });
      }

      // Browser binary/base64 upload
      const ct = req.headers['content-type'] || '';
      let fileBuffer;
      if (ct.includes('application/octet-stream')) {
        fileBuffer = _rawBodyBuf;  // already read above
      } else {
        if (!body || !body.content) return sendError(res, 'No file content  use serverSide:true or provide base64 content');
        fileBuffer = Buffer.from(body.content, 'base64');
      }
      // Strip Windows CRLF line endings before saving
      fileBuffer = stripCRLF(fileBuffer);
      const destPath = path.join(BASE_DIR, fileName);
      fs.writeFileSync(destPath, fileBuffer, { mode: 0o755 });
      if (ssh.mode === 'ssh' && ssh.sshHost && ssh.sshUser && ssh.scriptDir) {
        const remotePath = ssh.scriptDir.replace(/\/$/, '') + '/' + fileName;
        await execCmd(sshCmd(ssh, `mkdir -p "${ssh.scriptDir}"`));
        const scpResult = await execCmd(scpCmd(ssh, destPath, remotePath));
        if (!scpResult.ok) return sendError(res, `Upload OK but SCP failed: ${scpResult.stderr.trim()}`);
        await execCmd(sshCmd(ssh, `chmod +x "${remotePath}" && sed -i 's/\r//' "${remotePath}"`));
        return sendOk(res, { ok: true, local: destPath, remote: remotePath, bytes: fileBuffer.length, scp: true });
      }
      return sendOk(res, { ok: true, local: destPath, bytes: fileBuffer.length, scp: false });
    }

    //  Save SSH settings 
    // check myenv.conf on target
    if (p === '/api/run/check-conf') {
      const ssh      = readSshSettings();
      const confName = 'sparse_clone.conf';
      if (ssh.mode === 'ssh' && ssh.sshHost && ssh.sshUser && ssh.scriptDir) {
        const remotePath = ssh.scriptDir.replace(/\/$/, '') + '/' + confName;
        const result = await execCmd(sshCmd(ssh, `test -f "${remotePath}" && stat -c "%s bytes" "${remotePath}" && echo EXISTS`));
        const exists = result.stdout.includes('EXISTS');
        const sizeMatch = result.stdout.match(/(\d+ bytes)/);
        return sendJson(res, { exists, path: remotePath, size: sizeMatch ? sizeMatch[1] : null, mode: 'ssh' });
      }
      const confPath = path.join(BASE_DIR, confName);
      const exists   = fs.existsSync(confPath);
      let size = null;
      if (exists) { try { size = fs.statSync(confPath).size + ' bytes'; } catch {} }
      return sendJson(res, { exists, path: confPath, size, mode: 'local' });
    }

    // ls -ltr on target directory
    if (p === '/api/run/ls-target') {
      const dir   = (body && body.dir)   || '';
      const local = (body && body.local) || false;
      if (!dir) return sendError(res, 'dir is required');
      if (local) {
        const result = await execCmd(`ls -ltr "${dir}" 2>&1`);
        const lines  = (result.stdout || '').split('\n').filter(l => l.trim() && !l.startsWith('total'));
        return sendOk(res, { lines, mode: 'local' });
      }
      const ssh = readSshSettings();
      if (!ssh.sshHost || !ssh.sshUser) return sendError(res, 'SSH not configured');
      const result = await execCmd(sshCmd(ssh, `ls -ltr "${dir}" 2>&1`));
      const lines  = (result.stdout || '').split('\n').filter(l => l.trim() && !l.startsWith('total'));
      if (!result.ok && lines.length === 0)
        return sendOk(res, { ok: false, lines: [], error: result.stderr.trim() || 'ls failed or directory not found' });
      return sendOk(res, { lines, mode: 'ssh' });
    }

    if (p === '/api/ssh/save') {
      const allowed = ['mode','sshHost','sshPort','sshUser','sshKey','scriptDir'];
      const settings = {};
      allowed.forEach(k => { if (body[k] !== undefined) settings[k] = body[k]; });
      writeJson(SSH_SETTINGS_FILE, settings);
      console.log(`  [SSH] Settings saved: mode=${settings.mode} host=${settings.sshHost || 'local'}`);
      // Auto-regenerate the wrapper script with updated SSH settings
      _generateRunScript();
      return sendOk(res, { settings });
    }

    //  Test SSH connection 
    if (p === '/api/ssh/test') {
      const ssh = body;
      if (!ssh.sshHost || !ssh.sshUser) return sendError(res, 'sshHost and sshUser are required');
      const result = await execCmd(sshCmd(ssh, 'echo OK && hostname && whoami'));
      console.log(`  [SSH] Test  ${ssh.sshUser}@${ssh.sshHost} : ${result.ok ? 'OK' : 'FAIL'}`);
      return sendJson(res, {
        ok:     result.ok,
        output: (result.stdout + result.stderr).trim(),
        code:   result.code,
      });
    }

    //  Execute: run the script with --config <confFile> (Docker→SSH model) 
    if (p === '/api/run/execute') {
      if (_runState.running) return sendError(res, 'A job is already running. Abort it first.');

      // Auto-generate run_sparseclone.sh if it doesn't exist yet
      if (!fs.existsSync(RUN_SCRIPT_FILE)) {
        const genErr = _generateRunScript();
        if (genErr) return sendError(res, `Cannot generate run_sparseclone.sh: ${genErr}`);
      }

      // Resolve config file: use body.confFile if provided, else default
      const { confFile: reqConf, extraFlags } = body || {};
      const confArg = (reqConf && typeof reqConf === 'string' && reqConf.trim())
        ? reqConf.trim()
        : CONF_FILE;

      if (!fs.existsSync(confArg)) {
        return sendError(res, `Config not found: ${path.basename(confArg)} — deploy config first`);
      }

      // Build log file path: runs/<timestamp>_manual.log
      const ts = new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19);
      const runLogFile = path.join(RUN_LOG_DIR, `${ts}_manual.log`);

      // Reset run state
      _runState.running   = true;
      _runState.child     = null;
      _runState.pid       = null;
      _runState.startedAt = new Date().toISOString();
      _runState.exitCode  = null;
      _runState.log       = [];
      _runState.logFile   = runLogFile;

      // Write log header
      pushLog(`[${_runState.startedAt}] Manual run started`);
      pushLog(`[INFO] Script : ${RUN_SCRIPT_FILE}`);
      pushLog(`[INFO] Config : ${confArg}`);
      pushLog(`[INFO] Log    : ${runLogFile}`);

      const args = ['--config', confArg];
      if (Array.isArray(extraFlags) && extraFlags.length) args.push(...extraFlags);
      pushLog(`[CMD] /bin/bash run_sparseclone.sh ${args.join(' ')}`);

      let child;
      try {
        child = spawn('/bin/bash', [RUN_SCRIPT_FILE, ...args], {
          cwd: APP_DIR,
          env: { ...EXEC_ENV, TERM: 'xterm' },
          stdio: ['ignore', 'pipe', 'pipe'],
        });
      } catch (spawnErr) {
        _runState.running  = false;
        _runState.exitCode = -1;
        pushLog(`[ERROR] Failed to spawn process: ${spawnErr.message}`);
        return sendError(res, `Failed to start script: ${spawnErr.message}`);
      }

      _runState.child = child;
      _runState.pid   = child.pid;
      pushLog(`[INFO] PID: ${child.pid}`);

      child.stdout.on('data', d => d.toString().split('\n').filter(l => l).forEach(pushLog));
      child.stderr.on('data', d => d.toString().split('\n').filter(l => l).forEach(l => pushLog(`[ERR] ${l}`)));

      child.on('error', err => {
        // Process could not be started (e.g. permission denied)
        _runState.running  = false;
        _runState.exitCode = -1;
        pushLog(`[ERROR] Process error: ${err.message}`);
        _runState.sseClients.forEach(c => {
          try { c.write(`event: done\ndata: ${JSON.stringify({ exitCode: -1 })}\n\n`); c.end(); } catch {}
        });
        _runState.sseClients = [];
      });

      child.on('close', code => {
        _runState.running  = false;
        _runState.exitCode = code;
        const status = code === 0 ? 'SUCCESS' : `FAILED (exit ${code})`;
        pushLog(`[${new Date().toISOString()}] Process exited — ${status}`);
        _runState.sseClients.forEach(c => {
          try { c.write(`event: done\ndata: ${JSON.stringify({ exitCode: code })}\n\n`); c.end(); } catch {}
        });
        _runState.sseClients = [];
      });

      return sendOk(res, { pid: _runState.pid, startedAt: _runState.startedAt, mode: 'docker-ssh', logFile: runLogFile });
    }

    //  Generate run_sparseclone.sh from current SSH settings 
    if (p === '/api/run/generate-script' && method === 'POST') {
      const genErr = _generateRunScript();
      if (genErr) return sendError(res, genErr);
      return sendOk(res, { path: RUN_SCRIPT_FILE, message: 'run_sparseclone.sh generated successfully' });
    }

    //  Abort: kill the running job 
    if (p === '/api/run/abort') {
      if (!_runState.running || !_runState.child) return sendError(res, 'No job is running');
      try {
        const killedPid = _runState.child.pid;
        process.kill(killedPid, 'SIGTERM');
        // Mark as not running immediately so a re-trigger isn't blocked
        _runState.running = false;
        pushLog(`[${new Date().toISOString()}] [ABORT] SIGTERM sent to PID ${killedPid} — awaiting exit`);
        return sendOk(res, { pid: killedPid });
      } catch(e) { return sendError(res, 'Could not kill process: ' + e.message); }
    }

    //  Save schedules array 
    if (p === '/api/schedules/save') {
      const { schedules } = body;
      if (!Array.isArray(schedules)) return sendError(res, 'schedules must be an array');
      // Stamp confFile from the named profile at save time so the scheduler
      // always deploys the correct .conf file, not whatever was last written
      // to the shared sparse_clone.conf (which caused wrong-profile deployments).
      const stamped = schedules.map(s => {
        const profileName = (s.environmentProfile || '').trim();
        if (profileName) {
          const resolvedConf = profileConfPath(profileName);
          if (s.confFile !== resolvedConf) {
            console.log(`  [SCHED] Stamping confFile for "${s.name}": ${resolvedConf}`);
          }
          return { ...s, confFile: resolvedConf };
        }
        return s;
      });
      writeJson(SCHEDULES_FILE, stamped);
      console.log(`  [SCHED] Saved ${stamped.length} schedule(s)`);
      return sendOk(res, { count: stamped.length });
    }

    if (p === '/api/profiles/save') {
      const { name, data } = body;
      if (!name || typeof name !== 'string' || !name.trim()) return sendError(res, 'Profile name is required');
      if (data === undefined || data === null) return sendError(res, 'Profile data is required');
      const profiles = readProfiles();
      profiles[name.trim()] = data;
      writeJson(PROFILES_FILE, profiles);
      // Generate and write the companion .conf file for this profile
      const confPath    = profileConfPath(name.trim());
      const confContent = generateConfFromProfile(name.trim(), data);
      fs.writeFileSync(confPath, confContent, 'utf8');
      console.log(`  [SAVE] profile "${name}"  ${path.basename(PROFILES_FILE)}`);
      console.log(`  [CONF] wrote ${confPath}`);
      return sendOk(res, { profiles, confPath });
    }

    if (p === '/api/profiles/delete') {
      const { name } = body;
      if (!name || typeof name !== 'string') return sendError(res, 'Profile name is required');
      const profiles = readProfiles();
      delete profiles[name.trim()];
      writeJson(PROFILES_FILE, profiles);
      // Remove companion .conf file if it exists
      const confPath = profileConfPath(name.trim());
      try { if (fs.existsSync(confPath)) fs.unlinkSync(confPath); } catch {}
      console.log(`  [DEL]  profile "${name}"  ${path.basename(PROFILES_FILE)}`);
      return sendOk(res, { profiles });
    }

    if (p === '/api/schedules/save') {
      const { schedules } = body;
      if (!Array.isArray(schedules)) return sendError(res, 'schedules must be an array');
      writeJson(SCHEDULES_FILE, schedules);
      console.log(`  [SAVE] ${schedules.length} schedule(s)  ${path.basename(SCHEDULES_FILE)}`);
      return sendOk(res);
    }

    return sendError(res, 'Unknown endpoint: ' + p, 404);
  }

  res.writeHead(405); res.end('Method not allowed');
}

//  Open browser 
function openBrowser(url) {
  const cmd = process.platform === 'win32'  ? `start "" "${url}"` :
              process.platform === 'darwin' ? `open "${url}"` :
              `xdg-open "${url}" 2>/dev/null || true`;
  try { execSync(cmd, { stdio: 'ignore' }); } catch { /* ignore */ }
}

//  Banner 
function printBanner(serverUrl) {
  const pad = s => s.padEnd(41);
  console.log('');
  console.log('  ');
  console.log('         Exadata SparseClone Manager  Server           ');
  console.log('  ');
  console.log(`    URL      : ${pad(serverUrl)}`);
  console.log(`    HTML     : ${pad(path.basename(HTML_FILE))}`);
  console.log(`    Script   : ${pad(path.basename(SCRIPT_FILE))}`);
  console.log(`    Profiles : ${pad(path.basename(PROFILES_FILE))}`);
  console.log(`    Node.js  : ${pad(process.version)}`);
  console.log('  ');
  console.log('    API: /api/run/deploy    write myenv.conf                  ');
  console.log('    API: /api/run/execute   run script                 ');
  console.log('    API: /api/run/stream    SSE live log               ');
  console.log('    API: /api/run/abort     kill job                   ');
  console.log('  ');
  console.log('    Press Ctrl+C to stop                                ');
  console.log('  ');
  console.log('');
}

//  Main 
if (!fs.existsSync(HTML_FILE)) {
  console.error(`\n  ERROR: HTML file not found:\n    ${HTML_FILE}`);
  console.error(`\n  Make sure 'exadata_sparseclone_gui.html' is in the same directory.\n`);
  process.exit(1);
}

// Seed empty data files on first run so GET endpoints never 404.
// Never overwrites files that already exist on disk.
function seedDataFiles() {
  console.log(`  [SEED] Data dir: ${DATA_DIR}`);
  const stamp = (file, label) => {
    const exists = fs.existsSync(file);
    console.log(`  [SEED] ${exists ? 'FOUND  ' : 'missing'} ${label} → ${file}`);
    return exists;
  };
  if (!stamp(PROFILES_FILE,     'profiles    ')) writeJson(PROFILES_FILE,  {});
  if (!stamp(SCHEDULES_FILE,    'schedules   ')) writeJson(SCHEDULES_FILE, []);
  if (!stamp(SSH_SETTINGS_FILE, 'ssh settings')) writeJson(SSH_SETTINGS_FILE, { mode: 'local' });
}
seedDataFiles();

// Normalize SSH settings: scheduler.py may write slightly different keys.
// Returns a consistent object with all expected keys.
function readSshSettings() {
  const raw = readJson(SSH_SETTINGS_FILE, { mode: 'local' });
  // scheduler.py stores under same keys as manager — just return as-is with defaults
  return {
    mode:      raw.mode      || 'local',
    sshHost:   raw.sshHost   || raw.ssh_host   || '',
    sshPort:   raw.sshPort   || raw.ssh_port   || 22,
    sshUser:   raw.sshUser   || raw.ssh_user   || 'oracle',
    sshKey:    raw.sshKey    || raw.ssh_key    || '',
    scriptDir: raw.scriptDir || raw.script_dir || '',
  };
}
// Always returns a flat map and re-saves the file in flat format for consistency.
function readProfiles() {
  const raw = readJson(PROFILES_FILE, {});
  if (raw && typeof raw.profiles === 'object' && !Array.isArray(raw.profiles)) {
    const flat = { ...raw.profiles };
    Object.keys(flat).forEach(k => { if (k.startsWith('_')) delete flat[k]; });
    console.log(`  [PROFILES] Unwrapped nested format, found ${Object.keys(flat).length} profile(s)`);
    writeJson(PROFILES_FILE, flat);
    return flat;
  }
  const flat = { ...raw };
  Object.keys(flat).forEach(k => { if (k.startsWith('_')) delete flat[k]; });
  return flat;
}

const server = http.createServer((req, res) => {
  handleRequest(req, res).catch(err => {
    console.error('  [ERR]', err.message);
    try { sendError(res, 'Internal server error', 500); } catch { /* already sent */ }
  });
});

const serverUrl = `http://${HOST}:${PORT}`;

ensureDefaultAdmin();

// Auto-regenerate run_sparseclone.sh on startup if SSH settings are configured
// This ensures the script always reflects current settings after an image rebuild or config change
(function autoRegenRunScript() {
  try {
    const ssh = readSshSettings();
    if (ssh.sshHost && ssh.sshUser) {
      _generateRunScript();
      console.log('  [RUN] run_sparseclone.sh refreshed from SSH settings');
    }
  } catch (e) {
    console.warn('  [RUN] Could not auto-generate run_sparseclone.sh:', e.message);
  }
})();

server.listen(PORT, HOST, () => {
  printBanner(serverUrl);

  if (!NO_BROWSER) {
    console.log(`  Opening browser  ${serverUrl}\n`);
    setTimeout(() => openBrowser(serverUrl), 600);
  }
});

server.on('error', err => {
  if (err.code === 'EADDRINUSE') {
    console.error(`\n  ERROR: Port ${PORT} is already in use.`);
    console.error(`  Try:  node sparseclone_manager.js --port 8080\n`);
  } else {
    console.error('\n  Server error:', err.message);
  }
  process.exit(1);
});

process.on('SIGINT',  () => { console.log('\n\n  Server stopped.\n'); process.exit(0); });
process.on('SIGTERM', () => { process.exit(0); });
