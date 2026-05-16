#!/bin/bash
#
# Setup for Control Plane (Master) servers

set -euxo pipefail

TEMP_DIR="/tmp"

export CALICO_VERSION
export CRIO_VERSION
export CONTROL_IP
export POD_CIDR
export SERVICE_CIDR

NODENAME=$(hostname -s)

# Network connectivity check
echo "Testing network connectivity..."
ping -c 3 8.8.8.8 || echo "Warning: Cannot reach 8.8.8.8"
nslookup registry.k8s.io || echo "Warning: DNS resolution failed for registry.k8s.io"

# Configure alternative registry if needed
# Try primary registry first
echo "Trying primary registry..."
if sudo kubeadm config images pull --image-repository=registry.k8s.io; then
  echo "Primary registry worked!"
else
  echo "Primary registry failed, trying alternative approach..."
  
  # Get the list of required images
  echo "Getting list of required images..."
  sudo kubeadm config images list
  
  # Try pulling images individually with fallback
  echo "Pulling images individually..."
  
  # Most images work from k8s.gcr.io
  sudo crio pull k8s.gcr.io/kube-apiserver:v1.34.5 || echo "Failed to pull kube-apiserver"
  sudo crio pull k8s.gcr.io/kube-controller-manager:v1.34.5 || echo "Failed to pull kube-controller-manager"
  sudo crio pull k8s.gcr.io/kube-scheduler:v1.34.5 || echo "Failed to pull kube-scheduler"
  sudo crio pull k8s.gcr.io/kube-proxy:v1.34.5 || echo "Failed to pull kube-proxy"
  sudo crio pull k8s.gcr.io/pause:3.10 || echo "Failed to pull pause"
  sudo crio pull k8s.gcr.io/etcd:3.5.15-0 || echo "Failed to pull etcd"
  
  # CoreDNS needs special handling
  sudo crio pull registry.k8s.io/coredns/coredns:v1.12.1 || sudo crio pull coredns/coredns:1.12.1 || echo "Failed to pull coredns"
  
  echo "Individual image pulls completed"
fi

echo "Preflight Check Passed: Downloaded All Required Images"

sudo kubeadm init --apiserver-advertise-address=$CONTROL_IP --apiserver-cert-extra-sans=$CONTROL_IP --pod-network-cidr=$POD_CIDR --service-cidr=$SERVICE_CIDR --node-name "$NODENAME" --ignore-preflight-errors Swap

mkdir -p "$HOME"/.kube
sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

# Save Configs to shared /Vagrant location

# For Vagrant re-runs, check if there is existing configs in the location and delete it for saving new configuration.

config_path="/vagrant/configs"

if [ -d $config_path ]; then
  rm -f $config_path/*
else
  mkdir -p $config_path
fi

cp -i /etc/kubernetes/admin.conf $config_path/config
touch $config_path/join.sh
chmod +x $config_path/join.sh

kubeadm token create --print-join-command > $config_path/join.sh

# Install Calico Network Plugin

curl https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml -O

kubectl apply -f calico.yaml

# Install helm (required for cilium)
sudo apt-get install curl gpg apt-transport-https --yes
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update -y
sudo apt-get install helm -y

# ArgoCD CLI
wget -q https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 -O "${TEMP_DIR}/argocd"
sudo install -m 755 "${TEMP_DIR}/argocd" /usr/local/bin/argocd
rm "${TEMP_DIR}/argocd"

sudo -i -u vagrant bash << EOF
whoami
mkdir -p /home/vagrant/.kube
sudo cp -i $config_path/config /home/vagrant/.kube/
sudo chown 1000:1000 /home/vagrant/.kube/config
EOF

# Install Metrics Server
git clone https://github.com/mialeevs/kubernetes_installation_crio.git
cd kubernetes_installation_crio/
kubectl apply -f metrics-server.yaml
cd
rm -rf kubernetes_installation_crio/

kubectl create namespace argocd || true

# Download ArgoCD manifest
kubectl create namespace argocd || true
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort"}}'
kubectl patch svc argocd-server -n argocd --type='json' \
    -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30903},{"op":"replace","path":"/spec/ports/1/nodePort","value":30904}]'

