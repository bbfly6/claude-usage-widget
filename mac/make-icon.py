#!/usr/bin/env python3
"""맥 앱 아이콘 생성 — mac/icon.icns

src/icon-256.png 을 키우지 않는다. 그 파일은 가장자리가 안티에일리어싱돼 있어(알파 11단계)
확대하면 흐려진다. 캐릭터는 전부 축에 나란한 사각형이므로 좌표에서 직접 그린다.

좌표는 src/index.html 의 path 를 뜯어 확인한 것 (viewBox 24x24):
  머리·몸통 x 3~21,  y 5~17.079
  팔        x 0~3 및 21~24,  y 10.949~14.051
  다리      y 17.079~20,  x 4.487~6 / 7.488~9 / 15~16.513 / 18~19.513
  눈(구멍)  x 6~7.488 및 16.51~18,  y 8.102~10.949

윈도우 아이콘(src/icon-*.png)은 캐릭터만 있는 투명 배경이지만,
맥은 둥근 사각형 안에 들어가야 다른 앱 아이콘들과 나란히 놓았을 때 어색하지 않다.
"""
import os, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter

ORANGE = (217, 119, 87, 255)          # --claude-orange #D97757
CREAM_TOP = (250, 249, 246)           # 라이트 테마 --bg(#f7f6f3) 계열 위쪽
CREAM_BOT = (237, 234, 227)           # 아래쪽 — 아주 옅은 세로 그라데이션으로 깊이만 준다
ORANGE_TOP = (226, 133, 102)
ORANGE_BOT = (203, 105, 74)

# 기본은 주황 바탕 + 크림 캐릭터.
# 반대(크림 바탕 + 주황 캐릭터)는 윈도우 아이콘과 같은 모습이라 처음엔 그쪽을 만들었는데,
# 16px 에서 흰 바탕에 옅은 얼룩처럼 보여 못 알아본다 (260904 비교). LIGHT=1 로 그 배색을 쓴다.
INVERT = os.environ.get("LIGHT") != "1"

# 애플 아이콘 그리드: 1024 캔버스에 824 둥근사각형, 모서리 반경 185.4
ART = 824 / 1024
RADIUS = 185.4 / 824

BODY = (3, 5, 21, 17.079)
ARMS = [(0, 10.949, 3, 14.051), (21, 10.949, 24, 14.051)]
LEGS = [(4.487, 17.079, 6, 20), (7.488, 17.079, 9, 20),
        (15, 17.079, 16.513, 20), (18, 17.079, 19.513, 20)]
EYES = [(6, 8.102, 7.488, 10.949), (16.51, 8.102, 18, 10.949)]


def render(size, ss=4):
    bg_top, bg_bot = (ORANGE_TOP, ORANGE_BOT) if INVERT else (CREAM_TOP, CREAM_BOT)
    fg = (247, 244, 238, 255) if INVERT else ORANGE
    """size 픽셀 아이콘. ss 배로 그린 뒤 줄여 가장자리를 매끈하게 만든다."""
    n = size * ss
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))

    art = n * ART
    off = (n - art) / 2
    box = (off, off, off + art, off + art)
    r = art * RADIUS

    # 그림자 — 애플 아이콘은 자체적으로 옅은 그림자를 품는다
    sh = Image.new("L", (n, n), 0)
    ImageDraw.Draw(sh).rounded_rectangle(box, radius=r, fill=70)
    sh = sh.filter(ImageFilter.GaussianBlur(art * 0.022))
    shadow = Image.new("RGBA", (n, n), (90, 70, 55, 0))
    shadow.putalpha(sh.transform(sh.size, Image.AFFINE, (1, 0, 0, 0, 1, -art * 0.018)))
    img.alpha_composite(shadow)

    # 배경 — 세로 그라데이션을 둥근 사각형으로 잘라낸다
    grad = Image.new("RGBA", (1, n))
    for y in range(n):
        t = y / (n - 1)
        grad.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(bg_top, bg_bot)) + (255,))
    grad = grad.resize((n, n))
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=r, fill=255)
    img.paste(grad, (0, 0), mask)

    # 캐릭터 — 가로로 긴 형태라 폭 기준으로 맞추고 세로는 가운데
    cw = art * 0.70
    scale = cw / 24
    ch = 15 * scale                       # y 5~20
    cx = off + (art - cw) / 2
    cy = off + (art - ch) / 2

    def px(x0, y0, x1, y1):
        return (cx + x0 * scale, cy + (y0 - 5) * scale,
                cx + x1 * scale, cy + (y1 - 5) * scale)

    d = ImageDraw.Draw(img)
    for r_ in [BODY] + ARMS + LEGS:
        d.rectangle(px(*r_), fill=fg)
    for e in EYES:                        # 눈은 구멍이라 배경색으로 도려낸다
        x0, y0, x1, y1 = px(*e)
        band = round((y0 + y1) / 2)
        d.rectangle((x0, y0, x1, y1), fill=grad.getpixel((0, min(band, n - 1))))

    return img.resize((size, size), Image.LANCZOS)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    iconset = os.path.join(here, "icon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size, name in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                       (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                       (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]:
        render(size).save(os.path.join(iconset, f"icon_{name}.png"))
    out = os.path.join(here, "icon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    render(1024).save(os.path.join(here, "icon-preview.png"))
    print(f"완료: {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    sys.exit(main())
