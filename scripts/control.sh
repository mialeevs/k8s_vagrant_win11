#!/bin/bash
#
# Enhanced Setup for Kubernetes Control Plane
# This script includes improved error handling, monitoring, and performance optimizations

# Strict error handling
set -euo pipefail
trap 'catch_error $? $LINENO' ERR

# Error handling function
catch_error() {
    local exit_code=$1
    local line_number=$2
    echo "Error occurred in script at line: ${line_number}, exit code: ${exit_code}"
    exit "${exit_code}"
}

# Function to check system prerequisites
check_prerequisites() {
    echo "🔍 Checking system prerequisites..."
    
    # Check system resources
    local mem_available
    mem_available=$(free -m | awk '/^Mem:/{print $2}')
    if [ "${mem_available}" -lt 3500 ]; then
        echo "⚠️  Warning: Less than 4GB RAM available"
        sleep 3
    fi

    # Verify required tools
    for tool in curl wget kubectl kubeadm crictl; do
        if ! command -v "$tool" &> /dev/null; then
            echo "❌ Required tool not found: $tool"
            exit 1
        fi
    done
}

# Function to optimize system settings
optimize_system() {
    echo "⚙️ Optimizing system settings..."
    
    # Disable swap
    sudo swapoff -a
    sudo sed -i '/swap/d' /etc/fstab
    
    # Optimize kernel parameters for Kubernetes
    cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.tcp_tw_recycle            = 0
net.ipv4.tcp_tw_reuse              = 1
net.core.somaxconn                 = 32768
net.core.netdev_max_backlog        = 16384
net.ipv4.tcp_max_syn_backlog       = 8192
net.ipv4.tcp_fin_timeout           = 15
vm.swappiness                      = 0
EOF
    sudo sysctl --system

    # Disable unnecessary services
    sudo systemctl stop ufw || true
    sudo systemctl disable ufw || true
}

# Function to verify CRI-O status
verify_crio() {
    echo "🔍 Verifying CRI-O status..."
    
    if ! sudo systemctl is-active crio &>/dev/null; then
        echo "🔄 Restarting CRI-O service..."
        sudo systemctl restart crio
        sleep 5
    fi
    
    # Check CRI-O connectivity
    if ! sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock ps &>/dev/null; then
        echo "❌ CRI-O is not responding"
        exit 1
    fi
}

# Function to prepare for kubeadm
prepare_kubeadm() {
    echo "🔄 Preparing for kubeadm initialization..."
    
    # Reset previous installation
    sudo kubeadm reset -f || true
    sudo rm -rf /etc/cni/net.d/*
    sudo rm -rf "$HOME/.kube/config"
    
    # Clean up old certificates and configurations
    sudo rm -rf /etc/kubernetes/pki
    sudo rm -rf /etc/kubernetes/manifests/*
}

# Function to initialize control plane
initialize_control_plane() {
    echo "🚀 Initializing Kubernetes control plane..."
    
    # Get control plane IP
    CONTROL_IP=$(ip -f inet addr show eth1 | grep -Po 'inet \K[\d.]+')
    echo "📍 Control Plane IP: $CONTROL_IP"
    
    # Pull images with retry mechanism
    local retry_count=0
    while ! sudo kubeadm config images pull && [ $retry_count -lt 3 ]; do
        echo "🔄 Retrying image pull..."
        ((retry_count++))
        sleep 5
    done

    # Initialize with optimized settings
    sudo kubeadm init \
        --apiserver-advertise-address="$CONTROL_IP" \
        --apiserver-cert-extra-sans="$CONTROL_IP" \
        --pod-network-cidr="$POD_CIDR" \
        --service-cidr="$SERVICE_CIDR" \
        --node-name "$(hostname -s)" \
        --ignore-preflight-errors=Swap \
        --upload-certs \
        --control-plane-endpoint="$CONTROL_IP" \
        --v=5
}

# Function to configure networking
configure_networking() {
    echo "🌐 Configuring cluster networking..."
    
    # Setup kubectl for the current user
    mkdir -p "$HOME/.kube"
    sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
    sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
    
    # Save configurations for worker nodes
    config_path="/vagrant/configs"
    mkdir -p "$config_path"
    cp -f "$HOME/.kube/config" "$config_path/config"
    
    # Generate join command
    kubeadm token create --print-join-command > "$config_path/join.sh"
    chmod +x "$config_path/join.sh"
    
    # Install and configure Calico
    echo "🔧 Installing Calico network plugin..."
    if ! curl -sSLo calico.yaml "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"; then
        echo "❌ Failed to download Calico manifest"
        exit 1
    fi
    
    # Apply network configuration
    kubectl apply -f calico.yaml
}

# Function to install additional components
install_components() {
    echo "📦 Installing additional components..."
    
    # Install metrics server
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    
    # Configure metrics server for development environment
    kubectl patch deployment metrics-server \
        -n kube-system \
        --type=json \
        -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
}

# Function to configure vagrant user
configure_vagrant_user() {
    echo "👤 Configuring vagrant user environment..."
    
    sudo -i -u vagrant bash <<'EOF'
    mkdir -p /home/vagrant/.kube
    sudo cp -i /vagrant/configs/config /home/vagrant/.kube/
    sudo chown 1000:1000 /home/vagrant/.kube/config
    
    # Install and configure bash completion
    sudo apt-get install -y bash-completion
    
    # Setup helpful aliases and completions
    cat <<'ALIASES' >> /home/vagrant/.bashrc
# Kubernetes aliases and completions
source <(kubectl completion bash)
complete -F __start_kubectl k
alias k=kubectl
alias kn='kubectl config set-context --current --namespace'
alias kg='kubectl get'
alias kd='kubectl describe'
alias krm='kubectl delete'
alias kl='kubectl logs'
alias kex='kubectl exec -it'
alias c=clear
alias ud='sudo apt update -y && sudo apt upgrade -y'

# Enhanced prompt with kubectl context
parse_kubernetes_context() {
    kubectl config current-context 2>/dev/null
}
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\] [\[\033[01;33m\]$(parse_kubernetes_context)\[\033[00m\]]\$ '
ALIASES

    source /home/vagrant/.bashrc
EOF
}

# Function to verify cluster health
verify_cluster_health() {
    echo "🔍 Verifying cluster health..."
    
    # Wait for node to be ready
    local timeout=300
    local interval=10
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if kubectl get nodes | grep -q "Ready"; then
            echo "✅ Node is ready"
            break
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo "⏳ Waiting for node to be ready... ($elapsed/$timeout seconds)"
    done

    if [ $elapsed -ge $timeout ]; then
        echo "❌ Timeout waiting for node to be ready"
        exit 1
    fi
    
    # Display cluster status
    kubectl get nodes -o wide
    kubectl get pods --all-namespaces
}

# Main execution
{
    echo "🚀 Starting Kubernetes control plane setup..."
    check_prerequisites
    optimize_system
    verify_crio
    prepare_kubeadm
    initialize_control_plane
    configure_networking
    install_components
    configure_vagrant_user
    verify_cluster_health
    echo "✅ Control plane setup completed successfully!"
} 2>&1 | tee /var/log/k8s-control-setup.log