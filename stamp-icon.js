// dist/win-unpacked 의 앱 exe 에 아이콘·버전정보를 삽입한다.
//
// 왜 필요한가:
//   package.json 의 win.signAndEditExecutable = false 때문에 electron-builder 가
//   rcedit 단계를 통째로 건너뛴다. 그 결과 앱 exe 가 Electron 기본 아이콘 그대로 남고
//   바탕화면·작업표시줄·시작메뉴에 Electron 로고가 뜬다 (260820 실측).
//   이 설정을 켜면 winCodeSign 압축 해제 시 macOS 심볼릭 링크 생성 권한이 없어
//   빌드 자체가 실패하므로, rcedit 만 따로 호출한다.
//
// 사용: npm run build:win  (dir 빌드 → 이 스크립트 → prepackaged nsis)

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const pkg = require('./package.json');
const productName = pkg.build.productName;
const appExe = path.join(__dirname, 'dist', 'win-unpacked', `${productName}.exe`);
const iconPath = path.join(__dirname, 'src', 'icon.ico');

function findRcedit() {
  const cache = path.join(os.homedir(), 'AppData', 'Local', 'electron-builder', 'Cache', 'winCodeSign');
  if (!fs.existsSync(cache)) return null;
  for (const dir of fs.readdirSync(cache)) {
    const candidate = path.join(cache, dir, 'rcedit-x64.exe');
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

if (!fs.existsSync(appExe)) {
  console.error(`[stamp-icon] 대상 없음: ${appExe}`);
  console.error('[stamp-icon] 먼저 electron-builder --win --dir 를 실행하세요.');
  process.exit(1);
}

const rcedit = findRcedit();
if (!rcedit) {
  console.error('[stamp-icon] rcedit-x64.exe 를 찾지 못했습니다.');
  console.error('[stamp-icon] electron-builder 를 한 번 실행해 winCodeSign 캐시를 받아주세요.');
  process.exit(1);
}

execFileSync(rcedit, [
  appExe,
  '--set-icon', iconPath,
  '--set-version-string', 'ProductName', productName,
  '--set-version-string', 'FileDescription', pkg.description,
  '--set-version-string', 'CompanyName', pkg.author,
  '--set-version-string', 'InternalName', productName,
  '--set-version-string', 'OriginalFilename', `${productName}.exe`,
  '--set-file-version', pkg.version,
  '--set-product-version', pkg.version,
], { stdio: 'inherit' });

console.log(`[stamp-icon] 아이콘·버전정보 삽입 완료 (v${pkg.version})`);
