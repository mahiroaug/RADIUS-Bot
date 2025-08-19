#!/usr/bin/env python3
"""
パスワード生成・ハッシュ化ユーティリティ
RADIUS認証用のパスワード管理機能
"""

import hashlib
import logging
import os
import time

try:
    from Crypto.Hash import MD4  # pycryptodome
    _HAS_MD4 = True
except ImportError:  # pragma: no cover
    try:
        from Cryptodome.Hash import MD4  # pycryptodomex
        _HAS_MD4 = True
    except Exception:  # いずれも不可の場合
        _HAS_MD4 = False
import secrets
import string
from typing import Tuple

logger = logging.getLogger(__name__)


def _should_log_secrets() -> bool:
    """環境変数により機密情報をログに出すかを制御"""
    return os.environ.get("RADIUS_DEBUG_LOG_SECRETS", "false").lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def _mask_secret(value: str, keep: int = 2) -> str:
    """機密値をマスクしてログ出力用に整形"""
    if _should_log_secrets():
        return value
    if not value:
        return ""
    if len(value) <= keep:
        return "*" * len(value)
    return "*" * (len(value) - keep) + value[-keep:]


class PasswordManager:
    """RADIUSパスワード管理クラス"""

    # パスワード生成用文字セット（混同しやすい文字を除外）
    CHARSET = string.ascii_letters + string.digits + "!@#$%^&*"
    EXCLUDED_CHARS = "0O1lI"  # 混同しやすい文字を除外

    @classmethod
    def generate_password(cls, length: int = 12) -> str:
        """
        安全なランダムパスワードを生成

        Args:
            length: パスワード長（デフォルト12文字）

        Returns:
            生成されたパスワード
        """
        start_time = time.perf_counter()
        logger.debug(
            "[PasswordManager] generate_password called | "
            "length=%d excluded=%s",
            length,
            cls.EXCLUDED_CHARS,
        )

        # 除外文字を削除した文字セット
        charset = ''.join(
            c for c in cls.CHARSET if c not in cls.EXCLUDED_CHARS)
        logger.debug(
            "[PasswordManager] charset prepared | size=%d "
            "has_lower=%s has_upper=%s has_digit=%s has_symbol=%s",
            len(charset),
            any(c.islower() for c in charset),
            any(c.isupper() for c in charset),
            any(c.isdigit() for c in charset),
            any(c in "!@#$%^&*" for c in charset),
        )

        # 各文字種から最低1文字は含める
        password_chars = [
            secrets.choice(string.ascii_lowercase),
            secrets.choice(string.ascii_uppercase),
            secrets.choice(string.digits),
            secrets.choice("!@#$%^&*")
        ]

        # 残りをランダム生成
        for _ in range(length - 4):
            password_chars.append(secrets.choice(charset))

        # シャッフルして結合
        secrets.SystemRandom().shuffle(password_chars)
        password = ''.join(password_chars)

        elapsed_ms = int((time.perf_counter() - start_time) * 1000)
        logger.debug(
            "[PasswordManager] password generated | length=%d "
            "sample=%s took_ms=%d",
            len(password),
            _mask_secret(password),
            elapsed_ms,
        )
        return password

    @classmethod
    def generate_nt_hash(cls, plain_password: str) -> str:
        """
        MSCHAPv2用のNT-Passwordハッシュを生成

        Args:
            password: 平文パスワード

        Returns:
            NT-Passwordハッシュ（大文字16進数）
        """
        logger.debug(
            "[PasswordManager] generate_nt_hash called | "
            "password_sample=%s",
            _mask_secret(plain_password),
        )
        start_time = time.perf_counter()

        # UTF-16 Little Endianでエンコード
        password_utf16le = plain_password.encode('utf-16le')

        # MD4実装がない環境ではpycryptodomeを使用
        try:
            if _HAS_MD4:
                h = MD4.new()
                h.update(password_utf16le)
                md4_hex = h.hexdigest()
                backend = "pycryptodome"
            else:
                # 一部環境でhashlib.new('md4')が使える場合のフォールバック
                md4_hex = hashlib.new('md4', password_utf16le).hexdigest()
                backend = "hashlib.md4"
        except Exception as e:
            logger.error(
                "[PasswordManager] NT hash generation failed | "
                "backend_has_md4=%s error=%s",
                _HAS_MD4,
                e,
                exc_info=True,
            )
            raise

        nt_upper = md4_hex.upper()
        elapsed_ms = int((time.perf_counter() - start_time) * 1000)
        logger.debug(
            "[PasswordManager] NT hash generated | backend=%s "
            "hash_sample=%s took_ms=%d",
            backend,
            _mask_secret(nt_upper, keep=6),
            elapsed_ms,
        )
        return nt_upper

    @classmethod
    def generate_user_credentials(cls, length: int = 12) -> Tuple[str, str]:
        """
        ユーザー認証情報を生成（パスワード + NTハッシュ）

        Args:
            length: パスワード長

        Returns:
            (平文パスワード, NT-Passwordハッシュ) のタプル
        """
        gen_password = cls.generate_password(length)
        gen_nt_hash = cls.generate_nt_hash(gen_password)
        logger.debug(
            "[PasswordManager] credentials generated | password_sample=%s "
            "hash_sample=%s",
            _mask_secret(gen_password),
            _mask_secret(gen_nt_hash, keep=6),
        )
        return gen_password, gen_nt_hash


# テスト用関数
if __name__ == "__main__":
    # パスワード生成テスト
    password = PasswordManager.generate_password()
    nt_hash = PasswordManager.generate_nt_hash(password)

    print(f"Generated Password: {password}")
    print(f"NT-Hash: {nt_hash}")
    print(f"Password Length: {len(password)}")

    # 複数回生成して重複チェック
    passwords = [PasswordManager.generate_password() for _ in range(10)]
    print(f"Generated 10 passwords, unique count: {len(set(passwords))}")
