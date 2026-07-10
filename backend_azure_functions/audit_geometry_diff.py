# -*- coding: utf-8 -*-
"""
Task 1: _Walker.add の実効数値 vs rail_db.RAIL_GEOMETRY_DB の突き合わせ監査
（コード変更なし・読み取りのみ）

方法:
  各レール種別を「原点(0,0)・向き0°」に置いたときの
    A) rail_db 定義: joints[1] (出口ジョイント) の (x, y, 出口角)
    B) _Walker.add 実行: 1ピース追加後の (x, y, heading)
  を数値比較する。0.001mm/0.001° 超のズレ、および片側にしか存在しない
  ハンドリングを差分として報告する。
"""
import math
import sys

sys.path.insert(0, ".")
from layout_generator.rail_db import RailType, RAIL_GEOMETRY_DB
from layout_generator import algorithm as alg
from layout_generator.algorithm import _Walker


def db_exit(rt):
    """rail_db 定義から出口ポーズ (x, y, angle) を取得（2ジョイント以上のみ）"""
    g = RAIL_GEOMETRY_DB[rt]
    if len(g.joints) < 2:
        return None
    j = g.joints[1]
    return (j.x, j.y, j.angle % 360.0, len(g.joints), g.excluded_from_auto)


def walker_exit(rt):
    """_Walker.add 実行後のポーズ。emit されなければ 'no-op'"""
    w = _Walker()
    w.add(rt)
    if not w.placed:
        return None  # add() が何も処理しなかった
    return (w.x, w.y, w.h % 360.0)


print(f"{'rail_type':22s} {'DB出口(x,y,角)':>28s} {'Walker出口(x,y,角)':>28s}  判定")
print("-" * 110)

for rt in RailType:
    db = db_exit(rt)
    wk = walker_exit(rt)

    db_s = "ジョイント<2 (橋脚)" if db is None else f"({db[0]:7.2f},{db[1]:7.2f},{db[2]:6.1f}°)"
    wk_s = "no-op (未ハンドル)" if wk is None else f"({wk[0]:7.2f},{wk[1]:7.2f},{wk[2]:6.1f}°)"

    if db is None and wk is None:
        verdict = "一致（両側とも軌道ピース扱いなし）"
    elif db is not None and wk is None:
        excl = "excluded_from_auto=True" if db[4] else "excluded_from_auto=False ←注意"
        verdict = f"差分: DBに定義あるがWalker未対応 ({excl})"
    elif db is None and wk is not None:
        verdict = "差分: Walkerのみ対応"
    else:
        dx = abs(db[0] - wk[0])
        dy = abs(db[1] - wk[1])
        da = min(abs(db[2] - wk[2]), 360 - abs(db[2] - wk[2]))
        if dx < 1e-3 and dy < 1e-3 and da < 1e-3:
            verdict = "数値一致"
        else:
            verdict = f"数値差分: Δx={dx:.3f} Δy={dy:.3f} Δ角={da:.3f}°"
    print(f"{rt.value:22s} {db_s:>28s} {wk_s:>28s}  {verdict}")

print()
print("=== 追加照合: 交差レールの直交アーム（figure-8 の snap_to が使う座標） ===")
g = RAIL_GEOMETRY_DB[RailType.CROSSING]
arms = [(j.x, j.y, j.angle) for j in g.joints[2:]]
print(f"  DB 定義のアーム: {arms}")
print(f"  algorithm._try_build_figure8 ハードコード値: (53,53) 入射270° / (53,-53) 出射270°")
print()
print("=== 追加照合: エンジン定数 vs DB 派生値 ===")
print(f"  alg.STRAIGHT_LEN   = {[(k.value, v) for k, v in alg.STRAIGHT_LEN.items()]}")
print(f"  alg.CURVE_RADIUS   = {[(k.value, v) for k, v in alg.CURVE_RADIUS.items()]}")
print(f"  alg.CURVE_ANGLE    = {alg.CURVE_ANGLE}")
print(f"  alg.INCLINE_LEN    = {alg.INCLINE_LEN}")
print(f"  DB: 直線系長さ     = straight:106, half:53, quarter:26.5, stop:106 (joints[1].x)")
q = RAIL_GEOMETRY_DB[RailType.STRAIGHT_QUARTER].joints[1]
st = RAIL_GEOMETRY_DB[RailType.STOP_RAIL].joints[1]
print(f"      実測 quarter=({q.x},{q.y}) stop=({st.x},{st.y})")
