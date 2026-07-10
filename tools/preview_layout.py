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

SCALE = 0.42  # mm -> px（アプリと同じ）
TILE = int(1800 * SCALE)

RAIL_BLUE = (0, 114, 188)
Z1 = (0, 75, 135)
PIER_STD = (255, 193, 7)    # 標準橋脚 = 黄色
PIER_BLOCK = (158, 158, 158)  # ブロック橋脚 = 灰色
WHITE = (255, 255, 255)

BAND = 9.5            # 道床幅 px（アプリと同じ）
BORDER = 2.6         # 白枠 片側 px


def _segments(p, ox, oy):
    """ピースを (種別, 始点, 終点, 中心, 半径, a0deg, a1deg) の描画断片に分解。
    直線系は ('line', (x1,y1,x2,y2)) / 曲線は ('arc', bbox, a0, a1) を返す。"""
    x = ox + p["origin_x"] * SCALE
    y = oy + p["origin_y"] * SCALE
    rot = math.radians(p["rotation"])
    rt = p["rail_type"]
    out = []
    end = None
    end_ang = None
    if rt in ("curve_r", "curve_r_large"):
        R = (103.0 if rt == "curve_r" else 206.0) * SCALE
        if not p.get("flipped", False):
            cx = x + R * math.cos(rot + math.pi / 2)
            cy = y + R * math.sin(rot + math.pi / 2)
            a0 = math.degrees(rot) - 90
            a1 = a0 + 22.5
            ea = math.radians(a1)
            end_ang = rot + math.radians(22.5)
        else:
            cx = x + R * math.cos(rot - math.pi / 2)
            cy = y + R * math.sin(rot - math.pi / 2)
            a1 = math.degrees(rot) + 90
            a0 = a1 - 22.5
            ea = math.radians(a0)
            end_ang = rot - math.radians(22.5)
        out.append(("arc", (cx, cy, R), a0, a1))
        end = (cx + R * math.cos(ea), cy + R * math.sin(ea))
    else:
        L = (53.0 if rt == "straight_half"
             else 26.5 if rt == "straight_quarter" else 106.0) * SCALE
        x2 = x + L * math.cos(rot)
        y2 = y + L * math.sin(rot)
        out.append(("line", (x, y, x2, y2)))
        if rt in ("crossing", "cross_point"):
            mx, my = (x + x2) / 2, (y + y2) / 2
            pxp, pyp = -math.sin(rot), math.cos(rot)
            arm = 53.0 * SCALE
            out.append(("line", (mx - pxp * arm, my - pyp * arm,
                                  mx + pxp * arm, my + pyp * arm)))
        if rt in ("switch_left", "switch_right", "auto_turnout"):
            # 分岐カーブ 22.5°
            R = 103.0 * SCALE
            right = (rt == "switch_right")
            if right:
                cx = x + R * math.cos(rot - math.pi / 2)
                cy = y + R * math.sin(rot - math.pi / 2)
                a1 = math.degrees(rot) + 90
                a0 = a1 - 22.5
            else:
                cx = x + R * math.cos(rot + math.pi / 2)
                cy = y + R * math.sin(rot + math.pi / 2)
                a0 = math.degrees(rot) - 90
                a1 = a0 + 22.5
            out.append(("arc", (cx, cy, R), a0, a1))
        end = (x2, y2)
        end_ang = rot
    return out, end, end_ang


def _stroke(d, seg, width, color):
    kind = seg[0]
    if kind == "line":
        d.line(seg[1], fill=color, width=int(round(width)))
    else:
        (cx, cy, R) = seg[1]
        a0, a1 = seg[2], seg[3]
        d.arc([cx - R, cy - R, cx + R, cy + R], a0, a1,
              fill=color, width=int(round(width)))


def draw_layout(d: ImageDraw.ImageDraw, placed, ox, oy):
    """アプリと同じ3パス: 白枠 → 青道床 → 白シーム"""
    pieces = []
    for p in placed:
        if "pier" in p["rail_type"]:
            x = ox + p["origin_x"] * SCALE
            y = oy + p["origin_y"] * SCALE
            pc = PIER_BLOCK if "block" in p["rail_type"] else PIER_STD
            d.rectangle([x - 6, y - 6, x + 6, y + 6], fill=pc)
            continue
        segs, end, end_ang = _segments(p, ox, oy)
        # 側線は少し明るい青で区別
        if p.get("spur"):
            color = (66, 165, 245)
        else:
            color = RAIL_BLUE if p["z_level"] == 0 else Z1
        pieces.append((segs, end, end_ang, color))

    # Pass1: 白枠
    for segs, _, _, _ in pieces:
        for s in segs:
            _stroke(d, s, BAND + BORDER * 2, WHITE)
    # Pass2: 青道床
    for segs, _, _, color in pieces:
        for s in segs:
            _stroke(d, s, BAND, color)
    # Pass3: 白シーム（道床内のティック。白枠は割らない）
    for _, end, end_ang, _ in pieces:
        if end is None:
            continue
        ex, ey = end
        pxp, pyp = -math.sin(end_ang), math.cos(end_ang)
        half = BAND / 2
        d.line([ex - pxp * half, ey - pyp * half,
                ex + pxp * half, ey + pyp * half], fill=WHITE, width=2)


async def main():
    cases = [
        ("FIGURE-8 24c+1x+4h",
         {"curve_r": 24, "crossing": 1, "straight_half": 4}, "figure8"),
        ("SPUR 側線 24c+10s+switchL",
         {"curve_r": 24, "straight": 10, "switch_left": 1}, "standard"),
        ("standard 32c+10s", {"curve_r": 32, "straight": 10}, "standard"),
        ("SPUR 側線 24c+10s+switchR",
         {"curve_r": 24, "straight": 10, "switch_right": 1}, "standard"),
        ("elevated full", {"curve_r": 16, "straight": 10,
                           "incline_start": 1, "incline_end": 1,
                           "bridge_pier_standard": 5}, "elevated"),
        ("plain 16c", {"curve_r": 16}, "standard"),
    ]

    cols, rows = 3, 2
    img = Image.new("RGB", (TILE * cols, TILE * rows), (234, 240, 246))
    d = ImageDraw.Draw(img)

    for i, (name, inv, theme) in enumerate(cases):
        placed, closed, missing = await search_layout(inv, theme)
        # SPUR ケースは側線が出るまで最大20回リトライ（視覚確認用）
        if "SPUR" in name:
            for _ in range(20):
                if any(p.get("spur") for p in placed):
                    break
                placed, closed, missing = await search_layout(inv, theme)
        ox = (i % cols) * TILE
        oy = (i // cols) * TILE
        d.rectangle([ox, oy, ox + TILE - 1, oy + TILE - 1], outline=(200, 200, 200))
        draw_layout(d, placed, ox, oy)
        rails = len([p for p in placed if "pier" not in p["rail_type"]])
        spur = len([p for p in placed if p.get("spur")])
        label = f"{name} closed={closed} rails={rails} spur={spur}"
        d.text((ox + 8, oy + 6), label, fill=(60, 60, 60))
        print(f"[{'OK' if closed else 'NG'}] {label}")

    out = Path(__file__).parent.parent / "layout-preview.png"
    img.save(out)
    print(f"\npreview: {out}")


asyncio.run(main())
