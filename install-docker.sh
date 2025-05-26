#!/bin/bash
set -e # Exit on error

echo "INFO: Checking if Docker is installed..."
if ! command -v docker &> /dev/null
then
    echo "INFO: Docker not found. Installing Docker..."
    # Update package lists
    apt-get update -y
    # Install prerequisites
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common

    # Add Docker’s official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Start and enable Docker service
    systemctl start docker
    systemctl enable docker

    # Add vagrant user to docker group (useful for manual ssh sessions later)
    if id "vagrant" &>/dev/null; then
      usermod -aG docker vagrant
    fi
    echo "INFO: Docker installation complete."
else
    echo "INFO: Docker is already installed. Version: $(docker --version)"
fi

# Make sure docker commands can be found even if PATH is not immediately updated for root's non-login shell
# This is a bit of a hack for immediate use in subsequent provisioners in the same Vagrant run.
# Better is that the subsequent provisioner will run in a "new" context where PATH is correct.
# However, this won't hurt.
export PATH=/usr/bin:/usr/local/bin:/snap/bin:$PATH
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker command still not found in PATH after installation. Check installation."
    exit 1
fi