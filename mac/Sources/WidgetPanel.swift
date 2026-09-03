import AppKit

// borderless 창은 canBecomeKey 가 기본 false 라서 key window 가 되지 못한다.
// key 가 아니면 WKWebView 가 mouseMoved 를 받지 못해 요소별 커서(손가락/화살표)가 갱신되지 않고
// 창 전체가 하나의 커서로 굳는다 (260903 실측: NSApp.isActive=true 인데 key=false).
//
// 타이틀바 없이 쓰면서 상호작용도 하려면 이 두 개를 열어줘야 한다.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
