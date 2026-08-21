// Renderer ↔ Main 안전한 IPC 다리.
// contextIsolation 환경에서 renderer가 require/ipcRenderer 직접 못 쓰므로
// window.widgetAPI.* 함수만 노출.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('widgetAPI', {
  minimize: () => ipcRenderer.send('window-minimize'),
  quit: () => ipcRenderer.send('window-quit'),
  login: () => ipcRenderer.invoke('start-login'),
  setWindowMode: (mode) => ipcRenderer.invoke('set-window-mode', mode),
  setAlwaysOnTop: (flag) => ipcRenderer.invoke('set-always-on-top', flag),
  // 트레이 메뉴에서 바뀐 경우에도 설정 버튼이 따라오도록
  // 캐릭터 모드 컨트롤 노출용 (CSS :hover 가 드래그 영역에서 안 먹음)
  onWindowHover: (cb) => ipcRenderer.on('window-hover', (_e, inside) => cb(inside)),
  onAlwaysOnTopChanged: (cb) => ipcRenderer.on('always-on-top-changed', (_e, flag) => cb(flag)),
});
