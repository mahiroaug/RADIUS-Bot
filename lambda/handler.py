import json
import os
import subprocess
from typing import Any, Dict

import boto3

S3 = boto3.client("s3")


def _run(cmd: list[str]) -> str:
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return res.stdout
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"cmd failed: {' '.join(cmd)}\n{e.stdout}\n{e.stderr}"
        ) from e


def lambda_handler(_event: Dict[str, Any], _context: Any) -> Dict[str, Any]:
    fqdn = os.environ["RADIUS_FQDN"]
    email = os.environ["EMAIL"]
    bucket = os.environ["S3_BUCKET"]
    prefix = os.environ.get("S3_PREFIX", f"{fqdn}/")

    # obtain/renew
    _run([
        "certbot",
        "certonly",
        "--dns-route53",
        "-d",
        fqdn,
        "-m",
        email,
        "--agree-tos",
        "--non-interactive",
    ])

    live = f"/etc/letsencrypt/live/{fqdn}"
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
        with open(src, "rb") as f:
            S3.put_object(Bucket=bucket, Key=dest_key, Body=f.read())

    body = {"message": "cert updated", "fqdn": fqdn}
    return {"statusCode": 200, "body": json.dumps(body)}
