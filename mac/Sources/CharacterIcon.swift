import AppKit
import WebKit

// 메뉴바에서 움직이는 캐릭터 아이콘.
//
// 원칙: 캐릭터 도형(SVG)과 상태 규칙(tier-*)은 src/ 것을 그대로 쓴다. Swift 로 다시 그리지 않는다.
// 다만 **모션은 맥 전용으로 새로 정의**한다. 위젯 본체의 모션은 좌우 ±46px 이동이라
// 폭 28px 짜리 메뉴바 항목에서는 캐릭터가 화면 밖으로 나가버린다.
//
// 프레임 뽑는 방법: CSS 애니메이션을 정지시킨 뒤(animation-play-state: paused)
// animation-delay 를 음수로 주면 그 시점의 한 컷이 그려진다. 한 주기를 N등분해 샘플링하면
// 이어붙였을 때 완벽히 순환하는 프레임 셋이 나온다.
@MainActor
final class CharacterIcon {
    static let frameCount = 12
    /// 한 주기(초). 실제 재생 속도는 Swift 타이머가 결정하므로 여기선 기준값일 뿐이다.
    private static let cycle = 1.2

    // renderer.js 의 charTierFor() 와 같은 기준이어야 한다.
    static func tier(for percent: Double) -> String {
        if percent.rounded() >= 100 { return "tier-dead" }
        if percent <= 10 { return "tier-sleep" }
        if percent <= 30 { return "tier-walk-slow" }
        if percent <= 50 { return "tier-walk-fast" }
        if percent <= 80 { return "tier-jump" }
        if percent <= 90 { return "tier-fire" }
        return "tier-fire-hot"
    }

    /// RunCat 처럼 사용량이 높을수록 빨라진다. 반환값은 프레임 간격(초).
    /// 배터리를 위해 상한을 20fps 로 둔다 — 그 이상은 눈에 띄지도 않는다.
    static func frameInterval(for percent: Double) -> TimeInterval {
        // 하한이 낮으면 '느리다'가 아니라 '끊긴다'로 느껴진다. 8fps 부터 시작한다.
        let fps = min(24.0, 8.0 + percent * 0.16)   // 0% ≈ 8fps, 100% ≈ 24fps
        return 1.0 / fps
    }

    private let web: WKWebView
    private let host: NSWindow
    private let css: String
    private let body: String
    /// 부활 연출용 날개. 원본 캐릭터에는 없는 맥 전용 요소라 여기서 만들어 끼운다.
    /// 캐릭터가 픽셀 아트라 날개도 같은 결의 사각 블록으로 그린다.
    /// 책상·손은 캐릭터 SVG 밖에 둔다.
    /// 캐릭터 viewBox 안에 넣으면 몸 바로 밑에 붙어버려서 22pt 에서 한 덩어리로 뭉갠다.
    /// 아이콘 상자(56×44) 좌표를 직접 쓰면 캐릭터를 위로 올리고 아래에 책상을 깔 수 있다.
    /// 노트북. 캐릭터 SVG 밖에 두고 아이콘 상자(56×44) 좌표를 직접 쓴다.
    /// 앞서 '캐릭터 아래 키보드 + 옆에 손' 으로 해봤더니 22pt 에서
    /// 키보드는 바닥으로, 손은 바퀴로 읽혔다 (260903). 그래서 구도를 바꿨다.
    /// 노트북 뒤에서 얼굴만 내민 모습은 작은 크기에서도 '작업 중'으로 바로 읽힌다.
    private static let deskHTML = """
    <svg class="mb-deskfx" viewBox="0 0 56 44" aria-hidden="true">
      <!-- 화면 뒷면 (우리는 뚜껑 뒤쪽을 본다) -->
      <g class="mb-lid">
        <rect x="9"  y="18"   width="38" height="15.5" rx="1.6" fill="#8d949c"/>
        <rect x="9"  y="18"   width="38" height="1.4"  rx="1"   fill="#c2c8ce"/>
        <rect x="26" y="24"   width="4"  height="4"    rx="1"   fill="#767d85"/>
      </g>
      <!-- 키보드 베이스 -->
      <g class="mb-base">
        <rect x="4.5" y="33.5" width="47" height="5.2" rx="1.8" fill="#a7aeb5"/>
        <rect x="4.5" y="33.5" width="47" height="1.4" rx="1"   fill="#dde1e5"/>
      </g>
      <!-- 자판 위의 손 -->
    </svg>
    """

    /// 집중 구간 후보용 소품. 전부 아이콘 상자(56×44) 좌표를 쓴다.
    /// 빛기둥·잔광은 무대에 고정한다. 몸 안에 넣으면 캐릭터가 떠오를 때 빛도 같이 올라가 어색하다.
    private static let lightHTML = """
    <div class="mb-spot" aria-hidden="true"></div>
    <div class="mb-glow" aria-hidden="true"></div>
    """
    // 구간별 소품(선글라스·커피·음표·헤드셋·느낌표·땀·옆불꽃)은 src/index.html 로 옮겼다.
    // 좌표가 캐릭터 viewBox(24×24) 기준이라 위젯 창과 메뉴바 아이콘이 같은 그림을 쓴다.
    // 노트북·날개·빛만 맥 아이콘 전용으로 남는다 — 22pt 에서는 상자(56×44) 기준으로
    // 크게 그려야 읽히는데, 72px 짜리 위젯 창에서는 그 비율이 맞지 않는다.

    private static let wingsSVG = """
    <svg class="mb-wings" viewBox="0 0 36 20" aria-hidden="true">
      <g class="mb-wing mb-wing-l" fill="#ffffff">
        <rect x="4.5" y="3"  width="2"   height="2"/>
        <rect x="3"   y="5"  width="3.5" height="2"/>
        <rect x="1.5" y="7"  width="5"   height="2"/>
        <rect x="0.5" y="9"  width="6"   height="2"/>
        <rect x="1.5" y="11" width="5"   height="2"/>
        <rect x="3"   y="13" width="3.5" height="2"/>
      </g>
      <g class="mb-wing mb-wing-r" fill="#ffffff">
        <rect x="29.5" y="3"  width="2"   height="2"/>
        <rect x="29.5" y="5"  width="3.5" height="2"/>
        <rect x="29.5" y="7"  width="5"   height="2"/>
        <rect x="29.5" y="9"  width="6"   height="2"/>
        <rect x="29.5" y="11" width="5"   height="2"/>
        <rect x="29.5" y="13" width="3.5" height="2"/>
      </g>
    </svg>
    """
    private var bodyWithWings: String {
        // 날개는 char-body 안에 — 몸과 함께 움직여야 한다.
        guard let idx = body.range(of: ">") else { return Self.lightHTML + body + Self.deskHTML }
        let withWings = body.replacingCharacters(in: idx, with: ">" + Self.wingsSVG)
        // 빛은 char-body 밖에 — 무대 기준으로 고정된다.
        // 그리는 순서: 빛(뒤) → 캐릭터 → 노트북(앞).
        // 노트북이 뒤에 있으면 캐릭터가 덮어버려 화면이 안 보인다.
        return Self.lightHTML + withWings + Self.deskHTML
    }
    private var cache: [String: [NSImage]] = [:]
    // 오프스크린 WebView 는 하나뿐이다. 두 렌더가 겹치면 서로의 화면을 캡처해
    // 구간별 프레임이 뒤섞인다 (260903 실측: 프리워밍이 일반 렌더와 충돌).
    private var isRendering = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    // 메뉴바 아이콘 상자(@2x). 캐릭터가 가로로 긴 형태라 폭을 더 준다. 표시 크기 28x22pt.
    private let boxW: CGFloat = 56
    private let boxH: CGFloat = 44

    init?(uiDir: URL) {
        guard let cssText = try? String(contentsOf: uiDir.appendingPathComponent("style.css"), encoding: .utf8),
              let html = try? String(contentsOf: uiDir.appendingPathComponent("index.html"), encoding: .utf8),
              let b = CharacterIcon.extractCharBody(html) else { return nil }
        css = cssText
        // 캐릭터는 y 5~20 에만 있고 불꽃이 y 0.7 부터 시작한다. 위아래 빈 공간을 잘라낸다.
        body = b
            .replacingOccurrences(of: "viewBox=\"0 0 24 24\"", with: "viewBox=\"0 0.5 24 20\"")
            // (소품은 src/index.html 에 이미 들어 있다)

        web = WKWebView(frame: NSRect(x: 0, y: 0, width: boxW, height: boxH),
                        configuration: WKWebViewConfiguration())
        web.setValue(false, forKey: "drawsBackground")
        // WKWebView 는 창에 붙어 있지 않으면 합성을 하지 않아 스냅샷이 백지로 나온다 (260903 실측).
        host = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: boxW, height: boxH),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        host.isOpaque = false
        host.backgroundColor = .clear
        host.hasShadow = false
        host.ignoresMouseEvents = true
        host.contentView = web
        host.orderFront(nil)
    }

    /// index.html 의 <div class="char-body"> 블록을 통째로 꺼낸다.
    /// 안에 div 가 중첩돼 있어 깊이를 세면서 닫는 태그를 찾는다.
    private static func extractCharBody(_ html: String) -> String? {
        guard let start = html.range(of: "<div class=\"char-body\"") else { return nil }
        var depth = 0
        var i = start.lowerBound
        while i < html.endIndex {
            if html[i...].hasPrefix("<div") {
                depth += 1
                i = html.index(i, offsetBy: 4)
            } else if html[i...].hasPrefix("</div>") {
                depth -= 1
                i = html.index(i, offsetBy: 6)
                if depth == 0 { return String(html[start.lowerBound..<i]) }
            } else {
                i = html.index(after: i)
            }
        }
        return nil
    }

    /// 해당 구간의 프레임 배열. 처음 요청할 때만 렌더하고 이후엔 캐시를 준다.
    func frames(forPercent percent: Double) async -> [NSImage] {
        await frames(tier: CharacterIcon.tier(for: percent))
    }

    /// 히든 구간처럼 사용률로 계산되지 않는 상태도 직접 지정할 수 있다.
    func frames(tier t: String) async -> [NSImage] {
        if let c = cache[t] { return c }
        await acquire()
        defer { release() }
        // 기다리는 동안 다른 작업이 만들어 놨을 수 있다
        if let c = cache[t] { return c }
        let isRevive = (t == CharacterIcon.reviveTier)
        let n = isRevive ? CharacterIcon.reviveFrames : CharacterIcon.frameCount
        let dur = isRevive ? CharacterIcon.reviveCycle : CharacterIcon.cycle
        var out: [NSImage] = []
        for k in 0..<n {
            if let img = await render(tier: t, phase: Double(k) / Double(n), duration: dur) {
                out.append(img)
            }
        }
        cache[t] = out
        return out
    }

    private func acquire() async {
        while isRendering {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
            }
        }
        isRendering = true
    }

    private func release() {
        isRendering = false
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }

    /// 첫 발동 때 렌더하느라 연출이 밀리지 않도록 미리 만들어 둔다.
    func prewarmRevive() async { _ = await frames(tier: CharacterIcon.reviveTier) }

    /// 히든: 부활. 한 번만 재생되는 연출이라 루프하지 않는다.
    static let reviveTier = "tier-revive"
    /// 부활은 천천히 보여줘야 하는 연출이라 별도 길이·프레임 수를 쓴다.
    static let reviveCycle = 2.3
    static let reviveFrames = 30
    static var reviveInterval: TimeInterval { reviveCycle / Double(reviveFrames) }

    private func render(tier: String, phase: Double, duration: Double) async -> NSImage? {
        let delay = -duration * phase
        let doc = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        \(css)
        \(Self.macMotionCSS(cycle: CharacterIcon.cycle))
        html,body{margin:0;padding:0;background:transparent;overflow:hidden;
                  width:\(Int(boxW))px;height:\(Int(boxH))px}
        /* 공유 style.css 는 위젯 본체 레이아웃용이라 .char-stage 에 flex/padding 이 걸려 있다
           (padding:0 0 10px 때문에 캐릭터가 상자 위로 10px 밀려났다 — 260903 실측).
           아이콘에서는 레이아웃을 쓰지 않고 좌표를 직접 고정한다. */
        .char-stage{display:block !important;position:absolute;inset:0;
                    padding:0 !important;margin:0 !important;gap:0 !important;flex:none !important}
        .char-body{position:absolute;left:50%;bottom:1px;margin-left:-21px;width:42px}
        .char-svg{display:block;width:42px;height:35px}
        /* 머리 위 요소들 — 상자 안에 들어오도록 좌표를 다시 잡는다 */
        .char-zzz{top:-6px !important;right:-7px !important;font-size:9px !important;line-height:1 !important}
        .char-halo{top:-6px !important;width:26px !important;margin-left:-13px !important;
                   height:8px !important;border-width:2px !important}
        /* 모든 모션을 이 컷에서 정지시킨다 */
        *,*::before,*::after{animation-play-state:paused !important;
                             animation-delay:\(delay)s !important;
                             transition:none !important}
        </style></head><body class="mode-character">
        <div class="icon-wrap"><div class="char-stage \(tier == "tier-fire-hot" ? "tier-fire tier-fire-hot" : tier)">\(bodyWithWings)</div></div>
        </body></html>
        """
        web.loadHTMLString(doc, baseURL: nil)
        try? await Task.sleep(for: .milliseconds(160))
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        guard let snap = try? await web.takeSnapshot(configuration: cfg) else { return nil }
        let out = NSImage(size: NSSize(width: boxW / 2, height: boxH / 2))
        out.addRepresentations(snap.representations)
        out.size = NSSize(width: boxW / 2, height: boxH / 2)
        out.isTemplate = false      // 클로드 오렌지를 살린다
        return out
    }

    /// 모든 구간을 한 화면에서 동시에 보여주는 미리보기 페이지를 만든다.
    /// 메뉴바에서 하나씩 기다리며 보는 대신 한눈에 비교하기 위한 것.
    /// 구간별 재생 속도는 실제 메뉴바와 같게 맞춘다(프레임 수 ÷ fps).
    func previewHTML() -> String {
        let tiers: [(String, String, Double)] = [
            ("tier-sleep",     "잠 ~10%",       5),
            ("tier-walk-slow", "여유 ~30%",     20),
            ("tier-walk-fast", "집중 ~50%",     40),
            ("tier-jump",      "다급 ~80%",     70),
            ("tier-fire",      "불 ~90%",       85),
            ("tier-fire-hot",  "과열 90%+",     95),
            ("tier-dead",      "사망 100%",     100),
            (CharacterIcon.reviveTier, "히든 · 부활", -1),
        ]
        let cards = tiers.map { t -> String in
            // 메뉴바에서의 실제 한 바퀴 길이 = 프레임 수 ÷ fps
            let c = t.2 < 0
                ? CharacterIcon.reviveCycle
                : Double(CharacterIcon.frameCount) * CharacterIcon.frameInterval(for: t.2)
            let cls = t.0 == "tier-fire-hot" ? "tier-fire tier-fire-hot" : t.0
            let speed = t.2 < 0 ? "1회 재생" : String(format: "%.0f fps", 1 / CharacterIcon.frameInterval(for: t.2))
            return """
            <div class="card">
              <div class="label">\(t.1)</div>
              <div class="stages">
                <div class="wrap real"><div class="char-stage \(cls)" style="--c:\(c)s">\(bodyWithWings)</div></div>
                <div class="wrap big"><div class="char-stage \(cls)" style="--c:\(c)s">\(bodyWithWings)</div></div>
              </div>
              <div class="meta">\(speed)</div>
            </div>
            """
        }.joined()

        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <title>Claude Usage Widget — 메뉴바 캐릭터 미리보기</title><style>
        \(css)
        \(Self.macMotionCSS(cycle: CharacterIcon.cycle))
        /* 미리보기에서는 정지시키지 않는다 (컷 샘플링용 규칙을 덮어쓴다) */
        *,*::before,*::after { animation-play-state: running !important; animation-delay: 0s !important; }
        /* 부활은 1회 연출이지만 여기서는 반복해서 볼 수 있게 한다 */
        .tier-revive * { animation-iteration-count: infinite !important; }

        /* 위젯 style.css 는 320×500 고정 창용이라 html,body 에
           height:100% + overflow:hidden 이 걸려 있다. 그대로 두면 페이지가 스크롤되지 않는다. */
        html,body { margin:0 !important; padding:0 !important;
                    height:auto !important; min-height:100% !important;
                    overflow:visible !important; overflow-y:auto !important;
                    background:#141416 !important; color:#e8e6e3;
                    font: 13px/1.5 ui-sans-serif, -apple-system, sans-serif; }
        header { padding:22px 24px 6px; }
        header h1 { margin:0 0 4px; font-size:17px; font-weight:650; letter-spacing:-.2px; }
        header p { margin:0; color:#8b8a88; font-size:12px; }
        .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(178px,1fr));
                gap:14px; padding:18px 24px 32px; }
        .card { background:#1e1e21; border:1px solid #2c2c30; border-radius:10px; padding:14px 12px 10px; }
        .label { font-size:12px; font-weight:600; color:#f0eeec; margin-bottom:10px; }
        .stages { display:flex; align-items:center; gap:16px; min-height:96px; }
        .wrap { position:relative; overflow:hidden; flex:none; }
        /* 실제 메뉴바 크기 = 28×22pt (아이콘은 56×44 @2x 로 그려 절반 크기로 표시된다) */
        .wrap.real { width:28px; height:22px; outline:1px dashed #3a3a40; }
        .wrap.real .char-stage { transform:scale(.5); transform-origin:left top; }
        /* 2배 확대 — 디테일 확인용 */
        .wrap.big  { width:112px; height:88px; }
        .wrap.big .char-stage { transform:scale(2); transform-origin:left top; }
        .wrap .char-stage { display:block !important; position:absolute; left:0; top:0;
                            width:56px; height:44px;
                            padding:0 !important; margin:0 !important; gap:0 !important; flex:none !important; }
        .wrap .char-body { position:absolute; left:50%; bottom:1px; margin-left:-21px; width:42px; }
        .wrap .char-svg  { display:block; width:42px; height:35px; }
        .wrap .char-zzz  { top:-6px !important; right:-7px !important; font-size:9px !important; line-height:1 !important; }
        .wrap .char-halo { top:-6px !important; width:26px !important; margin-left:-13px !important;
                           height:8px !important; border-width:2px !important; }
        .meta { margin-top:12px; color:#77767a; font-size:11px; }
        footer { padding:0 24px 28px; color:#6f6e72; font-size:11px; }
        .sec { margin:14px 24px 2px; font-size:14px; font-weight:650; color:#f0eeec;
               border-top:1px solid #2c2c30; padding-top:20px; }
        .sub { margin:0 24px; color:#8b8a88; font-size:12px; }
        </style></head><body>
        <header>
          <h1>메뉴바 캐릭터 — 전체 구간</h1>
          <p>왼쪽 점선이 실제 메뉴바 크기, 오른쪽은 2배 확대. 속도도 실제와 같게 맞췄습니다.</p>
        </header>
        <div class="grid">\(cards)</div>
        <footer>사용량이 오를수록 재생 속도가 빨라집니다 (8fps → 24fps).</footer>
        </body></html>
        """
    }

    /// 맥 메뉴바 전용 모션. 폭 28px 안에서 읽히도록 진폭을 줄이고 한 주기로 통일한다.
    /// 원본(walk-x ±46px, panic-x ±34px)은 메뉴바에서 쓸 수 없다.
    private static func macMotionCSS(cycle: Double) -> String {
        """
        /* 길이는 CSS 변수로 둔다 — 컷 샘플링과 미리보기가 같은 규칙을 공유한다 */
        :root { --c: \(cycle)s; --rc: \(CharacterIcon.reviveCycle)s; }
        /* 원본 모션을 끄고 메뉴바용으로 갈아끼운다 */
        .char-stage .char-walker,
        .char-stage .char-body,
        .char-stage .char-halo,
        .char-stage .char-zzz span { animation: none; }

        .mb-shades, .mb-sweat, .mb-cup, .mb-notes { display: none; }
        .mb-note { transform-origin: 50% 100%; }

        @keyframes mb-type {            /* 타이핑 진동 — 작고 빠르게 */
          0%,100% { transform: translateY(0) }
          50%     { transform: translateY(-1.2px) }
        }
        /* 90% 초과 — 몸이 달아오른다.
           filter 의 hue-rotate 만으로는 22pt 에서 ~90% 와 구분이 안 됐다(260904 실측).
           몸통 path 의 fill 을 실제 붉은색까지 밀어붙인다. */
        @keyframes mb-overheat {
          0%   { transform: scale(1);    filter: brightness(1) }
          100% { transform: scale(1.07); filter: brightness(1.1) }
        }
        @keyframes mb-scorch {          /* #D97757(기본) → 달군 쇠 색 */
          0%   { fill: #e8583a }
          100% { fill: #c4160b }
        }
        /* 옆불꽃은 좌우가 엇갈려야 '번진다'로 읽힌다.
           컷 샘플링이 animation-delay 를 덮어쓰므로 시차를 키프레임 안에 넣는다. */
        @keyframes mb-blaze-a {
          0%,100% { transform: scaleY(1)    translateY(0);      opacity: .92 }
          50%     { transform: scaleY(1.32) translateY(-0.5px); opacity: 1 }
        }
        @keyframes mb-blaze-b {
          0%,100% { transform: scaleY(1.28) translateY(-0.4px); opacity: 1 }
          50%     { transform: scaleY(0.9)  translateY(0);      opacity: .88 }
        }
        /* 음표는 시차가 필요한데 animation-delay 를 쓸 수 없어(컷 샘플링용으로 덮어씀)
           키프레임 안에 시차를 넣은 별도 애니메이션으로 만든다. */
        @keyframes mb-note-a {
          0%   { opacity:0; transform:translateY(3px)  translateX(0) }
          22%  { opacity:1; transform:translateY(0)    translateX(.5px) }
          70%  { opacity:.6;transform:translateY(-6px) translateX(1.5px) }
          100% { opacity:0; transform:translateY(-11px) translateX(2.5px) }
        }
        @keyframes mb-note-b {
          0%,40% { opacity:0; transform:translateY(3px) translateX(0) }
          58%    { opacity:1; transform:translateY(-1px) translateX(.5px) }
          100%   { opacity:0; transform:translateY(-9px) translateX(2px) }
        }
        /* 땀방울은 시차를 둬야 자연스러운데, 프레임 샘플링 때문에 animation-delay 를 쓸 수 없다
           (모든 요소의 delay 를 한 값으로 덮어써서 컷을 뽑기 때문).
           그래서 시차를 키프레임 안에 넣은 별도 애니메이션 3개로 만든다. */
        @keyframes mb-drop-a {
          0%   { opacity:0; transform:translateY(-1px) }
          12%  { opacity:1; transform:translateY(0) }
          46%  { opacity:0; transform:translateY(5px) }
          100% { opacity:0; transform:translateY(5px) }
        }
        @keyframes mb-drop-b {
          0%,32% { opacity:0; transform:translateY(-1px) }
          44%    { opacity:1; transform:translateY(0) }
          78%    { opacity:0; transform:translateY(5px) }
          100%   { opacity:0; transform:translateY(5px) }
        }
        @keyframes mb-drop-c {
          0%,60% { opacity:0; transform:translateY(-1px) }
          72%    { opacity:1; transform:translateY(0) }
          100%   { opacity:0; transform:translateY(4px) }
        }

        @keyframes mb-breathe { 0%,100%{transform:translateY(0) scaleY(1)} 50%{transform:translateY(1px) scaleY(0.94)} }
        @keyframes mb-step    { 0%,100%{transform:translateY(0)} 50%{transform:translateY(-3px)} }
        @keyframes mb-sway    { 0%,100%{transform:translateX(-2px)} 50%{transform:translateX(2px)} }
        @keyframes mb-jump    { 0%,100%{transform:translateY(0)} 42%{transform:translateY(-6px)} }
        @keyframes mb-shake   { 0%,100%{transform:translateX(-1.5px) rotate(-3deg)} 50%{transform:translateX(1.5px) rotate(3deg)} }
        @keyframes mb-zzz     { 0%{opacity:0;transform:translateY(3px)} 35%{opacity:1} 100%{opacity:0;transform:translateY(-9px)} }
        @keyframes mb-fire-jump { 0%,100%{transform:translateY(0)} 42%{transform:translateY(-2px)} }
        @keyframes mb-halo    { 0%,100%{transform:translateY(0) scaleX(1);opacity:.85} 50%{transform:translateY(-2px) scaleX(.9);opacity:1} }

        /* 10% 이하 — 숨쉬기 + zZ. 정지 이미지에서도 잠든 게 보이도록 zZ 를 크게 띄운다 */
        .char-stage.tier-sleep .char-body { animation: mb-breathe var(--c) ease-in-out infinite; }
        .char-stage.tier-sleep .char-zzz { display:block; position:absolute; top:-9px; right:-11px;
                                           font-size:11px; line-height:1; letter-spacing:-1px; }
        .char-stage.tier-sleep .char-zzz span { animation: mb-zzz var(--c) ease-in-out infinite; }
        .char-stage.tier-sleep .char-zzz span:nth-child(2){ animation-delay: calc(var(--c) / 3); }
        .char-stage.tier-sleep .char-zzz span:nth-child(3){ animation-delay: calc(var(--c) / 3 * 2); }

        /* ~30% 여유 — 선글라스 + 커피컵, 휘파람 음표가 떠오른다.
           2D 정면 캐릭터라 '누운 자세'는 발이 빠진 것처럼 보여서 세운 채로 간다. */
        .char-stage.tier-walk-slow .mb-shades,
        .char-stage.tier-walk-slow .mb-cup,
        .char-stage.tier-walk-slow .mb-notes { display: block; }
        .char-stage.tier-walk-slow .char-walker { animation: none; }
        .char-stage.tier-walk-slow .char-body { animation: mb-breathe calc(var(--c) * 1.6) ease-in-out infinite; }
        .char-stage.tier-walk-slow .mb-note1 { animation: mb-note-a calc(var(--c) * 1.6) ease-in-out infinite; }
        .char-stage.tier-walk-slow .mb-note2 { animation: mb-note-b calc(var(--c) * 1.6) ease-in-out infinite; }

        /* ~50% 집중 — 헤드셋 쓰고 노트북 앞에서 작업.
           소품을 캐릭터 아래에 두면 팔·다리와 섞여 바닥·바퀴로 읽힌다(260903 3회 실패).
           노트북은 앞에 세우고 헤드셋은 머리 위에 얹어 겹치지 않게 했다. */
        .mb-deskfx { display:none; position:absolute; left:50%; top:50%;
                     width:56px; height:44px; margin-left:-28px; margin-top:-22px;
                     pointer-events:none; overflow:visible; }
        .char-stage.tier-walk-fast .mb-deskfx { display:block; transform: translateY(2px); }
        .char-stage.tier-walk-fast .mb-hs-p { display:block; }
        /* 눈이 화면 윗변 위로 나오도록 캐릭터를 내린다 */
        .char-stage.tier-walk-fast .char-body { bottom:10px; animation: mb-type calc(var(--c) / 3) ease-in-out infinite; }
        .char-stage.tier-walk-fast .char-walker { animation: none; }

        /* 소품 기본 숨김. 구간별 규칙에서 필요한 것만 켠다. */
        .mb-shades, .mb-cup, .mb-notes, .mb-sweat, .mb-excl, .mb-hs-p, .mb-blaze { display: none; }
        /* 위젯 창(72px)용 노트북·날개·빛. 아이콘은 상자 기준의 자기 것을 쓴다. */
        .wg-desk, .wg-wings, .wg-spot { display: none !important; }
        .mb-deskfx { display:none; position:absolute; left:50%; top:50%;
                     width:56px; height:44px; margin-left:-28px; margin-top:-22px;
                     pointer-events:none; overflow:visible; }

        @keyframes mb-pulse { 0% { transform: scale(1) } 100% { transform: scale(1.08) } }
        @keyframes mb-weary { 0%,100% { transform: translateY(0)     scaleY(1) }
                              55%     { transform: translateY(1.6px) scaleY(.965) } }

        /* ~80% 다급 — 땀 한 방울 + 머리 위 느낌표.
           50~80% 는 '정신없음'이 아니라 '작업량이 조금 버거운' 정도라,
           튀어오르는 점프 대신 느리게 가라앉는 숨쉬기로 간다. */
        .char-stage.tier-jump .char-body { animation: mb-weary calc(var(--c) * 1.15) ease-in-out infinite; }
        .char-stage.tier-jump .mb-sweat  { display: block; }
        .char-stage.tier-jump .mb-drop2,
        .char-stage.tier-jump .mb-drop3  { display: none; }
        .char-stage.tier-jump .mb-drop1  { animation: mb-drop-a calc(var(--c) * 1.6) ease-in infinite; }
        .char-stage.tier-jump .mb-excl   { display: block; animation: mb-pulse var(--c) ease-in-out infinite alternate; }

        /* 불꽃이 위 공간을 쓰므로 점프 폭을 줄인다 — 안 그러면 불꽃이 잘린다 */
        .char-stage.tier-fire .char-body { animation: mb-fire-jump calc(var(--c) / 3) cubic-bezier(0.3,0.1,0.5,1) infinite; }
        .char-stage.tier-fire .char-walker { animation: mb-shake calc(var(--c) / 2) ease-in-out infinite alternate; }

        /* 90% 초과 — 같은 '불' 구간이라도 위험도가 다르다.
           앞선 버전은 채도·색조 필터만 바꿔서 22pt 에서 ~90% 와 똑같아 보였다(260904).
           **실루엣**(옆으로 번진 불)과 **색**(몸이 빨개짐)을 같이 바꿔야 한 눈에 갈린다. */
        .char-stage.tier-fire-hot .mb-blaze { display: block; }
        .char-stage.tier-fire-hot .mb-blaze-l,
        .char-stage.tier-fire-hot .mb-blaze-r { transform-box: fill-box; transform-origin: 50% 100%; }
        .char-stage.tier-fire-hot .mb-blaze-l { animation: mb-blaze-a calc(var(--c) / 4) steps(3, end) infinite; }
        .char-stage.tier-fire-hot .mb-blaze-r { animation: mb-blaze-b calc(var(--c) / 4) steps(3, end) infinite; }
        /* 몸통 path 만 겨냥한다 — 감은 눈·십자 눈은 g 안에 있어 영향받지 않는다 */
        .char-stage.tier-fire-hot .char-svg > path { animation: mb-scorch calc(var(--c) / 2) ease-in-out infinite alternate; }
        .char-stage.tier-fire-hot .char-svg   { animation: mb-overheat calc(var(--c) / 2) ease-in-out infinite alternate; }
        .char-stage.tier-fire-hot .char-walker { animation: mb-shake calc(var(--c) / 3.5) ease-in-out infinite alternate; }
        .char-stage.tier-fire-hot .char-body   { animation: mb-fire-jump calc(var(--c) / 4) cubic-bezier(0.3,0.1,0.5,1) infinite; }

        .char-stage.tier-dead .char-body { animation: none; }
        .char-stage.tier-dead .char-halo { animation: mb-halo var(--c) ease-in-out infinite; }

        /* ── 히든: 부활 (2.3초, 한 번만) ──
           한도가 초기화되면 나온다.
           위에서 빛이 내려오고 → 몸을 웅크렸다가 → 흰 날개가 돋고 → 천천히 떠올랐다가
           날개와 빛이 사라지며 내려앉는다. 이후 평소(잠) 상태로 넘어간다.
           날개·빛은 원본에 없는 맥 전용 요소다. */

        /* 위에서 내려오는 빛기둥 */
        .mb-spot { display:none; position:absolute; left:50%; top:-13px;
                   width:54px; height:48px; margin-left:-27px; pointer-events:none;
                   background: linear-gradient(to bottom,
                       rgba(255,250,225,.85) 0%, rgba(255,244,200,.26) 58%, rgba(255,240,190,0) 100%);
                   /* 아래를 100% 까지 벌리면 날개 자리까지 크림색이 깔려 흰 날개가 묻힌다 */
                   clip-path: polygon(42% 0%, 58% 0%, 80% 100%, 20% 100%);
                   filter: blur(1.2px); }
        /* 몸 뒤에서 퍼지는 잔광 */
        .mb-glow { display:none; position:absolute; left:50%; top:50%;
                   width:52px; height:44px; margin-left:-26px; margin-top:-22px; pointer-events:none;
                   background: radial-gradient(circle at 50% 55%,
                       rgba(255,250,228,.7) 0%, rgba(255,244,205,.22) 42%, rgba(255,240,190,0) 66%); }
        .mb-wings { display:none; position:absolute; left:50%; top:50%;
                    width:63px; height:35px; margin-left:-31.5px; margin-top:-17.5px;
                    pointer-events:none; overflow:visible; }

        .char-stage.tier-revive .mb-spot,
        .char-stage.tier-revive .mb-glow,
        .char-stage.tier-revive .mb-wings { display:block; }
        /* 흰 날개는 밝은 메뉴바에서 배경에 묻힌다. 사방 윤곽으로 형태를 남긴다. */
        .char-stage.tier-revive .mb-wing { transform-origin: 50% 50%;
              filter: drop-shadow(0 1px 0 rgba(120,95,45,.85))
                      drop-shadow(0 -1px 0 rgba(120,95,45,.85))
                      drop-shadow(1px 0 0 rgba(120,95,45,.85))
                      drop-shadow(-1px 0 0 rgba(120,95,45,.85)); }

        @keyframes mb-rev-spot {          /* 빛이 먼저 내려온다 */
          0%      { opacity:0; transform:scaleY(.3) }
          14%     { opacity:.95; transform:scaleY(1) }
          62%     { opacity:.8; transform:scaleY(1) }
          88%,100%{ opacity:0; transform:scaleY(1) }
        }
        @keyframes mb-rev-glow {
          0%,18%  { opacity:0 }
          42%     { opacity:1 }
          72%     { opacity:.75 }
          92%,100%{ opacity:0 }
        }
        @keyframes mb-rev-eyes {          /* X 눈은 날개가 돋을 때 사라진다 */
          0%,40% { opacity:1 } 41%,100% { opacity:0 }
        }
        @keyframes mb-rev-halo {          /* 후광은 초반에 떠나간다 */
          0%   { opacity:.85; transform:translateY(0)     scaleX(1) }
          40%  { opacity:.3;  transform:translateY(-9px)  scaleX(.6) }
          64%,100% { opacity:0; transform:translateY(-16px) scaleX(.3) }
        }
        @keyframes mb-rev-color {         /* 회색 → 제 색 */
          0%,34% { filter:grayscale(1) brightness(.74); opacity:.9 }
          58%    { filter:grayscale(.4) brightness(.93); opacity:1 }
          78%,100% { filter:grayscale(0) brightness(1); opacity:1 }
        }
        @keyframes mb-rev-hop {           /* 웅크림 → 천천히 떠오름 → 내려앉음 */
          0%,20% { transform: translateY(0)     scaleY(1) }
          34%    { transform: translateY(1px)   scaleY(.78) }   /* 웅크림 */
          46%    { transform: translateY(0)     scaleY(1.05) }  /* 펴짐 */
          70%    { transform: translateY(-7px)  scaleY(1) }     /* 떠오름 */
          86%    { transform: translateY(-9px)  scaleY(1) }     /* 정점 */
          100%   { transform: translateY(0)     scaleY(1) }     /* 내려앉음 */
        }
        @keyframes mb-rev-wing-l {        /* 돋아나 천천히 퍼덕이다 사라진다 */
          0%,40%  { opacity:0; transform: scale(.15) translateX(7px) }
          52%     { opacity:1; transform: scale(1)   translateX(0) }
          68%     { opacity:1; transform: scale(1) rotate(-10deg) }
          82%     { opacity:1; transform: scale(1) rotate(-1deg) }
          100%    { opacity:0; transform: scale(.8)  translateX(5px) }
        }
        @keyframes mb-rev-wing-r {
          0%,40%  { opacity:0; transform: scale(.15) translateX(-7px) }
          52%     { opacity:1; transform: scale(1)   translateX(0) }
          68%     { opacity:1; transform: scale(1) rotate(10deg) }
          82%     { opacity:1; transform: scale(1) rotate(1deg) }
          100%    { opacity:0; transform: scale(.8)  translateX(-5px) }
        }

        .char-stage.tier-revive .mb-spot     { animation: mb-rev-spot  var(--rc) ease-out both; }
        .char-stage.tier-revive .mb-glow     { animation: mb-rev-glow  var(--rc) ease-in-out both; }
        .char-stage.tier-revive .char-eyes-x { display:block; animation: mb-rev-eyes var(--rc) steps(1,end) both; }
        .char-stage.tier-revive .char-halo   { display:block; animation: mb-rev-halo var(--rc) ease-out both; }
        .char-stage.tier-revive .char-svg    { animation: mb-rev-color var(--rc) ease-in-out both; }
        .char-stage.tier-revive .char-body   { animation: mb-rev-hop   var(--rc) ease-in-out both; }
        .char-stage.tier-revive .mb-wing-l   { animation: mb-rev-wing-l var(--rc) ease-in-out both; }
        .char-stage.tier-revive .mb-wing-r   { animation: mb-rev-wing-r var(--rc) ease-in-out both; }
        """
    }
}
