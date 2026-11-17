# Repository Guidelines (k8s-resources)

## Scripts and CI Conventions
- Discover cluster VMs by GCP labels (`labels.cluster=rke2`, `labels.managed-by=opentofu`, `labels.role=initial-server`) instead of hardcoded node names, IPs, or zones.
- Derive workload namespaces from `argocd/apps/*.yaml` (`spec.destination.namespace`) instead of hardcoded lists.
- Guard `GITHUB_OUTPUT`, `GITHUB_ENV`, and `GITHUB_STEP_SUMMARY` file writes with existence checks so scripts in `.github/scripts/` run locally.
- Mask any derived or API-fetched cloud identifiers with `::add-mask::` in CI logs.

## OpenTofu VM Safety
- Keep `metadata["startup-script"]` in `tofu/compute.tf`; never switch to `metadata_startup_script` (`ForceNew`).
- Keep `guard-node-replacement.sh` active before `tofu apply` on the GCP stack.

## GlusterFS `/shared` Storage
- Any workload that mounts `/shared/...` must set `hostPath.type: Directory` (never `DirectoryOrCreate`).
- Also mount `/shared/.glusterfs-mounted` (`type: File`, read-only) inside a writable `emptyDir` (such as `/tmp/.glusterfs-mounted`) so pods wait until GlusterFS mounts `/shared`.
