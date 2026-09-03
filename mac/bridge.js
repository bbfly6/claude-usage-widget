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
