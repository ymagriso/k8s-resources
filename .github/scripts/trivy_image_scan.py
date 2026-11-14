#!/usr/bin/env python3
"""Scan discovered container images with Trivy and generate a Markdown vulnerability summary."""

import json
import os
import subprocess


def run_trivy_image_scan(image: str, output_file: str) -> subprocess.CompletedProcess:
    """Run Trivy vulnerability scan on a single container image."""
    return subprocess.run(
        [
            "trivy",
            "image",
            "--scanners",
            "vuln",
            "--severity",
            "HIGH,CRITICAL",
            "--format",
            "json",
            "--output",
            output_file,
            "--exit-code",
            "0",
            image,
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def parse_image_report(report: dict) -> tuple[int, int, int, int, list[tuple]]:
    """Parse a Trivy image JSON report into counts and sorted vulnerability tuples."""
    crit = 0
    high = 0
    fixable = 0
    fixable_crit = 0
    vulns_list = []

    for res in report.get("Results") or []:
        for v in res.get("Vulnerabilities") or []:
            sev = v.get("Severity", "")
            fixed_ver = v.get("FixedVersion", "")
            if sev == "CRITICAL":
                crit += 1
                if fixed_ver:
                    fixable_crit += 1
            elif sev == "HIGH":
                high += 1
            if fixed_ver:
                fixable += 1
            vulns_list.append(
                (
                    sev,
                    v.get("VulnerabilityID", ""),
                    v.get("PkgName", ""),
                    v.get("InstalledVersion", ""),
                    fixed_ver or "*(unfixed)*",
                    (v.get("Title") or "").replace("|", "\\|")[:80],
                )
            )

    vulns_list.sort(key=lambda x: (0 if x[0] == "CRITICAL" else 1, x[1]))
    return crit, high, fixable, fixable_crit, vulns_list


def format_image_details(
    img: str, crit: int, high: int, fixable: int, vulns_list: list[tuple]
) -> str:
    """Format an expandable HTML <details> block for a single image's CVEs."""
    lines = [
        f"<details><summary><b>{img}</b> — {crit} Critical, {high} High ({fixable} fixable)</summary>\n\n",
        "| Severity | CVE | Package | Installed | Fixed Version | Title |\n",
        "| :--- | :--- | :--- | :--- | :--- | :--- |\n",
    ]
    for sev, cve, pkg, inst, fixv, title in vulns_list[:40]:
        lines.append(
            f"| **{sev}** | `{cve}` | `{pkg}` | `{inst}` | `{fixv}` | {title} |\n"
        )
    if len(vulns_list) > 40:
        lines.append(f"\n*...and {len(vulns_list) - 40} more findings.*\n")
    lines.append("\n</details>\n")
    return "".join(lines)


def format_scan_summary(
    image_count: int,
    priv_status: str,
    total_crit: int,
    total_fixable_crit: int,
    total_high: int,
    summary_rows: list[tuple],
    details_blocks: list[str],
) -> str:
    """Build the complete Markdown summary report for all scanned and skipped images."""
    out_lines = [
        "## 📦 Trivy Container Image Vulnerability Scan (`trivy image`)\n\n",
        f"- **Images scanned:** `{image_count}`\n",
        f"- **Private Docker Registry:** {priv_status}\n",
        f"- **Total findings:** `{total_crit}` Critical (`{total_fixable_crit}` fixable), `{total_high}` High\n\n",
        "| Image | Source(s) | Critical | High | Fixable | Status |\n",
        "| :--- | :--- | :---: | :---: | :---: | :--- |\n",
    ]
    for img, sources, c, h, fx, st in summary_rows:
        out_lines.append(f"| `{img}` | {sources} | {c} | {h} | {fx} | {st} |\n")
    out_lines.append("\n")
    if details_blocks:
        out_lines.append("### 🔍 Per-Image Vulnerability Details\n\n")
        for blk in details_blocks:
            out_lines.append(blk)

    return "".join(out_lines)


def main() -> None:
    with open("discovered-images.json", encoding="utf-8") as f:
        meta = json.load(f)

    image_list = meta["images"]
    skipped_list = meta.get("skipped_private") or []
    priv_status = meta["private_registry_status"]

    summary_rows = []
    details_blocks = []
    total_crit = 0
    total_high = 0
    total_fixable_crit = 0

    for idx, item in enumerate(image_list, 1):
        img = item["image"]
        sources = ", ".join(f"`{s}`" for s in item["sources"])
        out_file = f"trivy-image-{idx}.json"
        print(f"[{idx}/{len(image_list)}] Scanning image: {img}", flush=True)

        proc = run_trivy_image_scan(img, out_file)
        if proc.returncode != 0 or not os.path.exists(out_file):
            print(
                f"  -> Scan failed for {img} (rc={proc.returncode}):\n{proc.stderr}\n{proc.stdout}",
                flush=True,
            )
            summary_rows.append((img, sources, "-", "-", "-", "⚠️ Scan/Pull Failed"))
            continue

        with open(out_file, encoding="utf-8") as rf:
            report = json.load(rf)

        crit, high, fixable, fixable_crit, vulns_list = parse_image_report(report)
        total_crit += crit
        total_high += high
        total_fixable_crit += fixable_crit

        status = (
            "✅ Clean"
            if (crit == 0 and high == 0)
            else ("🔴 Critical" if crit > 0 else "🟠 High")
        )
        summary_rows.append((img, sources, str(crit), str(high), str(fixable), status))

        if vulns_list:
            details_blocks.append(
                format_image_details(img, crit, high, fixable, vulns_list)
            )

    for item in skipped_list:
        s_img = item["image"]
        s_sources = ", ".join(f"`{s}`" for s in item["sources"])
        summary_rows.append(
            (s_img, s_sources, "-", "-", "-", "⏭️ Skipped (Private Registry Offline)")
        )

    image_summary_md = format_scan_summary(
        image_count=len(image_list),
        priv_status=priv_status,
        total_crit=total_crit,
        total_fixable_crit=total_fixable_crit,
        total_high=total_high,
        summary_rows=summary_rows,
        details_blocks=details_blocks,
    )
    print(image_summary_md, flush=True)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as out:
            out.write(image_summary_md)

    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as gh_out:
            gh_out.write(f"fixable_critical={total_fixable_crit}\n")


if __name__ == "__main__":
    main()
