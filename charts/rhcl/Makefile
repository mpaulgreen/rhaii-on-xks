# RHCL Helm Chart Makefile
#
# Deployment Methods:
#   - Helmfile (RECOMMENDED): Use 'make apply/destroy' targets
#     - Includes presync/postsync hooks for proper sequencing
#     - Automatic finalizer cleanup on destroy
#   - Direct Helm: Use 'make install/uninstall' targets
#     - Requires manual steps (presync, Kuadrant CR creation)
#     - Suitable for development/testing

.PHONY: help lint template template-debug dry-run install upgrade uninstall test validate status logs logs-all clean package diff apply destroy

CHART_NAME := rhcl
NAMESPACE := kuadrant-operators
RELEASE_NAME := rhcl
VALUES_FILE := values.yaml

help: ## Show this help message
	@echo "RHCL Helm Chart - Make Targets"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## Lint the Helm chart
	@echo "Linting Helm chart..."
	helm lint .
	@echo "✓ Lint complete"

template: ## Generate Kubernetes manifests from templates
	@echo "Generating templates..."
	helm template $(RELEASE_NAME) . \
		--namespace $(NAMESPACE) \
		--values $(VALUES_FILE) \
		--include-crds
	@echo "✓ Template generation complete"

template-debug: ## Generate templates with debug output
	@echo "Generating templates with debug..."
	helm template $(RELEASE_NAME) . \
		--namespace $(NAMESPACE) \
		--values $(VALUES_FILE) \
		--include-crds \
		--debug

dry-run: ## Perform a dry-run install
	@echo "Performing dry-run install..."
	helm install $(RELEASE_NAME) . \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--values $(VALUES_FILE) \
		--dry-run \
		--debug

install: ## Install the chart using Helm (use 'make apply' for recommended method)
	@echo "Installing RHCL chart with Helm..."
	@echo "NOTE: For production use, 'make apply' (helmfile) is recommended"
	@echo ""
	@echo "1. Creating namespaces and presync resources..."
	kubectl apply -f manifests-presync/
	@echo ""
	@echo "2. Installing Helm chart..."
	helm install $(RELEASE_NAME) . \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--values $(VALUES_FILE) \
		--set-file images.pullSecret.dockerConfigJson=$(HOME)/.config/containers/auth.json \
		--wait \
		--timeout 10m
	@echo ""
	@echo "3. Waiting for operators to be ready..."
	kubectl wait --for=condition=Available \
		deployment/kuadrant-operator-controller-manager \
		deployment/authorino-operator \
		deployment/limitador-operator-controller-manager \
		-n $(NAMESPACE) \
		--timeout=5m
	@echo ""
	@echo "4. Creating Kuadrant instance..."
	@printf 'apiVersion: kuadrant.io/v1beta1\nkind: Kuadrant\nmetadata:\n  name: kuadrant\n  namespace: kuadrant-system\nspec: {}\n' | kubectl apply -f -
	@echo ""
	@echo "5. Waiting for Kuadrant instance..."
	kubectl wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=5m
	@echo ""
	@echo "✓ Installation complete!"

upgrade: ## Upgrade the chart
	@echo "Upgrading RHCL chart..."
	helm upgrade $(RELEASE_NAME) . \
		--namespace $(NAMESPACE) \
		--values $(VALUES_FILE) \
		--set-file images.pullSecret.dockerConfigJson=$(HOME)/.config/containers/auth.json \
		--wait \
		--timeout 10m
	@echo "✓ Upgrade complete!"

uninstall: ## Uninstall the chart using Helm (use destroy for helmfile method)
	@echo "Uninstalling RHCL chart with Helm..."
	@echo "NOTE: For production use, 'make destroy' (helmfile) is recommended"
	@echo ""
	@echo "1. Deleting Kuadrant instance..."
	-kubectl delete kuadrant kuadrant -n kuadrant-system --wait=false --timeout=10s
	@echo ""
	@echo "2. Removing finalizers if stuck..."
	-kubectl patch authorino authorino -n kuadrant-system -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	-kubectl patch limitador limitador -n kuadrant-system -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	-kubectl patch kuadrant kuadrant -n kuadrant-system -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	@echo ""
	@echo "3. Uninstalling Helm release..."
	helm uninstall $(RELEASE_NAME) -n $(NAMESPACE) || true
	@echo ""
	@echo "4. Cleaning up namespaces..."
	-kubectl delete namespace kuadrant-system --timeout=60s
	-kubectl delete namespace $(NAMESPACE) --timeout=60s
	@echo "✓ Uninstall complete!"

validate: ## Validate the deployment
	@echo "Validating RHCL deployment..."
	@bash manifests-postsync/validate.sh
	@echo "✓ Validation complete!"

test: ## Run Helm tests
	@echo "Running Helm tests..."
	helm test $(RELEASE_NAME) -n $(NAMESPACE)
	@echo "✓ Tests complete!"

status: ## Show deployment status
	@echo "=== Helm Release Status ==="
	helm status $(RELEASE_NAME) -n $(NAMESPACE)
	@echo ""
	@echo "=== Operator Deployments ==="
	kubectl get deployments -n $(NAMESPACE) -l app.kubernetes.io/part-of=rhcl
	@echo ""
	@echo "=== Kuadrant Instance ==="
	kubectl get kuadrant,authorino,limitador -n kuadrant-system 2>/dev/null || echo "No instances found"
	@echo ""
	@echo "=== CRDs ==="
	kubectl get crds | grep kuadrant || echo "No Kuadrant CRDs found"

logs: ## Show operator logs
	@echo "=== Kuadrant Operator Logs ==="
	kubectl logs -n $(NAMESPACE) deployment/kuadrant-operator-controller-manager --tail=50

logs-all: ## Show logs from all operators
	@echo "=== Kuadrant Operator ==="
	kubectl logs -n $(NAMESPACE) deployment/kuadrant-operator-controller-manager --tail=20
	@echo ""
	@echo "=== Authorino Operator ==="
	kubectl logs -n $(NAMESPACE) deployment/authorino-operator --tail=20
	@echo ""
	@echo "=== Limitador Operator ==="
	kubectl logs -n $(NAMESPACE) deployment/limitador-operator-controller-manager --tail=20
	@echo ""
	@echo "=== DNS Operator (if enabled) ==="
	-kubectl logs -n $(NAMESPACE) deployment/dns-operator-controller-manager --tail=20 2>/dev/null || echo "DNS operator not deployed (disabled by default)"

clean: ## Clean up generated files
	@echo "Cleaning up..."
	@rm -rf charts/*.tgz
	@rm -rf .helmfile
	@echo "✓ Clean complete!"

package: ## Package the Helm chart
	@echo "Packaging chart..."
	helm package .
	@echo "✓ Chart packaged!"

## Helmfile targets (recommended for production)

diff: ## Preview changes with Helmfile
	@echo "Previewing changes with Helmfile..."
	helmfile diff

apply: ## Install/upgrade using Helmfile (recommended)
	@echo "Deploying RHCL with Helmfile..."
	helmfile apply

destroy: ## Uninstall using Helmfile (recommended)
	@echo "Destroying RHCL with Helmfile..."
	helmfile destroy
