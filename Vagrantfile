# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"

  config.vm.provider "virtualbox" do |vb|
    vb.name = "pgAutoFailoverVM-Vagrant"
    vb.memory = "4096"
    vb.cpus = "2"
  end

  config.vm.network "private_network", ip: "192.168.56.150"

  # Forward ports
  config.vm.network "forwarded_port", guest: 5430, host: 5430, auto_correct: true # Monitor port from script
  config.vm.network "forwarded_port", guest: 5001, host: 5001, auto_correct: true # pgnode1
  config.vm.network "forwarded_port", guest: 5002, host: 5002, auto_correct: true # pgnode2
  config.vm.network "forwarded_port", guest: 5003, host: 5003, auto_correct: true # pgnode3

  config.vm.synced_folder ".", "/vagrant", type: "virtualbox"

  # Provisioning Step 1: Install Docker
  config.vm.provision "shell", path: "install-docker.sh", privileged: true, name: "Install Docker"

  # Provisioning Step 2: Run your main setup script
  # This will run after install-docker.sh completes.
  # By this point, Docker should be installed and the service running.
  # A new shell session for this provisioner might have an updated PATH.
  config.vm.provision "shell", path: "master_setup_pgauto.sh", privileged: true, name: "Setup pg_auto_failover Cluster"

end