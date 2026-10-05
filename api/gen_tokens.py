#!/usr/bin/env python3
"""Невалидные JWT для негативных сценариев: usage: gen_tokens.py --secret "$JWT_SECRET"

claims - как в user-service/src/middleware/auth.rs: sub, role, exp.
Печатает expired (срок истёк), foreign (чужой секрет), no_exp (без exp) и
no_session (подпись верна, но сессии в Redis нет). newman.sh подставляет их
через -env-var.
"""
import argparse
import base64
import hashlib
import hmac
import json
import sys
import time


def b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def make(secret: str, sub: str, role: str, exp=None) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    claims = {"sub": sub, "role": role}
    if exp is not None:
        claims["exp"] = exp
    parts = [
        b64(json.dumps(header, separators=(",", ":")).encode()),
        b64(json.dumps(claims, separators=(",", ":")).encode()),
    ]
    signing_input = ".".join(parts).encode()
    signature = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    parts.append(b64(signature))
    return ".".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--secret", required=True,
                        help="JWT_SECRET стенда (тот же, что в docker-compose/.env)")
    parser.add_argument("--sub", default="00000000-0000-0000-0000-000000000000")
    parser.add_argument("--role", default="admin")
    args = parser.parse_args()

    now = int(time.time())
    tokens = {
        "expired": make(args.secret, args.sub, args.role, now - 3600),
        "foreign": make("another-secret-not-used-by-this-stand", args.sub, args.role, now + 3600),
        "no_exp": make(args.secret, args.sub, args.role),
        "no_session": make(args.secret, args.sub, args.role, now + 3600),
    }
    for name, token in tokens.items():
        print("%s=%s" % (name, token))
    return 0


if __name__ == "__main__":
    sys.exit(main())
