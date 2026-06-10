# -*- coding: utf-8 -*-
"""v2 テンプレートエンジンの検証スクリプト"""
import asyncio
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from layout_generator.algorithm import search_layout


async def main():
    cases = [
        ('curve16 standard', {'curve_r': 16}, 'standard'),
        ('curve16+str8 standard', {'straight': 8, 'curve_r': 16}, 'standard'),
        ('curve16+str8 wide', {'straight': 8, 'curve_r': 16}, 'elevated'),
        ('compact', {'straight': 8, 'curve_r': 16, 'straight_half': 4}, 'figure8'),
        ('mixed 14std+2lg', {'curve_r': 14, 'curve_r_large': 2, 'straight': 4}, 'standard'),
        ('insufficient curve8', {'curve_r': 8, 'straight': 10}, 'standard'),
        ('zero', {}, 'standard'),
        ('many 50/50', {'straight': 50, 'curve_r': 50}, 'standard'),
    ]
    all_ok = True
    for name, inv, theme in cases:
        placed, closed, missing = await search_layout(inv, theme)
        tag = 'OK' if closed else 'NG'
        print(f'[{tag}] {name:28s} rails={len(placed):3d} closed={closed} missing={missing}')
        if placed:
            xs = [p['origin_x'] for p in placed]
            ys = [p['origin_y'] for p in placed]
            in_area = 0 <= min(xs) and max(xs) <= 1800 and 0 <= min(ys) and max(ys) <= 1800
            print(f'     bbox x:[{min(xs):.0f},{max(xs):.0f}] y:[{min(ys):.0f},{max(ys):.0f}] in_area={in_area}')
            if not in_area:
                all_ok = False

    print()
    print('variety check (same inventory, 4 runs):')
    shapes = set()
    for i in range(4):
        placed, closed, _ = await search_layout({'straight': 10, 'curve_r': 16}, 'standard')
        n_str = sum(1 for p in placed if p['rail_type'] == 'straight')
        rot0 = placed[0]['rotation'] if placed else -1
        shapes.add((n_str, rot0))
        print(f'  run{i+1}: total={len(placed)} straights={n_str} initial_rot={rot0}')
    print(f'  distinct shapes: {len(shapes)} (>=2 expected)')

    # 16カーブのときの必勝性: 100回連続で閉じるか
    fails = 0
    for _ in range(100):
        _, closed, _ = await search_layout({'straight': 6, 'curve_r': 16}, 'standard')
        if not closed:
            fails += 1
    print(f'\nclosure guarantee: 100 runs, failures={fails} (0 expected)')
    sys.exit(0 if fails == 0 and all_ok else 1)


asyncio.run(main())
