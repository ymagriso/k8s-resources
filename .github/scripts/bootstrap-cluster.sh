#!/usr/bin/env bash
# Bootstrap RKE2 cluster, GlusterFS /shared storage, core namespaces, secrets,
# cert-manager, Argo CD, Let's Encrypt certificates, and Root App-of-Apps.

set -e

: "${CLUSTER_LABEL:=rke2}"
: "${MANAGED_BY_LABEL:=opentofu}"
: "${INIT_ROLE_LABEL:=initial-server}"
: "${TOFU_DIR:=tofu}"
: "${STATE_BUCKET:=}"
: "${PLACEHOLDER_EMAIL:=your-email@yourdomain.com}"
: "${PLACEHOLDER_DOMAIN:=yourdomain.com}"
: "${CUSTOM_DOMAIN:=}"
: "${ACME_EMAIL:=}"
: "${CF_API_TOKEN:=}"
: "${CF_TUNNEL_TOKEN:=}"
: "${GOOGLE_OIDC_CLIENT_ID:=}"
: "${GOOGLE_OIDC_CLIENT_SECRET:=}"
: "${ARGOCD_ADMIN_EMAIL:=${ACME_EMAIL}}"
: "${MONGO_ROOT_PASSWORD:=}"
: "${MONGO_REPLICA_KEY:=}"
: "${DOCKER_REGISTRY_USERNAME:=admin}"
: "${DOCKER_REGISTRY_PASSWORD:=}"
: "${GRAFANA_ADMIN_USER:=admin}"
: "${GRAFANA_ADMIN_PASSWORD:=}"
: "${GRAFANA_GOOGLE_OIDC_CLIENT_ID:=}"
: "${GRAFANA_GOOGLE_OIDC_CLIENT_SECRET:=}"

TUNNEL_PID=""
NODE_NAMES=()
NODE_ZONES=()
NODE_IPS=()
INIT_NODE=""
INIT_NODE_ZONE=""
INIT_NODE_IP=""

cleanup_tunnel() {
  if [ -n "${TUNNEL_PID:-}" ]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
  fi
}

get_state_bucket() {
  if [ -z "${STATE_BUCKET}" ]; then
    local project_id
    project_id=$(gcloud config get-value project)
    STATE_BUCKET="${project_id}-tofu-state"
  fi
  printf '%s' "${STATE_BUCKET}"
}

discover_cluster_nodes() {
  local raw_nodes fallback_zone name zone ip role
  raw_nodes=$(gcloud compute instances list \
    --filter="labels.cluster=${CLUSTER_LABEL} AND labels.managed-by=${MANAGED_BY_LABEL}" \
    --format="csv[no-heading](name,zone.basename(),networkInterfaces[0].networkIP,labels.role)" \
    | sort -V)

  if [ -z "$raw_nodes" ]; then
    echo "::error::No GCP VMs found matching labels cluster=${CLUSTER_LABEL}, managed-by=${MANAGED_BY_LABEL}." >&2
    return 1
  fi

  fallback_zone=$(tofu -chdir="${TOFU_DIR}" output -raw zone 2>/dev/null || true)
  NODE_NAMES=()
  NODE_ZONES=()
  NODE_IPS=()
  INIT_NODE=""
  INIT_NODE_ZONE=""
  INIT_NODE_IP=""

  while IFS=',' read -r name zone ip role; do
    [ -z "$name" ] && continue
    zone="${zone:-$fallback_zone}"
    NODE_NAMES+=("$name")
    NODE_ZONES+=("$zone")
    NODE_IPS+=("$ip")
    if [ "$role" = "$INIT_ROLE_LABEL" ] && [ -z "$INIT_NODE" ]; then
      INIT_NODE="$name"
      INIT_NODE_ZONE="$zone"
      INIT_NODE_IP="$ip"
    fi
  done <<< "$raw_nodes"

  if [ -z "$INIT_NODE" ]; then
    INIT_NODE="${NODE_NAMES[0]}"
    INIT_NODE_ZONE="${NODE_ZONES[0]}"
    INIT_NODE_IP="${NODE_IPS[0]}"
  fi

  echo "Discovered ${#NODE_NAMES[@]} cluster nodes (primary: ${INIT_NODE} in ${INIT_NODE_ZONE}, IP: ${INIT_NODE_IP})."
}

backup_secret_to_gcs() {
  local ns="$1"
  local secret_name="$2"
  local gcs_path="$3"
  local bucket
  bucket=$(get_state_bucket)

  kubectl get secret "$secret_name" -n "$ns" -o json \
    | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
    | gcloud storage cp - "gs://${bucket}/${gcs_path}" 2>/dev/null || true
}

restore_secret_from_gcs() {
  local ns="$1"
  local secret_name="$2"
  local gcs_path="$3"
  local bucket cache_uri
  bucket=$(get_state_bucket)
  cache_uri="gs://${bucket}/${gcs_path}"

  if ! kubectl get secret "$secret_name" -n "$ns" >/dev/null 2>&1; then
    if gcloud storage ls "${cache_uri}" >/dev/null 2>&1; then
      echo "Restoring cached ${secret_name} Secret from ${cache_uri}..."
      gcloud storage cat "${cache_uri}" | kubectl apply -f -
      return 0
    fi
    return 1
  fi
  return 0
}

wait_for_control_plane() {
  echo "Waiting for ${INIT_NODE} to finish initialization..."
  for i in {1..40}; do
    if gcloud compute ssh "${INIT_NODE}" --tunnel-through-iap --zone="${INIT_NODE_ZONE}" \
      --command="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes" 2>/dev/null; then
      echo "${INIT_NODE} control-plane is up and healthy!"
      break
    fi
    echo "Waiting for RKE2 startup script on ${INIT_NODE} (attempt $i/40)..."
    sleep 15
  done
}

setup_iap_tunnel_and_kubeconfig() {
  echo "Fetching kubeconfig from ${INIT_NODE}..."
  gcloud compute ssh "${INIT_NODE}" --tunnel-through-iap --zone="${INIT_NODE_ZONE}" \
    --command="sudo cat /etc/rancher/rke2/rke2.yaml" > rke2-kubeconfig.yaml

  echo "Starting background IAP port-forwarding tunnel to ${INIT_NODE}:6443..."
  gcloud compute start-iap-tunnel "${INIT_NODE}" 6443 --local-host-port=localhost:6443 --zone="${INIT_NODE_ZONE}" &
  TUNNEL_PID=$!
  trap cleanup_tunnel EXIT
  sleep 5

  export KUBECONFIG="$(pwd)/rke2-kubeconfig.yaml"
  kubectl get nodes -o wide
}

configure_glusterfs_storage() {
  local node_count="${#NODE_NAMES[@]}"
  local idx n z ip peer_probes bricks volfile_servers

  echo "Configuring and verifying ${node_count}-node replicated GlusterFS /shared storage..."
  for idx in "${!NODE_NAMES[@]}"; do
    n="${NODE_NAMES[$idx]}"
    z="${NODE_ZONES[$idx]}"
    echo "Preparing GlusterFS brick disk (/mnt/shared-brick) and daemon on $n ($z)..."
    gcloud compute ssh "$n" --tunnel-through-iap --zone="$z" --command='
      if [ -b "/dev/disk/by-id/google-shared-disk" ]; then
        if ! sudo blkid /dev/disk/by-id/google-shared-disk | grep -q "TYPE="; then
          sudo mkfs.ext4 -m 0 -F /dev/disk/by-id/google-shared-disk
        fi
        sudo mkdir -p /mnt/shared-brick /shared
        if ! findmnt -M /mnt/shared-brick >/dev/null 2>&1; then
          UUID=$(sudo blkid -s UUID -o value /dev/disk/by-id/google-shared-disk)
          if ! grep -q "UUID=$UUID" /etc/fstab; then
            echo "UUID=$UUID /mnt/shared-brick ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
          fi
          sudo systemctl daemon-reload && sudo mount /mnt/shared-brick
        fi
        sudo mkdir -p /mnt/shared-brick/brick
        if ! command -v glusterd >/dev/null 2>&1; then
          sudo DEBIAN_FRONTEND=noninteractive apt-get update
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y glusterfs-server
        fi
        sudo systemctl enable --now glusterd.service
      fi
    '
  done

  peer_probes=""
  bricks=""
  for ip in "${NODE_IPS[@]}"; do
    if [ "$ip" != "$INIT_NODE_IP" ]; then
      peer_probes+="sudo gluster peer probe ${ip} || true; "
    fi
    bricks+=" ${ip}:/mnt/shared-brick/brick"
  done
  volfile_servers=$(IFS=:; echo "${NODE_IPS[*]}")

  echo "Forming ${node_count}-node GlusterFS trusted pool and 'shared-vol' replicated volume..."
  gcloud compute ssh "${INIT_NODE}" --tunnel-through-iap --zone="${INIT_NODE_ZONE}" --command="
    ${peer_probes}
    sleep 5
    if ! sudo gluster volume info shared-vol >/dev/null 2>&1; then
      sudo gluster volume create shared-vol replica ${node_count}${bricks} force
      sudo gluster volume set shared-vol network.ping-timeout 5
      sudo gluster volume set shared-vol cluster.quorum-type auto
      sudo gluster volume start shared-vol
    elif ! sudo gluster volume info shared-vol | grep -q 'Status: Started'; then
      sudo gluster volume start shared-vol || true
    fi
  "

  for idx in "${!NODE_NAMES[@]}"; do
    n="${NODE_NAMES[$idx]}"
    z="${NODE_ZONES[$idx]}"
    echo "Mounting GlusterFS volume 'shared-vol' at /shared on $n..."
    gcloud compute ssh "$n" --tunnel-through-iap --zone="$z" --command="
      sudo mkdir -p /shared
      if ! grep -q 'localhost:/shared-vol' /etc/fstab; then
        echo 'localhost:/shared-vol /shared glusterfs defaults,_netdev,backup-volfile-servers=${volfile_servers},x-systemd.requires=glusterd.service 0 0' | sudo tee -a /etc/fstab
      fi
      if ! findmnt -n -o FSTYPE -M /shared 2>/dev/null | grep -q 'glusterfs'; then
        sudo systemctl daemon-reload && sudo mount /shared
      fi
      sudo mkdir -p /etc/systemd/system/rke2-server.service.d
      printf '[Unit]\nWants=shared.mount\nAfter=shared.mount\n' | sudo tee /etc/systemd/system/rke2-server.service.d/10-wait-shared-mount.conf >/dev/null
      sudo systemctl daemon-reload
    "
  done

  gcloud compute ssh "${INIT_NODE}" --tunnel-through-iap --zone="${INIT_NODE_ZONE}" --command='
    if ! findmnt -n -o FSTYPE -M /shared 2>/dev/null | grep -q "glusterfs"; then
      echo "ERROR: /shared is not mounted as glusterfs on primary node." >&2
      exit 1
    fi
    sudo chmod 777 /shared
    sudo touch /shared/.glusterfs-mounted && sudo chmod 644 /shared/.glusterfs-mounted
    sudo mkdir -p /shared/docker-registry && sudo chmod 777 /shared/docker-registry
    sudo mkdir -p /shared/monitoring/prometheus /shared/monitoring/grafana
    sudo chown 65532:65532 /shared/monitoring/prometheus
    sudo chown 472:0 /shared/monitoring/grafana
    sudo chmod 755 /shared/monitoring /shared/monitoring/prometheus /shared/monitoring/grafana
  '

  echo "Checking /shared GlusterFS mount and volume status across all nodes:"
  gcloud compute ssh "${INIT_NODE}" --tunnel-through-iap --zone="${INIT_NODE_ZONE}" --command='sudo gluster volume status shared-vol' || true
  for idx in "${!NODE_NAMES[@]}"; do
    n="${NODE_NAMES[$idx]}"
    z="${NODE_ZONES[$idx]}"
    echo "--- $n /shared ---"
    gcloud compute ssh "$n" --tunnel-through-iap --zone="$z" --command='df -hT /shared' || true
  done
}

discover_app_namespaces() {
  python3 -c '
import glob, sys
try:
    import yaml
except ImportError:
    sys.exit(1)
namespaces = set()
for path in sorted(glob.glob("argocd/apps/*.yaml")):
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    ns = doc.get("spec", {}).get("destination", {}).get("namespace")
    if ns:
        namespaces.add(ns)
for ns in sorted(namespaces):
    print(ns)
' 2>/dev/null || awk '/^  destination:/{in_dest=1; next} in_dest && /^    namespace:/{print $2; in_dest=0}' argocd/apps/*.yaml | sort -u
}

create_core_namespaces() {
  local ns namespaces
  echo "Creating namespaces declared in argocd/apps/*.yaml..."
  namespaces=$(discover_app_namespaces)
  for ns in $namespaces; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  done
}

inject_cluster_secrets() {
  echo "Injecting secrets from GitHub Secrets..."
  if [ -n "$CF_API_TOKEN" ]; then
    kubectl create secret generic cloudflare-api-token-secret -n cert-manager \
      --from-literal=api-token="$CF_API_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
  fi

  if [ -n "$CF_TUNNEL_TOKEN" ]; then
    kubectl create secret generic cloudflared-token -n cloudflared \
      --from-literal=token="$CF_TUNNEL_TOKEN" \
      --from-literal=TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi

  if [ -n "$GOOGLE_OIDC_CLIENT_ID" ] && [ -n "$GOOGLE_OIDC_CLIENT_SECRET" ]; then
    kubectl create secret generic argocd-google-oidc -n argocd \
      --from-literal=clientID="$GOOGLE_OIDC_CLIENT_ID" \
      --from-literal=clientSecret="$GOOGLE_OIDC_CLIENT_SECRET" \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl label secret argocd-google-oidc -n argocd app.kubernetes.io/part-of=argocd --overwrite
  fi

  local mongo_root_pass mongo_replica_key
  local mongo_cache_path="secrets/mongodb.json"
  if [ -n "$MONGO_ROOT_PASSWORD" ] && [ -n "$MONGO_REPLICA_KEY" ]; then
    kubectl create secret generic mongodb -n mongodb \
      --from-literal=mongodb-root-password="$MONGO_ROOT_PASSWORD" \
      --from-literal=mongodb-replica-set-key="$MONGO_REPLICA_KEY" --dry-run=client -o yaml | kubectl apply -f -
    backup_secret_to_gcs mongodb mongodb "$mongo_cache_path"
  elif ! restore_secret_from_gcs mongodb mongodb "$mongo_cache_path"; then
    echo "Generating initial credentials for Secret/mongodb..."
    mongo_root_pass=$(openssl rand -base64 24 | tr -d '/+=')
    mongo_replica_key=$(openssl rand -base64 756 | tr -d '\n')
    kubectl create secret generic mongodb -n mongodb \
      --from-literal=mongodb-root-password="$mongo_root_pass" \
      --from-literal=mongodb-replica-set-key="$mongo_replica_key" --dry-run=client -o yaml | kubectl apply -f -
    backup_secret_to_gcs mongodb mongodb "$mongo_cache_path"
  fi
  if kubectl get secret mongodb -n mongodb >/dev/null 2>&1; then
    kubectl annotate secret mongodb -n mongodb argocd.argoproj.io/tracking-id- 2>/dev/null || true
    kubectl label secret mongodb -n mongodb app.kubernetes.io/instance- app.kubernetes.io/managed-by- helm.sh/chart- 2>/dev/null || true
  fi
}

configure_docker_registry_auth() {
  echo "Configuring Docker Registry authentication..."
  local reg_user reg_pass htpasswd_content generated_pass
  local registry_cache_path="secrets/docker-registry-auth.json"
  reg_user="${DOCKER_REGISTRY_USERNAME:-admin}"

  if [ -n "$DOCKER_REGISTRY_PASSWORD" ]; then
    reg_pass="$DOCKER_REGISTRY_PASSWORD"
    sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils
    htpasswd_content=$(htpasswd -Bbn "$reg_user" "$reg_pass")
    kubectl create secret generic docker-registry-auth -n docker-registry \
      --from-literal=htpasswd="$htpasswd_content" --dry-run=client -o yaml | kubectl apply -f -
    backup_secret_to_gcs docker-registry docker-registry-auth "$registry_cache_path"
  elif ! restore_secret_from_gcs docker-registry docker-registry-auth "$registry_cache_path"; then
    echo "Generating random initial password for docker-registry user '${reg_user}'..."
    sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils
    generated_pass=$(openssl rand -base64 18)
    htpasswd_content=$(htpasswd -Bbn "$reg_user" "$generated_pass")
    kubectl create secret generic docker-registry-auth -n docker-registry \
      --from-literal=htpasswd="$htpasswd_content" --dry-run=client -o yaml | kubectl apply -f -
    backup_secret_to_gcs docker-registry docker-registry-auth "$registry_cache_path"
    echo "::notice::Docker Registry auth secret generated for user '${reg_user}'. Set DOCKER_REGISTRY_PASSWORD in GitHub Secrets to override."
  fi
}

configure_grafana_auth() {
  echo "Configuring Grafana admin credentials..."
  local graf_user graf_pass
  local grafana_cache_path="secrets/grafana-admin.json"
  graf_user="${GRAFANA_ADMIN_USER:-admin}"

  if [ -n "$GRAFANA_ADMIN_PASSWORD" ]; then
    graf_pass="$GRAFANA_ADMIN_PASSWORD"
    kubectl create secret generic grafana-admin -n monitoring \
      --from-literal=admin-user="$graf_user" \
      --from-literal=admin-password="$graf_pass" \
      --dry-run=client -o yaml | kubectl apply -f -
    backup_secret_to_gcs monitoring grafana-admin "$grafana_cache_path"
  elif ! restore_secret_from_gcs monitoring grafana-admin "$grafana_cache_path"; then
    echo "Generating random initial password for Grafana user '${graf_user}'..."
    graf_pass=$(openssl rand -base64 18)
    kubectl create secret generic grafana-admin -n monitoring \
      --from-literal=admin-user="$graf_user" \
      --from-literal=admin-password="$graf_pass" \
      --dry-run=client -o yaml | kubectl apply -f -
    backup_secret_to_gcs monitoring grafana-admin "$grafana_cache_path"
    echo "::notice::Grafana admin secret generated for user '${graf_user}'. Set GRAFANA_ADMIN_PASSWORD in GitHub Secrets to override."
  fi

  configure_grafana_google_oidc
}

configure_grafana_google_oidc() {
  local oidc_client_id oidc_client_secret admin_email prev_rv new_rv role_attr_path
  oidc_client_id="${GRAFANA_GOOGLE_OIDC_CLIENT_ID:-${GOOGLE_OIDC_CLIENT_ID:-}}"
  oidc_client_secret="${GRAFANA_GOOGLE_OIDC_CLIENT_SECRET:-${GOOGLE_OIDC_CLIENT_SECRET:-}}"
  admin_email="${ARGOCD_ADMIN_EMAIL:-${ACME_EMAIL:-}}"

  if [ -z "${CUSTOM_DOMAIN:-}" ] || [ -z "$oidc_client_id" ] || [ -z "$oidc_client_secret" ] || [ -z "$admin_email" ]; then
    echo "Skipping Grafana Google OIDC secret (missing CUSTOM_DOMAIN, OIDC client credentials, or admin email)."
    return 0
  fi

  echo "Configuring Grafana Google OIDC secret..."
  prev_rv=$(kubectl get secret grafana-google-oidc -n monitoring -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)
  role_attr_path=$(kubectl get secret grafana-google-oidc -n monitoring -o jsonpath='{.data.GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -z "$role_attr_path" ]; then
    role_attr_path="email == '${admin_email}' && 'Admin'"
  fi

  kubectl create secret generic grafana-google-oidc -n monitoring \
    --from-literal=GF_SERVER_ROOT_URL="https://grafana.${CUSTOM_DOMAIN}" \
    --from-literal=GF_AUTH_GOOGLE_ENABLED="true" \
    --from-literal=GF_AUTH_GOOGLE_ALLOW_SIGN_UP="true" \
    --from-literal=GF_AUTH_GOOGLE_CLIENT_ID="${oidc_client_id}" \
    --from-literal=GF_AUTH_GOOGLE_CLIENT_SECRET="${oidc_client_secret}" \
    --from-literal=GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH="${role_attr_path}" \
    --from-literal=GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_STRICT="true" \
    --from-literal=GF_AUTH_GOOGLE_SKIP_ORG_ROLE_SYNC="false" \
    --dry-run=client -o yaml | kubectl apply -f -

  new_rv=$(kubectl get secret grafana-google-oidc -n monitoring -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)
  if [ -n "$new_rv" ] && [ "$new_rv" != "$prev_rv" ] && kubectl get deployment grafana -n monitoring >/dev/null 2>&1; then
    echo "Restarting Grafana Deployment to pick up updated Google OIDC secret..."
    kubectl rollout restart deployment/grafana -n monitoring
  fi
}

extract_chart_version() {
  local app_manifest="$1"
  python3 -c "import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))['spec']['sources'][0]['targetRevision'])" "$app_manifest" 2>/dev/null \
    || grep 'targetRevision:' "$app_manifest" | head -n1 | awk '{print $2}'
}

install_core_helm_charts() {
  # Extract chart versions dynamically from Argo CD manifests (Single Source of Truth)
  local cert_manager_version argocd_version admin_email
  cert_manager_version=$(extract_chart_version "argocd/apps/cert-manager.yaml")
  argocd_version=$(extract_chart_version "argocd/apps/argocd.yaml")

  if ! kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
    echo "Installing cert-manager (version: ${cert_manager_version}) via Helm..."
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    helm upgrade --install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --version "${cert_manager_version}" \
      --values cert-manager/values.yaml \
      --wait
  else
    echo "cert-manager is already installed; Argo CD GitOps manages lifecycle and upgrades."
  fi

  if [ -n "$ACME_EMAIL" ]; then
    echo "Applying Let's Encrypt ClusterIssuers..."
    sed "s/${PLACEHOLDER_EMAIL}/${ACME_EMAIL}/g" cert-manager/cluster-issuers.yaml | kubectl apply -f -
  fi

  if ! kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
    echo "Installing Argo CD (version: ${argocd_version}) via Helm..."
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm upgrade --install argocd argo/argo-cd \
      --namespace argocd \
      --version "${argocd_version}" \
      --values argocd/values.yaml \
      --wait
  else
    echo "Argo CD is already installed; Argo CD GitOps manages lifecycle and upgrades."
  fi

  admin_email="${ARGOCD_ADMIN_EMAIL:-$ACME_EMAIL}"
  if [ -n "$admin_email" ]; then
    echo "Configuring Argo CD admin RBAC for ${admin_email}..."
    kubectl -n argocd patch cm argocd-rbac-cm --type merge \
      -p "{\"data\": {\"policy.csv\": \"g, ${admin_email}, role:admin\"}}" 2>/dev/null || true
  fi
}

provision_tls_cert() {
  local ns="$1"
  local secret_name="$2"
  local cert_name="$3"
  local manifest="$4"
  local placeholder_host="$5"
  local target_host="$6"
  local cache_path="certs/${secret_name}.json"

  restore_secret_from_gcs "$ns" "$secret_name" "$cache_path" || true

  echo "Configuring Let's Encrypt certificate ${cert_name} (${target_host})..."
  sed "s/${placeholder_host}/${target_host}/g" "$manifest" | kubectl apply -f -

  echo "Waiting for TLS certificate ${cert_name} to be issued..."
  kubectl wait --for=condition=Ready "certificate/${cert_name}" -n "$ns" --timeout=180s 2>/dev/null || true

  if kubectl get secret "$secret_name" -n "$ns" >/dev/null 2>&1; then
    echo "Caching ${secret_name} Secret to GCS..."
    backup_secret_to_gcs "$ns" "$secret_name" "$cache_path"
  fi
}

configure_domain_and_certificates() {
  if [ -z "$CUSTOM_DOMAIN" ]; then
    return 0
  fi

  local reg_user
  reg_user="${DOCKER_REGISTRY_USERNAME:-admin}"

  kubectl -n argocd patch cm argocd-cm --type merge \
    -p "{\"data\": {\"url\": \"https://argocd.${CUSTOM_DOMAIN}\"}}" 2>/dev/null || true

  provision_tls_cert argocd argocd-server-tls argocd-server-tls \
    argocd/certificate.yaml "argocd.${PLACEHOLDER_DOMAIN}" "argocd.${CUSTOM_DOMAIN}"

  # Restart argocd-server if it has not yet loaded the issued certificate
  if ! kubectl logs -n argocd deployment/argocd-server --tail=50 2>/dev/null | grep -q "Loading TLS configuration from secret argocd/argocd-server-tls"; then
    echo "Restarting argocd-server to load the issued TLS certificate..."
    kubectl rollout restart deployment argocd-server -n argocd
    kubectl rollout status deployment argocd-server -n argocd --timeout=120s
  else
    echo "argocd-server already has the custom TLS secret loaded."
  fi

  provision_tls_cert docker-registry docker-registry-tls docker-registry-tls \
    argocd/certificate-registry.yaml "registry.${PLACEHOLDER_DOMAIN}" "registry.${CUSTOM_DOMAIN}"

  if [ -n "$DOCKER_REGISTRY_PASSWORD" ]; then
    echo "Configuring OCI registry credentials for Argo CD and devops-demo..."
    kubectl create secret docker-registry docker-registry-secret -n devops-demo \
      --docker-server="registry.${CUSTOM_DOMAIN}" \
      --docker-username="$reg_user" \
      --docker-password="$DOCKER_REGISTRY_PASSWORD" \
      --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic argocd-oci-registry -n argocd \
      --from-literal=type=helm \
      --from-literal=name=oci-charts \
      --from-literal=url="registry.${CUSTOM_DOMAIN}/charts" \
      --from-literal=enableOCI=true \
      --from-literal=username="$reg_user" \
      --from-literal=password="$DOCKER_REGISTRY_PASSWORD" \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl label secret argocd-oci-registry -n argocd \
      argocd.argoproj.io/secret-type=repository --overwrite
  fi
}

bootstrap_root_app() {
  echo "Bootstrapping Argo CD Root Application..."
  kubectl apply -f argocd/bootstrap/root-app.yaml

  if [ -n "$CUSTOM_DOMAIN" ] && [ -f argocd/apps/devops-demo.yaml ]; then
    # Allow Argo CD controller to reconcile root-apps ignoreDifferences/RespectIgnoreDifferences
    # before patching devops-demo with the custom registry domain.
    local phase
    for _ in $(seq 1 10); do
      phase=$(kubectl get application root-apps -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
      if [ "$phase" != "Running" ]; then
        break
      fi
      sleep 2
    done
    sleep 2
    echo "Applying devops-demo Argo CD Application with custom registry domain..."
    sed "s/registry.${PLACEHOLDER_DOMAIN}/registry.${CUSTOM_DOMAIN}/g" argocd/apps/devops-demo.yaml | kubectl apply -f -
  fi

  echo "Deployment and bootstrap sequence finished successfully!"
}

main() {
  discover_cluster_nodes
  wait_for_control_plane
  setup_iap_tunnel_and_kubeconfig
  configure_glusterfs_storage
  create_core_namespaces
  inject_cluster_secrets
  configure_docker_registry_auth
  configure_grafana_auth
  install_core_helm_charts
  configure_domain_and_certificates
  bootstrap_root_app
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
