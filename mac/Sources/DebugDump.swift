import AppKit

// 개발 확인용. CLAUDE_WIDGET_DEBUG=1 일 때만 동작하며 배포 전 이 파일만 지우면 된다.
@MainActor
extension AppDelegate {
    func dumpFrameSheet() async {
        guard Dbg.enabled, !AppDelegate.sheetDumped, let ci = charIcon else { return }
        AppDelegate.sheetDumped = true
        let tiers: [(String, Double)] = [("sleep", 5), ("chill", 20), ("focus", 40),
                                         ("rush", 70), ("fire", 85), ("hot", 95), ("dead", 100)]
        // lockFocus 는 await 를 건너면 컨텍스트가 풀린다 — 먼저 전부 모은다.
        var rows: [[NSImage]] = []
        for t in tiers { rows.append(await ci.frames(forPercent: t.1)) }
        rows.append(await ci.frames(tier: CharacterIcon.reviveTier))
        let cell = 26.0
        let cols = Double(rows.map(\.count).max() ?? 1)
        let sheet = NSImage(size: NSSize(width: cell * cols, height: cell * Double(rows.count)))
        sheet.lockFocus()
        // 흰 배경이면 흰 날개가 묻혀 안 보인다 (260903). 다크 메뉴바 색으로 깐다.
        // 위 절반은 다크 메뉴바, 아래 절반은 라이트 메뉴바 색 — 양쪽에서 보이는지 한 번에 본다
        NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: cell * cols, height: cell * Double(rows.count)).fill()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: cell * cols, height: cell).fill()
        for (r, row) in rows.enumerated() {
            for (c, img) in row.enumerated() {
                let y = (Double(rows.count) - 1 - Double(r)) * cell
                img.draw(in: NSRect(x: Double(c) * cell + 2, y: y + 2, width: 22, height: 22))
            }
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "claude-frames.png"))
        }
        let names = tiers.map(\.0) + ["revive"]
        Dbg.log("프레임 시트: " + rows.enumerated().map { "\(names[$0.offset])=\($0.element.count)" }.joined(separator: " "))
    }

    /// 맥 전용 설정 4종이 실제로 먹는지 스스로 눌러보고 원래대로 되돌린다.
    /// 사용자 시스템 설정(다크모드)을 건드리지 않고 검증하기 위한 것.
    func selfTest() async {
        guard Dbg.enabled else { return }

        // 1) 시스템 테마 추종 — 네이티브가 알려주는 경로를 그대로 태운다
        let before = try? await webView.evaluateJavaScript("document.documentElement.getAttribute('data-theme')")
        _ = try? await webView.evaluateJavaScript("localStorage.setItem('macThemeMode','system')")
        for want in ["light", "dark"] {
            _ = try? await webView.evaluateJavaScript("window.__macAppearanceChanged('\(want)')")
            try? await Task.sleep(for: .milliseconds(120))
            let got = try? await webView.evaluateJavaScript("document.documentElement.getAttribute('data-theme')")
            let act = try? await webView.evaluateJavaScript(
                "document.querySelector('#macThemeSystem').classList.contains('active')")
            Dbg.log("[검증] 시스템테마 \(want) -> data-theme=\(got ?? "?") 시스템버튼활성=\(act ?? "?")")
        }
        _ = try? await webView.evaluateJavaScript("localStorage.setItem('macThemeMode','manual')")
        if let b = before as? String {
            _ = try? await webView.evaluateJavaScript(
                "document.querySelector('.theme-btn[data-theme=\"\(b)\"]').click()")
        }

        // 2) 메뉴바 % 표시
        let on = statusTitle()
        togglePercentForTest()
        let off = statusTitle()
        togglePercentForTest()
        Dbg.log("[검증] %표시 켬='\(on)' 끔='\(off)' 복원='\(statusTitle())'")

        // 3) 로그인 시 자동 시작 — 상태만 읽는다.
        //    예전엔 여기서 켰다 껐는데, unregister 직후의 status 가 아직 갱신되지 않아
        //    '되돌렸다'고 로그를 남기고도 실제로는 켜진 채로 남았다 (260904 실측).
        //    사용자 시스템에 남는 설정이므로 점검이 건드리지 않는다.
        Dbg.log("[검증] 자동시작 현재=\(LaunchAtLogin.isEnabled) 승인필요=\(LaunchAtLogin.needsApproval)")
        // 점검이 켜놓고 간 것을 한 번 정리한다 (CLAUDE_WIDGET_RESET_LOGIN=1)
        if ProcessInfo.processInfo.environment["CLAUDE_WIDGET_RESET_LOGIN"] == "1" {
            LaunchAtLogin.set(false)
            try? await Task.sleep(for: .milliseconds(500))
            Dbg.log("[정리] 자동시작 해제 -> \(LaunchAtLogin.isEnabled)")
        }

        // 설정 화면 캡처 — '시스템' 버튼이 320px 폭에서 어떻게 앉는지 눈으로 본다
        _ = try? await webView.evaluateJavaScript("document.querySelector('#settingsBtn').click()")
        try? await Task.sleep(for: .milliseconds(300))
        await snapshot("settings")
        // 테마 버튼 3개가 한 줄에 앉는지 — 한국어/영어 둘 다 본다.
        // offsetTop 이 전부 같으면 한 줄이다.
        let rowCheck = """
        (() => {
          const t = [...document.querySelectorAll('.theme-btn')];
          return t.map(b => b.offsetTop).join(',') + ' / ' + t.map(b => b.textContent).join(' ');
        })()
        """
        // 점검이 끝나면 원래 언어로 돌려놔야 한다 — 안 그러면 확인만 했는데 화면이 영어로 바뀐다
        let langBefore = (try? await webView.evaluateJavaScript(
            "(JSON.parse(localStorage.getItem('claudeWidgetSettings'))||{}).lang || 'en'")) as? String ?? "en"
        for lang in ["ko", "en"] {
            _ = try? await webView.evaluateJavaScript(
                "document.querySelector('.lang-btn[data-lang=\"\(lang)\"]').click()")
            try? await Task.sleep(for: .milliseconds(150))
            let r = try? await webView.evaluateJavaScript(rowCheck)
            Dbg.log("[검증] 테마버튼 줄바꿈(\(lang)) offsetTop=\(r ?? "?")")
        }
        _ = try? await webView.evaluateJavaScript(
            "document.querySelector('.lang-btn[data-lang=\"\(langBefore)\"]').click()")
        _ = try? await webView.evaluateJavaScript("document.querySelector('#settingsBtn').click()")

        // 4) 단축키 — 실제 키 입력 없이 등록 상태와 발동 경로만 확인한다
        Dbg.log("[검증] 단축키 \(Prefs.hotKeyLabel) 등록=\(HotKeyCenter.shared.isActive) 콜백연결=\(HotKeyCenter.shared.onFire != nil)")
    }
}
