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

  if Vagrant.has_plugin?("vagrant-hostmanager")
    config.hostmanager.enabled = true
    config.hostmanager.manage_host = true
    config.hostmanager.manage_guest = true
  end

  # Box configuration
  config.vm.box = settings["software"]["box"]
  config.vm.box_check_update = true

  # VMware provider default settings
  config.vm.provider "vmware_desktop" do |vmw|
    vmw.gui = false
    vmw.linked_clone = true
    vmw.vmx["ethernet0.connectionType"] = "nat"
    # Ensure internet connectivity
    vmw.vmx["ethernet0.present"] = "TRUE"
    vmw.vmx["ethernet0.startConnected"] = "TRUE"
  end

  # Control Plane Node
  config.vm.define "control-plane", primary: true do |control|
    control.vm.hostname = "control-node"
    control.vm.network "private_network", ip: settings["nodes"]["control"]["ip"]

    # Shared folders configuration
    if settings["shared_folders"]
      settings["shared_folders"].each do |shared_folder|
        control.vm.synced_folder shared_folder["host_path"], shared_folder["vm_path"]
      end
    end

    control.vm.provider "vmware_desktop" do |vb|
      vb.vmx["memsize"] = settings["nodes"]["control"]["memory"]
      vb.vmx["numvcpus"] = settings["nodes"]["control"]["cpu"]
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
        "CONTROL_IP" => settings["nodes"]["control"]["ip"],
        "POD_CIDR" => settings["network"]["pod_cidr"],
        "SERVICE_CIDR" => settings["network"]["service_cidr"]
      },
      path: "scripts/control.sh"
  end

  # Worker Nodes
  (1..NUM_WORKER_NODES).each do |i|
    config.vm.define "node0#{i}" do |node|
      node.vm.hostname = "data-node0#{i}"
      # Assign static private IP to each worker node
      worker_ip = settings["nodes"]["workers"]["ip_start"].split('.')[0..2].join('.') + ".#{settings["nodes"]["workers"]["ip_start"].split('.')[3].to_i + i - 1}"
      node.vm.network "private_network", ip: worker_ip

      if settings["shared_folders"]
        settings["shared_folders"].each do |shared_folder|
          node.vm.synced_folder shared_folder["host_path"], shared_folder["vm_path"]
        end
      end

      node.vm.provider "vmware_desktop" do |vb|
        vb.vmx["memsize"] = settings["nodes"]["workers"]["memory"]
        vb.vmx["numvcpus"] = settings["nodes"]["workers"]["cpu"]
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

      node.vm.provision "shell", path: "scripts/node.sh"
    end
  end
end
