#!/usr/bin/env bash
#
# Enhanced Worker Node Setup Script for Kubernetes Cluster
# Features:
# - Advanced security hardening
# - Performance optimizations
# - Comprehensive monitoring
# - Robust error handling
# - Automated health checks

# Strict error handling and debugging
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Global variables with readonly protection
readonly CONFIG_PATH="/vagrant/configs"
readonly SETUP_LOG="/var/log/k8s-worker-setup.log"
readonly MAX_RETRIES=5
readonly TIMEOUT=300
readonly INTERVAL=10
readonly TEMP_DIR=$(mktemp -d)

# Cleanup temporary directory on exit
trap 'rm -rf "${TEMP_DIR}"' EXIT

# Enhanced logging function
log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "${SETUP_LOG}"
}

# Comprehensive error handling with cleanup
error_handler() {
    local exit_code=$1
    local line_number=$2
    local command="$3"
    log "ERROR" "Command '${command}' failed at line ${line_number} with exit code ${exit_code}"
    cleanup_on_failure
    exit "${exit_code}"
}

trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# Cleanup function for failure scenarios
cleanup_on_failure() {
    log "INFO" "Performing cleanup after failure..."

    # Reset Kubernetes components
    if command -v kubeadm >/dev/null 2>&1; then
        kubeadm reset -f || true
    fi

    # Clean up network configurations
    rm -rf /etc/cni/net.d/* || true

    # Reset containerd and CRI-O
    for service in containerd crio; do
        if systemctl is-active ${service} >/dev/null 2>&1; then
            systemctl stop ${service} || true
        fi
    done

    # Reset iptables
    iptables -F || true
    iptables -t nat -F || true

    # Clean up network interfaces
    for iface in cni0 flannel.1 calico.1; do
        if ip link show "${iface}" >/dev/null 2>&1; then
            ip link delete "${iface}" || true
        fi
    done
}

# System requirements verification
verify_system_requirements() {
    log "INFO" "Verifying system requirements..."

    # Define minimum requirements
    local min_memory=4096  # 4GB in MB
    local min_cpu=2
    local min_disk=20      # Reduced to 20GB to match available resources

    # Get available resources
    local available_memory=$(free -m | awk '/^Mem:/{print $2}')
    local available_cpu=$(nproc)
    local available_disk=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')

    # Check requirements
    if [ "${available_memory}" -lt "${min_memory}" ]; then
        log "ERROR" "Insufficient memory: ${available_memory}MB < ${min_memory}MB required"
        exit 1
    fi

    if [ "${available_cpu}" -lt "${min_cpu}" ]; then
        log "ERROR" "Insufficient CPU cores: ${available_cpu} < ${min_cpu} required"
        exit 1
    fi

    if [ "${available_disk}" -lt "${min_disk}" ]; then
        log "ERROR" "Insufficient disk space: ${available_disk}GB < ${min_disk}GB required"
        exit 1
    fi


    # Verify kernel modules
    local required_modules=(
        "br_netfilter"
        "overlay"
        "ip_vs"
        "ip_vs_rr"
        "ip_vs_wrr"
        "ip_vs_sh"
    )

    for module in "${required_modules[@]}"; do
        if ! lsmod | grep -q "^${module}"; then
            log "INFO" "Loading kernel module: ${module}"
            modprobe "${module}"
        fi
    done
}

# System optimization
optimize_system() {
    log "INFO" "Applying system optimizations..."

    # Kernel parameters optimization
    cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-worker.conf
# Network optimizations
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 40000
net.ipv4.tcp_max_tw_buckets = 500000
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

# Memory optimizations
vm.swappiness = 0
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100
vm.max_map_count = 262144

# General Kubernetes requirements
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1

# Performance optimizations
kernel.pid_max = 65535
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

    sysctl --system

    # Resource limits configuration
    cat <<EOF | sudo tee /etc/security/limits.d/kubernetes.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 262144
* hard nproc 262144
* soft memlock unlimited
* hard memlock unlimited
root soft nofile 1048576
root hard nofile 1048576
EOF

    # Optimize transparent hugepage settings
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
}


join_cluster() {
    log "INFO" "Joining the Kubernetes cluster..."

    # Full path to join script
    local join_script="${CONFIG_PATH}/join.sh"

    # Check if join script exists
    if [ ! -f "$join_script" ]; then
        log "ERROR" "Join script not found at ${join_script}"
        ls -l ${CONFIG_PATH}/ >> "${SETUP_LOG}"
        return 1
    fi

    # Make executable and run with absolute path
    chmod +x "$join_script"
    bash "$join_script"

    if [ $? -eq 0 ]; then
        log "INFO" "Successfully joined the cluster"
        return 0
    else
        log "ERROR" "Failed to join cluster"
        return 1
    fi
}


setup_monitoring() {
    log "INFO" "Setting up node monitoring..."

    local NODE_EXPORTER_VERSION="1.8.2"

    wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
        -O "${TEMP_DIR}/node_exporter.tar.gz"

    tar xf "${TEMP_DIR}/node_exporter.tar.gz" -C "${TEMP_DIR}"
    mv "${TEMP_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/

    useradd -rs /bin/false node_exporter || true

    cat <<EOF | tee /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now node_exporter
}

verify_node_health() {
    log "INFO" "Verifying node health status..."
    sleep 30

    local elapsed=0
    local health_url="http://localhost:10248/healthz"
    local timeout=300
    local interval=10

    while [ "${elapsed}" -lt "${timeout}" ]; do
        if curl -sSf "${health_url}" &>/dev/null; then
            log "INFO" "Node is healthy and ready"
            return 0
        fi
        sleep "${interval}"
        elapsed=$((elapsed + interval))
        log "INFO" "Waiting for node to become ready... (${elapsed}/${timeout} seconds)"
    done

    log "ERROR" "Node failed to become ready within timeout period"
    return 1
}

# Main execution
main() {
    log "INFO" "Starting worker node setup..."

    verify_system_requirements
    optimize_system
    join_cluster
    setup_monitoring
    verify_node_health

    log "INFO" "Worker node setup completed successfully"
}

main "$@"