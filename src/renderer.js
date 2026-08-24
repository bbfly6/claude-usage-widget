// ===== State =====
let userInterval = 600;   // 사용자가 선택한 자동 동기화 간격(초). 기본 10분
let currentDelay = 600;   // 실제 다음 호출까지 대기(초). 429 발생 시 backoff로 증가
let backoffLevel = 0;     // 429 연속 횟수 (0 = 정상)
let syncTimer = null;
let isSyncing = false;
let lang = 'en';
let theme = 'dark';
let windowMode = 'default';
let alwaysOnTop = false;
const MAX_BACKOFF = 3600; // backoff 상한 1시간

const API_BASE = window.location.origin;

const i18n = {
  en: {
    appTitle: 'Claude Usage Widget by R',
    checking: 'Checking credentials...',
    connected: 'Connected via OAuth',
    notLoggedIn: 'Claude Code not logged in',
    currentSession: 'Current session',
    weeklyLimits: 'Weekly limits',
    allModels: 'All models',
    modelLimit: 'Model limit',
    learnMore: 'Learn more',
    autoSync: 'Auto-sync',
    syncNote: 'Note: rate limit is per-account. Use 10min if running on multiple devices.',
    sync: 'sync',
    quit: 'quit',
    never: 'never',
    rateLimited: (m) => `Rate limited · auto-retry in ${m} min`,
    resetsSoon: 'Resets soon',
    resetsIn: (h, m) => h > 0 ? `Resets in ${h} hr ${m} min` : `Resets in ${m} min`,
    resetsAt: (d) => `Resets ${d}`,
    lastSync: (t) => `last sync ${t}`,
    language: 'Language',
    credentials: 'Credentials',
    autoDetected: 'Auto-detected from credentials file',
    notFound: 'Not found',
    refresh: 'Refresh',
    loginTitle: 'Claude Code sign-in required',
    loginTitleExpired: 'Sign-in expired',
    loginDescExpired: 'Your saved sign-in has expired. Sign in again to keep reading usage.',
    credExpired: 'Sign-in expired',
    loginDesc: 'Installs Claude Code if missing, then opens the browser to sign in.',
    loginStart: 'Start sign-in',
    loginRunning: 'In progress...',
    loginWaiting: 'Follow the console window. This updates automatically when done.',
    loginTimeout: 'Timed out. Press the button to try again.',
    loginFailed: 'Could not start. Restart the widget and try again.',
    theme: 'Theme',
    themeDark: 'Dark',
    themeLight: 'Light',
    windowMode: 'Window mode',
    modeDefault: 'Default',
    modeMini: 'Mini',
    modeCharacter: 'Character',
    onTop: 'Always on top',
    onTopOff: 'Off',
    onTopOn: 'On',
  },
  ko: {
    appTitle: 'Claude Usage Widget by R',
    checking: '인증 정보 확인 중...',
    connected: 'OAuth 연결됨',
    notLoggedIn: 'Claude Code 로그인 필요',
    currentSession: '현재 세션',
    weeklyLimits: '주간 사용량',
    allModels: '전체 모델',
    modelLimit: '모델 한도',
    learnMore: '자세히 알아보기',
    autoSync: '자동 동기화',
    syncNote: '참고: 속도 제한은 계정 단위. 여러 기기 사용 시 기기당 10분 권장.',
    sync: '동기화',
    quit: '종료',
    never: '동기화 안됨',
    rateLimited: (m) => `요청 한도 초과 · ${m}분 후 자동 재시도`,
    resetsSoon: '곧 초기화',
    resetsIn: (h, m) => h > 0 ? `${h}시간 ${m}분 후 초기화` : `${m}분 후 초기화`,
    resetsAt: (d) => `${d}에 초기화`,
    lastSync: (t) => `마지막 동기화 ${t}`,
    language: '언어',
    credentials: '인증 정보',
    autoDetected: '자격증명 파일에서 자동 감지됨',
    notFound: '찾을 수 없음',
    refresh: '새로고침',
    loginTitle: 'Claude Code 로그인 필요',
    loginTitleExpired: '로그인이 만료되었습니다',
    loginDescExpired: '저장된 로그인이 만료됐습니다. 다시 로그인하면 사용량을 계속 읽어옵니다.',
    credExpired: '로그인 만료됨',
    loginDesc: 'Claude Code가 없으면 설치하고, 브라우저를 열어 로그인합니다.',
    loginStart: '로그인 시작',
    loginRunning: '진행 중...',
    loginWaiting: '검은 콘솔 창의 안내를 따라주세요. 완료되면 자동 반영됩니다.',
    loginTimeout: '시간이 초과됐습니다. 버튼을 다시 눌러주세요.',
    loginFailed: '실행하지 못했습니다. 위젯을 재시작해주세요.',
    theme: '테마',
    themeDark: '다크',
    themeLight: '라이트',
    windowMode: '창 모드',
    modeDefault: '기본',
    modeMini: '미니',
    modeCharacter: '캐릭터',
    onTop: '항상 최상단',
    onTopOff: '끔',
    onTopOn: '켬',
  },
};

function t() { return i18n[lang]; }

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

// ===== Settings persistence =====
// 위젯은 트레이로 내렸다 올리는 일이 잦다. 선택값이 매번 초기화되면 못 쓴다.
const STORE_KEY = 'claudeWidgetSettings';

function loadSettings() {
  try { return JSON.parse(localStorage.getItem(STORE_KEY)) || {}; } catch { return {}; }
}

function saveSettings(patch) {
  try { localStorage.setItem(STORE_KEY, JSON.stringify({ ...loadSettings(), ...patch })); } catch {}
}

function applyTheme(next) {
  theme = next === 'light' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', theme);
  $$('.theme-btn').forEach((b) => b.classList.toggle('active', b.dataset.theme === theme));
}

let settingsOpen = false;

// 설정 패널이 열려 있으면 미니·캐릭터 모드에선 창을 키워야 패널이 보인다
function sizeKey() {
  return (settingsOpen && windowMode !== 'default') ? 'settings' : windowMode;
}

async function applyWindowSize() {
  if (window.widgetAPI && window.widgetAPI.setWindowMode) {
    await window.widgetAPI.setWindowMode(sizeKey());
  }
}

function setSettingsOpen(open) {
  settingsOpen = !!open;
  document.body.classList.toggle('settings-open', settingsOpen);
  applyWindowSize();
}

async function applyMode(next) {
  windowMode = ['default', 'mini', 'character'].includes(next) ? next : 'default';
  document.body.classList.remove('mode-default', 'mode-mini', 'mode-character');
  document.body.classList.add(`mode-${windowMode}`);
  $$('.mode-btn').forEach((b) => b.classList.toggle('active', b.dataset.mode === windowMode));
  // 창 크기는 메인 프로세스만 바꿀 수 있다 (브라우저 fallback에선 무시)
  await applyWindowSize();
}

// 버튼 상태만 갱신 (트레이 메뉴에서 바뀐 경우 되돌려 보내지 않기 위해 분리)
function syncAlwaysOnTopUI(flag) {
  alwaysOnTop = !!flag;
  $$('.ontop-btn').forEach((b) => b.classList.toggle('active', (b.dataset.ontop === 'on') === alwaysOnTop));
}

async function applyAlwaysOnTop(flag) {
  syncAlwaysOnTopUI(flag);
  if (window.widgetAPI && window.widgetAPI.setAlwaysOnTop) {
    await window.widgetAPI.setAlwaysOnTop(alwaysOnTop);
  }
}

// 사용량 구간별 캐릭터 모션
// 0~10 잠 · ~30 느린 걷기 · ~50 빠른 걷기 · ~80 점프 · ~100 불붙어 날뛰기 · 100 사망
const CHAR_TIERS = ['tier-sleep', 'tier-walk-slow', 'tier-walk-fast', 'tier-jump', 'tier-fire', 'tier-dead'];

function charTierFor(percent) {
  // 말풍선에 100% 라고 적혀 있으면 캐릭터도 사망 상태여야 한다 → 표시값과 같은 반올림 기준
  if (Math.round(percent) >= 100) return 'tier-dead';
  if (percent <= 10) return 'tier-sleep';
  if (percent <= 30) return 'tier-walk-slow';
  if (percent <= 50) return 'tier-walk-fast';
  if (percent <= 80) return 'tier-jump';
  return 'tier-fire';
}

function setCharPercent(percent) {
  const el = $('#charPercent');
  el.textContent = `${Math.round(percent)}%`;
  el.className = 'char-bubble-percent';
  if (percent >= 80) el.classList.add('danger');
  else if (percent >= 50) el.classList.add('warning');

  const stage = $('#charStage');
  const next = charTierFor(percent);
  CHAR_TIERS.forEach((c) => stage.classList.toggle(c, c === next));
}

function percentColor(p) {
  if (p >= 80) return 'danger';
  if (p >= 50) return 'warning';
  return 'success';
}

function setProgressBar(id, percent) {
  const el = $(`#${id}`);
  el.style.width = `${Math.min(percent, 100)}%`;
  el.className = 'progress-fill';
  if (percent >= 80) el.classList.add('danger');
  else if (percent >= 50) el.classList.add('warning');
}

function setPercentText(id, percent) {
  const el = $(`#${id}`);
  el.textContent = `${Math.round(percent)}%`;
  el.className = el.className.replace(/color-\w+/g, '').trim();
  el.classList.add(`color-${percentColor(percent)}`);
}

async function checkCredentials() {
  const dot = $('#credDot');
  const status = $('#credStatus');
  const statusIcon = $('.status-icon');
  const statusText = $('#statusText');

  try {
    const res = await fetch(`${API_BASE}/api/credentials`);
    const data = await res.json();

    // found 만 보면 "파일은 있는데 토큰이 만료된" 상태에서 로그인 버튼이 숨겨져
    // 사용자가 손쓸 방법이 없어진다. expired 를 함께 본다.
    if (data.found && !data.expired) {
      dot.className = 'cred-dot found';
      status.textContent = t().autoDetected;
      statusIcon.textContent = '✓';
      statusIcon.className = 'status-icon connected';
      statusText.textContent = t().connected;
      statusText.className = 'status-text connected';
      $('#loginCard').style.display = 'none';
      return true;
    }
    if (data.found && data.expired) {
      dot.className = 'cred-dot not-found';
      status.textContent = t().credExpired;
      statusIcon.textContent = '⚠';
      statusIcon.className = 'status-icon error';
      statusText.textContent = t().loginTitleExpired;
      statusText.className = 'status-text error';
      showLoginCard(true);
      return false;
    }
  } catch {}

  dot.className = 'cred-dot not-found';
  status.textContent = t().notFound;
  statusIcon.textContent = '✗';
  statusIcon.className = 'status-icon error';
  statusText.textContent = t().notLoggedIn;
  statusText.className = 'status-text error';
  showLoginCard(false);
  return false;
}

// 로그인 카드 노출. expired=true 면 "만료" 문구로 바꿔 처음 로그인과 구분한다.
// Electron에서만 설치·로그인 실행 가능 (브라우저 fallback에선 버튼 숨김)
function showLoginCard(expired) {
  const title = $('#loginTitle');
  const desc = $('#loginDesc');
  if (title) title.textContent = expired ? t().loginTitleExpired : t().loginTitle;
  if (desc) desc.textContent = expired ? t().loginDescExpired : t().loginDesc;
  $('#loginCard').style.display = window.widgetAPI ? 'flex' : 'none';
}

// ===== First-run login =====
let loginPoll = null;

async function startLogin() {
  const btn = $('#loginBtn');
  const hint = $('#loginHint');
  if (!window.widgetAPI || !window.widgetAPI.login) return;

  btn.disabled = true;
  btn.textContent = t().loginRunning;
  hint.textContent = t().loginWaiting;

  const r = await window.widgetAPI.login();
  if (!r || !r.ok) {
    btn.disabled = false;
    btn.textContent = t().loginStart;
    hint.textContent = t().loginFailed;
    return;
  }

  // 콘솔 창에서 설치·로그인이 끝나 인증 파일이 생기는지 폴링 (최대 10분)
  let waited = 0;
  clearInterval(loginPoll);
  loginPoll = setInterval(async () => {
    waited += 3;
    // checkCredentials 는 이제 "유효한 토큰" 일 때만 true 라,
    // 만료 상태에서 시작한 로그인도 실제 완료 시점에만 통과한다.
    if (await checkCredentials()) {
      clearInterval(loginPoll);
      loginPoll = null;
      btn.disabled = false;
      btn.textContent = t().loginStart;
      hint.textContent = '';
      doSync();
    } else if (waited >= 600) {
      clearInterval(loginPoll);
      loginPoll = null;
      btn.disabled = false;
      btn.textContent = t().loginStart;
      hint.textContent = t().loginTimeout;
    }
  }, 3000);
}

// 언어를 바꾸면 정적 라벨만 갱신되고 시간·동기화 문구는 다음 동기화까지 이전 언어로 남는다.
// 마지막 응답을 들고 있다가 즉시 다시 그린다.
let lastUsage = null;
let lastSyncAt = null;   // 포맷된 문자열이 아니라 시각 자체를 보관 — 언어 전환 시 다시 포맷
let scopedModelName = '';

// 시각 표기는 현재 UI 언어를 따른다. en-US 로 굳히면 한글 화면에 'Sun 12:00 AM',
// '11:46 am' 같은 영어가 섞여 나온다 (260824 실측).
function locale() { return lang === 'ko' ? 'ko-KR' : 'en-US'; }

function fmtResetAt(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d)) return '';
  return d.toLocaleString(locale(), { weekday: 'short', hour: 'numeric', minute: '2-digit', hour12: true });
}

function fmtClock(d) {
  return d.toLocaleTimeString(locale(), { hour: 'numeric', minute: '2-digit', hour12: true }).toLowerCase();
}

function renderResetTexts() {
  if (!lastUsage) return;
  const hrs = Math.floor(lastUsage.sessionResetSeconds / 3600);
  const mins = Math.floor((lastUsage.sessionResetSeconds % 3600) / 60);
  $('#sessionReset').textContent = (hrs === 0 && mins === 0) ? t().resetsSoon : t().resetsIn(hrs, mins);
  const resetAt = fmtResetAt(lastUsage.weeklyAllModelsResetAt);
  $('#allModelsReset').textContent = resetAt ? t().resetsAt(resetAt) : '';
}

function renderLastSync() {
  $('#lastSync').textContent = lastSyncAt ? t().lastSync(fmtClock(lastSyncAt)) : t().never;
}

async function doSync() {
  if (isSyncing) return;
  isSyncing = true;
  $('#syncBtn').innerHTML = '<span class="syncing">↻</span>';
  $('#charSyncBtn')?.classList.add('syncing');

  try {
    const res = await fetch(`${API_BASE}/api/usage`);
    const usage = await res.json();

    if (usage.error) {
      throw new Error(usage.error);
    }

    setPercentText('sessionPercent', usage.sessionUsagePercent);
    setProgressBar('sessionProgress', usage.sessionUsagePercent);
    setCharPercent(usage.sessionUsagePercent);

    lastUsage = usage;
    renderResetTexts();

    setPercentText('allModelsPercent', usage.weeklyAllModelsPercent);
    setProgressBar('allModelsProgress', usage.weeklyAllModelsPercent);

    // 모델 스코프 한도 — 이름은 API 응답 그대로. 한도가 없으면 행을 감춘다.
    scopedModelName = usage.scopedModelName || '';
    $('#scopedBlock').style.display = scopedModelName ? 'block' : 'none';
    if (scopedModelName) {
      $('#scopedTitle').textContent = scopedModelName;
      setPercentText('scopedPercent', usage.scopedModelPercent);
      setProgressBar('scopedProgress', usage.scopedModelPercent);
    }

    // 플랜은 인증 파일에서 온다. 알 수 없으면 배지를 숨긴다.
    // (예전엔 'Max' 가 하드코딩돼 Pro 사용자에게도 Max 로 보였다)
    const badge = $('#planBadge');
    badge.textContent = usage.planName || '';
    badge.style.display = usage.planName ? '' : 'none';

    const statusIcon = $('.status-icon');
    const statusText = $('#statusText');
    statusIcon.textContent = '✓';
    statusIcon.className = 'status-icon connected';
    statusText.textContent = t().connected;
    statusText.className = 'status-text connected';

    lastSyncAt = new Date();
    renderLastSync();

    // 정상 응답 → backoff 해제, 원래 간격 복귀
    backoffLevel = 0;
    currentDelay = userInterval;

  } catch (err) {
    const statusIcon = $('.status-icon');
    const statusText = $('#statusText');
    statusIcon.className = 'status-icon error';
    statusText.className = 'status-text error';

    if (err.message === 'RATE_LIMITED') {
      // 429 → 지수 backoff: 다음 자동 호출 간격을 2배씩 늘림 (상한 1시간)
      backoffLevel++;
      currentDelay = Math.min(userInterval * Math.pow(2, backoffLevel), MAX_BACKOFF);
      statusIcon.textContent = '⚠';
      statusText.textContent = t().rateLimited(Math.round(currentDelay / 60));
    } else if (err.message === 'NO_CREDENTIALS') {
      backoffLevel = 0;
      currentDelay = userInterval;
      statusIcon.textContent = '✗';
      statusText.textContent = t().notLoggedIn;
    } else if (err.message === 'TOKEN_EXPIRED') {
      backoffLevel = 0;
      currentDelay = userInterval;
      statusIcon.textContent = '⚠';
      statusText.textContent = t().loginTitleExpired;
      // 안내만 띄우고 끝내면 사용자가 할 수 있는 게 없다. 로그인 버튼을 같이 노출한다.
      showLoginCard(true);
    } else {
      backoffLevel = 0;
      currentDelay = userInterval;
      statusIcon.textContent = '⚠';
      statusText.textContent = err.message.substring(0, 40);
    }
  }

  isSyncing = false;
  $('#syncBtn').textContent = t().sync;
  $('#charSyncBtn')?.classList.remove('syncing');
}

// 자동 동기화: setTimeout 재귀 — 429 backoff로 간격이 바뀌어도 매번 다시 예약
async function autoSyncTick() {
  await doSync();
  scheduleNextSync();
}

function scheduleNextSync() {
  if (syncTimer) clearTimeout(syncTimer);
  syncTimer = null;
  if (userInterval > 0) {
    syncTimer = setTimeout(autoSyncTick, currentDelay * 1000);
  }
}

function setupAutoSync() {
  if (syncTimer) clearTimeout(syncTimer);
  syncTimer = null;
  backoffLevel = 0;
  currentDelay = userInterval;
  if (userInterval > 0) {
    // 시작 직후 즉시 호출 대신 4초 지연 (재시작 폭주로 인한 rate limit 완화)
    syncTimer = setTimeout(autoSyncTick, 4000);
  }
}

function applyLanguage() {
  const s = t();
  $('.app-title').textContent = s.appTitle;
  $$('.card-title')[0].textContent = s.currentSession;
  $$('.card-title')[1].textContent = s.weeklyLimits;
  $$('.sub-title')[0].textContent = s.allModels;
  $('#scopedTitle').textContent = scopedModelName || s.modelLimit;
  $('#learnMore').textContent = s.learnMore;
  $('.sync-label').textContent = s.autoSync;
  $('.sync-note').textContent = s.syncNote;
  $('#syncBtn').textContent = s.sync;
  // 설정 라벨이 늘어나 index 접근은 깨짐 → id로 고정
  $('#labelLanguage').textContent = s.language;
  $('#labelTheme').textContent = s.theme;
  $('#labelWindow').textContent = s.windowMode;
  $('#labelCredentials').textContent = s.credentials;
  $('#themeDark').textContent = s.themeDark;
  $('#themeLight').textContent = s.themeLight;
  $('#modeDefault').textContent = s.modeDefault;
  $('#modeMini').textContent = s.modeMini;
  $('#modeCharacter').textContent = s.modeCharacter;
  // 언어를 바꿔도 인증 상태 문구가 그대로 남던 누락 보완
  $('#credRefreshBtn').textContent = s.refresh;
  const dot = $('#credDot');
  if (dot.classList.contains('found')) {
    $('#credStatus').textContent = s.autoDetected;
    $('#statusText').textContent = s.connected;
  } else if (dot.classList.contains('not-found')) {
    $('#credStatus').textContent = s.notFound;
    $('#statusText').textContent = s.notLoggedIn;
  }
  renderResetTexts();
  renderLastSync();
  $('#labelOnTop').textContent = s.onTop;
  $('#onTopOff').textContent = s.onTopOff;
  $('#onTopOn').textContent = s.onTopOn;
  $('#loginTitle').textContent = s.loginTitle;
  $('#loginDesc').textContent = s.loginDesc;
  if (!$('#loginBtn').disabled) $('#loginBtn').textContent = s.loginStart;
}

// ===== Init =====
document.addEventListener('DOMContentLoaded', () => {
  const toggleSettings = () => {
    const panel = $('#settingsPanel');
    const open = panel.style.display === 'none';
    panel.style.display = open ? 'block' : 'none';
    setSettingsOpen(open);
  };

  $('#settingsBtn').addEventListener('click', toggleSettings);

  // 캐릭터 모드 전용 컨트롤 (헤더가 없으므로 여기서 최소화·설정·종료를 제공)
  $('#charSettingsBtn').addEventListener('click', toggleSettings);
  $('#charMinBtn').addEventListener('click', () => {
    if (window.widgetAPI) window.widgetAPI.minimize();
  });
  $('#charSyncBtn').addEventListener('click', doSync);
  $('#charQuitBtn').addEventListener('click', () => {
    if (window.widgetAPI) window.widgetAPI.quit();
    else window.close();
  });

  // 드래그 영역이 CSS :hover 를 삼키므로 메인 프로세스가 커서 위치를 알려준다
  if (window.widgetAPI && window.widgetAPI.onWindowHover) {
    window.widgetAPI.onWindowHover((inside) => {
      document.body.classList.toggle('char-hover', !!inside);
    });
  }

  $$('.lang-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      $$('.lang-btn').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      lang = btn.dataset.lang;
      saveSettings({ lang });
      applyLanguage();
    });
  });

  $$('.theme-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      applyTheme(btn.dataset.theme);
      saveSettings({ theme });
    });
  });

  $$('.mode-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      applyMode(btn.dataset.mode);
      saveSettings({ mode: btn.dataset.mode });
    });
  });

  $$('.ontop-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const flag = btn.dataset.ontop === 'on';
      applyAlwaysOnTop(flag);
      saveSettings({ alwaysOnTop: flag });
    });
  });

  // 트레이 메뉴로 바꿔도 설정 버튼이 따라오게
  if (window.widgetAPI && window.widgetAPI.onAlwaysOnTopChanged) {
    window.widgetAPI.onAlwaysOnTopChanged((flag) => {
      syncAlwaysOnTopUI(flag);
      saveSettings({ alwaysOnTop: !!flag });
    });
  }

  $$('.sync-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      $$('.sync-btn').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      userInterval = parseInt(btn.dataset.interval);
      saveSettings({ interval: userInterval });
      setupAutoSync();
    });
  });

  $('#syncBtn').addEventListener('click', doSync);

  $('#credRefreshBtn').addEventListener('click', () => {
    checkCredentials();
    doSync();
  });

  $('#loginBtn').addEventListener('click', startLogin);

  $('#learnMore').addEventListener('click', (e) => {
    e.preventDefault();
    window.open('https://support.anthropic.com/en/articles/9964580-how-does-usage-work-on-claude-ai', '_blank');
  });

  // Footer window controls (Electron 환경에서만 widgetAPI 존재)
  const minBtn = $('#minBtn');
  const quitBtn = $('#quitBtn');
  if (minBtn) {
    minBtn.addEventListener('click', () => {
      if (window.widgetAPI) window.widgetAPI.minimize();
    });
  }
  if (quitBtn) {
    quitBtn.addEventListener('click', () => {
      if (window.widgetAPI) window.widgetAPI.quit();
      else window.close();   // 일반 브라우저 fallback
    });
  }

  // 저장된 설정 복원 (언어·테마·창모드·동기화 주기)
  const saved = loadSettings();
  if (saved.lang === 'ko' || saved.lang === 'en') {
    lang = saved.lang;
    $$('.lang-btn').forEach((b) => b.classList.toggle('active', b.dataset.lang === lang));
  }
  if (typeof saved.interval === 'number') {
    userInterval = saved.interval;
    $$('.sync-btn').forEach((b) => b.classList.toggle('active', parseInt(b.dataset.interval) === userInterval));
  }
  applyTheme(saved.theme);
  applyMode(saved.mode);
  applyAlwaysOnTop(saved.alwaysOnTop === true);
  applyLanguage();

  showVersion();
  checkCredentials();
  setupAutoSync();
});

async function showVersion() {
  try {
    const res = await fetch(`${API_BASE}/api/version`);
    const { version } = await res.json();
    if (version) $('#appVersion').textContent = `v${version}`;
  } catch {}
}
