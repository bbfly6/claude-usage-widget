import AppKit
import CryptoKit

// 자체 업데이트.
//
// Sparkle 을 쓰지 않는 이유:
//  - 프레임워크가 11~14MB 다. 앱이 876KB 인데 12MB 로 커진다.
//    크기는 Electron 대신 하이브리드를 고른 이유의 절반이었다.
//  - 공식 문서가 Developer ID 서명을 전제로 쓰여 있고, 애드혹 서명에서 도는지 확인할 길이 없다.
//  - appcast XML 을 따로 만들어 어딘가에 올려야 한다.
// GitHub Releases 는 이미 배포 채널이라(bbfly6/claude-usage-widget) API 로 읽으면 그만이다.
//
// 서명이 없으므로 **격리 표시를 우리가 지운다**. 안 지우면 업데이트할 때마다
// 사용자가 우클릭 → 열기를 해야 한다.
@MainActor
enum Updater {
    struct Release {
        let version: String
        let notes: String
        let zipURL: URL
        let sha256: URL?
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case available(String)
        case downloading(Int)      // 0~100
        case installing
        case failed(String)
    }

    private(set) static var state: State = .idle
    private(set) static var latest: Release?
    /// 상태가 바뀔 때마다 위젯 창에 알린다.
    static var onState: ((State) -> Void)?

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 테스트할 때 로컬 서버를 보게 하려고 열어둔다. 평소에는 GitHub.
    private static var feedURL: URL {
        if let s = ProcessInfo.processInfo.environment["CLAUDE_WIDGET_FEED"], let u = URL(string: s) {
            return u
        }
        return URL(string: "https://api.github.com/repos/bbfly6/claude-usage-widget/releases/latest")!
    }

    private static func set(_ s: State) {
        state = s
        onState?(s)
        Dbg.log("업데이트 상태: \(s)")
    }

    // MARK: 확인

    @discardableResult
    static func check() async -> Release? {
        if case .downloading = state { return latest }
        if case .installing = state { return latest }
        set(.checking)
        do {
            var req = URLRequest(url: feedURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            // file:// 로 시험할 때는 HTTPURLResponse 가 아니다. 상태 코드는 있을 때만 본다.
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                Dbg.log("업데이트 확인: HTTP \(http.statusCode)")
                set(.idle); return nil
            }
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String else { set(.idle); return nil }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = j["assets"] as? [[String: Any]] ?? []
            // 맥용 zip 을 찾는다. 이름 규칙은 mac/build.sh 가 만든다.
            let macZip = assets.first {
                let n = ($0["name"] as? String ?? "").lowercased()
                return n.contains("mac") && n.hasSuffix(".zip")
            }
            guard let a = macZip, let s = a["browser_download_url"] as? String, let url = URL(string: s) else {
                Dbg.log("업데이트: 맥용 zip 자산 없음 (자산 \(assets.count)개)")
                set(.idle); return nil
            }
            let shaAsset = assets.first { ($0["name"] as? String ?? "").lowercased().hasSuffix(".sha256") }
            let r = Release(
                version: ver,
                notes: (j["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                zipURL: url,
                sha256: (shaAsset?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                pageURL: URL(string: j["html_url"] as? String ?? "https://github.com/bbfly6/claude-usage-widget/releases")!)
            latest = r
            if isNewer(r.version, than: current) {
                set(.available(r.version))
                return r
            }
            set(.idle)
            return nil
        } catch {
            Dbg.log("업데이트 확인 실패: \(error.localizedDescription)")
            set(.idle)
            return nil
        }
    }

    /// 1.7.10 > 1.7.9 가 되도록 숫자로 비교한다. 문자열 비교로는 뒤집힌다.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: 설치

    static func install() async {
        guard let r = latest else { return }
        do {
            set(.downloading(0))
            let zip = try await download(r.zipURL)
            if let s = r.sha256 { try await verifySHA(zip, listURL: s) }
            set(.installing)
            let newApp = try unpack(zip)
            try validate(newApp, expecting: r.version)
            try swapAndRelaunch(newApp)
        } catch {
            Dbg.log("업데이트 실패: \(error.localizedDescription)")
            set(.failed(error.localizedDescription))
        }
    }

    private static func download(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw Err("다운로드 실패 (HTTP \(http.statusCode))")
        }
        let total = resp.expectedContentLength
        var data = Data()
        data.reserveCapacity(total > 0 ? Int(total) : 1 << 20)
        var lastPct = -1
        for try await b in bytes {
            data.append(b)
            if total > 0 {
                let pct = Int(Double(data.count) / Double(total) * 100)
                if pct != lastPct, pct % 2 == 0 { lastPct = pct; set(.downloading(pct)) }
            }
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuw-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("update.zip")
        try data.write(to: out)
        Dbg.log("업데이트 내려받음 \(data.count) bytes")
        return out
    }

    /// 체크섬은 TLS 로 이미 인증된 경로에서 오므로 위조를 막지는 못한다.
    /// 받다 만 파일·깨진 파일을 거르는 용도다.
    ///
    /// 자산이 있으면 **반드시 통과해야** 설치한다. 읽지 못하거나 형식이 틀리면 멈춘다 —
    /// 처음엔 그런 경우 조용히 건너뛰게 했는데, 파일 끝 줄바꿈 때문에 64자 검사에 걸려
    /// 검증을 통째로 건너뛰면서도 성공한 것처럼 보였다 (260907 실측).
    private static func verifySHA(_ file: URL, listURL: URL) async throws {
        let data: Data
        do { (data, _) = try await URLSession.shared.data(from: listURL) }
        catch { throw Err("체크섬 파일을 받지 못했습니다") }
        guard let text = String(data: data, encoding: .utf8) else { throw Err("체크섬 파일이 깨졌습니다") }
        // "<해시>  <파일이름>" 이거나 해시만 있을 수 있다. 공백·줄바꿈을 모두 털어낸다.
        let want = (text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "").lowercased()
        guard want.count == 64, want.allSatisfy(\.isHexDigit) else {
            throw Err("체크섬 형식이 올바르지 않습니다")
        }
        let got = SHA256.hash(data: try Data(contentsOf: file))
            .map { String(format: "%02x", $0) }.joined()
        guard got == want else { throw Err("체크섬 불일치") }
        Dbg.log("체크섬 확인됨 \(want.prefix(12))…")
    }

    private static func unpack(_ zip: URL) throws -> URL {
        let dest = zip.deletingLastPathComponent().appendingPathComponent("x")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        // ditto 를 쓴다. unzip 은 맥 번들의 심볼릭 링크·확장속성을 망가뜨린다.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Err("압축 풀기 실패") }
        let apps = (try FileManager.default.contentsOfDirectory(atPath: dest.path))
            .filter { $0.hasSuffix(".app") }
        guard let name = apps.first else { throw Err("내려받은 파일에 앱이 없습니다") }
        return dest.appendingPathComponent(name)
    }

    /// 바꿔치기 전에 확인한다. 서명이 없으니 이 검사가 유일한 방어선이다.
    private static func validate(_ app: URL, expecting version: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) as? [String: Any] else {
            throw Err("Info.plist 를 읽을 수 없습니다")
        }
        guard d["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Err("다른 앱입니다")
        }
        guard d["CFBundleShortVersionString"] as? String == version else {
            throw Err("버전이 맞지 않습니다")
        }
        let exe = app.appendingPathComponent("Contents/MacOS/ClaudeUsageWidget")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw Err("실행 파일이 없습니다")
        }
        // 서명이 온전한지 — 내려받은 뒤 손댄 흔적이 있으면 여기서 걸린다
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", app.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Err("서명 검증 실패") }
        Dbg.log("새 앱 검증 통과: \(version)")
    }

    /// 실행 중인 앱은 자기 자신을 지울 수 없다. 도우미 스크립트에 맡기고 우리는 종료한다.
    /// 실패하면 원래 앱을 되돌려 놓는다 — 여기서 잘못되면 앱이 통째로 사라진다.
    private static func swapAndRelaunch(_ newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let log = NSTemporaryDirectory() + "cuw-swap.log"
        let script = """
        #!/bin/bash
        APP=$1; NEW=$2; PID=$3
        exec >>"\(log)" 2>&1
        echo "--- $(date) pid=$PID"
        for _ in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$PID" 2>/dev/null; then echo "앱이 안 끝남 — 중단"; exit 1; fi
        BAK="$APP.old"
        rm -rf "$BAK"
        mv "$APP" "$BAK" || { echo "백업 실패"; exit 1; }
        if ! mv "$NEW" "$APP"; then
          echo "교체 실패 — 되돌림"; mv "$BAK" "$APP"; exit 1
        fi
        # 서명이 없으므로 격리 표시를 지운다. 안 지우면 열 때마다 우클릭해야 한다.
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        rm -rf "$BAK"
        echo "교체 완료 — 다시 켠다"
        open "$APP"
        """
        let path = NSTemporaryDirectory() + "cuw-swap-\(UUID().uuidString).sh"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        // 그냥 자식으로 띄우면 앱이 끝날 때 같이 죽는다 (260907 실측 — 교체가 아예 일어나지 않았다).
        // LaunchServices 로 뜬 앱은 launchd 작업이라 종료할 때 자손까지 정리된다.
        // 바깥 셸을 즉시 끝내고 nohup 으로 배경에 두어 launchd 로 입양시킨다.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "nohup \"$0\" \"$1\" \"$2\" \"$3\" >/dev/null 2>&1 &",
                       path, target.path, newApp.path,
                       String(ProcessInfo.processInfo.processIdentifier)]
        try p.run()
        p.waitUntilExit()          // 바깥 셸이 배경 작업을 띄우고 바로 끝난다
        Dbg.log("교체 스크립트 분리 실행 (기록: \(log)) — 종료합니다")
        NSApp.terminate(nil)
    }

    struct Err: LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }
}
