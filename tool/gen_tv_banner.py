#!/usr/bin/env python3
"""生成 Android TV 首页 banner（320×180 xhdpi）。

为什么需要它：Google 规定 TV 应用的 banner 必须是 320×180，**图上必须带应用名文字**
（TV 首页只显示这张图，不另外叠加标题）。缺了这张图，`AndroidManifest.xml` 里的
`android:banner="@drawable/banner"` 会指向一个不存在的资源 → 构建直接失败。

配色从 `lib/ui/theme/app_theme.dart` 抄过来（bg / accent / accent2 / text / muted）。
**改了品牌色记得同步这里再重跑**：

    /Users/tandy/.workbuddy-ai-5/binaries/python/envs/default/bin/python tool/gen_tv_banner.py

输出：`android/app/src/main/res/drawable-xhdpi/banner.png`
"""
from __future__ import annotations

import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# ---- 与 app_theme.dart 对齐的色板 ----
BG = (0x0B, 0x0D, 0x12)
ACCENT = (0x5B, 0x8C, 0xFF)
ACCENT2 = (0xA4, 0x5C, 0xFF)
TEXT = (0xE9, 0xED, 0xF6)
MUTED = (0x8B, 0x95, 0xAC)

W, H = 320, 180
SCALE = 4  # 先按 4 倍画再缩回去，等于免费拿到抗锯齿

# macOS 上一定有、且覆盖简繁日汉字的字体。PingFang 在部分系统版本上不在
# /System/Library/Fonts 顶层，所以不依赖它。
CJK_FONT_CANDIDATES = [
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
]


def pick_font() -> str:
    for path in CJK_FONT_CANDIDATES:
        if os.path.exists(path):
            return path
    raise SystemExit("找不到中文字体，无法生成 banner（不会用方框糊过去）")


def font(path: str, size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=1)  # W6 / Medium 优先
    except Exception:
        return ImageFont.truetype(path, size, index=0)


def glow(w: int, h: int) -> Image.Image:
    """左上蓝、右上紫的两团径向光晕 —— 复刻 DesignBackground 的观感。"""
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([-w * 0.25, -h * 0.85, w * 0.75, h * 0.55], fill=ACCENT + (58,))
    d.ellipse([w * 0.45, -h * 0.85, w * 1.35, h * 0.45], fill=ACCENT2 + (44,))
    return layer.filter(ImageFilter.GaussianBlur(w * 0.09))


def gradient_round_rect(w: int, h: int, radius: int) -> Image.Image:
    """品牌渐变 + 圆角遮罩。PIL 没有渐变填充，只能自己逐像素刷。"""
    grad = Image.new("RGB", (w, h))
    px = grad.load()
    for y in range(h):
        for x in range(w):
            t = (x / max(w - 1, 1) + y / max(h - 1, 1)) / 2
            px[x, y] = tuple(
                round(c1 + (c2 - c1) * t) for c1, c2 in zip(ACCENT, ACCENT2)
            )
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, w - 1, h - 1], radius=radius, fill=255
    )
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def build() -> Image.Image:
    s = SCALE
    w, h = W * s, H * s
    canvas = Image.new("RGBA", (w, h), BG + (255,))
    canvas.alpha_composite(glow(w, h))
    d = ImageDraw.Draw(canvas)

    # ---- 图标：圆角方块 + 播放三角 ----
    icon = int(56 * s)
    tile = gradient_round_rect(icon, icon, int(15 * s))

    # ---- 文案 ----
    f_title = font(pick_font(), int(30 * s))
    f_sub = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(13 * s))
    title, sub = "云影", "CloudCine"

    tw = d.textlength(title, font=f_title)
    sw = d.textlength(sub, font=f_sub)

    gap = int(15 * s)
    text_w = max(tw, sw)
    total = icon + gap + text_w
    x0 = (w - total) / 2

    # 图标垂直居中
    canvas.alpha_composite(tile, (int(x0), int((h - icon) / 2)))
    # 播放三角
    cx, cy = x0 + icon / 2, h / 2
    r = icon * 0.19
    d.polygon(
        [(cx - r * 0.78, cy - r), (cx - r * 0.78, cy + r), (cx + r * 1.05, cy)],
        fill=(255, 255, 255, 255),
    )

    tx = x0 + icon + gap
    d.text((tx, h * 0.5 - int(9 * s)), title, font=f_title, fill=TEXT, anchor="lm")
    d.text(
        (tx + int(1.5 * s), h * 0.5 + int(21 * s)),
        sub,
        font=f_sub,
        fill=MUTED,
        anchor="lm",
    )

    return canvas.convert("RGB").resize((W, H), Image.LANCZOS)


def main() -> None:
    out = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "android/app/src/main/res/drawable-xhdpi/banner.png",
    )
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img = build()
    img.save(out, "PNG", optimize=True)
    print(f"{out}  {img.width}x{img.height}  {os.path.getsize(out)} bytes")


if __name__ == "__main__":
    main()
