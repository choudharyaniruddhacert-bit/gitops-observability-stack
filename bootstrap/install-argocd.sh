#!/usr/bin/env bash

set -euo pipefail

NAMESPACE=argocd

helm repo add argo https://argoproj.github.io/argo-helm

helm repo update

helm upgrade --install argocd argo/argo-cd \
    --namespace "$NAMESPACE" --create-namespace \
    --wait

kubectl -n "$NAMESPACE" get pods

echo "Argo CD admin password:"

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo