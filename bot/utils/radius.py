#!/usr/bin/env python3
"""
FreeRADIUS管理ユーティリティ
authorizeファイルの安全な読み書き機能
"""

import logging
import os
import re
import threading
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .password import PasswordManager

logger = logging.getLogger(__name__)


class RadiusManager:
    """FreeRADIUS管理クラス"""

    def __init__(self, authorize_file_path: str = "/radius/authorize"):
        """
        初期化

        Args:
            authorize_file_path: authorizeファイルのパス
        """
        self.authorize_file_path = Path(authorize_file_path)
        # 再入可能ロックにすることで、ロック内からget_user等を呼んでもデッドロックしない
        self._lock = threading.RLock()
        logger.debug(
            "[RadiusManager] initialized | path=%s exists=%s",
            self.authorize_file_path,
            self.authorize_file_path.exists(),
        )

    def _read_authorize_file(self) -> List[str]:
        """
        authorizeファイルを読み込み

        Returns:
            ファイルの行リスト
        """
        try:
            with open(self.authorize_file_path, 'r', encoding='utf-8') as rf:
                lines = rf.readlines()
                logger.debug(
                    "[RadiusManager] read authorize | path=%s lines=%d "
                    "bytes≈%d",
                    self.authorize_file_path,
                    len(lines),
                    sum(len(x) for x in lines),
                )
                return lines
        except FileNotFoundError:
            logger.warning(
                "[RadiusManager] authorize not found, treating as empty | "
                "path=%s",
                self.authorize_file_path,
            )
            return []

    def _write_authorize_file(self, lines: List[str]) -> None:
        """
        authorizeファイルに書き込み（アトミック操作）

        Args:
            lines: 書き込む行のリスト
        """
        # 一時ファイルに書き込み後、アトミックに置き換え
        temp_file = self.authorize_file_path.with_suffix('.tmp')

        try:
            with open(temp_file, 'w', encoding='utf-8') as tmpf:
                tmpf.writelines(lines)
            logger.debug(
                "[RadiusManager] wrote temp authorize | temp=%s lines=%d",
                temp_file,
                len(lines),
            )

            # アトミックに置き換え
            temp_file.replace(self.authorize_file_path)
            logger.info(
                "[RadiusManager] authorize updated atomically | path=%s "
                "size_bytes=%d",
                self.authorize_file_path,
                sum(len(x) for x in lines),
            )
        except OSError as e:
            # EBUSYなどでリネームできない環境向けフォールバック
            import errno
            if getattr(e, 'errno', None) == errno.EBUSY:
                logger.warning(
                    "[RadiusManager] atomic replace failed with EBUSY. "
                    "Falling back to direct write | path=%s",
                    self.authorize_file_path,
                )
                try:
                    with open(
                        self.authorize_file_path, 'w', encoding='utf-8'
                    ) as wf:
                        wf.writelines(lines)
                    logger.info(
                        "[RadiusManager] authorize updated by direct write | "
                        "path=%s size_bytes=%d",
                        self.authorize_file_path,
                        sum(len(x) for x in lines),
                    )
                finally:
                    if temp_file.exists():
                        temp_file.unlink(missing_ok=True)
            else:
                if temp_file.exists():
                    temp_file.unlink()
                logger.error(
                    "[RadiusManager] failed to write authorize | path=%s "
                    "error=%s",
                    self.authorize_file_path,
                    e,
                    exc_info=True,
                )
                raise

    def _sanitize_lines(self, lines: List[str]) -> List[str]:
        """
        孤立したインデント行（ユーザーやDEFAULTヘッダに紐づかない属性行）を除去。
        ついでに連続する空行を1つに圧縮。

        Args:
            lines: 現在のauthorize行群

        Returns:
            サニタイズ後の行群
        """
        sanitized: List[str] = []
        inside_header = False
        prev_blank = False

        for raw in lines:
            if raw.startswith('\t') or raw.startswith(' '):
                if not inside_header:
                    # 孤立した属性行はスキップ
                    continue
                sanitized.append(raw)
                prev_blank = False
                continue

            # 非インデント行
            stripped = raw.strip()
            if stripped == "":
                if prev_blank:
                    # 空行を圧縮
                    continue
                sanitized.append(raw)
                prev_blank = True
                inside_header = False
                continue

            sanitized.append(raw)
            prev_blank = False
            # コメント行はヘッダ開始扱いにしない
            inside_header = not stripped.startswith('#')

        return sanitized

    def sanitize_file(self) -> bool:
        """authorizeファイルをサニタイズして更新（変更があった場合のみ書込）。"""
        lines = self._read_authorize_file()
        sanitized = self._sanitize_lines(lines)
        if sanitized != lines:
            logger.info(
                "[RadiusManager] sanitize_file detected junk; rewriting file"
            )
            self._write_authorize_file(sanitized)
            return True
        return False

    def _find_user_blocks(
        self, lines: List[str], username: str
    ) -> List[Tuple[int, int]]:
        """
        指定ユーザーの全ブロック(start,end)を返す。endは排他的インデックス。
        ヘッダ行(ユーザー行)と、直後のインデント行(属性行)を含める。
        """
        pattern = re.compile(rf"^{re.escape(username)}\s")
        blocks: List[Tuple[int, int]] = []
        i = 0
        while i < len(lines):
            line = lines[i]
            if pattern.match(line):
                start = i
                j = i + 1
                while j < len(lines):
                    if lines[j].startswith('\t') or lines[j].startswith(' '):
                        j += 1
                        continue
                    break
                blocks.append((start, j))
                i = j
                continue
            i += 1
        return blocks

    def _parse_user_entry(
        self, lines: List[str], start_idx: int
    ) -> Tuple[Dict, int]:
        """
        ユーザーエントリをパース

        Args:
            lines: ファイルの行リスト
            start_idx: ユーザーエントリの開始行

        Returns:
            (ユーザー情報辞書, 次の行のインデックス) のタプル
        """
        if start_idx >= len(lines):
            return {}, start_idx

        raw_line = lines[start_idx]
        # インデントされた属性行はスキップ（ユーザー行ではない）
        if raw_line.startswith('\t') or raw_line.startswith(' '):
            return {}, start_idx + 1

        line = raw_line.strip()
        if not line or line.startswith('#'):
            return {}, start_idx + 1

        # ユーザー行をパース
        parts = line.split()
        if len(parts) < 3:
            return {}, start_idx + 1

        username = parts[0]
        user_info = {
            'username': username,
            'line_start': start_idx,
            'attributes': {}
        }

        # 属性をパース
        if 'NT-Password' in line:
            nt_hash = line.split('"')[1] if '"' in line else ""
            user_info['attributes']['NT-Password'] = nt_hash
        elif 'Cleartext-Password' in line:
            password = line.split('"')[1] if '"' in line else ""
            user_info['attributes']['Cleartext-Password'] = password

        # 次の行を確認（Reply-Message等）
        next_idx = start_idx + 1
        while next_idx < len(lines):
            next_line = lines[next_idx].strip()
            if (not next_line.startswith('\t') and
                    not next_line.startswith(' ')):
                break
            if 'Reply-Message' in next_line:
                reply_msg = next_line.split('"')[1] if '"' in next_line else ""
                user_info['attributes']['Reply-Message'] = reply_msg
            next_idx += 1

        user_info['line_end'] = next_idx - 1
        logger.debug(
            "[RadiusManager] parsed entry | user=%s attrs=%s "
            "range=[%d,%d]",
            user_info.get('username'),
            list(user_info.get('attributes', {}).keys()),
            user_info.get('line_start'),
            user_info.get('line_end'),
        )
        return user_info, next_idx

    def get_user(self, username: str) -> Optional[Dict]:
        """
        ユーザー情報を取得

        Args:
            username: ユーザー名

        Returns:
            ユーザー情報辞書（存在しない場合はNone）
        """
        with self._lock:
            logger.debug(
                "[RadiusManager] get_user called | user=%s",
                username,
            )
            lines = self._read_authorize_file()

            i = 0
            while i < len(lines):
                user_info, next_i = self._parse_user_entry(lines, i)
                if user_info and user_info['username'] == username:
                    logger.debug(
                        "[RadiusManager] user found | user=%s",
                        username,
                    )
                    return user_info
                i = next_i

            logger.debug(
                "[RadiusManager] user not found | user=%s",
                username,
            )
            return None

    def list_users(self) -> List[Dict]:
        """
        全ユーザー一覧を取得

        Returns:
            ユーザー情報辞書のリスト
        """
        with self._lock:
            logger.info("[RadiusManager] list_users")
            lines = self._read_authorize_file()
            entries = []

            i = 0
            while i < len(lines):
                user_info, next_i = self._parse_user_entry(lines, i)
                if user_info:
                    entries.append(user_info)
                i = next_i

            return entries

    def add_user(
        self, username: str, password: str = None, nt_hash: str = None
    ) -> Tuple[str, str]:
        """
        ユーザーを追加

        Args:
            username: ユーザー名
            password: 平文パスワード（指定時はNTハッシュ生成）
            nt_hash: NTハッシュ（直接指定）

        Returns:
            (生成されたパスワード, NTハッシュ) のタプル
        """
        with self._lock:
            # 既存ユーザーチェック
            if self.get_user(username):
                raise ValueError(f"User '{username}' already exists")

            # パスワード生成またはハッシュ化
            if password is None:
                password, nt_hash = PasswordManager.generate_user_credentials()
            elif nt_hash is None:
                nt_hash = PasswordManager.generate_nt_hash(password)

            # ファイル読み込み + サニタイズ
            lines = self._read_authorize_file()
            lines = self._sanitize_lines(lines)

            # ユーザーエントリを追加
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            new_entry = [
                f"\n# User added: {timestamp}\n",
                f"{username}\tNT-Password := \"{nt_hash}\"\n",
                f"\tReply-Message := \"Welcome {username}\"\n\n",
            ]

            # ファイル末尾に追加
            lines.extend(new_entry)

            # ファイル書き込み
            self._write_authorize_file(lines)
            logger.info(
                "[RadiusManager] user added | user=%s nt_hash_sample=%s",
                username,
                (nt_hash[:6] + "…") if nt_hash else "***",
            )

            return password, nt_hash

    def update_user_password(
        self, username: str, new_password: str = None
    ) -> Tuple[str, str]:
        """
        ユーザーパスワードを更新

        Args:
            username: ユーザー名
            new_password: 新しいパスワード（未指定時は自動生成）

        Returns:
            (新しいパスワード, NTハッシュ) のタプル
        """
        with self._lock:
            # ユーザー存在確認
            logger.info(
                "[RadiusManager] update_user_password | user=%s",
                username,
            )
            user_info = self.get_user(username)
            if not user_info:
                raise ValueError(f"User '{username}' not found")

            # パスワード生成
            if new_password is None:
                new_password, new_nt_hash = (
                    PasswordManager.generate_user_credentials()
                )
            else:
                new_nt_hash = PasswordManager.generate_nt_hash(new_password)

            # ファイル読み込み + サニタイズ
            lines = self._read_authorize_file()
            lines = self._sanitize_lines(lines)

            # 既存の同一ユーザーの全ブロックを削除
            blocks = self._find_user_blocks(lines, username)
            if blocks:
                adjusted: List[Tuple[int, int]] = []
                for (start, end) in blocks:
                    s = start
                    while s > 0:
                        prev = lines[s - 1].strip()
                        if prev == '' or prev.startswith('#'):
                            s -= 1
                            continue
                        break
                    adjusted.append((s, end))
                for s, e in sorted(adjusted, key=lambda x: x[0], reverse=True):
                    del lines[s:e]

            # 新しいエントリを末尾に1ブロック追加
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            new_entry = [
                f"# Password updated: {timestamp}\n",
                f"{username}\tNT-Password := \"{new_nt_hash}\"\n",
                f"\tReply-Message := \"Welcome {username}\"\n",
                "\n",
            ]
            lines.extend(new_entry)

            # サニタイズ（空行圧縮など）
            lines = self._sanitize_lines(lines)

            # ファイル書き込み
            self._write_authorize_file(lines)
            logger.info(
                "[RadiusManager] password updated | user=%s",
                username,
            )

            return new_password, new_nt_hash

    def delete_user(self, username: str) -> bool:
        """
        ユーザーを削除

        Args:
            username: ユーザー名

        Returns:
            削除成功時True、ユーザーが存在しない場合False
        """
        with self._lock:
            # ユーザー存在確認
            logger.info("[RadiusManager] delete_user | user=%s", username)
            user_info = self.get_user(username)
            if not user_info:
                return False

            # ファイル読み込み + サニタイズ
            lines = self._read_authorize_file()
            lines = self._sanitize_lines(lines)

            # 指定ユーザーの全ブロックを検出
            blocks = self._find_user_blocks(lines, username)
            if not blocks:
                logger.warning(
                    "[RadiusManager] delete_user: no blocks found | user=%s",
                    username,
                )
                return False

            # 直前の履歴コメント/空行も削除対象に含めて全て削除（後ろから）
            adjusted: List[Tuple[int, int]] = []
            for (start, end) in blocks:
                s = start
                while s > 0:
                    prev = lines[s - 1].strip()
                    if prev == '' or prev.startswith('#'):
                        s -= 1
                        continue
                    break
                adjusted.append((s, end))

            for s, e in sorted(adjusted, key=lambda x: x[0], reverse=True):
                del lines[s:e]

            # サニタイズで空行圧縮
            lines = self._sanitize_lines(lines)

            # ファイル書き込み
            self._write_authorize_file(lines)
            logger.info(
                "[RadiusManager] user deleted | user=%s",
                username,
            )

            return True


# テスト用関数
if __name__ == "__main__":
    # テスト用の一時ファイル
    import tempfile

    with tempfile.NamedTemporaryFile(
        mode='w+', delete=False, suffix='.authorize'
    ) as f:
        f.write("# Test authorize file\n\n")
        test_file = f.name

    try:
        radius = RadiusManager(test_file)

        # ユーザー追加テスト
        password, nt_hash = radius.add_user("testuser")
        print("Added user: testuser")
        print(f"Password: {password}")
        print(f"NT-Hash: {nt_hash}")

        # ユーザー取得テスト
        user_info = radius.get_user("testuser")
        print(f"User info: {user_info}")

        # ユーザー一覧テスト
        users = radius.list_users()
        print(f"All users: {[u['username'] for u in users]}")

    finally:
        # テストファイル削除
        os.unlink(test_file)
