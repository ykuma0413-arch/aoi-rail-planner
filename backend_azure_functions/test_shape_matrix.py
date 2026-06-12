# -*- coding: utf-8 -*-
"""
形状マトリクス検証 + ランダム在庫スイープ

Part 1: 仕様表の4ケースが「期待された形」を生成できるか検証
    在庫                          テーマ    出る形              右旋回
    カーブ24+直線8                おまかせ  S字入りピーナッツ     4本
    カーブ48+直線12               おまかせ  二重波形（最大複雑）   16本
    カーブ24+交差1+ハーフ4        8の字     真の∞形             12本
    カーブ16+坂2+橋脚5            こうか    高架オーバル(Z=0,1)   0本

Part 2: ランダム在庫 200 件 × 全テーマのスイープ
    「カーブ系が構成可能なら必ず閉じる」を全件で検証し、
    接続妥当性・自己交差・領域内も同時にチェック。
    1件でも失敗 = エンジンに「できない形」が存在する。

実行: backend の .venv python で  python test_shape_matrix.py
"""
import asyncio
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from layout_generator.algorithm import search_layout
from test_complex_layout import (
    check_connectivity, check_no_overlap, check_inventory, count_right_turns,
    PIERS,
)


def arc_feasible(inv: dict) -> bool:
    """エンジンと同じ判定: 180°アーク×2 を構成できるか"""
    std = inv.get("curve_r", 0)
    large = inv.get("curve_r_large", 0)
    per_std = min(8, std // 2)
    per_large = 8 - per_std
    return large >= per_large * 2


def validate(placed, inv) -> tuple:
    """閉ループの物理的妥当性をまとめて検証"""
    ok, msg = check_connectivity(placed)
    if not ok:
        return False, f"接続: {msg}"
    ok, msg = check_no_overlap(placed)
    if not ok:
        return False, f"交差: {msg}"
    ok, msg = check_inventory(placed, inv)
    if not ok:
        return False, f"在庫: {msg}"
    xs = [p["origin_x"] for p in placed]
    ys = [p["origin_y"] for p in placed]
    if not (0 <= min(xs) and max(xs) <= 1800 and 0 <= min(ys) and max(ys) <= 1800):
        return False, "領域外"
    return True, "ok"


async def part1_table():
    print("=" * 70)
    print("Part 1: 仕様表の4ケース検証")
    print("=" * 70)

    # (名前, 在庫, テーマ, 期待右旋回数, 交差必須, Z=[0,1]必須)
    table = [
        ("カーブ24+直線8 → S字入りピーナッツ",
         {"curve_r": 24, "straight": 8}, "standard", 4, False, False),
        ("カーブ48+直線12 → 二重波形（最大複雑）",
         {"curve_r": 48, "straight": 12}, "standard", 16, False, False),
        ("カーブ24+交差1+ハーフ4 → 真の∞形",
         {"curve_r": 24, "crossing": 1, "straight_half": 4}, "figure8", 12, True, False),
        ("カーブ16+坂2+橋脚5 → 高架オーバル",
         {"curve_r": 16, "straight": 10, "incline_start": 1, "incline_end": 1,
          "bridge_pier_standard": 5}, "elevated", 0, False, True),
    ]

    all_ok = True
    for name, inv, theme, exp_rturns, need_cross, need_z in table:
        # 形はランダム性があるため10回生成し、
        #   (a) 全回が物理的に妥当な閉ループ
        #   (b) 少なくとも1回は期待右旋回数を達成
        # の両方を要求する
        achieved = 0
        physical_fail = None
        for _ in range(10):
            placed, closed, missing = await search_layout(dict(inv), theme)
            if not closed:
                physical_fail = f"閉じない (missing={missing})"
                break
            ok, msg = validate(placed, inv)
            if not ok:
                physical_fail = msg
                break
            rt_ok = count_right_turns(placed) == exp_rturns
            cross_ok = (not need_cross) or any(
                p["rail_type"] == "crossing" for p in placed)
            z = sorted({p["z_level"] for p in placed})
            z_ok = (not need_z) or z == [0, 1]
            if rt_ok and cross_ok and z_ok:
                achieved += 1

        ok = physical_fail is None and achieved >= 1
        mark = "✓" if ok else "✗"
        detail = physical_fail or f"期待形を {achieved}/10 回達成"
        print(f"  [{mark}] {name}")
        print(f"        {detail}")
        if not ok:
            all_ok = False
    return all_ok


async def part2_sweep(n_cases=200, seed=42):
    print()
    print("=" * 70)
    print(f"Part 2: ランダム在庫スイープ ({n_cases}件)")
    print("=" * 70)

    rng = random.Random(seed)
    themes = ["standard", "figure8", "elevated"]
    fails = []
    closed_count = 0
    open_count = 0

    for i in range(n_cases):
        inv = {
            "curve_r": rng.randint(0, 50),
            "curve_r_large": rng.randint(0, 6),
            "straight": rng.randint(0, 20),
            "straight_half": rng.randint(0, 10),
            "crossing": rng.randint(0, 1),
            "incline_start": rng.randint(0, 2),
            "incline_end": rng.randint(0, 2),
            "bridge_pier_standard": rng.randint(0, 6),
            "bridge_pier_block": rng.randint(0, 3),
            # 自動探索除外パーツ（混ぜても無害なことを確認）
            "flexible": rng.randint(0, 3),
            "straight_double": rng.randint(0, 2),
        }
        theme = rng.choice(themes)
        feasible = arc_feasible(inv)

        placed, closed, missing = await search_layout(dict(inv), theme)

        if feasible:
            if not closed:
                fails.append((i, inv, theme, f"構成可能なのに閉じない missing={missing}"))
                continue
            ok, msg = validate(placed, inv)
            if not ok:
                fails.append((i, inv, theme, msg))
                continue
            closed_count += 1
        else:
            if closed:
                fails.append((i, inv, theme, "構成不可能なのに閉じたと主張"))
                continue
            if not missing:
                fails.append((i, inv, theme, "不足パーツの提示がない"))
                continue
            open_count += 1

    print(f"  閉ループ成功: {closed_count} 件 / 正しい不足報告: {open_count} 件")
    if fails:
        print(f"  ❌ 失敗 {len(fails)} 件:")
        for i, inv, theme, msg in fails[:10]:
            inv_s = {k: v for k, v in inv.items() if v > 0}
            print(f"    case#{i} theme={theme} {msg}")
            print(f"      inv={inv_s}")
    else:
        print("  ✓ 全件合格（エンジンに『できない形』なし）")
    return len(fails) == 0


async def main():
    ok1 = await part1_table()
    ok2 = await part2_sweep()
    print()
    print("=" * 70)
    print("総合判定:", "🎉 全テスト合格" if (ok1 and ok2) else "❌ 失敗あり → エンジン修正が必要")
    print("=" * 70)
    sys.exit(0 if (ok1 and ok2) else 1)


if __name__ == "__main__":
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    asyncio.run(main())
