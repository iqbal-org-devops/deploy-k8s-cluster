#!/usr/bin/env bash
#
# 03-nfs-server-setup.sh
# ------------------------------------------------------------------
# Run as root ON THE NFS NODE. Exports NFS_EXPORT_PATH (from
# config.env) to the master and every worker so it can back a
# StorageClass (see 04-nfs-provisioner-install.sh).
#
#   sudo ./03-nfs-server-setup.sh
# ------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

log "Installing nfs-kernel-server"
apt-get update -y
apt-get install -y nfs-kernel-server

log "Creating export directory ${NFS_EXPORT_PATH}"
mkdir -p "${NFS_EXPORT_PATH}"
chown nobody:nogroup "${NFS_EXPORT_PATH}"
chmod 0777 "${NFS_EXPORT_PATH}"

log "Writing /etc/exports for master + all workers"
cp /etc/exports "/etc/exports.bak.$(date +%s)" 2>/dev/null || true

allowed_ips=("${MASTER_IP}")
for ip in "${WORKER_IPS[@]}"; do
  allowed_ips+=("${ip}")
done

for ip in "${allowed_ips[@]}"; do
  line="${NFS_EXPORT_PATH} ${ip}(rw,sync,no_subtree_check,no_root_squash)"
  grep -qF "${line}" /etc/exports 2>/dev/null || echo "${line}" >> /etc/exports
done

log "Applying exports and restarting NFS services"
exportfs -ra
systemctl enable --now nfs-kernel-server

echo ""
echo "NFS export ready: ${NFS_EXPORT_PATH}"
showmount -e localhost || true
