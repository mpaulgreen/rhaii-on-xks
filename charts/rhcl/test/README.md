# RHCL Test Suite

Automated end-to-end test for RHCL policy enforcement.

---

## Quick Start

```bash
# From repository root:
cd charts/rhcl/test

# Run test with automatic cleanup (recommended)
./deploy-test.sh

# Keep resources for inspection
./deploy-test.sh --no-cleanup
```

**Test duration:** ~30 seconds

---

## What Gets Tested

✅ **Policy Enforcement**
- AuthPolicy enforced (anonymous auth)
- RateLimitPolicy enforced (10 req/min)

✅ **HTTP Request Flow**
- Gateway → WasmPlugin → Authorino → Echo service
- Requests return 200 OK

✅ **Rate Limiting**
- First 9-10 requests succeed (HTTP 200)
- Additional requests blocked (HTTP 429)

✅ **RHCL Resources**
- AuthConfig created in kuadrant-system
- WasmPlugin created in test namespace
- EnvoyFilters created automatically by Kuadrant operator

---

## Expected Output

```
=== RHCL Test Deployment ===

✅ Prerequisites check passed

Step 1: Applying test manifest...
[deployment output]

Step 2: Copying pull secrets...
✅ Pull secrets copied

Step 3: Waiting for resources to be ready...
✅ Gateway pod is running

=== Step 4: Validating RHCL Policies ===

  ✅ AuthPolicy: Enforced
  ✅ RateLimitPolicy: Enforced
  ✅ HTTP Request: 200 (Success)

  Testing rate limiting (10 req/min limit)...
    HTTP 200 (Allowed): 9
    HTTP 429 (Rate Limited): 3
  ✅ Rate Limiting: Working

  ✅ RHCL Resources: Created

=== Validation Summary ===

✅ Deployment successful
✅ All pods running
✅ Policies enforced: AuthPolicy (True), RateLimitPolicy (True)
✅ HTTP requests working: 200
✅ Rate limiting active: 9 allowed, 3 blocked

=== Cleanup ===

  ✅ Test namespace deleted

All test resources have been cleaned up.
```

---

## Troubleshooting

### Test Hangs Waiting for Pods

**Check pod status:**
```bash
kubectl get pods -n rhcl-test
```

**Common causes:**
- ImagePullBackOff: Pull secrets not copied (script handles this automatically)
- CrashLoopBackOff: Usually Istio sidecar injection issue (test disables sidecars)

### AuthPolicy Not Enforced

**Check operator logs:**
```bash
kubectl logs -n kuadrant-operators deployment/kuadrant-operator-controller-manager --tail=50
```

**Check policy status:**
```bash
kubectl describe authpolicy echo-auth -n rhcl-test
```

### HTTP Requests Return 403

**Cause:** Istio RBAC blocking requests

**Fix:** The test manifest includes an Istio AuthorizationPolicy (`allow-all`) to prevent this. If you modified the manifest, ensure it's present.

### Rate Limiting Not Working

**Check Limitador service:**
```bash
kubectl get pods -n kuadrant-system -l app=limitador
kubectl logs -n kuadrant-system -l app=limitador --tail=50
```

---

## Test Architecture

```
Test Request Flow:

curl-test pod
  ↓
Gateway (Istio)
  ↓
Istio AuthorizationPolicy (allow-all) ← Lets traffic through to RHCL
  ↓
WasmPlugin (RHCL enforcement point)
  ├─→ Authorino (authentication/authorization)
  └─→ Limitador (rate limiting)
  ↓
Echo service (if policies allow)
```

**Key Points:**
- **Istio AuthorizationPolicy:** Allows all traffic through Istio RBAC so RHCL policies can handle security
- **WasmPlugin:** Injected by Kuadrant operator, enforces AuthPolicy and RateLimitPolicy
- **EnvoyFilters:** Automatically created by Kuadrant operator to configure auth/ratelimit service endpoints
- **No service aliases needed:** EnvoyFilters handle service discovery

---

## Manual Cleanup

If you used `--no-cleanup` flag:

```bash
kubectl delete ns rhcl-test
```

This deletes:
- Test namespace and all resources
- AuthConfig in kuadrant-system (auto-deleted via ownerReference)

---

## Files

- **deploy-test.sh** - Automated deployment and validation script
- **test-rhcl-deployment.yaml** - Complete test environment manifest

**Note:** These files are excluded from Helm packaging via `.helmignore`.

---

## Prerequisites

Before running tests, ensure:

1. ✅ RHCL deployed: `helmfile -e aks apply`
2. ✅ Istio installed with Gateway API support
3. ✅ Red Hat pull secret in kuadrant-system namespace
