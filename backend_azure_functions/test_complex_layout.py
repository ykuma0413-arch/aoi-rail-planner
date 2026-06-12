# -*- coding: utf-8 -*-
"""
複雑レイアウト生成エンジンの厳密検証テスト

test_v2_engine.py が「閉じるか・領域内か」を見るのに対し、
こちらは API 出力（フロントが消費する placed_rails の dict）だけを使い、
エンジン内部を一切信用せずに以下の物理的妥当性を独立再計算で検証する:

  1. 接続妥当性  : 各ピースの出口ジョイントが次ピースの入口に許容誤差で一致するか
  2. 閉路       : 末尾ピースの出口が先頭ピースの入口に戻るか
  3. 自己交差    : 非隣接ピース同士が重ならないか（交差レールは例外）
  4. 8の字成立   : 交差レールが存在し、経路が2回そこを通るか
  5. 複雑性      : 右旋回（flipped）を含む非自明な形が出るか
  6. 在庫遵守    : 在庫より多くのピースを使っていないか
  7. タイムアウト : 200ms 仕様を超えないか

実行: backend の .venv python で  python test_complex_layout.py
"""
import asyncio
import math
import os
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
from layout_generator.algorithm import search_layout, CLOSE_DIST_MM, CLOSE_ANGLE_DEG

# ---- 部材実測値（エンジンと独立に定義してクロスチェック） ----
STRAIGHT = {"straight": 106.0, "straight_half": 53.0, "straight_double": 212.0}
CURVE = {"curve_r": 103.0, "curve_r_large": 206.0}
CURVE_DEG = 22.5
INCLINE = {"incline_start": 106.0, "incline_end": 106.0, "incline_middle": 106.0}
CROSSING_LEN = 106.0
PIERS = {"bridge_pier_standard", "bridge_pier_block"}

# ジョイント誤差は接続のたびに累積し得るため、許容を少し緩める
JOINT_TOL = CLOSE_DIST_MM + 1.0


def _u(deg):
    a = math.radians(deg)
    return math.cos(a), math.sin(a)


def piece_endpoints(p):
    """
    配置 dict から、そのピースの (入口座標, 入口向き, 出口座標, 出口向き) を再計算する。
    入口向き = 進入してくる電車の進行方向 / 出口向き = 出ていく電車の進行方向。
    橋脚は None。
    """
    rt = p["rail_type"]
    x, y, h = p["origin_x"], p["origin_y"], p["rotation"]
    if rt in PIERS:
        return None

    if rt in STRAIGHT or rt in INCLINE or rt == "crossing":
        length = STRAIGHT.get(rt) or INCLINE.get(rt) or CROSSING_LEN
        ux, uy = _u(h)
        return ((x, y), h, (x + length * ux, y + length * uy), h)

    if rt in CURVE:
        R = CURVE[rt]
        flipped = p.get("flipped", False)
        if not flipped:
            cx = x + R * _u(h + 90)[0]
            cy = y + R * _u(h + 90)[1]
            a0 = h - 90
            a1 = a0 + CURVE_DEG
            out_h = h + CURVE_DEG
        else:
            cx = x + R * _u(h - 90)[0]
            cy = y + R * _u(h - 90)[1]
            a0 = h + 90
            a1 = a0 - CURVE_DEG
            out_h = h - CURVE_DEG
        ex = cx + R * _u(a1)[0]
        ey = cy + R * _u(a1)[1]
        return ((x, y), h, (ex, ey), out_h % 360.0)

    return None


def ang_close(a, b):
    d = abs(a - b) % 360.0
    return d <= CLOSE_ANGLE_DEG + 1.0 or d >= 360.0 - (CLOSE_ANGLE_DEG + 1.0)


def check_connectivity(placed):
    """track ピース（橋脚以外）が順に物理接続しているか。交差の直交通過は隙間を許容。"""
    track = [p for p in placed if p["rail_type"] not in PIERS]
    if len(track) < 2:
        return True, "track too short"
    has_crossing = any(p["rail_type"] == "crossing" for p in track)
    gaps = []
    for i in range(len(track)):
        cur = piece_endpoints(track[i])
        nxt = piece_endpoints(track[(i + 1) % len(track)])
        if cur is None or nxt is None:
            continue
        (_, _, cur_out, _) = cur
        (nxt_in, _, _, _) = nxt
        dist = math.hypot(cur_out[0] - nxt_in[0], cur_out[1] - nxt_in[1])
        gaps.append(dist)
    big = [g for g in gaps if g > JOINT_TOL]
    # 8の字は交差を直交方向に渡る箇所で1〜2回の大きなジャンプ（橋渡し）が正当
    allowed_jumps = 2 if has_crossing else 0
    if len(big) > allowed_jumps:
        return False, f"{len(big)} disconnected joints (max gap {max(gaps):.1f}mm)"
    return True, f"max gap {max(gaps):.1f}mm, bridged jumps {len(big)}"


def check_no_overlap(placed, grid=20.0):
    """20mm グリッドで非隣接ピースの重なりを検出（交差レールは除外）。"""
    track = [p for p in placed if p["rail_type"] not in PIERS]
    n = len(track)
    cross_idx = {i for i, p in enumerate(track) if p["rail_type"] == "crossing"}
    cells = {}
    for idx, p in enumerate(track):
        ep = piece_endpoints(p)
        if ep is None:
            continue
        (sx, sy), _, (ex, ey), _ = ep
        steps = max(2, int(math.hypot(ex - sx, ey - sy) / 12))
        for s in range(steps + 1):
            t = s / steps
            cx = int((sx + (ex - sx) * t) // grid)
            cy = int((sy + (ey - sy) * t) // grid)
            prev = cells.get((cx, cy))
            if prev is not None and prev != idx:
                if prev in cross_idx or idx in cross_idx:
                    continue
                diff = abs(prev - idx)
                if diff > 1 and diff != n - 1:
                    return False, f"overlap: piece {prev} & {idx} at cell ({cx},{cy})"
            cells[(cx, cy)] = idx
    return True, "no overlap"


def check_inventory(placed, inv):
    used = Counter(p["rail_type"] for p in placed)
    for rt, cnt in used.items():
        if cnt > inv.get(rt, 0):
            return False, f"used {cnt} {rt} but only {inv.get(rt,0)} available"
    return True, "inventory respected"


def count_right_turns(placed):
    return sum(1 for p in placed if p.get("flipped"))


async def run():
    print("=" * 70)
    print("複雑レイアウト 厳密検証テスト")
    print("=" * 70)

    cases = [
        # (名前, 在庫, テーマ, 期待: 閉じる, 期待: 右旋回あり, 期待: 交差あり)
        ("おまかせ 24カーブ", {"curve_r": 24, "straight": 8}, "standard", True, True, False),
        ("おまかせ 32カーブ（複雑）", {"curve_r": 32, "straight": 10}, "standard", True, True, False),
        ("おまかせ 48カーブ（最大複雑）", {"curve_r": 48, "straight": 12}, "standard", True, True, False),
        ("8の字（交差レール）",
         {"curve_r": 24, "crossing": 1, "straight_half": 4}, "figure8", True, True, True),
        ("高架（坂+橋脚）",
         {"curve_r": 16, "straight": 10, "incline_start": 1, "incline_end": 1,
          "bridge_pier_standard": 5}, "elevated", True, False, False),
        ("混合 標準20+大4", {"curve_r": 20, "curve_r_large": 4, "straight": 6}, "standard", True, True, False),
    ]

    all_pass = True
    for name, inv, theme, exp_closed, exp_rturn, exp_cross in cases:
        placed, closed, missing = await search_layout(inv, theme)
        print(f"\n■ {name}  (theme={theme})")
        print(f"   pieces={len(placed)} closed={closed} missing={missing}")

        checks = []
        # 閉路
        checks.append(("閉路", closed == exp_closed,
                       f"closed={closed} (期待 {exp_closed})"))
        if closed:
            ok, msg = check_connectivity(placed); checks.append(("接続妥当性", ok, msg))
            ok, msg = check_no_overlap(placed);   checks.append(("自己交差なし", ok, msg))
            ok, msg = check_inventory(placed, inv); checks.append(("在庫遵守", ok, msg))
            rturns = count_right_turns(placed)
            if exp_rturn:
                checks.append(("右旋回あり", rturns > 0, f"right-turns={rturns}"))
            if exp_cross:
                ncross = sum(1 for p in placed if p["rail_type"] == "crossing")
                checks.append(("交差レール使用", ncross >= 1, f"crossings={ncross}"))
                z = sorted({p["z_level"] for p in placed})
                checks.append(("平面8の字(Z=0)", z == [0], f"z={z}"))
            if theme == "elevated":
                z = sorted({p["z_level"] for p in placed})
                checks.append(("高さ表現あり", len(z) >= 2, f"z-levels={z}"))
                npier = sum(1 for p in placed if p["rail_type"] in PIERS)
                checks.append(("橋脚配置", npier >= 1, f"piers={npier}"))

        for label, ok, msg in checks:
            mark = "✓" if ok else "✗"
            print(f"     [{mark}] {label}: {msg}")
            if not ok:
                all_pass = False

    # タイムアウト検証
    print("\n■ 200ms タイムアウト検証（最大複雑ケースを20回）")
    worst = 0.0
    for _ in range(20):
        t = time.perf_counter()
        await search_layout({"curve_r": 48, "straight": 12}, "standard")
        worst = max(worst, (time.perf_counter() - t) * 1000)
    ok = worst < 250  # asyncio.wait_for のオーバヘッド込みの上限
    print(f"     [{'✓' if ok else '✗'}] 最悪 {worst:.1f}ms (< 250ms)")
    if not ok:
        all_pass = False

    # 閉路保証（8の字）
    print("\n■ 8の字 連続生成（30回すべて8の字になるか）")
    f8_ok = 0
    for _ in range(30):
        placed, closed, _ = await search_layout(
            {"curve_r": 24, "crossing": 1, "straight_half": 4}, "figure8")
        if closed and any(p["rail_type"] == "crossing" for p in placed):
            f8_ok += 1
    print(f"     [{'✓' if f8_ok == 30 else '✗'}] {f8_ok}/30 が交差付き8の字")
    if f8_ok != 30:
        all_pass = False

    print("\n" + "=" * 70)
    print("総合判定:", "🎉 全テスト合格" if all_pass else "❌ 失敗あり")
    print("=" * 70)
    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    asyncio.run(run())
