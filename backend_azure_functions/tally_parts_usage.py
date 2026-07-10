# -*- coding: utf-8 -*-
"""
Task 3: 統一後エンジンで _WIGGLE_MOTIFS 生成を10回実行し、
使用パーツ種別の分布を集計する。全19種を在庫に入れ、
カタログのうち使われない種類を理由付きで確認する。
"""
import asyncio
import sys
from collections import Counter

sys.path.insert(0, ".")
from layout_generator.rail_db import RailType, RAIL_GEOMETRY_DB
from layout_generator.algorithm import search_layout, STRAIGHT_TYPES
from test_complex_layout import check_connectivity, check_no_overlap

# 全19種をたっぷり在庫に入れる
FULL_INV = {
    "curve_r": 32, "curve_r_large": 4,
    "straight": 10, "straight_half": 6, "straight_quarter": 6, "stop_rail": 4,
    "incline_start": 2, "incline_middle": 2, "incline_end": 2,
    "crossing": 1, "cross_point": 1,
    "switch_left": 2, "switch_right": 2, "switch_y": 1, "auto_turnout": 1,
    "bridge_pier_standard": 6, "bridge_pier_block": 3,
    "flexible": 2, "straight_double": 2,
}


async def main():
    print("直線プール（DB導出）:", [rt.value for rt in STRAIGHT_TYPES])
    print()
    print("=== standard テーマ（ウィグル生成）10回 ===")
    usage = Counter()
    all_valid = True
    for i in range(10):
        placed, closed, _ = await search_layout(dict(FULL_INV), "standard")
        c1, _m1 = check_connectivity(placed)
        c2, _m2 = check_no_overlap(placed)
        if not (closed and c1 and c2):
            all_valid = False
            print(f"  run{i+1}: NG closed={closed} conn={c1} overlap={c2}")
        for p in placed:
            usage[p["rail_type"]] += 1
    print(f"  10回すべて妥当な閉ループ: {'YES' if all_valid else 'NO'}")
    print()
    print("  種別ごとの使用回数（10回合計）:")
    for rt, cnt in usage.most_common():
        print(f"    {rt:22s} {cnt:4d} 本")

    # 参考: 他テーマでのみ使われる種類
    print()
    print("=== 参考: elevated / figure8 テーマ各3回 ===")
    extra = Counter()
    for _ in range(3):
        placed, _, _ = await search_layout(dict(FULL_INV), "elevated")
        for p in placed:
            extra[p["rail_type"]] += 1
    for _ in range(3):
        placed, _, _ = await search_layout(dict(FULL_INV), "figure8")
        for p in placed:
            extra[p["rail_type"]] += 1
    for rt, cnt in extra.most_common():
        print(f"    {rt:22s} {cnt:4d} 本")

    # 未使用種の判定
    print()
    print("=== 19種カタログの使用状況まとめ ===")
    used_any = set(usage) | set(extra)
    for rt in RailType:
        g = RAIL_GEOMETRY_DB[rt]
        if rt.value in used_any:
            status = "使用あり"
        elif g.excluded_from_auto:
            status = "未使用（excluded_from_auto=True: 設計上の除外）"
        elif len(g.joints) == 0:
            status = "未使用（橋脚: elevatedテーマのみ）"
        else:
            status = "未使用 ←要確認"
        print(f"    {rt.value:22s} {status}")


asyncio.run(main())
