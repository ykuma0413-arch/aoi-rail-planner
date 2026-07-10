# -*- coding: utf-8 -*-
"""
ステップ4 自己評価: 枕木描画のレンダリング検証（直線・曲線）

rail_geometry.dart の poseAtArcLength / computeTiePoses と同一の数式を
Python に移植し、(1) 拡大レンダリング画像 (2) 間隔の数値検証 を出力する。
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

TIE_SPACING_MM = 18.0
SCALE = 3.0  # 拡大表示 (px/mm)

RAIL_BLUE = (0, 114, 188)
GROOVE = tuple(int(c * 0.72) for c in RAIL_BLUE)
WHITE = (255, 255, 255)
BG = (234, 240, 246)

BAND_MM = 9.5 / 0.42   # キャンバス描画幅をmm換算 (≈22.6mm)


def pose_at(length_mm, turn_rad, s, origin=(0.0, 0.0), heading0=0.0):
    """rail_geometry.dart poseAtArcLength の移植（単一式・直線は曲率0の極限）"""
    k = 0.0 if abs(length_mm) < 1e-12 else turn_rad / length_mm
    th = k * s
    if abs(k) < 1e-9:
        lx, ly = s, 0.0
    else:
        r = 1.0 / k
        lx = r * math.sin(th)
        ly = r * (1.0 - math.cos(th))
    c, sn = math.cos(heading0), math.sin(heading0)
    return (origin[0] + lx * c - ly * sn,
            origin[1] + lx * sn + ly * c,
            heading0 + th)


def tie_poses(length_mm, turn_deg, spacing_mm, origin=(0, 0), heading0=0.0):
    n = int(length_mm // spacing_mm)
    if n < 1:
        return []
    turn_rad = math.radians(turn_deg)
    start = (length_mm - spacing_mm * (n - 1)) / 2.0
    return [pose_at(length_mm, turn_rad, start + i * spacing_mm,
                    origin, heading0) for i in range(n)]


def centerline(length_mm, turn_deg, origin, heading0, steps=64):
    turn_rad = math.radians(turn_deg)
    return [pose_at(length_mm, turn_rad, length_mm * i / steps,
                    origin, heading0) for i in range(steps + 1)]


def draw_piece(d, length_mm, turn_deg, origin, heading0, off):
    pts = [(off[0] + x * SCALE, off[1] + y * SCALE)
           for x, y, _ in centerline(length_mm, turn_deg, origin, heading0)]
    # 白枠 → 道床 → 枕木 → 溝
    d.line(pts, fill=WHITE, width=int((BAND_MM + 5) * SCALE * 0.42))
    d.line(pts, fill=RAIL_BLUE, width=int(BAND_MM * SCALE * 0.42))
    half = BAND_MM * 0.34 * SCALE * 0.42 / 0.42  # tie半長(mm)*SCALE
    half = BAND_MM * 0.34 * SCALE
    ties = tie_poses(length_mm, turn_deg, TIE_SPACING_MM, origin, heading0)
    for x, y, h in ties:
        px, py = off[0] + x * SCALE, off[1] + y * SCALE
        pxp, pyp = -math.sin(h), math.cos(h)
        d.line([px - pxp * half * 0.42, py - pyp * half * 0.42,
                px + pxp * half * 0.42, py + pyp * half * 0.42],
               fill=GROOVE, width=max(2, int(BAND_MM * 0.15 * SCALE * 0.42)))
    # 溝2本（中心線を法線方向にオフセット）
    for side in (+1, -1):
        gpts = []
        for x, y, h in centerline(length_mm, turn_deg, origin, heading0):
            gx = x + side * BAND_MM * 0.24 * (-math.sin(h))
            gy = y + side * BAND_MM * 0.24 * math.cos(h)
            gpts.append((off[0] + gx * SCALE, off[1] + gy * SCALE))
        d.line(gpts, fill=GROOVE, width=max(1, int(BAND_MM * 0.12 * SCALE * 0.42)))
    return ties


def main():
    img = Image.new("RGB", (900, 420), BG)
    d = ImageDraw.Draw(img)

    d.text((20, 10), "STRAIGHT 106mm  (tie spacing 18mm)", fill=(60, 60, 60))
    ties_s = draw_piece(d, 106.0, 0.0, (0, 0), 0.0, (60, 80))

    d.text((20, 150), "CURVE 45deg R103 (arc 80.9mm)", fill=(60, 60, 60))
    ties_c = draw_piece(d, 103.0 * math.radians(45), 45.0, (0, 0), 0.0, (60, 220))

    out = Path(__file__).parent.parent / "tie-preview.png"
    img.save(out)

    # ---- 数値検証: 連続する枕木の中心間距離 ----
    def gaps(ties):
        return [math.hypot(ties[i][0] - ties[i-1][0], ties[i][1] - ties[i-1][1])
                for i in range(1, len(ties))]

    gs, gc = gaps(ties_s), gaps(ties_c)
    print(f"直線: 枕木{len(ties_s)}本  間隔 = {[f'{g:.2f}' for g in gs]} mm")
    print(f"曲線: 枕木{len(ties_c)}本  間隔 = {[f'{g:.2f}' for g in gc]} mm")
    ok_s = all(abs(g - TIE_SPACING_MM) <= 1.5 for g in gs)
    ok_c = all(abs(g - TIE_SPACING_MM) <= 1.5 for g in gc)
    dens = len(ties_c) / len(ties_s)
    print(f"等間隔判定(±1.5mm): 直線 {'OK' if ok_s else 'NG'} / 曲線 {'OK' if ok_c else 'NG'}")
    print(f"密度比(曲線/直線) = {dens:.2f} (0.7〜1.3 期待)")
    print(f"preview: {out}")


if __name__ == "__main__":
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    main()
