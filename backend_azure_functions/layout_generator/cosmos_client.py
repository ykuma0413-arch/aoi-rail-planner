"""
あおいレールプランナー - Cosmos DB クライアント
429エラー時の Exponential Backoff 自動リトライ実装。
最大リトライ回数: 5回
初期待機時間: 200ms → 最大 6.4秒 (2^5 * 200ms)
"""
from __future__ import annotations
import asyncio
import os
import logging
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

from .secrets import get_cosmos_key

_COSMOS_ENDPOINT = os.getenv("COSMOS_ENDPOINT", "")
_COSMOS_KEY: str = ""  # 起動時に遅延取得

def _get_cosmos_key() -> str:
    global _COSMOS_KEY
    if not _COSMOS_KEY:
        _COSMOS_KEY = get_cosmos_key() or os.getenv("COSMOS_KEY", "")
    return _COSMOS_KEY
_COSMOS_DB = os.getenv("COSMOS_DB", "aoi_rail_db")
_COSMOS_CONTAINER = os.getenv("COSMOS_CONTAINER", "layouts")

_MAX_RETRIES = 5
_BASE_DELAY_S = 0.200  # 200ms


async def _with_exponential_backoff(coro_fn, *args, **kwargs) -> Any:
    """
    Cosmos DB 操作を Exponential Backoff でラップする汎用ラッパー。
    429 (TooManyRequests) および 503 (ServiceUnavailable) 時にリトライ。
    """
    last_exc: Optional[Exception] = None
    for attempt in range(_MAX_RETRIES + 1):
        try:
            return await coro_fn(*args, **kwargs)
        except Exception as exc:
            last_exc = exc
            status = getattr(exc, "status_code", None) or getattr(exc, "error_code", None)

            # 429: レート超過 / 503: 一時的な障害
            if status in (429, 503) and attempt < _MAX_RETRIES:
                # Retry-After ヘッダーを優先、なければ指数的後退
                retry_after = getattr(exc, "retry_after_ms", None)
                if retry_after is not None:
                    wait = retry_after / 1000.0
                else:
                    wait = _BASE_DELAY_S * (2 ** attempt)

                logger.warning(
                    "Cosmos DB %s error (attempt %d/%d), retrying in %.2fs",
                    status, attempt + 1, _MAX_RETRIES, wait,
                )
                await asyncio.sleep(wait)
            else:
                # リトライ不可能なエラー or 試行上限
                break

    logger.error("Cosmos DB operation failed after %d retries: %s", _MAX_RETRIES, last_exc)
    raise last_exc


async def save_layout(layout_id: str, payload: Dict[str, Any]) -> bool:
    """
    レイアウト結果を Cosmos DB に保存する。
    保存失敗はログに記録し、アプリ動作は継続（ベストエフォート）。
    """
    cosmos_key = _get_cosmos_key()
    if not _COSMOS_ENDPOINT or not cosmos_key:
        return False  # ローカル開発時はスキップ

    try:
        from azure.cosmos.aio import CosmosClient
        from azure.cosmos.exceptions import CosmosHttpResponseError

        async def _upsert():
            async with CosmosClient(_COSMOS_ENDPOINT, cosmos_key) as client:
                db = client.get_database_client(_COSMOS_DB)
                container = db.get_container_client(_COSMOS_CONTAINER)
                await container.upsert_item({
                    "id": layout_id,
                    **payload,
                })

        await _with_exponential_backoff(_upsert)
        return True

    except Exception as exc:
        logger.error("save_layout failed (non-critical): %s", exc)
        return False  # 保存失敗はサイレント継続


async def get_layout(layout_id: str) -> Optional[Dict[str, Any]]:
    """Cosmos DB からレイアウトを取得する"""
    cosmos_key = _get_cosmos_key()
    if not _COSMOS_ENDPOINT or not cosmos_key:
        return None

    try:
        from azure.cosmos.aio import CosmosClient

        async def _read():
            async with CosmosClient(_COSMOS_ENDPOINT, cosmos_key) as client:
                db = client.get_database_client(_COSMOS_DB)
                container = db.get_container_client(_COSMOS_CONTAINER)
                return await container.read_item(item=layout_id, partition_key=layout_id)

        return await _with_exponential_backoff(_read)

    except Exception as exc:
        logger.warning("get_layout failed: %s", exc)
        return None
