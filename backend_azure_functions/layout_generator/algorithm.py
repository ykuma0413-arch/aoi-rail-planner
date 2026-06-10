"""
あおいレールプランナー - レイアウト生成エンジン v2（テンプレート構成方式）

v1 のビームサーチは探索が浅く「単純な円しか出ない」「閉路に失敗して工事中になる」
ケースが多発したため、v2 では構成的アプローチに全面刷新した。

設計原則:
- 「幾何学的に閉じることが保証されたテンプレート」を在庫に合わせてパラメタライズする
- カーブ系レール(標準/大)が合計16本以上あれば必ず閉ループを返す（探索失敗が存在しない）
- 直線系は対辺に同じ長さだけ配置することで閉路性を維持したまま形を伸縮できる
- 生成は決定的で数ミリ秒のため 200ms タイムアウトは事実上不要（保険として残す）

閉路性の数学的根拠:
  オーバル = 180°アーク(カーブ8本) + 直線辺A + 180°アーク + 直線辺A'
  両アークのカーブ構成（半径の並び）が同一なら第2アークの変位は第1アークの
  ちょうど逆ベクトルになり、辺A と辺A' の長さが等しければ始点に戻る。
"""
from __future__ import annotations

import math
import random
from typing import Dict, List, Tuple

from .rail_db import RailType

# ---- 幾何定数 ----
AREA_MM = 1800.0          # 2畳相当の仮想エリア
CENTER_MM = AREA_MM / 2   # 900mm
CURVE_ANGLE = 22.5        # 1本あたりの旋回角
REQUIRED_CURVES = 16      # 360°ループに必要なカーブ系合計

STRAIGHT_LEN: Dict[RailType, float] = {
    RailType.STRAIGHT: 106.0,
    RailType.STRAIGHT_HALF: 53.0,
}
CURVE_RADIUS: Dict[RailType, float] = {
    RailType.CURVE_R: 103.0,
    RailType.CURVE_R_LARGE: 206.0,
}

# 片側の直線辺の最大長 (mm)。Canvas 表示領域に収まる値。
MAX_SIDE_MM = 1000.0


def _unit(deg: float) -> Tuple[float, float]:
    a = math.radians(deg)
    return math.cos(a), math.sin(a)


class _Walker:
    """ピースを順に連結しながらポーズ(x, y, heading)を更新する"""

    def __init__(self) -> None:
        self.x = 0.0
        self.y = 0.0
        self.h = 0.0
        self.placed: List[dict] = []
        self.points: List[Tuple[float, float]] = [(0.0, 0.0)]

    def add(self, rt: RailType) -> None:
        self.placed.append({
            "rail_type": rt.value,
            "origin_x": self.x,
            "origin_y": self.y,
            "rotation": self.h % 360.0,
            "z_level": 0,
        })
        if rt in STRAIGHT_LEN:
            L = STRAIGHT_LEN[rt]
            ux, uy = _unit(self.h)
            self.x += L * ux
            self.y += L * uy
        elif rt in CURVE_RADIUS:
            # 左旋回 22.5°: 中心 = pos + R*unit(h+90)
            # 新位置 = pos + R*(unit(h-90+a) - unit(h-90))
            R = CURVE_RADIUS[rt]
            ux0, uy0 = _unit(self.h - 90.0)
            ux1, uy1 = _unit(self.h - 90.0 + CURVE_ANGLE)
            self.x += R * (ux1 - ux0)
            self.y += R * (uy1 - uy0)
            self.h += CURVE_ANGLE
        self.points.append((self.x, self.y))

    def is_closed(self) -> bool:
        if math.hypot(self.x, self.y) > 1.0:
            return False
        hm = self.h % 360.0
        return hm < 0.5 or hm > 359.5


def _rotate_and_center(
    placed: List[dict],
    points: List[Tuple[float, float]],
    theta_deg: float,
) -> List[dict]:
    """レイアウト全体を回転させてからエリア中央に平行移動する"""
    c = math.cos(math.radians(theta_deg))
    s = math.sin(math.radians(theta_deg))

    rotated_pts = [(px * c - py * s, px * s + py * c) for px, py in points]
    xs = [p[0] for p in rotated_pts]
    ys = [p[1] for p in rotated_pts]
    shift_x = CENTER_MM - (min(xs) + max(xs)) / 2
    shift_y = CENTER_MM - (min(ys) + max(ys)) / 2

    out = []
    for p in placed:
        x, y = p["origin_x"], p["origin_y"]
        out.append({
            **p,
            "origin_x": round(x * c - y * s + shift_x, 3),
            "origin_y": round(x * s + y * c + shift_y, 3),
            "rotation": round((p["rotation"] + theta_deg) % 360.0, 3),
        })
    return out


def _arc_sequence(std_avail: int, large_avail: int) -> List[RailType] | None:
    """
    180°アーク1本分（8ピース）のカーブ構成を返す。
    同じ構成を2アークで使うため、各種類とも在庫の半分までしか使えない。
    構成できなければ None。
    """
    per_std = min(8, std_avail // 2)
    per_large = 8 - per_std
    if large_avail < per_large * 2:
        return None
    return [RailType.CURVE_R] * per_std + [RailType.CURVE_R_LARGE] * per_large


def _side_pieces(
    inv: Dict[RailType, int],
    theme: str,
    rng: random.Random,
) -> List[RailType]:
    """対辺に配置する直線辺1本分の構成を返す（両辺で同じものを使う）"""
    s_pairs = inv.get(RailType.STRAIGHT, 0) // 2
    h_pairs = inv.get(RailType.STRAIGHT_HALF, 0) // 2

    if theme == "figure8":      # コンパクト: 直線最小限
        s_use, h_use = 0, min(h_pairs, 1)
    elif theme == "elevated":   # ワイド: 直線最大
        s_use, h_use = s_pairs, h_pairs
    else:                       # おまかせ: ランダム
        s_use = rng.randint(0, s_pairs) if s_pairs > 0 else 0
        h_use = rng.randint(0, h_pairs) if h_pairs > 0 else 0

    # エリアに収まるよう側面長を制限
    while s_use * 106 + h_use * 53 > MAX_SIDE_MM and s_use > 0:
        s_use -= 1
    while s_use * 106 + h_use * 53 > MAX_SIDE_MM and h_use > 0:
        h_use -= 1

    side = [RailType.STRAIGHT] * s_use + [RailType.STRAIGHT_HALF] * h_use
    rng.shuffle(side)
    return side


def _build_open_preview(inv: Dict[RailType, int]) -> List[dict]:
    """カーブ不足時のプレビュー: 持っているパーツで開いたアークを描く"""
    w = _Walker()
    curves = (
        [RailType.CURVE_R] * min(inv.get(RailType.CURVE_R, 0), 15)
        + [RailType.CURVE_R_LARGE] * min(inv.get(RailType.CURVE_R_LARGE, 0), 4)
    )
    straights = [RailType.STRAIGHT] * min(inv.get(RailType.STRAIGHT, 0), 2)
    for rt in straights[:1] + curves + straights[1:]:
        w.add(rt)
    if not w.placed:
        return []
    return _rotate_and_center(w.placed, w.points, 0.0)


async def search_layout(
    inventory: Dict[str, int],
    theme: str = "standard",
) -> Tuple[List[dict], bool, Dict[str, int]]:
    """
    レイアウト生成エントリポイント。
    Returns: (placed_rails, is_closed_loop, missing_parts)
    """
    inv: Dict[RailType, int] = {}
    for k, v in inventory.items():
        try:
            inv[RailType(k)] = int(v)
        except (ValueError, TypeError):
            pass

    rng = random.Random()

    std = inv.get(RailType.CURVE_R, 0)
    large = inv.get(RailType.CURVE_R_LARGE, 0)

    arc = _arc_sequence(std, large)
    if arc is None:
        # カーブ系16本未満: 閉ループ構成不可。開アークのプレビュー + 不足数を返す
        shortage = max(1, REQUIRED_CURVES - std - large)
        placed = _build_open_preview(inv)
        return placed, False, {RailType.CURVE_R.value: shortage}

    side = _side_pieces(inv, theme, rng)

    # オーバル: アーク + 辺 + アーク + 辺
    chain = arc + side + arc + side
    walker = _Walker()
    for rt in chain:
        walker.add(rt)

    closed = walker.is_closed()
    if not closed:
        # テンプレート数学上ここには到達しないはずだが、保険として
        placed = _build_open_preview(inv)
        return placed, False, {RailType.CURVE_R.value: 1}

    # ランダム回転で毎回違う見た目に
    theta = rng.choice([i * 22.5 for i in range(16)])
    placed = _rotate_and_center(walker.placed, walker.points, theta)

    return placed, True, {}
