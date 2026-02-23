# Grafana Tempo Distributed Tracing PoC

Full observability stack on k3d: **Traces (Tempo) + Metrics (Prometheus) + Logs (Loki)** with correlation.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  k3d cluster: tempo-poc                                          │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ namespace: application                                      │ │
│  │  ┌──────────┐                                               │ │
│  │  │  HotROD  │──── traces (OTLP HTTP) ──────────┐           │ │
│  │  │  :8080   │                                   │           │ │
│  │  └──────────┘                                   │           │ │
│  └─────────────────────────────────────────────────│───────────┘ │
│                                                    │             │
│  ┌─────────────────────────────────────────────────│───────────┐ │
│  │ namespace: observability                        ▼           │ │
│  │                                                             │ │
│  │  ┌──────────────┐  traces  ┌──────────────┐                │ │
│  │  │ Grafana Alloy│────────> │    Tempo      │                │ │
│  │  │ (DaemonSet)  │ (OTLP)  │  :3200 HTTP   │                │ │
│  │  │ :4317/4318   │         │  :4317 OTLP   │                │ │
│  │  │              │         └──────┬────────┘                │ │
│  │  │ reads        │   span-metrics │(remote write)           │ │
│  │  │ /var/log/pods│                ▼                         │ │
│  │  │ for logs ──┐ │      ┌──────────────┐                    │ │
│  │  └────────────│─┘      │  Prometheus   │                    │ │
│  │               │        │   :9090       │                    │ │
│  │               │        └──────┬───────┘                    │ │
│  └───────────────│───────────────│────────────────────────────┘ │
│                  │               │                              │
│  ┌───────────────│───────────────│────────────────────────────┐ │
│  │ namespace: loki│               │                            │ │
│  │               ▼               │                            │ │
│  │  ┌──────────────────────┐     │                            │ │
│  │  │ Loki (Distributed)   │     │                            │ │
│  │  │ gateway :3100         │     │                            │ │
│  │  │ + MinIO (S3 storage)  │     │                            │ │
│  │  └─────────┬─────────────┘     │                            │ │
│  └────────────│───────────────────│────────────────────────────┘ │
│               │                   │                              │
│               ▼                   ▼                              │
│  ┌──────────────────────────────────────────────┐               │
│  │         Grafana UI  :3000                    │               │
│  │  Datasources: Tempo, Prometheus, Loki        │               │
│  │  Trace->Logs | Logs->Traces | Service Map    │               │
│  └──────────────────────────────────────────────┘               │
└──────────────────────────────────────────────────────────────────┘
```

## Without DaemonSet (Traces Only)

``` 
┌─────────────────────────────────────────────────────────┐
│  k3d cluster (3 nodes)                                  │
│                                                         │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐           │
│  │  Node 0  │   │  Node 1  │   │  Node 2  │           │
│  │          │   │          │   │          │           │
│  │ [HotROD] │   │          │   │          │           │
│  └────┬─────┘   └──────────┘   └──────────┘           │
│       │                                                 │
│       │ traces (OTLP over network)                      │
│       │ network works across any node                   │
│       ▼                                                 │
│  ┌──────────┐                                           │
│  │  Alloy   │  ← single Deployment (runs on 1 node)    │
│  │ (Node 1) │    receives traces over network = OK      │
│  └────┬─────┘                                           │
│       │                                                 │
│       ▼                                                 │
│  ┌──────────┐                                           │
│  │  Tempo   │                                           │
│  └──────────┘                                           │
└─────────────────────────────────────────────────────────┘
```

## With DaemonSet (Our Setup - Traces + Logs)

```
┌──────────────────────────────────────────────────────────────────┐
│  k3d cluster (3 nodes)                                           │
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐ │
│  │     Node 0       │  │     Node 1       │  │    Node 2      │ │
│  │                  │  │                  │  │                │ │
│  │  [HotROD pod]    │  │  [Tempo pod]     │  │  [Grafana pod] │ │
│  │       │          │  │                  │  │                │ │
│  │       │ traces   │  │                  │  │                │ │
│  │       │ (OTLP)   │  │                  │  │                │ │
│  │       ▼          │  │                  │  │                │ │
│  │  ┌──────────┐    │  │  ┌──────────┐    │  │  ┌──────────┐  │ │
│  │  │  Alloy   │    │  │  │  Alloy   │    │  │  │  Alloy   │  │ │
│  │  │ DaemonSet│    │  │  │ DaemonSet│    │  │  │ DaemonSet│  │ │
│  │  └──┬───┬───┘    │  │  └──┬───┬───┘    │  │  └──┬───┬───┘  │ │
│  │     │   │        │  │     │   │        │  │     │   │      │ │
│  │     │   │reads   │  │     │   │reads   │  │     │   │reads │ │
│  │     │   ▼        │  │     │   ▼        │  │     │   ▼      │ │
│  │     │ /var/log/  │  │     │ /var/log/  │  │     │ /var/log/│ │
│  │     │  pods/     │  │     │  pods/     │  │     │  pods/   │ │
│  │     │ (HotROD    │  │     │ (Tempo     │  │     │ (Grafana │ │
│  │     │  logs)     │  │     │  logs)     │  │     │  logs)   │ │
│  └─────│────────────┘  └─────│────────────┘  └─────│──────────┘ │
│        │                     │                     │            │
│        │ traces              │ logs                │ logs       │
│        ▼                     ▼                     ▼            │
│   ┌──────────┐         ┌──────────┐                             │
│   │  Tempo   │         │   Loki   │                             │
│   └──────────┘         └──────────┘                             │
└──────────────────────────────────────────────────────────────────┘
```

## What breaks WITHOUT DaemonSet (single Alloy + logs)

```
┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐
│     Node 0       │  │     Node 1       │  │    Node 2      │
│                  │  │                  │  │                │
│  [HotROD pod]    │  │  [Tempo pod]     │  │  [Grafana pod] │
│                  │  │                  │  │                │
│  /var/log/pods/  │  │  /var/log/pods/  │  │  /var/log/pods/│
│   hotrod.log     │  │   tempo.log      │  │   grafana.log  │
│                  │  │                  │  │                │
│  NO Alloy here   │  │  ┌──────────┐    │  │  NO Alloy here │
│  ❌ logs LOST    │  │  │  Alloy   │    │  │  ❌ logs LOST  │
│                  │  │  │(only one)│    │  │                │
│                  │  │  └────┬─────┘    │  │                │
│                  │  │       │          │  │                │
│                  │  │  can only read   │  │                │
│                  │  │  Node 1 logs     │  │                │
└──────────────────┘  └──────────────────┘  └────────────────┘

Result: Only Tempo logs collected. HotROD and Grafana logs are LOST.

```


## Data Flow

| Signal  | Path                                  | Protocol      |
|---------|---------------------------------------|---------------|
| Traces  | HotROD -> Alloy -> Tempo              | OTLP HTTP     |
| Metrics | Tempo metrics-generator -> Prometheus | Remote Write  |
| Logs    | Node /var/log/pods -> Alloy -> Loki   | Loki HTTP API |

## Prerequisites

- **k3d** >= v5.x
- **Helm** >= v3.x
- **kubectl** configured

## Quick Setup

```bash
./setup/setup.sh
```

## Manual Setup

### Step 1: Create 3d cluster

```bash
k3d cluster create --config setup/k3d-cluster.yaml
kubectl get nodes
```

### Step 2: Create namespaces + Helm repos

```bash
kubectl create namespace observability
kubectl create namespace application
kubectl create namespace loki

helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Step 3: Deploy MinIO for Loki storage

```bash
docker run -d --name minio --network k3d-tempo-poc \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin123 \
  minio/minio server /data --console-address ":9001"

docker exec minio mc alias set local http://localhost:9000 minioadmin minioadmin123
docker exec minio mc mb local/loki-poc

MINIO_IP=$(docker inspect minio --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
sed -i.bak "s|endpoint: http://.*:9000|endpoint: http://$MINIO_IP:9000|g" mgmt/values_override.yaml
```

### Step 4: Deploy Loki (Distributed)

```bash
cd mgmt && helm dependency build
helm install loki . --namespace loki \
  -f values_loki.yaml -f values_ingester.yaml -f values_distributor.yaml \
  -f values_querier.yaml -f values_queryFrontend.yaml -f values_queryScheduler.yaml \
  -f values_compactor.yaml -f values_indexGateway.yaml -f values_gateway.yaml \
  -f values_memcached.yaml -f values_monitor.yaml -f values_sa.yaml \
  -f values_ingress.yaml -f values_override.yaml --wait
cd ..
```

### Step 5: Deploy Prometheus + Grafana

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace observability --values helm/prometheus-stack-values.yaml --wait
```

### Step 6: Deploy Tempo

```bash
helm install tempo grafana/tempo \
  --namespace observability --values helm/tempo-values.yaml --wait
```

### Step 7: Deploy Alloy

```bash
helm install alloy grafana/alloy \
  --namespace observability --values helm/alloy-values.yaml --wait
```

### Step 8: Deploy HotROD

```bash
kubectl apply -f application/hotrod.yaml
```

### Step 9: Access UIs

```bash
kubectl port-forward svc/monitoring-grafana 3000:80 -n observability &
kubectl port-forward svc/hotrod 8081:8080 -n application &
```

- **Grafana:** http://localhost:3000 (admin / admin123)
- **HotROD:** http://localhost:8081 (click buttons to generate traces)
- **MinIO:** http://localhost:9001 (minioadmin / minioadmin123)

## Verify

1. **Traces:** Grafana -> Explore -> Tempo -> Search -> Run query
2. **Service Map:** Grafana -> Explore -> Tempo -> Service Graph tab
3. **Logs:** Grafana -> Explore -> Loki -> `{namespace="application"}`
4. **Trace->Logs:** Open trace -> click span -> "Logs for this span"
5. **Logs->Traces:** In Loki find traceID -> click link -> jumps to Tempo
6. **Span Metrics:** Grafana -> Explore -> Prometheus -> `traces_spanmetrics_latency_bucket`

## Component Summary

| Component  | Chart                                        | Namespace     |
|------------|----------------------------------------------|---------------|
| Tempo      | `grafana/tempo`                               | observability |
| Loki       | `grafana/loki` (umbrella, distributed mode)   | loki          |
| Prometheus | `prometheus-community/kube-prometheus-stack`  | observability |
| Grafana    | (included in kube-prometheus-stack)           | observability |
| Alloy      | `grafana/alloy`                               | observability |
| MinIO      | Docker container on k3d network              | external      |
| HotROD     | Raw K8s manifests                            | application   |

## Cleanup

```bash
kubectl delete -f application/hotrod.yaml
helm uninstall alloy tempo monitoring -n observability
helm uninstall loki -n loki
kubectl delete namespace observability application loki
docker rm -f minio
k3d cluster delete tempo-poc
```
