#!/bin/bash
#
# Common setup for all servers (Control Plane and Nodes)

set -euxo pipefail

# Check essential environment variables
required_vars=("DNS_SERVERS" "KUBERNETES_VERSION" "CRIO_VERSION")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set"
        exit 1
    fi
done

# Extract Kubernetes major.minor version
if ! VERSION="$(echo "${KUBERNETES_VERSION}" | grep -oE '[0-9]+\.[0-9]+')"; then
    echo "Error: Invalid KUBERNETES_VERSION format"
    exit 1
fi

# DNS Settings
sudo mkdir -p /etc/systemd/resolved.conf.d/
cat <<EOF | sudo tee /etc/systemd/resolved.conf.d/dns_servers.conf
[Resolve]
DNS=${DNS_SERVERS}
EOF

sudo systemctl restart systemd-resolved

# Disable swap
sudo swapoff -a
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true

# Update package list and install dependencies
sudo apt-get update
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg2 \
    software-properties-common \
    jq

# Configure kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/crio.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system

# Install CRI-O
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key" | \
    sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/cri-o.list

# Install Kubernetes
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key" | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update and install packages
sudo apt-get update
sudo apt-get install -y cri-o kubelet kubeadm kubectl

# Configure CRI-O environment
if [ ! -z "${ENVIRONMENT:-}" ]; then
    echo "${ENVIRONMENT}" | sudo tee -a /etc/default/crio
fi

# Enable and start CRI-O
sudo systemctl daemon-reload
sudo systemctl enable crio --now

echo "CRI runtime installed successfully"

# Configure kubelet
if ! local_ip="$(ip --json a s | jq -r '.[] | if .ifname == "eth1" then .addr_info[] | if .family == "inet" then .local else empty end else empty end')"; then
    echo "Error: Could not detect local IP address"
    exit 1
fi

cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF

if [ ! -z "${ENVIRONMENT:-}" ]; then
    echo "${ENVIRONMENT}" | sudo tee -a /etc/default/kubelet
fi