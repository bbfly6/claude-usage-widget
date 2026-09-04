import AppKit
import UserNotifications

// 사용량 임계값 알림.
//
// UNUserNotificationCenter 는 번들과 코드 서명을 확인한다.
// 애드혹 서명(개발자 인증서 없음)에서도 되는지가 이 기능의 전제라 먼저 확인하고 들어간다.
@MainActor
enum Notifications {
    private(set) static var authorized = false
    static var lastError = ""

    /// 묻지 않고 현재 권한만 읽는다. 실행 때 부른다.
    static func refreshAuthorization() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        if let st = await withTimeout(seconds: 3, { await c.notificationSettings().authorizationStatus }) {
            authorized = (st == .authorized || st == .provisional)
            Dbg.log("알림 권한 상태=\(st.rawValue) 사용가능=\(authorized)")
        }
    }

    /// 사용자가 알림을 켤 때 부른다. 거부당해도 앱은 그대로 동작해야 한다.
    static func requestIfNeeded() async {
        // 번들 밖(예: swift 스크립트)에서 부르면 크래시한다. 번들 여부부터 본다.
        guard Bundle.main.bundleIdentifier != nil else {
            lastError = "번들 아님"; return
        }
        let c = UNUserNotificationCenter.current()
        // 애드혹 서명 + 임의 위치에서는 콜백이 **영영 오지 않는다** (260904 실측, 45초 대기해도 무응답).
        // 오류도 아니고 거부도 아니라 그냥 응답이 없다. 시한을 두지 않으면 여기서 앱이 멈춘다.
        // 상태를 먼저 본다 — 이미 거부로 굳었으면 요청해도 대화상자가 안 뜬다
        if let pre = await withTimeout(seconds: 3, { await c.notificationSettings().authorizationStatus.rawValue }) {
            Dbg.log("알림 사전상태=\(pre) (0=미정 1=거부 2=허용)")
        }
        let ok = await withTimeout(seconds: 8) { () -> Bool in
            do { return try await c.requestAuthorization(options: [.alert, .sound]) }
            catch {
                await MainActor.run { Notifications.lastError = "\(error)" }
                return false
            }
        }
        guard let ok else {
            lastError = "무응답 (서명·등록 문제로 보임)"
            Dbg.log("알림 권한 요청 무응답 — 5초 시한 초과")
            return
        }
        authorized = ok
        if let s = await withTimeout(seconds: 3, { await c.notificationSettings().authorizationStatus.rawValue }) {
            Dbg.log("알림 권한 요청 -> 승인=\(authorized) 상태=\(s)")
        } else {
            Dbg.log("알림 권한 요청 -> 승인=\(authorized) (설정 조회 무응답)")
        }
    }

    /// 시한 안에 끝나면 결과, 넘기면 nil. 응답이 아예 없는 시스템 호출을 감싸는 용도다.
    private static func withTimeout<T: Sendable>(seconds: Double,
                                                 _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { await work() }
            g.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }

    /// 이미 알린 임계값. 다시 그 아래로 내려가면 지워서 한 주기에 한 번만 알리게 한다.
    private static var fired: [String: Set<Int>] = [:]

    /// 사용량이 임계값을 넘는 순간 한 번만 알린다.
    /// - 넘긴 뒤 계속 머물러도 다시 알리지 않는다.
    /// - 임계값 아래로 내려가면(한도 초기화 등) 다시 알릴 수 있게 푼다.
    static func checkThresholds(kind: String, label: String, percent: Double, korean: Bool) async {
        guard Prefs.notifyThresholds, authorized else { return }
        for n in decide(kind: kind, label: label, percent: percent, korean: korean) {
            await post(title: n.title, body: n.body, id: n.id)
        }
    }

    /// 무엇을 보낼지만 정한다. 실제 발송과 분리해야 권한 없이도 규칙을 검증할 수 있다.
    /// 부수효과는 fired 갱신뿐이다.
    static func decide(kind: String, label: String, percent: Double,
                       korean: Bool) -> [(title: String, body: String, id: String)] {
        var out: [(String, String, String)] = []
        var seen = fired[kind] ?? []
        for t in [80, 90] {
            if percent >= Double(t) {
                guard !seen.contains(t) else { continue }
                seen.insert(t)
                out.append((korean ? "\(label) \(t)% 도달" : "\(label) reached \(t)%",
                            korean ? "현재 \(Int(percent.rounded()))% 사용 중입니다."
                                   : "Currently at \(Int(percent.rounded()))%.",
                            "\(kind)-\(t)"))
            } else {
                seen.remove(t)      // 아래로 내려가면 다시 알릴 수 있게 푼다
            }
        }
        fired[kind] = seen
        return out
    }

    /// 검증용. 판정 상태를 초기화한다.
    static func resetFired() { fired.removeAll() }

    static func post(title: String, body: String, id: String) async {
        guard authorized else { Dbg.log("알림 건너뜀 (권한 없음)"); return }
        let c = UNNotificationContent.make(title: title, body: body)
        let req = UNNotificationRequest(identifier: id, content: c, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(req)
            Dbg.log("알림 전송: \(id)")
        } catch {
            Dbg.log("알림 전송 실패: \(error.localizedDescription)")
        }
    }
}

private extension UNNotificationContent {
    static func make(title: String, body: String) -> UNNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        return c
    }
}
