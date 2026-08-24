// dist/win-unpacked 의 앱 exe 에 아이콘·버전정보를 삽입한다.
//
// 왜 필요한가:
//   package.json 의 win.signAndEditExecutable = false 때문에 electron-builder 가
//   rcedit 단계를 통째로 건너뛴다. 그 결과 앱 exe 가 Electron 기본 아이콘 그대로 남고
//   바탕화면·작업표시줄·시작메뉴에 Electron 로고가 뜬다 (260820 실측).
//   이 설정을 켜면 winCodeSign 압축 해제 시 macOS 심볼릭 링크 생성 권한이 없어
//   빌드 자체가 실패하므로, rcedit 만 따로 호출한다.
//
// 어떻게 실행되나:
//   package.json 의 build.afterPack 훅으로 electron-builder 가 직접 호출한다
//   (pack 직후 · nsis 패키징 직전). 단독 실행도 가능: node stamp-icon.js
//
// afterPack 훅이어야 하는 이유:
//   예전엔 `--dir 빌드 → 이 스크립트 → --prepackaged nsis` 3단계였는데,
//   electron-builder 는 app-update.yml 을 onAfterPack 에서 "nsis 같은 실제 타겟이
//   있을 때만" 기록한다. 1단계는 타겟이 dir 이라 조기 반환되고 3단계는 pack 을
//   건너뛰므로, 그 구조에선 app-update.yml 이 영영 안 생겨 자동 업데이트가
//   ENOENT 로 죽었다 (260824 실측). 훅으로 바꾸면 정상 빌드 흐름에 얹혀 해결된다.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const pkg = require('./package.json');
const productName = pkg.build.productName;
const iconPath = path.join(__dirname, 'src', 'icon.ico');
const DEFAULT_OUT_DIR = path.join(__dirname, 'dist', 'win-unpacked');

function findRcedit() {
  const cache = path.join(os.homedir(), 'AppData', 'Local', 'electron-builder', 'Cache', 'winCodeSign');
  if (!fs.existsSync(cache)) return null;
  for (const dir of fs.readdirSync(cache)) {
    const candidate = path.join(cache, dir, 'rcedit-x64.exe');
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function stamp(appOutDir) {
  const appExe = path.join(appOutDir, `${productName}.exe`);

  if (!fs.existsSync(appExe)) {
    console.error(`[stamp-icon] 대상 없음: ${appExe}`);
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
}

// electron-builder afterPack 훅 진입점
module.exports = function (context) {
  if (context.electronPlatformName !== 'win32') return;
  stamp(context.appOutDir);
};

// 단독 실행 (node stamp-icon.js)
if (require.main === module) stamp(DEFAULT_OUT_DIR);
