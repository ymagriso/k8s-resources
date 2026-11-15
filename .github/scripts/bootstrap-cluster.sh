#!/usr/bin/env bash
# Bootstrap RKE2 cluster, GlusterFS /shared storage, core namespaces, secrets,
# cert-manager, Argo CD, Let's Encrypt certificates, and Root App-of-Apps.

set -e

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

cleanup_tunnel() {
  if [ -n "${TUNNEL_PID:-}" ]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
  fi
}

wait_for_control_plane() {
  echo "Waiting for rke2-node-1 to finish initialization..."
  for i in {1..40}; do
    if gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a \
      --command="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes" 2>/dev/null; then
      echo "rke2-node-1 control-plane is up and healthy!"
      break
    fi
    echo "Waiting for RKE2 startup script on rke2-node-1 (attempt $i/40)..."
    sleep 15
  done
}

setup_iap_tunnel_and_kubeconfig() {
  echo "Fetching kubeconfig from rke2-node-1..."
  gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a \
    --command="sudo cat /etc/rancher/rke2/rke2.yaml" > rke2-kubeconfig.yaml

  echo "Starting background IAP port-forwarding tunnel to rke2-node-1:6443..."
  gcloud compute start-iap-tunnel rke2-node-1 6443 --local-host-port=localhost:6443 --zone=me-west1-a &
  TUNNEL_PID=$!
  trap cleanup_tunnel EXIT
  sleep 5

  export KUBECONFIG="$(pwd)/rke2-kubeconfig.yaml"
  kubectl get nodes -o wide
}

configure_glusterfs_storage() {
  echo "Configuring and verifying 3-node replicated GlusterFS /shared storage..."
  for n in rke2-node-1 rke2-node-2 rke2-node-3; do
    echo "Preparing GlusterFS brick disk (/mnt/shared-brick) and daemon on $n..."
    gcloud compute ssh "$n" --tunnel-through-iap --zone=me-west1-a --command='
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

  echo "Forming 3-node GlusterFS trusted pool and 'shared-vol' replicated volume..."
  gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a --command='
    sudo gluster peer probe 10.10.0.12 || true
    sudo gluster peer probe 10.10.0.13 || true
    sleep 5
    if ! sudo gluster volume info shared-vol >/dev/null 2>&1; then
      sudo gluster volume create shared-vol replica 3 \
        10.10.0.11:/mnt/shared-brick/brick \
        10.10.0.12:/mnt/shared-brick/brick \
        10.10.0.13:/mnt/shared-brick/brick force
      sudo gluster volume set shared-vol network.ping-timeout 5
      sudo gluster volume set shared-vol cluster.quorum-type auto
      sudo gluster volume start shared-vol
    elif ! sudo gluster volume info shared-vol | grep -q "Status: Started"; then
      sudo gluster volume start shared-vol || true
    fi
  '

  for n in rke2-node-1 rke2-node-2 rke2-node-3; do
    echo "Mounting GlusterFS volume 'shared-vol' at /shared on $n..."
    gcloud compute ssh "$n" --tunnel-through-iap --zone=me-west1-a --command='
      sudo mkdir -p /shared
      if ! grep -q "localhost:/shared-vol" /etc/fstab; then
        echo "localhost:/shared-vol /shared glusterfs defaults,_netdev,backup-volfile-servers=10.10.0.11:10.10.0.12:10.10.0.13,x-systemd.requires=glusterd.service 0 0" | sudo tee -a /etc/fstab
      fi
      if ! findmnt -n -o FSTYPE -M /shared 2>/dev/null | grep -q "glusterfs"; then
        sudo systemctl daemon-reload && sudo mount /shared
      fi
    '
  done

  gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a --command='
    sudo chmod 777 /shared
    sudo mkdir -p /shared/docker-registry && sudo chmod 777 /shared/docker-registry
    sudo mkdir -p /shared/monitoring/prometheus /shared/monitoring/grafana
    sudo chown 65532:65532 /shared/monitoring/prometheus
    sudo chown 472:0 /shared/monitoring/grafana
    sudo chmod 755 /shared/monitoring /shared/monitoring/prometheus /shared/monitoring/grafana
  '

  echo "Checking /shared GlusterFS mount and volume status across all nodes:"
  gcloud compute ssh rke2-node-1 --tunnel-through-iap --zone=me-west1-a --command='sudo gluster volume status shared-vol' || true
  for n in rke2-node-1 rke2-node-2 rke2-node-3; do
    echo "--- $n /shared ---"
    gcloud compute ssh "$n" --tunnel-through-iap --zone=me-west1-a --command='df -hT /shared' || true
  done
}

create_core_namespaces() {
  echo "Creating core namespaces..."
  for ns in cert-manager cloudflared argocd mongodb docker-registry devops-demo monitoring; do
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

  local mongo_auth_cache_uri mongo_root_pass mongo_replica_key project_id
  project_id=$(gcloud config get-value project)
  mongo_auth_cache_uri="gs://${project_id}-tofu-state/secrets/mongodb.json"
  if [ -n "$MONGO_ROOT_PASSWORD" ] && [ -n "$MONGO_REPLICA_KEY" ]; then
    kubectl create secret generic mongodb -n mongodb \
      --from-literal=mongodb-root-password="$MONGO_ROOT_PASSWORD" \
      --from-literal=mongodb-replica-set-key="$MONGO_REPLICA_KEY" --dry-run=client -o yaml | kubectl apply -f -
    kubectl get secret mongodb -n mongodb -o json \
      | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
      | gcloud storage cp - "${mongo_auth_cache_uri}" 2>/dev/null || true
  elif ! kubectl get secret mongodb -n mongodb >/dev/null 2>&1; then
    if gcloud storage ls "${mongo_auth_cache_uri}" >/dev/null 2>&1; then
      echo "Restoring cached mongodb Secret from ${mongo_auth_cache_uri}..."
      gcloud storage cat "${mongo_auth_cache_uri}" | kubectl apply -f -
    else
      echo "Generating initial credentials for Secret/mongodb..."
      mongo_root_pass=$(openssl rand -base64 24 | tr -d '/+=')
      mongo_replica_key=$(openssl rand -base64 756 | tr -d '\n')
      kubectl create secret generic mongodb -n mongodb \
        --from-literal=mongodb-root-password="$mongo_root_pass" \
        --from-literal=mongodb-replica-set-key="$mongo_replica_key" --dry-run=client -o yaml | kubectl apply -f -
      kubectl get secret mongodb -n mongodb -o json \
        | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
        | gcloud storage cp - "${mongo_auth_cache_uri}" 2>/dev/null || true
    fi
  fi
  if kubectl get secret mongodb -n mongodb >/dev/null 2>&1; then
    kubectl annotate secret mongodb -n mongodb argocd.argoproj.io/tracking-id- 2>/dev/null || true
    kubectl label secret mongodb -n mongodb app.kubernetes.io/instance- app.kubernetes.io/managed-by- helm.sh/chart- 2>/dev/null || true
  fi
}

configure_docker_registry_auth() {
  echo "Configuring Docker Registry authentication..."
  local project_id registry_auth_cache_uri reg_user reg_pass htpasswd_content generated_pass
  project_id=$(gcloud config get-value project)
  registry_auth_cache_uri="gs://${project_id}-tofu-state/secrets/docker-registry-auth.json"
  reg_user="${DOCKER_REGISTRY_USERNAME:-admin}"

  if [ -n "$DOCKER_REGISTRY_PASSWORD" ]; then
    reg_pass="$DOCKER_REGISTRY_PASSWORD"
    sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils
    htpasswd_content=$(htpasswd -Bbn "$reg_user" "$reg_pass")
    kubectl create secret generic docker-registry-auth -n docker-registry \
      --from-literal=htpasswd="$htpasswd_content" --dry-run=client -o yaml | kubectl apply -f -
    kubectl get secret docker-registry-auth -n docker-registry -o json \
      | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
      | gcloud storage cp - "${registry_auth_cache_uri}" 2>/dev/null || true
  elif ! kubectl get secret docker-registry-auth -n docker-registry >/dev/null 2>&1; then
    if gcloud storage ls "${registry_auth_cache_uri}" >/dev/null 2>&1; then
      echo "Restoring cached docker-registry-auth Secret from ${registry_auth_cache_uri}..."
      gcloud storage cat "${registry_auth_cache_uri}" | kubectl apply -f -
    else
      echo "Generating random initial password for docker-registry user '${reg_user}'..."
      sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils
      generated_pass=$(openssl rand -base64 18)
      htpasswd_content=$(htpasswd -Bbn "$reg_user" "$generated_pass")
      kubectl create secret generic docker-registry-auth -n docker-registry \
        --from-literal=htpasswd="$htpasswd_content" --dry-run=client -o yaml | kubectl apply -f -
      kubectl get secret docker-registry-auth -n docker-registry -o json \
        | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
        | gcloud storage cp - "${registry_auth_cache_uri}" 2>/dev/null || true
      echo "::notice::Docker Registry auth secret generated for user '${reg_user}'. Set DOCKER_REGISTRY_PASSWORD in GitHub Secrets to override."
    fi
  fi
}

configure_grafana_auth() {
  echo "Configuring Grafana admin credentials..."
  local project_id grafana_auth_cache_uri graf_user graf_pass
  project_id=$(gcloud config get-value project)
  grafana_auth_cache_uri="gs://${project_id}-tofu-state/secrets/grafana-admin.json"
  graf_user="${GRAFANA_ADMIN_USER:-admin}"

  if [ -n "$GRAFANA_ADMIN_PASSWORD" ]; then
    graf_pass="$GRAFANA_ADMIN_PASSWORD"
    kubectl create secret generic grafana-admin -n monitoring \
      --from-literal=admin-user="$graf_user" \
      --from-literal=admin-password="$graf_pass" \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl get secret grafana-admin -n monitoring -o json \
      | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
      | gcloud storage cp - "${grafana_auth_cache_uri}" 2>/dev/null || true
  elif ! kubectl get secret grafana-admin -n monitoring >/dev/null 2>&1; then
    if gcloud storage ls "${grafana_auth_cache_uri}" >/dev/null 2>&1; then
      echo "Restoring cached grafana-admin Secret from ${grafana_auth_cache_uri}..."
      gcloud storage cat "${grafana_auth_cache_uri}" | kubectl apply -f -
    else
      echo "Generating random initial password for Grafana user '${graf_user}'..."
      graf_pass=$(openssl rand -base64 18)
      kubectl create secret generic grafana-admin -n monitoring \
        --from-literal=admin-user="$graf_user" \
        --from-literal=admin-password="$graf_pass" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl get secret grafana-admin -n monitoring -o json \
        | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
        | gcloud storage cp - "${grafana_auth_cache_uri}" 2>/dev/null || true
      echo "::notice::Grafana admin secret generated for user '${graf_user}'. Set GRAFANA_ADMIN_PASSWORD in GitHub Secrets to override."
    fi
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
    sed "s/your-email@yourdomain.com/${ACME_EMAIL}/g" cert-manager/cluster-issuers.yaml | kubectl apply -f -
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

configure_domain_and_certificates() {
  if [ -z "$CUSTOM_DOMAIN" ]; then
    return 0
  fi

  local project_id cert_cache_uri registry_cert_cache_uri reg_user
  project_id=$(gcloud config get-value project)
  cert_cache_uri="gs://${project_id}-tofu-state/certs/argocd-server-tls.json"
  reg_user="${DOCKER_REGISTRY_USERNAME:-admin}"

  # Restore cached TLS secret from GCS on fresh cluster builds to avoid Let's Encrypt rate limits
  if ! kubectl get secret argocd-server-tls -n argocd >/dev/null 2>&1; then
    if gcloud storage ls "${cert_cache_uri}" >/dev/null 2>&1; then
      echo "Restoring cached argocd-server-tls Secret from ${cert_cache_uri}..."
      gcloud storage cat "${cert_cache_uri}" | kubectl apply -f -
    fi
  fi

  echo "Configuring domain and Let's Encrypt certificates..."
  sed "s/argocd.yourdomain.com/argocd.${CUSTOM_DOMAIN}/g" argocd/certificate.yaml | kubectl apply -f -
  kubectl -n argocd patch cm argocd-cm --type merge \
    -p "{\"data\": {\"url\": \"https://argocd.${CUSTOM_DOMAIN}\"}}" 2>/dev/null || true

  echo "Waiting for Argo CD TLS certificate to be issued..."
  kubectl wait --for=condition=Ready certificate/argocd-server-tls -n argocd --timeout=180s 2>/dev/null || true

  # Persist valid TLS secret to GCS state bucket so cluster destroy/recreate cycles reuse it
  if kubectl get secret argocd-server-tls -n argocd >/dev/null 2>&1; then
    echo "Caching argocd-server-tls Secret to ${cert_cache_uri}..."
    kubectl get secret argocd-server-tls -n argocd -o json \
      | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
      | gcloud storage cp - "${cert_cache_uri}"
  fi

  # Restart argocd-server if it has not yet loaded the issued certificate
  if ! kubectl logs -n argocd deployment/argocd-server --tail=50 2>/dev/null | grep -q "Loading TLS configuration from secret argocd/argocd-server-tls"; then
    echo "Restarting argocd-server to load the issued TLS certificate..."
    kubectl rollout restart deployment argocd-server -n argocd
    kubectl rollout status deployment argocd-server -n argocd --timeout=120s
  else
    echo "argocd-server already has the custom TLS secret loaded."
  fi

  registry_cert_cache_uri="gs://${project_id}-tofu-state/certs/docker-registry-tls.json"

  # Restore cached Docker Registry TLS secret from GCS on fresh cluster builds to avoid Let's Encrypt rate limits
  if ! kubectl get secret docker-registry-tls -n docker-registry >/dev/null 2>&1; then
    if gcloud storage ls "${registry_cert_cache_uri}" >/dev/null 2>&1; then
      echo "Restoring cached docker-registry-tls Secret from ${registry_cert_cache_uri}..."
      gcloud storage cat "${registry_cert_cache_uri}" | kubectl apply -f -
    fi
  fi

  echo "Configuring Docker Registry domain and Let's Encrypt certificates..."
  sed "s/registry.yourdomain.com/registry.${CUSTOM_DOMAIN}/g" argocd/certificate-registry.yaml | kubectl apply -f -

  echo "Waiting for Docker Registry TLS certificate to be issued..."
  kubectl wait --for=condition=Ready certificate/docker-registry-tls -n docker-registry --timeout=180s 2>/dev/null || true

  # Persist valid TLS secret to GCS state bucket so cluster destroy/recreate cycles reuse it
  if kubectl get secret docker-registry-tls -n docker-registry >/dev/null 2>&1; then
    echo "Caching docker-registry-tls Secret to ${registry_cert_cache_uri}..."
    kubectl get secret docker-registry-tls -n docker-registry -o json \
      | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
      | gcloud storage cp - "${registry_cert_cache_uri}"
  fi

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
    sed "s/registry.yourdomain.com/registry.${CUSTOM_DOMAIN}/g" argocd/apps/devops-demo.yaml | kubectl apply -f -
  fi

  echo "Deployment and bootstrap sequence finished successfully!"
}

main() {
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
