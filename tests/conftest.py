# -*- coding: utf-8 -*-
"""
pytest ブートストラップ。

テスト雛形(test_geometry.py)は `from rail_db import ...` /
`from algorithm import ...` という素のモジュール名で import する想定のため、
実体である backend_azure_functions/layout_generator パッケージを
モジュールエイリアスとして登録する（テスト側の import 文は書き換えない）。
"""
import pathlib
import sys

_BACKEND = pathlib.Path(__file__).resolve().parents[1] / "backend_azure_functions"
sys.path.insert(0, str(_BACKEND))

from layout_generator import algorithm, rail_db  # noqa: E402

sys.modules["rail_db"] = rail_db
sys.modules["algorithm"] = algorithm
