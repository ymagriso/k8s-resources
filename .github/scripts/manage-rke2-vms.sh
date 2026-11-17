#!/usr/bin/env bash
# Manage power state (start / stop) of RKE2 cluster VMs in GCP.

set -euo pipefail

CLUSTER_LABEL="${CLUSTER_LABEL:-rke2}"
MANAGED_BY_LABEL="${MANAGED_BY_LABEL:-opentofu}"
BASE_VM_FILTER="labels.cluster=${CLUSTER_LABEL} AND labels.managed-by=${MANAGED_BY_LABEL}"

list_cluster_vms() {
  local status_filter="$1"
  local format="$2"
  gcloud compute instances list \
    --filter="${BASE_VM_FILTER} AND (${status_filter})" \
    --format="$format"
}

run_power_action_by_zone() {
  local action="$1"
  local vm_csv="$2"
  local zones zone zone_names

  mapfile -t zones < <(printf '%s\n' "$vm_csv" | cut -d',' -f2 | sort -u)
  for zone in "${zones[@]}"; do
    mapfile -t zone_names < <(printf '%s\n' "$vm_csv" | awk -F',' -v z="$zone" '$2 == z {print $1}')
    echo "Running '${action}' on RKE2 VMs in zone ${zone}: ${zone_names[*]}"
    gcloud compute instances "$action" "${zone_names[@]}" --zone="$zone" --quiet
  done
}

is_within_shutdown_window() {
  local hour_str="${1:-$(TZ=Asia/Jerusalem date +%H)}"
  local hour_num=$((10#$hour_str))
  # Enforce nightly shutdown only between 23:00 and 06:59 Asia/Jerusalem.
  (( hour_num == 23 || (hour_num >= 0 && hour_num <= 6) ))
}

stop_rke2_vms() {
  if [[ "${ENFORCE_SHUTDOWN_WINDOW:-false}" == "true" ]] && ! is_within_shutdown_window; then
    echo "Current Asia/Jerusalem time ($(TZ=Asia/Jerusalem date '+%Y-%m-%d %H:%M %Z')) is outside the 23:00–06:59 shutdown window. Skipping scheduled stop."
    return 0
  fi

  local transitioning running
  for i in {1..24}; do
    transitioning=$(list_cluster_vms "status=PROVISIONING OR status=STAGING" "value(name)")
    if [ -z "$transitioning" ]; then
      break
    fi
    echo "Waiting for starting RKE2 VMs to reach RUNNING (${i}/24): ${transitioning}"
    sleep 5
  done

  running=$(list_cluster_vms "status=RUNNING" "csv[no-heading](name,zone.basename())")

  if [ -z "$running" ]; then
    echo "No running RKE2 VMs found. Nothing to do."
    return 0
  fi

  echo "Found running RKE2 VMs:"
  echo "$running"
  run_power_action_by_zone stop "$running"
}

start_rke2_vms() {
  local stopping stopped
  for i in {1..24}; do
    stopping=$(list_cluster_vms "status=STOPPING" "value(name)")
    if [ -z "$stopping" ]; then
      break
    fi
    echo "Waiting for stopping RKE2 VMs to reach TERMINATED (${i}/24): ${stopping}"
    sleep 5
  done

  stopped=$(list_cluster_vms "status=TERMINATED OR status=SUSPENDED" "csv[no-heading](name,zone.basename())")

  if [ -z "$stopped" ]; then
    echo "All RKE2 VMs are already running."
    return 0
  fi

  echo "Found stopped RKE2 VMs:"
  echo "$stopped"
  run_power_action_by_zone start "$stopped"
}

main() {
  local action="${1:-${ACTION:-stop}}"
  case "$action" in
    stop)
      stop_rke2_vms
      ;;
    start)
      start_rke2_vms
      ;;
    *)
      echo "::error::Invalid action '${action}'. Expected 'start' or 'stop'." >&2
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
