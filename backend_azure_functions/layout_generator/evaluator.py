"""
あおいレールプランナー - レイアウトスコアリング
"""
from __future__ import annotations
from typing import List, Dict

from .rail_db import RailType

# 分岐・交差系の特殊パーツ（組み込むほど遊びの幅が広がるためスコアで優遇する）
_SPECIAL_TYPES = frozenset({
    RailType.SWITCH_LEFT.value,
    RailType.SWITCH_RIGHT.value,
    RailType.SWITCH_Y.value,
    RailType.AUTO_TURNOUT.value,
    RailType.CROSSING.value,
    RailType.CROSS_POINT.value,
})


def score_layout(placed: List[dict], is_closed: bool, theme: str) -> float:
    """
    0.0〜1.0のスコアを返す。
    """
    if not placed:
        return 0.0

    piece_count = len(placed)
    piece_score = min(piece_count / 20.0, 1.0) * 0.3

    closure_score = 0.35 if is_closed else 0.0

    z_levels = {p["z_level"] for p in placed}
    variety_score = min(len(z_levels) / 3.0, 1.0) * 0.1

    types_used = {p["rail_type"] for p in placed}
    type_score = min(len(types_used) / 4.0, 1.0) * 0.1

    special_count = sum(1 for p in placed if p["rail_type"] in _SPECIAL_TYPES)
    special_score = min(special_count / 3.0, 1.0) * 0.15

    return round(piece_score + closure_score + variety_score
                 + type_score + special_score, 3)


def build_comment_seed(placed: List[dict], is_closed: bool, theme: str) -> str:
    """LLMへのプロンプトシード文を生成する"""
    count = len(placed)
    z_levels = sorted({p["z_level"] for p in placed})
    has_height = len(z_levels) > 1

    height_text = "立体交差あり" if has_height else "平面レイアウト"
    closed_text = "ループが完成しています" if is_closed else "未完成のレイアウトです"

    return (
        f"テーマ「{theme}」、{count}ピース、{height_text}、{closed_text}。"
        "子どもが喜ぶ短いコメントを日本語30字以内で生成してください。"
        "おもちゃの電車の会社名やブランド名は含めないでください。"
    )
