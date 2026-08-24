// Electron 메인 프로세스 — server.js를 같은 프로세스에서 띄우고 BrowserWindow로 감쌈
const { app, BrowserWindow, Menu, Tray, nativeImage, shell, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

// GPU 샌드박스 완화.
// 회사 보안 정책이 Chromium GPU 샌드박스를 차단하는 PC 에서는 GPU 프로세스가
// 0x80000003 으로 즉시 죽고, 6회 연속 실패하면 Electron 이 앱 전체를 종료한다
//   ("GPU process isn't usable. Goodbye.")  — 260824 실측, 창이 뜨자마자 꺼짐.
// --disable-gpu 는 효과 없음(프로세스는 여전히 뜨고 같은 코드로 죽음). 샌드박스 완화만 통한다.
// 이 앱은 자기 자신의 127.0.0.1 페이지만 로드하므로 외부 콘텐츠 노출면이 없다.
app.commandLine.appendSwitch('disable-gpu-sandbox');

// 두 번째 인스턴스 차단: 단축아이콘 두 번 눌러도 EADDRINUSE 안 나고 첫 창에 포커스만
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
  process.exit(0);
}
app.on('second-instance', revealWindow);

// 자동 브라우저 열기 차단 후 server 로드
process.env.NO_AUTO_BROWSER = '1';
require('./server.js');

const URL = 'http://127.0.0.1:19522';
let mainWindow = null;
let tray = null;
let isQuitting = false;

async function waitForServer(timeoutMs = 8000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(URL + '/');
      if (res.ok) return true;
    } catch {}
    await new Promise((r) => setTimeout(r, 150));
  }
  return false;
}

function buildMenu() {
  return Menu.buildFromTemplate([
    {
      label: '보기',
      submenu: [
        {
          label: '항상 최상단',
          type: 'checkbox',
          checked: false,
          click: (item) => mainWindow && mainWindow.setAlwaysOnTop(item.checked),
        },
        { role: 'reload', label: '새로고침' },
        { type: 'separator' },
        {
          label: '트레이로 최소화',
          click: () => mainWindow && mainWindow.hide(),
        },
        { role: 'quit', label: '완전히 종료' },
      ],
    },
    {
      label: '도움말',
      submenu: [
        {
          label: 'Anthropic 사용량 안내',
          click: () => shell.openExternal('https://support.anthropic.com/en/articles/9964580-how-does-usage-work-on-claude-ai'),
        },
      ],
    },
  ]);
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 320,
    height: 500,
    minWidth: 300,
    minHeight: 440,
    useContentSize: true,    // width/height를 콘텐츠 영역 기준으로 적용 (frameless 보정)
    title: 'Claude Usage Widget by R',
    icon: path.join(__dirname, 'icon-256.png'),  // 작업표시줄·Alt+Tab 아이콘
    frame: false,            // 윈도우 chrome 제거
    transparent: true,       // 둥근 모서리 알파
    hasShadow: false,        // OS 그림자 비활성 (모서리 주변 회색 hue 제거)
    resizable: true,
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      // 렌더러 샌드박스 해제.
      // 회사 보안 정책이 Chromium 샌드박스를 차단해 렌더러가 즉시 크래시하고
      // 빈 창만 남는다 ("Renderer process crashed" — 260824 실측).
      // 이 창은 자기 자신의 127.0.0.1 페이지만 로드하고 외부 링크는 기본
      // 브라우저로 넘기므로, 렌더러가 실행하는 코드는 항상 우리 코드다.
      // contextIsolation / nodeIntegration:false 는 그대로 유지된다.
      sandbox: false,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  Menu.setApplicationMenu(null);   // 메뉴바 완전 제거 (frameless라 어차피 안 보이지만 Alt 키로도 안 뜸)

  // 외부 링크는 기본 브라우저로 넘긴다.
  // 지정하지 않으면 Electron이 새 창을 만들어 외부 사이트를 앱 안에서 띄운다.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\//i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });

  // 창 자체가 로컬 origin 밖으로 이동하는 것도 차단
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith(URL)) {
      event.preventDefault();
      if (/^https:\/\//i.test(url)) shell.openExternal(url);
    }
  });

  mainWindow.loadURL(URL);

  // 어떤 경로로 실행됐든(설치 직후 자동 실행 포함) 창이 최소화·뒤쪽으로 묻히지 않게 한다
  mainWindow.once('ready-to-show', revealWindow);

  // 창 닫기 = 트레이로 숨김 (실제 종료는 footer quit 버튼 또는 트레이 우클릭)
  mainWindow.on('close', (e) => {
    if (!isQuitting) {
      e.preventDefault();
      mainWindow.hide();
    }
  });
}

// ── 창을 확실히 앞으로 꺼낸다
// Windows 에선 **최소화된 창도 isVisible() 이 true** 다. 이 구분을 안 하면
// 트레이 아이콘을 눌렀을 때 "복구" 가 아니라 "숨김" 이 실행돼, 안 보이는 창이
// 더 안 보이게 된다 (260824 실측 — 설치 후 창이 최소화된 상태로 시작한 사례).
function revealWindow() {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  if (!mainWindow.isVisible()) mainWindow.show();
  mainWindow.focus();
}

// ── 항상 최상단
// 트레이 메뉴와 설정 패널 두 곳에서 바꿀 수 있으므로, 여기로 일원화하고
// 변경될 때마다 renderer에 알려 버튼 상태가 어긋나지 않게 한다.
function setAlwaysOnTop(flag) {
  if (!mainWindow) return false;
  mainWindow.setAlwaysOnTop(!!flag);
  if (!mainWindow.isDestroyed()) {
    mainWindow.webContents.send('always-on-top-changed', !!flag);
  }
  return !!flag;
}

ipcMain.handle('set-always-on-top', (_event, flag) => ({ ok: true, value: setAlwaysOnTop(flag) }));

// ── IPC: 창 모드 (기본 / 미니 / 캐릭터)
// useContentSize:true 로 만든 창이라 setContentSize 기준.
// 축소 시 기존 minimumSize 가 걸리므로 반드시 먼저 완화한다.
const WINDOW_MODES = {
  default:   { width: 320, height: 500, minWidth: 300, minHeight: 440, resizable: true },
  mini:      { width: 320, height: 200, minWidth: 260, minHeight: 170, resizable: false },
  character: { width: 240, height: 210, minWidth: 200, minHeight: 190, resizable: false },
  // 미니·캐릭터 모드에서 설정 패널을 열면 그 작은 창에 패널이 안 들어간다.
  // 패널이 열려 있는 동안만 이 크기를 쓰고, 닫으면 원래 모드 크기로 돌아간다.
  settings:  { width: 320, height: 440, minWidth: 300, minHeight: 380, resizable: false },
};

ipcMain.handle('set-window-mode', (_event, mode) => {
  const cfg = WINDOW_MODES[mode];
  if (!mainWindow || !cfg) return { ok: false };
  mainWindow.setResizable(true);
  mainWindow.setMinimumSize(cfg.minWidth, cfg.minHeight);
  mainWindow.setContentSize(cfg.width, cfg.height, false);
  mainWindow.setResizable(cfg.resizable);
  return { ok: true, mode };
});

// ── IPC: renderer의 minimize / quit 버튼
ipcMain.on('window-minimize', () => {
  if (mainWindow) mainWindow.minimize();
});
ipcMain.on('window-quit', () => {
  isQuitting = true;
  app.quit();
});

// ── IPC: 최초 사용자용 Claude Code 설치 + 로그인
// 콘솔 창을 띄워 진행 상황을 사용자가 직접 보게 한다 (숨긴 채 설치하지 않음).
// 위젯은 인증 파일이 생기는지 폴링만 하고, 인증 정보는 건드리지 않는다.
const LOGIN_PS1 = `
$ErrorActionPreference = 'Continue'
$bin = "$env:USERPROFILE\\.local\\bin"
if ($env:PATH -notlike "*$bin*") { $env:PATH = "$bin;$env:PATH" }

Write-Host ""
Write-Host "  Claude Code 로그인 설정" -ForegroundColor Cyan
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host ""

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Host "  [1/2] Claude Code 설치 중... 2~3분 걸립니다" -ForegroundColor Yellow
  irm https://claude.ai/install.ps1 | iex
  if ($env:PATH -notlike "*$bin*") { $env:PATH = "$bin;$env:PATH" }
} else {
  Write-Host "  [1/2] Claude Code 설치 확인됨" -ForegroundColor Green
}

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Host ""
  Write-Host "  설치 실패. 이 화면을 캡처해 공유해주세요." -ForegroundColor Red
  Write-Host ""
  Read-Host "  Enter 키를 누르면 닫힙니다"
  exit
}

Write-Host ""
Write-Host "  [2/2] 브라우저가 열립니다. 로그인해주세요" -ForegroundColor Yellow
Write-Host ""
claude auth login --claudeai

Write-Host ""
if (Test-Path "$env:USERPROFILE\\.claude\\.credentials.json") {
  Write-Host "  로그인 완료. 위젯이 자동으로 인식합니다." -ForegroundColor Green
  Write-Host "  이 창은 닫으셔도 됩니다." -ForegroundColor Green
} else {
  Write-Host "  로그인이 확인되지 않았습니다. 이 화면을 캡처해 공유해주세요." -ForegroundColor Red
  Write-Host "  USERPROFILE = $env:USERPROFILE" -ForegroundColor Red
}
Write-Host ""
Read-Host "  Enter 키를 누르면 닫힙니다"
`;

ipcMain.handle('start-login', async () => {
  if (process.platform !== 'win32') return { ok: false, error: 'UNSUPPORTED_PLATFORM' };
  try {
    const ps1 = path.join(os.tmpdir(), 'claude-widget-login.ps1');
    // BOM 없이 쓰면 Windows PowerShell 5.1이 한글을 깨뜨림
    fs.writeFileSync(ps1, '﻿' + LOGIN_PS1, 'utf8');
    // cmd /c start 로 띄워야 새 콘솔 창이 생긴다.
    // spawn(detached:true)만 쓰면 Windows가 DETACHED_PROCESS로 붙여 콘솔이 아예 없고,
    // 사용자는 진행 상황을 볼 수 없다 (260820 실측).
    const child = spawn(
      'cmd.exe',
      ['/c', 'start', 'Claude Code Login', 'powershell.exe',
       '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1],
      { detached: true, stdio: 'ignore', windowsHide: false }
    );
    child.unref();
    return { ok: true };
  } catch {
    return { ok: false, error: 'SPAWN_FAILED' };
  }
});

// ── 자동 업데이트 (GitHub Releases)
// 작업 중 창이 사라지면 안 되므로 다운로드만 백그라운드로 받고, 적용은 종료 시점에 한다.
// 사내망에서 GitHub이 막혀 있어도 조용히 실패해야 한다 — 위젯 자체는 계속 동작.
function initAutoUpdate() {
  if (!app.isPackaged) return;   // 개발 모드엔 update 메타데이터가 없어 항상 실패
  let autoUpdater;
  try { ({ autoUpdater } = require('electron-updater')); } catch { return; }
  autoUpdater.autoDownload = true;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.on('error', () => {});
  autoUpdater.on('update-downloaded', (info) => {
    if (tray) {
      tray.setToolTip(`Claude Usage Widget by R\n업데이트 준비됨 (v${info.version}) — 종료 후 재실행 시 적용`);
    }
  });

  const check = () => { try { autoUpdater.checkForUpdates()?.catch(() => {}); } catch {} };
  check();
  setInterval(check, 6 * 60 * 60 * 1000);   // 6시간마다
}

// ── 커서가 창 위에 있는지 감시
// 캐릭터 모드는 캐릭터 전체가 드래그 영역이라 CSS :hover 가 아예 동작하지 않는다.
// (Electron 드래그 영역은 마우스 이벤트를 페이지로 전달하지 않음 — 260821 실측)
// 그래서 커서 좌표를 직접 읽어 renderer 에 알린다.
function initHoverWatch() {
  const { screen } = require('electron');
  let last = null;
  setInterval(() => {
    if (!mainWindow || mainWindow.isDestroyed() || !mainWindow.isVisible()) return;
    const p = screen.getCursorScreenPoint();
    const b = mainWindow.getBounds();
    const inside = p.x >= b.x && p.x < b.x + b.width && p.y >= b.y && p.y < b.y + b.height;
    if (inside !== last) {
      last = inside;
      mainWindow.webContents.send('window-hover', inside);
    }
  }, 180);
}

function createTray() {
  // 16×16 Claude 오렌지 + 'C' 아이콘 (PowerShell로 사전 생성)
  const trayIconPath = path.join(__dirname, 'icon-16.png');
  const trayIcon = nativeImage.createFromPath(trayIconPath);
  tray = new Tray(trayIcon);
  tray.setToolTip('Claude Usage Widget by R');
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: '열기', click: revealWindow },
      { label: '항상 최상단 토글', click: () => mainWindow && setAlwaysOnTop(!mainWindow.isAlwaysOnTop()) },
      { type: 'separator' },
      { label: '종료', click: () => { isQuitting = true; app.quit(); } },
    ])
  );
  tray.on('click', () => {
    if (!mainWindow) return;
    const hidden = !mainWindow.isVisible() || mainWindow.isMinimized();
    hidden ? revealWindow() : mainWindow.hide();
  });
}

app.whenReady().then(async () => {
  await waitForServer();
  createWindow();
  createTray();
  initHoverWatch();
  initAutoUpdate();
});

app.on('before-quit', () => { isQuitting = true; });
app.on('window-all-closed', (e) => {
  // 트레이가 살아있으면 앱 유지 — 명시적 종료 시에만 quit
});
