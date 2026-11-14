#!/usr/bin/env python3
"""Discover container images across Kubernetes manifests, Kustomize overlays, Helm charts, and private registry."""

import base64
import json
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
import yaml

SKIP_DIRS = {".git", ".github", "docs", ".terraform"}
KUSTOMIZE_NAMES = {"kustomization.yaml", "kustomization.yml", "Kustomization"}


def check_private_registry(
    domain: str, reg_user: str, reg_pass: str
) -> tuple[bool, str, str]:
    """Check connectivity to the private Docker registry and log in with docker/helm if online."""
    private_registry_status = "Not configured (CUSTOM_DOMAIN secret unset)"
    private_registry_reachable = False
    reg_host = f"registry.{domain}" if domain else ""

    if not domain:
        return private_registry_reachable, private_registry_status, reg_host

    ping_url = f"https://{reg_host}/v2/"
    req = urllib.request.Request(
        ping_url,
        method="GET",
        headers={"User-Agent": "Docker-Client/27.0.0 (linux)"},
    )
    if reg_user and reg_pass:
        basic_token = base64.b64encode(f"{reg_user}:{reg_pass}".encode()).decode()
        req.add_header("Authorization", f"Basic {basic_token}")

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            code = resp.getcode()
        private_registry_reachable = code in (200, 401)
        if not private_registry_reachable:
            private_registry_status = f"Offline / unreachable (`{reg_host}` — HTTP {code})"
    except urllib.error.HTTPError as e:
        private_registry_reachable = e.code in (200, 401)
        if not private_registry_reachable:
            private_registry_status = f"Offline / unreachable (`{reg_host}` — HTTP {e.code})"
    except Exception:
        private_registry_reachable = False
        private_registry_status = (
            f"Offline / unreachable (`{reg_host}` — cluster VMs likely stopped)"
        )

    if private_registry_reachable:
        private_registry_status = f"Online (`{reg_host}`)"
        if reg_user and reg_pass:
            subprocess.run(
                ["docker", "login", reg_host, "-u", reg_user, "--password-stdin"],
                input=reg_pass,
                text=True,
                check=False,
            )
            subprocess.run(
                ["helm", "registry", "login", reg_host, "-u", reg_user, "--password-stdin"],
                input=reg_pass,
                text=True,
                check=False,
            )

    return private_registry_reachable, private_registry_status, reg_host


def is_offline_private_ref(
    ref: str, reg_host: str, private_registry_reachable: bool
) -> bool:
    """Return True if an image or chart URL points to an unconfigured or offline private registry."""
    clean = re.sub(r"^[a-zA-Z0-9+.-]+://", "", ref.strip())
    if clean.startswith("registry.yourdomain.com"):
        return True
    if reg_host and clean.startswith(reg_host) and not private_registry_reachable:
        return True
    return False


def extract_images_from_docs(
    docs: list,
    source_label: str,
    add_image_fn,
    include_dict_images: bool = False,
) -> None:
    """Extract container image references from parsed YAML documents."""
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind", "")
        api_version = str(doc.get("apiVersion", ""))
        spec = doc.get("spec") or {}

        # Skip kubeconfig files
        if (
            kind == "Config"
            and api_version == "v1"
            and "clusters" in doc
            and "contexts" in doc
        ):
            continue

        # Rancher System Upgrade Controller Plan CRD
        if kind == "Plan" and api_version.startswith("upgrade.cattle.io/"):
            version = str(spec.get("version", "")).strip()
            tag = version.replace("+", "-") if version else "latest"
            for field in ("upgrade", "prepare"):
                blk = spec.get(field) or {}
                img_repo = blk.get("image")
                if isinstance(img_repo, str) and img_repo:
                    add_image_fn(
                        f"{img_repo}:{tag}" if ":" not in img_repo else img_repo,
                        source_label,
                    )
            continue

        def walk(obj):
            if isinstance(obj, dict):
                for k, v in obj.items():
                    if k == "image" and isinstance(v, str):
                        add_image_fn(v, source_label)
                    elif k == "image" and isinstance(v, dict) and include_dict_images:
                        repo = v.get("repository")
                        tag = v.get("tag") or v.get("version")
                        reg = v.get("registry")
                        if isinstance(repo, str) and repo:
                            full_repo = (
                                f"{reg.rstrip('/')}/{repo.lstrip('/')}"
                                if isinstance(reg, str) and reg
                                else repo
                            )
                            full_img = (
                                f"{full_repo}:{tag}"
                                if tag and ":" not in full_repo
                                else full_repo
                            )
                            add_image_fn(full_img, source_label)
                    else:
                        walk(v)
            elif isinstance(obj, list):
                for item in obj:
                    walk(item)

        walk(spec if spec else doc)


def find_repo_manifests(
    root_dir: str = ".", skip_dirs: set[str] = SKIP_DIRS
) -> tuple[list[str], list[str], list[str]]:
    """Walk the repository and return (kustomize_dirs, helm_chart_dirs, yaml_files)."""
    kustomize_dirs = []
    helm_chart_dirs = []
    yaml_files = []

    for root, dirs, files in os.walk(root_dir):
        dirs[:] = sorted(
            d for d in dirs if d not in skip_dirs and not d.startswith(".")
        )
        norm_root = os.path.normpath(root)
        file_set = set(files)
        if file_set & KUSTOMIZE_NAMES:
            kustomize_dirs.append(norm_root)
        if "Chart.yaml" in file_set:
            helm_chart_dirs.append(norm_root)
        for fname in sorted(files):
            if (
                fname.endswith((".yaml", ".yml"))
                and fname not in KUSTOMIZE_NAMES
                and fname != "Chart.yaml"
            ):
                yaml_files.append(os.path.normpath(os.path.join(root, fname)))

    return kustomize_dirs, helm_chart_dirs, yaml_files


def discover_images(
    root_dir: str = ".",
    domain: str = "",
    reg_user: str = "admin",
    reg_pass: str = "",
) -> dict:
    """Discover all container images across the repository and private registry."""
    # 1. Check Private Docker Registry connectivity first
    (
        private_registry_reachable,
        private_registry_status,
        reg_host,
    ) = check_private_registry(domain, reg_user, reg_pass)

    images: dict[str, set[str]] = {}
    skipped_private: dict[str, set[str]] = {}

    def add_image(img: str, source: str) -> None:
        img = img.strip().strip('"').strip("'")
        if not img or "{{" in img or "$" in img:
            return
        if domain:
            img = img.replace("yourdomain.com", domain)
        if is_offline_private_ref(img, reg_host, private_registry_reachable):
            skipped_private.setdefault(img, set()).add(source)
            return
        images.setdefault(img, set()).add(source)

    kustomize_dirs, helm_chart_dirs, yaml_files = find_repo_manifests(root_dir)

    # 2. Render all Kustomize overlays found anywhere in the repository
    for kust_dir in sorted(kustomize_dirs):
        print(f"Rendering Kustomize directory: {kust_dir}", flush=True)
        rendered = subprocess.check_output(
            ["kubectl", "kustomize", kust_dir], text=True
        )
        extract_images_from_docs(
            list(yaml.safe_load_all(rendered)), f"kustomize:{kust_dir}", add_image
        )

    # 3. Render all Argo CD Applications & ApplicationSets found anywhere in the repository
    consumed_value_files = set()
    rendered_local_charts = set()

    for fpath in yaml_files:
        with open(fpath, encoding="utf-8") as f:
            raw_text = f.read()
        if domain:
            raw_text = raw_text.replace("yourdomain.com", domain)
        try:
            docs = list(yaml.safe_load_all(raw_text))
        except Exception:
            continue

        for doc in docs:
            if not isinstance(doc, dict):
                continue
            if not str(doc.get("apiVersion", "")).startswith("argoproj.io/"):
                continue
            if doc.get("kind") not in ("Application", "ApplicationSet"):
                continue

            spec = doc.get("spec") or {}
            tmpl_spec = ((spec.get("template") or {}).get("spec")) or {}
            sources = []
            for s_holder in (spec, tmpl_spec):
                if isinstance(s_holder.get("source"), dict):
                    sources.append(s_holder["source"])
                if isinstance(s_holder.get("sources"), list):
                    sources.extend(
                        s for s in s_holder["sources"] if isinstance(s, dict)
                    )

            ref_map = {"values": "."}
            for src in sources:
                if src.get("ref"):
                    ref_map[src["ref"]] = src.get("path", ".")

            for src in sources:
                chart = src.get("chart")
                repo_url = (src.get("repoURL") or "").strip()
                rev = str(src.get("targetRevision") or "").strip()
                local_path = (src.get("path") or "").strip()
                helm_cfg = src.get("helm") or {}

                # Extract any inline images from valuesObject / values even if chart repo is offline
                if isinstance(helm_cfg.get("valuesObject"), dict):
                    extract_images_from_docs(
                        [helm_cfg["valuesObject"]],
                        fpath,
                        add_image,
                        include_dict_images=True,
                    )
                if (
                    isinstance(helm_cfg.get("values"), str)
                    and helm_cfg["values"].strip()
                ):
                    try:
                        extract_images_from_docs(
                            list(yaml.safe_load_all(helm_cfg["values"])),
                            fpath,
                            add_image,
                            include_dict_images=True,
                        )
                    except Exception:
                        pass

                is_local_chart = bool(
                    local_path and os.path.exists(os.path.join(local_path, "Chart.yaml"))
                )
                if not chart and not is_local_chart:
                    continue

                if repo_url and is_offline_private_ref(
                    repo_url, reg_host, private_registry_reachable
                ):
                    print(
                        f"Skipping offline private registry Helm chart in {fpath}: {repo_url}/{chart}",
                        flush=True,
                    )
                    continue

                release_name = (
                    helm_cfg.get("releaseName")
                    or chart
                    or os.path.basename(local_path)
                )
                cmd = ["helm", "template", release_name]
                if is_local_chart:
                    cmd.append(local_path)
                    rendered_local_charts.add(os.path.normpath(local_path))
                    label = f"helm:{local_path}"
                elif repo_url.startswith(("http://", "https://")):
                    cmd.extend([chart, "--repo", repo_url])
                    if rev:
                        cmd.extend(["--version", rev])
                    label = f"helm:{chart}@{rev}"
                else:
                    oci_url = (
                        repo_url
                        if repo_url.startswith("oci://")
                        else f"oci://{repo_url}"
                    )
                    cmd.append(f"{oci_url.rstrip('/')}/{chart}")
                    if rev:
                        cmd.extend(["--version", rev])
                    label = f"helm:{chart}@{rev}"

                for vf in helm_cfg.get("valueFiles") or []:
                    resolved_vf = vf
                    for rname, rpath in ref_map.items():
                        prefix = f"${rname}/"
                        if resolved_vf.startswith(prefix):
                            resolved_vf = os.path.normpath(
                                os.path.join(rpath, resolved_vf[len(prefix) :])
                            )
                    if os.path.exists(resolved_vf):
                        consumed_value_files.add(os.path.normpath(resolved_vf))
                        cmd.extend(["-f", resolved_vf])

                temp_files = []
                try:
                    if (
                        isinstance(helm_cfg.get("valuesObject"), dict)
                        and helm_cfg["valuesObject"]
                    ):
                        tf = tempfile.NamedTemporaryFile(
                            "w", suffix=".yaml", delete=False, encoding="utf-8"
                        )
                        yaml.safe_dump(helm_cfg["valuesObject"], tf)
                        tf.close()
                        temp_files.append(tf.name)
                        cmd.extend(["-f", tf.name])
                    if (
                        isinstance(helm_cfg.get("values"), str)
                        and helm_cfg["values"].strip()
                    ):
                        tf = tempfile.NamedTemporaryFile(
                            "w", suffix=".yaml", delete=False, encoding="utf-8"
                        )
                        tf.write(helm_cfg["values"])
                        tf.close()
                        temp_files.append(tf.name)
                        cmd.extend(["-f", tf.name])
                    for param in helm_cfg.get("parameters") or []:
                        if (
                            isinstance(param, dict)
                            and param.get("name")
                            and "value" in param
                        ):
                            cmd.extend(["--set", f"{param['name']}={param['value']}"])

                    print(
                        f"Rendering Helm chart for {fpath}: {' '.join(cmd)}",
                        flush=True,
                    )
                    rendered = subprocess.check_output(cmd, text=True)
                    extract_images_from_docs(
                        list(yaml.safe_load_all(rendered)), label, add_image
                    )
                finally:
                    for tf_name in temp_files:
                        if os.path.exists(tf_name):
                            os.remove(tf_name)

    # 4. Render any standalone local Helm charts (Chart.yaml) not already rendered via Argo CD
    for chart_dir in sorted(helm_chart_dirs):
        if chart_dir in rendered_local_charts:
            continue
        print(f"Rendering standalone local Helm chart: {chart_dir}", flush=True)
        rendered = subprocess.check_output(
            ["helm", "template", os.path.basename(chart_dir), chart_dir], text=True
        )
        extract_images_from_docs(
            list(yaml.safe_load_all(rendered)), f"helm:{chart_dir}", add_image
        )

    # 5. Scan all remaining YAML manifests across the repository
    for fpath in yaml_files:
        if fpath in consumed_value_files:
            continue
        with open(fpath, encoding="utf-8") as f:
            raw_text = f.read()
        if domain:
            raw_text = raw_text.replace("yourdomain.com", domain)
        try:
            docs = list(yaml.safe_load_all(raw_text))
        except Exception:
            continue
        other_docs = [
            d
            for d in docs
            if isinstance(d, dict)
            and not (
                str(d.get("apiVersion", "")).startswith("argoproj.io/")
                and d.get("kind") in ("Application", "ApplicationSet")
            )
        ]
        if other_docs:
            extract_images_from_docs(other_docs, fpath, add_image)

    image_list = [
        {"image": img, "sources": sorted(srcs)} for img, srcs in sorted(images.items())
    ]
    skipped_list = [
        {"image": img, "sources": sorted(srcs)}
        for img, srcs in sorted(skipped_private.items())
    ]
    return {
        "private_registry_status": private_registry_status,
        "images": image_list,
        "skipped_private": skipped_list,
    }


def main() -> None:
    domain = os.environ.get("CUSTOM_DOMAIN", "").strip()
    reg_user = os.environ.get("REGISTRY_USER", "admin").strip()
    reg_pass = os.environ.get("REGISTRY_PASS", "").strip()

    result = discover_images(
        root_dir=".", domain=domain, reg_user=reg_user, reg_pass=reg_pass
    )
    with open("discovered-images.json", "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)

    image_list = result["images"]
    skipped_list = result["skipped_private"]
    print(
        f"Discovered {len(image_list)} unique scan-ready container images.", flush=True
    )
    for item in image_list:
        print(f" - {item['image']} ({', '.join(item['sources'])})", flush=True)
    if skipped_list:
        print(
            f"Skipped {len(skipped_list)} offline/unconfigured private-registry images:",
            flush=True,
        )
        for item in skipped_list:
            print(f" - {item['image']} ({', '.join(item['sources'])})", flush=True)


if __name__ == "__main__":
    main()
