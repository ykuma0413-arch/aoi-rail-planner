"""
バックエンドアルゴリズムのローカルテスト（Azure Functions 不要）
実行: python test_algorithm.py
"""
import asyncio
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from layout_generator.algorithm import search_layout


async def main():
    test_cases = [
        {
            "name": "基本オーバル（直線8本 + カーブ16本）",
            "inventory": {"straight": 8, "curve_r": 16},
            "theme": "standard",
        },
        {
            "name": "8の字（交差レール使用）",
            "inventory": {"straight": 8, "curve_r": 16, "crossing": 1},
            "theme": "figure8",
        },
        {
            "name": "立体交差（勾配レール使用）",
            "inventory": {
                "straight": 6,
                "curve_r": 16,
                "incline_start": 1,
                "incline_middle": 2,
                "incline_end": 1,
            },
            "theme": "elevated",
        },
        {
            "name": "在庫不足（カーブ4本のみ）",
            "inventory": {"curve_r": 4},
            "theme": "standard",
        },
    ]

    for case in test_cases:
        print(f"\n{'='*50}")
        print(f"テスト: {case['name']}")
        placed, is_closed, missing = await search_layout(
            case["inventory"], case["theme"]
        )
        print(f"  配置レール数 : {len(placed)}")
        print(f"  ループ閉鎖  : {'✅ 完成' if is_closed else '❌ 未完成'}")
        if missing:
            print(f"  不足パーツ  : {missing}")
        if placed:
            types = {}
            for r in placed:
                types[r["rail_type"]] = types.get(r["rail_type"], 0) + 1
            print(f"  使用内訳    : {types}")


if __name__ == "__main__":
    asyncio.run(main())
