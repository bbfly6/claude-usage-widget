import AppKit
import Carbon.HIToolbox

// 단축키 직접 지정 창.
//
// 위젯 화면(HTML) 안에 넣지 않는 이유: src/ 는 Windows 와 공유라 고칠 수 없고,
// 단축키는 어차피 맥에만 있는 개념이라 네이티브 쪽이 제자리다.
@MainActor
final class HotKeyRecorder: NSObject {
    private static var current: HotKeyRecorder?

    private let panel: NSPanel
    private let field: NSTextField
    private var monitor: Any?
    private let onDone: () -> Void
    private let ko: Bool

    static func show(korean: Bool, onDone: @escaping () -> Void) {
        current?.close()
        let r = HotKeyRecorder(korean: korean, onDone: onDone)
        current = r
        r.present()
    }

    private init(korean: Bool, onDone: @escaping () -> Void) {
        self.ko = korean
        self.onDone = onDone
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 132),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = korean ? "단축키 지정" : "Set shortcut"
        panel.isFloatingPanel = true
        panel.level = .modalPanel

        let hint = NSTextField(labelWithString: korean
            ? "새 단축키를 누르세요. esc 로 취소."
            : "Press the new shortcut. esc to cancel.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 16, y: 22, width: 288, height: 16)

        field = NSTextField(labelWithString: Prefs.hotKeyLabel)
        field.font = .systemFont(ofSize: 26, weight: .medium)
        field.alignment = .center
        field.frame = NSRect(x: 16, y: 52, width: 288, height: 34)

        panel.contentView?.addSubview(hint)
        panel.contentView?.addSubview(field)
        super.init()
    }

    private func present() {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // 등록해 둔 전역 단축키가 살아 있으면 녹화 중에 그 조합이 가로채인다. 잠깐 푼다.
        HotKeyCenter.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handle(e) ? nil : e
        }
    }

    /// true 를 돌려주면 이벤트를 삼킨다.
    private func handle(_ e: NSEvent) -> Bool {
        if e.keyCode == UInt16(kVK_Escape) { finish(save: false); return true }
        let mods = Prefs.carbonMods(e.modifierFlags)
        // 수정키가 없으면 전역 단축키로 쓸 수 없다 — 그냥 'C' 를 뺏어가면 안 되니까.
        guard mods != 0 else {
            field.stringValue = ko ? "⌘ ⌥ ⌃ ⇧ 중 하나는 필요" : "Needs ⌘ ⌥ ⌃ or ⇧"
            return true
        }
        let key = (e.charactersIgnoringModifiers ?? "").uppercased()
        let name = Self.specialKeyName(e.keyCode) ?? (key.isEmpty ? "?" : key)
        Prefs.hotKeyCode = UInt32(e.keyCode)
        Prefs.hotKeyMods = mods
        Prefs.hotKeyLabel = Prefs.label(mods: mods, key: name)
        Prefs.hotKeyDisabled = false
        field.stringValue = Prefs.hotKeyLabel
        // 바뀐 걸 눈으로 확인하고 닫히도록 한 박자 둔다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.finish(save: true)
        }
        return true
    }

    /// 문자로 표시되지 않는 키들. 나머지는 charactersIgnoringModifiers 로 충분하다.
    private static func specialKeyName(_ c: UInt16) -> String? {
        switch Int(c) {
        case kVK_Space:        return "Space"
        case kVK_Return:       return "↩"
        case kVK_Tab:          return "⇥"
        case kVK_LeftArrow:    return "←"
        case kVK_RightArrow:   return "→"
        case kVK_UpArrow:      return "↑"
        case kVK_DownArrow:    return "↓"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2";  case kVK_F3:  return "F3"
        case kVK_F4:  return "F4";  case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8";  case kVK_F9:  return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return nil
        }
    }

    private func finish(save: Bool) {
        close()
        HotKeyCenter.shared.reload()
        if save { onDone() }
    }

    private func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        panel.close()
        if HotKeyRecorder.current === self { HotKeyRecorder.current = nil }
    }
}
