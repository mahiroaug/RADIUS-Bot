#!/usr/bin/env bash
set -euo pipefail

# Lambda（コンテナイメージ）のビルド・ECRプッシュ・デプロイを行うスクリプト
# 前提：AWS CLI v2 / Docker が利用可能、認証済み（aws sts get-caller-identity が成功すること）
#
# 必須/任意の環境変数
#   LAMBDA_FUNCTION_NAME   必須: デプロイ対象の Lambda 関数名
#   AWS_REGION             任意: リージョン（未指定時は `aws configure get region` を使用）
#   ECR_REPO               任意: ECR リポジトリ名（デフォルト: radius-certbot-lambda）
#   IMAGE_TAG              任意: イメージタグ（デフォルト: git の短SHA もしくは日付）
#   LAMBDA_ROLE_ARN        任意: 関数が未作成だった場合の作成に使用する IAM Role ARN
#   MEMORY_SIZE            任意: 新規作成時のメモリ(MB)（デフォルト: 512）
#   TIMEOUT                任意: 新規作成時のタイムアウト(秒)（デフォルト: 900）
#   ARCHITECTURE           任意: 新規作成時のアーキテクチャ（x86_64 or arm64、デフォルト: x86_64）
#   DOCKERFILE_PATH        任意: Dockerfile のパス（デフォルト: lambda/Dockerfile）
#   CONTEXT_DIR            任意: Docker ビルドコンテキスト（デフォルト: lambda）
#   
#   以下は Lambda の環境変数として設定（指定があるもののみ反映）
#   RADIUS_FQDN, EMAIL, S3_BUCKET, S3_PREFIX

usage() {
  cat <<'USAGE'
使い方:
  環境変数を設定して実行してください。

  必須:
    LAMBDA_FUNCTION_NAME  デプロイ対象の Lambda 関数名

  例:
    LAMBDA_FUNCTION_NAME=radius-certbot \
    AWS_REGION=ap-northeast-1 \
    ECR_REPO=radius-certbot-lambda \
    IMAGE_TAG=$(date +%Y%m%d-%H%M%S) \
    RADIUS_FQDN=radius.example.com \
    EMAIL=admin@example.com \
    S3_BUCKET=my-cert-bucket \
    S3_PREFIX=radius/ \
    bash scripts/prod/deploy_lambda_image.sh

  新規作成（関数が未作成）の場合は LAMBDA_ROLE_ARN も指定してください:
    LAMBDA_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/<LambdaExecutionRole>
USAGE
}

command -v aws >/dev/null 2>&1 || { echo "[ERROR] aws CLI が見つかりません"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker が見つかりません"; exit 1; }

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage; exit 0
fi

# .env ロード（KEY=VALUE / export KEY=VALUE の行のみを抽出して評価）
ENV_FILE=${ENV_FILE:-.env}
if [[ -f "${ENV_FILE}" ]]; then
  echo "[STEP] 環境ファイルを読み込みます: ${ENV_FILE}"
  TMP_ENV=$(mktemp)
  # コメント/空行を除外し、export 付き/無しの KEY=VALUE 形式だけを抽出
  # 例外: `.env` 内の任意コマンド（例: bash 実行行）は無視される
  awk 'BEGIN{IGNORECASE=0} \
      /^[[:space:]]*#/ {next} \
      /^[[:space:]]*$/ {next} \
      /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/ {print} \
  ' "${ENV_FILE}" > "${TMP_ENV}"
  set -a
  # shellcheck disable=SC1090
  . "${TMP_ENV}"
  set +a
  rm -f "${TMP_ENV}"
fi

LAMBDA_FUNCTION_NAME=${LAMBDA_FUNCTION_NAME:-}
if [[ -z "${LAMBDA_FUNCTION_NAME}" ]]; then
  echo "[ERROR] LAMBDA_FUNCTION_NAME を指定してください"; usage; exit 1
fi

AWS_REGION=${AWS_REGION:-$(aws configure get region || true)}
if [[ -z "${AWS_REGION}" ]]; then
  echo "[ERROR] AWS_REGION を指定するか、aws configure で region を設定してください"; exit 1
fi

ECR_REPO=${ECR_REPO:-radius-certbot-lambda}
DOCKERFILE_PATH=${DOCKERFILE_PATH:-lambda/Dockerfile}
CONTEXT_DIR=${CONTEXT_DIR:-lambda}
MEMORY_SIZE=${MEMORY_SIZE:-512}
TIMEOUT=${TIMEOUT:-900}
ARCHITECTURE=${ARCHITECTURE:-x86_64}
BUILD_PLATFORM=${BUILD_PLATFORM:-linux/amd64}

# IMAGE_TAG は git の短SHA、なければ日時
if [[ -z "${IMAGE_TAG:-}" ]]; then
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    IMAGE_TAG=$(git rev-parse --short HEAD)
  else
    IMAGE_TAG=$(date +%Y%m%d-%H%M%S)
  fi
fi

echo "[INFO] Region: ${AWS_REGION}"
echo "[INFO] ECR Repo: ${ECR_REPO}"
echo "[INFO] Image Tag: ${IMAGE_TAG}"
echo "[INFO] Function: ${LAMBDA_FUNCTION_NAME}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

echo "[STEP] ECR リポジトリ存在確認/作成"
if ! aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "${ECR_REPO}" --image-scanning-configuration scanOnPush=true --region "${AWS_REGION}" >/dev/null
  echo "[INFO] ECR リポジトリを作成しました: ${ECR_REPO}"
else
  echo "[INFO] ECR リポジトリは既に存在します: ${ECR_REPO}"
fi

echo "[STEP] ECR ログイン"
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "[STEP] Docker ビルド: ${DOCKERFILE_PATH} (context=${CONTEXT_DIR}, platform=${BUILD_PLATFORM})"
docker build --platform "${BUILD_PLATFORM}" -t "${ECR_REPO}:${IMAGE_TAG}" -f "${DOCKERFILE_PATH}" "${CONTEXT_DIR}"

echo "[STEP] Docker タグ付け"
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"

echo "[STEP] Docker プッシュ"
docker push "${ECR_URI}:${IMAGE_TAG}"

echo "[STEP] Lambda 関数の存在確認"
if aws lambda get-function --function-name "${LAMBDA_FUNCTION_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "[STEP] 既存関数のコード更新"
  aws lambda update-function-code \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --image-uri "${ECR_URI}:${IMAGE_TAG}" \
    --region "${AWS_REGION}" \
    --output text --query 'LastUpdateStatus'

  echo "[STEP] 反映完了待ち"
  aws lambda wait function-updated --function-name "${LAMBDA_FUNCTION_NAME}" --region "${AWS_REGION}"
else
  echo "[STEP] 関数が存在しないため新規作成します"
  if [[ -z "${LAMBDA_ROLE_ARN:-}" ]]; then
    echo "[ERROR] 新規作成には LAMBDA_ROLE_ARN が必要です"; exit 1
  fi
  # --architectures が未対応の AWS CLI 環境では省略する（x86_64 がデフォルト）
  CREATE_ARGS=(
    --function-name "${LAMBDA_FUNCTION_NAME}"
    --package-type Image
    --code ImageUri="${ECR_URI}:${IMAGE_TAG}"
    --role "${LAMBDA_ROLE_ARN}"
    --timeout "${TIMEOUT}"
    --memory-size "${MEMORY_SIZE}"
    --region "${AWS_REGION}"
  )
  if aws lambda create-function help 2>&1 | grep -q -- "--architectures"; then
    CREATE_ARGS+=(--architectures "${ARCHITECTURE}")
  else
    echo "[INFO] この AWS CLI は --architectures 未対応のため省略します（デフォルト: x86_64）"
  fi
  aws lambda create-function "${CREATE_ARGS[@]}" >/dev/null
fi

# 指定されている環境変数だけを Lambda に反映
declare -a KV
[[ -n "${RADIUS_FQDN:-}" ]] && KV+=("RADIUS_FQDN=${RADIUS_FQDN}")
[[ -n "${EMAIL:-}" ]]        && KV+=("EMAIL=${EMAIL}")
[[ -n "${S3_BUCKET:-}" ]]    && KV+=("S3_BUCKET=${S3_BUCKET}")
[[ -n "${S3_PREFIX:-}" ]]    && KV+=("S3_PREFIX=${S3_PREFIX}")

if (( ${#KV[@]} > 0 )); then
  # 既存の環境変数を維持しつつ上書きするために一旦取得してマージする
  echo "[STEP] 環境変数を更新します"
  # 既存値の取得（空や未設定でも安全に扱えるように text で取得）
  EXISTING=$(aws lambda get-function-configuration \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --region "${AWS_REGION}" \
    --query 'Environment.Variables' --output json || echo '{}')

  # jq がある場合は既存変数とマージし、--cli-input-json で投入
  if command -v jq >/dev/null 2>&1; then
    TMP=$(mktemp)
    printf '%s\n' "${EXISTING}" >"${TMP}"
    for pair in "${KV[@]}"; do
      key="${pair%%=*}"; val="${pair#*=}"
      jq --arg k "$key" --arg v "$val" '.[$k]=$v' "${TMP}" >"${TMP}.new" && mv "${TMP}.new" "${TMP}"
    done
    MERGED=$(cat "${TMP}")
    rm -f "${TMP}"
    PAYLOAD=$(mktemp)
    # {"FunctionName":"...","Environment":{"Variables":{...}}}
    jq -n --arg fn "${LAMBDA_FUNCTION_NAME}" --argjson vars "${MERGED}" '{FunctionName:$fn, Environment:{Variables:$vars}}' >"${PAYLOAD}"
    aws lambda update-function-configuration --cli-input-json file://"${PAYLOAD}" --region "${AWS_REGION}" >/dev/null
    rm -f "${PAYLOAD}"
  else
    # jq が無い環境では shorthand 形式で指定分のみ上書き
    joined=$(IFS=, ; echo "${KV[*]}")
    aws lambda update-function-configuration \
      --function-name "${LAMBDA_FUNCTION_NAME}" \
      --region "${AWS_REGION}" \
      --environment "Variables={${joined}}" >/dev/null
  fi
fi

echo "[DONE] Lambda デプロイが完了しました: ${LAMBDA_FUNCTION_NAME} (${ECR_URI}:${IMAGE_TAG})"


