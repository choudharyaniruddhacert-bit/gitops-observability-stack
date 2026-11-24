#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=observability

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

read -rp "Grafana admin username: " GF_USER

read -rsp "Grafana admin password: " GF_PASS

echo

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
    name: grafana-admin
    namespace: ${NAMESPACE}
type: Opaque
stringData:
    admin-user: "${GF_USER}"
    admin-password: "${GF_PASS}"
EOF

echo "Secret grafana-admin created in namespace ${NAMESPACE}"
