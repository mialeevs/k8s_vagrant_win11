#!/bin/bash
#
# Enhanced Worker Node Setup Script
# Includes improved error handling, verification, and node optimization

# Strict error handling
set -euo pipefail
trap 'error_handler $? $LINENO' ERR

# Global variables
readonly CONFIG_PATH="/vagrant/configs"
readonly SETUP_LOG="/var/log/k8s-worker-setup.log"

# Error handling function
error_handler() {
    local exit_code=$1
    local line_number=$2
    echo "❌ Error occurred in script at line: ${line_number}, exit code: ${exit_code}" | tee -a "${SETUP_LOG}"
    exit "${exit_code}"
}

# Function to verify prerequisites
verify_prerequisites() {
    echo "🔍 Verifying prerequisites..." | tee -a "${SETUP_LOG}"
    
    # Check join script existence
    if [ ! -f "${CONFIG_PATH}/join.sh" ]; then
        echo "❌ Error: Join script not found at ${CONFIG_PATH}/join.sh" | tee -a "${SETUP_LOG}"
        exit 1
    fi

    # Check kubeconfig existence
    if [ ! -f "${CONFIG_PATH}/config" ]; then
        echo "❌ Error: Kubeconfig not found at ${CONFIG_PATH}/config" | tee -a "${SETUP_LOG}"
        exit 1
    fi

    # Verify CRI-O is running
    if ! systemctl is-active --quiet crio; then
        echo "❌ Error: CRI-O is not running" | tee -a "${SETUP_LOG}"
        exit 1
    fi

    # Verify kubelet is running
    if ! systemctl is-active --quiet kubelet; then
        echo "❌ Error: kubelet is not running" | tee -a "${SETUP_LOG}"
        exit 1
    }
}

# Function to optimize node settings
optimize_node() {
    echo "⚙️ Optimizing node settings..." | tee -a "${SETUP_LOG}"
    
    # Configure system limits
    cat <<EOF | sudo tee /etc/security/limits.d/kubernetes.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
* soft memlock unlimited
* hard memlock unlimited
EOF

    # Optimize kubelet settings
    cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/11-cgroups.conf
[Service]
CPUAccounting=true
MemoryAccounting=true
BlockIOAccounting=true
EOF

    sudo systemctl daemon-reload
}

# Function to join the cluster
join_cluster() {
    echo "🔄 Joining the cluster..." | tee -a "${SETUP_LOG}"
    
    # Make join script executable
    chmod +x "${CONFIG_PATH}/join.sh"
    
    # Execute join command with retries
    local max_retries=3
    local retry_count=0
    local joined=false
    
    while [ $retry_count -lt $max_retries ] && [ "$joined" = false ]; do
        if /bin/bash "${CONFIG_PATH}/join.sh" -v; then
            joined=true
            echo "✅ Successfully joined the cluster" | tee -a "${SETUP_LOG}"
        else
            ((retry_count++))
            echo "⚠️ Join attempt $retry_count failed, retrying..." | tee -a "${SETUP_LOG}"
            sleep 10
        fi
    done

    if [ "$joined" = false ]; then
        echo "❌ Failed to join cluster after $max_retries attempts" | tee -a "${SETUP_LOG}"
        exit 1
    fi
}

# Function to configure worker node
configure_node() {
    echo "🔧 Configuring worker node..." | tee -a "${SETUP_LOG}"
    
    # Setup vagrant user
    sudo -i -u vagrant bash <<'EOF'
    # Create .kube directory
    mkdir -p /home/vagrant/.kube
    sudo cp -i /vagrant/configs/config /home/vagrant/.kube/
    sudo chown 1000:1000 /home/vagrant/.kube/config

    # Get node name
    NODENAME=$(hostname -s)

    # Label node
    kubectl label node "$NODENAME" \
        node-role.kubernetes.io/worker=worker \
        node.kubernetes.io/worker=true \
        kubernetes.io/role=worker

    # Add useful taints and annotations
    kubectl taint nodes "$NODENAME" \
        node-role.kubernetes.io/worker=true:NoSchedule \
        --overwrite

    # Set up bash completion and aliases
    sudo apt-get install -y bash-completion
    echo 'source <(kubectl completion bash)' >> ~/.bashrc
    echo 'alias k=kubectl' >> ~/.bashrc
    echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc
    
    # Add useful aliases
    cat <<'ALIASES' >> ~/.bashrc
# Kubernetes aliases
alias kn='kubectl config set-context --current --namespace'
alias kg='kubectl get'
alias kd='kubectl describe'
alias krm='kubectl delete'
alias kl='kubectl logs'
alias kex='kubectl exec -it'
alias kns='kubectl config view --minify --output "jsonpath={..namespace}"'

# System aliases
alias c=clear
alias ud='sudo apt update -y && sudo apt upgrade -y'

# Add node info to prompt
parse_kubernetes_node() {
    hostname -s
}
PS1='\[\033[01;32m\]\u@$(parse_kubernetes_node)\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
ALIASES

    # Source the new configurations
    source ~/.bashrc
EOF
}

# Function to verify node status
verify_node_status() {
    echo "🔍 Verifying node status..." | tee -a "${SETUP_LOG}"
    
    local timeout=300
    local interval=10
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if kubectl get nodes "$(hostname -s)" | grep -q "Ready"; then
            echo "✅ Node is ready and healthy" | tee -a "${SETUP_LOG}"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo "⏳ Waiting for node to be ready... ($elapsed/$timeout seconds)" | tee -a "${SETUP_LOG}"
    done

    echo "❌ Timeout waiting for node to become ready" | tee -a "${SETUP_LOG}"
    exit 1
}

# Main execution
{
    echo "🚀 Starting worker node setup..."
    verify_prerequisites
    optimize_node
    join_cluster
    configure_node
    verify_node_status
    echo "✅ Worker node setup completed successfully!"
} 2>&1 | tee -a "${SETUP_LOG}"