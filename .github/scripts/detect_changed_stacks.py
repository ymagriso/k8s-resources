#!/usr/bin/env python3
"""Determine which OpenTofu infrastructure stacks (GCP / Cloudflare) need to run."""

import os
import subprocess

BOTH_STACKS_PATHS = {
    ".github/workflows/tofu-apply.yml",
    ".github/scripts/detect_changed_stacks.py",
    ".github/scripts/manage-rke2-vms.sh",
}
GCP_SCRIPT_PATHS = {
    ".github/scripts/guard-node-replacement.sh",
    ".github/scripts/bootstrap-cluster.sh",
}
CLOUDFLARE_SCRIPT_PATHS = {
    ".github/scripts/resolve_cloudflare_credentials.py",
    ".github/scripts/verify-cloudflare-token.sh",
    ".github/scripts/import-cloudflare-resources.sh",
}


def get_changed_files(base_sha: str, head_ref: str = "HEAD") -> list[str]:
    """Return list of changed file paths between base_sha and head_ref."""
    return subprocess.check_output(
        ["git", "diff", "--name-only", base_sha, head_ref],
        text=True,
    ).splitlines()


def determine_stacks(
    event: str,
    target: str = "all",
    base_sha: str = "",
    changed_files: list[str] | None = None,
) -> tuple[bool, bool]:
    """Return (run_gcp, run_cloudflare) booleans based on workflow event and changed paths."""
    run_gcp = False
    run_cloudflare = False

    if event == "workflow_dispatch":
        run_gcp = target in ("all", "gcp")
        run_cloudflare = target in ("all", "cloudflare")
        return run_gcp, run_cloudflare

    if not base_sha or base_sha == "0" * 40:
        return True, True

    files = changed_files if changed_files is not None else get_changed_files(base_sha)
    for path in files:
        if path in BOTH_STACKS_PATHS:
            run_gcp = True
            run_cloudflare = True
        elif path in CLOUDFLARE_SCRIPT_PATHS or path.startswith("tofu/cloudflare/"):
            run_cloudflare = True
        elif path in GCP_SCRIPT_PATHS or path.startswith("tofu/"):
            run_gcp = True

    return run_gcp, run_cloudflare


def main() -> None:
    event = os.environ.get("EVENT_NAME", "")
    target = os.environ.get("INPUT_TARGET", "all")
    base_sha = (
        os.environ.get("PR_BASE_SHA", "")
        if event == "pull_request"
        else os.environ.get("PUSH_BEFORE_SHA", "")
    )

    run_gcp, run_cloudflare = determine_stacks(
        event=event,
        target=target,
        base_sha=base_sha,
    )

    print(
        f"Detected stacks -> run_gcp={run_gcp}, run_cloudflare={run_cloudflare}",
        flush=True,
    )
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as out:
            out.write(f"run_gcp={str(run_gcp).lower()}\n")
            out.write(f"run_cloudflare={str(run_cloudflare).lower()}\n")


if __name__ == "__main__":
    main()
