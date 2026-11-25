#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=observability

# 1. Namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 2. Grafana admin secret
read -rp  "Grafana admin username: " GF_USER
read -rsp "Grafana admin password (letters/digits only): " GF_PASS
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

# 3. SeaweedFS S3 secret (shared by SeaweedFS and Loki)
if kubectl -n "$NAMESPACE" get secret seaweedfs-s3 >/dev/null 2>&1; then
  echo "seaweedfs-s3 already exists - keeping existing keys"
else
  S3_ACCESS_KEY=$(openssl rand -hex 10)
  S3_SECRET_KEY=$(openssl rand -hex 20)

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: seaweedfs-s3
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${S3_ACCESS_KEY}"
  AWS_SECRET_ACCESS_KEY: "${S3_SECRET_KEY}"
  seaweedfs_s3_config: |
    {
      "identities": [
        {
          "name": "observability",
          "credentials": [
            { "accessKey": "${S3_ACCESS_KEY}", "secretKey": "${S3_SECRET_KEY}" }
          ],
          "actions": ["Admin", "Read", "Write", "List", "Tagging"]
        }
      ]
    }
EOF
fi

kubectl -n "$NAMESPACE" get secrets