import AppKit
import Carbon.HIToolbox

// 맥 전용 설정.
// 위젯 화면의 설정(언어·테마·창모드)은 renderer.js 가 localStorage 에 저장한다 — 그쪽은 Windows 와 공유다.
// 여기에는 **맥에만 있는 것**만 둔다. 서로 섞으면 Windows 설정 파일에 맥 키가 새어 들어간다.
enum Prefs {
    private static let d = UserDefaults.standard

    // MARK: 메뉴바 % 숫자
    private static let kPercent = "mac.menubar.showPercent"
    static var showPercent: Bool {
        get { d.object(forKey: kPercent) as? Bool ?? true }
        set { d.set(newValue, forKey: kPercent) }
    }

    // MARK: 전역 단축키 — 기본 ⌃⌥C
    // Carbon 은 자기 상수를 쓴다: controlKey 4096 / optionKey 2048 / shiftKey 512 / cmdKey 256.
    // NSEvent.ModifierFlags 값과 다르므로 변환해서 넣어야 한다.
    private static let kCode  = "mac.hotkey.code"
    private static let kMods  = "mac.hotkey.mods"
    private static let kLabel = "mac.hotkey.label"
    private static let kOff   = "mac.hotkey.disabled"

    static let defaultCode  = UInt32(kVK_ANSI_C)
    static let defaultMods  = UInt32(controlKey | optionKey)
    static let defaultLabel = "⌃⌥C"

    static var hotKeyCode: UInt32 {
        get { UInt32(d.object(forKey: kCode) as? Int ?? Int(defaultCode)) }
        set { d.set(Int(newValue), forKey: kCode) }
    }
    static var hotKeyMods: UInt32 {
        get { UInt32(d.object(forKey: kMods) as? Int ?? Int(defaultMods)) }
        set { d.set(Int(newValue), forKey: kMods) }
    }
    /// 표시용 문자열. keyCode 를 문자로 되돌리려면 UCKeyTranslate 가 필요한데,
    /// 녹화할 때 이미 charactersIgnoringModifiers 로 알 수 있으므로 그냥 같이 저장한다.
    static var hotKeyLabel: String {
        get { d.string(forKey: kLabel) ?? defaultLabel }
        set { d.set(newValue, forKey: kLabel) }
    }
    static var hotKeyDisabled: Bool {
        get { d.bool(forKey: kOff) }
        set { d.set(newValue, forKey: kOff) }
    }

    /// NSEvent 의 수정키를 Carbon 값으로 옮긴다.
    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option)  { m |= UInt32(optionKey) }
        if f.contains(.shift)   { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// 맥 표기 순서는 ⌃⌥⇧⌘ 다. 순서를 바꾸면 낯설게 보인다.
    static func label(mods: UInt32, key: String) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey)  != 0 { s += "⌥" }
        if mods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if mods & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + key
    }
}
