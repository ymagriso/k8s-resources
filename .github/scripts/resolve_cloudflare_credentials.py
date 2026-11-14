#!/usr/bin/env python3
"""Resolve and validate Cloudflare credentials and domain for OpenTofu operations."""

import base64
import json
import os
import sys


def decode_tunnel_token(tunnel_token: str) -> tuple[str, str]:
    """Decode Cloudflare account_id and tunnel_id from a base64 cloudflared tunnel token."""
    padded = tunnel_token + "=" * (-len(tunnel_token) % 4)
    payload = json.loads(base64.b64decode(padded).decode("utf-8"))
    account_id = str(payload.get("a", "")).strip()
    tunnel_id = str(payload.get("t", "")).strip()
    return account_id, tunnel_id


def resolve_credentials(env: dict[str, str]) -> tuple[dict[str, str], list[str]]:
    """Resolve Cloudflare credentials from environment variables and return (resolved_dict, missing_list)."""
    api_token = env.get("RAW_API_TOKEN", "").strip()
    tunnel_token = env.get("RAW_TUNNEL_TOKEN", "").strip()
    account_id = env.get("RAW_ACCOUNT_ID", "").strip()
    tunnel_id = env.get("RAW_TUNNEL_ID", "").strip()
    domain = env.get("RAW_DOMAIN", "").strip()

    if (not account_id or not tunnel_id) and tunnel_token:
        try:
            decoded_acct, decoded_tun = decode_tunnel_token(tunnel_token)
            if not account_id:
                account_id = decoded_acct
            if not tunnel_id:
                tunnel_id = decoded_tun
        except Exception as exc:
            print(
                f"::warning::Unable to decode account/tunnel IDs from CLOUDFLARED_TUNNEL_TOKEN: {exc}",
                flush=True,
            )

    missing = []
    if not api_token:
        missing.append("CLOUDFLARE_TUNNEL_API_TOKEN (or CLOUDFLARE_API_TOKEN)")
    if not account_id:
        missing.append("CLOUDFLARE_ACCOUNT_ID (or valid CLOUDFLARED_TUNNEL_TOKEN)")
    if not tunnel_id:
        missing.append("CLOUDFLARE_TUNNEL_ID (or valid CLOUDFLARED_TUNNEL_TOKEN)")
    if not domain:
        missing.append("CUSTOM_DOMAIN")

    resolved = {
        "CLOUDFLARE_API_TOKEN": api_token,
        "TF_VAR_account_id": account_id,
        "TF_VAR_tunnel_id": tunnel_id,
        "TF_VAR_domain": domain,
    }
    return resolved, missing


def main() -> None:
    resolved, missing = resolve_credentials(dict(os.environ))
    if missing:
        print(
            "::error::Missing required GitHub Secrets: " + ", ".join(missing),
            flush=True,
        )
        sys.exit(1)

    print(f"::add-mask::{resolved['TF_VAR_account_id']}", flush=True)
    print(f"::add-mask::{resolved['TF_VAR_tunnel_id']}", flush=True)
    print(f"::add-mask::{resolved['TF_VAR_domain']}", flush=True)

    github_env = os.environ.get("GITHUB_ENV")
    if github_env:
        with open(github_env, "a", encoding="utf-8") as env_file:
            for key, val in resolved.items():
                env_file.write(f"{key}={val}\n")


if __name__ == "__main__":
    main()
