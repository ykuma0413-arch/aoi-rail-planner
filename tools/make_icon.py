# -*- coding: utf-8 -*-
"""
あおいレールプランナー - ランチャーアイコン生成
青いオーバルレール（道床+溝）の上を走る赤い汽車 + AIスパークル。
一目で「レールあそびのシミュレーション」と分かるデザイン。

実行: python tools/make_icon.py
出力: frontend_flutter/android/app/src/main/res/mipmap-*/ic_launcher.png
      app-icon-preview.png (確認用 512px)
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).parent.parent
RES = ROOT / "frontend_flutter" / "android" / "app" / "src" / "main" / "res"

# ---- パレット ----
BG_TOP = (227, 242, 253)      # 空色
BG_BOTTOM = (255, 248, 225)   # クリーム（おもちゃ感）
RAIL_BLUE = (0, 114, 188)     # 道床ブルー
RAIL_BLUE_DARK = (0, 75, 135)
GROOVE = (255, 255, 255)
TRAIN_RED = (229, 57, 53)
TRAIN_RED_DARK = (183, 28, 28)
WHEEL = (38, 50, 56)
WHEEL_HUB = (176, 190, 197)
WINDOW = (255, 255, 255)
SPARK = (255, 193, 7)
SMOKE = (207, 216, 220)


def draw_master(size: int = 1024) -> Image.Image:
    img = Image.new("RGBA", (size, size))
    d = ImageDraw.Draw(img)
    s = size / 1024.0  # スケール係数

    # ---- 背景: 縦グラデーション ----
    for y in range(size):
        t = y / size
        r = int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        d.line([(0, y), (size, y)], fill=(r, g, b, 255))

    # ---- オーバルレール（道床 + 2本の溝） ----
    cx, cy = 512 * s, 545 * s
    rx, ry = 370 * s, 270 * s
    band = 92 * s

    def ellipse_box(rx_, ry_):
        return [cx - rx_, cy - ry_, cx + rx_, cy + ry_]

    # 道床本体
    d.ellipse(ellipse_box(rx, ry), outline=RAIL_BLUE, width=int(band))
    # 道床の縁取り
    d.ellipse(ellipse_box(rx + band / 2, ry + band / 2),
              outline=RAIL_BLUE_DARK, width=int(6 * s))
    d.ellipse(ellipse_box(rx - band / 2, ry - band / 2),
              outline=RAIL_BLUE_DARK, width=int(6 * s))
    # 2本の溝（車輪ガイド）
    d.ellipse(ellipse_box(rx + band * 0.20, ry + band * 0.20),
              outline=GROOVE, width=int(10 * s))
    d.ellipse(ellipse_box(rx - band * 0.20, ry - band * 0.20),
              outline=GROOVE, width=int(10 * s))

    # ---- 赤い汽車（下アーク上に側面ビュー） ----
    train_cy = cy + ry          # 下アークの中心線
    body_w, body_h = 300 * s, 130 * s
    bx0 = cx - body_w / 2
    by1 = train_cy - 34 * s      # 車体下端（道床にめり込まない位置）
    by0 = by1 - body_h

    # 煙突 + 煙
    chim_x = bx0 + 52 * s
    d.rounded_rectangle([chim_x - 22 * s, by0 - 52 * s, chim_x + 22 * s, by0 + 8 * s],
                        radius=10 * s, fill=TRAIN_RED_DARK)
    for i, (dx, dy, r_) in enumerate([(0, -95, 26), (38, -150, 34), (90, -195, 42)]):
        d.ellipse([chim_x + dx * s - r_ * s, by0 + dy * s - r_ * s,
                   chim_x + dx * s + r_ * s, by0 + dy * s + r_ * s],
                  fill=SMOKE + (230 - i * 40,))

    # 車体
    d.rounded_rectangle([bx0, by0, bx0 + body_w, by1], radius=30 * s, fill=TRAIN_RED)
    # キャブ（運転室）
    cab_x0 = bx0 + body_w - 118 * s
    d.rounded_rectangle([cab_x0, by0 - 70 * s, bx0 + body_w, by0 + 40 * s],
                        radius=22 * s, fill=TRAIN_RED_DARK)
    # 窓
    d.rounded_rectangle([cab_x0 + 20 * s, by0 - 50 * s, bx0 + body_w - 20 * s, by0 + 6 * s],
                        radius=14 * s, fill=WINDOW)
    # 前照灯
    d.ellipse([bx0 - 12 * s, by1 - 64 * s, bx0 + 28 * s, by1 - 24 * s], fill=SPARK)

    # 車輪
    for wx in (bx0 + 70 * s, bx0 + body_w / 2, bx0 + body_w - 70 * s):
        r_ = 44 * s
        d.ellipse([wx - r_, train_cy - 18 * s - r_, wx + r_, train_cy - 18 * s + r_],
                  fill=WHEEL)
        hub = 16 * s
        d.ellipse([wx - hub, train_cy - 18 * s - hub, wx + hub, train_cy - 18 * s + hub],
                  fill=WHEEL_HUB)

    # ---- AI スパークル（右上） ----
    def star(cx_, cy_, r_outer, r_inner, fill):
        pts = []
        for i in range(8):
            ang = math.pi / 2 * (i / 2) - math.pi / 2
            r_ = r_outer if i % 2 == 0 else r_inner
            pts.append((cx_ + r_ * math.cos(ang), cy_ + r_ * math.sin(ang)))
        d.polygon(pts, fill=fill)

    star(810 * s, 168 * s, 86 * s, 30 * s, SPARK)
    star(906 * s, 282 * s, 44 * s, 16 * s, SPARK)

    return img


def main():
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    master = draw_master(1024)

    sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, px in sizes.items():
        out_dir = RES / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        icon = master.resize((px, px), Image.LANCZOS).convert("RGB")
        icon.save(out_dir / "ic_launcher.png")
        print(f"[OK] {folder}/ic_launcher.png ({px}px)")

    preview = master.resize((512, 512), Image.LANCZOS).convert("RGB")
    preview_path = ROOT / "app-icon-preview.png"
    preview.save(preview_path)
    print(f"[OK] preview: {preview_path}")


if __name__ == "__main__":
    main()
