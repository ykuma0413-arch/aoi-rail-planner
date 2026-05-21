"""
あおいレールプランナー - Azure OpenAI クライアント
2.0秒HTTPタイムアウト + サイレントフォールバック実装。
"""
from __future__ import annotations
import os
import httpx

from .secrets import get_openai_key, get_openai_endpoint

def _get_endpoint() -> str:
    return get_openai_endpoint() or os.getenv("AZURE_OPENAI_ENDPOINT", "")

def _get_api_key() -> str:
    return get_openai_key() or os.getenv("AZURE_OPENAI_KEY", "")

_DEPLOYMENT = os.getenv("AZURE_OPENAI_DEPLOYMENT", "gpt-4o-mini")
_API_VERSION = "2024-02-01"
_HTTP_TIMEOUT = 2.0  # 障害時フォールバックのためのHTTPタイムアウト

_FALLBACK_COMMENTS = [
    "すごいレイアウトができたよ！",
    "かっこいいコースだね！",
    "電車が走るのが楽しみだね！",
    "おもしろいレールの形だね！",
    "上手にできました！",
]
_fallback_index = 0


async def get_llm_comment(prompt: str) -> str:
    """
    LLM短評コメントを取得する。
    Azure OpenAIが2秒以内に応答しない場合は定型文をサイレント返却。
    """
    global _fallback_index

    endpoint = _get_endpoint()
    api_key = _get_api_key()

    if not endpoint or not api_key:
        return _cycle_fallback()

    url = (
        f"{endpoint}/openai/deployments/{_DEPLOYMENT}"
        f"/chat/completions?api-version={_API_VERSION}"
    )
    payload = {
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 60,
        "temperature": 0.7,
    }

    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT) as client:
            resp = await client.post(
                url,
                json=payload,
                headers={"api-key": api_key, "Content-Type": "application/json"},
            )
            resp.raise_for_status()
            data = resp.json()
            return data["choices"][0]["message"]["content"].strip()
    except Exception:
        # LLM障害時: サイレントフォールバック（エラーを上位に伝播させない）
        return _cycle_fallback()


def _cycle_fallback() -> str:
    global _fallback_index
    msg = _FALLBACK_COMMENTS[_fallback_index % len(_FALLBACK_COMMENTS)]
    _fallback_index += 1
    return msg
