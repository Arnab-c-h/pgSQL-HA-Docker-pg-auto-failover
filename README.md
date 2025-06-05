# PostgreSQL HA Cluster with pg_auto_failover using Vagrant & Docker

## Project Components

This project automates the deployment of a `pg_auto_failover` high-availability PostgreSQL cluster. The setup is orchestrated by Vagrant, which provisions a VirtualBox VM. Inside this VM, Docker is used to run the `pg_auto_failover` components.

The core components are:

### 1. `Vagrantfile`

*   **Role:** The master configuration for Vagrant, defining the virtual machine's characteristics and how it's provisioned.
*   **Key Actions & Code Summary:**
    *   **Base VM Image Selection:**
        ```ruby
        config.vm.box = "ubuntu/focal64"
        ```
        This line specifies that the virtual machine will be created from the `ubuntu/focal64` Vagrant box, which is an official Ubuntu 20.04 LTS 64-bit image. Vagrant automatically downloads and caches this box if it's not already available locally.
    *   **VirtualBox Provider Customization:**
        ```ruby
        config.vm.provider "virtualbox" do |vb|
          vb.name = "pgAutoFailoverVM-Vagrant" # Sets the VM name in VirtualBox GUI
          vb.memory = "6144"  # Allocates 6GB of RAM to the VM
          vb.cpus = "4"       # Assigns 4 virtual CPU cores to the VM
        end
        ```
        This block configures VM-specific settings for the VirtualBox provider, such as the display name, allocated memory, and CPU cores. Adequate resources are crucial for running multiple PostgreSQL instances within Docker.
    *   **Network Configuration:**
        *   **Private Network (Host-Only):**
            ```ruby
            config.vm.network "private_network", ip: "192.168.56.150"
            ```
            A host-only network is created, assigning a static IP address (e.g., `192.168.56.150`) to the VM. This allows stable network communication between the host machine and the guest VM using this predictable IP.
        *   **Port Forwarding:**
            ```ruby
            config.vm.network "forwarded_port", guest: 5430, host: 5430, auto_correct: true # Monitor
            config.vm.network "forwarded_port", guest: 5001, host: 5001, auto_correct: true # pgnode1
            config.vm.network "forwarded_port", guest: 5002, host: 5002, auto_correct: true # pgnode2
            config.vm.network "forwarded_port", guest: 5003, host: 5003, auto_correct: true # pgnode3
            config.vm.network "forwarded_port", guest: 6432, host: 6432, auto_correct: true # For PgCat/Pgpool later
            ```
            These rules forward specific ports from the host machine to corresponding ports on the guest VM. This enables accessing services running inside the VM (like the PostgreSQL nodes via their Docker-mapped ports, or a connection pooler) using `localhost:<host_port>` on the host machine. The `auto_correct: true` option helps resolve conflicts if a host port is already in use.
    *   **Synced Folder:**
        ```ruby
        config.vm.synced_folder ".", "/vagrant", type: "virtualbox"
        ```
        This instruction shares the current project directory on the host machine (where the `Vagrantfile` resides) into the `/vagrant` directory inside the guest VM. This mechanism makes the provisioning scripts (`install-docker.sh`, `master_setup_pgauto.sh`) available within the VM's filesystem.
    *   **Provisioning Sequence:**
        ```ruby
        # Step 1: Install Docker
        config.vm.provision "shell", path: "install-docker.sh", privileged: true, name: "Install Docker"
        
        # Step 2: Install psql client in VM for direct VM-level testing
        config.vm.provision "shell", inline: "apt-get update -y && apt-get install -y postgresql-client-16 ...", privileged: true, name: "Install psql client in VM"
        
        # Step 3: Setup pg_auto_failover Cluster
        config.vm.provision "shell", path: "master_setup_pgauto.sh", privileged: true, name: "Setup pg_auto_failover Cluster"
        ```
        Defines a sequence of shell scripts that Vagrant executes after the VM is created and booted to set up the necessary software:
        1.  `install-docker.sh`: Installs Docker Community Edition and Docker Compose plugin.
        2.  An inline shell script: Installs `psql` (PostgreSQL client utilities) directly within the VM for diagnostics.
        3.  `master_setup_pgauto.sh`: The main script that orchestrates the deployment of the `pg_auto_failover` cluster using Docker.
        The `privileged: true` option ensures these scripts run with root permissions inside the VM, necessary for package installation and system configuration.

### 2. `install-docker.sh`

*   **Role:** A dedicated provisioning script executed by Vagrant to install Docker Engine on the Ubuntu guest VM.
*   **Functionality & Key Actions:**
    *   **Package Updates:** Runs `apt-get update -y`.
    *   **Prerequisite Installation:** Installs packages required for adding Docker's APT repository and for Docker itself (e.g., `apt-transport-https`, `ca-certificates`, `curl`, `gnupg`, `lsb-release`).
    *   **Docker GPG Key & Repository Setup:** Securely adds Docker's official GPG key and configures the system to use Docker's official APT repository. This ensures that authentic and current versions of Docker are installed.
    *   **Docker Engine Installation:** Installs the core Docker components: `docker-ce` (Community Edition engine), `docker-ce-cli` (command-line interface), `containerd.io` (container runtime), and `docker-compose-plugin` (for `docker compose` functionality).
    *   **Service Management:** Uses `systemctl start docker` and `systemctl enable docker` to start the Docker service immediately and ensure it starts automatically on subsequent VM boots.
    *   **User Group Modification:** Adds the default `vagrant` user to the `docker` group using `usermod -aG docker vagrant`. This allows the `vagrant` user to run `docker` commands without needing `sudo` after their next login session or after running `newgrp docker`.
    *   **Verification:** Includes a basic check to confirm the `docker` command is accessible.

### 3. `master_setup_pgauto.sh` (Focus: `pg_auto_failover` Setup Only)

*   **Role:** The primary automation script for deploying the `pg_auto_failover` PostgreSQL cluster. It leverages Docker (assumed to be installed by `install-docker.sh`) to create and configure the necessary containers. This version of the script sets up the HA cluster and prepares it for a connection pooler, but does not install the pooler itself.
*   **Functionality & Key Actions:**
    *   **Error Handling & PATH:**
        *   `set -e` and `set -o pipefail`: Ensures the script exits immediately on errors.
        *   `export PATH=...`: Prepends common binary locations to the `PATH` for robustness.
    *   **Configuration Variables:**
        *   Defines numerous bash variables for Docker image names (`CUSTOM_IMAGE_NAME`), container names (`MONITOR_CONTAINER_NAME`, `PGNODEx_CONTAINER_NAME`), hostnames for Docker's internal DNS, Docker volume names for data persistence, host port mappings, database name (`DB_NAME`), and essential **passwords** (`PG_AUTOCTL_MONITOR_PASSWORD`, `POSTGRES_SUPERUSER_PASSWORD`). **These passwords are explicitly marked as needing user modification for security.**
        *   `CLIENT_IP_FOR_HBA` is set (e.g., to `"0.0.0.0/0"`) to control direct client access via `psql`, with `DB_USER_FOR_CLIENT_ACCESS` specifying the PostgreSQL user for this access (typically `postgres`).
    *   **Helper Functions:**
        *   `log_info()`: Provides timestamped informational messages.
        *   `cleanup()`: Stops and removes specified Docker containers, volumes, and (optionally commented out) the Docker network from previous runs to ensure a clean environment. Uses `>/dev/null 2>&1 || true` to suppress errors for non-existent items.
        *   `create_network_if_not_exists()`: Creates a custom Docker bridge network (e.g., `pgautofailover_cluster_net`) if it's not already present, enabling inter-container communication by hostname.
        *   `configure_hba_and_reload()`:
            *   This function is crucial for setting up PostgreSQL client authentication. It's called for each data node container (`pgnode1`, `pgnode2`, `pgnode3`).
            *   It appends lines to the `pg_hba.conf` file inside the target container.
            *   Adds a `trust` rule for the `DB_USER_FOR_CLIENT_ACCESS` (e.g., `postgres`) from `CLIENT_IP_FOR_HBA` (e.g., `0.0.0.0/0`), allowing direct `psql` connections from the host/VM without a password for testing.
            *   **If the node is the initial primary (`is_primary_node=true`):** It adds `trust` rules for `pg_auto_failover`'s internal replication users (`pgautofailover_replicator` and `postgres` for replication purposes) from any IP within the `DOCKER_NETWORK_CIDR`. This allows standbys to connect to the primary for `pg_basebackup` and streaming replication.
            *   **(Crucial for Pooler Integration Later):** This function is designed to also add HBA rules to **all data nodes** that allow the `postgres` user to connect from the `DOCKER_NETWORK_CIDR` using password authentication (e.g., `scram-sha-256`). This prepares the PostgreSQL nodes to accept connections from a connection pooler (like Pgpool-II or PgCat) that will run in its own container on the same Docker network.
            *   Finally, it executes `pg_ctl reload` as the `postgres` user inside the container to apply HBA changes without a full PostgreSQL restart.
        *   `set_postgres_superuser_password()`: Connects to the specified data node as the `postgres` OS user (leveraging initial trust or peer auth) and executes `ALTER USER postgres WITH PASSWORD ...` to set the password for the `postgres` database superuser, using the `POSTGRES_SUPERUSER_PASSWORD` variable.
    *   **Custom Docker Image Generation for `pg_auto_failover` Nodes:**
        *   `ENTRYPOINT_SCRIPT_CONTENT`: A bash heredoc (`cat <<'EOF'`) that defines the content of an entrypoint script. This script is copied into the Docker image. Its main responsibilities are:
            1.  Setting default `PG_USER` and `PG_GROUP` to `postgres`.
            2.  Checking and correcting file ownership of the mounted `PGDATA` volume path (`VOL_BASE_PATH_IN_CONTAINER`) and its subdirectories (`ACTUAL_MONITOR_PGDATA`, `ACTUAL_NODE_PGDATA`) to `PG_USER:PG_GROUP`. This is critical because Docker volumes mounted from the host might initially be owned by `root`.
            3.  Using `gosu` (a lightweight `sudo` alternative) to switch from the `root` user (which the container starts as) to the `PG_USER` (`postgres`) before executing the main command (e.g., `pg_autoctl`, `postgres`). This follows the security best practice of running processes with least privilege.
        *   `DOCKERFILE_CONTENT`: A bash heredoc (`cat <<EOF`) defining the `Dockerfile` instructions. This Dockerfile:
            1.  Uses `ubuntu:focal` as the base.
            2.  Sets essential environment variables (`DEBIAN_FRONTEND`, `LANG`, `LC_ALL`, `GOSU_VERSION`, etc.).
            3.  Performs multi-step `RUN` commands to:
                *   Install prerequisite packages (`wget`, `gnupg`, `ca-certificates`, `lsb-release`, `sudo`, `curl`, `locales`, etc.) and `gosu` (including GPG signature verification for `gosu`).
                *   Add the official PostgreSQL APT repository, including its GPG key.
                *   Install `postgresql-16`, `postgresql-client-16`, `postgresql-16-pglogical`, and importantly, `postgresql-16-auto-failover`. A crucial step here is modifying `/etc/postgresql-common/createcluster.conf` with `sed` to prevent the Debian packaging from automatically creating a default "main" PostgreSQL cluster, as `pg_auto_failover` will manage cluster creation.
            4.  Sets further `ENV` variables for paths used by the entrypoint script.
            5.  Creates placeholder `PGDATA` directories within the image build (actual data resides on volumes).
            6.  Adds PostgreSQL's `bin` directory to the system `PATH`.
            7.  `COPY`s the generated entrypoint script (from `ENTRYPOINT_SCRIPT_CONTENT`) into the image and makes it executable.
            8.  Sets the `ENTRYPOINT` of the image to this script.
            9.  Sets the default `CMD` to `["pg_autoctl", "run"]`, which is the command the `pg_auto_failover` agent nodes will execute on startup.
        *   `build_docker_image()`: This shell function encapsulates the image build logic. It checks if an image with `CUSTOM_IMAGE_NAME:CUSTOM_IMAGE_TAG` already exists. If not, it creates a temporary build context directory, writes the `DOCKERFILE_CONTENT` and `ENTRYPOINT_SCRIPT_CONTENT` into respective files within this context, then runs `docker build`. Afterwards, it cleans up the temporary directory.
    *   **Main Cluster Deployment Logic:**
        1.  Executes `cleanup()`, `build_docker_image()`, and `create_network_if_not_exists()`.
        2.  Dynamically determines `DOCKER_NETWORK_CIDR` by running `docker network inspect` on the created network and parsing the output. This is used for HBA rules.
        3.  **Monitor Node:** Starts the `monitor_node` container using `docker run`. The command executed inside is `pg_autoctl create monitor --auth trust --run`, with appropriate `--pgdata`, `--hostname`, and SSL flags. A `sleep` allows for initialization.
        4.  **Primary Node (`pgnode1`):** Starts the `pgnode1` container. The command is `pg_autoctl create postgres --auth trust --run`, providing the monitor's URI (constructed using `PG_AUTOCTL_MONITOR_USER` and `PG_AUTOCTL_MONITOR_PASSWORD`). After a `sleep`, `configure_hba_and_reload` is called (with `is_primary_node=true` to add replication rules) and `set_postgres_superuser_password` is called.
        5.  **Standby Nodes (`pgnode2`, `pgnode3`):** Started sequentially, similar to `pgnode1`, they connect to the monitor and are instructed to become standbys. After each starts and a `sleep` period, `configure_hba_and_reload` is called (with `is_primary_node=false`).
        6.  **Final Verification:** Runs `docker ps -a` to show container statuses and `docker exec -u postgres monitor_node pg_autoctl show state` to display the cluster's formation status from `pg_auto_failover`'s perspective.
        7.  **Output:** Prints completion messages, connection examples for direct PostgreSQL access


# How to use the configuration 
This project provides an automated setup for a high-availability PostgreSQL cluster using `pg_auto_failover`. It leverages Vagrant to create and provision a Linux Virtual Machine (VM) inside VirtualBox. Docker, running within that VM, is then used to deploy the `pg_auto_failover` components: one monitor node, one primary PostgreSQL node, and two standby PostgreSQL nodes.

## Features

*   **Automated VM Creation:** Uses Vagrant to create an Ubuntu Focal (20.04 LTS) VM.
*   **Automated Docker Installation:** The VM is provisioned with Docker CE.
*   **Custom PostgreSQL + pg_auto_failover Docker Image:** The script builds a Docker image containing PostgreSQL 16 and the necessary `pg_auto_failover` tools.
*   **Automated `pg_auto_failover` Cluster Initialization:**
    *   Starts and configures the monitor node.
    *   Initializes a primary PostgreSQL node (`pgnode1`).
    *   Initializes two standby PostgreSQL nodes (`pgnode2`, `pgnode3`) replicating from the primary.
    *   Sets a password for the `postgres` superuser on all data nodes.
    *   Configures `pg_hba.conf` on PostgreSQL nodes for:
        *   Internal replication and communication required by `pg_auto_failover` (using `--auth trust`).
        *   Direct client access from the host machine/VM (configurable, defaults to `trust` from any IP for testing).
*   **Reproducible HA Environment:** Ideal for learning, developing, and testing `pg_auto_failover` functionality.

## Prerequisites

1.  **VirtualBox:** Download and install from [https://www.virtualbox.org/](https://www.virtualbox.org/).
    *   Ensure the "VirtualBox Oracle VM VirtualBox Extension Pack" is also installed.
2.  **Vagrant:** Download and install from [https://www.vagrantup.com/downloads](https://www.vagrantup.com/downloads).
3.  **Git (Optional but Recommended):** To clone the repository containing these files.
4.  **SSH Client:** For `vagrant ssh` (usually included with Git Bash on Windows, or native on macOS/Linux).
5.  **`psql` Client (on Host Machine - Optional but Recommended):** To connect to and test the PostgreSQL cluster from your host machine.

## Project Files

*   `Vagrantfile`: Defines the VirtualBox VM configuration and the provisioning steps.
*   `install-docker.sh`: A script called by Vagrant to install Docker inside the VM.
*   `master_setup_pgauto.sh`: The main script called by Vagrant to:
    1.  Build the custom `pg_auto_failover` Docker image.
    2.  Set up the Docker network.
    3.  Deploy and initialize the monitor, primary, and standby containers.
    4.  Configure HBA rules and the `postgres` superuser password.

## Setup Instructions

1.  **Prepare Project Files:**
    Ensure `Vagrantfile`, `install-docker.sh`, and `master_setup_pgauto.sh` are in the same directory on your host machine. If cloned from Git, they will be.

2.  **Review and Configure `master_setup_pgauto.sh`:**
    Open `master_setup_pgauto.sh` in a text editor. Before running, **it is crucial to review and modify the following variables** in the "Configuration Variables" section:

    *   **Passwords (MUST CHANGE):**
        *   `PG_AUTOCTL_MONITOR_PASSWORD`: Set a strong password for the `pg_auto_failover` monitor's internal user (`autoctl_node`), used by data nodes to connect to the monitor.
        *   `POSTGRES_SUPERUSER_PASSWORD`: Set a strong password for the `postgres` superuser on all PostgreSQL data nodes (`pgnode1`, `pgnode2`, `pgnode3`).
    *   **Client Access HBA:**
        *   `CLIENT_IP_FOR_HBA`: Defaults to `"0.0.0.0/0"`. This allows your `psql` client (or other tools) to connect as the `DB_USER_FOR_CLIENT_ACCESS` (which is `postgres`) from *any* IP address using `trust` authentication (no password required for this specific HBA rule). This is for ease of testing.
            *   **Security Note:** For a more secure setup, change this to your specific host IP address or a restricted network range (e.g., `"192.168.56.1/32"` if your host is `192.168.56.1` on the Vagrant private network).
    *   **Other Variables (Review, defaults are usually fine):**
        *   `CUSTOM_IMAGE_NAME`, `CUSTOM_IMAGE_TAG`: For the pg_auto_failover Docker image.
        *   `DOCKER_NETWORK_NAME`: Name of the Docker network.
        *   Container names (`MONITOR_CONTAINER_NAME`, `PGNODEx_CONTAINER_NAME`).
        *   Hostnames (`MONITOR_HOSTNAME`, `PGNODEx_HOSTNAME`).
        *   Volume names (`MONITOR_DATA_VOL`, `PGNODEx_DATA_VOL`).
        *   Port mappings (`MONITOR_PORT`, `PGNODEx_PORT`).

3.  **Review `Vagrantfile` (Optional):**
    *   It's pre-configured for an `ubuntu/focal64` VM, RAM/CPU allocation (defaults to 6GB/4CPUs in the last provided version), a private network (VM IP `192.168.56.150`), and forwards the PostgreSQL node ports to your host's `localhost`. Adjust if necessary.
    *   Forwarded ports to host `localhost`:
        *   `5430` (Monitor's PostgreSQL)
        *   `5001` (pgnode1)
        *   `5002` (pgnode2)
        *   `5003` (pgnode3)

4.  **Start the Vagrant Environment:**
    Open a terminal/command prompt on your **host machine**, navigate to your project directory (containing the `Vagrantfile`), and run:
    ```bash
    vagrant up
    ```
    *   This will download the Vagrant box (if new), create the VM, and run the provisioners (`install-docker.sh` then `master_setup_pgauto.sh`).
    *   The process (especially the first time) can take 15-30+ minutes depending on downloads and image build time. Monitor the output.

5.  **Verify `pg_auto_failover` Cluster Setup:**
    Once `vagrant up` completes, the `master_setup_pgauto.sh` script should have printed the final cluster state.
    *   To verify manually, SSH into the VM:
        ```bash
        vagrant ssh
        ```
    *   Inside the Vagrant VM:
        ```bash
        docker ps
        # Expected: monitor_node, pgnode1, pgnode2, pgnode3 all 'Up'.

        docker exec -u postgres monitor_node pg_autoctl show state
        # Expected: One 'primary' node (likely pgnode1), two 'secondary' nodes,
        # all healthy and with closely matching LSNs.
        ```
    *   Type `exit` to leave the VM's SSH session.

## Connecting to the PostgreSQL Cluster (Directly)

After successful setup, you can connect to the individual PostgreSQL nodes from your **host machine** using `psql` or a GUI tool.

*   **User:** `postgres`
*   **Password:** The `POSTGRES_SUPERUSER_PASSWORD` you set in `master_setup_pgauto.sh`.
    *(Note: If connecting from an IP matching `CLIENT_IP_FOR_HBA` which uses `trust`, the password might not be prompted by `psql` for that specific connection, but the user does have a password set).*
*   **Database:** `myappdb` (or as defined by `DB_NAME`).

**Connection Examples (from your host machine):**

*   **To the current primary (initially `pgnode1`):**
    ```bash
    psql "postgresql://postgres:YOUR_POSTGRES_SUPERUSER_PASSWORD@localhost:5001/myappdb"
    ```

*   **To a standby (e.g., `pgnode2`) for read-only queries:**
    ```bash
    psql "postgresql://postgres:YOUR_POSTGRES_SUPERUSER_PASSWORD@localhost:5002/myappdb"
    ```
    *(Attempting a write operation on a standby will result in an error).*

*   **To the `pg_auto_failover` monitor's internal PostgreSQL instance:**
    *   User: `autoctl_node` (as defined by `PG_AUTOCTL_MONITOR_USER`).
    *   Password: The `PG_AUTOCTL_MONITOR_PASSWORD` you set.
    *   Port: `5430` (as per `MONITOR_PORT`).
    *   Database: `pg_auto_failover`.
    ```bash
    psql "postgresql://autoctl_node:YOUR_PG_AUTOCTL_MONITOR_PASSWORD@localhost:5430/pg_auto_failover"
    ```

## Testing `pg_auto_failover` Functionality

Once connected (either directly to nodes or via `vagrant ssh` to run `docker exec` commands):

1.  **Check Cluster Status:**
    *   Inside VM: `docker exec -u postgres monitor_node pg_autoctl show state`

2.  **Perform Data Operations:**
    *   Write to the primary (e.g., via `psql` to `localhost:5001`).
    *   Verify data replicates to standbys (via `psql` to `localhost:5002` and `localhost:5003`).

3.  **Test Switchover (Planned Maintenance):**
    *   Inside VM: `docker exec -u postgres monitor_node pg_autoctl perform switchover --formation default`
    *   Observe role changes using `pg_autoctl show state`.
    *   Verify connectivity and write capability on the new primary from your host.

4.  **Test Failover (Simulate Primary Crash):**
    *   Identify current primary (e.g., `pgnode1`).
    *   Inside VM: `docker stop <current_primary_container_name>` (e.g., `docker stop pgnode1`)
    *   Observe `pg_autoctl show state` (inside VM) as a standby gets promoted.
    *   Verify connectivity and write capability on the new primary from your host.
    *   Start the old primary (`docker start <old_primary_container_name>`) and observe it rejoining as a standby.

## Vagrant Management Commands (Run from Host in Project Directory)

*   `vagrant up`: Create and provision the VM.
*   `vagrant ssh`: SSH into the VM.
*   `vagrant halt`: Shut down the VM gracefully.
*   `vagrant resume`: Start a halted VM.
*   `vagrant provision`: Re-run only the provisioners on a running VM.
*   `vagrant reload --provision`: Restart the VM and re-run provisioners.
*   `vagrant destroy -f`: **Delete the VM and all its associated resources.**


