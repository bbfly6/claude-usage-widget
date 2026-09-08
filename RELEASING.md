# 릴리스 절차

새 버전을 내보낼 때 보는 문서. **함정이 대부분 조용히 깨지는 종류라** 순서를 지켜야 한다.
자동 업데이트가 멈춰도 오류가 뜨지 않고, 사용자는 그냥 옛 버전을 계속 쓴다.

## 갈림길

| 무엇을 고쳤나 | 윈도우 PC 가 필요한가 |
|---|---|
| `mac/` 만 | 아니오 |
| `src/` · `docs/` · `package.json` 중 하나라도 | **예** — 윈도우 설치 파일을 다시 만들어야 한다 |

윈도우 설치 파일(`.exe`)은 맥에서 만들 수 없다(wine 없음).
`src/` 는 두 플랫폼이 공유하므로, 여기를 건드렸으면 윈도우도 다시 빌드해야 한다.

---

## 1. 버전 올리기

```bash
npm version 1.8.2 --no-git-tag-version
```

`package.json` 만 고치면 `package-lock.json` 이 뒤처져서, 윈도우에서 빌드할 때마다
수정된 파일로 잡힌다. 위 명령은 두 파일을 같이 맞춘다.

**버전을 안 올리면 자동 업데이트가 "이미 최신"으로 보고 아무 일도 안 한다.**

## 2. 커밋 · 푸시

푸시하면 GitHub Pages 가 `docs/` 를 다시 배포한다(1~2분).
설치 페이지 반영 여부는 이렇게 확인한다.

```bash
curl -s https://bbfly6.github.io/claude-usage-widget/ | grep -c "<찾을 문자열>"
```

## 3. 맥 빌드

```bash
ARCH=universal ./mac/build.sh
```

**`ARCH=universal` 을 빼면 애플 실리콘 전용이 나온다.**
설치 페이지는 "인텔 · 애플 실리콘" 이라고 안내하고 있으므로 인텔 맥에서 안 열린다.

```bash
lipo -archs "mac/dist/Claude Usage Widget by R.app/Contents/MacOS/ClaudeUsageWidget"
# x86_64 arm64  가 나와야 한다
```

`mac/dist/` 에 zip 2개(버전 있는 것 + 없는 것)와 각각의 `.sha256` 이 생긴다.

## 4. 윈도우 빌드 — 윈도우 PC 에서

```
git pull origin main
npm install
npm run build:win
```

`dist/` 에 exe · exe.blockmap · **latest.yml** 이 생긴다. latest.yml 이 없으면 중단.

### exe 는 하이픈 이름으로 바꿔 올린다

electron-builder 는 **파일은 공백 이름**으로 만들면서 **`latest.yml` 에는 하이픈 이름**을 적는다.
공백 이름 그대로 올리면 GitHub 이 공백을 점으로 바꾼다
(`Claude.Usage.Widget.by.R-Setup-x.y.z.exe`). 그러면 latest.yml 이 가리키는 주소가 404 다.

```
latest.yml 기재 : Claude-Usage-Widget-by-R-Setup-1.8.2.exe
빌드 산출물     : Claude Usage Widget by R-Setup-1.8.2.exe   ← 이름을 바꿔서 올린다
```

blockmap 도 하이픈이어야 한다. electron-updater 가 blockmap 주소를 `<exe 주소>.blockmap`
으로 만들기 때문이다. **blockmap 이 404 면 업데이트가 실패하는 게 아니라 97MB 를 통째로
다시 받는다** — 조용히 느려져서 못 알아챈다.

버전 없는 사본도 만든다. 설치 페이지의 내려받기 버튼이 고정 이름을 가리키기 때문이다.

```
copy "Claude Usage Widget by R-Setup-1.8.2.exe" "Claude-Usage-Widget-Setup.exe"
```

## 5. 릴리스는 **초안(draft)** 으로 만든다

두 기기에서 나눠 올리므로, 한쪽만 채운 채 공개하면 최신 릴리스가 바뀌면서
반대편 `releases/latest/download` 링크가 404 가 된다.
`latest.yml` 없는 릴리스가 최신이 되면 더 나쁘다 — 윈도우 자동 업데이트가 전면 중단된다.

초안은 "최신"으로 잡히지 않으므로 그 사이에도 옛 릴리스 링크가 살아 있다.

```bash
gh release create v1.8.2 --draft --title "v1.8.2" --notes "..."
gh release upload v1.8.2 <윈도우 4개>
gh release upload v1.8.2 <맥 4개>
gh release edit v1.8.2 --draft=false     # 양쪽 다 채운 뒤에만
```

### 맥만 고친 경우에도 윈도우 파일 4개가 필요하다

윈도우 코드가 안 바뀌었어도, **새 릴리스에 `latest.yml` 이 없으면 윈도우 사용자 전원이
업데이트를 못 받는다.** 직전 릴리스의 윈도우 4개를 그대로 옮겨 담는다.
내용이 같으니 윈도우 사용자에게는 "새 버전 없음"으로 보이고, 그게 맞는 동작이다.

```bash
gh release download <직전 태그> -p "*.exe" -p "*.blockmap" -p "latest.yml" -D /tmp/win
gh release upload <새 태그> /tmp/win/*
```

## 6. 자산 8개 확인

```
Claude-Usage-Widget-by-R-Setup-<ver>.exe            윈도우 설치 파일
Claude-Usage-Widget-by-R-Setup-<ver>.exe.blockmap   바뀐 부분만 받게 하는 색인
Claude-Usage-Widget-Setup.exe                       위와 같은 파일, 고정 이름
latest.yml                                          윈도우 자동 업데이트 기준
Claude-Usage-Widget-mac-<ver>.zip                   맥 앱 (유니버설)
Claude-Usage-Widget-mac-<ver>.zip.sha256            체크섬 — 있으면 반드시 통과해야 설치된다
Claude-Usage-Widget-mac.zip                         위와 같은 파일, 고정 이름
Claude-Usage-Widget-mac.zip.sha256
```

## 7. 공개 후 점검

```bash
for f in Claude-Usage-Widget-Setup.exe Claude-Usage-Widget-mac.zip \
         Claude-Usage-Widget-mac.zip.sha256 latest.yml \
         Claude-Usage-Widget-by-R-Setup-<ver>.exe.blockmap; do
  printf "%-50s %s\n" "$f" \
    "$(curl -sIL -o /dev/null -w '%{http_code}' \
       "https://github.com/bbfly6/claude-usage-widget/releases/latest/download/$f")"
done

curl -sL ".../releases/latest/download/latest.yml" | head -2   # version 이 새 버전인지
```

마지막으로 **자동 업데이트를 실제로 한 번 돌려본다.** 옛 버전 앱을 띄워
띠가 뜨고 교체까지 되는지 본다. 맥은 이렇게 확인할 수 있다.

```bash
open --env CLAUDE_WIDGET_DEBUG=1 --env CLAUDE_WIDGET_TEST_UPDATE=1 -a "<옛 버전 앱>"
grep -a "체크섬\|검증 통과\|교체 완료\|launch v" "$TMPDIR/claude-widget-mac.log"
```

---

## 맥 개발용 스위치

`open --env <이름>=1 -a <앱>` 로 켠다. 셸에서 `nohup ... &` 로 띄우면 세션이 끝날 때
앱이 같이 죽으므로 반드시 `open` 을 쓴다.

| 이름 | 하는 일 |
|---|---|
| `CLAUDE_WIDGET_DEBUG` | `$TMPDIR/claude-widget-mac.log` 기록 + 자가 점검 |
| `CLAUDE_WIDGET_CHAR_SHOT` | 캐릭터 모드 구간별 화면 캡처 |
| `CLAUDE_WIDGET_FEED` | 가짜 릴리스 JSON 을 물려 업데이트 경로 시험 |
| `CLAUDE_WIDGET_TEST_UPDATE` | 확인만 하지 않고 실제로 교체까지 |
| `CLAUDE_WIDGET_NO_OPEN` | 링크·미리보기를 눌러도 브라우저를 띄우지 않음 (자가 점검용) |

**`NO_OPEN` 을 켜둔 채 넘기면 "링크가 안 눌린다"로 보인다.** 점검이 끝나면 끄고 다시 띄운다.
