#!/bin/bash
# Pre-deployment verification script for RHCL on AKS
# Run this before deploying RHCL to verify all prerequisites

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"

ERRORS=0
WARNINGS=0

echo "======================================================"
echo "RHCL Pre-Deployment Verification for AKS"
echo "======================================================"
echo ""

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

error() {
  echo -e "${RED}✗ ERROR: $1${NC}"
  ERRORS=$((ERRORS + 1))
}

warning() {
  echo -e "${YELLOW}⚠ WARNING: $1${NC}"
  WARNINGS=$((WARNINGS + 1))
}

success() {
  echo -e "${GREEN}✓ $1${NC}"
}

info() {
  echo "ℹ $1"
}

# 1. Check cluster connectivity
echo "1. Checking AKS Cluster Connectivity"
echo "-------------------------------------"
if kubectl cluster-info &>/dev/null; then
  CLUSTER_NAME=$(kubectl config current-context)
  success "Connected to cluster: $CLUSTER_NAME"
else
  error "Cannot connect to Kubernetes cluster"
  echo "  Run: kubectl get nodes"
  exit 1
fi
echo ""

# 2. Check for GPU nodes
echo "2. Checking Node Configuration"
echo "-------------------------------"
GPU_NODES=$(kubectl get nodes -l sku=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$GPU_NODES" -gt 0 ]; then
  success "Found $GPU_NODES GPU node(s) with label sku=gpu"
  info "RHCL operators will avoid these nodes (configured in values-aks.yaml)"
else
  warning "No GPU nodes found with label sku=gpu"
  info "If you have GPU nodes, ensure they're labeled: kubectl label nodes <node-name> sku=gpu"
fi

TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
NON_GPU_NODES=$((TOTAL_NODES - GPU_NODES))
if [ "$NON_GPU_NODES" -gt 0 ]; then
  success "Found $NON_GPU_NODES non-GPU node(s) available for RHCL operators"
else
  error "No non-GPU nodes available for RHCL operators"
  echo "  RHCL operators need at least 1 non-GPU node"
fi
echo ""

# 3. Check cert-manager
echo "3. Checking cert-manager"
echo "------------------------"
if kubectl get namespace cert-manager &>/dev/null; then
  if kubectl get pods -n cert-manager -l app.kubernetes.io/name=cert-manager --no-headers 2>/dev/null | grep -q "Running"; then
    VERSION=$(kubectl get pods -n cert-manager -l app.kubernetes.io/name=cert-manager -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    success "cert-manager is running (version: $VERSION)"
  else
    warning "cert-manager namespace exists but pods are not running"
    echo "  Check: kubectl get pods -n cert-manager"
  fi
else
  error "cert-manager is not installed"
  echo "  Install with:"
  echo "    helm repo add jetstack https://charts.jetstack.io"
  echo "    helm repo update"
  echo "    helm install cert-manager jetstack/cert-manager \\"
  echo "      --namespace cert-manager \\"
  echo "      --create-namespace \\"
  echo "      --set installCRDs=true \\"
  echo "      --version v1.15.2"
fi
echo ""

# 4. Check Gateway API CRDs
echo "4. Checking Gateway API CRDs"
echo "----------------------------"
GATEWAY_CRDS=$(kubectl get crds 2>/dev/null | grep -c "gateway.networking.k8s.io" || echo "0")
if [ "$GATEWAY_CRDS" -gt 0 ]; then
  success "Found $GATEWAY_CRDS Gateway API CRDs"
  # Check for specific required CRDs
  REQUIRED_CRDS=("gateways.gateway.networking.k8s.io" "httproutes.gateway.networking.k8s.io" "gatewayclasses.gateway.networking.k8s.io")
  for crd in "${REQUIRED_CRDS[@]}"; do
    if kubectl get crd "$crd" &>/dev/null; then
      success "  $crd installed"
    else
      error "  Missing CRD: $crd"
    fi
  done
else
  error "Gateway API CRDs are not installed"
  echo "  Install with:"
  echo "    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml"
fi
echo ""

# 5. Check for namespace conflicts
echo "5. Checking Namespace Conflicts"
echo "--------------------------------"
if kubectl get namespace kuadrant-operators &>/dev/null; then
  warning "Namespace kuadrant-operators already exists"
  info "Existing resources may conflict with deployment"
else
  success "Namespace kuadrant-operators is available"
fi

if kubectl get namespace kuadrant-system &>/dev/null; then
  warning "Namespace kuadrant-system already exists"
  info "Existing resources may conflict with deployment"
else
  success "Namespace kuadrant-system is available"
fi
echo ""

# 6. Check podman/docker auth
echo "6. Checking Red Hat Registry Authentication"
echo "--------------------------------------------"
AUTH_FILE="$HOME/.config/containers/auth.json"
if [ -f "$AUTH_FILE" ]; then
  if grep -q "registry.redhat.io" "$AUTH_FILE" 2>/dev/null; then
    success "Red Hat registry credentials found in $AUTH_FILE"
  else
    error "No registry.redhat.io credentials in $AUTH_FILE"
    echo "  Login with: podman login registry.redhat.io"
  fi
else
  error "Podman auth file not found at $AUTH_FILE"
  echo "  Login with: podman login registry.redhat.io"
  echo "  Or use pullSecretFile in values-aks.yaml"
fi
echo ""

# 7. Check GPU Operator (informational)
echo "7. Checking GPU Operator (Informational)"
echo "-----------------------------------------"
if kubectl get namespace gpu-operator &>/dev/null; then
  GPU_OP_PODS=$(kubectl get pods -n gpu-operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$GPU_OP_PODS" -gt 0 ]; then
    success "GPU Operator is deployed ($GPU_OP_PODS pods)"
    info "RHCL will coexist with GPU Operator in separate namespaces"
  else
    warning "GPU Operator namespace exists but no pods found"
  fi
else
  info "GPU Operator not detected (this is optional)"
fi
echo ""

# 8. Check DNS Operator Configuration (if enabled)
echo "8. Checking DNS Operator Configuration"
echo "---------------------------------------"
VALUES_FILE="$CHART_DIR/values.yaml"
if [ -f "$VALUES_FILE" ]; then
  DNS_ENABLED=$(grep -A 1 "^  dns:" "$VALUES_FILE" | grep "enabled:" | grep -q "true" && echo "true" || echo "false")

  if [ "$DNS_ENABLED" == "true" ]; then
    warning "DNS operator is ENABLED in values.yaml"
    info "DNS operator requires cloud provider credentials AND a domain name to function:"
    info "  - AWS Route53: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION + Hosted Zone"
    info "  - Azure DNS: AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET + DNS Zone"
    info "  - GCP Cloud DNS: GCP_PROJECT, GCP_SERVICE_ACCOUNT_KEY + Managed Zone"
    echo ""
    info "Without valid credentials and domain:"
    info "  ✅ DNS operator pod will deploy successfully"
    info "  ⚠️  DNSRecord/DNSHealthCheckProbe will show errors"
    info "  ⚠️  DNS records will NOT be created in cloud provider"
    echo ""
    info "For testing DNS operator deployment without cloud credentials:"
    info "  - DNS operator deployment can be validated"
    info "  - Use: cd test && ./deploy-test-dns.sh"
  else
    success "DNS operator is disabled (default configuration)"
    info "To enable DNS operator, set operators.dns.enabled: true in values.yaml"
  fi
else
  warning "Could not find values.yaml at $VALUES_FILE"
fi
echo ""

# 9. Check available resources
echo "9. Checking Available Resources"
echo "--------------------------------"
# Calculate total CPU/Memory available on non-GPU nodes
info "Estimating available resources on non-GPU nodes..."
# This is informational only
kubectl top nodes --selector='sku!=gpu' 2>/dev/null | tail -n +2 | head -5 || info "kubectl top nodes not available (metrics-server may not be installed)"
echo ""

# Summary
echo "======================================================"
echo "Pre-Deployment Check Summary"
echo "======================================================"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
  echo -e "${GREEN}✓ All checks passed!${NC}"
  echo ""
  echo "You can proceed with RHCL deployment:"
  echo "  cd charts/rhcl"
  echo "  helmfile -e aks apply"
  echo ""
  exit 0
elif [ $ERRORS -eq 0 ]; then
  echo -e "${YELLOW}⚠ $WARNINGS warning(s) found${NC}"
  echo ""
  echo "You can proceed with caution, but review warnings above."
  echo ""
  exit 0
else
  echo -e "${RED}✗ $ERRORS error(s) and $WARNINGS warning(s) found${NC}"
  echo ""
  echo "Please fix errors before deploying RHCL."
  echo "Review the output above for installation instructions."
  echo ""
  exit 1
fi
