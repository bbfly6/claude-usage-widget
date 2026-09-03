import Foundation

// src/server.js 의 fetchUsage() 를 그대로 이식한다.
// 렌더러가 읽는 필드 이름·의미가 Windows 와 100% 같아야 UI 를 공유할 수 있다.
let USAGE_URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

private struct APIResponse: Decodable {
    struct Window: Decodable { let utilization: Double?; let resets_at: String? }
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let display_name: String? }
            let model: Model?
        }
        let kind: String?
        let percent: Double?
        let scope: Scope?
    }
    struct Extra: Decodable { let is_enabled: Bool? }
    let five_hour: Window?
    let seven_day: Window?
    let limits: [Limit]?
    let extra_usage: Extra?
}

enum UsageAPI {
    // src/server.js readScopedLimit() 이식.
    // seven_day_sonnet 은 항상 null 이라 못 쓴다 (260821 실측).
    // 실제 값과 모델 이름은 limits[] 의 weekly_scoped 에 있다.
    private static func scopedLimit(_ j: APIResponse) -> (String, Double) {
        guard let s = j.limits?.first(where: { $0.kind == "weekly_scoped" }) else { return ("", 0) }
        return (s.scope?.model?.display_name ?? "", s.percent ?? 0)
    }

    /// 렌더러의 GET /api/usage 에 대응. 실패는 예외 대신 {"error": ...} 로 돌려준다.
    static func fetchUsage() async -> [String: Any] {
        guard let creds = readCredentials() else { return ["error": "NO_CREDENTIALS"] }

        var req = URLRequest(url: USAGE_URL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data, status: Int
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            data = d
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return ["error": "NETWORK"]
        }

        if status == 401 || status == 403 { return ["error": "TOKEN_EXPIRED"] }
        if status == 429 { return ["error": "RATE_LIMITED"] }
        guard status == 200 else { return ["error": "HTTP \(status)"] }
        guard let j = try? JSONDecoder().decode(APIResponse.self, from: data) else {
            return ["error": "PARSE"]
        }

        // 5시간 한도 리셋까지 남은 초. 음수는 0 으로 (서버 구현과 동일)
        var sessionResetSeconds = 0
        if let s = j.five_hour?.resets_at, let d = parseISO(s) {
            sessionResetSeconds = max(0, Int(d.timeIntervalSinceNow))
        }
        let (scopedName, scopedPercent) = scopedLimit(j)

        // 플랜은 API 가 아니라 인증 정보에서 온다 (응답에 플랜 필드가 없다, 260824 실측)
        var plan = planLabel(creds)
        if !plan.isEmpty, j.extra_usage?.is_enabled == true { plan += " (Extra)" }

        return [
            "isConnected": true,
            "sessionUsagePercent": j.five_hour?.utilization ?? 0,
            "sessionResetSeconds": sessionResetSeconds,
            "weeklyAllModelsPercent": j.seven_day?.utilization ?? 0,
            // 포맷은 렌더러가 현재 언어로 처리한다 — 서버는 ISO 문자열만 넘긴다
            "weeklyAllModelsResetAt": j.seven_day?.resets_at ?? "",
            "scopedModelName": scopedName,
            "scopedModelPercent": scopedPercent,
            "planName": plan,
        ]
    }

    /// 렌더러의 GET /api/credentials 에 대응.
    /// found 만 주면 "파일은 있는데 만료된" 상태를 구분 못 해 로그인 버튼이 사라진다.
    static func credentialsStatus() -> [String: Any] {
        let c = readCredentials()
        return ["found": c != nil, "expired": isExpired(c), "plan": planLabel(c)]
    }

    // Anthropic 은 소수점 6자리 + 오프셋을 준다: 2026-09-02T05:09:59.678587+00:00
    private static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
