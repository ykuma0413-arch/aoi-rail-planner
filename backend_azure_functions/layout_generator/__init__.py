"""
あおいレールプランナー - Azure Functions エントリポイント
エンドポイント: POST /api/layout_generator
非機能要件:
  - 関数キー認証 (x-functions-key ヘッダー)
  - 簡易IPレートリミット: 1分間に10リクエストまで
  - ウォームアップPingエンドポイント対応
  - Cosmos DB 429エラー時のExponential Backoff
"""
from __future__ import annotations
import json
import os
import time
import uuid
import asyncio
import logging
from collections import defaultdict
from typing import Dict, Tuple

import azure.functions as func

from .algorithm import search_layout
from .evaluator import score_layout, build_comment_seed
from .llm_client import get_llm_comment
from .rail_db import RailType, RAIL_GEOMETRY_DB
from .cosmos_client import save_layout

# ---- レートリミット ----
_rate_store: Dict[str, list] = defaultdict(list)
_RATE_WINDOW = 60   # seconds
_RATE_LIMIT = 10    # requests per window

# ---- アフィリエイトURL ----
_AFFILIATE_BASE = os.getenv("AFFILIATE_BASE_URL", "")
_AMAZON_SEARCH_BASE = "https://www.amazon.co.jp/s?i=toys&k=%E3%81%82%E3%81%8A%E3%81%84%E3%83%AC%E3%83%BC%E3%83%AB+"


app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


def _check_rate_limit(ip: str) -> bool:
    now = time.time()
    timestamps = _rate_store[ip]
    _rate_store[ip] = [t for t in timestamps if now - t < _RATE_WINDOW]
    if len(_rate_store[ip]) >= _RATE_LIMIT:
        return False
    _rate_store[ip].append(now)
    return True


def _affiliate_urls(rail_type_value: str) -> Tuple[str, str]:
    geom = RAIL_GEOMETRY_DB.get(RailType(rail_type_value))
    name = geom.display_name if geom else rail_type_value
    import urllib.parse
    fallback = _AMAZON_SEARCH_BASE + urllib.parse.quote(name)
    primary = _AFFILIATE_BASE + urllib.parse.quote(name) if _AFFILIATE_BASE else fallback
    return primary, fallback


@app.route(route="layout_generator", methods=["POST"])
async def layout_generator(req: func.HttpRequest) -> func.HttpResponse:
    # ウォームアップPing
    if req.method == "GET" or req.params.get("warmup") == "1":
        return func.HttpResponse("ok", status_code=200)

    # IPレートリミット
    ip = req.headers.get("X-Forwarded-For", "unknown").split(",")[0].strip()
    if not _check_rate_limit(ip):
        return func.HttpResponse(
            json.dumps({"error": "rate_limit_exceeded"}),
            status_code=429,
            mimetype="application/json",
        )

    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "invalid_json"}),
            status_code=400,
            mimetype="application/json",
        )

    inventory: Dict[str, int] = {
        item["rail_type"]: item["count"]
        for item in body.get("inventory", [])
        if item.get("count", 0) > 0
    }
    theme: str = body.get("theme", "standard")

    # レイアウト探索
    placed, is_closed, missing_map = await search_layout(inventory, theme)

    is_suggested = not is_closed or len(placed) == 0
    score = score_layout(placed, is_closed, theme)

    # LLMコメント（2秒タイムアウト + フォールバック）
    comment_seed = build_comment_seed(placed, is_closed, theme)
    llm_comment = await get_llm_comment(comment_seed)

    # 不足パーツのアフィリエイトURL解決
    missing_parts = []
    for rt_val, count in missing_map.items():
        try:
            primary, fallback = _affiliate_urls(rt_val)
        except (ValueError, KeyError):
            primary = fallback = ""
        missing_parts.append({
            "rail_type": rt_val,
            "count": count,
            "primary_affiliate_url": primary,
            "fallback_search_url": fallback,
        })

    response = {
        "layout_id": str(uuid.uuid4()),
        "is_suggested_layout": is_suggested,
        "placed_rails": placed,
        "missing_parts": missing_parts,
        "llm_comment": llm_comment,
        "score": score,
    }

    # Cosmos DB に結果を非同期保存（Exponential Backoffリトライ付き、失敗は非致命的）
    asyncio.ensure_future(save_layout(response["layout_id"], {
        "placed_rails": placed,
        "score": score,
        "theme": theme,
        "is_closed": not is_suggested,
    }))

    return func.HttpResponse(
        json.dumps(response, ensure_ascii=False),
        status_code=200,
        mimetype="application/json",
    )


@app.route(route="config", methods=["GET"])
async def get_config(req: func.HttpRequest) -> func.HttpResponse:
    """
    リモートコンフィグエンドポイント。
    1,000MAU超過時に動画広告フラグを有効化。
    """
    mau = int(os.getenv("CURRENT_MAU", "0"))
    config = {
        "affiliate_enabled": True,
        "video_ad_enabled": mau >= 1000,
        "max_inventory": 100,
        "search_timeout_ms": 200,
        "supported_themes": ["standard", "figure8", "elevated"],
        "app_version_required": "1.0.0",
    }
    return func.HttpResponse(
        json.dumps(config),
        status_code=200,
        mimetype="application/json",
    )
