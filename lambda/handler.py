import importlib
import json
import logging
import os
import subprocess
import sys
from typing import Any, Dict

import boto3

S3 = boto3.client("s3")

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def _run(cmd: list[str]) -> str:
    logger.info("run: %s", " ".join(cmd))
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        if res.stdout:
            logger.info("stdout: %s", res.stdout.strip())
        if res.stderr:
            logger.info("stderr: %s", res.stderr.strip())
        return res.stdout
    except subprocess.CalledProcessError as e:
        logger.error("cmd failed: %s", " ".join(cmd))
        logger.error("stdout: %s", (e.stdout or "").strip())
        logger.error("stderr: %s", (e.stderr or "").strip())
        raise RuntimeError(
            f"cmd failed: {' '.join(cmd)}\n{e.stdout}\n{e.stderr}"
        ) from e


def lambda_handler(_event: Dict[str, Any], _context: Any) -> Dict[str, Any]:
    try:
        fqdn = os.environ["RADIUS_FQDN"]
        email = os.environ["EMAIL"]
        bucket = os.environ["S3_BUCKET"]
        prefix = os.environ.get("S3_PREFIX", f"{fqdn}/")
        logger.info(
            "env: fqdn=%s bucket=%s prefix=%s email=%s",
            fqdn,
            bucket,
            prefix,
            email,
        )

        # 依存を /opt/python に配置しているため、明示的にパスへ追加
        if "/opt/python" not in sys.path:
            sys.path.append("/opt/python")

        # certbot はモジュールとしてインポートせず、`python -m certbot` で実行する

        # Lambda は /tmp 以外が読み取り専用。certbot の作業/設定/ログを /tmp 配下に置く
        base = os.environ.get("CERTBOT_DIR", "/tmp/letsencrypt")
        config_dir = f"{base}"
        work_dir = f"{base}"
        logs_dir = f"{base}"
        os.makedirs(base, exist_ok=True)
        logger.info("paths: base=%s", base)

        # obtain/renew by invoking certbot internal entrypoint directly
        try:
            mod = importlib.import_module("certbot._internal.main")
            certbot_main = getattr(mod, "main")
        except Exception as import_error:  # noqa: BLE001
            raise RuntimeError(
                "failed to import certbot internal main: " f"{import_error}"
            ) from import_error

        cert_args = [
            "certonly",
            "--dns-route53",
            "--config-dir",
            config_dir,
            "--work-dir",
            work_dir,
            "--logs-dir",
            logs_dir,
            "-d",
            fqdn,
            "-m",
            email,
            "--agree-tos",
            "--non-interactive",
        ]
        logger.info("calling certbot main with args: %s", " ".join(cert_args))
        code = certbot_main(cert_args)
        if code not in (0, None):
            raise RuntimeError(f"certbot exited with code {code}")

        live = f"{base}/live/{fqdn}"
        paths = {
            "server.pem": f"{live}/fullchain.pem",
            "server.key": f"{live}/privkey.pem",
            "ca.pem": f"{live}/chain.pem",
        }

        for key, src in paths.items():
            if not os.path.exists(src):
                # fallback for chain.pem absence
                if key == "ca.pem":
                    src = f"{live}/fullchain.pem"
                else:
                    raise FileNotFoundError(src)
            dest_key = f"{prefix.rstrip('/')}/{key}"
            logger.info("upload: %s -> s3://%s/%s", src, bucket, dest_key)
            with open(src, "rb") as f:
                S3.put_object(Bucket=bucket, Key=dest_key, Body=f.read())

        body = {"message": "cert updated", "fqdn": fqdn}
        return {"statusCode": 200, "body": json.dumps(body)}
    except Exception as e:  # noqa: BLE001 - ハンドラ最終防御
        logger.exception("lambda_handler failed: %s", e)
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)}),
        }
