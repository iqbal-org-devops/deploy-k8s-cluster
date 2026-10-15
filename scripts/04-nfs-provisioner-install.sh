#!/usr/bin/env bash
#
# 04-nfs-provisioner-install.sh
# ------------------------------------------------------------------
# Run on the MASTER node, AFTER 01-init-master.sh and AFTER
# 03-nfs-server-setup.sh have both completed. Installs the
# nfs-subdir-external-provisioner via Helm and creates a default
# StorageClass named "nfs-client" backed by NFS_IP/NFS_EXPORT_PATH
# from config.env.
#
#   ./04-nfs-provisioner-install.sh
# ------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/lib/common.sh"

export KUBECONFIG=/etc/kubernetes/admin.conf

if ! command -v helm >/dev/null 2>&1; then
  log "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

log "Adding nfs-subdir-external-provisioner Helm repo"
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
helm repo update

log "Installing/upgrading the provisioner (NFS server: ${NFS_IP}, path: ${NFS_EXPORT_PATH})"
helm upgrade --install nfs-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace kube-system \
  --set nfs.server="${NFS_IP}" \
  --set nfs.path="${NFS_EXPORT_PATH}" \
  --set storageClass.name=nfs-client \
  --set storageClass.defaultClass=true \
  --set storageClass.reclaimPolicy=Retain

log "Waiting for the provisioner pod to be ready"
kubectl -n kube-system rollout status deploy/nfs-provisioner-nfs-subdir-external-provisioner --timeout=90s

echo ""
kubectl get storageclass
