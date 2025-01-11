
require "yaml"
settings = YAML.load_file "settings.yaml"

NUM_WORKER_NODES = settings["nodes"]["workers"]["count"]

Vagrant.configure("2") do |config|

  if `uname -m`.strip == "aarch64"
    config.vm.box = settings["software"]["box"] + "-arm64"
  else
    config.vm.box = settings["software"]["box"]
  end
  config.vm.box_check_update = true
  

  config.vm.define "control-plane" do |control|
    control.vm.hostname = "master-node"
    control.vm.network "public_network"
    if settings["shared_folders"]
      settings["shared_folders"].each do |shared_folder|
        control.vm.synced_folder shared_folder["host_path"], shared_folder["vm_path"]
      end
    end
    control.vm.provider "virtualbox" do |vb|
      vb.memory = settings["nodes"]["control"]["memory"]
      vb.cpus = settings["nodes"]["control"]["cpu"]
    end
    control.vm.provision "shell",
      env: {
        "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
        "KUBERNETES_VERSION" => settings["software"]["kubernetes"],
        "CRIO_VERSION" => settings["software"]["crio"],
        "OS" => settings["software"]["os"]
      },
      path: "scripts/common.sh"
    control.vm.provision "shell",
      env: {
        "CALICO_VERSION" => settings["software"]["calico"],
        "CONTROL_IP" => settings["network"]["control_ip"],
        "POD_CIDR" => settings["network"]["pod_cidr"],
        "SERVICE_CIDR" => settings["network"]["service_cidr"]
      },
      path: "scripts/control.sh"
  end

  (1..NUM_WORKER_NODES).each do |i|
    config.vm.define "node0#{i}" do |node|
      node.vm.hostname = "worker-node0#{i}"
      node.vm.network "public_network"
  
      if settings["shared_folders"]
        settings["shared_folders"].each do |shared_folder|
          node.vm.synced_folder shared_folder["host_path"], shared_folder["vm_path"]
        end
      end
  
      node.vm.provider "virtualbox" do |vb|
        vb.memory = settings["nodes"]["workers"]["memory"]
        vb.cpus = settings["nodes"]["workers"]["cpu"]
      end
  
      # Common script with all required environment variables
      node.vm.provision "shell",
        env: {
          "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
          "KUBERNETES_VERSION" => settings["software"]["kubernetes"],
          "CRIO_VERSION" => settings["software"]["crio"],
          "OS" => settings["software"]["os"]
        },
        path: "scripts/common.sh"
  
      # Node script with required environment variables
      node.vm.provision "shell", 
        env: {
          "CONTROL_IP" => settings["network"]["control_ip"],
          "POD_CIDR" => settings["network"]["pod_cidr"],
          "SERVICE_CIDR" => settings["network"]["service_cidr"]
        },
        path: "scripts/node.sh"
    end
  end 
end