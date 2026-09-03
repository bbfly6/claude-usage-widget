import AppKit

// src/main.js 의 LOGIN_PS1 에 대응하는 맥 버전.
// Windows 와 같은 원칙: 숨긴 채 설치하지 않고 터미널 창을 띄워 사용자가 진행을 직접 본다.
// 위젯은 인증 정보를 만들지도 건드리지도 않는다 — Claude Code 가 만들어 주기를 기다릴 뿐이다.
enum Login {
    static let script = """
    #!/bin/bash
    export PATH="$HOME/.local/bin:$PATH"

    printf '\\n  Claude Code 로그인 설정\\n'
    printf '  ----------------------------------------\\n\\n'

    if ! command -v claude >/dev/null 2>&1; then
      printf '  [1/2] Claude Code 설치 중... 2~3분 걸립니다\\n'
      curl -fsSL https://claude.ai/install.sh | bash
      export PATH="$HOME/.local/bin:$PATH"
    else
      printf '  [1/2] Claude Code 설치 확인됨\\n'
    fi

    if ! command -v claude >/dev/null 2>&1; then
      printf '\\n  설치 실패. 이 화면을 캡처해 공유해주세요.\\n\\n'
      read -r -p '  Enter 키를 누르면 닫힙니다'
      exit 1
    fi

    printf '\\n  [2/2] 브라우저가 열립니다. 로그인해주세요\\n\\n'
    claude auth login --claudeai

    printf '\\n'
    # 값은 절대 출력하지 않는다 — 항목 존재 여부만 확인한다
    if security find-generic-password -s 'Claude Code-credentials' -a "$USER" >/dev/null 2>&1 \\
       || [ -f "$HOME/.claude/.credentials.json" ]; then
      printf '  로그인 완료. 위젯이 자동으로 인식합니다.\\n'
      printf '  이 창은 닫으셔도 됩니다.\\n'
    else
      printf '  로그인이 확인되지 않았습니다. 이 화면을 캡처해 공유해주세요.\\n'
      printf '  HOME = %s\\n' "$HOME"
    fi
    printf '\\n'
    read -r -p '  Enter 키를 누르면 닫힙니다'
    """

    /// 터미널에서 로그인 스크립트를 실행한다. 반환값은 renderer 의 login() 계약과 동일.
    static func start() -> [String: Any] {
        let path = NSTemporaryDirectory() + "claude-widget-login.command"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            // .command 는 더블클릭·open 으로 터미널에서 실행된다. 실행 권한이 없으면 열리지 않는다.
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: path)
        } catch {
            return ["ok": false, "error": "SPAWN_FAILED"]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", path]
        do { try p.run() } catch { return ["ok": false, "error": "SPAWN_FAILED"] }
        return ["ok": true]
    }
}
