# -*- mode: ruby -*-
# vi: set ft=ruby :

require "yaml"
require "fileutils"

settings_file = "settings.yaml"
unless File.exist?(settings_file)
  raise "Settings file '#{settings_file}' not found!"
end

begin
  settings = YAML.load_file settings_file
rescue StandardError => e
  raise "Error loading settings: #{e.message}"
end

NUM_WORKER_NODES = settings["nodes"]["workers"]["count"]

Vagrant.configure("2") do |config|
  # Box configuration
  config.vm.box = settings["software"]["box"]
  config.vm.box_check_update = true

  # VMware provider default settings
  config.vm.provider "vmware_desktop" do |vmw|
    # Basic settings
    vmw.gui = false
    vmw.linked_clone = true
    
    # VMware tools settings
    vmw.vmx["tools.upgrade.policy"] = "manual"
    vmw.vmx["tools.syncTime"] = "TRUE"
    
    # Network settings
    vmw.vmx["ethernet0.virtualDev"] = "e1000"
    vmw.vmx["ethernet0.present"] = "TRUE"
    vmw.vmx["ethernet0.connectionType"] = "nat"
    vmw.vmx["ethernet0.addressType"] = "generated"
    vmw.vmx["ethernet0.generatedAddressOffset"] = "0"
    
    # Display settings
    vmw.vmx["svga.vramSize"] = "134217728"
    vmw.vmx["svga.autodetect"] = "TRUE"
    
    # Disk settings
    vmw.vmx["scsi0.present"] = "TRUE"
    vmw.vmx["scsi0.virtualDev"] = "lsilogic"
    
    # Other settings
    vmw.vmx["hgfs.linkRootShare"] = "TRUE"
    vmw.vmx["isolation.tools.hgfs.disable"] = "FALSE"
  end

  # Control Plane Node
  config.vm.define "control-plane", primary: true do |control|
    control.vm.hostname = "master-node"
    
    # Shared folders configuration
    if settings["shared_folders"]
      settings["shared_folders"].each do |shared_folder|
        control.vm.synced_folder shared_folder["host_path"], 
                                shared_folder["vm_path"]
      end
    end

    control.vm.provider "vmware_desktop" do |vb|
      # Resource allocation
      vb.vmx["memsize"] = settings["nodes"]["control"]["memory"]
      vb.vmx["numvcpus"] = settings["nodes"]["control"]["cpu"]
      
      # Basic settings
      vb.vmx["guestOS"] = "ubuntu-64"
      vb.vmx["virtualHW.version"] = "19"
      vb.vmx["mks.enable3d"] = "FALSE"
      
      # Performance settings
      vb.vmx["sched.cpu.latencySensitivity"] = "normal"
      vb.vmx["mainMem.useNamedFile"] = "FALSE"
    end

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
      
      if settings["shared_folders"]
        settings["shared_folders"].each do |shared_folder|
          node.vm.synced_folder shared_folder["host_path"], 
                               shared_folder["vm_path"]
        end
      end

      node.vm.provider "vmware_desktop" do |vb|
        vb.vmx["memsize"] = settings["nodes"]["workers"]["memory"]
        vb.vmx["numvcpus"] = settings["nodes"]["workers"]["cpu"]
        vb.vmx["guestOS"] = "ubuntu-64"
        vb.vmx["virtualHW.version"] = "19"
        vb.vmx["mks.enable3d"] = "FALSE"
        vb.vmx["sched.cpu.latencySensitivity"] = "normal"
        vb.vmx["mainMem.useNamedFile"] = "FALSE"
      end

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
end