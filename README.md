# Kubernetes Installation on Ubuntu 24.04 with Vagrant

## For Linux OS / Windows 10/11 OS

### Prerequisites

Install VirtualBox, Vagrant and Git on your system:

- [VirtualBox](https://www.virtualbox.org/wiki/Downloads)
- [Vagrant](https://www.vagrantup.com/)
- [Git](https://git-scm.com/)

### Setup

1. Clone the repository:
```bash
git clone https://github.com/mialeevs/kube_vagrant.git
cd kube_vagrant
```

2. Configure your cluster by editing `settings.yaml`:
   - Adjust worker node count
   - Modify CPU/memory allocation
   - Update network settings if needed

3. Start the cluster:
```bash
vagrant up
```

4. Access the control plane:
```bash
vagrant ssh control-plane
kubectl get nodes
```
