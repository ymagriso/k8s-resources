[← Back to Main README](../README.md) | [← Previous: Argo CD, Cloudflare Tunnel & Google OIDC](04-argocd-cloudflare-oidc.md) | [Next: Operations & Cost Management →](06-operations-and-cleanup.md)

---

# 5. Deploy MongoDB ReplicaSet (`8.0`) & Prometheus Metrics Exporter

- [Overview & Architecture](#overview--architecture)
- [Resource Requests & Limits Sizing Rationale](#resource-requests--limits-sizing-rationale)
- [Step 1: GitOps Deployment via Argo CD](#step-1-gitops-deployment-via-argo-cd)
- [Step 2: Retrieve the Generated MongoDB Credentials](#step-2-retrieve-the-generated-mongodb-credentials)
- [Step 3: Expose MongoDB (`27017/TCP`) Externally via Cloudflare Tunnel](#step-3-expose-mongodb-27017tcp-externally-via-cloudflare-tunnel)
- [Step 4: Externalize Prometheus Metrics (`9216/TCP`) via Cloudflare Tunnel](#step-4-externalize-prometheus-metrics-9216tcp-via-cloudflare-tunnel)

---

## Overview & Architecture

MongoDB is deployed into a dedicated **`mongodb`** namespace via Argo CD ([`argocd/apps/mongodb.yaml`](../argocd/apps/mongodb.yaml)) using a custom Kustomize `StatefulSet` in [`argocd/apps/workloads/mongodb/`](../argocd/apps/workloads/mongodb/) running **MongoDB Community Server (`8.0.38-ubi9-slim`)** alongside a **`percona/mongodb_exporter:0.54.0`** sidecar.

### Key Design Choices
* **ReplicaSet Topology (1 Replica per Node):** Configured with `replicas: 3` and hard `podAntiAffinity` on `kubernetes.io/hostname`, guaranteeing that `mongodb-0`, `mongodb-1`, and `mongodb-2` are scheduled on separate RKE2 nodes (`rke2-node-1`, `rke2-node-2`, `rke2-node-3`).
* **No Arbiter & Ephemeral Storage:** 3 data-bearing replicas provide a full voting quorum without a separate arbiter, backed by `emptyDir` storage and `--wiredTigerCacheSizeGB 0.5`.
* **Minimal-CVE Pinned UBI9-slim & Distroless Images:** Uses `docker.io/mongodb/mongodb-community-server:8.0.38-ubi9-slim` (`runAsUser: 1000`, `readOnlyRootFilesystem: true`) and `docker.io/percona/mongodb_exporter:0.54.0` (`runAsUser: 65535`, `readOnlyRootFilesystem: true`), keeping explicit version tags tracked by Renovate (with major and minor upgrades disabled to remain on `8.0.x` LTS patches).
* **Bootstrap & GitOps Secret Stability:** [`bootstrap-cluster.sh`](../.github/scripts/bootstrap-cluster.sh) provisions (or restores/caches) `Secret/mongodb` out-of-band without storing credentials in Git, while `mongodb-0`'s entrypoint script idempotently runs `rs.initiate()` (`rs0`) and ensures the `root` user exists whenever peers have no active ReplicaSet.

---

## Resource Requests & Limits Sizing Rationale

Each of the 3 `e2-standard-2` nodes provides **2 vCPUs (`2000m`)** and **8 GiB RAM**. After accounting for RKE2 control-plane static pods (`etcd`, `kube-apiserver`, `kube-controller-manager`), Cilium, `cert-manager`, Argo CD, and `cloudflared`, the busiest node (`rke2-node-3`) has **`~465m` unrequested CPU** and **`~5.0 GiB` unrequested RAM** available.

| Container | CPU Request | CPU Limit | Memory Request | Memory Limit |
| :--- | :--- | :--- | :--- | :--- |
| **`mongodb`** (`resources`) | **`250m`** | **`1000m`** | **`1Gi`** | **`2Gi`** |
| **`metrics`** sidecar (`metrics.resources`) | **`50m`** | **`200m`** | **`64Mi`** | **`128Mi`** |
| **Total per Pod (1 per Node)** | **`300m`** | **`1200m`** | **`1088Mi`** | **`2176Mi`** |

1. **Guaranteed Scheduling Across All 3 Nodes (`300m` total CPU request):**
   Requesting `250m` (`mongodb`) + `50m` (`metrics`) = **`300m` CPU per pod** fits comfortably inside the `465m` unrequested CPU budget on `rke2-node-3`, ensuring all 3 replicas schedule immediately alongside `podAntiAffinityPreset: hard`.
2. **Burst Headroom (`1000m` CPU limit):**
   Control-plane static pods reserve CPU requests for safety but idle below 15% actual CPU utilization. A `1000m` (1 full vCPU) limit allows MongoDB to burst during replica set elections, initial syncs, and heavy queries without throttling.
3. **WiredTiger Cache Sizing (`1Gi` Request / `2Gi` Limit):**
   MongoDB's WiredTiger engine sizes its internal cache to `max(50% of (RAM Limit - 1 GB), 256 MB)`. With a **`2Gi` memory limit**, WiredTiger allocates **`512 MB`** to its cache and leaves **`1.5 GiB`** inside the container for connections, aggregation buffers, and `emptyDir` data—preventing `OOMKilled` events while keeping over **`2.8 GiB`** of free RAM on every node.
4. **Prometheus Exporter Sidecar (`50m`/`64Mi` Request, `200m`/`128Mi` Limit):**
   `mongodb-exporter` is a lightweight stateless Go process that translates MongoDB's `serverStatus` metrics when scraped on port `9216`.

---

## Step 1: GitOps Deployment via Argo CD

Because the Root App-of-Apps ([`argocd/bootstrap/root-app.yaml`](../argocd/bootstrap/root-app.yaml)) watches `argocd/apps/`, merging [`argocd/apps/mongodb.yaml`](../argocd/apps/mongodb.yaml) to `main` automatically deploys the `mongodb` Application.

Verify the rollout and check that one replica is running on each of the 3 nodes:

```bash
kubectl get pods -n mongodb -o wide
```

Expected output (3 pods, each with `2/2` containers ready — `mongodb` + `metrics` — across `rke2-node-1`, `rke2-node-2`, and `rke2-node-3`):

```text
NAME        READY   STATUS    RESTARTS   AGE   IP            NODE          NOMINATED NODE   READINESS GATES
mongodb-0   2/2     Running   0          2m    10.42.0.xxx   rke2-node-1   <none>           <none>
mongodb-1   2/2     Running   0          2m    10.42.1.xxx   rke2-node-2   <none>           <none>
mongodb-2   2/2     Running   0          2m    10.42.2.xxx   rke2-node-3   <none>           <none>
```

---

## Step 2: Retrieve the Generated MongoDB Credentials

Retrieve the `root` password generated in `Secret/mongodb`:

```bash
export MONGODB_ROOT_PASSWORD=$(kubectl get secret --namespace mongodb mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 -d)
echo "Root Password: $MONGODB_ROOT_PASSWORD"
```

---

## Step 3: Expose MongoDB (`27017/TCP`) Externally via Cloudflare Tunnel

Because the `cloudflared` connector already runs inside the cluster (`cloudflare` namespace), it can route TCP traffic directly to the headless MongoDB service without opening GCP firewall ports or paying for external load balancers.

1. **Declarative Tunnel Route (`tofu/cloudflare/routes.yaml`):**
   The `mongodb` TCP route and its proxied DNS CNAME record (`mongodb.<your-domain>`) are managed declaratively in [`tofu/cloudflare/routes.yaml`](../tofu/cloudflare/routes.yaml) and applied via [`.github/workflows/tofu-apply.yml`](../.github/workflows/tofu-apply.yml):
   * **Subdomain:** `mongodb`
   * **Service:** `tcp://mongodb-0.mongodb-headless.mongodb.svc.cluster.local:27017`

2. **Connect from Your Workstation Using Docker (No Local Install Needed):**
   Open a terminal and run `cloudflared access tcp` inside Docker to bridge `localhost:27017` to the Cloudflare Tunnel:

```bash
docker run --rm -it \
  -p 127.0.0.1:27017:27017 \
  cloudflare/cloudflared:latest \
  access tcp --hostname mongodb.<your-domain> --url 0.0.0.0:27017
```

3. **Connect with `mongosh` (via Docker) or MongoDB Compass:**
   In a second terminal, connect to `127.0.0.1:27017` with `?directConnection=true`:

```bash
docker run --rm -it --network host mongo:8.0.13 \
  mongosh "mongodb://root:${MONGODB_ROOT_PASSWORD}@127.0.0.1:27017/admin?directConnection=true" \
  --eval "rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))"
```

---

## Step 4: Externalize Prometheus Metrics (`9216/TCP`) via Cloudflare Tunnel

[`services.yaml`](../argocd/apps/workloads/mongodb/services.yaml) creates a `ClusterIP` service **`mongodb-metrics.mongodb.svc.cluster.local:9216`** exposing Prometheus metrics at `/metrics`.

1. **Declarative Tunnel Route (`tofu/cloudflare/routes.yaml`):**
   The `mongo-metrics` HTTP route and its proxied DNS CNAME record (`mongo-metrics.<your-domain>`) are managed declaratively in [`tofu/cloudflare/routes.yaml`](../tofu/cloudflare/routes.yaml) and applied via [`.github/workflows/tofu-apply.yml`](../.github/workflows/tofu-apply.yml):
   * **Subdomain:** `mongo-metrics`
   * **Service:** `http://mongodb-metrics.mongodb.svc.cluster.local:9216`
   * *(Recommended for production)* Under **Access → Applications**, add a Zero Trust Access policy (e.g., Google OIDC or a Service Token) for `mongo-metrics.<your-domain>` so only authorized scrapers or users can view metrics.

2. **Verify the Externalized Metrics Endpoint:**

```bash
curl -s https://mongo-metrics.<your-domain>/metrics | grep -E "^mongodb_up|^mongodb_ss_connections"
```

3. **In-Cluster Prometheus & Grafana Dashboards (`https://grafana.<your-domain>`):**
   The `monitoring` Argo CD application ([`argocd/apps/monitoring.yaml`](../argocd/apps/monitoring.yaml)) deploys **Prometheus** (scraping both `devops-demo` on `:8080/metrics` and all 3 MongoDB ReplicaSet pods via `mongodb-metrics` endpoint discovery on `:9216/metrics`) and **Grafana** with pre-provisioned dashboards (`DevOps Demo (sample-nodejs)` and `MongoDB ReplicaSet`), persisted on GlusterFS under `/shared/monitoring/`.

   **Google OAuth Login (Default When OIDC Secrets Are Configured):**
   * `.github/scripts/bootstrap-cluster.sh` provisions `Secret/grafana-google-oidc` in `monitoring`, reusing `ARGOCD_GOOGLE_OIDC_CLIENT_ID` / `ARGOCD_GOOGLE_OIDC_CLIENT_SECRET` (or optional `GRAFANA_GOOGLE_OIDC_CLIENT_ID` / `GRAFANA_GOOGLE_OIDC_CLIENT_SECRET` overrides if set) and granting `Admin` to `ARGOCD_ADMIN_EMAIL` (falling back to `ACME_EMAIL`).
   * Ensure `https://grafana.<your-domain>/login/google` is added to **Authorized redirect URIs** in your GCP OAuth 2.0 Web Client (see [Guide 04, Step 5](04-argocd-cloudflare-oidc.md#step-5-configure-google-oidc-authentication-disable-default-admin)).
   * `GF_AUTH_GOOGLE_ALLOW_SIGN_UP=true` allows Grafana to auto-create user records on first Google login, while `GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_STRICT=true` rejects any Google account whose email does not match `GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH`.

   **Local Admin Fallback (`Secret/grafana-admin`):**
   Retrieve the local admin credentials generated (or seeded via `GRAFANA_ADMIN_PASSWORD`) in `Secret/grafana-admin`:

```bash
kubectl get secret grafana-admin -n monitoring -o jsonpath="{.data.admin-user}" | base64 -d; echo
kubectl get secret grafana-admin -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

   **Supported Grafana Roles (`GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH`):**
   * `Viewer` — Read-only access to dashboards.
   * `Editor` — View, create, and edit dashboards and panels (cannot manage users, data sources, or org settings).
   * `Admin` — Full organization control (dashboards, data sources, alert rules, and organization settings).
   * `GrafanaAdmin` — Instance-wide super-admin (requires setting `GF_AUTH_GOOGLE_ALLOW_ASSIGN_GRAFANA_ADMIN=true` as well, since Grafana defaults `allow_assign_grafana_admin` to `false`).

   **Allowing Additional Google Email Addresses:**
   1. **GCP OAuth Consent Screen:** If your GCP OAuth app is in **Testing** mode, add each new email under **Google Auth platform → Audience → Test users** in the GCP Console (see [Guide 04, Step 5](04-argocd-cloudflare-oidc.md#step-5-configure-google-oidc-authentication-disable-default-admin)).
   2. **Update `GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH` in `Secret/grafana-google-oidc`:** Set a JMESPath expression mapping each allowed email to its Grafana role (`bootstrap-cluster.sh` preserves an existing `GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH` across re-runs), then restart Grafana so pods reload the Secret:

```bash
ROLE_EXPR='contains(`["admin@example.com"]`, email) && '\''Admin'\'' || contains(`["editor@example.com"]`, email) && '\''Editor'\'' || contains(`["viewer1@example.com", "viewer2@example.com"]`, email) && '\''Viewer'\'''
kubectl patch secret grafana-google-oidc -n monitoring \
  --type merge \
  -p "$(jq -n --arg expr "$ROLE_EXPR" '{stringData: {GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH: $expr}}')"
kubectl rollout restart deployment/grafana -n monitoring
```

---

[← Back to Main README](../README.md) | [← Previous: Argo CD, Cloudflare Tunnel & Google OIDC](04-argocd-cloudflare-oidc.md) | [Next: Operations & Cost Management →](06-operations-and-cleanup.md)
