#!/bin/bash
# DevContainer post-create setup script

set -e

echo "🚀 Setting up RADIUS Slack Bot development environment..."

# Update pip and install Python packages
echo "📦 Installing Python packages (project deps + dev tools)..."
python3 -m pip install --upgrade pip

# Project dependencies (includes pycryptodomex)
python3 -m pip install -r bot/requirements.txt

# Dev tools for lint/format/test
python3 -m pip install pytest black flake8 isort pylint

# ngrok不要（Socket Mode使用）

# Lambda deps for local linting (boto3, etc.)
if [ -f "lambda/requirements.txt" ]; then
    echo "🧩 Installing lambda requirements for local linting..."
    python3 -m pip install -r lambda/requirements.txt || true
fi

# Certbot + Route53 プラグイン（DNS-01 用）
echo "🔐 Installing Certbot + Route53 plugin for DNS-01..."
if command -v apt-get >/dev/null 2>&1; then
    # use sudo when not running as root
    SUDO=""
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            echo "⚠️ sudo が無く、rootでもありません。certbotの自動インストールをスキップします。" >&2
            exit 0
        fi
    fi
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -y
    $SUDO apt-get install -y certbot python3-certbot-dns-route53
    if command -v certbot >/dev/null 2>&1; then
        echo "certbot: $(certbot --version)"
        certbot plugins 2>/dev/null | grep -qi route53 && \
          echo "✅ Route53 plugin detected" || echo "⚠️ Route53 plugin not found"
    fi
else
    echo "⚠️ apt-get がありません。ベースイメージに合わせて certbot と dns-route53 プラグインを手動導入してください。"
fi

echo "✅ DevContainer setup completed!"
echo ""
echo "Next steps:"
echo "1. Copy .env.sample to .env and configure Slack tokens"
echo "2. Create Slack App with Socket Mode enabled"
echo "3. Run: docker-compose up -d --build (to start all services)"
echo "4. Check logs: docker-compose logs -f bot"
