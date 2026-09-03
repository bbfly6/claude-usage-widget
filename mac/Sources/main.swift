import AppKit

// 단일 인스턴스 잠금 — Windows 의 app.requestSingleInstanceLock() 대응.
// 이미 떠 있으면 그 인스턴스를 앞으로 꺼내고 조용히 종료한다.
let bundleID = Bundle.main.bundleIdentifier ?? "com.roy.claude-usage-widget"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if let existing = others.first {
    existing.activate(options: [])
    exit(0)
}

@MainActor
func boot() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // 델리게이트는 약참조라 전역에 붙들어 두지 않으면 해제된다
    objc_setAssociatedObject(app, "widgetDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    // 메뉴바 전용 — Dock 아이콘 없음 (Info.plist 의 LSUIElement 와 짝)
    app.setActivationPolicy(.accessory)
    app.run()
}
MainActor.assumeIsolated { boot() }
