#!/usr/bin/env python3
"""
RADIUS + Slack連携 Bot - Socket Mode版
Socket Mode接続でngrok/HTTPS不要
"""

import logging
import os
import time

from dotenv import load_dotenv
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler
from utils.radius import RadiusManager

# 環境変数読み込み
load_dotenv()

# ログ設定（詳細ログ有効化）
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def _should_log_secrets() -> bool:
    return os.environ.get("RADIUS_DEBUG_LOG_SECRETS", "false").lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def _mask_secret(value: str, keep: int = 2) -> str:
    if _should_log_secrets():
        return value
    if not value:
        return ""
    if len(value) <= keep:
        return "*" * len(value)
    return "*" * (len(value) - keep) + value[-keep:]


# Slack Boltのログも詳細化
slack_logger = logging.getLogger("slack_bolt")
slack_logger.setLevel(logging.DEBUG)

# RADIUS管理インスタンス（安全な初期化）
radius_manager = None
try:
    radius_manager = RadiusManager("/app/radius/authorize")
    logger.info("✅ RadiusManager initialized successfully")
except Exception as e:
    logger.error(f"❌ RadiusManager initialization failed: {e}", exc_info=True)
    # 初期化に失敗してもBotは起動する（機能制限あり）

# Slack App初期化（Socket Mode）
app = App(
    token=os.environ.get("SLACK_BOT_TOKEN"),
    # Socket ModeではSigning Secret不要
)


@app.command("/radius_help")
def handle_radius_help(ack, respond, command):
    """RADIUS Botヘルプコマンド"""
    ack()
    help_text = """
🔐 **RADIUS Bot ヘルプ**

利用可能なコマンド:
• `/radius_help` - このヘルプを表示
• `/radius_register` - RADIUSアカウントを作成
• `/radius_resetpass` - パスワードをリセット
• `/radius_status` - アカウント状態を確認
• `/radius_unregister` - アカウントを削除

⚠️ **注意**: すべてのコマンドはDMでのみ利用可能です
    """
    respond(help_text)


@app.command("/radius_register")
def handle_radius_register(ack, respond, command):
    """RADIUSアカウント登録"""
    logger.info("radius_register command received")
    # 即時応答（Slackに必ず表示させる）
    try:
        ack("⌛ 登録処理を開始します…")
    except Exception as e:
        logger.error(f"ack failed: {e}")
    try:
        logger.info(f"Command data: {command}")
        user_id = command.get('user_id', 'unknown')
        logger.info(f"User ID: {user_id}")

        # RADIUS管理インスタンスの確認
        if radius_manager is None:
            respond("❌ RADIUS管理システムが利用できません。")
            return

        # 既存ユーザーチェック
        username = f"user_{user_id}"
        existing_user = radius_manager.get_user(username)
        if existing_user:
            respond("❌ 既にRADIUSアカウントが登録されています。")
            return

        # アカウント作成
        logger.debug("[App] add_user start | user=%s", username)
        start_ms = time.perf_counter()
        password, nt_hash = radius_manager.add_user(username)
        took_ms = int((time.perf_counter() - start_ms) * 1000)
        logger.info(
            "[App] add_user done | user=%s took_ms=%d "
            "pwd_sample=%s hash_sample=%s",
            username,
            took_ms,
            _mask_secret(password),
            _mask_secret(nt_hash, keep=6),
        )

        # 成功メッセージ
        success_message = f"""✅ **RADIUSアカウント作成完了**

**ユーザー名**: `{username}`
**パスワード**: `{password}`

⚠️ **重要**: 
• パスワードは安全に保管してください
• 802.1X認証設定で上記の認証情報を使用してください

📝 **設定方法**: 
1. 有線LAN設定で802.1X認証を選択
2. ユーザー名とパスワードを入力
3. 認証方式: PEAP/MSCHAPv2"""

        # 通常はrespondで返信
        try:
            respond(success_message)
        except Exception as e:
            logger.error(f"respond failed, trying chat_postMessage: {e}")
            try:
                app.client.chat_postMessage(
                    channel=command.get('channel_id'), text=success_message
                )
            except Exception as post_err:
                logger.error(f"chat_postMessage failed: {post_err}")
        logger.info(f"RADIUS account created successfully for user: {user_id}")
    except Exception as e:
        logger.error(f"Register command error: {e}", exc_info=True)
        try:
            respond("❌ RADIUSアカウント登録でエラーが発生しました。")
        except Exception as respond_error:
            logger.error(f"Failed to respond: {respond_error}", exc_info=True)


@app.command("/radius_resetpass")
def handle_radius_resetpass(ack, respond, command):
    """パスワードリセット"""
    # 即時応答
    try:
        ack("⌛ パスワードを再発行しています…")
    except Exception as e:
        logger.error(f"ack failed: {e}")

    try:
        # ユーザー情報取得
        user_id = command['user_id']
        username = f"user_{user_id}"

        # ユーザー存在確認
        user_info = radius_manager.get_user(username)
        if not user_info:
            respond(
                "❌ RADIUSアカウントが見つかりません。"
                "`/radius_register` でアカウントを作成してください。"
            )
            return

        # パスワードリセット
        new_password, _ = radius_manager.update_user_password(username)

        # 成功メッセージ
        success_message = f"""
✅ **パスワードリセット完了**

**ユーザー名**: `{username}`
**新しいパスワード**: `{new_password}`

⚠️ **重要**: 
• 古いパスワードは無効になりました
• 新しいパスワードで802.1X認証を再設定してください
• パスワードは安全に保管してください
        """

        respond(success_message)
        logger.info(f"Reset password for user: {user_id}")

    except Exception as e:
        logger.error(f"Failed to reset password: {e}")
        respond("❌ パスワードリセットに失敗しました。")


@app.command("/radius_status")
def handle_radius_status(ack, respond, command):
    """RADIUSアカウント状態確認"""
    # 即時応答
    try:
        ack("⌛ 状態を確認しています…")
    except Exception as e:
        logger.error(f"ack failed: {e}")

    try:
        # ユーザー情報取得
        user_id = command['user_id']
        username = f"user_{user_id}"

        # ユーザー存在確認
        user_info = radius_manager.get_user(username)
        if not user_info:
            respond(
                "❌ RADIUSアカウントが見つかりません。"
                "`/radius_register` でアカウントを作成してください。"
            )
            return

        # ステータス情報
        status_message = f"""
📊 **RADIUSアカウント状態**

**ユーザー名**: `{username}`
**状態**: ✅ アクティブ
**認証方式**: PEAP/MSCHAPv2 (NT-Password)

💡 **利用可能なコマンド**:
• `/radius_resetpass` - パスワードリセット
• `/radius_unregister` - アカウント削除
        """

        respond(status_message)

    except Exception as e:
        logger.error(f"Failed to get status: {e}")
        respond("❌ ステータス確認に失敗しました。")


@app.command("/radius_unregister")
def handle_radius_unregister(ack, respond, command):
    """RADIUSアカウント削除"""
    # 即時応答
    try:
        ack("⌛ 削除処理を開始します…")
    except Exception as e:
        logger.error(f"ack failed: {e}")

    try:
        # ユーザー情報取得
        user_id = command['user_id']
        username = f"user_{user_id}"

        # ユーザー削除
        success = radius_manager.delete_user(username)
        if not success:
            respond("❌ RADIUSアカウントが見つかりません。")
            return

        # 成功メッセージ
        success_message = """
✅ **RADIUSアカウント削除完了**

アカウントが正常に削除されました。
• 802.1X認証は利用できなくなります
• 再度利用する場合は `/radius_register` でアカウントを作成してください
        """

        respond(success_message)
        logger.info(f"Deleted RADIUS account for user: {user_id}")

    except Exception as e:
        logger.error(f"Failed to delete account: {e}")
        respond("❌ アカウント削除に失敗しました。")


@app.event("app_mention")
def handle_app_mention(event, say):
    """Botがメンションされた時の応答"""
    say(f"こんにちは <@{event['user']}>！`/radius_help` でコマンド一覧を確認できます。")


if __name__ == "__main__":
    # Socket Mode Handler開始
    handler = SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"])
    logger.info("🚀 RADIUS Slack Bot (Socket Mode) starting...")
    handler.start()
