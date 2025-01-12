#!/bin/bash
#
# Enhanced Common Setup for Kubernetes Nodes
# Includes improved error handling, system optimizations, and security features

# Strict error handling
set -euo pipefail
trap 'error_handler $? $LINENO' ERR

# Global variables
SETUP_LOG="/var/log/k8s-setup.log"
CRIO_REGISTRY="pkgs.k8s.io"
K8S_REGISTRY="pkgs.k8s.io"

# Error handling function
error_handler() {
    local exit_code=$1
    local line_number=$2
    echo "Error occurred in script at line: ${line_number}, exit code: ${exit_code}" | tee -a "${SETUP_LOG}"
    exit "${exit_code}"
}

# Function to verify environment variables
verify_environment() {
    echo "🔍 Verifying environment variables..." | tee -a "${SETUP_LOG}"
    
    local required_vars=("DNS_SERVERS" "KUBERNETES_VERSION" "CRIO_VERSION")
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            echo "❌ Error: Required variable $var is not set" | tee -a "${SETUP_LOG}"
            exit 1
        fi
    done

    # Validate Kubernetes version format
    if ! VERSION="$(echo "${KUBERNETES_VERSION}" | grep -oE '[0-9]+\.[0-9]+')"; then
        echo "❌ Error: Invalid KUBERNETES_VERSION format" | tee -a "${SETUP_LOG}"
        exit 1
    fi
}

# Function to optimize system settings
optimize_system() {
    echo "⚙️ Optimizing system settings..." | tee -a "${SETUP_LOG}"
    
    # Kernel parameters optimization
    cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-optimized.conf
# Network optimization
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.tcp_tw_recycle            = 0
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_fin_timeout           = 15
net.core.somaxconn                 = 32768
net.core.netdev_max_backlog        = 16384
net.ipv4.tcp_max_syn_backlog       = 8192
net.ipv4.tcp_keepalive_time        = 600
net.ipv4.tcp_keepalive_intvl       = 30
net.ipv4.tcp_keepalive_probes      = 10

# VM optimization
vm.swappiness                      = 0
vm.overcommit_memory              = 1
vm.panic_on_oom                   = 0
vm.max_map_count                  = 262144

# File system optimization
fs.file-max                       = 2097152
fs.inotify.max_user_instances     = 8192
fs.inotify.max_user_watches       = 524288
EOF

    sudo sysctl --system

    # Optimize transparent hugepage settings
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
}

# Function to configure networking
configure_networking() {
    echo "🌐 Configuring network settings..." | tee -a "${SETUP_LOG}"
    
    # DNS configuration
    sudo mkdir -p /etc/systemd/resolved.conf.d/
    cat <<EOF | sudo tee /etc/systemd/resolved.conf.d/dns_servers.conf
[Resolve]
DNS=${DNS_SERVERS}
DNSStubListener=no
DNSSEC=no
Cache=yes
DNSStubListenerExtra=
EOF

    # Disable swap permanently
    sudo swapoff -a
    sudo sed -i '/swap/d' /etc/fstab
    echo "@reboot /sbin/swapoff -a" | crontab -

    # Configure kernel modules
    cat <<EOF | sudo tee /etc/modules-load.d/k8s-modules.conf
overlay
br_netfilter
ip_tables
ip6_tables
nf_nat
xt_REDIRECT
xt_owner
iptable_nat
iptable_mangle
iptable_filter
EOF

    # Load kernel modules
    while read -r module; do
        sudo modprobe "$module"
    done < /etc/modules-load.d/k8s-modules.conf
}

# Function to install dependencies
install_dependencies() {
    echo "📦 Installing dependencies..." | tee -a "${SETUP_LOG}"
    
    local DEBIAN_FRONTEND=noninteractive
    sudo apt-get update
    sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg2 \
        software-properties-common \
        jq \
        git \
        conntrack \
        ipset \
        socat \
        bash-completion \
        iproute2 \
        nfs-common \
        chrony
}

# Function to install and configure CRI-O
install_crio() {
    echo "🐳 Installing CRI-O..." | tee -a "${SETUP_LOG}"
    
    # Add CRI-O repository
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://${CRIO_REGISTRY}/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key" | \
        sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://${CRIO_REGISTRY}/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/cri-o.list

    # Install CRI-O
    sudo apt-get update
    sudo apt-get install -y crio

    # Configure CRI-O
    cat <<EOF | sudo tee /etc/crio/crio.conf.d/02-crio-performance.conf
[crio]
storage_driver = "overlay"
storage_option = ["overlay.mount_program=/usr/bin/fuse-overlayfs"]

[crio.runtime]
default_runtime = "runc"
conmon_cgroup = "pod"
cgroup_manager = "systemd"

[crio.image]
pause_image = "registry.k8s.io/pause:3.9"
max_parallel_downloads = 10

[crio.network]
network_dir = "/etc/cni/net.d/"
plugin_dirs = ["/opt/cni/bin"]

[crio.metrics]
enable_metrics = true
metrics_port = 9537
EOF

    if [ -n "${ENVIRONMENT:-}" ]; then
        echo "${ENVIRONMENT}" | sudo tee -a /etc/default/crio
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable crio
    sudo systemctl restart crio
}

# Function to install Kubernetes components
install_kubernetes() {
    echo "☸️ Installing Kubernetes components..." | tee -a "${SETUP_LOG}"
    
    # Add Kubernetes repository
    curl -fsSL "https://${K8S_REGISTRY}/core:/stable:/$KUBERNETES_VERSION/deb/Release.key" | \
        sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://${K8S_REGISTRY}/core:/stable:/$KUBERNETES_VERSION/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list

    # Install Kubernetes packages
    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl

    # Configure kubelet
    local_ip="$(ip --json a s | jq -r '.[] | if .ifname == "eth1" then .addr_info[] | if .family == "inet" then .local else empty end else empty end')"
    
    cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS="--node-ip=${local_ip} \
--container-runtime-endpoint=unix:///var/run/crio/crio.sock \
--runtime-request-timeout=15m \
--max-pods=250 \
--image-pull-progress-deadline=2m \
--cpu-manager-policy=static \
--topology-manager-policy=best-effort"
EOF

    if [ -n "${ENVIRONMENT:-}" ]; then
        echo "${ENVIRONMENT}" | sudo tee -a /etc/default/kubelet
    fi

    sudo systemctl daemon-reload
    sudo systemctl restart kubelet
}

# Function to verify installation
verify_installation() {
    echo "✅ Verifying installation..." | tee -a "${SETUP_LOG}"
    
    # Check CRI-O status
    if ! sudo systemctl is-active crio &>/dev/null; then
        echo "❌ CRI-O is not running" | tee -a "${SETUP_LOG}"
        exit 1
    fi

    # Check kubelet status
    if ! sudo systemctl is-active kubelet &>/dev/null; then
        echo "❌ Kubelet is not running" | tee -a "${SETUP_LOG}"
        exit 1
    fi

    echo "✅ Installation completed successfully!" | tee -a "${SETUP_LOG}"
}

# Main execution
{
    echo "🚀 Starting Kubernetes node setup..."
    verify_environment
    optimize_system
    configure_networking
    install_dependencies
    install_crio
    install_kubernetes
    verify_installation
} 2>&1 | tee -a "${SETUP_LOG}"