import AppKit

// 개발 확인용. CLAUDE_WIDGET_DEBUG=1 일 때만 동작하며 배포 전 이 파일만 지우면 된다.
@MainActor
extension AppDelegate {
    func dumpFrameSheet() async {
        guard Dbg.enabled, !AppDelegate.sheetDumped, let ci = charIcon else { return }
        AppDelegate.sheetDumped = true
        let tiers: [(String, Double)] = [("sleep", 5), ("chill", 20), ("focus", 40),
                                         ("rush", 70), ("fire", 85), ("hot", 95), ("dead", 100)]
        // lockFocus 는 await 를 건너면 컨텍스트가 풀린다 — 먼저 전부 모은다.
        var rows: [[NSImage]] = []
        for t in tiers { rows.append(await ci.frames(forPercent: t.1)) }
        rows.append(await ci.frames(tier: CharacterIcon.reviveTier))
        let cell = 26.0
        let cols = Double(rows.map(\.count).max() ?? 1)
        let sheet = NSImage(size: NSSize(width: cell * cols, height: cell * Double(rows.count)))
        sheet.lockFocus()
        // 흰 배경이면 흰 날개가 묻혀 안 보인다 (260903). 다크 메뉴바 색으로 깐다.
        // 위 절반은 다크 메뉴바, 아래 절반은 라이트 메뉴바 색 — 양쪽에서 보이는지 한 번에 본다
        NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: cell * cols, height: cell * Double(rows.count)).fill()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: cell * cols, height: cell).fill()
        for (r, row) in rows.enumerated() {
            for (c, img) in row.enumerated() {
                let y = (Double(rows.count) - 1 - Double(r)) * cell
                img.draw(in: NSRect(x: Double(c) * cell + 2, y: y + 2, width: 22, height: 22))
            }
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "claude-frames.png"))
        }
        let names = tiers.map(\.0) + ["revive"]
        Dbg.log("프레임 시트: " + rows.enumerated().map { "\(names[$0.offset])=\($0.element.count)" }.joined(separator: " "))
    }
}
