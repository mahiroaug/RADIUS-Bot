#!/usr/bin/env python3
"""
簡単なテスト用Bot - デバッグ用
"""

import logging
import os

from dotenv import load_dotenv
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Slack App初期化
app = App(token=os.environ.get("SLACK_BOT_TOKEN"))


@app.command("/radius_test")
def handle_radius_test(ack, respond, command):
    """テスト用コマンド"""
    logger.info("radius_test command received")
    ack()
    respond("✅ 簡単なテストコマンド動作中！")


if __name__ == "__main__":
    handler = SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"])
    logger.info("🚀 Simple Test Bot starting...")
    handler.start()
