"""
あおいレールプランナー - レイアウト生成エンジン v2.1（ウィグル付きテンプレート構成）

v2 で「カーブ16本あれば必ず閉じる」保証を実現したが、生成形状がオーバルのみだった。
v2.1 では右旋回（カーブの反転連結, flipped）を導入し、複雑な閉ループを生成する。

閉路性の数学的根拠（v2.1 拡張）:
  基本ループ = ARC(左8本=180°) + 辺S + ARC(左8本) + 辺S
  辺S が「正味旋回角 0」の任意ピース列なら、2つ目の辺は heading が 180° 反転して
  いるため同一列の変位ベクトルが正確に逆向きになり、ループは厳密に閉じる。
  → 辺に S字 [L,R]・波形 [L,L,R,R] などのウィグルモチーフを挿入しても閉路は保たれる。

安全性:
  - 自己交差は 20mm グリッド占有チェックで排除（仕様 §4.2 の簡易マスクの転用）
  - 閉路判定は仕様 §4.1 の許容誤差（距離10mm・角度2°）に準拠
  - 不合格ならウィグル数を減らして再試行し、最終的にオーバルへフォールバック
    （= カーブ16本あれば必ず成功、の保証は維持）
"""
from __future__ import annotations

import asyncio
import math
import random
from typing import Dict, List, Optional, Tuple

from .rail_db import RailType

# ---- 幾何定数 ----
AREA_MM = 1800.0
CENTER_MM = AREA_MM / 2
CURVE_ANGLE = 22.5
REQUIRED_CURVES = 16

STRAIGHT_LEN: Dict[RailType, float] = {
    RailType.STRAIGHT: 106.0,
    RailType.STRAIGHT_HALF: 53.0,
}
CURVE_RADIUS: Dict[RailType, float] = {
    RailType.CURVE_R: 103.0,
    RailType.CURVE_R_LARGE: 206.0,
}
INCLINE_LEN = 106.0
SEARCH_TIMEOUT_S = 0.200      # 仕様 §4.3

# 仕様 §4.1 接続許容誤差
CLOSE_DIST_MM = 10.0
CLOSE_ANGLE_DEG = 2.0

GRID_MM = 20.0                # 仕様 §4.2 占有グリッド
MAX_BBOX_MM = 1500.0          # レイアウトの最大外形
MAX_SIDE_MM = 1000.0

# ピース = (RailType, flipped)。flipped=True のカーブは右旋回。
Piece = Tuple[RailType, bool]


def _unit(deg: float) -> Tuple[float, float]:
    a = math.radians(deg)
    return math.cos(a), math.sin(a)


class _Walker:
    """ピースを順に連結しながらポーズ(x, y, heading, z)を更新する"""

    def __init__(self) -> None:
        self.x = 0.0
        self.y = 0.0
        self.h = 0.0
        self.z = 0
        self.placed: List[dict] = []
        self.points: List[Tuple[float, float]] = [(0.0, 0.0)]
        # 自己交差チェック用: (ピース番号, x, y) のサンプル点列
        self.samples: List[Tuple[int, float, float]] = []
        self._piece_idx = -1

    def _emit(self, rt: RailType, z: int, flipped: bool) -> None:
        self._piece_idx += 1
        self.placed.append({
            "rail_type": rt.value,
            "origin_x": self.x,
            "origin_y": self.y,
            "rotation": self.h % 360.0,
            "z_level": z,
            "flipped": flipped,
        })

    def _sample_line(self, x0: float, y0: float, x1: float, y1: float) -> None:
        dist = math.hypot(x1 - x0, y1 - y0)
        steps = max(2, int(dist / 15.0))
        for i in range(steps + 1):
            t = i / steps
            self.samples.append(
                (self._piece_idx, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))

    def _advance_straight(self, length: float) -> None:
        x0, y0 = self.x, self.y
        ux, uy = _unit(self.h)
        self.x += length * ux
        self.y += length * uy
        self._sample_line(x0, y0, self.x, self.y)

    def add(self, rt: RailType, flipped: bool = False) -> None:
        if rt in STRAIGHT_LEN:
            self._emit(rt, self.z, False)
            self._advance_straight(STRAIGHT_LEN[rt])
        elif rt in CURVE_RADIUS:
            self._emit(rt, self.z, flipped)
            R = CURVE_RADIUS[rt]
            if not flipped:
                # 左旋回: 中心 = pos + R*u(h+90)
                cx = self.x + R * _unit(self.h + 90.0)[0]
                cy = self.y + R * _unit(self.h + 90.0)[1]
                a0 = self.h - 90.0          # 中心→始点の角度
                sweep = CURVE_ANGLE
                self.h += CURVE_ANGLE
            else:
                # 右旋回: 中心 = pos + R*u(h-90)
                cx = self.x + R * _unit(self.h - 90.0)[0]
                cy = self.y + R * _unit(self.h - 90.0)[1]
                a0 = self.h + 90.0
                sweep = -CURVE_ANGLE
                self.h -= CURVE_ANGLE
            # 弧に沿ってサンプリング
            steps = 4
            for i in range(1, steps + 1):
                a = a0 + sweep * i / steps
                self.samples.append(
                    (self._piece_idx,
                     cx + R * _unit(a)[0], cy + R * _unit(a)[1]))
            a1 = a0 + sweep
            self.x = cx + R * _unit(a1)[0]
            self.y = cy + R * _unit(a1)[1]
        elif rt == RailType.INCLINE_START:
            self._emit(rt, self.z, False)
            self._advance_straight(INCLINE_LEN)
            self.z += 1
        elif rt == RailType.INCLINE_END:
            self._emit(rt, self.z, False)
            self._advance_straight(INCLINE_LEN)
            self.z -= 1
        elif rt == RailType.CROSSING:
            # 交差: 主軸を直線106mmとして通過（直交軸は snap_to で通過する）
            self._emit(rt, self.z, False)
            self._advance_straight(106.0)
        self.points.append((self.x, self.y))

    def snap_to(self, x: float, y: float, h: float) -> None:
        """
        既設ピース（交差の直交軸など）を通過する際にポーズを正確な出口へスナップする。
        仕様 §4.1 の許容誤差内で到達していることは呼び出し側で確認すること。
        """
        self.x = x
        self.y = y
        self.h = h
        self.points.append((self.x, self.y))

    def add_pier(self, rt: RailType) -> None:
        """現在位置に橋脚を置く（軌道ピースではないので前進しない）"""
        self._piece_idx += 1
        self.placed.append({
            "rail_type": rt.value,
            "origin_x": self.x,
            "origin_y": self.y,
            "rotation": 0.0,
            "z_level": 0,
            "flipped": False,
        })

    def is_closed(self) -> bool:
        """仕様 §4.1 の許容誤差（10mm / 2°）で閉路判定"""
        if self.z != 0:
            return False
        if math.hypot(self.x, self.y) > CLOSE_DIST_MM:
            return False
        hm = self.h % 360.0
        return hm <= CLOSE_ANGLE_DEG or hm >= 360.0 - CLOSE_ANGLE_DEG

    def no_self_intersection(self, exempt: frozenset = frozenset()) -> bool:
        """
        20mm グリッド占有で自己交差をチェック（隣接ピース・始終端の重なりは許容）。
        exempt: 交差レールなど「他ピースとの重なりが正当」なピース番号の集合。
        """
        n_pieces = self._piece_idx + 1
        cells: Dict[Tuple[int, int], int] = {}
        for idx, x, y in self.samples:
            cell = (int(x // GRID_MM), int(y // GRID_MM))
            prev = cells.get(cell)
            if prev is not None and prev != idx:
                if prev in exempt or idx in exempt:
                    continue
                diff = abs(prev - idx)
                if diff > 1 and diff != n_pieces - 1:  # 隣接・閉路の継ぎ目は許容
                    return False
            cells[cell] = idx
        return True

    def bbox_span(self) -> float:
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        return max(max(xs) - min(xs), max(ys) - min(ys))


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


def _arc_sequence(std_avail: int, large_avail: int) -> Optional[List[Piece]]:
    """180°アーク1本分（左カーブ8ピース）。同一構成を2本使う。"""
    per_std = min(8, std_avail // 2)
    per_large = 8 - per_std
    if large_avail < per_large * 2:
        return None
    return ([(RailType.CURVE_R, False)] * per_std
            + [(RailType.CURVE_R_LARGE, False)] * per_large)


# ウィグルモチーフ: 正味旋回角 0 のカーブ列（L=左, R=右）
# (モチーフ, 消費カーブ本数)
_WIGGLE_MOTIFS: List[List[Piece]] = [
    [(RailType.CURVE_R, False), (RailType.CURVE_R, True)],                # S字 LR
    [(RailType.CURVE_R, True), (RailType.CURVE_R, False)],                # S字 RL
    [(RailType.CURVE_R, False), (RailType.CURVE_R, False),
     (RailType.CURVE_R, True), (RailType.CURVE_R, True)],                 # 深い波 LLRR
    [(RailType.CURVE_R, True), (RailType.CURVE_R, True),
     (RailType.CURVE_R, False), (RailType.CURVE_R, False)],               # 深い波 RRLL
]


def _build_side(
    s_use: int,
    h_use: int,
    wiggle_budget: int,
    rng: random.Random,
) -> List[Piece]:
    """
    対辺に使う 1 辺分のピース列を構築する（両辺で同一列を使用）。
    直線ユニット + ウィグルモチーフをランダム順に並べる。正味旋回角は常に 0。
    """
    units: List[List[Piece]] = []
    units += [[(RailType.STRAIGHT, False)] for _ in range(s_use)]
    units += [[(RailType.STRAIGHT_HALF, False)] for _ in range(h_use)]

    remaining = wiggle_budget
    while remaining >= 2:
        candidates = [m for m in _WIGGLE_MOTIFS if len(m) <= remaining]
        if not candidates:
            break
        motif = rng.choice(candidates)
        units.append(list(motif))
        remaining -= len(motif)

    rng.shuffle(units)
    return [p for unit in units for p in unit]


def _try_chain(
    arc: List[Piece],
    side: List[Piece],
) -> Optional[_Walker]:
    """チェーンを構築して 閉路・自己交差・外形 を検証する"""
    walker = _Walker()
    for rt, fl in arc:
        walker.add(rt, fl)
    for rt, fl in side:
        walker.add(rt, fl)
    for rt, fl in arc:
        walker.add(rt, fl)
    for rt, fl in side:
        walker.add(rt, fl)

    if not walker.is_closed():
        return None
    if walker.bbox_span() > MAX_BBOX_MM:
        return None
    if not walker.no_self_intersection():
        return None
    return walker


def _try_build_figure8(inv: Dict[RailType, int]) -> Optional[_Walker]:
    """
    本物の8の字: 交差レールを中心に、左旋回ループと右旋回ループを直交させる。

    幾何学的検証（机上計算済み）:
      交差(W→E) → ハーフ → 左カーブ×12(+270°) → ハーフ → 交差の側腕(53,53)に
      誤差(3,-3)mm で到達 → 交差を直交方向に通過(snap) → ハーフ →
      右カーブ×12(-270°) → ハーフ → W腕(0,0)に誤差(3,-3)mm で帰着。
      接合誤差 4.24mm ≤ 仕様許容 10mm。

    必要部材: 交差1 + 標準カーブ24 + ハーフ直線4
    """
    if inv.get(RailType.CROSSING, 0) < 1:
        return None
    if inv.get(RailType.CURVE_R, 0) < 24:
        return None
    if inv.get(RailType.STRAIGHT_HALF, 0) < 4:
        return None

    w = _Walker()
    w.add(RailType.CROSSING)              # idx 0: 主軸 W→E を通過
    w.add(RailType.STRAIGHT_HALF)
    for _ in range(12):
        w.add(RailType.CURVE_R)           # 左ループ +270°
    w.add(RailType.STRAIGHT_HALF)

    # 交差の側腕 (53, 53) に向き 270° で到達しているか（許容誤差内）
    if math.hypot(w.x - 53.0, w.y - 53.0) > CLOSE_DIST_MM:
        return None
    hm = (w.h - 270.0) % 360.0
    if hm > CLOSE_ANGLE_DEG and hm < 360.0 - CLOSE_ANGLE_DEG:
        return None

    # 交差を直交方向に通過して反対側の腕 (53, -53) から出る
    w.snap_to(53.0, -53.0, 270.0)

    w.add(RailType.STRAIGHT_HALF)
    for _ in range(12):
        w.add(RailType.CURVE_R, flipped=True)   # 右ループ -270°
    w.add(RailType.STRAIGHT_HALF)

    if not w.is_closed():
        return None
    if w.bbox_span() > MAX_BBOX_MM:
        return None
    # 交差(idx 0)は他ピースと重なるのが正当
    if not w.no_self_intersection(exempt=frozenset({0})):
        return None
    return w


def _try_build_elevated(
    inv: Dict[RailType, int],
    arc: List[Piece],
) -> Optional[_Walker]:
    """高架テンプレート（v2 から継続）: 坂→高架直線(Z=1)→坂 + 橋脚"""
    if inv.get(RailType.INCLINE_START, 0) < 1 or inv.get(RailType.INCLINE_END, 0) < 1:
        return None
    s_avail = inv.get(RailType.STRAIGHT, 0)
    piers_std = inv.get(RailType.BRIDGE_PIER_STANDARD, 0)
    piers_blk = inv.get(RailType.BRIDGE_PIER_BLOCK, 0)
    piers_total = piers_std + piers_blk
    if s_avail < 2 or piers_total < 1:
        return None

    n = min((s_avail - 2) // 2, piers_total - 1, 7)
    if n < 0:
        return None

    walker = _Walker()
    pier_queue = (
        [RailType.BRIDGE_PIER_STANDARD] * piers_std
        + [RailType.BRIDGE_PIER_BLOCK] * piers_blk
    )

    for rt, fl in arc:
        walker.add(rt, fl)
    walker.add(RailType.INCLINE_START)
    walker.add_pier(pier_queue.pop(0))
    for _ in range(n):
        walker.add(RailType.STRAIGHT)
        walker.add_pier(pier_queue.pop(0))
    walker.add(RailType.INCLINE_END)
    for rt, fl in arc:
        walker.add(rt, fl)
    for _ in range(n + 2):
        walker.add(RailType.STRAIGHT)

    if not walker.is_closed():
        return None
    return walker


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


def _generate(
    inventory: Dict[str, int],
    theme: str,
) -> Tuple[List[dict], bool, Dict[str, int]]:
    """テンプレート構成の本体"""
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
        shortage = max(1, REQUIRED_CURVES - std - large)
        placed = _build_open_preview(inv)
        return placed, False, {RailType.CURVE_R.value: shortage}

    theta = rng.choice([i * 22.5 for i in range(16)])

    # 高架テーマ
    if theme == "elevated":
        walker = _try_build_elevated(inv, arc)
        if walker is not None:
            placed = _rotate_and_center(walker.placed, walker.points, theta)
            return placed, True, {}
        # 坂・橋脚が足りなければ通常生成へフォールバック

    # 8の字テーマ: 交差レールがあれば本物の8の字を構成
    if theme == "figure8":
        walker = _try_build_figure8(inv)
        if walker is not None:
            placed = _rotate_and_center(walker.placed, walker.points, theta)
            return placed, True, {}
        # 部材不足ならコンパクトオーバルへフォールバック

    # ---- 在庫予算の計算 ----
    used_std_in_arc = sum(1 for rt, _ in arc if rt == RailType.CURVE_R) * 2
    extra_std = std - used_std_in_arc            # ウィグルに使える標準カーブ
    s_pairs = inv.get(RailType.STRAIGHT, 0) // 2
    h_pairs = inv.get(RailType.STRAIGHT_HALF, 0) // 2
    wiggle_max = (extra_std // 2) // 2 * 2       # 片辺あたり（偶数に丸め）

    # テーマ別パラメータ
    if theme == "figure8":          # コンパクト: 直線少なめ + ウィグル多め
        s_target, h_target = min(s_pairs, 1), min(h_pairs, 1)
    else:                            # おまかせ / 高架フォールバック
        s_target = rng.randint(0, s_pairs) if s_pairs > 0 else 0
        h_target = rng.randint(0, h_pairs) if h_pairs > 0 else 0

    # 辺の長さ制限
    while s_target * 106 + h_target * 53 > MAX_SIDE_MM and s_target > 0:
        s_target -= 1
    while s_target * 106 + h_target * 53 > MAX_SIDE_MM and h_target > 0:
        h_target -= 1

    # ---- ウィグル付き生成（自己交差したらワイルドさを下げて再試行） ----
    best_walker: Optional[_Walker] = None
    for attempt in range(40):
        # 試行が進むほどウィグル数を減らす（最後は 0 = 確実なオーバル）
        decay = max(0.0, 1.0 - attempt / 25.0)
        budget = int(wiggle_max * decay)
        if budget % 2 == 1:
            budget -= 1
        side = _build_side(s_target, h_target, budget, rng)
        walker = _try_chain(arc, side)
        if walker is not None:
            best_walker = walker
            break

    if best_walker is None:
        # 最終保険: ウィグルなし・直線なしの純オーバル（幾何学的に必ず成功）
        best_walker = _try_chain(arc, [])

    if best_walker is None:
        placed = _build_open_preview(inv)
        return placed, False, {RailType.CURVE_R.value: 1}

    placed = _rotate_and_center(best_walker.placed, best_walker.points, theta)
    return placed, True, {}


async def search_layout(
    inventory: Dict[str, int],
    theme: str = "standard",
) -> Tuple[List[dict], bool, Dict[str, int]]:
    """
    レイアウト生成エントリポイント。
    仕様 §4.3 に従い 200ms の強制タイムアウト付き。
    Returns: (placed_rails, is_closed_loop, missing_parts)
    """
    async def _run() -> Tuple[List[dict], bool, Dict[str, int]]:
        return _generate(inventory, theme)

    try:
        return await asyncio.wait_for(_run(), timeout=SEARCH_TIMEOUT_S)
    except asyncio.TimeoutError:
        return [], False, {RailType.CURVE_R.value: REQUIRED_CURVES}
