"""
あおいレールプランナー - レールマスターデータベース
実測値に基づく幾何学定義（単位: mm）。
"""
from __future__ import annotations
from enum import Enum
from dataclasses import dataclass, field
from typing import List, Dict
import math


class RailType(Enum):
    STRAIGHT = "straight"
    STRAIGHT_HALF = "straight_half"
    CURVE_R = "curve_r"
    CURVE_R_LARGE = "curve_r_large"
    INCLINE_START = "incline_start"
    INCLINE_MIDDLE = "incline_middle"
    INCLINE_END = "incline_end"
    CROSSING = "crossing"
    SWITCH_LEFT = "switch_left"
    SWITCH_RIGHT = "switch_right"
    BRIDGE_PIER_STANDARD = "bridge_pier_standard"
    BRIDGE_PIER_BLOCK = "bridge_pier_block"
    # 自動探索除外パーツ（在庫登録は許容）
    FLEXIBLE = "flexible"
    STRAIGHT_DOUBLE = "straight_double"


class Polarity(Enum):
    MALE = "male"
    FEMALE = "female"


@dataclass
class JointPoint:
    """レール端点（ジョイント先端座標基準）"""
    x: float          # レール原点からの相対X (mm)
    y: float          # レール原点からの相対Y (mm)
    angle: float      # ジョイント外向き方向 (degrees, 0=右, CCW+)
    polarity: Polarity
    z_offset: int = 0


@dataclass
class RailGeometry:
    rail_type: RailType
    joints: List[JointPoint]
    height_change: int = 0
    excluded_from_auto: bool = False
    display_name: str = ""


# ---- 実測値定数 ----
_S = 106.0          # 直線レール長さ
_S2 = 53.0          # 直線ハーフ
_R = 103.0          # 標準カーブ半径
_RL = 206.0         # 大カーブ半径
_DA = 22.5          # 1ピースあたりの角度 (16個で360°)


def _curve_exit(radius: float, angle_deg: float) -> tuple[float, float]:
    a = math.radians(angle_deg)
    return radius * math.sin(a), radius * (1.0 - math.cos(a))


_cx_r, _cy_r = _curve_exit(_R, _DA)
_cx_rl, _cy_rl = _curve_exit(_RL, _DA)

RAIL_GEOMETRY_DB: Dict[RailType, RailGeometry] = {
    RailType.STRAIGHT: RailGeometry(
        rail_type=RailType.STRAIGHT,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE),
            JointPoint(_S, 0.0, 0.0, Polarity.MALE),
        ],
        display_name="直線レール",
    ),
    RailType.STRAIGHT_HALF: RailGeometry(
        rail_type=RailType.STRAIGHT_HALF,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE),
            JointPoint(_S2, 0.0, 0.0, Polarity.MALE),
        ],
        display_name="直線レール（ハーフ）",
    ),
    RailType.CURVE_R: RailGeometry(
        rail_type=RailType.CURVE_R,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE),
            JointPoint(_cx_r, _cy_r, _DA, Polarity.MALE),
        ],
        display_name="曲線レール（R）",
    ),
    RailType.CURVE_R_LARGE: RailGeometry(
        rail_type=RailType.CURVE_R_LARGE,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE),
            JointPoint(_cx_rl, _cy_rl, _DA, Polarity.MALE),
        ],
        display_name="大カーブレール",
    ),
    RailType.INCLINE_START: RailGeometry(
        rail_type=RailType.INCLINE_START,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE, z_offset=0),
            JointPoint(_S, 0.0, 0.0, Polarity.MALE, z_offset=1),
        ],
        height_change=1,
        display_name="勾配開始レール",
    ),
    RailType.INCLINE_MIDDLE: RailGeometry(
        rail_type=RailType.INCLINE_MIDDLE,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE, z_offset=0),
            JointPoint(_S, 0.0, 0.0, Polarity.MALE, z_offset=0),
        ],
        display_name="勾配中間レール",
    ),
    RailType.INCLINE_END: RailGeometry(
        rail_type=RailType.INCLINE_END,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE, z_offset=1),
            JointPoint(_S, 0.0, 0.0, Polarity.MALE, z_offset=0),
        ],
        height_change=-1,
        display_name="勾配終了レール",
    ),
    RailType.CROSSING: RailGeometry(
        rail_type=RailType.CROSSING,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE),
            JointPoint(_S, 0.0, 0.0, Polarity.MALE),
            JointPoint(_S / 2, -_S / 2, 270.0, Polarity.FEMALE),
            JointPoint(_S / 2, _S / 2, 90.0, Polarity.MALE),
        ],
        display_name="交差レール",
    ),
    RailType.SWITCH_LEFT: RailGeometry(
        rail_type=RailType.SWITCH_LEFT,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE),
            JointPoint(_S, 0.0, 0.0, Polarity.MALE),
            JointPoint(_cx_r, _cy_r, _DA, Polarity.MALE),
        ],
        display_name="左分岐レール",
    ),
    RailType.SWITCH_RIGHT: RailGeometry(
        rail_type=RailType.SWITCH_RIGHT,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE),
            JointPoint(_S, 0.0, 0.0, Polarity.MALE),
            JointPoint(_cx_r, -_cy_r, -_DA % 360.0, Polarity.MALE),
        ],
        display_name="右分岐レール",
    ),
    RailType.BRIDGE_PIER_STANDARD: RailGeometry(
        rail_type=RailType.BRIDGE_PIER_STANDARD,
        joints=[],
        display_name="橋脚（標準）",
    ),
    RailType.BRIDGE_PIER_BLOCK: RailGeometry(
        rail_type=RailType.BRIDGE_PIER_BLOCK,
        joints=[],
        display_name="橋脚（ブロック）",
    ),
    RailType.FLEXIBLE: RailGeometry(
        rail_type=RailType.FLEXIBLE,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE),
            JointPoint(_S, 0.0, 0.0, Polarity.MALE),
        ],
        excluded_from_auto=True,  # まがレール: 計算量爆発のため除外
        display_name="まがレール",
    ),
    RailType.STRAIGHT_DOUBLE: RailGeometry(
        rail_type=RailType.STRAIGHT_DOUBLE,
        joints=[
            JointPoint(0.0, 0.0, 180.0, Polarity.FEMALE),
            JointPoint(_S * 2, 0.0, 0.0, Polarity.MALE),
        ],
        excluded_from_auto=True,  # 2倍系: 2畳枠制約超過のため除外
        display_name="直線レール（2倍）",
    ),
}


def get_auto_search_types() -> List[RailType]:
    return [
        rt for rt, g in RAIL_GEOMETRY_DB.items()
        if not g.excluded_from_auto and len(g.joints) >= 2
    ]
