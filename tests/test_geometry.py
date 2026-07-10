"""
幾何整合性・生成ロジックのテストスイート雛形。

実際のモジュール構成に合わせて import 部分を書き換えて使用してください。
想定: rail_db.py に RAIL_GEOMETRY_DB / RailType、algorithm.py に _Walker、
     course生成関数(例: generate_course)が存在する構成。

このテストの目的は「見た目が良いか」ではなく「機械的に合否判定できるか」。
LOOPはこのテストのpass/failのみを見て反復するので、閾値は最初に固めておくこと。
"""

import math
import pytest

# --- 実プロジェクトに合わせて書き換える ---
from rail_db import RAIL_GEOMETRY_DB, RailType  # noqa: F401
from algorithm import _Walker, generate_course  # noqa: F401

CLOSED_LOOP_POS_TOLERANCE_MM = 10.0
CLOSED_LOOP_ANGLE_TOLERANCE_DEG = 2.0
MIN_GRID_MM = 20.0  # no_self_intersection 判定グリッド


# ============================================================
# A. パーツ定義の単一性(rail_db と algorithm の二重定義解消の検証)
# ============================================================

class TestSingleSourceOfTruth:
    """
    _Walker が rail_db.RAIL_GEOMETRY_DB の値をそのまま使っているか。
    独自の角度・長さを再定義していないかを検証する。
    """

    @pytest.mark.parametrize("rail_type", list(RailType))
    def test_walker_uses_rail_db_geometry(self, rail_type):
        db_entry = RAIL_GEOMETRY_DB[rail_type]
        walker_entry = _Walker.geometry_for(rail_type)  # 実装側に合わせて調整

        assert walker_entry.move_vector == pytest.approx(
            db_entry.move_vector, abs=0.5
        ), f"{rail_type}: moveVectorがrail_dbと不一致。二重定義が疑われる"

        assert walker_entry.turn_degrees == pytest.approx(
            db_entry.turn_degrees, abs=0.1
        ), f"{rail_type}: turnDegreesがrail_dbと不一致。二重定義が疑われる"


# ============================================================
# B. 生成ロジック
# ============================================================

class TestCourseGeneration:

    def test_generated_course_is_closed_loop(self):
        course = generate_course(seed=1)
        walker = _Walker.from_course(course)

        assert walker.position_error_mm() < CLOSED_LOOP_POS_TOLERANCE_MM, (
            "終端位置が始端と一致していない(ループが閉じていない)"
        )
        assert walker.angle_error_deg() < CLOSED_LOOP_ANGLE_TOLERANCE_DEG, (
            "終端の向きが始端と一致していない(ループが閉じていない)"
        )

    def test_generated_course_has_no_self_intersection(self):
        course = generate_course(seed=1)
        walker = _Walker.from_course(course)
        assert walker.no_self_intersection(grid_mm=MIN_GRID_MM)

    def test_generation_succeeds_repeatedly(self):
        """B4相当: 生成が安定して成功するか"""
        failures = []
        for seed in range(10):
            try:
                course = generate_course(seed=seed)
                walker = _Walker.from_course(course)
                if walker.position_error_mm() >= CLOSED_LOOP_POS_TOLERANCE_MM:
                    failures.append((seed, "not_closed"))
            except Exception as e:  # noqa: BLE001
                failures.append((seed, str(e)))
        assert not failures, f"生成失敗: {failures}"

    def test_piece_variety_across_generations(self):
        """
        「毎回同じようなコースになる」問題の回帰テスト。
        複数回生成した際に使われるパーツ種別に十分なばらつきがあるか。
        """
        used_types = set()
        for seed in range(20):
            course = generate_course(seed=seed)
            for piece in course.pieces:
                used_types.add(piece.rail_type)

        total_types = len(list(RailType))
        # 分岐など意図的に除外されたものを除いた種類数を分母にすること
        assert len(used_types) >= total_types * 0.6, (
            f"使用されたパーツ種別が少なすぎる({len(used_types)}/{total_types})。"
            "生成ロジックのバリエーション不足の可能性"
        )