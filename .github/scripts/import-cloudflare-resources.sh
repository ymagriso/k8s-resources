#!/usr/bin/env bash
# Import pre-existing Cloudflare Tunnel configuration and DNS CNAME records into OpenTofu state.

set -euo pipefail

parse_route_subdomains() {
  local routes_file="${1:-routes.yaml}"
  python3 - "$routes_file" <<'PY'
import re
import sys

seen = set()
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.split("#", 1)[0].strip()
        m = re.match(r"^(?:-\s*)?subdomain:\s*['\"]?([A-Za-z0-9._-]+)['\"]?$", line)
        if m and m.group(1) not in seen:
            seen.add(m.group(1))
            print(m.group(1))
PY
}

import_cloudflare_resources() {
  local workdir="${1:-tofu/cloudflare}"
  cd "$workdir"

  local state_list
  state_list=$(tofu state list 2>/dev/null || true)

  local tunnel_addr="cloudflare_zero_trust_tunnel_cloudflared_config.tunnel"
  if ! printf '%s\n' "$state_list" | grep -qxF "$tunnel_addr"; then
    local tunnel_resp
    tunnel_resp=$(curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      "https://api.cloudflare.com/client/v4/accounts/${TF_VAR_account_id}/cfd_tunnel/${TF_VAR_tunnel_id}/configurations")
    if [ "$(printf '%s' "$tunnel_resp" | jq -r '.success == true and .result.config != null')" = "true" ]; then
      echo "Importing existing Cloudflare Tunnel configuration into OpenTofu state..."
      tofu import -input=false "$tunnel_addr" "${TF_VAR_account_id}/${TF_VAR_tunnel_id}"
    else
      echo "No existing remote tunnel configuration found to import; OpenTofu will create it."
    fi
  fi

  local zone_resp
  zone_resp=$(curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/zones?name=${TF_VAR_domain}")
  if [ "$(printf '%s' "$zone_resp" | jq -r '.success')" != "true" ]; then
    echo "::error::Failed to query Cloudflare Zones API. Ensure the API token has Zone:Read, DNS:Edit, and Cloudflare One Connector: cloudflared: Write permissions."
    printf '%s\n' "$zone_resp" | jq -c '.errors // .'
    return 1
  fi

  local zone_id
  zone_id=$(printf '%s' "$zone_resp" | jq -r '.result[0].id // empty')
  if [ -z "$zone_id" ]; then
    echo "::error::Could not find Cloudflare Zone for configured CUSTOM_DOMAIN."
    return 1
  fi
  echo "::add-mask::${zone_id}"

  local subdomains subdomain dns_addr fqdn cname_resp record_id conflict_resp conflict_type
  subdomains=$(parse_route_subdomains "routes.yaml")
  for subdomain in $subdomains; do
    dns_addr="cloudflare_dns_record.route[\"${subdomain}\"]"
    if printf '%s\n' "$state_list" | grep -qxF "$dns_addr"; then
      continue
    fi

    fqdn="${subdomain}.${TF_VAR_domain}"
    cname_resp=$(curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${fqdn}")
    record_id=$(printf '%s' "$cname_resp" | jq -r '.result[0].id // empty')

    if [ -n "$record_id" ]; then
      echo "Importing existing CNAME record for route '${subdomain}'..."
      tofu import -input=false "$dns_addr" "${zone_id}/${record_id}"
    else
      conflict_resp=$(curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${fqdn}")
      conflict_type=$(printf '%s' "$conflict_resp" | jq -r '.result[0].type // empty')
      if [ -n "$conflict_type" ]; then
        echo "::error::Existing ${conflict_type} DNS record conflicts with CNAME for route '${subdomain}'. Remove or convert it in Cloudflare DNS first."
        return 1
      fi
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  import_cloudflare_resources "$@"
fi
