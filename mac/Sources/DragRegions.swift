import Foundation

// WebKit 은 -webkit-app-region 을 파싱조차 하지 않는다 (260903 실측:
// getComputedStyle 도 cssRules 도 빈 값). Electron 전용 확장이라 그렇다.
//
// style.css 를 고치지 않고 드래그 영역을 알아내기 위해, 빌드된 CSS 원문에서
// 해당 선언을 가진 선택자만 뽑아 브리지에 넘긴다. UI 파일은 Windows 와 계속 동일하게 유지된다.
enum DragRegions {
    /// (드래그 선택자, 제외 선택자) 를 CSS 셀렉터 문자열로 돌려준다.
    static func parse(_ css: String) -> (drag: String, noDrag: String) {
        var drag: [String] = [], noDrag: [String] = []
        // "선택자 { 선언들 }" 단위로 자른다. @media 등 중첩 블록은 여는 괄호가 남지만
        // 선택자 자리에 '@' 나 '{' 가 섞이므로 아래에서 걸러진다.
        for chunk in css.components(separatedBy: "}") {
            guard let brace = chunk.firstIndex(of: "{") else { continue }
            let body = chunk[chunk.index(after: brace)...]
            guard body.contains("-webkit-app-region") else { continue }
            var sel = chunk[..<brace]
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            // 앞 블록에서 흘러든 주석·중첩 잔재 제거
            if let r = sel.range(of: "*/", options: .backwards) { sel = String(sel[r.upperBound...]) }
            if let r = sel.range(of: "{", options: .backwards) { sel = String(sel[r.upperBound...]) }
            sel = sel.trimmingCharacters(in: .whitespaces)
            guard !sel.isEmpty, !sel.hasPrefix("@") else { continue }

            if body.contains("-webkit-app-region: no-drag") || body.contains("-webkit-app-region:no-drag") {
                noDrag.append(sel)
            } else if body.contains("-webkit-app-region: drag") || body.contains("-webkit-app-region:drag") {
                drag.append(sel)
            }
        }
        return (drag.joined(separator: ", "), noDrag.joined(separator: ", "))
    }
}
