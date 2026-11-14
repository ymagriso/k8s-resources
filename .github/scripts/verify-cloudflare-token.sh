#!/usr/bin/env bash
# Verify Cloudflare API token validity, Zone read access, and Tunnel configuration read access.

set -euo pipefail

verify_api_token() {
  local verify_acct verify_user
  verify_acct=$(curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${TF_VAR_account_id}/tokens/verify")
  if [ "$(printf '%s' "$verify_acct" | jq -r '.success')" = "true" ]; then
    echo "Account API token verified: status=$(printf '%s' "$verify_acct" | jq -r '.result.status')"
  else
    verify_user=$(curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      "https://api.cloudflare.com/client/v4/user/tokens/verify")
    if [ "$(printf '%s' "$verify_user" | jq -r '.success')" = "true" ]; then
      echo "User API token verified: status=$(printf '%s' "$verify_user" | jq -r '.result.status')"
    else
      echo "::error::Cloudflare API token verification failed. Check that CLOUDFLARE_API_TOKEN is valid and not truncated or expired."
      printf '%s\n' "$verify_acct" | jq -c '.errors // .'
      return 1
    fi
  fi
}

verify_zone_access() {
  local zone_check
  zone_check=$(curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/zones?name=${TF_VAR_domain}")
  if [ "$(printf '%s' "$zone_check" | jq -r '.success')" != "true" ]; then
    echo "::error::Cloudflare Zone lookup failed. Ensure the token has Zone:Read and DNS:Edit permissions for the domain (if scoped to 'Specific domains', try 'All domains' if /zones list still returns 9109)."
    printf '%s\n' "$zone_check" | jq -c '.errors // .'
    return 1
  fi
  echo "Cloudflare Zone lookup succeeded."
}

verify_tunnel_access() {
  local tunnel_check
  tunnel_check=$(curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${TF_VAR_account_id}/cfd_tunnel/${TF_VAR_tunnel_id}/configurations")
  if [ "$(printf '%s' "$tunnel_check" | jq -r '.success')" != "true" ]; then
    echo "::error::Cloudflare Tunnel config read failed. Ensure the token has 'Cloudflare One Connector: cloudflared: Write' (or 'Cloudflare Tunnel: Edit') under Entire account."
    printf '%s\n' "$tunnel_check" | jq -c '.errors // .'
    return 1
  fi
  echo "Cloudflare Tunnel config access verified."
}

main() {
  verify_api_token
  verify_zone_access
  verify_tunnel_access
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
