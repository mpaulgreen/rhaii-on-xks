#!/bin/bash
# RHCL Post-deployment Validation Script
# This script validates that all RHCL components are deployed and operational

set -euo pipefail

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-kuadrant-operators}"
INSTANCE_NAMESPACE="${INSTANCE_NAMESPACE:-kuadrant-system}"
TIMEOUT="${TIMEOUT:-300}"

echo "======================================================"
echo "RHCL Post-Deployment Validation"
echo "======================================================"
echo ""

# Function to check if a deployment is ready
check_deployment() {
  local name=$1
  local namespace=$2

  echo "Checking deployment: $name in namespace $namespace..."

  if ! kubectl get deployment "$name" -n "$namespace" &>/dev/null; then
    echo "ERROR: Deployment $name not found in namespace $namespace"
    return 1
  fi

  if ! kubectl wait --for=condition=Available deployment/"$name" \
    -n "$namespace" --timeout="${TIMEOUT}s" 2>/dev/null; then
    echo "ERROR: Deployment $name is not ready"
    kubectl get deployment "$name" -n "$namespace"
    kubectl describe deployment "$name" -n "$namespace"
    return 1
  fi

  echo "✓ Deployment $name is ready"
  return 0
}

# Check all operator deployments
echo "1. Validating Operator Deployments"
echo "-----------------------------------"
check_deployment "kuadrant-operator-controller-manager" "$OPERATOR_NAMESPACE" || exit 1
check_deployment "authorino-operator" "$OPERATOR_NAMESPACE" || exit 1
check_deployment "limitador-operator-controller-manager" "$OPERATOR_NAMESPACE" || exit 1

# DNS operator is optional (disabled by default)
if kubectl get deployment "dns-operator-controller-manager" -n "$OPERATOR_NAMESPACE" &>/dev/null; then
  check_deployment "dns-operator-controller-manager" "$OPERATOR_NAMESPACE" || exit 1
else
  echo "ℹ DNS operator not deployed (disabled by default in values.yaml)"
fi
echo ""

# Check Kuadrant CR
echo "2. Validating Kuadrant Instance"
echo "--------------------------------"
if ! kubectl get kuadrant -n "$INSTANCE_NAMESPACE" &>/dev/null; then
  echo "WARNING: No Kuadrant instance found in namespace $INSTANCE_NAMESPACE"
  echo "This is expected if instance.kuadrant.enabled=false in values"
else
  KUADRANT_NAME=$(kubectl get kuadrant -n "$INSTANCE_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
  echo "Found Kuadrant instance: $KUADRANT_NAME"

  if kubectl wait --for=condition=Ready kuadrant/"$KUADRANT_NAME" \
    -n "$INSTANCE_NAMESPACE" --timeout="${TIMEOUT}s" 2>/dev/null; then
    echo "✓ Kuadrant instance is ready"
  else
    echo "WARNING: Kuadrant instance is not ready yet"
    kubectl describe kuadrant/"$KUADRANT_NAME" -n "$INSTANCE_NAMESPACE"
  fi
fi
echo ""

# Check sub-operator instances
echo "3. Validating Sub-Operator Instances"
echo "-------------------------------------"

# Check Authorino
if kubectl get authorino -n "$INSTANCE_NAMESPACE" &>/dev/null; then
  AUTHORINO_COUNT=$(kubectl get authorino -n "$INSTANCE_NAMESPACE" --no-headers | wc -l)
  echo "✓ Found $AUTHORINO_COUNT Authorino instance(s)"
  kubectl get authorino -n "$INSTANCE_NAMESPACE"
else
  echo "ℹ No Authorino instances found (will be created by Kuadrant operator)"
fi

# Check Limitador
if kubectl get limitador -n "$INSTANCE_NAMESPACE" &>/dev/null; then
  LIMITADOR_COUNT=$(kubectl get limitador -n "$INSTANCE_NAMESPACE" --no-headers | wc -l)
  echo "✓ Found $LIMITADOR_COUNT Limitador instance(s)"
  kubectl get limitador -n "$INSTANCE_NAMESPACE"
else
  echo "ℹ No Limitador instances found (will be created by Kuadrant operator)"
fi
echo ""

# Check CRDs
echo "4. Validating CRDs"
echo "------------------"
EXPECTED_CRDS=(
  "kuadrants.kuadrant.io"
  "authpolicies.kuadrant.io"
  "ratelimitpolicies.kuadrant.io"
  "dnspolicies.kuadrant.io"
  "tlspolicies.kuadrant.io"
  "authconfigs.authorino.kuadrant.io"
  "authorinos.operator.authorino.kuadrant.io"
  "limitadors.limitador.kuadrant.io"
  "dnsrecords.kuadrant.io"
  "dnshealthcheckprobes.kuadrant.io"
)

MISSING_CRDS=0
for crd in "${EXPECTED_CRDS[@]}"; do
  if kubectl get crd "$crd" &>/dev/null; then
    echo "✓ CRD $crd is installed"
  else
    echo "✗ CRD $crd is missing"
    MISSING_CRDS=$((MISSING_CRDS + 1))
  fi
done

if [ $MISSING_CRDS -gt 0 ]; then
  echo ""
  echo "WARNING: $MISSING_CRDS CRD(s) are missing"
fi
echo ""

# Summary
echo "======================================================"
echo "Validation Complete!"
echo "======================================================"
echo ""
echo "Operator Status:"
kubectl get deployments -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/part-of=rhcl
echo ""
echo "Instance Status:"
kubectl get kuadrant,authorino,limitador -n "$INSTANCE_NAMESPACE" 2>/dev/null || echo "No instances found yet"
echo ""
echo "For more details, check:"
echo "  kubectl get all -n $OPERATOR_NAMESPACE"
echo "  kubectl get all -n $INSTANCE_NAMESPACE"
echo "  kubectl get crds | grep kuadrant"
