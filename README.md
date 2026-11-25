# GitOps Observability Stack on Kubernetes

Metrics, logs and traces for a Kubernetes cluster: **Prometheus, Loki, Tempo, Grafana Alloy and Grafana**, deployed entirely from Git with **Argo CD**.

You push a change to Git, and Argo CD makes the cluster match it. No `helm install`, no manual `kubectl apply` for the stack.

---

## What you get

| Question | Signal | Tool |
|---|---|---|
| Is something wrong? | **Metrics**: numbers over time | Prometheus |
| What exactly happened? | **Logs**: messages from every pod and Kubernetes events | Loki |
| Where is it slow or failing? | **Traces**: one request's path across services | Tempo |
| One place to see all three | Dashboards, Explore, log ↔ trace links | Grafana |

---

## Core concepts

### GitOps with Argo CD
- **Git is the source of truth.** The desired state of the cluster lives in this repo.
- **Argo CD** runs inside the cluster, watches the repo, renders the Helm chart and applies it.
- **Self-heal:** if someone changes a resource by hand, Argo CD puts it back to what Git says.
- **AppProject:** a guard rail that limits which repo, namespaces and cluster-wide resource kinds the apps may use.
- **Application:** says *what* to deploy (repo + path + values files) and *where* (cluster + namespace).

### Umbrella Helm chart
One chart (`charts/observability`) that has no workloads of its own. It lists the real charts as **dependencies** in `Chart.yaml`:

```
observability (umbrella)
├── prometheus   (Prometheus, Alertmanager, kube-state-metrics, node-exporter)
├── grafana
├── seaweedfs
├── loki
├── alloy
└── tempo
```

- Each dependency is configured under its **own top-level key** in `values.yaml` (`prometheus:`, `loki:`, ...).
- `condition: <name>.enabled` turns a component on or off.
- The downloaded charts (`charts/*.tgz`) are **committed to Git**, so Argo CD renders exactly the same versions every time.

### Values overlays
| File | Purpose |
|---|---|
| `charts/observability/values.yaml` | Production-shaped base: replicas, retention, storage sizes |
| `argocd/values-dev.yaml` | Small sizes for a laptop (kind) |

Argo CD merges them in order, so **the later file wins**. Maps merge key by key; lists are replaced as a whole.

### Secrets stay out of Git
`bootstrap/create-secrets.sh` creates two Kubernetes Secrets directly in the cluster:

| Secret | Used by | Contents |
|---|---|---|
| `grafana-admin` | Grafana | admin username and password |
| `seaweedfs-s3` | SeaweedFS, Loki, Tempo | one S3 key pair (random), plus the SeaweedFS user list |

The values files only **reference** these Secrets by name.

### Object storage
Loki and Tempo store their data in **S3-compatible object storage**. **SeaweedFS** provides an S3 API inside the cluster, so the stack runs anywhere, with no cloud account. Each tool keeps recent data on its own small disk (WAL) and flushes it to its bucket.

### One collector: Grafana Alloy
**Alloy** collects pod logs and Kubernetes events **through the Kubernetes API** (no host mounts) and receives traces from apps over **OTLP**. Its pipeline is written in `config.alloy`:

```
discover pods → add labels → read logs → push to Loki
read Kubernetes events ─────────────────→ push to Loki
receive OTLP traces → batch ────────────→ send to Tempo
```

---

## Architecture

```
                         ┌──────────────── GitHub repo ────────────────┐
                         │ charts/observability  apps/demo  argocd/     │
                         └───────────────────────┬──────────────────────┘
                                                 │ watch + sync
┌────────────────────────── kind cluster ────────┼───────────────────────────────────────┐
│                                                ▼                                        │
│                                           Argo CD                                       │
│                                                │ renders Helm, applies                  │
│        demo namespace                          ▼        observability namespace          │
│  ┌──────────────────────────┐                                                           │
│  │ loadgen → order → payment│──OTLP :4317──▶ Alloy ──traces──▶ Tempo ──┐                 │
│  └──────────────────────────┘                 ▲  │                     │                 │
│                                               │  └──logs──▶ Loki ──────┼──▶ SeaweedFS    │
│  all pods (stdout) + k8s events ── K8s API ───┘                        │    (S3 buckets) │
│                                                                                         │
│  node-exporter, kube-state-metrics, pods ◀── scrape ── Prometheus                       │
│                                                                                         │
│                         Grafana ── queries ──▶ Prometheus, Loki, Tempo                  │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

| Signal | Path |
|---|---|
| Metrics | Prometheus **pulls** from node-exporter, kube-state-metrics and annotated pods |
| Logs | Pods and events → Alloy (K8s API) → Loki → bucket `loki-chunks` |
| Traces | Demo apps (OTel SDK) → Alloy :4317 → Tempo → bucket `tempo-traces` |
| Correlation | Log line `trace_id=...` → Tempo trace, and trace → its logs in Loki |

---

## Tech stack

| Tool | Version (chart / app) | Role |
|---|---|---|
| kind | — | Local Kubernetes: 1 control plane + 2 workers |
| Argo CD | v3.6.1 | GitOps controller |
| Prometheus | 29.47.2 / v3.16.0 | Metrics storage and PromQL |
| Grafana | 14.4.2 / 13.3.1 | Dashboards, Explore, data sources as code |
| SeaweedFS | 4.55.0 | S3-compatible object storage (all-in-one) |
| Loki | 21.6.0 / 3.7.10 | Logs, Monolithic mode, LogQL |
| Grafana Alloy | 1.16.0 / v1.22.0 | Collector for logs, events and traces |
| Tempo | 3.2.1 / 3.1.1 | Traces, single binary, TraceQL |
| Demo apps | Python 3.12 + Flask | order → payment, OpenTelemetry auto-instrumentation |

---

## Repository structure

```
gitops-observability-stack/
├── cluster/
│   └── kind-config.yaml            # 3-node kind cluster
├── bootstrap/
│   ├── install-argocd.sh           # installs Argo CD with Helm, prints admin password
│   └── create-secrets.sh           # creates grafana-admin and seaweedfs-s3 Secrets
├── argocd/
│   ├── project.yaml                # AppProject: allowed repo, namespaces, kinds
│   ├── observability-app.yaml      # Application: the umbrella chart
│   ├── demo-app.yaml               # Application: the demo apps
│   └── values-dev.yaml             # small sizes for kind
├── charts/observability/
│   ├── Chart.yaml                  # 6 dependencies
│   ├── Chart.lock
│   ├── charts/                     # vendored dependency .tgz files
│   ├── values.yaml                 # production-shaped base values
│   ├── templates/
│   │   └── alloy-config.yaml       # ConfigMap built from config.alloy
│   └── files/alloy/
│       └── config.alloy            # Alloy pipeline: logs, events, traces
├── apps/demo/
│   └── demo-app.yaml               # order, payment, loadgen
└── README.md
```

---

## Setup

### Prerequisites
Docker Desktop (at least 6 GB of memory), `kind`, `kubectl`, `helm`, `git`.

### 1. Create the cluster
```bash
kind create cluster --config cluster/kind-config.yaml
kubectl get nodes
```
Expected: 3 nodes `Ready`.

### 2. Install Argo CD
```bash
bash bootstrap/install-argocd.sh
```
Expected: Argo CD pods `Running`, and the admin password printed at the end.

### 3. Create the Secrets
```bash
bash bootstrap/create-secrets.sh
```
It asks for a Grafana username and password (letters and digits only) and generates the S3 keys. Running it again keeps the existing S3 keys.

### 4. Register the project and apps
```bash
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/observability-app.yaml
kubectl apply -f argocd/demo-app.yaml
```
From now on, every `git push` to `main` is deployed automatically.

### 5. Check
```bash
kubectl -n observability get pods
kubectl -n demo get pods
```
Expected: all pods `Running`. The demo pods take 1–3 minutes (they install Python packages at start).

---

## Access the UIs

**Argo CD**
```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```
Open https://localhost:8080 and log in as `admin`. Both apps should show **Healthy** and **Synced**.

**Grafana**
```bash
kubectl -n observability port-forward svc/observability-grafana 3000:80
```
Open http://localhost:3000 and log in with the credentials from step 3. The Prometheus, Loki and Tempo data sources are already provisioned.

---

## Verify each signal

### Metrics (Prometheus)
Explore → **Prometheus**:
```promql
up
```
```promql
sum by (namespace) (kube_pod_info)
```

### Logs (Loki)
Explore → **Loki** → Code:
```logql
{namespace="observability"}
```
```logql
{job="kubernetes-events"} |= "Failed"
```
```logql
sum by (namespace) (count_over_time({namespace=~".+"}[5m]))
```
Labels added by Alloy: `namespace`, `pod`, `container`, `app`.

### Traces (Tempo)
Explore → **Tempo** → Search → Service name `order` → Run query. Open a trace:

```
order    GET /order      ████████████████████
 └ GET   (call)            ██████████████████
   └ payment GET /pay       █████████████████   ← 500 about 20% of the time
```

Only failed requests:
```traceql
{ status = error }
```

### Correlation
- **Log → trace:** in Loki run `{namespace="demo", app="order"}`, expand a line, click **View trace**.
- **Trace → logs:** in a Tempo trace, open a span and click **Related logs**.

---

## How the pieces connect

| Setting | Where | Effect |
|---|---|---|
| `existingSecret: grafana-admin` | `values.yaml` → grafana | Grafana admin login comes from the Secret |
| `existingConfigSecret: seaweedfs-s3` | `values.yaml` → seaweedfs | SeaweedFS accepts only the generated S3 key |
| `extraEnvFrom: seaweedfs-s3` + `${AWS_ACCESS_KEY_ID}` | `values.yaml` → loki, tempo | Keys reach Loki and Tempo as env vars, expanded at startup |
| `createBuckets` | `values.yaml` → seaweedfs | Creates `loki-chunks`, `loki-ruler`, `tempo-traces` |
| `configMap.name: alloy-config` | `values.yaml` → alloy | Alloy runs our `config.alloy` |
| `extraPorts` 4317 / 4318 | `values.yaml` → alloy | Alloy Service accepts OTLP from apps |
| `derivedFields` / `tracesToLogsV2` | `values.yaml` → grafana datasources | Log ↔ trace links |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `apps/demo/demo-app.yaml` | Apps send traces to `observability-alloy:4317` |
| `OTEL_PYTHON_LOG_CORRELATION` | `apps/demo/demo-app.yaml` | Adds `trace_id=` to every app log line |

---

## Render locally before pushing

```bash
cd charts/observability
helm dependency build
helm template observability . -n observability -f values.yaml -f ../../argocd/values-dev.yaml > ../../rendered-dev.yaml
```
This is the same rendering Argo CD does. If it renders cleanly here, it will sync cleanly in the cluster.

---

## Clean up
```bash
kind delete cluster --name observability
```

---

Author: **Aniruddha Choudhary**: Cloud / DevOps / MLOps engineer.
