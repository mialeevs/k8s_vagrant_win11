# -*- mode: ruby -*-
# vi: set ft=ruby :

require 'yaml'

settings = YAML.load_file('settings.yaml')

Vagrant.configure('2') do |config|
  config.vm.box = settings['software']['box']
  config.vm.box_check_update = false
  config.vm.synced_folder '.', '/vagrant', disabled: true
  config.vm.synced_folder './configs', '/vagrant/configs', create: true

  # VirtualBox provider settings
  config.vm.provider 'virtualbox' do |vb|
    vb.gui = false
    vb.linked_clone = true
    vb.customize ['modifyvm', :id, '--audio', 'none']
    vb.customize ['modifyvm', :id, '--usb', 'off']
    vb.customize ['modifyvm', :id, '--vrde', 'off']
  end

  # Control plane
  config.vm.define 'control-plane', primary: true do |control|
    control.vm.hostname = 'control-node'
    control.vm.network 'private_network', ip: settings['network']['control_ip'], 
                       virtualbox__intnet: 'k8s-cluster'
    
    control.vm.provider 'virtualbox' do |vb|
      vb.memory = settings['nodes']['control']['memory']
      vb.cpus = settings['nodes']['control']['cpu']
    end

    control.vm.provision 'shell', path: 'scripts/common.sh', env: {
      'DNS_SERVERS' => settings['network']['dns_servers'],
      'KUBERNETES_VERSION' => settings['software']['kubernetes'],
      'CRIO_VERSION' => settings['software']['crio'],
      'OS' => settings['software']['os']
    }

    control.vm.provision 'shell', path: 'scripts/control.sh', env: {
      'CALICO_VERSION' => settings['software']['calico'],
      'POD_CIDR' => settings['network']['pod_cidr'],
      'SERVICE_CIDR' => settings['network']['service_cidr'],
      'CONTROL_IP' => settings['network']['control_ip']
    }
  end

  # Worker nodes
  (1..settings['nodes']['workers']['count']).each do |i|
    config.vm.define "worker#{i}" do |worker|
      worker.vm.hostname = "worker-node#{i}"
      worker.vm.network 'private_network', ip: "#{settings['network']['worker_ip_prefix']}.#{i + 10}",
                        virtualbox__intnet: 'k8s-cluster'
      
      worker.vm.provider 'virtualbox' do |vb|
        vb.memory = settings['nodes']['workers']['memory']
        vb.cpus = settings['nodes']['workers']['cpu']
      end

      worker.vm.provision 'shell', path: 'scripts/common.sh', env: {
        'DNS_SERVERS' => settings['network']['dns_servers'],
        'KUBERNETES_VERSION' => settings['software']['kubernetes'],
        'CRIO_VERSION' => settings['software']['crio'],
        'OS' => settings['software']['os']
      }

      worker.vm.provision 'shell', path: 'scripts/node.sh'
    end
  end
end
