// 맥 전용 주입 스크립트 (documentStart).
//
// 목적: src/renderer.js 를 한 줄도 고치지 않고 그대로 쓰기 위해,
//       renderer 가 기대하는 두 창구를 네이티브로 갈아끼운다.
//         1) fetch('/api/...')  — Windows 는 127.0.0.1:19522 HTTP 서버
//         2) window.widgetAPI   — Windows 는 preload.js 의 contextBridge
//       맥은 로컬 HTTP 서버를 띄우지 않으므로 포트 충돌이 원천적으로 없다.
(() => {
  'use strict';
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge;
  if (!bridge) return;                       // Electron(Windows)에서는 아무것도 하지 않는다
  const call = (method, args) => bridge.postMessage({ method, args: args || [] });

  // ── 1) fetch 가로채기
  // renderer 는 `${window.location.origin}/api/usage` 를 부른다.
  // file:// 에서 origin 은 "null" 이라 경로 끝부분으로 판별한다.
  const nativeFetch = window.fetch ? window.fetch.bind(window) : null;
  window.fetch = async function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    const m = /\/api\/(usage|credentials|version)(?:\?.*)?$/.exec(url);
    if (!m) {
      if (nativeFetch) return nativeFetch(input, init);
      throw new Error('fetch unavailable');
    }
    const data = await call('api', [m[1]]);
    return new Response(JSON.stringify(data), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  };

  // ── 2) widgetAPI — preload.js 와 동일한 시그니처
  window.widgetAPI = {
    minimize: () => call('minimize'),
    quit: () => call('quit'),
    login: () => call('login'),
    setWindowMode: (mode) => call('setWindowMode', [mode]),
    setAlwaysOnTop: (flag) => call('setAlwaysOnTop', [!!flag]),
    // 네이티브에서 밀어주는 이벤트. 콜백을 보관만 하고 호출은 Swift 가 한다.
    onWindowHover: (cb) => { window.__widgetOnHover = cb; },
    onAlwaysOnTopChanged: (cb) => { window.__widgetOnAlwaysOnTop = cb; },
  };

  // ── 3) 맥 전용 UI 조정
  // src/ 는 Windows 와 공유하므로 고치지 않고, 맥에서만 스타일을 덮어쓴다.
  const macCSS = document.createElement('style');
  macCSS.textContent = [
    /* 최소화 버튼 제거.
       Windows 는 작업표시줄 앱이라 최소화가 필요하지만,
       맥은 메뉴바에 상시 노출되고 아이콘 클릭으로 여닫으므로 중복이다.
       뒤따르는 구분선(|)도 같이 없애야 'sync | | x' 처럼 보이지 않는다. */
    '#minBtn, #minBtn + .footer-sep { display: none !important; }',
    '#charMinBtn { display: none !important; }',

    /* 커서 정리.
       Electron 은 -webkit-app-region: drag 영역에서 텍스트 선택과 커서 변경을 자동으로 막지만,
       WKWebView 는 이 속성 자체를 모른다. 그래서 글자 위에서 I빔이 뜨고 드래그하면 선택된다.
       기본은 화살표로 고정하고, 클릭 가능한 요소(= no-drag 로 지정된 것들)에만 손가락을 준다. */
    '*, *::before, *::after { cursor: default !important;',
    '  -webkit-user-select: none !important; user-select: none !important; }',
    /* 자식 요소까지 포함해야 한다. 아이콘(svg·span)이 들어 있는 버튼은
       테두리에선 손가락인데 가운데 아이콘 위에선 화살표로 바뀐다 (260903 증상).
       cursor 는 상속되지만 위의 * 규칙이 모든 요소에 default 를 직접 박기 때문이다. */
    (window.__NODRAG_SEL
      ? window.__NODRAG_SEL.split(',').map(sel => {
          const t = sel.trim();
          return t ? `${t}, ${t} *` : '';
        }).filter(Boolean).join(', ') + ' { cursor: pointer !important; }'
      : ''),
    'button, button *, a, a * { cursor: pointer !important; }',

    /* 테마 버튼이 셋(다크·라이트·자동)이 되면서 320px 폭에서 한 줄에 안 들어간다.
       style.css 는 flex-wrap 이라 줄바꿈되긴 하는데 옆의 '언어' 열과 높이가 어긋난다.
       라벨을 '자동/Auto' 로 줄여도 여전히 넘쳐서(실측 offsetTop 73,73,100)
       좌우 여백까지 줄인다. 세로 여백은 그대로라 다른 버튼과 높이는 같다. */
    '.theme-btn { padding-left: 7px !important; padding-right: 7px !important; }',
    '.mac-links { display: flex; gap: 14px; margin-bottom: 10px; }',

    'button:disabled, button:disabled *, .login-btn:disabled, .login-btn:disabled * { cursor: default !important; }',
  ].join('\n');
  (document.head || document.documentElement).appendChild(macCSS);

  // ── 4) 언어를 네이티브에 알린다
  // 메뉴바 우클릭 메뉴와 캐릭터 미리보기 라벨을 위젯 화면과 같은 언어로 맞추기 위한 것.
  // renderer.js 는 localStorage('claudeWidgetSettings').lang 에 저장한다.
  const reportLang = () => {
    let lang = 'en';
    try { lang = (JSON.parse(localStorage.getItem('claudeWidgetSettings')) || {}).lang || 'en'; } catch {}
    call('setLang', [lang]);
  };
  document.addEventListener('DOMContentLoaded', reportLang);
  // 언어 버튼을 누르면 renderer 가 저장한 뒤에 읽어야 하므로 한 틱 미룬다
  document.addEventListener('click', (e) => {
    if (e.target && e.target.closest && e.target.closest('.lang-btn')) setTimeout(reportLang, 0);
  }, true);

  // ── 6) 시스템 테마 자동 추종 (맥 전용)
  //
  // src/renderer.js 의 테마는 다크/라이트 둘뿐이고, 그 파일은 Windows 와 공유라 고칠 수 없다.
  // 그래서 '시스템' 버튼을 여기서 하나 더 끼워 넣고, 눌리면 renderer 의 기존 버튼을
  // 대신 눌러준다. renderer 입장에서는 사용자가 다크/라이트를 고른 것과 똑같아
  // 저장·적용 경로가 하나로 유지된다.
  const THEME_MODE_KEY = 'macThemeMode';          // 'system' | 'manual'
  let applyingSystem = false;                     // 프로그램이 누른 클릭을 사용자 선택으로 오해하지 않도록

  const themeMode = () => { try { return localStorage.getItem(THEME_MODE_KEY) || 'manual'; } catch { return 'manual'; } };
  const setThemeMode = (v) => { try { localStorage.setItem(THEME_MODE_KEY, v); } catch {} };
  const systemTheme = () => (window.__MAC_APPEARANCE === 'light' ? 'light' : 'dark');

  function markSystemActive() {
    document.querySelectorAll('.theme-btn').forEach((b) => b.classList.remove('active'));
    const s = document.getElementById('macThemeSystem');
    if (s) s.classList.add('active');
  }

  function applySystemTheme() {
    const btn = document.querySelector(`.theme-btn[data-theme="${systemTheme()}"]`);
    if (!btn) return;
    applyingSystem = true;
    btn.click();               // renderer 가 적용하고 저장한다
    applyingSystem = false;
    markSystemActive();        // 눌린 표시는 '시스템' 쪽에 남긴다
  }

  function installThemeSystemButton() {
    const light = document.getElementById('themeLight');
    if (!light || document.getElementById('macThemeSystem')) return;

    const b = document.createElement('button');
    b.className = 'theme-btn';
    b.id = 'macThemeSystem';
    // data-theme 은 일부러 비워둔다. renderer 의 applyTheme() 은 'system' 을 모르고
    // 모르는 값이 오면 다크로 떨어뜨린다.
    b.dataset.macTheme = 'system';
    light.after(b);
    b.addEventListener('click', () => { setThemeMode('system'); applySystemTheme(); });

    // 사용자가 다크/라이트를 직접 고르면 자동 추종을 끈다
    document.querySelectorAll('.theme-btn[data-theme]').forEach((x) => {
      x.addEventListener('click', () => { if (!applyingSystem) setThemeMode('manual'); });
    });

    labelThemeSystem();
    if (themeMode() === 'system') applySystemTheme();
  }

  function labelThemeSystem() {
    const b = document.getElementById('macThemeSystem');
    if (!b) return;
    let lang = 'en';
    try { lang = (JSON.parse(localStorage.getItem('claudeWidgetSettings')) || {}).lang || 'en'; } catch {}
    // '시스템'/'System' 은 영어에서 320px 폭을 넘겨 줄바꿈됐다(실측 offsetTop 73,73,100).
    // 다크·라이트 옆에 붙는 세 번째 칸이라 짧아야 한다.
    b.textContent = lang === 'ko' ? '자동' : 'Auto';
    b.title = lang === 'ko' ? '시스템 설정에 맞춤' : 'Follow system setting';
  }

  // 네이티브가 시스템 외관 변경을 알려준다
  window.__macAppearanceChanged = (t) => {
    window.__MAC_APPEARANCE = t;
    if (themeMode() === 'system') applySystemTheme();
  };

  // renderer 가 DOMContentLoaded 에서 버튼들에 핸들러를 붙인 뒤에 끼워야 한다.
  // bridge 가 먼저 등록되므로 한 틱 미룬다.
  document.addEventListener('DOMContentLoaded', () => setTimeout(() => {
    installThemeSystemButton();
    installMacSettings();
    installUpdateBar();
  }, 0));
  document.addEventListener('click', (e) => {
    if (e.target && e.target.closest && e.target.closest('.lang-btn')) {
      setTimeout(async () => {
        labelThemeSystem();
        renderMacSettings(await call('macSettings'));   // 라벨을 새 언어로 다시 그린다
      }, 0);
    }
  }, true);

  // ── 7) 맥 전용 설정을 설정 창 안으로
  //
  // 이 항목들은 원래 메뉴바 우클릭 메뉴에 있었다. 설정이 두 군데로 나뉘면
  // 사용자는 우클릭을 시도하지 않아 그런 기능이 있는 줄도 모른다.
  // 우클릭에는 '열기/종료'만 남기고 설정은 전부 이 창으로 모은다.
  const MAC_L = {
    ko: { notify: '사용량 알림', percent: '메뉴바 % 표시', login: '로그인 시 자동 시작',
          hotkey: '단축키', off: '끔', on: '켬',
          previewAll: '캐릭터 전체 보기 →', previewBar: '메뉴바에서 재생 →' },
    en: { notify: 'Usage alerts', percent: 'Menu bar %', login: 'Start at login',
          hotkey: 'Shortcut', off: 'Off', on: 'On',
          previewAll: 'All characters →', previewBar: 'Play in menu bar →' },
  };
  const macLang = () => {
    try { return (JSON.parse(localStorage.getItem('claudeWidgetSettings')) || {}).lang === 'ko' ? 'ko' : 'en'; }
    catch { return 'en'; }
  };

  /// 맥 전용 버튼 스타일.
  ///
  /// 원래는 style.css 의 규칙에 선택자만 얹어(cssRules 수정) 값을 베끼지 않으려 했는데,
  /// file:// 에서 로드한 스타일시트는 cssRules 접근이 SecurityError 로 막힌다 (260904 실측).
  /// 그래서 어쩔 수 없이 여기 적는다. 색은 같은 토큰을 쓰므로 테마는 함께 따라가고,
  /// 치수만 중복된다. 원본은 style.css 의 .theme-btn/.mode-btn/.ontop-btn 규칙이다.
  function macButtonStyles() {
    const css = document.createElement('style');
    css.textContent = `
      .mac-seg-btn {
        font-size: 11px; padding: 4px 10px;
        border: 1px solid var(--border); border-radius: 6px;
        background: transparent; color: var(--text-secondary); cursor: pointer;
        transition: background .15s, color .15s, border-color .15s, transform .1s;
      }
      .mac-seg-btn:hover { color: var(--text-primary); border-color: rgba(217,119,87,.35); }
      .mac-seg-btn:active { transform: scale(.97); }
      .mac-seg-btn:focus-visible { outline: 2px solid var(--claude-orange); outline-offset: 1px; }
      .mac-seg-btn.active {
        color: var(--claude-orange); background: rgba(217,119,87,.1);
        border-color: rgba(217,119,87,.3); font-weight: 600;
      }
      .mac-link { font-size: 10px; color: var(--claude-orange); text-decoration: none; cursor: pointer; }
      .mac-link:hover { text-decoration: underline; }
    `;
    document.head.appendChild(css);
  }

  function segGroup(key, label, on) {
    const t = MAC_L[macLang()];
    return `<div class="settings-group">
      <label class="settings-label" data-mac-label="${key}">${label}</label>
      <div class="seg-buttons">
        <button class="mac-seg-btn${on ? '' : ' active'}" data-mac="${key}" data-val="0">${t.off}</button>
        <button class="mac-seg-btn${on ? ' active' : ''}" data-mac="${key}" data-val="1">${t.on}</button>
      </div>
    </div>`;
  }

  function renderMacSettings(st) {
    const t = MAC_L[macLang()];
    const host = document.getElementById('macSettings');
    if (!host) return;
    host.innerHTML = `
      <div class="settings-row">
        ${segGroup('notify', t.notify, st.notify)}
        ${segGroup('percent', t.percent, st.percent)}
      </div>
      <div class="settings-row">
        ${segGroup('login', t.login, st.login)}
        <div class="settings-group">
          <label class="settings-label">${t.hotkey}</label>
          <div class="seg-buttons">
            <button class="mac-seg-btn active" id="macHotkey">${st.hotkey}</button>
          </div>
        </div>
      </div>
      <div class="settings-group mac-links">
        <a class="mac-link" id="macPreviewAll">${t.previewAll}</a>
        <a class="mac-link" id="macPreviewBar">${t.previewBar}</a>
      </div>`;

    host.querySelectorAll('.mac-seg-btn[data-mac]').forEach((b) => {
      b.addEventListener('click', async () => {
        const next = await call('setMac', [b.dataset.mac, b.dataset.val === '1']);
        renderMacSettings(next);          // 네이티브가 돌려준 실제 상태로 그린다
      });                                 // (권한 거부처럼 요청대로 안 되는 경우가 있다)
    });
    document.getElementById('macHotkey').addEventListener('click', () => call('pickHotKey'));
    document.getElementById('macPreviewAll').addEventListener('click', () => call('previewAll'));
    document.getElementById('macPreviewBar').addEventListener('click', () => call('previewMenuBar'));
  }

  // 네이티브가 상태를 바꿨을 때(단축키 녹화 등) 화면을 다시 그린다
  window.__macSettingsChanged = (st) => renderMacSettings(st);

  async function installMacSettings() {
    const panel = document.getElementById('settingsPanel');
    if (!panel || document.getElementById('macSettings')) return;
    macButtonStyles();
    const host = document.createElement('div');
    host.id = 'macSettings';
    // '인증 정보' **앞**에 넣는다. 인증 정보는 설정이 아니라 상태 표시라
    // 설정 항목들 사이에 끼면 흐름이 끊긴다.
    const cred = document.getElementById('labelCredentials');
    const before = (cred && cred.closest('.settings-group')) || panel.querySelector('.divider');
    before ? panel.insertBefore(host, before) : panel.appendChild(host);
    renderMacSettings(await call('macSettings'));
  }

  // ── 8) 업데이트 띠
  //
  // 창 맨 위(헤더 아래)에 얇게 뜬다. 새 버전이 없으면 아예 그리지 않는다.
  // 눌렀을 때 무슨 일이 일어나는지 그 자리에서 보여야 해서 진행률도 같은 자리에 쓴다.
  const UPD_L = {
    ko: { avail: (v) => `새 버전 v${v}`, btn: '업데이트',
          checking: '확인 중…', downloading: (p) => `내려받는 중 ${p}%`,
          installing: '설치 중… 곧 다시 켜집니다', failed: '업데이트 실패', retry: '다시 시도' },
    en: { avail: (v) => `Version ${v} available`, btn: 'Update',
          checking: 'Checking…', downloading: (p) => `Downloading ${p}%`,
          installing: 'Installing… restarting shortly', failed: 'Update failed', retry: 'Retry' },
  };

  function updateBarStyles() {
    const css = document.createElement('style');
    css.textContent = `
      .mac-update {
        display: flex; align-items: center; gap: 8px;
        margin: 0 16px 10px; padding: 7px 10px;
        border: 1px solid rgba(217,119,87,.35); border-radius: 8px;
        background: rgba(217,119,87,.09);
        font-size: 11px; color: var(--text-primary);
      }
      .mac-update-msg { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .mac-update-btn {
        font-size: 11px; font-weight: 600; padding: 3px 10px;
        border: 1px solid rgba(217,119,87,.45); border-radius: 6px;
        background: var(--claude-orange); color: #fff; cursor: pointer;
        transition: filter .15s, transform .1s;
      }
      .mac-update-btn:hover { filter: brightness(1.07); }
      .mac-update-btn:active { transform: scale(.97); }
      /* 진행 중에는 누를 것이 없으므로 버튼을 감춘다 */
      .mac-update.busy .mac-update-btn { display: none; }
      .mac-update-bar { height: 3px; border-radius: 2px; background: rgba(217,119,87,.25); flex: 0 0 64px; overflow: hidden; }
      .mac-update-bar > i { display: block; height: 100%; background: var(--claude-orange); transition: width .2s; }
    `;
    document.head.appendChild(css);
  }

  function renderUpdate(st) {
    const host = document.getElementById('macUpdate');
    if (!host) return;
    const t = UPD_L[st.lang === 'ko' ? 'ko' : 'en'];
    const show = ['available', 'downloading', 'installing', 'failed'].includes(st.kind);
    host.hidden = !show;
    if (!show) { host.innerHTML = ''; return; }

    let msg = '', btn = '', busy = false, bar = '';
    if (st.kind === 'available')    { msg = t.avail(st.version); btn = t.btn; }
    if (st.kind === 'downloading')  { msg = t.downloading(st.percent); busy = true;
                                      bar = `<span class="mac-update-bar"><i style="width:${st.percent}%"></i></span>`; }
    if (st.kind === 'installing')   { msg = t.installing; busy = true; }
    if (st.kind === 'failed')       { msg = `${t.failed} — ${st.message || ''}`; btn = t.retry; }

    host.className = 'mac-update' + (busy ? ' busy' : '');
    host.innerHTML = `<span class="mac-update-msg">${msg}</span>${bar}`
      + (btn ? `<button class="mac-update-btn" id="macUpdateBtn">${btn}</button>` : '');
    const b = document.getElementById('macUpdateBtn');
    if (b) b.addEventListener('click', () => call('updateInstall'));
  }

  window.__macUpdateState = (st) => renderUpdate(st);

  /// 자동 확인은 실행 직후와 6시간마다 돈다. 그래도 지금 확인하고 싶을 때가 있어
  /// 푸터의 버전 글씨를 눌러 확인할 수 있게 한다 (새 UI 를 늘리지 않는다).
  function wireVersionCheck() {
    const v = document.getElementById('appVersion');
    if (!v) return;
    v.style.cursor = 'pointer';
    v.title = macLang() === 'ko' ? '업데이트 확인' : 'Check for updates';
    v.addEventListener('click', () => call('updateCheck'));
  }

  async function installUpdateBar() {
    if (document.getElementById('macUpdate')) return;
    // 헤더 바로 아래, 설정 패널보다 위. 설정을 열지 않아도 보여야 한다.
    const panel = document.getElementById('settingsPanel');
    if (!panel || !panel.parentNode) return;
    updateBarStyles();
    const bar = document.createElement('div');
    bar.id = 'macUpdate';
    bar.className = 'mac-update';
    bar.hidden = true;
    panel.parentNode.insertBefore(bar, panel);
    wireVersionCheck();
    renderUpdate(await call('updateState'));
  }

  // ── 5) 창 드래그
  // WKWebView 는 -webkit-app-region 을 창 이동으로 해석하지 않는다 (Electron 전용 동작).
  // style.css 를 손대지 않기 위해, 계산된 스타일을 읽어 네이티브에 알린다.
  // WebKit 은 -webkit-app-region 을 파싱하지 않으므로 getComputedStyle 로는 못 읽는다.
  // 네이티브가 style.css 를 파싱해 넘겨준 선택자를 쓴다.
  document.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    const el = e.target;
    if (!el || !el.closest) return;
    if (window.__NODRAG_SEL && el.closest(window.__NODRAG_SEL)) return;
    if (window.__DRAG_SEL && el.closest(window.__DRAG_SEL)) call('dragStart');
  }, true);
})();
