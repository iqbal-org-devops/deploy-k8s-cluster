#!/usr/bin/env bash
#
# lib/common.sh
# ------------------------------------------------------------------
# Shared functions used by 01-init-master.sh, 02-join-worker.sh, and
# 99-reset-node.sh. This file only DEFINES functions — it does not
# run anything on its own. It expects config.env to already be
# sourced by the caller (for MASTER_IP, WORKER_IPS, K8S_VERSION, etc).
#
# Target: Ubuntu 24.04.x LTS, arm64 or amd64, CRI-O runtime.
# ------------------------------------------------------------------

log() {
  echo -e "\n>>> [$(date +'%H:%M:%S')] $*"
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: this script must be run as root (sudo ...)." >&2
    exit 1
  fi
}

check_arch() {
  local arch
  arch="$(dpkg --print-architecture)"
  log "Detected architecture: ${arch}"
  # Informational only — apt pulls the matching-arch package automatically.
}

# On VMware Fusion/Workstation, missing open-vm-tools is a common cause of
# guest clock drift, which makes etcd crash-loop with election-timeout
# errors. Install it automatically when VMware is detected; harmless
# no-op everywhere else.
maybe_install_vmware_tools() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    if [[ "${virt}" == "vmware" ]]; then
      log "VMware virtualization detected — ensuring open-vm-tools + time sync are installed"
      apt-get update -y
      apt-get install -y open-vm-tools
      systemctl enable --now open-vm-tools 2>/dev/null || true
      timedatectl set-ntp true 2>/dev/null || true
    fi
  fi
}

# Warn (don't block) if the node is under kubeadm's practical minimums.
preflight_resource_check() {
  local cpus mem_kb mem_gb
  cpus="$(nproc)"
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  mem_gb=$(( mem_kb / 1024 / 1024 ))

  log "Resource check: ${cpus} vCPU, ${mem_gb} GB RAM"
  if (( cpus < 2 )); then
    echo "WARNING: kubeadm requires at least 2 CPUs on control-plane nodes." >&2
  fi
  if (( mem_gb < 2 )); then
    echo "WARNING: less than 2GB RAM detected. etcd and kube-apiserver are prone to" >&2
    echo "         crash-looping / being OOM-killed below this. 4GB+ recommended for master." >&2
  fi
}

disable_swap() {
  log "Disabling swap"
  swapoff -a
  sed -ri 's/^([^#].*\sswap\s.*)$/#\1/' /etc/fstab
}

configure_kernel_and_sysctl() {
  log "Loading kernel modules and tuning sysctl for Kubernetes"
  cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null
}

# Writes static /etc/hosts entries for master + all workers + nfs node,
# using the arrays/vars defined in config.env. Idempotent: skips any IP
# already present.
configure_hosts_file() {
  log "Writing static /etc/hosts entries"
  cp /etc/hosts "/etc/hosts.bak.$(date +%s)"

  local entries=("${MASTER_IP} ${MASTER_HOSTNAME}")
  local i
  for i in "${!WORKER_HOSTNAMES[@]}"; do
    entries+=("${WORKER_IPS[$i]} ${WORKER_HOSTNAMES[$i]}")
  done
  entries+=("${NFS_IP} ${NFS_HOSTNAME}")

  local entry ip
  for entry in "${entries[@]}"; do
    ip="${entry%% *}"
    if ! grep -qE "^\s*${ip}\s" /etc/hosts; then
      echo "${entry}" >> /etc/hosts
    fi
  done
}

# Installs CRI-O at CRIO_VERSION (derived from K8S_MINOR in config.env)
# from the current official CRI-O repo, and pins the systemd cgroup
# manager explicitly to avoid kubelet/runtime cgroup-driver mismatches.
install_crio() {
  log "Installing CRI-O ${CRIO_VERSION}"
  apt-get update -y
  apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common
  mkdir -p -m 755 /etc/apt/keyrings

  curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
  chmod 644 /etc/apt/keyrings/cri-o-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/cri-o.list
  chmod 644 /etc/apt/sources.list.d/cri-o.list

  apt-get update -y
  apt-get install -y cri-o

  mkdir -p /etc/crio/crio.conf.d
  cat <<EOF >/etc/crio/crio.conf.d/10-cgroup-manager.conf
[crio.runtime]
cgroup_manager = "systemd"
EOF

  systemctl daemon-reload
  systemctl enable --now crio
  systemctl restart crio
}

# Installs kubeadm/kubelet/kubectl pinned to K8S_VERSION and holds them
# so a stray `apt upgrade` can't silently move the cluster version.
install_kube_tools() {
  log "Adding pkgs.k8s.io repo for v${K8S_MINOR} and installing kubeadm/kubelet/kubectl ${K8S_VERSION}"
  mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  chmod 644 /etc/apt/sources.list.d/kubernetes.list

  apt-get update -y
  apt-get install -y \
    kubelet="${K8S_VERSION}-*" \
    kubeadm="${K8S_VERSION}-*" \
    kubectl="${K8S_VERSION}-*"
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable kubelet
}

install_nfs_common() {
  log "Installing nfs-common (NFS client support, needed for PersistentVolumes)"
  apt-get install -y nfs-common
}
