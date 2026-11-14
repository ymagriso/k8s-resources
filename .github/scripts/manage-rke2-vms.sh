#!/usr/bin/env bash
# Manage power state (start / stop) of RKE2 cluster VMs in GCP.

set -euo pipefail

stop_rke2_vms() {
  local transitioning running
  for i in {1..24}; do
    transitioning=$(gcloud compute instances list \
      --filter="name~'^rke2-node-' AND (status=PROVISIONING OR status=STAGING)" \
      --format="value(name)")
    if [ -z "$transitioning" ]; then
      break
    fi
    echo "Waiting for starting RKE2 VMs to reach RUNNING (${i}/24): ${transitioning}"
    sleep 5
  done

  running=$(gcloud compute instances list \
    --filter="name~'^rke2-node-' AND status=RUNNING" \
    --format="csv[no-heading](name,zone.basename())")

  if [ -z "$running" ]; then
    echo "No running RKE2 VMs found. Nothing to do."
    return 0
  fi

  echo "Found running RKE2 VMs:"
  echo "$running"

  local zones zone zone_names
  mapfile -t zones < <(printf '%s\n' "$running" | cut -d',' -f2 | sort -u)
  for zone in "${zones[@]}"; do
    mapfile -t zone_names < <(printf '%s\n' "$running" | awk -F',' -v z="$zone" '$2 == z {print $1}')
    echo "Stopping RKE2 VMs in zone ${zone}: ${zone_names[*]}"
    gcloud compute instances stop "${zone_names[@]}" --zone="$zone" --quiet
  done
}

start_rke2_vms() {
  local stopping stopped
  for i in {1..24}; do
    stopping=$(gcloud compute instances list \
      --filter="name~'^rke2-node-' AND status=STOPPING" \
      --format="value(name)")
    if [ -z "$stopping" ]; then
      break
    fi
    echo "Waiting for stopping RKE2 VMs to reach TERMINATED (${i}/24): ${stopping}"
    sleep 5
  done

  stopped=$(gcloud compute instances list \
    --filter="name~'^rke2-node-' AND (status=TERMINATED OR status=SUSPENDED)" \
    --format="csv[no-heading](name,zone.basename())")

  if [ -z "$stopped" ]; then
    echo "All RKE2 VMs are already running."
    return 0
  fi

  echo "Found stopped RKE2 VMs:"
  echo "$stopped"

  local zones zone zone_names
  mapfile -t zones < <(printf '%s\n' "$stopped" | cut -d',' -f2 | sort -u)
  for zone in "${zones[@]}"; do
    mapfile -t zone_names < <(printf '%s\n' "$stopped" | awk -F',' -v z="$zone" '$2 == z {print $1}')
    echo "Starting RKE2 VMs in zone ${zone}: ${zone_names[*]}"
    gcloud compute instances start "${zone_names[@]}" --zone="$zone" --quiet
  done
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
