#!/usr/bin/env bash

set -euxo pipefail

SETUP_LOG=${SETUP_LOG:-"/var/log/k8s-setup.log"}
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

error_handler() {
    local exit_code=$1
    local line_number=$2
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - Error on line ${line_number}: Command exited with status ${exit_code}" | 
        tee -a "${SETUP_LOG}"
    exit "${exit_code}"
}
trap 'error_handler $? $LINENO' ERR

log() {
    local level=$1
    shift
    echo "[${level}] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${SETUP_LOG}"
}

if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    log "ERROR" "This script must be run with root privileges"
    exit 1
fi

required_vars=("DNS_SERVERS" "KUBERNETES_VERSION" "CRIO_VERSION" "OS")

for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        log "ERROR" "$var is not set"
        exit 1
    fi
done

disable_swap() {
    sudo swapoff -a
    (crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true
}

configure_dns() {
    log "INFO" "Configuring DNS settings..."
    
    # Disable IPv6 to avoid connectivity issues
    echo 'net.ipv6.conf.all.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.default.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
    sysctl -p
    
    # Configure systemd-resolved
    mkdir -p /etc/systemd/resolved.conf.d/
    cat <<EOF | sudo tee /etc/systemd/resolved.conf.d/dns_servers.conf
[Resolve]
DNS=${DNS_SERVERS}
DNSStubListener=no
FallbackDNS=8.8.8.8 8.8.4.4
EOF

    # Also configure /etc/resolv.conf as backup
    cat <<EOF | sudo tee /etc/resolv.conf
nameserver 9.9.9.9
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    systemctl restart systemd-resolved
    
    # Wait a moment for DNS to be ready
    sleep 2
    
    # Verify DNS resolution
    for i in {1..5}; do
        if nslookup pkgs.k8s.io >/dev/null 2>&1; then
            log "INFO" "DNS resolution verified successfully"
            return 0
        fi
        log "WARN" "DNS resolution attempt $i failed. Retrying..."
        sleep 2
    done
    
    log "ERROR" "DNS resolution verification failed after 5 attempts"
    exit 1
}

container_runtime_setup() {
    log "INFO" "Setting up container runtime prerequisites..."
    
    cat <<EOF | sudo tee /etc/modules-load.d/crio.conf
overlay
br_netfilter
EOF

    for module in overlay br_netfilter; do
        if ! lsmod | grep -q "^$module"; then
            log "INFO" "Loading kernel module: $module"
            modprobe "$module"
        fi
    done

    cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system
}

install_crio() {
    log "INFO" "Installing CRI-O version ${CRIO_VERSION}..."
    
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" | \
        sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/cri-o.list

    for i in {1..3}; do
        if apt-get update && apt-get install -y cri-o; then
            log "INFO" "Successfully installed CRI-O"
            break
        fi
        if [ $i -eq 3 ]; then
            log "ERROR" "Failed to install CRI-O after 3 attempts"
            exit 1
        fi
        log "WARN" "CRI-O installation attempt $i failed. Retrying..."
        sleep 5
    done

    mkdir -p /etc/crio/crio.conf.d/
    cat <<EOF | sudo tee /etc/crio/crio.conf.d/02-crio.conf
[crio.runtime]
conmon_cgroup = "pod"
cgroup_manager = "systemd"

[crio.image]
pause_image = "registry.k8s.io/pause:3.10"

[crio.network]
network_dir = "/etc/cni/net.d/"
plugin_dirs = ["/opt/cni/bin"]
EOF

    systemctl daemon-reload
    systemctl enable --now crio
    
    if ! systemctl is-active --quiet crio; then
        log "ERROR" "CRI-O service failed to start"
        systemctl status crio
        exit 1
    fi
    
    log "INFO" "CRI-O installation completed"
}

install_kubernetes() {
    log "INFO" "Installing Kubernetes version ${KUBERNETES_VERSION}..."

    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | \
        sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    
    sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list

    apt-get update
    apt-get install -y kubelet kubeadm kubectl jq
    apt-mark hold kubelet kubeadm kubectl

    local_ip=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    
    if [ -z "$local_ip" ]; then
        log "ERROR" "Could not detect local IP address"
        exit 1
    fi

    mkdir -p /etc/default
    cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF
}

main() {
    log "INFO" "Starting Kubernetes node setup..."
    
    configure_dns
    disable_swap
    container_runtime_setup
    install_crio
    install_kubernetes
    
    log "INFO" "Kubernetes node setup completed successfully"
}

main "$@"
