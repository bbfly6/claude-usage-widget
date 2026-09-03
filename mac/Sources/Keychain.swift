import Foundation

// ===== Credentials (READ-ONLY) =====
// 위젯은 인증 정보를 절대 쓰지 않는다. 갱신은 Claude Code 담당.
//
// 맥은 Claude Code 가 로그인 키체인에 저장한다 (~/.claude/.credentials.json 은 없다).
//   service = "Claude Code-credentials", account = 로그인 사용자명
//
// SecItemCopyMatching 으로 직접 읽지 말 것. 260902 실측:
//   앱 바이너리가 직접 호출하면 SecurityAgent 권한 프롬프트가 뜨고 그 자리에서 블록된다.
//   (Security::SecurityServer::ClientSession::decrypt 에서 정지)
//   /usr/bin/security 에 위임하면 프롬프트 없이 11ms 만에 읽힌다.
enum Keychain {
    static let service = "Claude Code-credentials"

    static func readRaw() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}

struct OAuthCredentials: Decodable {
    let accessToken: String
    let expiresAt: Double?
    let subscriptionType: String?
}

private struct CredentialsFile: Decodable {
    let claudeAiOauth: OAuthCredentials?
}

func readCredentials() -> OAuthCredentials? {
    // 1) 키체인 (맥 기본 경로)
    if let d = Keychain.readRaw(),
       let f = try? JSONDecoder().decode(CredentialsFile.self, from: d),
       let o = f.claudeAiOauth, !o.accessToken.isEmpty {
        return o
    }
    // 2) 파일 폴백 — 구버전이나 수동 설치 환경 대비 (Windows 와 같은 경로 규칙)
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    if let d = try? Data(contentsOf: path),
       let f = try? JSONDecoder().decode(CredentialsFile.self, from: d),
       let o = f.claudeAiOauth, !o.accessToken.isEmpty {
        return o
    }
    return nil
}

// src/server.js 의 planLabel() 이식
private let PLAN_LABEL: [String: String] = [
    "max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise", "free": "Free",
]
func planLabel(_ c: OAuthCredentials?) -> String {
    let t = (c?.subscriptionType ?? "").lowercased()
    if t.isEmpty { return "" }
    return PLAN_LABEL[t] ?? t.prefix(1).uppercased() + t.dropFirst()
}

// src/server.js 의 isExpired() 이식.
// 위젯은 토큰을 갱신하지 않으므로 만료되면 재로그인 외 방법이 없다.
func isExpired(_ c: OAuthCredentials?) -> Bool {
    guard let e = c?.expiresAt else { return false }
    return Date().timeIntervalSince1970 * 1000 >= e
}
