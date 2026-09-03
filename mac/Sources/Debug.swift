import Foundation

// 진단용 로그. CLAUDE_WIDGET_DEBUG=1 일 때만 파일에 남는다.
// 인증 토큰 값은 어떤 경우에도 기록하지 않는다.
enum Dbg {
    static let enabled = ProcessInfo.processInfo.environment["CLAUDE_WIDGET_DEBUG"] == "1"
    static let path = NSTemporaryDirectory() + "claude-widget-mac.log"

    static func log(_ m: String) {
        guard enabled else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(m)\n"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close()
        }
    }
}
