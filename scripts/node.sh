#!/bin/bash
#
# Worker node setup script

set -euxo pipefail

config_path="/vagrant/configs"

# Check if join script exists
if [ ! -f "$config_path/join.sh" ]; then
    echo "Error: Join script not found at $config_path/join.sh"
    exit 1
fi

# Check if join script is executable
if [ ! -x "$config_path/join.sh" ]; then
    chmod +x "$config_path/join.sh"
fi

# Execute join command with verbose output
/bin/bash "$config_path/join.sh" -v

# Setup vagrant user kubeconfig and label node
sudo -i -u vagrant bash << 'EOF'
mkdir -p /home/vagrant/.kube
sudo cp -i /vagrant/configs/config /home/vagrant/.kube/
sudo chown 1000:1000 /home/vagrant/.kube/config

NODENAME=$(hostname -s)
kubectl label node "$NODENAME" node-role.kubernetes.io/worker=worker
EOF