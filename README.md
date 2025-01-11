# Kubernetes Installation on Ubuntu 24.04


## For Linux / Windows 10/11 OS

### Install VMware Workstation(VMware dekstop plugin) or VirtualBox, Vagrant and Git

> [VMWare Workstation](https://www.vmware.com/products/workstation-pro.html)

> [VMWare Desktop Plugin](https://developer.hashicorp.com/vagrant/docs/providers/vmware/vagrant-vmware-utility)

OR

> [Virtualbox](https://www.virtualbox.org/)

> [Vagrant](https://www.vagrantup.com/)

> [GIT](https://git-scm.com/)

Install the required plugins for vmwaredesktop

```bash
vagrant plugin install vagrant-vmware-desktop
vagrant plugin install vagrant-hostmanager
```

Install the required plugins for virtualbox

```bash
vagrant plugin install vagrant-hostmanager

```

### Clone the repository

Clone the repo to the desired location

```bash
git clone https://github.com/mialeevs/kube_vagrant.git
cd kube_vagrant
git fetch -a

# For VMWare
git switch Vmware_desktop
# Update the settings.yaml file for desired worker node count and run below command.
# Update the same file for memory and cpu allocation for the cp and worker nodes as needed.
vagrant up

# For Virtualbox
git switch VirtualBox
# Update the settings.yaml file for desired worker node count and run below command.
# Update the same file for memory and cpu allocation for the cp and worker nodes as needed.
vagrant up
```
