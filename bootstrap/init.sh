#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="gitops"
ARGOCD_VERSION="10.1.4"

# 1. Provision the cluster (skip if it exists)
if k3d cluster list "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  echo "Creating cluster '${CLUSTER_NAME}'..."
  k3d cluster create "${CLUSTER_NAME}" \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer"
fi

# 2. Install Argo CD (skip if the release exists)
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

if helm status argocd -n argocd >/dev/null 2>&1; then
  echo "Argo CD release already exists, skipping install."
else
  echo "Installing Argo CD ${ARGOCD_VERSION}..."
  helm install argocd argo/argo-cd \
    --namespace argocd --create-namespace \
    --version "${ARGOCD_VERSION}" \
    --wait
fi

# 3. Apply the root application (apply is idempotent)
echo "Applying root application..."
kubectl apply -f "$(dirname "$0")/root.yaml"

echo "Bootstrap complete."
