#!/usr/bin/env bash
#
# 99-reset-node.sh
# ------------------------------------------------------------------
# Cleanly resets a node (master OR worker) back to a pre-kubeadm
# state, so 01-init-master.sh / 02-join-worker.sh can be re-run from
# scratch. Written after debugging a CRI-O image-store corruption
# issue where kubeadm reset alone was NOT enough — CRI-O's storage
# also needs to be stopped, unmounted, and wiped.
#
# Run as root ON THE NODE YOU WANT TO RESET:
#   sudo ./99-reset-node.sh            # reset state, keep packages installed
#   sudo ./99-reset-node.sh --purge    # also apt-get remove kube*/cri-o packages
# ------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

PURGE=false
if [[ "${1:-}" == "--purge" ]]; then
  PURGE=true
fi

log "Running kubeadm reset (if kubeadm is installed)"
if command -v kubeadm >/dev/null 2>&1; then
  kubeadm reset -f --cri-socket=unix:///var/run/crio/crio.sock || true
fi

log "Stopping kubelet and CRI-O"
systemctl stop kubelet 2>/dev/null || true
systemctl stop crio 2>/dev/null || true

log "Unmounting any leftover CRI-O storage mounts"
# Must happen with crio stopped, or these will report "target is busy".
for m in $(mount | grep '/var/lib/containers/storage' | awk '{print $3}' | sort -r); do
  umount "${m}" 2>/dev/null || true
done

log "Wiping Kubernetes and CRI-O state"
rm -rf /etc/kubernetes
rm -rf /var/lib/etcd
rm -rf /var/lib/kubelet
rm -rf /var/lib/containers/storage/*

log "Restarting CRI-O"
systemctl start crio 2>/dev/null || true
sleep 2
systemctl status crio --no-pager || true

if [[ "${PURGE}" == "true" ]]; then
  log "Purging kubeadm/kubelet/kubectl/cri-o packages (--purge specified)"
  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
  apt-get purge -y kubelet kubeadm kubectl cri-o 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/cri-o.list
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg /etc/apt/keyrings/cri-o-apt-keyring.gpg
fi

echo ""
echo "Reset complete on $(hostname)."
if [[ "${PURGE}" == "true" ]]; then
  echo "Packages were purged — re-run 01-init-master.sh or 02-join-worker.sh to reinstall from scratch."
else
  echo "State was wiped but packages are still installed — re-run 01-init-master.sh or 02-join-worker.sh directly."
fi
