#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Step 1: Create k3d cluster..."

if k3d cluster list 2>/dev/null | grep -q "tempo-poc"; then
  echo "Cluster exists, skipping"
else
  k3d cluster create --config "$SCRIPT_DIR/k3d-cluster.yaml"
fi

echo "Step 2: Create namespaces..."
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace application --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace loki --dry-run=client -o yaml | kubectl apply -f -

echo "Step 3: Add Helm repos..."
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

echo "Step 4: Start MinIO..."
if docker ps --format '{{.Names}}' | grep -q "^minio$"; then
  echo "MinIO already running"
else
  docker run -d --name minio --network k3d-tempo-poc \
    -p 9000:9000 -p 9001:9001 \
    -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin123 \
    minio/minio server /data --console-address ":9001"
  sleep 3
fi

docker exec minio mc alias set local http://localhost:9000 minioadmin minioadmin123 2>/dev/null || true
docker exec minio mc mb local/loki-poc 2>/dev/null || true

MINIO_IP=$(docker inspect minio --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
sed -i.bak "s|endpoint: http://.*:9000|endpoint: http://$MINIO_IP:9000|g" "$PROJECT_DIR/mgmt/values_override.yaml"
rm -f "$PROJECT_DIR/mgmt/values_override.yaml.bak"

echo "Step 5: Deploy Loki..."
cd "$PROJECT_DIR/mgmt"
helm dependency build 2>/dev/null || true
helm upgrade --install loki . --namespace loki \
  -f values_loki.yaml -f values_ingester.yaml -f values_distributor.yaml \
  -f values_querier.yaml -f values_queryFrontend.yaml -f values_queryScheduler.yaml \
  -f values_compactor.yaml -f values_indexGateway.yaml -f values_gateway.yaml \
  -f values_memcached.yaml -f values_monitor.yaml -f values_sa.yaml \
  -f values_ingress.yaml -f values_override.yaml --wait --timeout 5m
cd "$PROJECT_DIR"

echo "Step 6: Deploy Prometheus + Grafana..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace observability --values "$PROJECT_DIR/helm/prometheus-stack-values.yaml" \
  --wait --timeout 5m

echo "Step 7: Deploy Tempo..."
helm upgrade --install tempo grafana/tempo \
  --namespace observability --values "$PROJECT_DIR/helm/tempo-values.yaml" \
  --wait --timeout 3m

echo "Step 8: Deploy Alloy..."
helm upgrade --install alloy grafana/alloy \
  --namespace observability --values "$PROJECT_DIR/helm/alloy-values.yaml" \
  --wait --timeout 3m

echo "Step 9: Deploy HotROD app..."
kubectl apply -f "$PROJECT_DIR/application/hotrod.yaml"
kubectl wait --for=condition=Available deployment/hotrod -n application --timeout=120s

echo "Setup complete!"
echo ""
echo "🎉 Observability Stack Successfully Deployed!"
echo ""
echo "📊 Access URLs:"
echo "  🖥️  Grafana: kubectl port-forward svc/monitoring-grafana 3000:80 -n observability"
echo "       → http://localhost:3000 (admin/admin123)"
echo "  🚗 HotROD:  kubectl port-forward svc/hotrod 8081:8080 -n application"
echo "       → http://localhost:8081 (generate traces by clicking buttons)"
echo "  📦 MinIO:   http://localhost:9001 (minioadmin/minioadmin123)"
echo "  🔍 Loki:    kubectl port-forward svc/loki-gateway 3100:3100 -n loki"
echo "       → http://localhost:3100"
echo "  📈 Tempo:   kubectl port-forward tempo-0 3200:3200 -n observability" 
echo "       → http://localhost:3200"
echo ""
echo "🧪 Quick Test:"
echo "  1. Access HotROD and click buttons to generate traces"
echo "  2. Open Grafana → Explore → Tempo → Search to see traces"
echo "  3. Open Grafana → Explore → Loki → Query: {namespace=\"application\"}"
echo ""
echo "📚 Full guide: See README.md"
