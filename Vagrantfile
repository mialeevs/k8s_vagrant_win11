# -*- mode: ruby -*-
# vi: set ft=ruby :

require 'yaml'
require 'fileutils'
require 'open3'

# Custom error class for Vagrant configuration
class VagrantConfigError < StandardError; end

# Load and validate settings
def load_settings
  settings_file = 'settings.yaml'
  raise VagrantConfigError, "Settings file '#{settings_file}' not found!" unless File.exist?(settings_file)

  begin
    YAML.load_file(settings_file)
  rescue StandardError => e
    raise VagrantConfigError, "Error loading settings: #{e.message}"
  end
end

# Main Vagrant configuration
Vagrant.configure('2') do |config|
  # Load configuration
  settings = load_settings

  # Ensure the hostmanager plugin is present if needed
  if Vagrant.has_plugin?("vagrant-hostmanager")
    config.hostmanager.enabled = settings.dig('hostmanager', 'enabled')
    config.hostmanager.manage_host = settings.dig('hostmanager', 'manage_host')
    config.hostmanager.manage_guest = settings.dig('hostmanager', 'manage_guest')
  end

  # Global VM provider settings
  config.vm.provider 'virtualbox' do |vb|
    # vb.memory = settings['nodes']['default']['memory']
    # vb.cpus = settings['nodes']['default']['cpu']

    # Security settings
    vb.customize ['modifyvm', :id, '--clipboard-mode', 'disabled']
    vb.customize ['modifyvm', :id, '--drag-and-drop', 'disabled']
    vb.customize ['modifyvm', :id, '--audio', 'none']
    vb.customize ['modifyvm', :id, '--usb', 'off']
    vb.customize ['modifyvm', :id, '--vrde', 'off']

    # CPU and Memory optimizations
    vb.customize ['modifyvm', :id, '--hwvirtex', 'on']
    vb.customize ['modifyvm', :id, '--vtxvpid', 'on']
    vb.customize ['modifyvm', :id, '--vtxux', 'on']
    vb.customize ['modifyvm', :id, '--paravirtprovider', 'kvm']
    vb.customize ['modifyvm', :id, '--largepages', 'on']
    vb.customize ['modifyvm', :id, '--nestedpaging', 'on']
    vb.customize ['modifyvm', :id, '--pagefusion', 'off']

    # I/O optimizations
    vb.customize ['storagectl', :id, '--name', 'SATA Controller', '--hostiocache', 'on']
  end

  # Box configuration with architecture detection (for cross-platform compatibility)
  config.vm.box = if `uname -m`.strip == 'aarch64'
    "#{settings['software']['box']}-arm64"
  else
    settings['software']['box']
  end

  config.vm.box_check_update = true

  # Disable default shared folder
  config.vm.synced_folder '.', '/vagrant', disabled: true

  # Secure shared folder configuration
  config.vm.synced_folder './configs', '/vagrant/configs',
    owner: 'vagrant',
    group: 'vagrant',
    mount_options: ['dmode=750,fmode=640'],
    create: true

  # Control plane node configuration
  config.vm.define 'control-plane', primary: true do |control|
    control.vm.hostname = 'control-node'

    # Network configuration
    control.vm.network 'public_network',
      ip: settings['network']['control_ip'],
      netmask: settings['network']['netmask'],
      nic_type: 'virtio'

    control.vm.network 'private_network',
      ip: "#{settings['network']['private_ip_prefix']}.10",
      virtualbox__intnet: 'cluster_internal',
      nic_type: 'virtio'

    # VirtualBox provider settings
    control.vm.provider 'virtualbox' do |vb|
      vb.memory = settings['nodes']['control']['memory']
      vb.cpus = settings['nodes']['control']['cpu']

      # Storage configuration
      disk_path = 'control_plane_disk.vdi'
      unless File.exist?(disk_path)
        vb.customize ['createhd', '--filename', disk_path, '--size', settings['nodes']['control']['disk_size'], '--variant', 'Fixed']
        vb.customize ['storageattach', :id, '--storagectl', 'SATA Controller', '--port', 1, '--device', 0, '--type', 'hdd', '--medium', disk_path]
      end
    end

    # Provisioning
    control.vm.provision 'shell',
      env: {
        'DNS_SERVERS' => settings['network']['dns_servers'].join(','),
        'ENVIRONMENT' => settings['environment'],
        'KUBERNETES_VERSION' => settings['software']['kubernetes'],
        'CRIO_VERSION' => settings['software']['crio'],
        'OS' => settings['software']['os'],
        'SETUP_LOG' => '/var/log/k8s-setup.log'
      },
      path: 'scripts/common.sh'

    control.vm.provision 'shell',
      env: {
        'CALICO_VERSION' => settings['software']['calico'],
        'POD_CIDR' => settings['network']['pod_cidr'],
        'SERVICE_CIDR' => settings['network']['service_cidr'],
        'CONTROL_IP' => settings['network']['control_ip']
      },
      path: 'scripts/control.sh'
  end

  # Worker nodes configuration
  (1..settings['nodes']['workers']['count']).each do |i|
    config.vm.define "worker#{i}" do |worker|
      worker.vm.hostname = "worker-node#{i}"

      # Network configuration
      worker.vm.network 'public_network',
        ip: "#{settings['network']['worker_ip_prefix']}.#{i + 10}",
        netmask: settings['network']['netmask'],
        nic_type: 'virtio'

      worker.vm.network 'private_network',
        ip: "#{settings['network']['private_ip_prefix']}.#{i + 20}",
        virtualbox__intnet: 'cluster_internal',
        nic_type: 'virtio'

      worker.vm.provider 'virtualbox' do |vb|
        vb.memory = settings['nodes']['workers']['memory']
        vb.cpus = settings['nodes']['workers']['cpu']

        # Storage configuration
        disk_path = "worker#{i}_disk.vdi"
        unless File.exist?(disk_path)
          vb.customize ['createhd', '--filename', disk_path, '--size', settings['nodes']['workers']['disk_size'], '--variant', 'Fixed']
          vb.customize ['storageattach', :id, '--storagectl', 'SATA Controller', '--port', 1, '--device', 0, '--type', 'hdd', '--medium', disk_path]
        end
      end

      # Provisioning
      worker.vm.provision 'shell',
        env: {
          'DNS_SERVERS' => settings['network']['dns_servers'].join(','),
          'ENVIRONMENT' => settings['environment'],
          'KUBERNETES_VERSION' => settings['software']['kubernetes'],
          'CRIO_VERSION' => settings['software']['crio'],
          'OS' => settings['software']['os'],
          'SETUP_LOG' => '/var/log/k8s-setup.log'
        },
        path: 'scripts/common.sh'

      worker.vm.provision 'shell', path: 'scripts/node.sh'
    end
  end

  # Post-setup health check
  config.trigger.after [:up, :reload] do |trigger|
    trigger.name = "Verifying cluster health"
    trigger.ruby do |env, machine|
      system(<<-SHELL
        echo "Checking cluster status..."
        vagrant ssh control-plane -c "kubectl get nodes -o wide"
        vagrant ssh control-plane -c "kubectl get pods -A"
        vagrant ssh control-plane -c "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
      SHELL
      )
    end
  end
end
