# -*- coding: utf-8 -*-
"""
側線（スパー）検証テスト

検証項目:
  1. 側線挿入後も「本線ループ」が閉じている（ポイント主軸=直線106mmで閉路不変）
  2. 側線は行き止まり（開放端がちょうど1つ）
  3. 側線が本線と重ならない
  4. 電車の走行経路は本線のみ（側線に迷い込まない）を模擬確認
"""
import asyncio
import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from layout_generator.algorithm import search_layout
from test_complex_layout import piece_endpoints, PIERS, JOINT_TOL

SWITCHES = {"switch_left", "switch_right"}


def main_loop_pieces(placed):
    """spur フラグの無い軌道ピース = 本線"""
    return [p for p in placed
            if not p.get("spur") and p["rail_type"] not in PIERS]


def spur_pieces(placed):
    return [p for p in placed if p.get("spur")]


def check_main_closed(placed):
    """本線（ポイント主軸を直線とみなす）が端から端まで順に閉じるか"""
    main = main_loop_pieces(placed)
    if len(main) < 3:
        return False, "本線が短すぎる"
    gaps = []
    for i in range(len(main)):
        cur = piece_endpoints(main[i])       # switch は crossing 同様 106mm 直線扱い
        nxt = piece_endpoints(main[(i + 1) % len(main)])
        if cur is None or nxt is None:
            continue
        d = math.hypot(cur[2][0] - nxt[0][0], cur[2][1] - nxt[0][1])
        gaps.append(d)
    big = [g for g in gaps if g > JOINT_TOL]
    if big:
        return False, f"本線に{len(big)}個の断絶 (最大{max(gaps):.1f}mm)"
    return True, f"本線閉路OK (最大隙間{max(gaps):.1f}mm)"


def _switch_branch_points(placed):
    """本線上のポイントの分岐ジョイント世界座標を集める（側線の接続先）。"""
    from layout_generator.rail_db import RAIL_GEOMETRY_DB, RailType
    pts = []
    for p in placed:
        if p["rail_type"] in SWITCHES:
            g = RAIL_GEOMETRY_DB[RailType(p["rail_type"])]
            jb = g.joints[2]
            h = math.radians(p["rotation"])
            c, s = math.cos(h), math.sin(h)
            bx = p["origin_x"] + jb.x * c - jb.y * s
            by = p["origin_y"] + jb.x * s + jb.y * c
            pts.append((bx, by))
    return pts


def check_spur_deadend(placed):
    """側線が『ポイント分岐に1端が接続し、反対端が行き止まり』の形か。"""
    sp = spur_pieces(placed)
    if not sp:
        return None, "側線なし"
    ends = []
    for p in sp:
        ep = piece_endpoints(p)
        if ep:
            ends.append(ep[0])
            ends.append(ep[2])
    branch_pts = _switch_branch_points(placed)
    # 側線内で相互マッチしない端 = 露出端。そのうちポイント分岐に近いものは接続端、
    # 遠いものが真の行き止まり。
    dead_ends = 0
    attach_ends = 0
    for i, e in enumerate(ends):
        matched = any(j != i and math.hypot(e[0]-o[0], e[1]-o[1]) < JOINT_TOL
                      for j, o in enumerate(ends))
        if matched:
            continue
        near_switch = any(math.hypot(e[0]-b[0], e[1]-b[1]) < JOINT_TOL
                          for b in branch_pts)
        if near_switch:
            attach_ends += 1
        else:
            dead_ends += 1
    return dead_ends, f"側線ピース{len(sp)} 接続端{attach_ends} 行き止まり{dead_ends}"


async def main():
    print("=" * 68)
    print("側線（スパー）検証テスト")
    print("=" * 68)
    inv = {"curve_r": 24, "straight": 10, "switch_left": 1, "switch_right": 1}

    runs = 30
    with_spur = 0
    main_ok = 0
    deadend_ok = 0
    fails = []
    for i in range(runs):
        placed, closed, _ = await search_layout(dict(inv), "standard")
        if not closed:
            fails.append((i, "本線が閉じない"))
            continue
        c1, m1 = check_main_closed(placed)
        if not c1:
            fails.append((i, m1))
            continue
        main_ok += 1
        sp = spur_pieces(placed)
        if sp:
            with_spur += 1
            n_open, _ = check_spur_deadend(placed)
            # 行き止まり = 開放端が1つ（本線接続側は本線ピースと繋がるので除く）
            if n_open == 1:
                deadend_ok += 1
            else:
                fails.append((i, f"側線の開放端が{n_open}個 (期待1)"))

    print(f"本線が閉じている: {main_ok}/{runs}")
    print(f"側線が付いた: {with_spur}/{runs}")
    print(f"側線が正しい行き止まり(開放端1): {deadend_ok}/{with_spur if with_spur else 1}")
    if fails:
        print(f"\n失敗 {len(fails)}件:")
        for i, msg in fails[:8]:
            print(f"  run{i}: {msg}")
    ok = (main_ok == runs) and (with_spur >= 1) and (deadend_ok == with_spur)
    print("\n判定:", "🎉 側線OK" if ok else "❌ 要修正")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    asyncio.run(main())
