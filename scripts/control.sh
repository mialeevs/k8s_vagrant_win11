#!/usr/bin/env bash

set -euxo pipefail

# Global variables
SETUP_LOG=${SETUP_LOG:-"/var/log/k8s-control-setup.log"}
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

log() {
   local level="$1"
   shift
   echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "${SETUP_LOG}"
}

error_handler() {
   local exit_code=$1
   local line_number=$2
   log "ERROR" "Error on line ${line_number}: Command exited with status ${exit_code}"
   cleanup_on_failure
   exit "${exit_code}"
}
trap 'error_handler $? $LINENO' ERR

cleanup_on_failure() {
   log "INFO" "Performing cleanup after failure..."
   kubeadm reset -f || true
   rm -rf /etc/cni/net.d/*
   iptables -F && iptables -t nat -F
}

wait_for_apiserver() {
   log "INFO" "Waiting for API server to be ready..."
   local timeout=180
   local interval=5
   local elapsed=0

   while [ $elapsed -lt $timeout ]; do
       if kubectl get nodes &>/dev/null; then
           log "INFO" "API server is ready"
           return 0
       fi
       log "INFO" "Waiting for API server... ($elapsed/$timeout seconds)"
       sleep $interval
       elapsed=$((elapsed + interval))
   done

   log "ERROR" "Timeout waiting for API server"
   return 1
}

wait_for_pods() {
   local namespace=$1
   local label=$2
   local timeout=300
   local interval=10
   local elapsed=0

   log "INFO" "Waiting for pods with label $label in namespace $namespace..."

   while [ $elapsed -lt $timeout ]; do
       if kubectl get pods -n "$namespace" -l "$label" 2>/dev/null | grep -q "Running"; then
           local ready_pods=$(kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | grep -o "true" | wc -l)
           local total_pods=$(kubectl get pods -n "$namespace" -l "$label" --no-headers | wc -l)

           if [ "$ready_pods" -eq "$total_pods" ] && [ "$total_pods" -gt 0 ]; then
               log "INFO" "All pods are ready ($ready_pods/$total_pods)"
               return 0
           fi
       fi

       log "INFO" "Waiting for pods to be ready... ($elapsed/$timeout seconds)"
       sleep $interval
       elapsed=$((elapsed + interval))
   done

   log "ERROR" "Timeout waiting for pods"
   kubectl get pods -n "$namespace" -l "$label" -o wide
   return 1
}

initialize_control_plane() {
   log "INFO" "Initializing control plane..."

   cat <<EOF > "$TEMP_DIR/kubeadm-config.yaml"
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${CONTROL_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: "unix:///var/run/crio/crio.sock"
  imagePullPolicy: IfNotPresent
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  serviceSubnet: "${SERVICE_CIDR}"
  podSubnet: "${POD_CIDR}"
  dnsDomain: "cluster.local"
apiServer:
  extraArgs:
    - name: "authorization-mode"
      value: "Node,RBAC"
    - name: "enable-admission-plugins"
      value: "NodeRestriction"
controllerManager:
  extraArgs:
    - name: "bind-address"
      value: "0.0.0.0"
scheduler:
  extraArgs:
    - name: "bind-address"
      value: "0.0.0.0"
EOF

   kubeadm config images pull --config "$TEMP_DIR/kubeadm-config.yaml"
   kubeadm init --config "$TEMP_DIR/kubeadm-config.yaml" --upload-certs

   mkdir -p /home/vagrant/.kube
   cp -i /etc/kubernetes/admin.conf /home/vagrant/.kube/config
   chown -R vagrant:vagrant /home/vagrant/.kube

   export KUBECONFIG=/etc/kubernetes/admin.conf

   wait_for_apiserver

   sleep 5
   sudo apt-get install bash-completion -y
   echo "source <(kubectl completion bash)" >> ~/.bashrc
   echo "complete -F __start_kubectl k" >> ~/.bashrc
   echo "alias k=kubectl" >> ~/.bashrc
   echo "alias c=clear" >> ~/.bashrc
   echo "alias ud='sudo apt update -y && sudo apt upgrade -y'" >> ~/.bashrc



install_calico() {
    # Configure Calico IP autodetection
    cat <<EOF > "/vagrant/calico-config.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: calico-config
  namespace: kube-system
data:
  calico_backend: "bird"
  veth_mtu: "1440"
  ip_autodetection_method: "interface=eth1"
EOF

   kubectl apply -f "/vagrant/calico-config.yaml"

   echo "INFO: Downloading Calico manifest..."
   curl -L https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml \
      -o "/vagrant/calico.yaml"

   sed -i "s#192.168.0.0/16#${POD_CIDR}#g" "/vagrant/calico.yaml"
   sed -i '/name: CALICO_IPV4POOL_CIDR/a\            - name: IP_AUTODETECTION_METHOD\n              value: "interface=eth1"' "/vagrant/calico.yaml"

   echo "INFO: Applying Calico manifest..."
   kubectl apply -f "/vagrant/calico.yaml"

   echo "INFO: Waiting for CoreDNS to be ready..."
   wait_for_pods "kube-system" "k8s-app=kube-dns"

   echo "INFO: Waiting for Calico to be ready..."
   wait_for_pods "kube-system" "k8s-app=calico-node"

   echo "INFO: Verifying cluster status..."
   kubectl get nodes -o wide
   kubectl get pods --all-namespaces

   kubeadm token create --print-join-command > /vagrant/configs/join.sh
   chmod +x /vagrant/configs/join.sh
}

install_tools(){
  sudo apt-get install unzip -y
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  sudo ./aws/install --update
  rm -rf awscliv2.zip
  rm -rf aws
  sleep 5
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 get_helm.sh
  ./get_helm.sh
  rm get_helm.sh
  wget https://github.com/argoproj/argo-cd/releases/download/v2.13.2/argocd-linux-amd64
  sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
  rm argocd-linux-amd64
}

install_argocd(){
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
  kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort"}}'
  kubectl patch svc argocd-server -n argocd --type='json' -p='[{"op": "replace", "path": "/spec/ports/0/nodePort", "value": 30903}]'
  kubectl patch svc argocd-server -n argocd --type='json' -p='[{"op": "replace", "path": "/spec/ports/1/nodePort", "value": 30904}]'
}

}
main() {
   log "INFO" "Starting control plane setup..."
   initialize_control_plane
   install_calico
   install_tools
   install_argocd
   log "INFO" "Control plane setup completed successfully"
}

main "$@"