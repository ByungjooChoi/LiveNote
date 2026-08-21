#!/usr/bin/env python3
"""livenote2 앱 아이콘 생성 — 건곤감리 트라이그램, macOS Big Sur 스타일."""
from PIL import Image, ImageDraw, ImageFilter
import os

S = 1024
RECT = (100, 100, 924, 924)   # 824x824 (Apple macOS 아이콘 그리드)
RADIUS = 185

# 트라이그램 정의: True=통 막대, False=끊긴 막대 (위→아래)
GEON = [True, True, True]     # 건 ☰ 하늘
GON  = [False, False, False]  # 곤 ☷ 땅
GAM  = [False, True, False]   # 감 ☵ 물
RI   = [True, False, True]    # 리 ☲ 불

# 배치 (태극기 모서리 배열): 좌상=건, 우상=감, 좌하=리, 우하=곤
LAYOUT = {"TL": GEON, "TR": GAM, "BL": RI, "BR": GON}

# 콘텐츠 그리드
QUAD = 248       # 트라이그램 한 변
GUTTER = 80
BAR_H = 48
BAR_R = 24
BREAK_GAP = 44

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def vgradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    for y in range(size):
        img.putpixel((0, y), lerp(top, bottom, y / (size - 1)))
    return img.resize((size, size))

def rounded_mask(size, rect, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(rect, radius=radius, fill=255)
    return mask

def draw_trigram(draw, ox, oy, pattern, color):
    ys = [0, 100, 200]
    for bars, y in zip(pattern, ys):
        top = oy + y
        if bars:  # 통 막대
            draw.rounded_rectangle((ox, top, ox + QUAD, top + BAR_H), radius=BAR_R, fill=color)
        else:     # 끊긴 막대
            seg = (QUAD - BREAK_GAP) // 2
            draw.rounded_rectangle((ox, top, ox + seg, top + BAR_H), radius=BAR_R, fill=color)
            draw.rounded_rectangle((ox + QUAD - seg, top, ox + QUAD, top + BAR_H), radius=BAR_R, fill=color)

def make_icon(bg_top, bg_bottom, colors, gloss=True, shadow=True):
    """colors: {"TL":.., "TR":.., "BL":.., "BR":..} RGB"""
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 그림자 (Dock에서의 입체감 — Big Sur 아이콘은 아트워크에 포함)
    if shadow:
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle(
            (RECT[0], RECT[1] + 14, RECT[2], RECT[3] + 14), radius=RADIUS, fill=(0, 0, 0, 70))
        canvas = Image.alpha_composite(canvas, sh.filter(ImageFilter.GaussianBlur(22)))

    # 배경 그라데이션 (라운드 마스크)
    grad = vgradient(S, bg_top, bg_bottom).convert("RGBA")
    mask = rounded_mask(S, RECT, RADIUS)
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bg.paste(grad, (0, 0), mask)
    canvas = Image.alpha_composite(canvas, bg)

    # 트라이그램
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    grid = 2 * QUAD + GUTTER            # 576
    x0 = (S - grid) // 2                # 224
    y0 = (S - grid) // 2
    pos = {
        "TL": (x0, y0), "TR": (x0 + QUAD + GUTTER, y0),
        "BL": (x0, y0 + QUAD + GUTTER), "BR": (x0 + QUAD + GUTTER, y0 + QUAD + GUTTER),
    }
    for key, pattern in LAYOUT.items():
        draw_trigram(draw, *pos[key], pattern, colors[key])
    canvas = Image.alpha_composite(canvas, layer)

    # 상단 글로스 (은은한 빛)
    if gloss:
        gl = Image.new("L", (1, S), 0)
        for y in range(S):
            t = max(0.0, 1.0 - y / (S * 0.55))
            gl.putpixel((0, y), int(26 * t))
        gl = gl.resize((S, S))
        white = Image.new("RGBA", (S, S), (255, 255, 255, 255))
        gloss_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        gloss_layer.paste(white, (0, 0), Image.composite(gl, Image.new("L", (S, S), 0), mask))
        canvas = Image.alpha_composite(canvas, gloss_layer)

    return canvas

WHITE = (247, 248, 250)
INK = (28, 31, 38)

variants = {
    "A_graphite": make_icon((52, 58, 70), (17, 20, 27),
                            {k: WHITE for k in LAYOUT}),
    "B_indigo":   make_icon((76, 92, 168), (24, 30, 60),
                            {k: (255, 255, 255) for k in LAYOUT}),
    "C_taegeuk":  make_icon((251, 248, 242), (236, 230, 219),
                            {"TL": INK, "BR": INK, "TR": (39, 76, 156), "BL": (196, 57, 46)},
                            gloss=False),
}

out = "/sessions/exciting-optimistic-hopper/icons"
os.makedirs(out, exist_ok=True)
for name, img in variants.items():
    img.resize((512, 512), Image.LANCZOS).save(f"{out}/preview_{name}.png")
    img.save(f"{out}/master_{name}.png")
print("done:", os.listdir(out))
