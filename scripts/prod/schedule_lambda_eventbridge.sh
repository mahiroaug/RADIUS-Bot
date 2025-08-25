#!/usr/bin/env bash
set -euo pipefail

# Lambda を EventBridge で定期実行させる設定スクリプト
# 前提: AWS CLI v1/v2 が利用可能、認証済み (aws sts get-caller-identity が通る)
#
# 必須環境変数/引数:
#   FUNCTION_NAME   対象 Lambda 関数名
#   AWS_REGION      リージョン (例: ap-northeast-1)
#   ACCOUNT_ID      アカウントID (自動取得可)
#   RULE_NAME       ルール名 (例: radius-certbot-daily)
#   CRON            スケジュール式 (例: cron(10 18 * * ? *))
# 任意:
#   PAYLOAD_JSON    ターゲットへ渡す JSON (例: '{"action":"run"}')
#   ENV_FILE        .env ファイルパス（デフォルト: .env）
#
# 使い方:
#   ACTION=apply \
#   FUNCTION_NAME=radius-web3sst-certbot AWS_REGION=ap-northeast-1 \
#   RULE_NAME=radius-certbot-daily CRON='cron(10 18 * * ? *)' \
#   bash scripts/prod/schedule_lambda_eventbridge.sh
#
# サブコマンド:
#   ACTION=apply    ルール作成/更新 + 権限付与 + ターゲット設定
#   ACTION=disable  ルールを一時停止
#   ACTION=enable   ルールを有効化
#   ACTION=delete   ターゲット削除 + ルール削除 + 権限削除

ACTION=${ACTION:-apply}

command -v aws >/dev/null 2>&1 || { echo "[ERROR] aws CLI が見つかりません"; exit 1; }

# .env ロード（KEY=VALUE / export KEY=VALUE のみ）
ENV_FILE=${ENV_FILE:-.env}
if [[ -f "$ENV_FILE" ]]; then
  echo "[STEP] 環境ファイルを読み込みます: $ENV_FILE"
  TMP_ENV=$(mktemp)
  awk 'BEGIN{IGNORECASE=0} \
      /^[[:space:]]*#/ {next} \
      /^[[:space:]]*$/ {next} \
      /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/ {print} \
  ' "$ENV_FILE" > "$TMP_ENV"
  set -a
  # shellcheck disable=SC1090
  . "$TMP_ENV"
  set +a
  rm -f "$TMP_ENV"
fi

# パラメータ取得
FUNCTION_NAME=${FUNCTION_NAME:-${LAMBDA_FUNCTION_NAME:-}}
AWS_REGION=${AWS_REGION:-$(aws configure get region || true)}
ACCOUNT_ID=${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}
RULE_NAME=${RULE_NAME:-}
CRON=${CRON:-}
PAYLOAD_JSON=${PAYLOAD_JSON:-}

if [[ -z "$FUNCTION_NAME" || -z "$AWS_REGION" || -z "$RULE_NAME" ]]; then
  echo "[ERROR] 必須: FUNCTION_NAME, AWS_REGION, RULE_NAME"; exit 1
fi

LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
RULE_ARN="arn:aws:events:${AWS_REGION}:${ACCOUNT_ID}:rule/${RULE_NAME}"

case "$ACTION" in
  apply)
    if [[ -z "$CRON" ]]; then
      echo "[ERROR] ACTION=apply では CRON が必須です"; exit 1
    fi

    echo "[STEP] ルール作成/更新: ${RULE_NAME} (${CRON})"
    aws events put-rule \
      --name "${RULE_NAME}" \
      --schedule-expression "${CRON}" \
      --region "${AWS_REGION}" >/dev/null

    echo "[STEP] Lambda 実行許可(EventBridge→Lambda)を付与"
    # 既存の同一 statement-id があれば一旦削除
    if aws lambda get-policy --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" 2>/dev/null | grep -q "${RULE_NAME}-invoke"; then
      aws lambda remove-permission \
        --function-name "${FUNCTION_NAME}" \
        --statement-id "${RULE_NAME}-invoke" \
        --region "${AWS_REGION}" >/dev/null || true
    fi
    aws lambda add-permission \
      --function-name "${FUNCTION_NAME}" \
      --statement-id "${RULE_NAME}-invoke" \
      --action lambda:InvokeFunction \
      --principal events.amazonaws.com \
      --source-arn "${RULE_ARN}" \
      --region "${AWS_REGION}" >/dev/null

    echo "[STEP] ターゲット登録"
    if [[ -n "$PAYLOAD_JSON" ]]; then
      aws events put-targets \
        --rule "${RULE_NAME}" \
        --targets "Id"="1","Arn"="${LAMBDA_ARN}","Input"='"'${PAYLOAD_JSON//'"'/\"}'"' \
        --region "${AWS_REGION}" >/dev/null
    else
      aws events put-targets \
        --rule "${RULE_NAME}" \
        --targets "Id"="1","Arn"="${LAMBDA_ARN}" \
        --region "${AWS_REGION}" >/dev/null
    fi

    echo "[DONE] スケジュールを適用しました: ${RULE_NAME} -> ${FUNCTION_NAME}"
    ;;

  disable)
    echo "[STEP] ルールを無効化: ${RULE_NAME}"
    aws events disable-rule --name "${RULE_NAME}" --region "${AWS_REGION}" >/dev/null
    echo "[DONE] 無効化しました"
    ;;

  enable)
    echo "[STEP] ルールを有効化: ${RULE_NAME}"
    aws events enable-rule --name "${RULE_NAME}" --region "${AWS_REGION}" >/dev/null
    echo "[DONE] 有効化しました"
    ;;

  delete)
    echo "[STEP] ターゲット削除"
    aws events remove-targets --rule "${RULE_NAME}" --ids "1" --region "${AWS_REGION}" >/dev/null || true

    echo "[STEP] ルール削除"
    aws events delete-rule --name "${RULE_NAME}" --region "${AWS_REGION}" >/dev/null || true

    echo "[STEP] Lambda 実行許可を削除"
    aws lambda remove-permission \
      --function-name "${FUNCTION_NAME}" \
      --statement-id "${RULE_NAME}-invoke" \
      --region "${AWS_REGION}" >/dev/null || true

    echo "[DONE] 削除しました"
    ;;

  *)
    echo "[ERROR] 不明な ACTION: ${ACTION} (apply|disable|enable|delete)"; exit 1 ;;
esac


