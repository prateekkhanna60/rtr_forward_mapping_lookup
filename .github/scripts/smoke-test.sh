#!/usr/bin/env bash
set -euo pipefail

integration=$1
namespace=${DEV_NAMESPACE:-camelk-system}

echo "Running smoke tests for integration: ${integration}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for smoke tests"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required for smoke tests"
  exit 1
fi

phase=$(kubectl get integration "$integration" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$phase" != "Running" ]; then
  echo "Smoke test failed: integration $integration is not Running (phase=$phase)"
  kubectl describe integration "$integration" -n "$namespace" || true
  exit 1
fi

# Validate the real REST endpoint exposed by this integration via platform-http.
local_url="http://127.0.0.1:18080/invoices"

# Prefer Service port-forward. If no Service exists, fall back to Pod port-forward.
target_resource=""
target_port=""
service_name=$(kubectl get svc -n "$namespace" -l "camel.apache.org/integration=$integration" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -n "$service_name" ] && kubectl get svc "$service_name" -n "$namespace" >/dev/null 2>&1; then
  service_port=$(kubectl get svc "$service_name" -n "$namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)
  if [ -n "$service_port" ]; then
    target_resource="service/$service_name"
    target_port="$service_port"
    echo "Using service '$service_name' on port '$service_port' for smoke test"
  fi
fi

if [ -z "$target_resource" ]; then
  pod_name=$(kubectl get pod -n "$namespace" -l "camel.apache.org/integration=$integration" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod_name" ]; then
    echo "Smoke test failed: no Service or Pod found for integration '$integration' in namespace '$namespace'"
    kubectl get svc -n "$namespace" -l "camel.apache.org/integration=$integration" -o wide || true
    kubectl get pod -n "$namespace" -l "camel.apache.org/integration=$integration" -o wide || true
    kubectl get integration "$integration" -n "$namespace" -o yaml || true
    exit 1
  fi

  pod_port=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.containers[0].ports[0].containerPort}' 2>/dev/null || true)
  if [ -z "$pod_port" ]; then
    # platform-http defaults to 8080 when no explicit container port is exposed.
    pod_port="8080"
  fi

  target_resource="pod/$pod_name"
  target_port="$pod_port"
  echo "No Service found. Using pod '$pod_name' on port '$pod_port' for smoke test"
fi

kubectl port-forward -n "$namespace" "$target_resource" 18080:"$target_port" >/tmp/${integration}-portforward.log 2>&1 &
pf_pid=$!
cleanup() {
  kill "$pf_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait briefly for port-forward to be ready.
for _ in {1..20}; do
  if curl -s -o /dev/null "$local_url"; then
    break
  fi
  if ! kill -0 "$pf_pid" >/dev/null 2>&1; then
    echo "Smoke test failed: kubectl port-forward process exited unexpectedly"
    echo "Port-forward logs:"
    cat /tmp/${integration}-portforward.log || true
    if [ -n "$service_name" ]; then
      kubectl get svc "$service_name" -n "$namespace" -o wide || true
      kubectl get endpointslice -n "$namespace" -l "kubernetes.io/service-name=$service_name" -o wide || true
    fi
    kubectl get pod -n "$namespace" -l "camel.apache.org/integration=$integration" -o wide || true
    exit 1
  fi
  sleep 1
done

set +e
response=$(curl -s -o /dev/null -w "%{http_code}" "$local_url")
curl_exit=$?
set -e

if [ "$curl_exit" -ne 0 ]; then
  echo "Smoke test failed: curl could not connect to $local_url (exit=$curl_exit)"
  echo "Port-forward logs:"
  cat /tmp/${integration}-portforward.log || true
  if [ -n "$service_name" ]; then
    kubectl get svc "$service_name" -n "$namespace" -o wide || true
    kubectl get endpointslice -n "$namespace" -l "kubernetes.io/service-name=$service_name" -o wide || true
  fi
  POD=$(kubectl get pod -n "$namespace" -l camel.apache.org/integration="$integration" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$POD" ]; then
    kubectl logs "$POD" -n "$namespace" --tail=80 || true
    kubectl logs "$POD" -n "$namespace" --previous --tail=80 || true
  fi
  exit 1
fi

if [ "$response" != "200" ]; then
  echo "Smoke test failed: expected HTTP 200 from $local_url but got $response"
  echo "Port-forward logs:"
  cat /tmp/${integration}-portforward.log || true
  exit 1
fi

echo "Smoke tests passed for ${integration}"
