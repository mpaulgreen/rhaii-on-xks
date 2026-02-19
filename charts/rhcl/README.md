# Red Hat Connectivity Link (RHCL) Helm Chart

Helm chart for deploying Red Hat Connectivity Link (RHCL) 1.2.0 on Kubernetes/AKS.

## Overview

RHCL is a **meta-operator** that manages four sub-operators to provide API gateway, authentication, authorization, and rate limiting capabilities:

- **Kuadrant Operator** (meta-operator) - Orchestrates the deployment of sub-operators
- **Authorino Operator** v1.2.4 - Authentication and authorization
- **Limitador Operator** v1.2.0 - Rate limiting
- **DNS Operator** v1.2.0 - DNS policy management (disabled by default)

## Architecture

RHCL uses a three-tier deployment architecture:

```
Helm Chart
  ↓
4 Operator Deployments (Kuadrant, Authorino, Limitador, DNS)
  ↓
Kuadrant CR (created by Helm postsync)
  ↓
Sub-Operator CRs (Authorino CR, Limitador CR - created by Kuadrant operator)
  ↓
Component Deployments (Authorino, Limitador instances)
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed architecture documentation.

## Prerequisites

Before installing RHCL, ensure the following are installed:

1. **Kubernetes** 1.25.0 or higher
2. **Helm** 3.17.0 or higher (for Server-Side Apply support)
3. **Helmfile** 0.157.0 or higher
4. **cert-manager** 1.15.2 or higher (deployed by cert-manager-operator chart)
5. **Gateway API** v1.4.0 or higher CRDs (deployed by sail-operator chart)
6. **Podman or Docker** with Red Hat registry authentication

## Pre-Deployment Verification

Run the verification script to check prerequisites:

```bash
cd charts/rhcl
./scripts/pre-deploy-check-aks.sh
```

This verifies:
- Cluster connectivity
- cert-manager installation
- Gateway API CRDs
- Red Hat registry authentication
- Namespace availability

## Installation

### Quick Start

Deploy RHCL using helmfile:

```bash
cd charts/rhcl

# Preview changes (optional)
helmfile diff

# Deploy RHCL
helmfile apply
```

**What happens:**
1. Creates namespaces (`kuadrant-operators`, `kuadrant-system`)
2. Deploys 3 operators (Kuadrant, Authorino, Limitador)
3. Installs 20 CRDs
4. Creates Kuadrant instance
5. Validates deployment

**Deployment time:** ~40 seconds

### Alternative: Manual Helm Installation

If not using Helmfile:

```bash
cd charts/rhcl

# Phase 1: Presync - Create namespaces and ServiceAccounts
kubectl apply -f manifests-presync/

# Phase 2: Install RHCL operators
helm install rhcl . \
  --namespace kuadrant-operators \
  --create-namespace \
  --values values.yaml \
  --set-file images.pullSecret.dockerConfigJson=~/.config/containers/auth.json

# Phase 3: Postsync - Create Kuadrant CR
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
spec: {}
EOF

# Wait for Kuadrant to be ready
kubectl wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=300s
```

## Verify Deployment

### 1. Check Operators

```bash
kubectl get deployments -n kuadrant-operators
```

Expected output:
```
NAME                                    READY   UP-TO-DATE   AVAILABLE
kuadrant-operator-controller-manager    1/1     1            1
authorino-operator                      1/1     1            1
limitador-operator-controller-manager   1/1     1            1
```

### 2. Check Kuadrant Instance

```bash
kubectl get kuadrant -n kuadrant-system
```

Expected output:
```
NAME       READY
kuadrant   True
```

### 3. Check Sub-Operator Instances

```bash
kubectl get authorino,limitador -n kuadrant-system
```

Expected output:
```
NAME                                           READY
authorino.operator.authorino.kuadrant.io/...   True

NAME                                    READY
limitador.limitador.kuadrant.io/...     True
```

### 4. Run Automated Test

```bash
cd test
./deploy-test.sh
```

Expected output:
```
✅ HTTP Request: 200 (Success)
✅ Rate Limiting: Working (9 allowed, 3 blocked)
✅ AuthPolicy: Enforced
✅ RateLimitPolicy: Enforced
```

## Configuration

### GPU Node Avoidance (AKS)

All operators are configured to avoid GPU nodes (labeled `sku=gpu`):

```bash
# Verify operators are NOT on GPU nodes
kubectl get pods -n kuadrant-operators -o wide
```

Check the `NODE` column - should show standard nodes, not GPU nodes.

### Resource Limits

Operators use optimized resource limits:
- **CPU:** 100m (request), 500m (limit)
- **Memory:** 128Mi (request), 512Mi (limit)

### Image Pull Authentication

Helmfile automatically uses podman authentication from:
```
~/.config/containers/auth.json
```

If using Docker instead, update `values.yaml`:
```yaml
useSystemPodmanAuth: false
pullSecretFile: "~/.docker/config.json"
```

### Key Configuration Values

See [values.yaml](values.yaml) for full configuration options.

```yaml
# Platform (kubernetes or openshift)
platform:
  type: kubernetes

# Namespaces
namespaces:
  operators: kuadrant-operators  # Where operators run
  instances: kuadrant-system     # Where Kuadrant instance runs

# Image registry and pull secret
images:
  registry: registry.redhat.io
  pullPolicy: IfNotPresent
  pullSecret:
    name: redhat-pull-secret
    create: true

# Operator configurations
operators:
  kuadrant:
    enabled: true
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    # GPU node avoidance (AKS)
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: sku
              operator: NotIn
              values: ["gpu"]

# Kuadrant instance
instance:
  kuadrant:
    enabled: true
    name: kuadrant
```

## Usage

### Creating Policies

After installation, you can create API policies for your workloads.

#### AuthPolicy Example

```yaml
apiVersion: kuadrant.io/v1beta2
kind: AuthPolicy
metadata:
  name: my-auth-policy
  namespace: my-app
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-route
  rules:
    authentication:
      "api-key":
        apiKey:
          selector:
            matchLabels:
              app: my-app
```

#### RateLimitPolicy Example

```yaml
apiVersion: kuadrant.io/v1beta2
kind: RateLimitPolicy
metadata:
  name: my-ratelimit
  namespace: my-app
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-route
  limits:
    "per-user":
      rates:
        - limit: 100
          duration: 60
          unit: second
```

See the test manifest at `test/test-rhcl-deployment.yaml` for working examples.

## Troubleshooting

### Operators Not Starting

Check pull secret authentication:

```bash
# Verify credentials exist
cat ~/.config/containers/auth.json | grep registry.redhat.io

# Re-authenticate if needed
podman login registry.redhat.io

# Check operator logs
kubectl logs -n kuadrant-operators deployment/kuadrant-operator-controller-manager --tail=50
```

### Kuadrant Not Ready

Check operator logs and status:

```bash
kubectl logs -n kuadrant-operators deployment/kuadrant-operator-controller-manager --tail=50

# Check Kuadrant status
kubectl describe kuadrant kuadrant -n kuadrant-system
```

### Test Failures

If the automated test fails with 403 errors, wait 30 seconds for WASM plugin to load:

```bash
# Wait for WASM plugin
sleep 30

# Re-run test
cd test
./deploy-test.sh
```

### Sub-Operator Instances Not Created

```bash
# Verify Kuadrant CR exists
kubectl get kuadrant -n kuadrant-system

# Check if Authorino/Limitador CRDs are installed
kubectl get crds | grep -E "authorino|limitador"

# Check operator reconciliation
kubectl logs -n kuadrant-operators deployment/kuadrant-operator-controller-manager --tail=50
```

## Upgrading

Update RHCL to a new version:

```bash
cd charts/rhcl

# Update image digests in values.yaml if needed
# Then upgrade
helmfile apply
```

Helmfile will perform a rolling upgrade of operators with zero downtime.

Using Helm directly:

```bash
helm upgrade rhcl . \
  --namespace kuadrant-operators \
  --values values.yaml
```

## Uninstalling

Remove RHCL deployment:

```bash
cd charts/rhcl
helmfile destroy
```

**What happens automatically:**
1. **Preuninstall hook**: Deletes Kuadrant CR (cascades to Authorino/Limitador instances)
2. **Helm uninstall**: Removes all operators and CRDs
3. **Postuninstall hook**: Deletes both namespaces (kuadrant-operators, kuadrant-system)
4. **Finalizer removal**: Automatically patches stuck resources if needed

**Note:** CRDs are preserved by default. To also remove CRDs:

```bash
kubectl get crds | grep kuadrant | awk '{print $1}' | xargs kubectl delete crd
```

Using Helm directly:

```bash
# 1. Delete Kuadrant instance first
kubectl delete kuadrant kuadrant -n kuadrant-system

# 2. Uninstall Helm release
helm uninstall rhcl -n kuadrant-operators

# 3. Clean up namespaces
kubectl delete namespace kuadrant-operators
kubectl delete namespace kuadrant-system
```

## Next Steps

After deployment, create policies for your workloads:

1. **Create Gateway** in your application namespace
2. **Create HTTPRoute** for your service
3. **Apply AuthPolicy** for authentication
4. **Apply RateLimitPolicy** for rate limiting

See the test manifest at `test/test-rhcl-deployment.yaml` for working examples.

## Known Limitations

### Limitador Storage (In-Memory)

Limitador uses **ephemeral in-memory storage** by default. Rate limit counters are lost on pod restart.

**Impact:**
- Rate limits reset when Limitador pod restarts
- Not suitable for production workloads requiring persistent rate limiting

**Workaround:**
Configure Redis for persistent storage:

```yaml
# values.yaml
instance:
  kuadrant:
    spec:
      limitador:
        storage:
          redis:
            configSecretRef:
              name: redis-config
```

See [Limitador Storage Documentation](https://docs.kuadrant.io/limitador/storage/) for Redis configuration.

### Single Replica Operators

All operators run with **1 replica** by default (sufficient for development/testing).

**Impact:**
- No high availability (operator unavailable during pod restart)
- Not recommended for production

**Workaround:**
Increase replicas in `values.yaml`:

```yaml
operators:
  kuadrant:
    replicas: 3
  authorino:
    replicas: 3
  limitador:
    replicas: 3
```

**Note:** Ensure proper leader election configuration for multi-replica deployments.

### DNS Operator Disabled

DNS operator is **disabled by default** (requires Azure DNS credentials).

**When needed:**
- Multi-cluster geo-routing
- DNS-based load balancing
- DNSPolicy for external DNS management

**To enable:**

```yaml
operators:
  dns:
    enabled: true

# Configure Azure DNS credentials
# See: https://docs.kuadrant.io/dns-operator/
```

**Basic Testing Completed:**

✅ **Minimal deployment testing has been validated** on AKS:
- DNS operator pod deploys successfully and runs (1/1 Ready)
- All 3 DNS CRDs installed (DNSPolicy, DNSRecord, DNSHealthCheckProbe)
- DNS operator reconciliation confirmed (processes DNS resources)
- RBAC and node affinity configured correctly (avoids GPU nodes)
- Basic DNSPolicy/DNSRecord creation works

⚠️ **Full functionality requires:**
1. **Valid cloud provider credentials** (AWS/Azure/GCP)
2. **A domain name you own** configured in the cloud provider's DNS service
   - Azure: DNS Zone in Azure DNS (e.g., "example.com")
   - AWS: Hosted Zone in Route53
   - GCP: Managed Zone in Cloud DNS

- **Without these:** DNS operator runs but cannot create actual DNS records
- **With these:** Operator can manage DNS records in your domain via cloud provider

**Testing:**
```bash
# Run DNS operator validation test
cd test
./deploy-test-dns.sh

# Validate DNS operator deployment
make validate
```

**Documentation:**
- Validation plan: `.claude_dev/DNS-OPERATOR-VALIDATION.md`
- Quick start: `.claude_dev/DNS-OPERATOR-QUICK-START.md`
- Deployment report: `.claude_dev/DNS-OPERATOR-DEPLOYMENT-REPORT.md`

## Roadmap

Potential enhancements for future versions:

- [ ] **Persistent Limitador Storage** - Built-in Redis configuration for production deployments
- [ ] **Observability** - Prometheus ServiceMonitors for operator metrics and rate limit statistics
- [ ] **Security Hardening** - Kyverno policies for pod security standards and network policies
- [ ] **HA Configuration** - Pre-configured values for high-availability production deployments
- [ ] **Custom CA Support** - Custom CA certificates for private image registries
- [ ] **Automated Testing** - CI/CD pipeline for upgrade testing and policy validation

**Contributions welcome!** See [Kuadrant Operator](https://github.com/kuadrant/kuadrant-operator) for upstream development.

## Contributing

This chart is maintained as part of the RHAII on XKS project.

## License

Red Hat Connectivity Link is licensed under Apache License 2.0.

## Support

For issues and questions:
- RHCL Documentation: https://docs.kuadrant.io/
- Kuadrant Operator: https://github.com/kuadrant/kuadrant-operator
