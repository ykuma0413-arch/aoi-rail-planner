# -*- coding: utf-8 -*-
"""
多様性検証テスト

「ループが閉じて完成する」だけでなく、同じ在庫から何度生成しても
毎回同じ線路ではなく、複数の異なるパターンが生成されることを検証する。

形状の同一性は「旋回シグネチャ」で判定する:
  各ピースを進行順に 直線=S / 左カーブ=L / 右カーブ=R / 交差=X に分類した文字列。
  閉ループなので巡回（回転）+ 反転（逆走）に対して正規化し、
  絶対回転や開始位置・走行方向に依存しない純粋な「形」の指紋にする。
  → 指紋が異なる = 物理的に異なる形のコース。

実行: backend の .venv python で  python test_diversity.py
"""
import asyncio
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
from layout_generator.algorithm import search_layout
from test_complex_layout import check_connectivity, check_no_overlap

PIERS = {"bridge_pier_standard", "bridge_pier_block"}


def turn_signature(placed) -> str:
    """ピース列を旋回記号列にし、巡回+反転で正規化した形状指紋を返す。"""
    syms = []
    for p in placed:
        rt = p["rail_type"]
        if rt in PIERS:
            continue
        if rt in ("curve_r", "curve_r_large"):
            syms.append("R" if p.get("flipped") else "L")
        elif rt == "crossing":
            syms.append("X")
        else:
            syms.append("S")  # 直線系・坂など
    s = "".join(syms)
    if not s:
        return ""

    # 巡回正規化: 全回転の中で辞書順最小
    def canon_rotations(text):
        return min(text[i:] + text[:i] for i in range(len(text)))

    forward = canon_rotations(s)
    # 反転（逆走）: 順序反転 + L<->R 入替（逆走すると旋回方向が反転する）
    swap = {"L": "R", "R": "L", "S": "S", "X": "X"}
    rev = "".join(swap[ch] for ch in reversed(s))
    backward = canon_rotations(rev)
    return min(forward, backward)


async def diversity_case(name, inv, theme, runs=24, min_distinct=4):
    sigs = Counter()
    valid = 0
    for _ in range(runs):
        placed, closed, _ = await search_layout(dict(inv), theme)
        if not closed:
            continue
        ok1, _ = check_connectivity(placed)
        ok2, _ = check_no_overlap(placed)
        if not (ok1 and ok2):
            continue
        valid += 1
        sigs[turn_signature(placed)] += 1

    distinct = len(sigs)
    top = sigs.most_common(1)[0][1] if sigs else 0
    dominance = top / valid if valid else 1.0
    # 合格条件:
    #   全 runs が妥当な閉ループ
    #   distinct >= min_distinct（複数パターン）
    #   1パターンが全体の80%超を占めない（偏りすぎていない）
    ok = (valid == runs) and (distinct >= min_distinct) and (dominance <= 0.80)
    mark = "✓" if ok else "✗"
    print(f"  [{mark}] {name}")
    print(f"        valid={valid}/{runs}  distinct shapes={distinct}  "
          f"top-pattern share={dominance*100:.0f}%")
    # 代表的な形をいくつか表示
    for sig, cnt in sigs.most_common(4):
        preview = sig[:40] + ("…" if len(sig) > 40 else "")
        print(f"          {cnt:2d}x  {preview}")
    return ok


async def main():
    print("=" * 70)
    print("多様性検証: 同じ在庫から複数の異なる形が生成されるか")
    print("=" * 70)

    cases = [
        # 直線が多いほどウィグル配置の自由度が高く多様化しやすい
        ("おまかせ カーブ24+直線12", {"curve_r": 24, "straight": 12}, "standard", 24, 5),
        ("おまかせ カーブ32+直線10", {"curve_r": 32, "straight": 10}, "standard", 24, 5),
        ("おまかせ カーブ48+直線12", {"curve_r": 48, "straight": 12}, "standard", 24, 5),
        ("おまかせ カーブ16+直線8 (小)", {"curve_r": 16, "straight": 8}, "standard", 24, 3),
    ]
    all_ok = True
    for name, inv, theme, runs, mind in cases:
        ok = await diversity_case(name, inv, theme, runs, mind)
        if not ok:
            all_ok = False
        print()

    # 退化ケース: カーブ16のみ（直線0）は純オーバルしか作れない＝多様性が無くて当然。
    # この場合は「全部同じでも閉じていればOK」とし、誤検知しないことを確認。
    print("  [参考] カーブ16のみ（直線なし）= 純オーバル（多様性なしが正常）")
    sigs = Counter()
    for _ in range(10):
        placed, closed, _ = await search_layout({"curve_r": 16}, "standard")
        if closed:
            sigs[turn_signature(placed)] += 1
    print(f"        distinct shapes={len(sigs)} (1が正常: 円は1種類)")
    print()

    print("=" * 70)
    print("総合判定:", "🎉 多様性OK（毎回違う形が出る）" if all_ok
          else "❌ 多様性不足（同じ形ばかり）→ 生成ロジック要改善")
    print("=" * 70)
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    asyncio.run(main())
