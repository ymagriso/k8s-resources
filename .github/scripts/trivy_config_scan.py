#!/usr/bin/env python3
"""Run Trivy IaC/Kubernetes configuration scan and generate a Markdown summary."""

import json
import os
import subprocess

SKIP_DIRS = {".git", ".github", "docs", ".terraform"}


def get_scanned_dirs(root_dir: str = ".", skip_dirs: set[str] = SKIP_DIRS) -> list[str]:
    """Return formatted list of top-level directories scanned by Trivy."""
    return sorted(
        f"`{d}/`"
        for d in os.listdir(root_dir)
        if os.path.isdir(os.path.join(root_dir, d))
        and d not in skip_dirs
        and not d.startswith(".")
    )


def run_trivy_config(
    target_dir: str = ".",
    sarif_output: str = "trivy-config.sarif",
    json_output: str = "trivy-config.json",
    skip_dirs: set[str] = SKIP_DIRS,
) -> None:
    """Execute Trivy config scan producing both SARIF and JSON reports."""
    skip_arg = ",".join(sorted(skip_dirs))
    print("Running Trivy IaC & Kubernetes manifest misconfiguration scan...", flush=True)

    for fmt, out_file in (("sarif", sarif_output), ("json", json_output)):
        subprocess.run(
            [
                "trivy",
                "config",
                "--severity",
                "HIGH,CRITICAL",
                "--skip-dirs",
                skip_arg,
                "--format",
                fmt,
                "--output",
                out_file,
                "--exit-code",
                "0",
                target_dir,
            ],
            check=True,
        )


def summarize_config_report(
    data: dict, scanned_dirs: list[str]
) -> tuple[str, int, int]:
    """Parse Trivy config JSON report and return (markdown_summary, crit_count, high_count)."""
    results = data.get("Results") or []
    findings = []
    crit_count = 0
    high_count = 0

    for res in results:
        target = res.get("Target", "")
        for m in res.get("Misconfigurations") or []:
            sev = m.get("Severity", "UNKNOWN")
            if sev == "CRITICAL":
                crit_count += 1
            elif sev == "HIGH":
                high_count += 1
            findings.append((sev, target, m.get("ID", ""), m.get("Title", "")))

    lines = [
        "## 🛡️ Trivy IaC & Kubernetes Manifest Scan (`trivy config`)\n\n",
        f"- **Scanned directories:** {', '.join(scanned_dirs) or '`.`'} (`{len(results)}` config targets evaluated)\n",
        f"- **Findings (`CRITICAL` / `HIGH`):** `{crit_count}` Critical, `{high_count}` High\n\n",
    ]
    if findings:
        lines.append("| Severity | Target | Rule ID | Title |\n")
        lines.append("| :--- | :--- | :--- | :--- |\n")
        for sev, target, rid, title in findings[:50]:
            safe_title = title.replace("|", "\\|")
            lines.append(f"| **{sev}** | `{target}` | `{rid}` | {safe_title} |\n")
        lines.append("\n")
    else:
        lines.append("> ✅ No `HIGH` or `CRITICAL` IaC misconfigurations detected.\n\n")

    return "".join(lines), crit_count, high_count


def main() -> None:
    run_trivy_config()
    scanned_dirs = get_scanned_dirs()

    with open("trivy-config.json", encoding="utf-8") as f:
        data = json.load(f)

    summary_md, crit_count, _ = summarize_config_report(data, scanned_dirs)
    print(summary_md, flush=True)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as out:
            out.write(summary_md)

    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as gh_out:
            gh_out.write(f"config_critical={crit_count}\n")


if __name__ == "__main__":
    main()
