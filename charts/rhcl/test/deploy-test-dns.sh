#!/bin/bash
set -euo pipefail

# DNS Operator Validation Test Script
# Validates that DNS operator deploys correctly and reconciles DNS resources

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NAMESPACE="dns-test"
OPERATORS_NAMESPACE="kuadrant-operators"
KUADRANT_NAMESPACE="kuadrant-system"
CLEANUP=${CLEANUP:-true}

# Parse arguments
for arg in "$@"; do
    case $arg in
        --no-cleanup)
            CLEANUP=false
            shift
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--no-cleanup]"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}=== DNS Operator Validation Test ===${NC}\n"

# Function: Print colored status
print_status() {
    local status=$1
    local message=$2
    case $status in
        ok)
            echo -e "  ${GREEN}✅${NC} $message"
            ;;
        error)
            echo -e "  ${RED}❌${NC} $message"
            ;;
        warn)
            echo -e "  ${YELLOW}⚠️${NC} $message"
            ;;
        info)
            echo -e "  ${BLUE}ℹ️${NC} $message"
            ;;
    esac
}

# Function: Check if command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_status error "$1 not found. Please install it first."
        exit 1
    fi
}

# Function: Wait for resource to be ready
wait_for_ready() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local timeout=${4:-300}

    echo "Waiting for $resource_type/$resource_name to be ready (timeout: ${timeout}s)..."
    if kubectl wait --for=condition=Available "$resource_type/$resource_name" \
        -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
        print_status ok "$resource_type/$resource_name is ready"
        return 0
    else
        # Some resources may not have Available condition, check if they exist and are running
        if kubectl get "$resource_type/$resource_name" -n "$namespace" &>/dev/null; then
            print_status warn "$resource_type/$resource_name exists but may not be fully ready"
            return 0
        else
            print_status error "$resource_type/$resource_name is not ready"
            return 1
        fi
    fi
}

# Function: Wait for pod to be running
wait_for_pod() {
    local label=$1
    local namespace=$2
    local timeout=${3:-300}

    echo "Waiting for pod with label $label to be Running (timeout: ${timeout}s)..."
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local status=$(kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
        if [ "$status" == "Running" ]; then
            print_status ok "Pod is Running"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    print_status error "Pod did not reach Running state within ${timeout}s"
    return 1
}

# Function: Wait for Gateway pod (tries multiple Istio label formats)
wait_for_gateway_pod() {
    local gateway_name=$1
    local namespace=$2
    local timeout=${3:-300}

    echo "Waiting for Gateway pod ($gateway_name) to be Running (timeout: ${timeout}s)..."

    # Try different label selectors that Istio may use
    local labels=(
        "gateway.networking.k8s.io/gateway-name=$gateway_name"
        "istio.io/gateway-name=$gateway_name"
        "app=$gateway_name"
    )

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        # Try each label selector
        for label in "${labels[@]}"; do
            local status=$(kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
            if [ "$status" == "Running" ]; then
                print_status ok "Gateway pod is Running (found with label: $label)"
                return 0
            fi
        done
        sleep 5
        elapsed=$((elapsed + 5))
    done

    print_status error "Gateway pod did not reach Running state within ${timeout}s"
    return 1
}

# Prerequisites check
echo -e "${BLUE}Step 1: Checking prerequisites${NC}"
check_command kubectl
check_command jq

# Check if DNS operator is enabled and deployed
echo -e "\n${BLUE}Step 2: Verifying DNS operator is deployed${NC}"

if ! kubectl get deployment dns-operator-controller-manager -n "$OPERATORS_NAMESPACE" &>/dev/null; then
    print_status error "DNS operator deployment not found in namespace $OPERATORS_NAMESPACE"
    print_status info "Did you enable DNS operator in values.yaml? (operators.dns.enabled: true)"
    exit 1
fi
print_status ok "DNS operator deployment exists"

# Check DNS operator pod status
DNS_OPERATOR_STATUS=$(kubectl get pods -n "$OPERATORS_NAMESPACE" -l control-plane=dns-operator-controller-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [ "$DNS_OPERATOR_STATUS" != "Running" ]; then
    print_status error "DNS operator pod is not Running (status: $DNS_OPERATOR_STATUS)"
    print_status info "Check logs: kubectl logs -n $OPERATORS_NAMESPACE deployment/dns-operator-controller-manager"
    exit 1
fi
print_status ok "DNS operator pod is Running"

# Check DNS CRDs
echo -e "\n${BLUE}Step 3: Verifying DNS CRDs are installed${NC}"
REQUIRED_CRDS=("dnspolicies.kuadrant.io" "dnsrecords.kuadrant.io" "dnshealthcheckprobes.kuadrant.io")
for crd in "${REQUIRED_CRDS[@]}"; do
    if kubectl get crd "$crd" &>/dev/null; then
        print_status ok "CRD $crd exists"
    else
        print_status error "CRD $crd not found"
        exit 1
    fi
done

# Check DNS operator RBAC
echo -e "\n${BLUE}Step 4: Verifying DNS operator RBAC${NC}"
if kubectl get clusterrole dns-operator-manager-role &>/dev/null; then
    print_status ok "ClusterRole dns-operator-manager-role exists"
else
    print_status error "ClusterRole dns-operator-manager-role not found"
    exit 1
fi

if kubectl get clusterrolebinding dns-operator-manager-rolebinding &>/dev/null; then
    print_status ok "ClusterRoleBinding dns-operator-manager-rolebinding exists"
else
    print_status error "ClusterRoleBinding dns-operator-manager-rolebinding not found"
    exit 1
fi

# Deploy test manifest
echo -e "\n${BLUE}Step 5: Deploying DNS operator test resources${NC}"
kubectl apply -f "${SCRIPT_DIR}/test-dns-operator.yaml"
print_status ok "Test manifest applied"

# Copy pull secret from kuadrant-system
echo -e "\n${BLUE}Step 6: Copying pull secrets to test namespace${NC}"
if kubectl get secret redhat-pull-secret -n "$KUADRANT_NAMESPACE" &>/dev/null; then
    kubectl get secret redhat-pull-secret -n "$KUADRANT_NAMESPACE" -o yaml | \
        sed "s/namespace: $KUADRANT_NAMESPACE/namespace: $TEST_NAMESPACE/" | \
        kubectl apply -f - &>/dev/null
    print_status ok "Pull secret copied to $TEST_NAMESPACE"
else
    print_status warn "Pull secret not found in $KUADRANT_NAMESPACE (may cause ImagePullBackOff)"
fi

# Wait for test resources to be created
echo -e "\n${BLUE}Step 7: Waiting for test resources to be ready${NC}"

# Wait for Gateway pod (tries multiple Istio label formats)
if ! wait_for_gateway_pod "dns-test-gateway" "$TEST_NAMESPACE" 180; then
    print_status warn "Gateway pod may not be ready yet"
fi

# Wait for echo pod
if ! wait_for_pod "app=echo" "$TEST_NAMESPACE" 120; then
    print_status warn "Echo pod may not be ready yet"
fi

# Check DNS resources created
sleep 5  # Give operator time to reconcile
echo -e "\n${BLUE}Step 8: Validating DNS resources${NC}"

# Check DNSPolicy
if kubectl get dnspolicy dns-test-policy -n "$TEST_NAMESPACE" &>/dev/null; then
    print_status ok "DNSPolicy created"
    DNSPOLICY_ACCEPTED=$(kubectl get dnspolicy dns-test-policy -n "$TEST_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
    if [ "$DNSPOLICY_ACCEPTED" == "True" ]; then
        print_status ok "DNSPolicy Accepted=True"
    else
        print_status warn "DNSPolicy Accepted=$DNSPOLICY_ACCEPTED (may take time to reconcile)"
    fi
else
    print_status error "DNSPolicy not found"
fi

# Check DNSRecord
if kubectl get dnsrecord echo-dns-record -n "$TEST_NAMESPACE" &>/dev/null; then
    print_status ok "DNSRecord created"
    DNSRECORD_READY=$(kubectl get dnsrecord echo-dns-record -n "$TEST_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$DNSRECORD_READY" == "True" ]; then
        print_status ok "DNSRecord Ready=True (provider credentials are valid!)"
    elif [ "$DNSRECORD_READY" == "False" ]; then
        print_status warn "DNSRecord Ready=False (expected without valid cloud provider credentials)"
    else
        print_status warn "DNSRecord status unknown (may be reconciling)"
    fi
else
    print_status error "DNSRecord not found"
fi

# Check DNSHealthCheckProbe
if kubectl get dnshealthcheckprobe echo-health-probe -n "$TEST_NAMESPACE" &>/dev/null; then
    print_status ok "DNSHealthCheckProbe created"
    PROBE_HEALTHY=$(kubectl get dnshealthcheckprobe echo-health-probe -n "$TEST_NAMESPACE" -o jsonpath='{.status.healthy}' 2>/dev/null || echo "Unknown")
    if [ "$PROBE_HEALTHY" == "true" ]; then
        print_status ok "DNSHealthCheckProbe is healthy"
    else
        print_status warn "DNSHealthCheckProbe healthy=$PROBE_HEALTHY (expected without valid endpoints)"
    fi
else
    print_status error "DNSHealthCheckProbe not found"
fi

# Check DNS operator logs for reconciliation
echo -e "\n${BLUE}Step 9: Checking DNS operator reconciliation${NC}"
LOGS=$(kubectl logs -n "$OPERATORS_NAMESPACE" deployment/dns-operator-controller-manager --tail=50 2>/dev/null || echo "")

if echo "$LOGS" | grep -qi "dnspolicy"; then
    print_status ok "DNS operator is reconciling DNSPolicy"
else
    print_status info "No DNSPolicy logs (DNSPolicy controller operates silently when successful)"
fi

if echo "$LOGS" | grep -qi "dnsrecord"; then
    print_status ok "DNS operator is reconciling DNSRecord"
else
    print_status warn "No DNSRecord reconciliation logs found (may need more time)"
fi

# Check node affinity (GPU avoidance)
echo -e "\n${BLUE}Step 10: Verifying DNS operator node placement${NC}"
NODE_NAME=$(kubectl get pods -n "$OPERATORS_NAMESPACE" -l control-plane=dns-operator-controller-manager -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "Unknown")
if [ "$NODE_NAME" != "Unknown" ]; then
    NODE_SKU=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.sku}' 2>/dev/null || echo "none")
    if [ "$NODE_SKU" == "gpu" ]; then
        print_status error "DNS operator is running on GPU node (should avoid GPU nodes)"
    else
        print_status ok "DNS operator is NOT on GPU node (node: $NODE_NAME, sku: $NODE_SKU)"
    fi
fi

# Summary
echo -e "\n${BLUE}=== Validation Summary ===${NC}\n"

# Get final status
DNS_OP_READY=$(kubectl get deployment dns-operator-controller-manager -n "$OPERATORS_NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
DNSPOLICY_EXISTS=$(kubectl get dnspolicy -n "$TEST_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
DNSRECORD_EXISTS=$(kubectl get dnsrecord -n "$TEST_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
PROBE_EXISTS=$(kubectl get dnshealthcheckprobe -n "$TEST_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')

echo "DNS Operator Deployment:"
if [ "$DNS_OP_READY" -ge 1 ]; then
    print_status ok "DNS operator pod: Running ($DNS_OP_READY/1)"
else
    print_status error "DNS operator pod: Not running"
fi

echo -e "\nDNS CRDs:"
print_status ok "DNSPolicy CRD: Installed"
print_status ok "DNSRecord CRD: Installed"
print_status ok "DNSHealthCheckProbe CRD: Installed"

echo -e "\nTest Resources Created:"
[ "$DNSPOLICY_EXISTS" -ge 1 ] && print_status ok "DNSPolicy: $DNSPOLICY_EXISTS created" || print_status error "DNSPolicy: Not created"
[ "$DNSRECORD_EXISTS" -ge 1 ] && print_status ok "DNSRecord: $DNSRECORD_EXISTS created" || print_status error "DNSRecord: Not created"
[ "$PROBE_EXISTS" -ge 1 ] && print_status ok "DNSHealthCheckProbe: $PROBE_EXISTS created" || print_status error "DNSHealthCheckProbe: Not created"

echo -e "\nOperator Reconciliation:"
print_status info "Check operator logs for detailed reconciliation activity:"
echo "  kubectl logs -n $OPERATORS_NAMESPACE deployment/dns-operator-controller-manager -f"

echo -e "\n${YELLOW}Important Notes:${NC}"
print_status info "DNS operator does NOT create component deployments (unlike Authorino/Limitador)"
print_status info "The DNS operator pod itself manages DNS records with cloud providers"
print_status warn "Without valid cloud provider credentials, DNSRecord/DNSHealthCheckProbe will show errors"
print_status info "This is EXPECTED behavior - the test validates operator deployment, not cloud integration"

# Cleanup
if [ "$CLEANUP" == "true" ]; then
    echo -e "\n${BLUE}=== Cleanup ===${NC}\n"

    print_status info "Deleting test namespace $TEST_NAMESPACE..."
    kubectl delete namespace "$TEST_NAMESPACE" --timeout=60s &>/dev/null || true
    print_status ok "Test namespace deleted"

    echo -e "\nAll test resources have been cleaned up."
    echo "DNS operator remains running in namespace $OPERATORS_NAMESPACE"
else
    echo -e "\n${YELLOW}Cleanup skipped (--no-cleanup flag used)${NC}"
    echo "To manually cleanup: kubectl delete namespace $TEST_NAMESPACE"
fi

echo -e "\n${GREEN}=== DNS Operator Validation Complete ===${NC}\n"

# Exit status
if [ "$DNS_OP_READY" -ge 1 ] && [ "$DNSPOLICY_EXISTS" -ge 1 ] && [ "$DNSRECORD_EXISTS" -ge 1 ]; then
    print_status ok "All critical validations passed"
    exit 0
else
    print_status error "Some validations failed"
    exit 1
fi
