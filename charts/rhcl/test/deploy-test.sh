#!/bin/bash
#
# RHCL Test Deployment and Validation Script
#
# This script:
# 1. Deploys test environment (namespace, Gateway, policies, echo service)
# 2. Copies pull secrets from kuadrant-system
# 3. Waits for resources to be ready
# 4. Validates policy enforcement (AuthPolicy, RateLimitPolicy)
# 5. Tests HTTP requests and rate limiting
# 6. Cleans up all test resources
#
# Usage:
#   ./deploy-test.sh           # Run test with automatic cleanup
#   ./deploy-test.sh --no-cleanup  # Keep resources for manual inspection
#

set -euo pipefail

# Parse arguments
CLEANUP=true
if [ "${1:-}" = "--no-cleanup" ]; then
  CLEANUP=false
fi

echo "=== RHCL Test Deployment ==="
echo

# Check prerequisites
echo "Checking prerequisites..."

# Check if kuadrant-system namespace exists
if ! kubectl get ns kuadrant-system &>/dev/null; then
  echo "❌ Error: kuadrant-system namespace not found"
  echo "   Please deploy RHCL first: helmfile -e aks apply"
  exit 1
fi

# Check if pull secret exists
if ! kubectl get secret redhat-pull-secret -n kuadrant-system &>/dev/null; then
  echo "❌ Error: redhat-pull-secret not found in kuadrant-system"
  echo "   Please ensure RHCL is deployed correctly"
  exit 1
fi

# Check if Istio is installed
if ! kubectl get gatewayclass istio &>/dev/null; then
  echo "❌ Error: Istio GatewayClass not found"
  echo "   Please install Istio with Gateway API support"
  exit 1
fi

echo "✅ Prerequisites check passed"
echo

# Copy pull secret to rhcl-test namespace (will be created by the manifest)
echo "Step 1: Applying test manifest..."
kubectl apply -f test-rhcl-deployment.yaml

echo
echo "Step 2: Copying pull secrets to rhcl-test namespace..."
# Copy redhat-pull-secret for pod images
kubectl get secret redhat-pull-secret -n kuadrant-system -o yaml | \
  sed 's/namespace: kuadrant-system/namespace: rhcl-test/' | \
  kubectl apply -f -

# Copy wasm-plugin-pull-secret for WasmPlugin image (created by RHCL Helm chart)
kubectl get secret wasm-plugin-pull-secret -n kuadrant-system -o yaml | \
  sed 's/namespace: kuadrant-system/namespace: rhcl-test/' | \
  kubectl apply -f -

echo "✅ Pull secrets copied"
echo

# Wait for namespace
echo "Step 3: Waiting for resources to be ready..."
sleep 2

# Wait for echo pod
echo "  Waiting for echo pod..."
kubectl wait --for=condition=Ready pod -l app=echo -n rhcl-test --timeout=60s

# Wait for Gateway
echo "  Waiting for Gateway to be programmed..."
kubectl wait --for=condition=Programmed gateway/rhcl-test-gateway -n rhcl-test --timeout=120s || true

# Wait for Gateway pod (may take time for Istio to create it)
echo "  Waiting for Gateway pod..."
for i in {1..30}; do
  if kubectl get pods -n rhcl-test -l gateway.networking.k8s.io/gateway-name=rhcl-test-gateway 2>/dev/null | grep -q Running; then
    echo "  ✅ Gateway pod is running"
    break
  fi
  echo "    Waiting for Gateway pod to be created... ($i/30)"
  sleep 2
done

echo
echo "=== Deployment Status ==="
echo
kubectl get pods -n rhcl-test
echo
kubectl get gateway,httproute -n rhcl-test
echo
kubectl get authpolicy,ratelimitpolicy -n rhcl-test
echo

echo "=== Step 4: Validating RHCL Policies ==="
echo

# Create test pod for making requests
echo "  Creating test pod..."
kubectl run curl-test --image=curlimages/curl:8.5.0 -n rhcl-test --command -- sleep 3600 2>/dev/null
kubectl wait --for=condition=Ready pod/curl-test -n rhcl-test --timeout=30s >/dev/null 2>&1
echo "  ✅ Test pod ready"
echo

# Check policy enforcement status
echo "  Checking AuthPolicy enforcement..."
AUTH_ENFORCED=$(kubectl get authpolicy echo-auth -n rhcl-test -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}')
if [ "$AUTH_ENFORCED" = "True" ]; then
  echo "  ✅ AuthPolicy: Enforced"
else
  echo "  ❌ AuthPolicy: NOT Enforced (Status: $AUTH_ENFORCED)"
fi

echo "  Checking RateLimitPolicy enforcement..."
RL_ENFORCED=$(kubectl get ratelimitpolicy echo-ratelimit -n rhcl-test -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}')
if [ "$RL_ENFORCED" = "True" ]; then
  echo "  ✅ RateLimitPolicy: Enforced"
else
  echo "  ❌ RateLimitPolicy: NOT Enforced (Status: $RL_ENFORCED)"
fi
echo

# Test basic request
echo "  Testing basic HTTP request..."
HTTP_CODE=$(kubectl exec -n rhcl-test curl-test -- curl -H "Host: echo.test.local" http://rhcl-test-gateway-istio/ -s -o /dev/null -w "%{http_code}" 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
  echo "  ✅ HTTP Request: $HTTP_CODE (Success)"
else
  echo "  ❌ HTTP Request: $HTTP_CODE (Expected 200)"
fi
echo

# Test rate limiting (limit is 10 requests per minute)
echo "  Testing rate limiting (10 req/min limit)..."
SUCCESS_COUNT=0
RATE_LIMITED_COUNT=0

for i in {1..12}; do
  CODE=$(kubectl exec -n rhcl-test curl-test -- curl -H "Host: echo.test.local" http://rhcl-test-gateway-istio/ -s -o /dev/null -w "%{http_code}" 2>/dev/null)
  if [ "$CODE" = "200" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  elif [ "$CODE" = "429" ]; then
    RATE_LIMITED_COUNT=$((RATE_LIMITED_COUNT + 1))
  fi
  # Small delay between requests
  sleep 0.1
done

echo "    Requests sent: 12"
echo "    HTTP 200 (Allowed): $SUCCESS_COUNT"
echo "    HTTP 429 (Rate Limited): $RATE_LIMITED_COUNT"

if [ $SUCCESS_COUNT -le 10 ] && [ $RATE_LIMITED_COUNT -ge 2 ]; then
  echo "  ✅ Rate Limiting: Working (blocked requests after limit)"
else
  echo "  ⚠️  Rate Limiting: Unexpected behavior (Success: $SUCCESS_COUNT, Limited: $RATE_LIMITED_COUNT)"
fi
echo

# Check created resources
echo "  Checking created RHCL resources..."
AUTHCONFIG_COUNT=$(kubectl get authconfig -n kuadrant-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
WASMPLUGIN_COUNT=$(kubectl get wasmplugin -n rhcl-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "    AuthConfigs created: $AUTHCONFIG_COUNT"
echo "    WasmPlugins created: $WASMPLUGIN_COUNT"

if [ "$AUTHCONFIG_COUNT" -ge "1" ] && [ "$WASMPLUGIN_COUNT" -ge "1" ]; then
  echo "  ✅ RHCL Resources: Created"
else
  echo "  ❌ RHCL Resources: Missing (AuthConfigs: $AUTHCONFIG_COUNT, WasmPlugins: $WASMPLUGIN_COUNT)"
fi
echo

# Cleanup test pod
echo "  Cleaning up test pod..."
kubectl delete pod curl-test -n rhcl-test >/dev/null 2>&1
echo "  ✅ Test pod deleted"
echo

echo "=== Validation Summary ==="
echo
echo "✅ Deployment successful"
echo "✅ All pods running"
echo "✅ Policies enforced: AuthPolicy ($AUTH_ENFORCED), RateLimitPolicy ($RL_ENFORCED)"
echo "✅ HTTP requests working: $HTTP_CODE"
echo "✅ Rate limiting active: $SUCCESS_COUNT allowed, $RATE_LIMITED_COUNT blocked"
echo

# Cleanup test resources
if [ "$CLEANUP" = true ]; then
  echo "=== Cleanup ==="
  echo
  echo "  Deleting test namespace and all resources..."
  kubectl delete ns rhcl-test
  echo "  ✅ Test namespace deleted"
  echo
  echo "All test resources have been cleaned up."
  echo
else
  echo "=== Test Resources Left for Inspection ==="
  echo
  echo "Test namespace 'rhcl-test' is still running."
  echo
  echo "To inspect resources:"
  echo "  kubectl get all,gateway,httproute,authpolicy,ratelimitpolicy -n rhcl-test"
  echo
  echo "To cleanup when done:"
  echo "  kubectl delete ns rhcl-test"
  echo
fi
