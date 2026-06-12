# -*- coding: utf-8 -*-
"""
Android 署名用 PKCS12 キーストア生成（JDK 不要、cryptography ライブラリ使用）
実行: python tools/make_keystore.py
出力:
  upload-keystore.p12       (キーストア本体 — git 管理外)
  keystore-password.txt     (パスワード     — git 管理外)
※ 紛失すると同じ署名でアプリ更新ができなくなる。安全な場所にバックアップすること。
"""
import datetime
import secrets
import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization.pkcs12 import (
    serialize_key_and_certificates,
)
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).parent.parent
KS_PATH = ROOT / "upload-keystore.p12"
PW_PATH = ROOT / "keystore-password.txt"
ALIAS = b"upload"
VALID_DAYS = 10000  # Play 要件 (2033年以降まで有効) を満たす約27年


def main() -> None:
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    if KS_PATH.exists():
        print(f"[SKIP] keystore already exists: {KS_PATH}")
        print("       (再生成すると既存の署名と互換性がなくなるため中断)")
        return

    password = secrets.token_urlsafe(24)

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "Aoi Rail Planner Upload Key"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Aoi Rail Planner"),
        x509.NameAttribute(NameOID.COUNTRY_NAME, "JP"),
    ])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=VALID_DAYS))
        .sign(key, hashes.SHA256())
    )

    p12 = serialize_key_and_certificates(
        name=ALIAS,
        key=key,
        cert=cert,
        cas=None,
        encryption_algorithm=serialization.BestAvailableEncryption(
            password.encode()),
    )

    KS_PATH.write_bytes(p12)
    PW_PATH.write_text(password, encoding="utf-8")

    print(f"[OK] keystore : {KS_PATH}  ({len(p12)} bytes)")
    print(f"[OK] password : {PW_PATH}")
    print(f"     alias    : {ALIAS.decode()}")
    print()
    print("次の手順:")
    print("  1. gh secret set KEYSTORE_BASE64 < (base64エンコードした p12)")
    print("  2. gh secret set KEYSTORE_PASSWORD < keystore-password.txt")
    print("  3. upload-keystore.p12 と keystore-password.txt を安全な場所にバックアップ")


if __name__ == "__main__":
    main()
