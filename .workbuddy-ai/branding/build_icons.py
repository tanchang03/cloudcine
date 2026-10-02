"""生成云影 CloudCine 各平台图标。

用法：
    /Users/tandy/.workbuddy-ai/binaries/python/envs/default/bin/python3 \
        /Users/tandy/workbuddy-ai/网盘媒体库播放器/.workbuddy-ai/branding/build_icons.py

源文件：由 ImageGen 生成的 1024x1024 PNG（背景渐变 + 白色云朵播放图）。
本脚本做三件事：
1. 用「圆角矩形 alpha mask」把源图破损的角裁掉，导出干净的源。
2. 把干净源缩放到 macOS AppIcon 全部 7 个尺寸 + Android 5 个密度。
3. 用多张 PNG 拼成 Windows ICO（含 256 / 128 / 64 / 48 / 32 / 16）。

不修改任何项目目录外的文件，也不清空到原图标文件（覆盖写）。
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path("/Users/tandy/workbuddy-ai/网盘媒体库播放器")
BRANDING = ROOT / ".workbuddy-ai" / "branding"

# ImageGen 输出（每张源都来自同一次调用：蒙版/像素不同）
SRC = BRANDING / "Mobile_app_icon_1024x1024__Per_2026-10-01T13-56-41.png"

# 干净的源：写回与源同目录，给后面所有缩放用。
CLEAN_SRC = BRANDING / "cloudcine_icon_1024.png"

# 平台输出目录
MACOS_APPICONSET = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
ANDROID_RES = ROOT / "android" / "app" / "src" / "main" / "res"
WINDOWS_RES = ROOT / "windows" / "runner" / "resources"

# ── macOS AppIcon.appiconset/Contents.json 期待的尺码 ──────────────────────
# 命名沿用 Flutter create 默认：app_icon_<width>.png
MACOS_SIZES = [
    ("16", 16),
    ("32", 32),
    ("64", 64),
    ("128", 128),
    ("256", 256),
    ("512", 512),
    ("1024", 1024),
]

# ── Android mipmap 密度 ────────────────────────────────────────────────────
ANDROID_DENSITY = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# ── Windows ICO（一张 ICO 里塞多分辨率） ──────────────────────────────────
WINDOWS_ICO_SIZES = [16, 32, 48, 64, 128, 256]


def make_clean_source(src_path: Path, dst_path: Path, size: int = 1024) -> Image.Image:
    """读源图，套一层圆角矩形 alpha 蒙版，把破损的角裁干净。

    角半径 = 边长的 22.5%（沿用 iOS / Android / macOS 的常用比例，
    与 iOS "Squircle" 与 macOS Big Sur+ 图标圆角接近）。
    """
    img = Image.open(src_path).convert("RGBA")
    if img.size != (size, size):
        img = img.resize((size, size), Image.LANCZOS)

    mask = Image.new("L", (size, size), 0)
    radius = int(size * 0.225)
    ImageDraw.Draw(mask).rounded_rectangle(
        ((0, 0), (size - 1, size - 1)), radius=radius, fill=255
    )

    clean = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    clean.paste(img, (0, 0), mask=mask)

    clean.save(dst_path, "PNG", optimize=True)
    return clean


def resize_contain(src: Image.Image, target: int) -> Image.Image:
    """等比缩放到目标尺寸（高分辨率降采样用 LANCZOS）。"""
    if src.size == (target, target):
        return src
    return src.resize((target, target), Image.LANCZOS)


def write_macos(clean: Image.Image) -> None:
    for name, size in MACOS_SIZES:
        out = resize_contain(clean, size)
        path = MACOS_APPICONSET / f"app_icon_{name}.png"
        out.save(path, "PNG", optimize=True)
        print(f"  macos {name:<4} → {path.relative_to(ROOT)}")


def write_android(clean: Image.Image) -> None:
    for dirname, size in ANDROID_DENSITY.items():
        target_dir = ANDROID_RES / dirname
        target_dir.mkdir(parents=True, exist_ok=True)
        out = resize_contain(clean, size)
        # Flutter 默认用 ic_launcher.png；保留这个命名以免改动 manifest 引用。
        path = target_dir / "ic_launcher.png"
        out.save(path, "PNG", optimize=True)
        print(f"  android {dirname:<16} ({size:>3}) → {path.relative_to(ROOT)}")


def write_windows(clean: Image.Image) -> None:
    """写 ICO：一张文件含 16/32/48/64/128/256 共六种分辨率。"""
    # ICO 不能直接塞 1024（Pillow 限制），256 已经是 Windows 桌面图标的最大公约数。
    WINDOWS_RES.mkdir(parents=True, exist_ok=True)
    ico_path = WINDOWS_RES / "app_icon.ico"
    # Pillow 的 append_rgba.save 走 ICO plugin
    base = resize_contain(clean, 256)
    base.save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in WINDOWS_ICO_SIZES],
    )
    print(f"  windows ico ({'x'.join(str(s) for s in WINDOWS_ICO_SIZES)}) → {ico_path.relative_to(ROOT)}")


def main() -> None:
    if not SRC.exists():
        raise SystemExit(f"源文件不存在: {SRC}")

    print("生成干净源（圆角方块裁切）…")
    clean = make_clean_source(SRC, CLEAN_SRC)
    print(f"  → {CLEAN_SRC.relative_to(ROOT)}")

    print("\n写 macOS AppIcon.appiconset/…")
    write_macos(clean)

    print("\n写 Android mipmap-*…")
    write_android(clean)

    print("\n写 Windows ICO…")
    write_windows(clean)

    print("\n完成。")


if __name__ == "__main__":
    main()