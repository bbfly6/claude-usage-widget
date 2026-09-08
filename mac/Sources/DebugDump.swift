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
        let sizes = try? await webView.evaluateJavaScript("""
        (() => {
          const p = document.querySelector('#settingsPanel');
          const c = document.querySelector('.content');
          const g = document.querySelector('.settings-group');
          return `패널=${p.offsetHeight} 콘텐츠=${c.offsetHeight} 창=${window.innerHeight} 그룹1개=${g.offsetHeight}`;
        })()
        """)
        Dbg.log("[측정] 설정패널 \(sizes ?? "?")")
        // 맥 전용 설정이 창 안에 제대로 들어갔는지
        let mac = try? await webView.evaluateJavaScript("""
        (() => {
          const h = document.querySelector('#macSettings');
          if (!h) return 'none';
          const b = [...h.querySelectorAll('.mac-seg-btn')].map(x => x.textContent.trim() + (x.classList.contains('active') ? '*' : ''));
          const l = [...h.querySelectorAll('.mac-link')].map(x => x.textContent.trim());
          const styled = getComputedStyle(h.querySelector('.mac-seg-btn')).borderRadius;
          return `버튼=${b.join(' ')} 링크=${l.join(' ')} 모서리=${styled} 높이=${h.offsetHeight}`;
        })()
        """)
        Dbg.log("[검증] 맥설정 \(mac ?? "?")")

        // 창에서 누른 것이 실제로 네이티브에 닿는지 — % 표시를 창에서 껐다 켠다
        _ = try? await webView.evaluateJavaScript(
            "document.querySelector('.mac-seg-btn[data-mac=\"percent\"][data-val=\"0\"]').click()")
        try? await Task.sleep(for: .milliseconds(400))
        let offTitle = statusTitle()
        _ = try? await webView.evaluateJavaScript(
            "document.querySelector('.mac-seg-btn[data-mac=\"percent\"][data-val=\"1\"]').click()")
        try? await Task.sleep(for: .milliseconds(400))
        Dbg.log("[검증] 창에서 %표시 끔='\(offTitle)' 켬='\(statusTitle())'")
        Dbg.log("[검증] 우클릭 메뉴 = \(menuTitlesForTest())")

        // '캐릭터 전체 보기' 는 index.html(윈도우와 공유) 의 링크를 맥 설정 줄로 옮겨 심은 것이다.
        // 맥 설정이 다시 그려질 때(위의 % 토글) 같이 지워지면 링크가 사라진다 (260908).
        let previewPath = NSTemporaryDirectory() + "claude-widget-characters.html"
        try? FileManager.default.removeItem(atPath: previewPath)
        let moved = try? await webView.evaluateJavaScript("""
        (() => {
          const a = document.querySelector('#previewChars');
          if (!a) return 'link-gone';
          a.click();
          return a.parentElement.id + '/' + a.textContent.trim();
        })()
        """)
        try? await Task.sleep(for: .milliseconds(700))
        let made = FileManager.default.fileExists(atPath: previewPath)
        Dbg.log("[검증] 캐릭터 전체 보기 \(moved as? String ?? "?") 페이지생성=\(made)")

        // 링크를 옮기고 나면 원래 자리에 빈 껍데기가 남는다 — 설정창에 빈 줄로 보이면 안 된다
        let leftover = try? await webView.evaluateJavaScript("""
        (() => {
          const d = document.querySelector('#settingsPanel > .settings-link');
          return d ? '아직 원래 자리에 있음' : '남은 것 없음';
        })()
        """)
        Dbg.log("[검증] 옮긴 뒤 원래 자리 \(leftover as? String ?? "?")")

        // 'Learn more' 는 renderer 가 window.open 을 쓴다.
        // uiDelegate 가 없으면 WKWebView 가 요청을 조용히 버려 링크가 죽는다 (260908).
        AppDelegate.lastExternal = nil
        let hasLink = try? await webView.evaluateJavaScript(
            "(() => { const a = document.querySelector('#learnMore'); if (!a) return 'no-elem'; a.click(); return a.textContent.trim() })()")
        try? await Task.sleep(for: .milliseconds(400))
        Dbg.log("[검증] Learn more '\(hasLink as? String ?? "?")' uiDelegate=\(webView.uiDelegate != nil) 열림=\(AppDelegate.lastExternal ?? "없음")")

        // 실제 위젯의 캐릭터 모드 — CHAR_SHOT=1 일 때만
        if ProcessInfo.processInfo.environment["CLAUDE_WIDGET_CHAR_SHOT"] == "1" {
            // 앞 단계에서 설정 패널이 열려 있으면 캐릭터가 가려진다
            _ = try? await webView.evaluateJavaScript("""
            (() => {
              const p = document.querySelector('#settingsPanel');
              if (p && p.style.display !== 'none') document.querySelector('#settingsBtn').click();
            })()
            """)
            try? await Task.sleep(for: .milliseconds(300))
            _ = try? await webView.evaluateJavaScript(
                "document.querySelector('.mode-btn[data-mode=\"character\"]').click()")
            try? await Task.sleep(for: .milliseconds(1200))
            for t in ["tier-sleep", "tier-walk-slow", "tier-walk-fast", "tier-jump",
                      "tier-fire", "tier-fire-hot", "tier-dead", "tier-revive"] {
                _ = try? await webView.evaluateJavaScript("""
                (() => {
                  const s = document.querySelector('#charStage');
                  s.className = 'char-stage ' + '\(t)';
                })()
                """)
                // 부활은 3.6초짜리 1회 연출이다. 500ms 에서 찍으면 아직 빛만 내려온 참이라
                // 정작 확인해야 할 '떠오른 정점'(74%)을 못 본다.
                try? await Task.sleep(for: .milliseconds(t == "tier-revive" ? 2650 : 500))
                await snapshot("char-\(t)")
                if t == "tier-jump" {
                    // 좌우로 서성이는 폭이 창(240px) 안에 들어오는지 — 양 끝에서 잰다
                    let pace = try? await webView.evaluateJavaScript("""
                    (() => {
                      const w = document.querySelector('#charWalker');
                      const st = document.querySelector('#charStage').getBoundingClientRect();
                      const at = (d) => { w.style.animationDelay = d; w.style.animationPlayState = 'paused';
                                          const r = w.getBoundingClientRect(); return [r.left, r.right]; };
                      const l = at('0s'), r = at('-3.4s');
                      w.style.animationDelay = ''; w.style.animationPlayState = '';
                      const lo = Math.min(l[0], r[0]), hi = Math.max(l[1], r[1]);
                      return `왼쪽끝=${Math.round(lo)} 오른쪽끝=${Math.round(hi)} `
                           + `무대=${Math.round(st.left)}~${Math.round(st.right)} `
                           + `잘림=${lo < st.left || hi > st.right}`;
                    })()
                    """)
                    Dbg.log("[검증] 다급 서성임 \(pace as? String ?? "?")")
                }
                if t == "tier-revive" {
                    // 정점에서 머리가 창 밖으로 나가지 않는지 — 캐릭터 창은 240×210 으로 좁다
                    let fit = try? await webView.evaluateJavaScript("""
                    (() => {
                      const st = document.querySelector('#charStage').getBoundingClientRect();
                      const b  = document.querySelector('#charBody').getBoundingClientRect();
                      const w  = document.querySelector('.wg-wing-l').getBoundingClientRect();
                      const top = Math.min(b.top, w.top);
                      const cs = getComputedStyle(document.querySelector('.wg-wing-l'));
                      const th = document.documentElement.getAttribute('data-theme');
                      return `무대=${Math.round(st.top)}~${Math.round(st.bottom)} `
                           + `캐릭터위=${Math.round(b.top)} 날개=${Math.round(w.top)}~${Math.round(w.bottom)}`
                           + `x${Math.round(w.width)} 불투명=${cs.opacity} 테마=${th} `
                           + `윤곽=${(cs.filter||'').slice(0, 42)} `
                           + `창=${innerWidth}x${innerHeight} 잘림=${top < 0 || top < st.top - 1}`;
                    })()
                    """)
                    Dbg.log("[검증] 부활 정점 \(fit as? String ?? "?")")
                }
            }
            _ = try? await webView.evaluateJavaScript(
                "document.querySelector('.mode-btn[data-mode=\"default\"]').click()")
        }

        // 새 버전이 없을 때 띠가 정말 안 보이는지 — 빈 박스가 남은 적이 있다 (260907)
        let idleBar = try? await webView.evaluateJavaScript("""
        (() => {
          const b = document.querySelector('#macUpdate');
          if (!b) return 'none';
          const cs = getComputedStyle(b);
          return `hidden=${b.hidden} display=${cs.display} 높이=${b.offsetHeight}`;
        })()
        """)
        Dbg.log("[검증] 업데이트 없을 때 띠 \(idleBar ?? "?")")

        // 업데이트 — CLAUDE_WIDGET_FEED 로 가짜 릴리스를 물려 끝까지 돌려본다.
        // TEST_UPDATE=1 이면 실제로 교체까지 한다 (앱이 재시작된다).
        let env = ProcessInfo.processInfo.environment
        // FEED 는 가짜 릴리스를 물릴 때, TEST_UPDATE 는 실제 GitHub 로 끝까지 돌려볼 때 쓴다
        if env["CLAUDE_WIDGET_FEED"] != nil || env["CLAUDE_WIDGET_TEST_UPDATE"] == "1" {
            let r = await Updater.check()
            Dbg.log("[검증] 업데이트 확인 현재=\(Updater.current) 최신=\(r?.version ?? "없음")")
            try? await Task.sleep(for: .milliseconds(300))
            let bar = try? await webView.evaluateJavaScript("""
            (() => {
              const b = document.querySelector('#macUpdate');
              if (!b) return 'none';
              const btn = b.querySelector('.mac-update-btn');
              return `보임=${!b.hidden} 글=${(b.textContent||'').trim()} 버튼=${btn ? btn.textContent : '-'} 높이=${b.offsetHeight}`;
            })()
            """)
            Dbg.log("[검증] 업데이트 띠 \(bar ?? "?")")
            await snapshot("update")
            if r != nil, env["CLAUDE_WIDGET_TEST_UPDATE"] == "1" {
                Dbg.log("[검증] 업데이트 설치 시작")
                await Updater.install()
            }
        }
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

        // 5) 알림 — 권한 상태만 읽는다.
        //    권한 요청은 사용자가 메뉴에서 켤 때만 한다. 실행할 때 물으면
        //    무엇을 허용하는지 모르는 채로 대화상자를 만나고, 그때 답을 안 하면
        //    '거부'로 굳어 이후 요청이 UNErrorDomain Code=1 로 막힌다 (260904 실측).
        await Notifications.refreshAuthorization()
        Dbg.log("[검증] 알림 사용가능=\(Notifications.authorized) 켬=\(Prefs.notifyThresholds)")
        // 임계값 규칙은 권한과 무관하게 검증할 수 있다 — 판정과 발송을 분리해 뒀다.
        Notifications.resetFired()
        var trace: [String] = []
        for p in [70.0, 85, 88, 92, 95, 40, 85] {
            let d = Notifications.decide(kind: "test", label: "세션", percent: p, korean: true)
            trace.append("\(Int(p))%->\(d.isEmpty ? "-" : d.map(\.id).joined(separator: "+"))")
        }
        Notifications.resetFired()
        Dbg.log("[검증] 임계값 판정 " + trace.joined(separator: " "))

        // 4) 단축키 — 실제 키 입력 없이 등록 상태와 발동 경로만 확인한다
        Dbg.log("[검증] 단축키 \(Prefs.hotKeyLabel) 등록=\(HotKeyCenter.shared.isActive) 콜백연결=\(HotKeyCenter.shared.onFire != nil)")
    }
}
