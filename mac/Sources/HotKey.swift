import AppKit
import Carbon.HIToolbox

// 전역 단축키.
//
// NSEvent.addGlobalMonitorForEvents 를 쓰면 '손쉬운 사용' 권한을 받아야 하고,
// 그 권한은 키 입력 전체를 훔쳐볼 수 있는 것이라 사용량 위젯이 요구하기엔 과하다.
// Carbon 의 RegisterEventHotKey 는 권한 없이 특정 조합 하나만 받는다.
// 오래된 API 지만 대체재가 없고, 맥 메뉴바 앱들이 지금도 이 방식을 쓴다.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    /// 4바이트 서명. 다른 앱의 핫키 이벤트와 구분하는 용도다.
    private static let signature: OSType = 0x43555721   // 'CUW!'

    var onFire: (() -> Void)?

    private init() {}

    /// 현재 저장된 설정대로 다시 등록한다. 이미 등록돼 있으면 먼저 푼다.
    func reload() {
        unregister()
        guard !Prefs.hotKeyDisabled else {
            Dbg.log("단축키 사용 안 함")
            return
        }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let st = RegisterEventHotKey(Prefs.hotKeyCode, Prefs.hotKeyMods,
                                     id, GetApplicationEventTarget(), 0, &ref)
        if st == noErr {
            Dbg.log("단축키 등록: \(Prefs.hotKeyLabel)")
        } else {
            // 다른 앱이 이미 같은 조합을 쓰고 있으면 여기서 실패한다.
            Dbg.log("단축키 등록 실패 (\(st)) — 다른 앱이 \(Prefs.hotKeyLabel) 를 쓰는 중일 수 있다")
            ref = nil
        }
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    /// 등록에 성공했는지. 메뉴에 표시해 사용자가 충돌을 알아채게 한다.
    var isActive: Bool { ref != nil }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // C 함수 포인터라 아무것도 캡처할 수 없다. 싱글턴을 통해 되돌아온다.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard hk.signature == HotKeyCenter.signature else { return noErr }
            // Carbon 핸들러는 메인 스레드에서 오지만, Swift 6 는 그걸 알지 못한다.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.onFire?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
