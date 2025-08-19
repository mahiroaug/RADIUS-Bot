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

echo "✅ DevContainer setup completed!"
echo ""
echo "Next steps:"
echo "1. Copy .env.sample to .env and configure Slack tokens"
echo "2. Create Slack App with Socket Mode enabled"
echo "3. Run: docker-compose up -d --build (to start all services)"
echo "4. Check logs: docker-compose logs -f bot"
