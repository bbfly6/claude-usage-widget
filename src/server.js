const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');
const crypto = require('crypto');
const { exec } = require('child_process');

const PORT = 19522;
const HOST = '127.0.0.1';

// 푸터 버전 표기용. index.html에 하드코딩하면 릴리스마다 어긋난다 (260821 실측: 1.1.0인데 화면은 1.0.0).
let APP_VERSION = '';
try { APP_VERSION = require('../package.json').version; } catch { APP_VERSION = ''; }
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';

// ===== Security: session token =====
// Generated at startup, required in cookie for all API requests.
//
// 무엇을 막는가: 브라우저에 떠 있는 외부 웹사이트가 이 API를 호출하는 것.
//   교차 출처라 응답도 쿠키도 읽을 수 없고, Host 헤더 검사로 DNS rebinding 도 막힌다.
// 무엇을 막지 못하는가: 같은 PC의 다른 로컬 프로세스.
//   `/` 를 요청하면 누구나 Set-Cookie 로 토큰을 받아갈 수 있다.
//   다만 API가 돌려주는 것은 사용률 퍼센트뿐이고, 인증 토큰은 어떤 응답에도 포함되지 않는다.
//   (토큰은 Anthropic 요청의 Authorization 헤더로만 쓰인다)
const SESSION_TOKEN = crypto.randomBytes(32).toString('hex');

// Allowed Host header values (prevent DNS rebinding attacks)
const ALLOWED_HOSTS = new Set([
  `127.0.0.1:${PORT}`,
  `localhost:${PORT}`,
]);

// Static files allowlist — only these can be served
const STATIC_DIR = path.resolve(__dirname);
const ALLOWED_STATIC = new Set([
  'index.html',
  'style.css',
  'renderer.js',
]);

// ===== Credentials (READ-ONLY) =====
// Widget never writes or refreshes. Claude Code owns the refresh flow.
function readCredentials() {
  const credPath = path.join(os.homedir(), '.claude', '.credentials.json');
  try {
    const data = fs.readFileSync(credPath, 'utf-8');
    const json = JSON.parse(data);
    const oauth = json.claudeAiOauth;
    if (!oauth || !oauth.accessToken) return null;
    return oauth;
  } catch { return null; }
}

// 인증 파일의 subscriptionType 이 실제 플랜이다.
// 사용량 API 응답에는 플랜·티어를 알려주는 필드가 아예 없다 (260824 실측).
// 예전엔 'Max' 를 하드코딩해서 Pro 사용자에게도 Max 로 표시됐다.
const PLAN_LABEL = { max: 'Max', pro: 'Pro', team: 'Team', enterprise: 'Enterprise', free: 'Free' };
function planLabel(creds) {
  const t = (creds && creds.subscriptionType || '').toLowerCase();
  if (!t) return '';
  return PLAN_LABEL[t] || (t.charAt(0).toUpperCase() + t.slice(1));
}

// accessToken 만료 여부. 위젯은 토큰을 갱신하지 않으므로(Claude Code 담당)
// 만료되면 사용자가 다시 로그인하는 것 외에 방법이 없다.
function isExpired(creds) {
  if (!creds || typeof creds.expiresAt !== 'number') return false;
  return Date.now() >= creds.expiresAt;
}

// ===== HTTPS helper =====
function httpsRequest(url, options, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const opts = {
      hostname: u.hostname,
      path: u.pathname + u.search,
      // Enforce TLS verification (default, but make explicit)
      rejectUnauthorized: true,
      ...options,
    };
    const req = https.request(opts, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.setTimeout(15000, () => { req.destroy(); reject(new Error('Timeout')); });
    if (body) req.write(body);
    req.end();
  });
}

// limits[] 에서 모델 스코프 주간 한도를 꺼낸다.
// 해당 항목이 없으면 화면에서 행 자체를 숨기도록 name 을 빈 값으로 둔다.
function readScopedLimit(j) {
  const list = Array.isArray(j.limits) ? j.limits : [];
  const scoped = list.find((l) => l && l.kind === 'weekly_scoped');
  if (!scoped) return { scopedModelName: '', scopedModelPercent: 0 };
  return {
    scopedModelName: scoped.scope?.model?.display_name || '',
    scopedModelPercent: scoped.percent || 0,
  };
}

// ===== Fetch usage (READ-ONLY) =====
async function fetchUsage() {
  const creds = readCredentials();
  if (!creds) return { error: 'NO_CREDENTIALS' };

  const res = await httpsRequest(USAGE_URL, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${creds.accessToken}`,
      'anthropic-beta': 'oauth-2025-04-20',
      Accept: 'application/json',
    },
  });

  if (res.status === 401 || res.status === 403) {
    return { error: 'TOKEN_EXPIRED' };
  }
  if (res.status === 429) {
    return { error: 'RATE_LIMITED' };
  }
  if (res.status !== 200) return { error: `HTTP ${res.status}` };

  const j = JSON.parse(res.body);
  const usage = {
    isConnected: true,
    sessionUsagePercent: j.five_hour?.utilization || 0,
    sessionResetSeconds: j.five_hour?.resets_at
      ? Math.max(0, Math.floor((new Date(j.five_hour.resets_at) - Date.now()) / 1000)) : 0,
    weeklyAllModelsPercent: j.seven_day?.utilization || 0,
    // 포맷은 렌더러가 현재 언어로 처리한다 (서버에서 en-US 로 굳히면 한글 UI 에 영어가 섞인다)
    weeklyAllModelsResetAt: j.seven_day?.resets_at || '',
    // 모델 스코프 주간 한도.
    // seven_day_sonnet 은 이 계정에서 항상 null 이라 0% 로만 표시됐다 (260821 실측).
    // 실제 값은 limits[] 의 weekly_scoped 항목에 있고, 모델 이름도 여기서 온다.
    ...readScopedLimit(j),
    // 플랜은 API 가 아니라 인증 파일에서 온다. 알 수 없으면 빈 값 → 화면에서 배지를 숨긴다.
    planName: (() => {
      const base = planLabel(creds);
      if (!base) return '';
      return j.extra_usage?.is_enabled ? `${base} (Extra)` : base;
    })(),
  };
  return usage;
}

// ===== Security helpers =====

function setSecurityHeaders(res) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Content-Security-Policy',
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'");
  // Same-origin only — no CORS
  res.setHeader('Cache-Control', 'no-store');
}

function hasValidSession(req) {
  const cookie = req.headers.cookie || '';
  const match = cookie.match(/claude_widget_session=([a-f0-9]{64})/);
  if (!match) return false;
  // Constant-time comparison to prevent timing attacks
  try {
    const a = Buffer.from(match[1], 'hex');
    const b = Buffer.from(SESSION_TOKEN, 'hex');
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

function hostAllowed(req) {
  const host = req.headers.host || '';
  return ALLOWED_HOSTS.has(host);
}

// ===== MIME types =====
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
};

// ===== HTTP Server =====
const server = http.createServer(async (req, res) => {
  setSecurityHeaders(res);

  // Only allow GET/HEAD (no POST etc. to the local server)
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    res.end('Method Not Allowed');
    return;
  }

  // Reject requests with unknown Host headers (DNS rebinding protection)
  if (!hostAllowed(req)) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('Forbidden');
    return;
  }

  // Parse URL safely (ignore query, only use pathname)
  let pathname;
  try {
    pathname = new URL(req.url, `http://${req.headers.host}`).pathname;
  } catch {
    res.writeHead(400);
    res.end('Bad Request');
    return;
  }

  // Root: inject session cookie and serve index.html
  if (pathname === '/' || pathname === '/index.html') {
    try {
      const content = fs.readFileSync(path.join(STATIC_DIR, 'index.html'));
      res.writeHead(200, {
        'Content-Type': MIME['.html'],
        'Set-Cookie': `claude_widget_session=${SESSION_TOKEN}; Path=/; HttpOnly; SameSite=Strict`,
      });
      res.end(content);
    } catch {
      res.writeHead(500);
      res.end('Internal error');
    }
    return;
  }

  // API endpoints require session token
  if (pathname.startsWith('/api/')) {
    if (!hasValidSession(req)) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Unauthorized' }));
      return;
    }

    if (pathname === '/api/usage') {
      try {
        const data = await fetchUsage();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(data));
      } catch {
        // Do not leak internal error details to client
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Internal error' }));
      }
      return;
    }

    if (pathname === '/api/credentials') {
      // found 만 내려주면 "파일은 있는데 토큰이 만료된" 상태를 구분할 수 없어
      // 로그인 버튼이 숨겨진 채 막다른 길이 된다 (260824 팀원 PC 실측).
      const creds = readCredentials();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        found: !!creds,
        expired: isExpired(creds),
        plan: planLabel(creds),
      }));
      return;
    }

    if (pathname === '/api/version') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ version: APP_VERSION }));
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not found' }));
    return;
  }

  // Static files: strict allowlist (prevents path traversal)
  const filename = path.basename(pathname);
  if (!ALLOWED_STATIC.has(filename)) {
    res.writeHead(404);
    res.end('Not found');
    return;
  }

  const fullPath = path.join(STATIC_DIR, filename);
  // Double-check: resolved path must be inside STATIC_DIR
  if (!fullPath.startsWith(STATIC_DIR + path.sep) && fullPath !== STATIC_DIR) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  try {
    const content = fs.readFileSync(fullPath);
    const ext = path.extname(fullPath);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(content);
  } catch {
    res.writeHead(404);
    res.end('Not found');
  }
});

// 포트를 못 잡으면 진행하지 않고 종료한다.
// 억지로 계속 진행하면 Electron 창이 '그 포트를 점유한 프로세스가 주는 화면'을 로드하게 된다.
// (단일 인스턴스 잠금이 이미 자기 자신은 막으므로, 여기 걸리면 외부 프로세스다)
//
// 다만 그냥 exit 하면 GUI 앱이라 사용자 눈에는 "실행해도 아무 일이 없음" 으로만 보인다.
// 이유를 창으로 알려주고 끝낸다. 그리고 일시적인 점유일 수 있으므로 잠깐 재시도한다.
// (작업관리자 강제 종료 후 즉시 재실행은 260824 실측상 재시도 없이도 정상 —
//  Node 가 SO_REUSEADDR 를 걸어 잔여 소켓이 새 리스닝을 막지 않는다.
//  재시도는 보안 프로그램 등이 순간적으로 포트를 잡는 다른 환경을 위한 여유분이다.)
const LISTEN_RETRY_MAX = 3;
const LISTEN_RETRY_DELAY = 700;
let listenRetries = 0;

function fatal(message) {
  console.error('[FATAL]', message);
  // Electron 메인 프로세스에서 로드된 경우에만 창을 띄운다 (npm run server 단독 실행 시엔 없음)
  try {
    require('electron').dialog.showErrorBox('Claude Usage Widget by R', message);
  } catch { /* Electron 아님 — 콘솔 출력으로 충분 */ }
  process.exit(1);
}

server.on('error', (err) => {
  const code = err && err.code;

  if (code === 'EADDRINUSE' && listenRetries < LISTEN_RETRY_MAX) {
    listenRetries += 1;
    console.error(`[WARN] 포트 ${PORT} 사용 중 — 재시도 ${listenRetries}/${LISTEN_RETRY_MAX}`);
    setTimeout(() => server.listen(PORT, HOST), LISTEN_RETRY_DELAY);
    return;
  }

  // fatal 뒤에는 반드시 return. process.exit 에만 기대면 안 된다 —
  // showErrorBox 가 모달로 블로킹하는 동안 exit 가 즉시 끝나지 않아
  // 아래 일반 분기까지 실행돼 안내창이 두 번 떴다 (260824 실측).
  if (code === 'EADDRINUSE') {
    fatal(
      `다른 프로그램이 포트 ${PORT} 를 사용하고 있어 위젯을 시작할 수 없습니다.\n\n` +
      `위젯이 이미 실행 중인지 확인해 주세요. 화면에 보이지 않아도 작업표시줄 오른쪽 ` +
      `트레이 아이콘으로 숨어 있을 수 있습니다.\n\n` +
      `트레이에도 없다면 PC를 다시 시작한 뒤 실행해 주세요.`
    );
    return;
  }

  fatal(`로컬 서버를 시작하지 못했습니다. (${code || err})`);
});

server.listen(PORT, HOST, () => {
  const url = `http://${HOST}:${PORT}`;
  console.log(`Claude Widget running at ${url}`);
  console.log(`Session locked to this process. Close the browser tab to revoke.`);

  // Open in default browser (Electron 모드에선 NO_AUTO_BROWSER=1로 차단)
  if (process.env.NO_AUTO_BROWSER !== '1') {
    const cmd = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'start' : 'xdg-open';
    exec(`${cmd} "${url}"`);
  }
});

// Graceful shutdown
process.on('SIGINT', () => { server.close(() => process.exit(0)); });
process.on('SIGTERM', () => { server.close(() => process.exit(0)); });
