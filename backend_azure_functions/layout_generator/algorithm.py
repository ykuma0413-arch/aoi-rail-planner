"""
あおいレールプランナー - レイアウト生成エンジン v2.2（rail_db 単一真実源化）

v2.1 まではエンジンが長さ・半径・角度を独自定数で二重保持していた。
v2.2 では rail_db.RAIL_GEOMETRY_DB を single source of truth とし、
  - 各ピースの走行変換（入口→出口の移動量・回転量・Z変化）
  - 直線プール / カーブプールの選択可否（excluded_from_auto）
  - 交差レールの直交アーム座標（8の字用）
をすべて DB から導出する。これにより DB にレールを追加・修正すれば
エンジンは自動で追従する。

閉路性の数学的根拠（v2.1 から不変）:
  基本ループ = ARC(左8本=180°) + 辺S + ARC(左8本) + 辺S
  辺S が「正味旋回角 0」の任意ピース列なら、2つ目の辺は heading が 180° 反転して
  いるため同一列の変位ベクトルが正確に逆向きになり、ループは厳密に閉じる。

安全性:
  - 自己交差は 20mm グリッド占有チェックで排除（仕様 §4.2）
  - 閉路判定は仕様 §4.1 の許容誤差（距離10mm・角度2°）
  - 不合格ならウィグル数を減らして再試行 → 最終的に純オーバルへフォールバック
    （= カーブ16本あれば必ず成功、の保証は維持）
"""
from __future__ import annotations

import asyncio
import math
import random
from typing import Dict, List, Optional, Tuple

from .rail_db import RailType, RAIL_GEOMETRY_DB

# ---- エリア・許容誤差定数（仕様書由来。ジオメトリではないのでここに残す） ----
AREA_MM = 1800.0
CENTER_MM = AREA_MM / 2
REQUIRED_CURVES = 16
SEARCH_TIMEOUT_S = 0.200      # 仕様 §4.3

CLOSE_DIST_MM = 10.0          # 仕様 §4.1
CLOSE_ANGLE_DEG = 2.0

GRID_MM = 20.0                # 仕様 §4.2 占有グリッド
MAX_BBOX_MM = 1500.0
MAX_SIDE_MM = 1000.0

# ============================================================
# rail_db からの導出（single source of truth）
# ============================================================


def _signed_angle(deg: float) -> float:
    a = deg % 360.0
    return a - 360.0 if a > 180.0 else a


def _derive_track_transforms() -> Dict[RailType, Tuple[float, float, float, int]]:
    """
    各軌道ピースの走行変換 (exit_x, exit_y, 旋回角[signed deg], Z変化) を
    RAIL_GEOMETRY_DB の joints[0]→joints[1] から導出する。
    """
    out: Dict[RailType, Tuple[float, float, float, int]] = {}
    for rt, g in RAIL_GEOMETRY_DB.items():
        if len(g.joints) < 2:
            continue
        j0, j1 = g.joints[0], g.joints[1]
        out[rt] = (
            j1.x - j0.x,
            j1.y - j0.y,
            _signed_angle(j1.angle),
            j1.z_offset - j0.z_offset,
        )
    return out


_TRACK_XFORM = _derive_track_transforms()

# 橋脚（ジョイントを持たない設置物）
PIER_TYPES = frozenset(
    rt for rt, g in RAIL_GEOMETRY_DB.items() if len(g.joints) == 0)

# 自動探索で選択可能な軌道ピース
_SELECTABLE = frozenset(
    rt for rt, g in RAIL_GEOMETRY_DB.items()
    if not g.excluded_from_auto and rt in _TRACK_XFORM)

# 直線プール: 旋回 0・Z変化 0・2ジョイント（交差は4ジョイントなので自然に除外）
STRAIGHT_TYPES: List[RailType] = sorted(
    (rt for rt in _SELECTABLE
     if abs(_TRACK_XFORM[rt][2]) < 1e-9
     and _TRACK_XFORM[rt][3] == 0
     and len(RAIL_GEOMETRY_DB[rt].joints) == 2),
    key=lambda rt: -_TRACK_XFORM[rt][0],
)
STRAIGHT_LEN: Dict[RailType, float] = {
    rt: _TRACK_XFORM[rt][0] for rt in STRAIGHT_TYPES}

# カーブ定数（描画・8の字数学の基準は標準カーブ）
CURVE_ANGLE = abs(_TRACK_XFORM[RailType.CURVE_R][2])


def _radius_of(rt: RailType) -> float:
    ex, ey, _, _ = _TRACK_XFORM[rt]
    return (ex * ex + ey * ey) / (2.0 * ey)


CURVE_RADIUS: Dict[RailType, float] = {
    RailType.CURVE_R: _radius_of(RailType.CURVE_R),
    RailType.CURVE_R_LARGE: _radius_of(RailType.CURVE_R_LARGE),
}
INCLINE_LEN = _TRACK_XFORM[RailType.INCLINE_START][0]

# 交差レールの直交アーム（8の字が使う。DB の joints[2:] が真実源）
_CROSS_ARM_NEG = next(  # y<0 側 (53, -53, 270°)
    j for j in RAIL_GEOMETRY_DB[RailType.CROSSING].joints[2:] if j.y < 0)
_CROSS_ARM_POS = next(  # y>0 側 (53, +53, 90°)
    j for j in RAIL_GEOMETRY_DB[RailType.CROSSING].joints[2:] if j.y > 0)

# ピース = (RailType, flipped)。flipped=True のカーブは右旋回（鏡映連結）。
Piece = Tuple[RailType, bool]


def _unit(deg: float) -> Tuple[float, float]:
    a = math.radians(deg)
    return math.cos(a), math.sin(a)


# ============================================================
# ウォーカー（DB の変換をワールド座標に適用するだけの汎用実装）
# ============================================================


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

    def add(self, rt: RailType, flipped: bool = False) -> None:
        """
        rail_db 由来の走行変換を適用する（独自ジオメトリは持たない）。
        flipped は進行軸に対する鏡映連結（カーブの左右反転）。
        """
        xf = _TRACK_XFORM.get(rt)
        if xf is None:
            return  # 橋脚などの非軌道ピースは add_pier を使う
        ex, ey, ea, dz = xf
        if flipped:
            ey, ea = -ey, -ea

        self._emit(rt, self.z, flipped)

        c, s = _unit(self.h)
        x0, y0 = self.x, self.y

        if abs(ea) < 1e-9:
            # 直進ピース
            nx = x0 + ex * c - ey * s
            ny = y0 + ex * s + ey * c
            dist = math.hypot(nx - x0, ny - y0)
            steps = max(2, int(dist / 15.0))
            for i in range(steps + 1):
                t = i / steps
                self.samples.append(
                    (self._piece_idx, x0 + (nx - x0) * t, y0 + (ny - y0) * t))
        else:
            # 円弧ピース: 半径は DB の出口座標から導出（p(t)=(R sinθt, R(1-cosθt))）
            radius = (ex * ex + ey * ey) / (2.0 * ey)  # 符号付き
            steps = 4
            for i in range(1, steps + 1):
                th = math.radians(ea) * i / steps
                lx = radius * math.sin(th)
                ly = radius * (1.0 - math.cos(th))
                self.samples.append((
                    self._piece_idx,
                    x0 + lx * c - ly * s,
                    y0 + lx * s + ly * c,
                ))
            nx = x0 + ex * c - ey * s
            ny = y0 + ex * s + ey * c

        self.x, self.y = nx, ny
        self.h += ea
        self.z += dz
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
        self.add_pier_at(rt, self.x, self.y)

    def add_pier_at(self, rt: RailType, x: float, y: float) -> None:
        """指定位置に橋脚を置く（軌道チェーン完了後の一括設置用）"""
        self._piece_idx += 1
        self.placed.append({
            "rail_type": rt.value,
            "origin_x": x,
            "origin_y": y,
            "rotation": 0.0,
            "z_level": 0,
            "flipped": False,
        })

    def seed(self, x: float, y: float, h_deg: float, z: int) -> None:
        """任意ポーズにカーソルを初期化する（側線=スパーの起点設定に使う）。"""
        self.x = x
        self.y = y
        self.h = h_deg
        self.z = z
        self.points = [(x, y)]

    def is_closed(self) -> bool:
        """仕様 §4.1 の許容誤差（10mm / 2°）で閉路判定"""
        if self.z != 0:
            return False
        if math.hypot(self.x, self.y) > CLOSE_DIST_MM:
            return False
        hm = self.h % 360.0
        return hm <= CLOSE_ANGLE_DEG or hm >= 360.0 - CLOSE_ANGLE_DEG

    # ---- テスト/検証用アクセサ（仕様§4.1 の許容誤差判定を数値で公開） ----

    def position_error_mm(self) -> float:
        """終端位置と始端(0,0)の距離 (mm)"""
        return math.hypot(self.x, self.y)

    def angle_error_deg(self) -> float:
        """終端向きと始端(0°)の角度差 (deg, 0〜180)"""
        hm = self.h % 360.0
        return min(hm, 360.0 - hm)

    @classmethod
    def geometry_for(cls, rail_type: RailType):
        """
        Walker が実際に使う走行変換（rail_db 由来）を返すゲッター。
        単一真実源の検証テスト用。橋脚などの非軌道ピースは (0,0)/0°。
        """
        from types import SimpleNamespace
        xf = _TRACK_XFORM.get(rail_type)
        if xf is None:
            return SimpleNamespace(move_vector=(0.0, 0.0), turn_degrees=0.0)
        return SimpleNamespace(move_vector=(xf[0], xf[1]), turn_degrees=xf[2])

    @classmethod
    def from_course(cls, course: "Course") -> "_Walker":
        """generate_course() が返す Course から生成時の Walker を取り出す"""
        if course.walker is None:
            raise ValueError("course has no walker (open preview?)")
        return course.walker

    def no_self_intersection(self, exempt: Optional[frozenset] = None,
                             grid_mm: float = GRID_MM) -> bool:
        """
        20mm グリッド占有で自己交差をチェック（隣接ピース・始終端の重なりは許容）。
        exempt: 交差レールなど「他ピースとの重なりが正当」なピース番号の集合。
                None の場合は生成時に記録された既定値（_overlap_exempt）を使う。
        """
        if exempt is None:
            exempt = getattr(self, "_overlap_exempt", frozenset())
        n_pieces = self._piece_idx + 1
        cells: Dict[Tuple[int, int], int] = {}
        for idx, x, y in self.samples:
            cell = (int(x // grid_mm), int(y // grid_mm))
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


# ============================================================
# テンプレート構成
# ============================================================


def _arc_sequence(std_avail: int, large_avail: int) -> Optional[List[Piece]]:
    """180°アーク1本分（左カーブ8ピース）。同一構成を2本使う。"""
    per_std = min(8, std_avail // 2)
    per_large = 8 - per_std
    if large_avail < per_large * 2:
        return None
    return ([(RailType.CURVE_R, False)] * per_std
            + [(RailType.CURVE_R_LARGE, False)] * per_large)


# ウィグルモチーフ: 正味旋回角 0 のカーブ列（L=左, R=右）
_WIGGLE_MOTIFS: List[List[Piece]] = [
    [(RailType.CURVE_R, False), (RailType.CURVE_R, True)],                # S字 LR
    [(RailType.CURVE_R, True), (RailType.CURVE_R, False)],                # S字 RL
    [(RailType.CURVE_R, False), (RailType.CURVE_R, False),
     (RailType.CURVE_R, True), (RailType.CURVE_R, True)],                 # 深い波 LLRR
    [(RailType.CURVE_R, True), (RailType.CURVE_R, True),
     (RailType.CURVE_R, False), (RailType.CURVE_R, False)],               # 深い波 RRLL
]


def _build_side(
    straight_counts: Dict[RailType, int],
    wiggle_budget: int,
    rng: random.Random,
) -> List[Piece]:
    """
    対辺に使う 1 辺分のピース列を構築する（両辺で同一列を使用）。
    直線プール（DB由来: straight/stop/half/quarter…）+ ウィグルモチーフを
    ランダム順に並べる。正味旋回角は常に 0。
    """
    units: List[List[Piece]] = []
    for rt, n in straight_counts.items():
        units += [[(rt, False)] for _ in range(n)]

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
      交差(W→E) → ハーフ → 左カーブ×12(+270°) → ハーフ → 交差の側腕に
      誤差(3,-3)mm で到達 → 交差を直交方向に通過(snap) → ハーフ →
      右カーブ×12(-270°) → ハーフ → W腕(0,0)に誤差(3,-3)mm で帰着。
      接合誤差 4.24mm ≤ 仕様許容 10mm。

    必要部材: 交差1 + 標準カーブ24 + ハーフ直線4
    アーム座標は RAIL_GEOMETRY_DB[CROSSING].joints[2:] を真実源とする。
    """
    if inv.get(RailType.CROSSING, 0) < 1:
        return None
    if inv.get(RailType.CURVE_R, 0) < 24:
        return None
    if inv.get(RailType.STRAIGHT_HALF, 0) < 4:
        return None

    arm_in = _CROSS_ARM_POS    # 進入する側腕 (53, +53), 外向き90°
    arm_out = _CROSS_ARM_NEG   # 通過後に出る側腕 (53, -53), 外向き270°
    entry_heading = (arm_in.angle + 180.0) % 360.0   # 側腕へ進入する向き = 270°

    w = _Walker()
    w.add(RailType.CROSSING)              # idx 0: 主軸 W→E を通過
    w.add(RailType.STRAIGHT_HALF)
    for _ in range(12):
        w.add(RailType.CURVE_R)           # 左ループ +270°
    w.add(RailType.STRAIGHT_HALF)

    # 交差の側腕に許容誤差内で到達しているか
    if math.hypot(w.x - arm_in.x, w.y - arm_in.y) > CLOSE_DIST_MM:
        return None
    hm = (w.h - entry_heading) % 360.0
    if hm > CLOSE_ANGLE_DEG and hm < 360.0 - CLOSE_ANGLE_DEG:
        return None

    # 交差を直交方向に通過して反対側の腕から出る（出射向き = 出口腕の外向き角）
    w.snap_to(arm_out.x, arm_out.y, arm_out.angle)

    w.add(RailType.STRAIGHT_HALF)
    for _ in range(12):
        w.add(RailType.CURVE_R, flipped=True)   # 右ループ -270°
    w.add(RailType.STRAIGHT_HALF)

    if not w.is_closed():
        return None
    if w.bbox_span() > MAX_BBOX_MM:
        return None
    if not w.no_self_intersection(exempt=frozenset({0})):
        return None
    # 交差レール(idx 0)の重なりは正当 — 後段の再検証（from_course経由）でも同じ扱いにする
    w._overlap_exempt = frozenset({0})
    return w


def _try_build_elevated(
    inv: Dict[RailType, int],
    arc: List[Piece],
) -> Optional[_Walker]:
    """高架テンプレート: 坂→高架直線(Z=1)→坂 + 橋脚"""
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

    # 橋脚は設置位置だけ記録し、軌道チェーン完了後にまとめて emit する。
    # （軌道ピースの合間に emit するとピース番号が飛び、
    #   no_self_intersection の「配置順=物理隣接」前提が崩れるため）
    pier_spots: List[Tuple[RailType, float, float]] = []

    for rt, fl in arc:
        walker.add(rt, fl)
    walker.add(RailType.INCLINE_START)
    pier_spots.append((pier_queue.pop(0), walker.x, walker.y))
    for _ in range(n):
        walker.add(RailType.STRAIGHT)
        pier_spots.append((pier_queue.pop(0), walker.x, walker.y))
    walker.add(RailType.INCLINE_END)
    for rt, fl in arc:
        walker.add(rt, fl)
    for _ in range(n + 2):
        walker.add(RailType.STRAIGHT)

    if not walker.is_closed():
        return None

    for rt_p, px, py in pier_spots:
        walker.add_pier_at(rt_p, px, py)
    return walker


# ============================================================
# 側線（スパー）: ポイントレールで本線から分岐する行き止まり
# ============================================================


def _grid_cells(samples: List[Tuple[int, float, float]]) -> Dict[Tuple[int, int], int]:
    cells: Dict[Tuple[int, int], int] = {}
    for idx, x, y in samples:
        cells[(int(x // GRID_MM), int(y // GRID_MM))] = idx
    return cells


def _try_add_spur(
    main: _Walker,
    used: Dict[RailType, int],
    inv: Dict[RailType, int],
    rng: random.Random,
) -> Optional[Tuple[List[dict], List[Tuple[float, float]], dict]]:
    """
    本線ループの直線ピース1本をポイント(switch_left/right)に置換し、
    そこから行き止まりの側線を伸ばす。

    ポイントの主軸は直線106mmと幾何的に同一なので、本線の閉路性は不変
    （is_closed の再検証は不要）。側線は開放端を1つ持つ付属チェーンとして
    本線との非重なり・領域内のみを検証する。

    Returns: (統合placed, 統合points, 側線の開放端dict) / 不成立なら None
    """
    # 使えるポイントを選ぶ
    switch_type = None
    for st in (RailType.SWITCH_LEFT, RailType.SWITCH_RIGHT):
        if inv.get(st, 0) - used.get(st, 0) > 0:
            switch_type = st
            break
    if switch_type is None:
        return None

    # 側線に使える余剰の直線・カーブ
    spare_straight = inv.get(RailType.STRAIGHT, 0) - used.get(RailType.STRAIGHT, 0)
    spare_curve = inv.get(RailType.CURVE_R, 0) - used.get(RailType.CURVE_R, 0)
    if spare_straight + spare_curve < 1:
        return None

    branch = RAIL_GEOMETRY_DB[switch_type].joints[2]  # 分岐側ジョイント（曲線出口）
    main_cells = _grid_cells(main.samples)

    # 本線の「素の直線(106mm・非スパー)」ピースを置換候補にする
    cand = [i for i, p in enumerate(main.placed)
            if p["rail_type"] == RailType.STRAIGHT.value]
    rng.shuffle(cand)

    # 側線構成の候補（短い順に試す。分岐で既に22.5°曲がっているので直線主体）
    spur_configs: List[List[RailType]] = []
    for ns in range(min(spare_straight, 3), 0, -1):
        spur_configs.append([RailType.STRAIGHT] * ns)
    if spare_curve >= 1 and spare_straight >= 1:
        spur_configs.insert(0, [RailType.CURVE_R, RailType.STRAIGHT])
    if not spur_configs:
        spur_configs = [[RailType.CURVE_R]] if spare_curve >= 1 else []

    for idx in cand:
        p = main.placed[idx]
        rot = math.radians(p["rotation"])
        c, s = math.cos(rot), math.sin(rot)
        bx = p["origin_x"] + branch.x * c - branch.y * s
        by = p["origin_y"] + branch.x * s + branch.y * c
        bh = (p["rotation"] + branch.angle) % 360.0

        for pieces in spur_configs:
            spur = _Walker()
            spur.seed(bx, by, bh, p["z_level"])
            for rt in pieces:
                spur.add(rt)

            # 領域内チェック
            allx = [pt[0] for pt in main.points + spur.points]
            ally = [pt[1] for pt in main.points + spur.points]
            if max(max(allx) - min(allx), max(ally) - min(ally)) > MAX_BBOX_MM:
                continue

            # 側線 vs 本線 の重なりチェック（分岐直後の1セルだけ許容）
            ok = True
            skip = 2  # 分岐付近の最初の数サンプルは本線と近接するので許容
            spur_cells: Dict[Tuple[int, int], int] = {}
            for k, (sidx, x, y) in enumerate(spur.samples):
                cell = (int(x // GRID_MM), int(y // GRID_MM))
                if k >= skip and cell in main_cells:
                    ok = False
                    break
                # 側線内の自己交差
                if cell in spur_cells and abs(spur_cells[cell] - sidx) > 1:
                    ok = False
                    break
                spur_cells[cell] = sidx
            if not ok:
                continue

            # 成立: 本線の直線をポイントに置換し、側線ピースを spur フラグ付きで追加
            new_placed = [dict(pp) for pp in main.placed]
            new_placed[idx]["rail_type"] = switch_type.value
            for sp in spur.placed:
                sp2 = dict(sp)
                sp2["spur"] = True
                new_placed.append(sp2)
            open_end = {"x": spur.x, "y": spur.y, "heading": spur.h % 360.0}
            new_points = list(main.points) + spur.points
            return new_placed, new_points, open_end

    return None


def _used_counts(placed: List[dict]) -> Dict[RailType, int]:
    counts: Dict[RailType, int] = {}
    for p in placed:
        try:
            rt = RailType(p["rail_type"])
        except ValueError:
            continue
        counts[rt] = counts.get(rt, 0) + 1
    return counts


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
    """テンプレート構成の本体（API用: walker を伏せて返す）"""
    placed, closed, missing, _walker = _generate_ex(
        inventory, theme, random.Random())
    return placed, closed, missing


def _generate_ex(
    inventory: Dict[str, int],
    theme: str,
    rng: random.Random,
) -> Tuple[List[dict], bool, Dict[str, int], Optional["_Walker"]]:
    """テンプレート構成の本体（検証用に生成時 Walker も返す）"""
    inv: Dict[RailType, int] = {}
    for k, v in inventory.items():
        try:
            inv[RailType(k)] = int(v)
        except (ValueError, TypeError):
            pass

    std = inv.get(RailType.CURVE_R, 0)
    large = inv.get(RailType.CURVE_R_LARGE, 0)

    arc = _arc_sequence(std, large)
    if arc is None:
        shortage = max(1, REQUIRED_CURVES - std - large)
        placed = _build_open_preview(inv)
        return placed, False, {RailType.CURVE_R.value: shortage}, None

    theta = rng.choice([i * CURVE_ANGLE for i in range(16)])

    # 高架テーマ
    if theme == "elevated":
        walker = _try_build_elevated(inv, arc)
        if walker is not None:
            placed = _rotate_and_center(walker.placed, walker.points, theta)
            return placed, True, {}, walker
        # 坂・橋脚が足りなければ通常生成へフォールバック

    # 8の字テーマ: 交差レールがあれば本物の8の字を構成
    if theme == "figure8":
        walker = _try_build_figure8(inv)
        if walker is not None:
            placed = _rotate_and_center(walker.placed, walker.points, theta)
            return placed, True, {}, walker
        # 部材不足ならコンパクトオーバルへフォールバック

    # ---- 在庫予算の計算（直線プールは DB 由来の STRAIGHT_TYPES 全種） ----
    used_std_in_arc = sum(1 for rt, _ in arc if rt == RailType.CURVE_R) * 2
    extra_std = std - used_std_in_arc            # ウィグルに使える標準カーブ
    wiggle_max = (extra_std // 2) // 2 * 2       # 片辺あたり（偶数に丸め）

    pairs = {rt: inv.get(rt, 0) // 2 for rt in STRAIGHT_TYPES}

    # テーマ別パラメータ
    if theme == "figure8":          # コンパクト: 直線少なめ + ウィグル多め
        targets = {rt: min(p, 1) for rt, p in pairs.items()}
    else:                            # おまかせ / 高架フォールバック
        targets = {rt: (rng.randint(0, p) if p > 0 else 0)
                   for rt, p in pairs.items()}

    # 辺の長さ制限（長いピースから順に削る）
    def _side_len() -> float:
        return sum(STRAIGHT_LEN[rt] * n for rt, n in targets.items())

    for rt in STRAIGHT_TYPES:  # 長さ降順に並んでいる
        while _side_len() > MAX_SIDE_MM and targets[rt] > 0:
            targets[rt] -= 1

    # ---- ウィグル付き生成（自己交差したらワイルドさを下げて再試行） ----
    best_walker: Optional[_Walker] = None
    for attempt in range(40):
        decay = max(0.0, 1.0 - attempt / 25.0)
        budget = int(wiggle_max * decay)
        if budget % 2 == 1:
            budget -= 1
        side = _build_side(targets, budget, rng)
        walker = _try_chain(arc, side)
        if walker is not None:
            best_walker = walker
            break

    if best_walker is None:
        # 最終保険: ウィグルなし・直線なしの純オーバル（幾何学的に必ず成功）
        best_walker = _try_chain(arc, [])

    if best_walker is None:
        placed = _build_open_preview(inv)
        return placed, False, {RailType.CURVE_R.value: 1}, None

    # ---- 側線（スパー）: ポイントレールがあれば本線に行き止まり側線を付ける ----
    result_placed = best_walker.placed
    result_points = best_walker.points
    if theme != "figure8" and (
            inv.get(RailType.SWITCH_LEFT, 0) > 0
            or inv.get(RailType.SWITCH_RIGHT, 0) > 0):
        used = _used_counts(best_walker.placed)
        spur = _try_add_spur(best_walker, used, inv, rng)
        if spur is not None:
            result_placed, result_points, _open_end = spur

    placed = _rotate_and_center(result_placed, result_points, theta)
    return placed, True, {}, best_walker


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


# ============================================================
# テストハーネス用 API（tests/test_geometry.py が使用）
# ============================================================


class Course:
    """generate_course() の戻り値。pieces は rail_type を持つ軽量オブジェクト列。"""

    def __init__(self, placed: List[dict], closed: bool,
                 missing: Dict[str, int], theme: str,
                 walker: Optional[_Walker]) -> None:
        from types import SimpleNamespace
        self.placed = placed
        self.closed = closed
        self.missing = missing
        self.theme = theme
        self.walker = walker
        self.pieces = [
            SimpleNamespace(rail_type=p["rail_type"]) for p in placed]


def generate_course(seed: Optional[int] = None) -> Course:
    """
    シード付き決定的コース生成（テスト・検証用の同期ハーネス）。

    テーマと在庫レシピを seed から決定し、生成の再現性を保証する:
      - theme      : seed % 3 → standard / elevated / figure8
      - ポイント   : 偶数 seed は左分岐、奇数 seed は右分岐を1本（側線の多様性）
      - seed % 4==3: 標準カーブを14本に絞り大カーブ4本を混ぜる
                     （大カーブの使用経路を確実に踏む）
    """
    s = 0 if seed is None else int(seed)
    rng = random.Random(s)
    theme = ("standard", "elevated", "figure8")[s % 3]

    inv: Dict[str, int] = {
        "curve_r": 26, "straight": 10, "straight_half": 6,
        "straight_quarter": 4, "stop_rail": 2,
        "incline_start": 1, "incline_end": 1,
        "bridge_pier_standard": 2, "bridge_pier_block": 2,
        "crossing": 1,
    }
    if s % 2 == 0:
        inv["switch_left"] = 1
    else:
        inv["switch_right"] = 1
    if s % 4 == 3:
        inv["curve_r"] = 14
        inv["curve_r_large"] = 4

    placed, closed, missing, walker = _generate_ex(inv, theme, rng)
    return Course(placed, closed, missing, theme, walker)
