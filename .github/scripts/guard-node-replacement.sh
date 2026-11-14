#!/usr/bin/env bash
# Guard against accidental destruction or replacement of RKE2 node VMs in an OpenTofu plan.

set -euo pipefail

check_node_replacement() {
  local workdir="${1:-tofu}"
  local plan_file="${2:-tfplan}"
  local allow_replacement="${ALLOW_NODE_REPLACEMENT:-false}"

  # Any delete action on an existing node VM (destroy or replace) destroys the whole
  # HA cluster's etcd/data. Block it unless explicitly allowed via workflow_dispatch.
  local replaced
  replaced=$(tofu -chdir="$workdir" show -json "$plan_file" | jq -r '.resource_changes[]?
    | select(.type == "google_compute_instance")
    | select(.change.actions | index("delete"))
    | "\(.address): \(.change.actions | join("/"))"')

  if [ -n "$replaced" ]; then
    echo "::warning::This plan destroys or replaces RKE2 node VMs:"
    echo "$replaced"
    if [ "$allow_replacement" != "true" ]; then
      echo "::error::Refusing to continue: node VM replacement wipes the cluster. RKE2 upgrades must go through the System Upgrade Controller. Re-run manually with allow_node_replacement=true if this is intended."
      return 1
    fi
  else
    echo "No node VM destruction or replacement in this plan."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  check_node_replacement "$@"
fi
