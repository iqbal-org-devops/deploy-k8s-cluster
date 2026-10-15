#!/usr/bin/env bash
#
# 02-join-worker.sh
# ------------------------------------------------------------------
# Prepares a worker node and joins it to the cluster created by
# 01-init-master.sh. MASTER_IP, versions, and hostnames all come
# from ../config.env — this script only needs the join token and
# CA cert hash, which 01-init-master.sh prints/saves on the master.
#
# Run as root ON EACH WORKER NODE:
#   sudo ./02-join-worker.sh <TOKEN> <CA_CERT_HASH>
#
# Example:
#   sudo ./02-join-worker.sh abcdef.0123456789abcdef sha256:1234...
# ------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

if [[ $# -lt 2 ]]; then
  echo "Usage: sudo $0 <TOKEN> <CA_CERT_HASH>" >&2
  echo "  CA_CERT_HASH must include the 'sha256:' prefix." >&2
  echo "  Get both from /root/kubeadm-join-command.sh on the master." >&2
  exit 1
fi

TOKEN="$1"
CA_CERT_HASH="$2"

log "Starting worker join for '$(hostname)', targeting master at ${MASTER_IP}"
log "Kubernetes v${K8S_VERSION} | CRI-O ${CRIO_VERSION}"

check_arch
maybe_install_vmware_tools
preflight_resource_check
disable_swap
configure_kernel_and_sysctl
configure_hosts_file
install_crio
install_kube_tools
install_nfs_common

log "Joining the cluster"
kubeadm join "${MASTER_IP}:6443" \
  --token "${TOKEN}" \
  --discovery-token-ca-cert-hash "${CA_CERT_HASH}" \
  --cri-socket=unix:///var/run/crio/crio.sock

log "Done. Verify from the MASTER node with: kubectl get nodes -o wide"
