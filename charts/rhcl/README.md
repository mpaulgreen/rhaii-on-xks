# Red Hat Connectivity Link (RHCL) Helm Chart  [Pattern to deploy meta operator]

Helm chart for deploying Red Hat Connectivity Link (RHCL) 1.2.1 on Kubernetes/AKS.

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
2. Deploys 3 operators (Kuadrant, Authorino, Limitador, DNS (diabled by default))
3. Installs 14 CRDs
4. Creates Kuadrant instance
5. Validates deployment


## Verify Deployment

### 1. Check Operators

```bash
kubectl get deployments -n kuadrant-operators
```

### 2. Check Kuadrant Instance

```bash
kubectl get kuadrant -n kuadrant-system
```

### 3. Check Sub-Operator Instances

```bash
kubectl get authorino,limitador -n kuadrant-system
```

### 4. Run Automated Test

```bash
cd test
./deploy-test.sh
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
pullSecretFile: "/Users/username/.docker/config.json"
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

```

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

## Uninstalling

Remove RHCL deployment:

```bash
cd charts/rhcl
helmfile destroy
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


### Single Replica Operators

All operators run with **1 replica** by default (sufficient for development/testing).

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

## Roadmap

Potential enhancements for future versions:

- [ ] **Persistent Limitador Storage** - Built-in Redis configuration for production deployments
- [ ] **Complete DNS Operator Integration** - As mentioned in known limitation
- [ ] **Observability** - Prometheus ServiceMonitors for operator metrics and rate limit statistics
- [ ] **HA Configuration** - Pre-configured values for high-availability production deployments
- [ ] **Automated Testing** - CI/CD pipeline for upgrade testing and policy validation


## Contributing

This chart is maintained as part of the RHAII on XKS project.

## License

Red Hat Connectivity Link is licensed under Apache License 2.0.

## Support

For issues and questions:
- RHCL Documentation: https://docs.kuadrant.io/
- Kuadrant Operator: https://github.com/kuadrant/kuadrant-operator
