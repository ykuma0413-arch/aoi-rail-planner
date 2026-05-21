"""
あおいレールプランナー - Azure Key Vault シークレット注入
本番環境では環境変数の代わりに Key Vault からシークレットを取得する。
ローカル開発時は環境変数にフォールバック。

Key Vault のセットアップ:
  1. az keyvault create --name aoi-rail-kv --resource-group YOUR-RG
  2. az keyvault secret set --vault-name aoi-rail-kv --name AZURE-OPENAI-KEY --value YOUR_KEY
  3. Function App のマネージドIDに Key Vault 読み取り権限を付与:
     az keyvault set-policy --name aoi-rail-kv \
       --object-id $(az functionapp identity show --name YOUR-FUNC --query principalId -o tsv) \
       --secret-permissions get
"""
from __future__ import annotations
import os
import logging
from typing import Optional

logger = logging.getLogger(__name__)

# Key Vault の URL（環境変数 KEYVAULT_URL で設定）
_KEYVAULT_URL = os.getenv("KEYVAULT_URL", "")
_client = None


def _get_kv_client():
    global _client
    if _client is not None:
        return _client
    if not _KEYVAULT_URL:
        return None
    try:
        from azure.keyvault.secrets import SecretClient
        from azure.identity import DefaultAzureCredential
        _client = SecretClient(vault_url=_KEYVAULT_URL, credential=DefaultAzureCredential())
        return _client
    except ImportError:
        logger.warning("azure-keyvault-secrets not installed, using env vars only")
        return None
    except Exception as exc:
        logger.warning("Key Vault client init failed: %s", exc)
        return None


def get_secret(name: str, env_fallback: Optional[str] = None) -> str:
    """
    Key Vault からシークレットを取得する。
    Key Vault が未設定、または取得失敗時は環境変数にフォールバック。

    Key Vault のシークレット名はハイフン区切り（例: AZURE-OPENAI-KEY）
    環境変数名はアンダースコア区切り（例: AZURE_OPENAI_KEY）
    """
    kv_name = name.replace("_", "-")
    client = _get_kv_client()

    if client:
        try:
            secret = client.get_secret(kv_name)
            return secret.value
        except Exception as exc:
            logger.debug("Key Vault get_secret('%s') failed: %s", kv_name, exc)

    # フォールバック: 環境変数
    env_name = env_fallback or name
    value = os.getenv(env_name, "")
    return value


# ---- アプリ全体のシークレット ----

def get_openai_key() -> str:
    return get_secret("AZURE_OPENAI_KEY")

def get_openai_endpoint() -> str:
    return get_secret("AZURE_OPENAI_ENDPOINT")

def get_cosmos_key() -> str:
    return get_secret("COSMOS_KEY")

def get_affiliate_base_url() -> str:
    return get_secret("AFFILIATE_BASE_URL")
