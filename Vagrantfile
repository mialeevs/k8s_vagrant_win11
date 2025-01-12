# -*- mode: ruby -*-
# vi: set ft=ruby :

require "yaml"
require "fileutils"

# Validate settings file exists
settings_file = "settings.yaml"
unless File.exist?(settings_file)
  raise "Settings file '#{settings_file}' not found!"
end

# Load and validate settings
begin
  settings = YAML.load_file settings_file
rescue StandardError => e
  raise "Error loading settings: #{e.message}"
end

NUM_WORKER_NODES = settings["nodes"]["workers"]["count"]

Vagrant.configure("2") do |config|
  # Box configuration
  if `uname -m`.strip == "aarch64"
    config.vm.box = settings["software"]["box"] + "-arm64"
  else
    config.vm.box = settings["software"]["box"]
  end
  
  config.vm.box_version = "202407.23.0"
  config.vm.box_check_update = true

  # VirtualBox global settings
  config.vm.provider "virtualbox" do |vb|
    # Enable hardware virtualization
    vb.customize ["modifyvm", :id, "--hwvirtex", "on"]
    vb.customize ["modifyvm", :id, "--vtxux", "on"]
    
    # I/O APIC for better interrupt handling
    vb.customize ["modifyvm", :id, "--ioapic", "on"]
    
    # Use host's CPU processor features
    vb.customize ["modifyvm", :id, "--cpu-profile", "host"]
    
    # Disable audio
    vb.customize ["modifyvm", :id, "--audio", "none"]
    
    # Clipboard and drag'n'drop
    vb.customize ["modifyvm", :id, "--clipboard", "disabled"]
    vb.customize ["modifyvm", :id, "--draganddrop", "disabled"]
    
    # Memory balloon driver
    vb.customize ["modifyvm", :id, "--balloon", "0"]
    
    # Network performance
    vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
    
    # Storage performance
    vb.customize ["storagectl", :id, "--name", "SATA Controller", "--hostiocache", "on"]
  end

  # Control Plane Node
  config.vm.define "control-plane", primary: true do |control|
    control.vm.hostname = "master-node"
    
    # Shared folders with performance options
    if settings["shared_folders"]
      settings["shared_folders"].each do |shared_folder|
        control.vm.synced_folder shared_folder["host_path"], 
                                shared_folder["vm_path"],
                                type: "virtualbox",
                                mount_options: ["dmode=755,fmode=644"]
      end
    end

    # VirtualBox specific settings
    control.vm.provider "virtualbox" do |vb|
      # Resource allocation
      vb.memory = settings["nodes"]["control"]["memory"]
      vb.cpus = settings["nodes"]["control"]["cpu"]
      
      # CPU settings
      vb.customize ["modifyvm", :id, "--cpu-execution-cap", "100"]
      vb.customize ["modifyvm", :id, "--paravirtprovider", "kvm"]
      
      # Nested virtualization support
      vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
      
      # I/O Settings
      vb.customize ["modifyvm", :id, "--largepages", "on"]
      vb.customize ["modifyvm", :id, "--pagefusion", "off"]
      
      # Graphics memory
      vb.customize ["modifyvm", :id, "--vram", "16"]
      
      # Network settings
      vb.customize ["modifyvm", :id, "--nicpromisc1", "allow-all"]
      vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
      
      # Storage settings
      vb.customize ["storageattach", :id, 
                    "--storagectl", "SATA Controller",
                    "--port", "0",
                    "--nonrotational", "on",
                    "--discard", "on"]
    end

    # Provisioning
    control.vm.provision "shell",
      env: {
        "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
        "ENVIRONMENT" => settings["environment"],
        "CRIO_VERSION" => settings["software"]["crio"],
        "KUBERNETES_VERSION" => settings["software"]["kubernetes"],
        "OS" => settings["software"]["os"]
      },
      path: "scripts/common.sh"

    control.vm.provision "shell",
      env: {
        "CALICO_VERSION" => settings["software"]["calico"],
        "CRIO_VERSION" => settings["software"]["crio"],
        "CONTROL_IP" => settings["network"]["control_ip"],
        "POD_CIDR" => settings["network"]["pod_cidr"],
        "SERVICE_CIDR" => settings["network"]["service_cidr"]
      },
      path: "scripts/control.sh"
  end

  # Worker Nodes
  (1..NUM_WORKER_NODES).each do |i|
    config.vm.define "node0#{i}" do |node|
      node.vm.hostname = "worker-node0#{i}"
      
      # Shared folders
      if settings["shared_folders"]
        settings["shared_folders"].each do |shared_folder|
          node.vm.synced_folder shared_folder["host_path"], 
                               shared_folder["vm_path"],
                               type: "virtualbox",
                               mount_options: ["dmode=755,fmode=644"]
        end
      end

      # VirtualBox specific settings
      node.vm.provider "virtualbox" do |vb|
        # Resource allocation
        vb.memory = settings["nodes"]["workers"]["memory"]
        vb.cpus = settings["nodes"]["workers"]["cpu"]
        
        # CPU settings
        vb.customize ["modifyvm", :id, "--cpu-execution-cap", "100"]
        vb.customize ["modifyvm", :id, "--paravirtprovider", "kvm"]
        
        # Nested virtualization
        vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
        
        # I/O Settings
        vb.customize ["modifyvm", :id, "--largepages", "on"]
        vb.customize ["modifyvm", :id, "--pagefusion", "off"]
        
        # Network settings
        vb.customize ["modifyvm", :id, "--nicpromisc1", "allow-all"]
        vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
        vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
        
        # Storage settings
        vb.customize ["storageattach", :id, 
                    "--storagectl", "SATA Controller",
                    "--port", "0",
                    "--nonrotational", "on",
                    "--discard", "on"]
      end

      # Provisioning
      node.vm.provision "shell",
        env: {
          "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
          "ENVIRONMENT" => settings["environment"],
          "KUBERNETES_VERSION" => settings["software"]["kubernetes"],
          "CRIO_VERSION" => settings["software"]["crio"],
          "OS" => settings["software"]["os"]
        },
        path: "scripts/common.sh"

      node.vm.provision "shell", 
        path: "scripts/node.sh"
    end
  end

  # Post-setup checks
  config.trigger.after [:up, :reload] do |trigger|
    trigger.info = "Checking cluster health..."
    trigger.run = {inline: "vagrant ssh control-plane -c 'kubectl get nodes'"}
  end
end