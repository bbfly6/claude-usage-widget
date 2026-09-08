import AppKit
import WebKit
import Carbon.HIToolbox   // 전역 단축키 keyCode 상수

// src/main.js 의 WINDOW_MODES 와 같은 값이어야 한다.
struct WindowMode {
    let w: CGFloat, h: CGFloat, minW: CGFloat, minH: CGFloat, resizable: Bool
}
let WINDOW_MODES: [String: WindowMode] = [
    "default":   .init(w: 320, h: 500, minW: 300, minH: 440, resizable: true),
    "mini":      .init(w: 320, h: 200, minW: 260, minH: 170, resizable: false),
    "character": .init(w: 240, h: 210, minW: 200, minH: 190, resizable: false),
    "settings":  .init(w: 320, h: 440, minW: 300, minH: 380, resizable: false),
]

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {

    private var statusItem: NSStatusItem!
    private var panel: WidgetPanel!
    private var web: WKWebView!
    private var alwaysOnTop = false
    private var hoverTimer: Timer?
    var charIcon: CharacterIcon?
    private var lastTier = ""
    private var animFrames: [NSImage] = []
    private var animIndex = 0
    private var animTimer: Timer?
    private var previewTask: Task<Void, Never>?
    private var lastPercent: Double = 0
    private var napToken: NSObjectProtocol?
    private var reviving = false
    private var prevPercent: Double = -1
    private var revivePrewarmed = false
    private var uiLang = "en"
    static var sheetDumped = false
    static var selfTested = false
    private var lastHoverInside: Bool?
    /// 시스템 다크/라이트가 바뀌는 걸 지켜본다. 해제하려면 보관해야 한다.
    private var appearanceObs: NSKeyValueObservation?
    private var updateTimer: Timer?

    // 창 드래그 (Electron 의 -webkit-app-region: drag 대체)
    private var dragMonitors: [Any] = []
    private var dragMouseStart: NSPoint = .zero
    private var dragWindowStart: NSPoint = .zero

    func applicationDidFinishLaunching(_ n: Notification) {
        Dbg.log("launch v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        // macOS 는 상시 상주하는 배경 앱을 App Nap 으로 재운다.
        // 그러면 메뉴바 애니메이션 타이머가 멈췄다가 사용자가 클릭할 때만 깨어난다 (260903 증상).
        napToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "menu bar character animation")
        buildWebView()
        buildPanel()
        buildStatusItem()
        startHoverWatch()
        startAppearanceWatch()
        // 이미 허용해 둔 사용자라면 묻지 않고 바로 쓸 수 있어야 한다. 상태만 읽는다.
        Task { await Notifications.refreshAuthorization() }
        startUpdateWatch()
        HotKeyCenter.shared.onFire = { [weak self] in self?.toggleByHotKey() }
        HotKeyCenter.shared.reload()
        // 상태아이템이 메뉴바에 자리를 잡은 뒤에 띄워야 위치가 맞는다.
        waitForStatusItemThenShow()
    }

    private func waitForStatusItemThenShow(attempt: Int = 0) {
        if statusItemFrame != nil || attempt >= 40 {
            showPanel()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForStatusItemThenShow(attempt: attempt + 1)
        }
    }

    // MARK: - WebView

    private func buildWebView() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        // 브리지는 renderer.js 보다 먼저 들어가야 한다 (documentStart)
        let uiDir = Bundle.main.resourceURL!.appendingPathComponent("ui")
        // style.css 에서 드래그 영역 선택자를 뽑아 브리지보다 먼저 주입한다
        var prelude = ""
        if let css = try? String(contentsOf: uiDir.appendingPathComponent("style.css"), encoding: .utf8) {
            let r = DragRegions.parse(css)
            Dbg.log("drag 선택자: '\(r.drag)'")
            Dbg.log("no-drag 선택자: '\(r.noDrag)'")
            let enc = { (v: String) -> String in
                String(data: try! JSONSerialization.data(withJSONObject: [v], options: []), encoding: .utf8)!
            }
            prelude = "window.__DRAG_SEL=\(enc(r.drag))[0];window.__NODRAG_SEL=\(enc(r.noDrag))[0];"
        }
        // 시스템 테마 추종용. 화면이 그려지기 전에 알려줘야 처음부터 맞는 색으로 뜬다.
        prelude += "window.__MAC_APPEARANCE='\(AppDelegate.systemAppearance())';"
        if let js = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let src = try? String(contentsOf: js, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: prelude + src, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        }
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "bridge")
        cfg.userContentController = ucc

        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 500), configuration: cfg)
        web.navigationDelegate = self
        // window.open 을 받으려면 필요하다. 없으면 renderer 의 'Learn more' 가 조용히 아무 일도 안 한다.
        web.uiDelegate = self
        // 투명 배경 — 창 자체가 투명해야 style.css 의 둥근 모서리가 산다
        web.setValue(false, forKey: "drawsBackground")
        // 웹 컨텐츠를 앱처럼 보이게: 우클릭 메뉴·확대 제스처 제거
        web.allowsMagnification = false

        web.loadFileURL(uiDir.appendingPathComponent("index.html"), allowingReadAccessTo: uiDir)
    }

    // MARK: - Panel
    // NSPopover 가 아니라 NSPanel 을 쓴다.
    // 캐릭터 모드처럼 화면에 띄워두고 쓰는 용도가 있어 '항상 최상단'·자유 배치가 필요하고,
    // 그래야 Windows 버전의 창 동작과 1:1로 맞는다.

    private func buildPanel() {
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // style.css 가 그림자를 직접 그린다
        panel.isMovableByWindowBackground = false   // 드래그는 app-region 으로 직접 처리
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = web
        applyMode("default")
    }

    /// 사용자가 직접 연 경우 true. 이때만 앱을 활성화한다.
    /// 자동 표시(실행 직후)까지 활성화하면 쓰던 앱에서 포커스를 뺏는다.
    private func showPanel(userInitiated: Bool) {
        showPanel()
        if userInitiated {
            // 비활성 앱 위에서는 WKWebView 가 요소별 커서를 갱신하지 못해
            // 창 전체가 화살표이거나 전체가 손가락으로 굳는다 (260903 증상).
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showPanel() {
        let wasHidden = !panel.isVisible
        if wasHidden, !restoreSessionOrigin() { positionUnderStatusItem() }
        // NSApp.activate 를 부르면 사용자가 쓰던 앱에서 포커스를 뺏는다.
        // 메뉴바 위젯이 로그인 직후나 자동 갱신 때 앞으로 튀어나오면 안 된다.
        // .nonactivatingPanel 이라 앱을 활성화하지 않고도 클릭·입력을 받는다.
        if wasHidden { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.acceptsMouseMovedEvents = true
        statusItem.button?.highlight(true)      // 다른 메뉴바 앱처럼 눌린 표시를 남긴다
        if Dbg.enabled, let f = statusItemFrame {
            Dbg.log("정렬: 아이콘mid=\(Int(f.midX)) 아이콘하단=\(Int(f.minY)) / 창mid=\(Int(panel.frame.midX)) 창상단=\(Int(panel.frame.maxY)) → 가로차=\(Int(panel.frame.midX - f.midX))px 세로간격=\(Int(f.minY - panel.frame.maxY))px")
        }
        if wasHidden {
            // 툭 나타나면 이질적이다. 아주 짧게만 페이드 — 길면 느리게 느껴진다.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.11
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    /// 상태아이템이 화면에 자리를 잡았는가.
    /// 앱 시작 직후엔 아직 레이아웃 전이라 좌표가 (0,0) 이고, 그대로 계산하면
    /// 창이 화면 왼쪽 끝으로 튕겨나간다 (260903 실측: 아이콘 x=907 인데 창 x=8).
    private var statusItemFrame: NSRect? {
        guard let sb = statusItem?.button, let sw = sb.window,
              let screen = sw.screen ?? NSScreen.main else { return nil }
        let f = sw.convertToScreen(sb.bounds)
        // 폭·높이만 보면 (0,0) 짜리 초기값도 통과한다. 실제로 '메뉴바 높이에 있는가'까지 본다.
        guard f.width > 1, f.height > 1,
              f.minY > screen.frame.maxY - 80 else { return nil }
        return f
    }

    private func positionUnderStatusItem() {
        guard let f = statusItemFrame,
              let screen = statusItem.button?.window?.screen ?? NSScreen.main else {
            panel.center(); return
        }
        var x = f.midX - panel.frame.width / 2
        // 메뉴바 바로 아래 — 다른 메뉴바 앱의 팝오버와 같은 간격
        let y = f.minY - panel.frame.height - 5
        x = min(max(x, screen.visibleFrame.minX + 8),
                screen.visibleFrame.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // ── 창 위치 기억 (세션 한정)
    // 앱을 켜 둔 동안 드래그로 옮긴 자리는 계속 유지하고,
    // 앱을 껐다 켜면 메뉴바 아이콘 아래에서 다시 시작한다.
    // 디스크에 저장하지 않으므로 재실행하면 자연히 초기화된다.
    private var sessionOrigin: NSPoint?

    private func saveSessionOrigin() {
        guard panel.isVisible else { return }   // 자리도 못 잡은 좌표를 저장하면 안 된다
        sessionOrigin = panel.frame.origin
    }

    private func restoreSessionOrigin() -> Bool {
        guard let p = sessionOrigin else { return false }
        // 모니터 구성이 바뀌어 그 자리가 사라졌으면 무시한다
        let r = NSRect(origin: p, size: panel.frame.size)
        let visible = NSScreen.screens.map { $0.visibleFrame.intersection(r) }
            .map { $0.isNull ? 0 : $0.width * $0.height }.max() ?? 0
        guard visible >= r.width * r.height * 0.5 else { sessionOrigin = nil; return false }
        panel.setFrameOrigin(p)
        return true
    }

    private func applyMode(_ mode: String) {
        guard let m = WINDOW_MODES[mode] else { return }
        panel.contentMinSize = NSSize(width: m.minW, height: m.minH)
        panel.contentMaxSize = m.resizable
            ? NSSize(width: 10000, height: 10000)
            : NSSize(width: m.w, height: m.h)
        // 좌상단을 고정한 채 크기를 바꾼다 (위로 자라면 메뉴바를 뚫는다)
        let old = panel.frame
        panel.setContentSize(NSSize(width: m.w, height: m.h))
        let new = panel.frame
        panel.setFrameOrigin(NSPoint(x: old.minX, y: old.maxY - new.height))
        var mask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if m.resizable { mask.insert(.resizable) }
        panel.styleMask = mask
    }

    // MARK: - 메뉴바

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.imagePosition = .imageLeading
            // 데이터가 오기 전 잠깐 비어 보이지 않도록 잠자는 캐릭터로 시작
            Task { await self.updateStatusIcon(0) }
            b.target = self
            b.action = #selector(statusClicked)
            // 맥 메뉴바 항목은 누르는 순간 반응한다. mouseUp 으로 두면 한 박자 늦게 느껴진다.
            b.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }

    @objc private func statusClicked() {
        guard let button = statusItem.button else { return }
        let e = NSApp.currentEvent
        // mouseDown 으로 받고 있으므로 Up 이 아니라 Down 을 봐야 한다.
        // 맥에서는 Control+좌클릭도 우클릭으로 친다.
        let isSecondary = e.map { ev in
            ev.type == .rightMouseDown || ev.type == .rightMouseUp
            || (ev.type == .leftMouseDown && ev.modifierFlags.contains(.control))
        } ?? false

        if isSecondary {
            // statusItem.menu 를 잠깐 붙였다 떼는 방식은 클릭을 삼키는 경우가 있다.
            // 메뉴를 버튼 기준으로 직접 띄운다.
            let menu = buildMenu()
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.minY - 6),
                       in: button)
            return
        }
        panel.isVisible ? hidePanel() : showPanel(userInitiated: true)
    }

    /// 위젯 화면과 같은 언어를 쓴다. 화면은 영어인데 메뉴만 한글이면 어색하다.
    private func L(_ ko: String, _ en: String) -> String { uiLang == "ko" ? ko : en }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: L("열기", "Open"), action: #selector(menuOpen), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: L("종료", "Quit"), action: #selector(menuQuit), keyEquivalent: "q").target = self
        return m
    }

    private func togglePercent() {
        Prefs.showPercent.toggle()
        applyPercentTitle()
        Dbg.log("메뉴바 % 표시 \(Prefs.showPercent)")
    }

    /// 켤 때 권한을 묻는다. 실행하자마자 묻으면 사용자가 무엇을 허용하는지 모르는 채로
    /// 대화상자를 만나고, 답을 안 하면 '거부'로 굳어 이후 요청이 막힌다 (260904 실측).
    private func enableNotifications() async {
        await Notifications.requestIfNeeded()
        if Notifications.authorized {
            Prefs.notifyThresholds = true
            await Notifications.post(
                title: L("사용량 알림을 켰습니다", "Usage alerts on"),
                body: L("세션·주간 사용량이 80%, 90% 를 넘으면 알려드립니다.",
                        "You'll be notified when session or weekly usage passes 80% and 90%."),
                id: "enabled")
        } else {
            let a = NSAlert()
            a.messageText = L("알림이 허용되지 않았습니다", "Notifications not allowed")
            a.informativeText = L(
                "시스템 설정 > 알림 에서 이 앱의 알림을 켜주세요.",
                "Turn on notifications for this app in System Settings > Notifications.")
            a.alertStyle = .warning
            a.addButton(withTitle: L("시스템 설정 열기", "Open Settings"))
            a.addButton(withTitle: L("닫기", "Close"))
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn,
               let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(u)
            }
        }
    }

    /// 자동 시작 실패는 대개 앱 위치 문제라서 그것만 알려준다.
    private func warnLoginFailed() {
        let a = NSAlert()
        a.messageText = L("자동 시작을 켤 수 없습니다", "Couldn't enable start at login")
        a.informativeText = L("앱을 응용 프로그램 폴더로 옮긴 뒤 다시 시도해주세요.",
                              "Move the app to Applications and try again.")
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: - 업데이트
    // 위젯 창 위쪽에 띠가 뜨고, 버튼을 누르면 내려받아 교체하고 다시 켠다.
    // 서명이 없어 격리 표시를 우리가 지우므로 업데이트 뒤에는 우클릭이 필요 없다.

    private func updateStateDict() -> [String: Any] {
        var d: [String: Any] = ["current": Updater.current, "lang": uiLang]
        switch Updater.state {
        case .idle:               d["kind"] = "idle"
        case .checking:           d["kind"] = "checking"
        case .available(let v):   d["kind"] = "available"; d["version"] = v
        case .downloading(let p): d["kind"] = "downloading"; d["percent"] = p
        case .installing:         d["kind"] = "installing"
        case .failed(let m):      d["kind"] = "failed"; d["message"] = m
        }
        return d
    }

    private func pushUpdateState() {
        guard let j = try? JSONSerialization.data(withJSONObject: updateStateDict()),
              let t = String(data: j, encoding: .utf8) else { return }
        Task { _ = try? await web.evaluateJavaScript(
            "window.__macUpdateState && window.__macUpdateState(\(t))") }
    }

    /// 실행 직후 한 번, 그다음 6시간마다. GitHub API 는 인증 없이 시간당 60번이라 넉넉하다.
    private func startUpdateWatch() {
        Updater.onState = { [weak self] _ in self?.pushUpdateState() }
        Task {
            try? await Task.sleep(for: .seconds(4))   // 실행 직후엔 사용량 조회가 먼저다
            await Updater.check()
        }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
    }

    // MARK: - 위젯 창이 그리는 맥 전용 설정
    // 원래 우클릭 메뉴에 있던 것들. 설정이 두 군데로 나뉘면 사용자는 우클릭을 시도하지 않아
    // 그런 기능이 있는 줄도 모른다 (260904 Roy 지적).

    private func macSettingsDict() -> [String: Any] {
        [
            "notify":  Prefs.notifyThresholds && Notifications.authorized,
            "percent": Prefs.showPercent,
            "login":   LaunchAtLogin.isEnabled,
            "hotkey":  Prefs.hotKeyDisabled ? L("사용 안 함", "Off") : Prefs.hotKeyLabel,
        ]
    }

    /// 네이티브 쪽에서 값이 바뀌었을 때(단축키 녹화 등) 창을 다시 그리게 한다.
    func pushMacSettings() {
        guard let d = try? JSONSerialization.data(withJSONObject: macSettingsDict()),
              let j = String(data: d, encoding: .utf8) else { return }
        Task { _ = try? await web.evaluateJavaScript(
            "window.__macSettingsChanged && window.__macSettingsChanged(\(j))") }
    }

    /// 요청대로 안 되는 경우(권한 거부·앱 위치)가 있어 **실제** 상태를 돌려준다.
    private func setMacSetting(_ key: String, _ on: Bool) async -> [String: Any] {
        switch key {
        case "percent":
            Prefs.showPercent = on
            applyPercentTitle()
        case "login":
            if !LaunchAtLogin.set(on) { warnLoginFailed() }
        case "notify":
            if on { await enableNotifications() } else { Prefs.notifyThresholds = false }
        default: break
        }
        return macSettingsDict()
    }

    /// 단축키로 열 때는 사용자가 직접 부른 것이므로 앱을 활성화한다.
    private func toggleByHotKey() {
        Dbg.log("단축키 발동")
        panel.isVisible ? hidePanel() : showPanel(userInitiated: true)
    }

    /// % 숫자 표시. 끄면 캐릭터만 남는다.
    private func applyPercentTitle() {
        guard previewTask == nil || previewTask!.isCancelled else { return }
        statusItem.button?.title = Prefs.showPercent ? " \(Int(lastPercent.rounded()))%" : ""
    }

    // MARK: - 시스템 테마 추종

    static func systemAppearance() -> String {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    }

    /// 시스템 설정에서 다크/라이트를 바꾸면 위젯도 따라가야 한다.
    /// 따라갈지 말지는 위젯 화면의 '시스템' 버튼(bridge.js)이 정한다 — 여기서는 알리기만 한다.
    private func startAppearanceWatch() {
        appearanceObs = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let d = NSApp.delegate as? AppDelegate else { return }
                    d.pushAppearance()
                }
            }
        }
    }

    private func pushAppearance() {
        let a = AppDelegate.systemAppearance()
        Dbg.log("시스템 외관 -> \(a)")
        let js = "window.__macAppearanceChanged && window.__macAppearanceChanged('\(a)')"
        Task { _ = try? await web.evaluateJavaScript(js) }
    }

    @objc private func menuOpen() { showPanel(userInitiated: true) }

    /// 모든 구간을 한 페이지에서 동시에 보여준다.
    /// 메뉴바 순차 재생은 한 구간씩 기다려야 해서 비교가 어렵다.
    @objc private func menuPreviewAll() {
        Task { @MainActor in
            if charIcon == nil {
                charIcon = CharacterIcon(uiDir: Bundle.main.resourceURL!.appendingPathComponent("ui"))
            }
            guard let html = charIcon?.previewHTML() else { return }
            let path = NSTemporaryDirectory() + "claude-widget-characters.html"
            do { try html.write(toFile: path, atomically: true, encoding: .utf8) }
            catch { Dbg.log("미리보기 저장 실패"); return }
            // 자가 점검에서는 브라우저를 실제로 띄우지 않는다 (파일이 만들어졌는지만 본다)
            if ProcessInfo.processInfo.environment["CLAUDE_WIDGET_NO_OPEN"] != "1" {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Dbg.log("전체 미리보기 -> \(path)")
        }
    }

    /// 사용량 구간별 캐릭터를 메뉴바에서 차례로 보여준다.
    /// 실제로 그 구간이 될 때까지 기다리지 않아도 확인할 수 있게 하기 위한 것.
    @objc private func menuPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewTask = Task { @MainActor in
            let demo: [(String, Double)] = [
                (L("잠 ~10%", "Sleep ~10%"), 5),
                (L("여유 ~30%", "Chill ~30%"), 20),
                (L("집중 ~50%", "Focus ~50%"), 40),
                (L("다급 ~80%", "Rush ~80%"), 70),
                (L("불 ~90%", "Fire ~90%"), 85),
                (L("과열 90%+", "Overheat 90%+"), 95),
                (L("사망 100%", "Dead 100%"), 100),
            ]
            if charIcon == nil {
                charIcon = CharacterIcon(uiDir: Bundle.main.resourceURL!.appendingPathComponent("ui"))
            }
            for d in demo {
                if Task.isCancelled { break }
                guard let f = await charIcon?.frames(forPercent: d.1), !f.isEmpty else { continue }
                animFrames = f
                animIndex = 0
                statusItem.button?.title = "  \(d.0)"
                startAnimation(interval: CharacterIcon.frameInterval(for: d.1))
                try? await Task.sleep(for: .seconds(2.2))
            }
            // 히든 — 한도 초기화로 0% 가 됐을 때만 실제로 나온다
            if !Task.isCancelled,
               let rev = await charIcon?.frames(tier: CharacterIcon.reviveTier), !rev.isEmpty {
                animTimer?.invalidate()
                statusItem.button?.title = "  " + L("히든: 부활", "Hidden: Revive")
                for img in rev {
                    if Task.isCancelled { break }
                    statusItem.button?.image = img
                    try? await Task.sleep(for: .seconds(CharacterIcon.reviveInterval))
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
            // 실제 상태로 되돌린다. previewTask 를 먼저 비워야 갱신이 다시 통과한다.
            previewTask = nil
            lastTier = ""
            applyPercentTitle()
            await updateStatusIcon(lastPercent)
        }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// 메뉴바에 현재 세션 사용률을 캐릭터 + 숫자로 표시한다.
    private func updateStatusTitle(_ usage: [String: Any]) {
        guard let p = usage["sessionUsagePercent"] as? Double else { return }
        lastPercent = p
        // 미리보기 중에는 화면을 뺏지 않는다
        guard previewTask == nil || previewTask!.isCancelled else { return }
        applyPercentTitle()
        Task { await self.updateStatusIcon(p) }
        // 세션과 주간을 따로 본다. 주간이 90% 인 게 세션 90% 보다 아플 때가 많다.
        let weekly = usage["weeklyAllModelsPercent"] as? Double
        let ko = uiLang == "ko"
        Task { @MainActor in
            await Notifications.checkThresholds(kind: "session",
                                                label: ko ? "현재 세션" : "Current session",
                                                percent: p, korean: ko)
            if let w = weekly {
                await Notifications.checkThresholds(kind: "weekly",
                                                    label: ko ? "주간 사용량" : "Weekly usage",
                                                    percent: w, korean: ko)
            }
        }
    }

    /// 캐릭터 아이콘 갱신.
    /// 구간(tier)이 바뀌면 프레임을 새로 받고, 속도는 사용률에 따라 매번 조정한다.
    private func updateStatusIcon(_ percent: Double) async {
        if charIcon == nil {
            charIcon = CharacterIcon(uiDir: Bundle.main.resourceURL!.appendingPathComponent("ui"))
        }
        let t = CharacterIcon.tier(for: percent)
        // 히든: 한도가 초기화돼 0% 로 돌아올 때마다 한 번 부활한다.
        // 직전 사용량이 1% 이상이었다가 0% 가 되는 순간 = 5시간 창이 리셋된 시점.
        if !reviving, percent.rounded() == 0, prevPercent.rounded() >= 1 {
            prevPercent = percent
            await playRevive(then: percent)
            return
        }
        prevPercent = percent
        if t != lastTier {
            guard let f = await charIcon?.frames(forPercent: percent), !f.isEmpty else { return }
            let isFirst = lastTier.isEmpty
            lastTier = t
            animFrames = f
            animIndex = 0
            Dbg.log("메뉴바 아이콘 -> \(t) (\(f.count) 프레임)")
            // 구간이 바뀐 걸 놓치지 않도록 짧게 튀는 효과. 첫 표시 때는 생략한다.
            if !isFirst { await popIn(f[0]) }
        }
        startAnimation(interval: CharacterIcon.frameInterval(for: percent))
        // 부활은 24프레임이라 즉석에서 만들면 연출이 늦는다. 한가할 때 미리 만들어 둔다.
        if !revivePrewarmed {
            revivePrewarmed = true
            Task { await self.charIcon?.prewarmRevive() }
        }
        if Dbg.enabled {
            await dumpFrameSheet()
            if !AppDelegate.selfTested { AppDelegate.selfTested = true; await selfTest() }
        }
    }

    /// 히든 연출: 부활을 한 번만 재생하고 평소 상태로 돌아간다.
    private func playRevive(then percent: Double) async {
        guard let f = await charIcon?.frames(tier: CharacterIcon.reviveTier), !f.isEmpty else { return }
        reviving = true
        animTimer?.invalidate()
        Dbg.log("히든: 부활 연출 재생")
        for img in f {
            statusItem.button?.image = img
            try? await Task.sleep(for: .seconds(CharacterIcon.reviveInterval))
        }
        try? await Task.sleep(for: .milliseconds(250))
        reviving = false
        lastTier = ""
        await updateStatusIcon(percent)
    }

    /// 구간이 바뀔 때 0.16초짜리 스쿼시-스트레치. 새 모습으로 갈아탄 걸 알아채게 한다.
    private func popIn(_ base: NSImage) async {
        animTimer?.invalidate()
        for f in [0.74, 0.92, 1.06, 1.0] as [CGFloat] {
            statusItem.button?.image = scaled(base, f)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// 같은 캔버스 안에서 배율만 바꿔 그린다. 커지면 가장자리가 살짝 잘리지만 그게 튀는 맛을 낸다.
    private func scaled(_ img: NSImage, _ factor: CGFloat) -> NSImage {
        let size = img.size
        let out = NSImage(size: size)
        out.lockFocus()
        let w = size.width * factor, h = size.height * factor
        img.draw(in: NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// 프레임을 순환 재생한다. RunCat 처럼 사용률이 높을수록 빨라진다.
    private func startAnimation(interval: TimeInterval) {
        animTimer?.invalidate()
        guard !animFrames.isEmpty else { return }
        statusItem.button?.image = animFrames[0]
        // 프레임이 1장뿐이면 타이머를 돌릴 이유가 없다 (배터리)
        guard animFrames.count > 1 else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.animFrames.isEmpty else { return }
                self.animIndex = (self.animIndex + 1) % self.animFrames.count
                self.statusItem.button?.image = self.animFrames[self.animIndex]
            }
        }
        // .common 으로 넣어야 메뉴가 열려 있거나 창을 드래그하는 동안에도 계속 돈다.
        // scheduledTimer 는 .default 모드라 그때마다 멈춘다.
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
        Dbg.log("애니메이션 \(String(format: "%.1f", 1.0 / interval))fps")
    }

    // MARK: - 항상 최상단 / hover
    // src/main.js 의 setAlwaysOnTop() · initHoverWatch() 와 같은 역할.

    @discardableResult
    private func setAlwaysOnTop(_ flag: Bool) -> Bool {
        alwaysOnTop = flag
        panel.level = flag ? .floating : .normal
        let js = "window.__widgetOnAlwaysOnTop && window.__widgetOnAlwaysOnTop(\(flag))"
        Task { _ = try? await web.evaluateJavaScript(js) }
        return flag
    }

    // CSS :hover 는 드래그 영역에서 안 먹어서 커서 위치를 직접 본다 (Windows 와 동일한 이유).
    private func startHoverWatch() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                let inside = self.panel.frame.contains(NSEvent.mouseLocation)
                if inside != self.lastHoverInside {
                    self.lastHoverInside = inside
                    let js = "window.__widgetOnHover && window.__widgetOnHover(\(inside))"
                    _ = try? await self.web.evaluateJavaScript(js)
                }
            }
        }
    }

    // MARK: - 창 드래그
    // WKWebView 는 -webkit-app-region 을 창 이동으로 해석하지 않는다 (Electron 전용 동작).
    // JS 가 drag 영역 mousedown 을 알려주면 여기서 직접 창을 옮긴다.

    private func beginDrag() {
        endDrag()
        dragMouseStart = NSEvent.mouseLocation
        dragWindowStart = panel.frame.origin
        let move: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = NSEvent.mouseLocation
                self.panel.setFrameOrigin(NSPoint(
                    x: self.dragWindowStart.x + (now.x - self.dragMouseStart.x),
                    y: self.dragWindowStart.y + (now.y - self.dragMouseStart.y)))
            }
        }
        let stop: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.endDrag() }
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged],
                                                    handler: { e in move(e); return e }) { dragMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp],
                                                    handler: { e in stop(e); return e }) { dragMonitors.append(m) }
        dragMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: move) as Any)
        dragMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: stop) as Any)
    }

    private func endDrag() {
        guard !dragMonitors.isEmpty else { return }
        for m in dragMonitors { NSEvent.removeMonitor(m) }
        dragMonitors.removeAll()
        saveSessionOrigin()
    }

    // MARK: - JS 브리지
    // bridge.js 가 보내는 { method, args } 를 처리한다.

    func userContentController(_ c: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        let args = body["args"] as? [Any] ?? []
        Dbg.log("bridge <- \(method)\(args.isEmpty ? "" : " \(args)")")
        Task { @MainActor in
            switch method {
            case "api":
                let which = args.first as? String ?? ""
                switch which {
                case "usage":
                    let u = await UsageAPI.fetchUsage()
                    self.updateStatusTitle(u)
                    Dbg.log("usage -> \(u["error"].map { "error=\($0)" } ?? "session=\(u["sessionUsagePercent"] ?? "?")% weekly=\(u["weeklyAllModelsPercent"] ?? "?")% scoped=\(u["scopedModelName"] ?? "?") \(u["scopedModelPercent"] ?? "?")% plan=\(u["planName"] ?? "?")")")
                    replyHandler(u, nil)
                case "credentials":
                    replyHandler(UsageAPI.credentialsStatus(), nil)
                case "version":
                    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                    replyHandler(["version": v], nil)
                default:
                    replyHandler(["error": "Not found"], nil)
                }
            case "minimize":
                self.hidePanel(); replyHandler(nil, nil)
            case "quit":
                replyHandler(nil, nil); NSApp.terminate(nil)
            case "login":
                replyHandler(Login.start(), nil)
            case "setWindowMode":
                let mode = args.first as? String ?? "default"
                self.applyMode(mode)
                replyHandler(["ok": true, "mode": mode], nil)
            case "setAlwaysOnTop":
                let f = args.first as? Bool ?? false
                replyHandler(["ok": true, "value": self.setAlwaysOnTop(f)], nil)
            case "setLang":
                self.uiLang = (args.first as? String) == "ko" ? "ko" : "en"
                replyHandler(nil, nil)
            case "macSettings":
                replyHandler(self.macSettingsDict(), nil)
            case "setMac":
                let key = args.first as? String ?? ""
                let on = (args.count > 1 ? args[1] as? Bool : false) ?? false
                replyHandler(await self.setMacSetting(key, on), nil)
            case "pickHotKey":
                HotKeyRecorder.show(korean: self.uiLang == "ko") { [weak self] in
                    self?.pushMacSettings()
                }
                replyHandler(nil, nil)
            case "previewAll":
                self.menuPreviewAll(); replyHandler(nil, nil)
            case "previewMenuBar":
                self.menuPreview(); replyHandler(nil, nil)
            case "updateState":
                replyHandler(self.updateStateDict(), nil)
            case "updateInstall":
                replyHandler(nil, nil)
                Task { await Updater.install() }
            case "updateCheck":
                replyHandler(nil, nil)
                Task { await Updater.check() }
            case "dragStart":
                self.beginDrag(); replyHandler(nil, nil)
            default:
                replyHandler(nil, "unknown method")
            }
        }
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        guard Dbg.enabled else { return }
        Task {
            let n = try? await w.evaluateJavaScript("document.querySelectorAll('*').length")
            let api = try? await w.evaluateJavaScript("typeof window.widgetAPI")
            let minHidden = try? await w.evaluateJavaScript(
                "(() => { const b = document.querySelector('#minBtn'); return b ? getComputedStyle(b).display : 'no-elem' })()")
            // 주입한 '시스템' 테마 버튼은 renderer 초기화 뒤에 붙으므로 한 틱 뒤에 확인한다
            try? await Task.sleep(for: .milliseconds(120))
            let sysBtn = try? await w.evaluateJavaScript(
                "(() => { const b = document.querySelector('#macThemeSystem'); return b ? b.textContent + '/' + (b.classList.contains('active') ? 'active' : 'off') : 'none' })()")
            Dbg.log("DOM=\(n ?? "?") widgetAPI=\(api ?? "?") #minBtn.display=\(minHidden ?? "?") 시스템테마버튼=\(sysBtn ?? "?")")
            Dbg.log("자동시작=\(LaunchAtLogin.isEnabled) 승인필요=\(LaunchAtLogin.needsApproval) %표시=\(Prefs.showPercent) 단축키=\(Prefs.hotKeyLabel) 활성=\(HotKeyCenter.shared.isActive)")
            await self.snapshot("boot")
        }
    }

    // DebugDump.swift 가 쓰는 통로. private 는 파일 밖에서 보이지 않아 여기서 열어준다.
    var webView: WKWebView { web }
    func statusTitle() -> String { statusItem.button?.title ?? "" }
    func togglePercentForTest() { togglePercent() }
    func menuTitlesForTest() -> [String] { buildMenu().items.map(\.title) }

    /// 디버그용 화면 캡처. WKWebView 가 자기 자신을 그려서 PNG 로 남긴다.
    func snapshot(_ tag: String) async {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        guard let img = try? await web.takeSnapshot(configuration: cfg),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Dbg.log("snapshot(\(tag)) 실패"); return
        }
        let path = NSTemporaryDirectory() + "claude-widget-\(tag).png"
        try? png.write(to: URL(fileURLWithPath: path))
        Dbg.log("snapshot(\(tag)) -> \(path) \(png.count) bytes")
    }

    func webView(_ w: WKWebView, didFail nav: WKNavigation!, withError e: Error) {
        Dbg.log("load FAIL \(e.localizedDescription)")
    }

    // MARK: - 외부 링크
    // renderer.js 는 window.open(url, '_blank') 를 쓴다. Electron 은 setWindowOpenHandler 로
    // 기본 브라우저에 넘기는데, WKWebView 는 uiDelegate 가 없으면 요청 자체를 버린다
    // (오류도 없어서 '링크가 안 눌린다'로 보였다 — 260908).
    // 새 WebView 를 만들지 않고 nil 을 돌려주면 앱 안에서는 아무 창도 열리지 않는다.
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openExternal(action.request.url)
        return nil
    }

    /// https 만 연다. file:// 이나 커스텀 스킴을 그대로 넘기면 의도치 않은 앱이 뜬다.
    static var lastExternal: String?

    private func openExternal(_ url: URL?) {
        guard let url, url.scheme?.lowercased() == "https" else {
            Dbg.log("외부 링크 거부 -> \(url?.scheme ?? "nil")")
            return
        }
        AppDelegate.lastExternal = url.host
        // 자가 점검에서는 브라우저를 실제로 띄우지 않는다
        if ProcessInfo.processInfo.environment["CLAUDE_WIDGET_NO_OPEN"] != "1" {
            NSWorkspace.shared.open(url)
        }
        Dbg.log("외부 링크 열기 -> \(url.host ?? "?")")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}
