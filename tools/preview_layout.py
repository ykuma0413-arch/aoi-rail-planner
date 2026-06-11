# -*- coding: utf-8 -*-
"""
レイアウトエンジンの出力を Pillow で可視化する検証ツール。
実行: backend venv の python で tools/preview_layout.py
出力: layout-preview.png (2x3 グリッドで6サンプル)
"""
import asyncio
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "backend_azure_functions"))
from PIL import Image, ImageDraw
from layout_generator.algorithm import search_layout

SCALE = 0.30  # mm -> px
TILE = int(1800 * SCALE)  # 540

RAIL_BLUE = (0, 114, 188)
RAIL_DARK = (0, 75, 135)
Z1 = (0, 75, 135)
PIER = (141, 154, 165)


def draw_layout(d: ImageDraw.ImageDraw, placed, ox, oy):
    """道床は連続バンド、継ぎ目はピース終端のペグ円1個（アプリの新描画仕様を模擬）"""
    ends = []  # (x, y, color)
    for p in placed:
        x = ox + p["origin_x"] * SCALE
        y = oy + p["origin_y"] * SCALE
        rot = math.radians(p["rotation"])
        rt = p["rail_type"]
        color = RAIL_BLUE if p["z_level"] == 0 else Z1
        flipped = p.get("flipped", False)

        if "pier" in rt:
            d.rectangle([x - 4, y - 4, x + 4, y + 4], fill=PIER)
            continue

        if rt in ("curve_r", "curve_r_large"):
            R = (103.0 if rt == "curve_r" else 206.0) * SCALE
            if not flipped:
                cx = x + R * math.cos(rot + math.pi / 2)
                cy = y + R * math.sin(rot + math.pi / 2)
                a0 = math.degrees(rot) - 90
                a1 = a0 + 22.5
                end_a = math.radians(a1)
            else:
                cx = x + R * math.cos(rot - math.pi / 2)
                cy = y + R * math.sin(rot - math.pi / 2)
                a1 = math.degrees(rot) + 90
                a0 = a1 - 22.5
                end_a = math.radians(a0)
            bbox = [cx - R, cy - R, cx + R, cy + R]
            d.arc(bbox, a0, a1, fill=color, width=8)
            ends.append((cx + R * math.cos(end_a), cy + R * math.sin(end_a), color))
        else:
            L = (53.0 if rt == "straight_half" else 106.0) * SCALE
            x2 = x + L * math.cos(rot)
            y2 = y + L * math.sin(rot)
            d.line([x, y, x2, y2], fill=color, width=8)
            ends.append((x2, y2, color))

    # 継ぎ目ペグ（2パス目）
    for ex, ey, color in ends:
        dark = tuple(int(c * 0.6) for c in color)
        d.ellipse([ex - 2.4, ey - 2.4, ex + 2.4, ey + 2.4], fill=dark)
        d.ellipse([ex - 1.1, ey - 1.1, ex + 1.1, ey + 1.1], fill=(255, 255, 255))


async def main():
    cases = [
        ("standard 24c+8s", {"curve_r": 24, "straight": 8}, "standard"),
        ("standard 24c+8s #2", {"curve_r": 24, "straight": 8}, "standard"),
        ("standard 32c+10s", {"curve_r": 32, "straight": 10}, "standard"),
        ("compact 20c+4h", {"curve_r": 20, "straight_half": 4}, "figure8"),
        ("elevated full", {"curve_r": 16, "straight": 10,
                           "incline_start": 1, "incline_end": 1,
                           "bridge_pier_standard": 5}, "elevated"),
        ("plain 16c", {"curve_r": 16}, "standard"),
    ]

    cols, rows = 3, 2
    img = Image.new("RGB", (TILE * cols, TILE * rows), (250, 250, 250))
    d = ImageDraw.Draw(img)

    for i, (name, inv, theme) in enumerate(cases):
        placed, closed, missing = await search_layout(inv, theme)
        ox = (i % cols) * TILE
        oy = (i // cols) * TILE
        d.rectangle([ox, oy, ox + TILE - 1, oy + TILE - 1], outline=(200, 200, 200))
        draw_layout(d, placed, ox, oy)
        rails = len([p for p in placed if "pier" not in p["rail_type"]])
        flips = len([p for p in placed if p.get("flipped")])
        label = f"{name} closed={closed} rails={rails} R-turns={flips}"
        d.text((ox + 8, oy + 6), label, fill=(60, 60, 60))
        print(f"[{'OK' if closed else 'NG'}] {label}")

    out = Path(__file__).parent.parent / "layout-preview.png"
    img.save(out)
    print(f"\npreview: {out}")


asyncio.run(main())
