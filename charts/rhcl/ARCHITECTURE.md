# RHCL Helm Chart Architecture

## Overview

This Helm chart deploys Red Hat Connectivity Link (RHCL) 1.2.0 on Kubernetes following the **meta-operator pattern**. Unlike traditional single-operator charts, RHCL orchestrates four interconnected operators to provide comprehensive API gateway, authentication, authorization, and rate limiting capabilities.

## Meta-Operator Architecture

RHCL is fundamentally different from single-operator deployments:

```
┌─────────────────────────────────────────────────────────────┐
│                         Helm Chart                          │
│  Deploys: 20 CRDs + 4 Operator Deployments + RBAC          │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ├─► Kuadrant Operator (meta-operator)
                  ├─► Authorino Operator
                  ├─► Limitador Operator
                  └─► DNS Operator
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│              Kuadrant CR (created by Helm/user)             │
│  Triggers orchestration of sub-operators                    │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  │ Kuadrant Operator watches and creates:
                  │
                  ├─► Authorino CR ───► Authorino Deployment
                  │                     (auth/authz service)
                  │
                  ├─► Limitador CR ───► Limitador Deployment
                  │                     (rate limiting service)
                  │
                  └─► DNS Records/Probes ───► DNS management
                                               (external DNS)
```

### Three-Tier Reconciliation

1. **Tier 1: Helm** - Deploys operators, CRDs, RBAC
2. **Tier 2: Kuadrant Operator** - Creates and manages Authorino/Limitador CRs
3. **Tier 3: Sub-Operators** - Deploy and manage component workloads

This creates a **dynamic CR creation pattern** where:
- Helm creates `Kuadrant` CR
- Kuadrant operator creates `Authorino` and `Limitador` CRs
- Authorino/Limitador operators create their respective deployments

## Deployment Phases

The chart uses a **three-phase deployment** pattern (borrowed from LWS operator):

### Phase 1: Presync (Before Helm Install)

**Purpose:** Prepare the cluster environment

**Actions:**
1. Create namespaces (`kuadrant-operators`, `kuadrant-system`)
2. Create pull secret for Red Hat registry
3. Pre-create ServiceAccounts with `imagePullSecrets`

**Why pre-create ServiceAccounts?**
- Operators reference ServiceAccounts in their deployments
- ServiceAccounts need `imagePullSecrets` before pod creation
- Avoids race conditions where pods fail due to missing pull secrets

**Executed by:** Helmfile presync hooks or manual `kubectl apply`

### Phase 2: Helm Install (Main Deployment)

**Purpose:** Deploy all operators and infrastructure

**Resources Created:**
- 20 CRDs (across 4 operators) via Server-Side Apply
- 4 operator deployments
- 75+ RBAC resources (ClusterRoles, ClusterRoleBindings, Roles, RoleBindings)
- Operator ServiceAccounts (adopt pre-created ones)
- Services (for inter-component communication)

**CRD Installation:**
- Uses Helm 3.17+ Server-Side Apply (SSA)
- CRDs in `crds/` directory, organized by operator
- Idempotent updates (no ownership conflicts)

**RBAC Strategy:**
- Essential operator ClusterRoles (4 files, ~200 rules total)
- Optional granular CRD-specific roles (disabled by default)
- Operators can self-manage additional RBAC if needed

### Phase 3: Postsync (After Helm Install)

**Purpose:** Validate deployment and trigger instance creation

**Actions:**
1. Wait for all 4 operators to be `Available` (up to 5 minutes)
2. Create `Kuadrant` CR (if `instance.kuadrant.enabled=true`)
3. Wait for Kuadrant instance to be `Ready`
4. Validate Authorino/Limitador instances were created
5. Run validation script (`manifests-postsync/validate.sh`)

**Why wait for operators first?**
- Creating Kuadrant CR before operators are ready causes reconciliation failures
- Ensures all CRDs are registered and webhooks are active

**Executed by:** Helmfile postsync hooks or manual steps

## Component Breakdown

### 1. Kuadrant Operator (Meta-Operator)

**Responsibilities:**
- Watch `Kuadrant` CR
- Create and manage `Authorino` and `Limitador` CRs
- Manage Gateway API policies (AuthPolicy, RateLimitPolicy, DNSPolicy, TLSPolicy)
- Inject WASM filters into Istio/Envoy sidecars
- Orchestrate DNS record creation via DNS operator

**Key Environment Variables:**
- `RELATED_IMAGE_WASMSHIM`: WASM plugin image for Envoy
- `OPERATOR_NAMESPACE`: Self-reference for namespace
- `ISTIO_GATEWAY_CONTROLLER_NAMES`: Gateway API controller identifier

**Dependencies:**
- Gateway API v1.4.0+ CRDs (deployed by sail-operator chart)
- cert-manager 1.15.2+ (deployed by cert-manager-operator chart, required for TLSPolicy)
- Istio or Envoy Gateway (for WASM injection)

### 2. Authorino Operator

**Responsibilities:**
- Watch `Authorino` CR (created by Kuadrant operator)
- Deploy Authorino service (gRPC external authorization server)
- Manage `AuthConfig` CRDs (fine-grained auth rules)
- Create ServiceAccounts, Roles, and Deployments for Authorino

**Key Environment Variables:**
- `RELATED_IMAGE_AUTHORINO`: Authorino service container image

**Reconciliation Loop:**
```
Authorino CR created
  ↓
Operator creates Deployment (authorino)
  ↓
Authorino service listens on gRPC (default: 50051)
  ↓
Gateway configures external auth to Authorino
```

### 3. Limitador Operator

**Responsibilities:**
- Watch `Limitador` CR (created by Kuadrant operator)
- Deploy Limitador service (rate limiting server)
- Manage rate limit configurations
- Support in-memory or Redis-backed storage

**Key Environment Variables:**
- `RELATED_IMAGE_LIMITADOR`: Limitador service container image

**Storage Options:**
- **In-memory** (default): Fast, ephemeral, no persistence
- **Redis**: Persistent, shared state across replicas

### 4. DNS Operator

**Responsibilities:**
- Watch `DNSRecord` and `DNSHealthCheckProbe` CRDs
- Manage external DNS records (Route53, Azure DNS, GCP Cloud DNS)
- Configure health checks for geo-routing
- Support for `DNSPolicy` (created by Kuadrant operator)

**Key Environment Variables:**
- `WATCH_NAMESPACES`: Namespace filter (empty = cluster-wide)
- `CLUSTER_SECRET_NAMESPACE`: Where DNS provider credentials are stored

## Namespace Strategy

### Two-Namespace Design

**`kuadrant-operators` (Operator Namespace):**
- All 4 operator deployments
- Operator ServiceAccounts and RBAC
- Pull secrets for Red Hat registry
- **Why separate?** Isolates operator infrastructure from user workloads

**`kuadrant-system` (Instance Namespace):**
- Kuadrant CR
- Authorino and Limitador instances (created by operators)
- Component services
- User-created policies (AuthPolicy, RateLimitPolicy, etc.)


## Image Management

### Digest Pinning Strategy

All images use **digest pinning** for reproducibility:
```yaml
image: registry.redhat.io/rhcl-1/rhcl-rhel9-operator@sha256:1afb2fe...
```

**Why digests over tags?**
- Tags are mutable (`:latest`, `:v1.2.0` can change)
- Digests are immutable (SHA256 hash)
- Ensures exact same image across environments

### Image Types

**Operator Images (4):**
- `rhcl-rhel9-operator` (Kuadrant meta-operator)
- `authorino-rhel9-operator` (Authorino operator)
- `limitador-rhel9-operator` (Limitador operator)
- `dns-rhel9-operator` (DNS operator)

**Component Images (3+):**
- `authorino-rhel9` (Authorino service)
- `limitador-rhel9` (Limitador service)
- `wasm-shim-rhel9` (Envoy WASM plugin)

**Total: 7+ images** managed via `values.yaml`

### RELATED_IMAGE Pattern

Operators use `RELATED_IMAGE_*` environment variables to reference component images:
```yaml
env:
  - name: RELATED_IMAGE_AUTHORINO
    value: registry.redhat.io/rhcl-1/authorino-rhel9@sha256:be779...
```

This allows operators to deploy correct component versions without hardcoding.

## RBAC Model

### Operator ClusterRoles

Each operator has a ClusterRole with permissions to:
1. Manage their CRDs (create, update, delete, watch)
2. Manage core resources (Deployments, Services, Secrets)
3. Read Gateway API resources
4. Create RBAC resources (for sub-components)

**Example (Kuadrant):**
- ~50 rules covering 15+ API groups
- Permissions for Kuadrant, Authorino, Limitador CRDs
- Gateway API, Istio, cert-manager resources

### Granular CRD Roles (Optional)

For each CRD, can optionally create:
- `{crd}-admin`: Full CRUD permissions
- `{crd}-edit`: Create/update/delete
- `{crd}-view`: Read-only access
- `{crd}-crdview`: View CRD definition

**Disabled by default** (`rbac.createGranularRoles: false`)

Enable for fine-grained RBAC:
```yaml
rbac:
  createGranularRoles: true
```

## Configuration Patterns

### Image Pull Secrets

**Three methods supported:**

1. **System Podman Auth** (default for local dev):
```bash
helmfile apply --set useSystemPodmanAuth=true
```
Reads `~/.config/containers/auth.json`

2. **Explicit Auth File:**
```bash
helmfile apply --set pullSecretFile=/path/to/auth.json
```

3. **Pre-created Secret:**
```bash
kubectl create secret docker-registry redhat-pull-secret \
  --docker-server=registry.redhat.io \
  --from-file=.dockerconfigjson=auth.json \
  -n kuadrant-operators

helm install rhcl . --set images.pullSecret.create=false
```

### Kuadrant Instance Configuration

**Minimal (default):**
```yaml
instance:
  kuadrant:
    enabled: true
    spec: {}  # Uses operator defaults
```

**Customized:**
```yaml
instance:
  kuadrant:
    enabled: true
    spec:
      limitador:
        affinity:
          podAntiAffinity: ...
        storage:
          redis:
            configSecretRef:
              name: redis-config
```

The Kuadrant CR spec is passed directly to the operator - refer to Kuadrant operator documentation for all options.


## Upgrade Strategy

### Helm Upgrade Process

```bash
helm upgrade rhcl . \
  --namespace kuadrant-operators \
  --values values.yaml
```

**What happens:**
1. CRDs updated (if changed)
2. Operator deployments rolled out (one at a time)
3. Kuadrant CR updated (if spec changed)
4. Sub-operators reconcile changes

**Zero-downtime:**
- RollingUpdate strategy on all deployments
- Authorino/Limitador instances continue serving during operator upgrades

### Image Updates

Update digest in `values.yaml`:
```yaml
images:
  operators:
    kuadrant:
      digest: sha256:newdigest...
```


## References

- [Kuadrant Documentation](https://docs.kuadrant.io/)
- [Authorino Documentation](https://docs.kuadrant.io/authorino/)
- [Limitador Documentation](https://docs.kuadrant.io/limitador/)
- [Gateway API Specification](https://gateway-api.sigs.k8s.io/)
- [Helm Best Practices](https://helm.sh/docs/chart_best_practices/)
