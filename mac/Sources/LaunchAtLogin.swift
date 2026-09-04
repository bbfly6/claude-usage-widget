import AppKit
import ServiceManagement

// 로그인 시 자동 시작.
//
// 예전 방식(SMLoginItemSetEnabled + 별도 헬퍼 앱)은 번들 안에 헬퍼를 하나 더 넣어야 했다.
// macOS 13 부터는 SMAppService.mainApp 으로 앱 자신을 바로 등록할 수 있다.
// 배포 최소 버전이 13.0 이므로 분기가 필요 없다.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 실패하면 false. 성공 여부를 메뉴 체크 표시에 그대로 반영해야
    /// 껐다 켜지지 않는 상태를 사용자가 알아챈다.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            Dbg.log("자동시작 \(on ? "켬" : "끔") -> \(SMAppService.mainApp.status.rawValue)")
            return true
        } catch {
            // 흔한 실패: 앱이 ~/Downloads 나 임시 폴더에 있을 때. /Applications 로 옮기면 된다.
            Dbg.log("자동시작 변경 실패: \(error.localizedDescription)")
            return false
        }
    }

    /// 등록은 됐지만 사용자가 시스템 설정에서 꺼둔 상태.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}
