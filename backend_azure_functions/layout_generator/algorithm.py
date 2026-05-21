"""
あおいレールプランナー - レイアウト自動生成アルゴリズム
200msタイムアウト付きビームサーチ。
接続判定式:
  Distance = sqrt((x1-x2)^2+(y1-y2)^2) <= 10mm
  AngleError = |θ1-θ2| mod 360° <= 2° OR ||θ1-θ2|-180°| <= 2°
  PolarityCheck = polarity1 != polarity2
3条件すべてTrueのとき接続成功。
"""
from __future__ import annotations
import asyncio
import math
import time
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple, Set

from .rail_db import (
    RailType, Polarity, JointPoint, RAIL_GEOMETRY_DB, get_auto_search_types,
)

# ---- 定数 ----
GRID_MM = 20.0        # セルサイズ (mm)
GRID_DIM = 90         # 2畳分 = 90 * 20mm = 1800mm
MAX_DIST = 10.0       # 接続許容距離 (mm)
MAX_ANGLE = 2.0       # 接続許容角度誤差 (degrees)
TIMEOUT_S = 0.200     # 探索タイムアウト (秒)
BEAM_WIDTH = 6        # ビーム幅
ORIGIN_X = GRID_DIM * GRID_MM / 2   # 900mm
ORIGIN_Y = GRID_DIM * GRID_MM / 2   # 900mm

THEME_PRIORITY: Dict[str, List[RailType]] = {
    "standard": [RailType.CURVE_R, RailType.STRAIGHT, RailType.STRAIGHT_HALF],
    "figure8": [RailType.CROSSING, RailType.CURVE_R, RailType.STRAIGHT],
    "elevated": [
        RailType.INCLINE_START, RailType.INCLINE_END, RailType.INCLINE_MIDDLE,
        RailType.CURVE_R, RailType.STRAIGHT,
    ],
}


@dataclass(slots=True)
class WorldJoint:
    x: float
    y: float
    angle: float
    polarity: Polarity
    z: int


@dataclass
class PlacedRail:
    rail_type: str
    origin_x: float
    origin_y: float
    rotation: float
    z_level: int
    joints: List[WorldJoint] = field(default_factory=list)


@dataclass
class SearchState:
    placed: List[PlacedRail]
    open_joints: List[Tuple[int, WorldJoint]]   # (global_index, joint)
    inventory: Dict[RailType, int]
    mask: List[List[Dict[int, int]]]


def _empty_mask() -> List[List[Dict[int, int]]]:
    return [[{} for _ in range(GRID_DIM)] for _ in range(GRID_DIM)]


def _copy_mask(m: List[List[Dict[int, int]]]) -> List[List[Dict[int, int]]]:
    return [[dict(c) for c in row] for row in m]


def _to_grid(x: float, y: float) -> Tuple[int, int]:
    return (
        max(0, min(GRID_DIM - 1, int(x / GRID_MM))),
        max(0, min(GRID_DIM - 1, int(y / GRID_MM))),
    )


def _mark_segment(
    mask: List[List[Dict[int, int]]],
    x1: float, y1: float,
    x2: float, y2: float,
    z: int,
    is_block: bool,
) -> bool:
    """
    線分をグリッドにマーキング。
    立体交差ルール: Z>0のレールがZ-1のブロック橋脚の直上 → 衝突。
    """
    dist = math.hypot(x2 - x1, y2 - y1)
    steps = max(1, int(dist / (GRID_MM * 0.5)))
    for i in range(steps + 1):
        t = i / steps
        gx, gy = _to_grid(x1 + t * (x2 - x1), y1 + t * (y2 - y1))
        cell = mask[gx][gy]
        if is_block:
            if cell.get(z) == 1:
                return False
            cell[z] = 2
        else:
            if z > 0 and cell.get(z - 1) == 2:
                return False
            if cell.get(z) == 2:
                return False
            cell[z] = 1
    return True


def _transform(j: JointPoint, ox: float, oy: float, rot: float, bz: int) -> WorldJoint:
    r = math.radians(rot)
    c, s = math.cos(r), math.sin(r)
    return WorldJoint(
        x=ox + j.x * c - j.y * s,
        y=oy + j.x * s + j.y * c,
        angle=(rot + j.angle) % 360.0,
        polarity=j.polarity,
        z=bz + j.z_offset,
    )


def _can_connect(a: WorldJoint, b: WorldJoint) -> bool:
    if math.hypot(a.x - b.x, a.y - b.y) > MAX_DIST:
        return False
    if a.polarity == b.polarity:
        return False
    if a.z != b.z:
        return False
    diff = abs(a.angle - b.angle) % 360.0
    err = min(diff, abs(diff - 180.0))
    return err <= MAX_ANGLE


def _try_extend(
    state: SearchState,
    target_idx: int,
    target: WorldJoint,
    rail_type: RailType,
) -> Optional[SearchState]:
    if state.inventory.get(rail_type, 0) <= 0:
        return None
    geom = RAIL_GEOMETRY_DB[rail_type]
    if not geom.joints:
        return None

    for entry_idx, local_j in enumerate(geom.joints):
        # 必要な回転角: (target.angle + 180) - local_j.angle
        rot = (target.angle + 180.0 - local_j.angle) % 360.0
        r = math.radians(rot)
        c, s = math.cos(r), math.sin(r)
        lx, ly = local_j.x, local_j.y
        ox = target.x - (lx * c - ly * s)
        oy = target.y - (lx * s + ly * c)
        bz = target.z

        world_js = [_transform(j, ox, oy, rot, bz) for j in geom.joints]

        # 境界チェック
        if any(not (0 <= wj.x <= GRID_DIM * GRID_MM and 0 <= wj.y <= GRID_DIM * GRID_MM)
               for wj in world_js):
            continue

        # 接続チェック
        if not _can_connect(world_js[entry_idx], target):
            continue

        # 空間マスクチェック
        new_mask = _copy_mask(state.mask)
        p0 = world_js[0]
        ok = True
        for k in range(1, len(world_js)):
            p1 = world_js[k]
            if not _mark_segment(new_mask, p0.x, p0.y, p1.x, p1.y, bz,
                                  rail_type == RailType.BRIDGE_PIER_BLOCK):
                ok = False
                break
            p0 = p1
        if not ok:
            continue

        # 新状態構築
        new_inv = dict(state.inventory)
        new_inv[rail_type] -= 1

        placed = PlacedRail(
            rail_type=rail_type.value,
            origin_x=round(ox, 3),
            origin_y=round(oy, 3),
            rotation=round(rot, 3),
            z_level=bz,
            joints=world_js,
        )

        new_open = [
            (idx, j) for (idx, j) in state.open_joints if idx != target_idx
        ]
        new_rail_base_idx = sum(
            len(p.joints) for p in state.placed
        )
        for ji, wj in enumerate(world_js):
            if ji != entry_idx:
                new_open.append((new_rail_base_idx + ji, wj))

        ns = SearchState(
            placed=state.placed + [placed],
            open_joints=new_open,
            inventory=new_inv,
            mask=new_mask,
        )
        return ns

    return None


def _close_loops(state: SearchState) -> SearchState:
    """開口端点どうしで接続可能なペアを自動的に閉じる"""
    changed = True
    open_j = list(state.open_joints)
    while changed:
        changed = False
        for i in range(len(open_j)):
            for j_ in range(i + 1, len(open_j)):
                if _can_connect(open_j[i][1], open_j[j_][1]):
                    open_j.pop(j_)
                    open_j.pop(i)
                    changed = True
                    break
            if changed:
                break
    return SearchState(state.placed, open_j, state.inventory, state.mask)


def _state_score(s: SearchState) -> float:
    return len(s.placed) - len(s.open_joints) * 0.5


async def _beam_search(
    inventory: Dict[RailType, int],
    theme: str,
) -> Tuple[List[PlacedRail], bool]:
    auto = get_auto_search_types()
    prio = THEME_PRIORITY.get(theme, THEME_PRIORITY["standard"])
    ordered = [t for t in prio if t in auto] + [t for t in auto if t not in prio]
    ordered = [t for t in ordered if inventory.get(t, 0) > 0]
    if not ordered:
        return [], False

    # 最初のレールを中央に配置
    first = ordered[0]
    first_geom = RAIL_GEOMETRY_DB[first]
    first_rot = 0.0
    first_joints = [_transform(j, ORIGIN_X, ORIGIN_Y, first_rot, 0) for j in first_geom.joints]

    init_mask = _empty_mask()
    if len(first_joints) >= 2:
        _mark_segment(init_mask, first_joints[0].x, first_joints[0].y,
                      first_joints[-1].x, first_joints[-1].y, 0, False)

    init_inv = dict(inventory)
    init_inv[first] -= 1

    init_placed = PlacedRail(
        rail_type=first.value,
        origin_x=ORIGIN_X, origin_y=ORIGIN_Y,
        rotation=first_rot, z_level=0,
        joints=first_joints,
    )

    init_state = SearchState(
        placed=[init_placed],
        open_joints=[(i, wj) for i, wj in enumerate(first_joints)],
        inventory=init_inv,
        mask=init_mask,
    )
    init_state = _close_loops(init_state)

    if not init_state.open_joints:
        return init_state.placed, True

    beam: List[SearchState] = [init_state]
    best = init_state
    deadline = time.monotonic() + TIMEOUT_S - 0.010

    while beam and time.monotonic() < deadline:
        next_beam: List[SearchState] = []
        for state in beam:
            if not state.open_joints:
                return state.placed, True
            target_idx, target = state.open_joints[0]
            for rt in ordered:
                if time.monotonic() >= deadline:
                    break
                ns = _try_extend(state, target_idx, target, rt)
                if ns is None:
                    continue
                ns = _close_loops(ns)
                if not ns.open_joints:
                    return ns.placed, True
                next_beam.append(ns)
            await asyncio.sleep(0)  # コルーチン協調

        next_beam.sort(key=_state_score, reverse=True)
        beam = next_beam[:BEAM_WIDTH]
        if beam and _state_score(beam[0]) > _state_score(best):
            best = beam[0]

    return best.placed, False


async def search_layout(
    inventory: Dict[str, int],
    theme: str = "standard",
) -> Tuple[List[dict], bool, Dict[str, int]]:
    """
    200msタイムアウト付きレイアウト探索エントリポイント。
    Returns: (placed_rails_as_dicts, is_closed_loop, missing_parts)
    """
    typed_inv: Dict[RailType, int] = {}
    for k, v in inventory.items():
        try:
            typed_inv[RailType(k)] = v
        except ValueError:
            pass

    try:
        placed, closed = await asyncio.wait_for(
            _beam_search(typed_inv, theme),
            timeout=TIMEOUT_S,
        )
    except asyncio.TimeoutError:
        placed, closed = [], False

    placed_dicts = [
        {
            "rail_type": p.rail_type,
            "origin_x": p.origin_x,
            "origin_y": p.origin_y,
            "rotation": p.rotation,
            "z_level": p.z_level,
        }
        for p in placed
    ]

    missing: Dict[str, int] = {}
    if not closed:
        used = {rt: typed_inv.get(rt, 0) - v
                for rt, v in typed_inv.items()}
        remaining_curves = typed_inv.get(RailType.CURVE_R, 0)
        open_count = sum(
            len(p.joints) - 2 + 2  # rough estimate
            for p in placed
        ) // 4 if placed else 4
        if remaining_curves < open_count:
            missing[RailType.CURVE_R.value] = max(1, open_count - remaining_curves)

    return placed_dicts, closed, missing
