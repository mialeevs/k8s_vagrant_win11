#!/bin/bash
#
# Setup for Control Plane (Master) servers

set -euxo pipefail

# Check system status before proceeding
echo "Checking system status..."
sudo swapoff -a
sudo systemctl stop ufw || true
sudo systemctl disable ufw || true

# Verify CRI-O is running
echo "Verifying CRI-O status..."
sudo systemctl status crio
sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock ps

# Reset any previous kubeadm configuration
echo "Resetting previous kubeadm configuration..."
sudo kubeadm reset -f || true
sudo rm -rf /etc/cni/net.d/*
sudo rm -rf $HOME/.kube/config

# Verify kubelet status
echo "Checking kubelet status..."
sudo systemctl daemon-reload
sudo systemctl restart kubelet
sudo systemctl status kubelet

# Get the correct IP address
CONTROL_IP=$(ip -f inet addr show eth1 | grep -Po 'inet \K[\d.]+')
echo "Control IP: $CONTROL_IP"

# Pull images before init
echo "Pulling required images..."
sudo kubeadm config images pull

# Initialize with more verbose logging
echo "Initializing Kubernetes control plane..."
sudo kubeadm init \
    --apiserver-advertise-address="$CONTROL_IP" \
    --apiserver-cert-extra-sans="$CONTROL_IP" \
    --pod-network-cidr="$POD_CIDR" \
    --service-cidr="$SERVICE_CIDR" \
    --node-name "$(hostname -s)" \
    --ignore-preflight-errors=Swap \
    --v=5

# Wait for kubelet to start
echo "Waiting for kubelet to start..."
sleep 30
sudo systemctl status kubelet

# Rest of your original script...
mkdir -p "$HOME"/.kube
sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

# Save configs
config_path="/vagrant/configs"
if [ -d "$config_path" ]; then
    rm -f "$config_path"/*
else
    mkdir -p "$config_path"
fi

cp -i /etc/kubernetes/admin.conf "$config_path/config"
touch "$config_path/join.sh"
chmod +x "$config_path/join.sh"

# Generate join command
kubeadm token create --print-join-command > "$config_path/join.sh"

# Install Calico Network Plugin
curl -sSLo calico.yaml "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"
kubectl apply -f calico.yaml

# Wait for the system to stabilize
echo "Waiting for system to stabilize..."
sleep 60

# Verify cluster status
echo "Checking cluster status..."
kubectl get nodes
kubectl get pods -A

sleep 5
git clone https://github.com/mialeevs/kubernetes_installation_crio.git
cd kubernetes_installation_crio/
kubectl apply -f metrics-server.yaml
cd ..
rm -rf kubernetes_installation_crio
sleep 5

# Setup vagrant user
sudo -i -u vagrant bash << 'EOF'
mkdir -p /home/vagrant/.kube
sudo cp -i /vagrant/configs/config /home/vagrant/.kube/
sudo chown 1000:1000 /home/vagrant/.kube/config
sleep 5
sudo apt-get install bash-completion -y
echo "source <(kubectl completion bash)" >> ~/.bashrc
echo "complete -F __start_kubectl k" >> ~/.bashrc
echo "alias k=kubectl" >> ~/.bashrc
echo "alias c=clear" >> ~/.bashrc
echo "alias ud='sudo apt update -y && sudo apt upgrade -y' >> ~/.bashrc"
source ~/.profile
EOF