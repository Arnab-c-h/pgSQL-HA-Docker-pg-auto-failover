# pg_auto_failover PostgreSQL HA Cluster with Vagrant & Docker

This project provides an automated setup for a high-availability PostgreSQL cluster using `pg_auto_failover`. It leverages Vagrant to create and provision a Linux Virtual Machine (VM) inside VirtualBox, and then uses Docker within that VM to deploy the `pg_auto_failover` components: one monitor node, one primary PostgreSQL node, and two standby PostgreSQL nodes.

## Features

*   **Automated VM Setup:** Uses Vagrant to create an Ubuntu Focal (20.04) VM.
*   **Automated Docker & pg_auto_failover Installation:** The VM is provisioned with Docker and all necessary components for the cluster.
*   **Automated Cluster Initialization:**
    *   Builds a custom Docker image for `pg_auto_failover` with PostgreSQL 16.
    *   Starts and configures the monitor node.
    *   Initializes a primary PostgreSQL node.
    *   Initializes two standby PostgreSQL nodes replicating from the primary.
    *   Sets a superuser password for the `postgres` user on all data nodes.
    *   Configures `pg_hba.conf` for:
        *   Internal replication within the Docker network.
        *   Client access from the host machine to the PostgreSQL nodes via Vagrant's forwarded ports.
*   **Reproducible Environment:** Ideal for development, testing, and learning about `pg_auto_failover`.

## Prerequisites

1.  **VirtualBox:** Download and install from [https://www.virtualbox.org/](https://www.virtualbox.org/).
    *   Ensure the "VirtualBox Oracle VM VirtualBox Extension Pack" is also installed.
2.  **Vagrant:** Download and install from [https://www.vagrantup.com/downloads](https://www.vagrantup.com/downloads).
3.  **Git (Optional but Recommended):** To clone this repository if it's hosted.
4.  **SSH Client:** For `vagrant ssh` (usually included with Git Bash on Windows, or native on macOS/Linux).
5.  **`psql` Client (on Host Machine - Optional):** To connect to the PostgreSQL cluster from your host machine for testing.

## Project Structure
pgauto_vagrant_project/
├── Vagrantfile # Defines the VM and its provisioning
├── master_setup_pgauto.sh # Main script to build image, setup Docker containers, and configure pg_auto_failover
└── install-docker.sh # Helper script to install Docker inside the VM (called by Vagrantfile)
└── README.md 


## Setup Instructions

1.  **Clone the Repository (if applicable) or Prepare Files:**
    Ensure you have `Vagrantfile`, `master_setup_pgauto.sh`, and `install-docker.sh` in the same project directory on your host machine.

2.  **Review and Configure `master_setup_pgauto.sh`:**
    Open `master_setup_pgauto.sh` in a text editor and **critically review and update** the following variables in the "Configuration Variables" section:
    *   `PG_AUTOCTL_MONITOR_PASSWORD`: Set a strong password for the `pg_auto_failover` monitor's internal user (`autoctl_node`).
    *   `POSTGRES_SUPERUSER_PASSWORD`: Set a strong password for the `postgres` superuser on all data nodes.
    *   `CLIENT_IP_FOR_HBA`:
        *   This defines which client IPs can connect to the PostgreSQL nodes using the `postgres` user.
        *   For initial testing and connections from your host machine to the VM via Vagrant's forwarded ports, set this to `"0.0.0.0/0"` to allow connections from any IP.
        *   **Security Note:** For a more secure setup later, determine your host's IP on the Vagrant private network (often `192.168.56.1` if the VM is `192.168.56.150`) or your actual client IP and restrict this value (e.g., `"192.168.56.1"` or your specific public/private IP).
    *   `CUSTOM_IMAGE_NAME` and `CUSTOM_IMAGE_TAG`: Defaults are `pgautofailover-pgsql16-focal` and `latest`. Change if needed.
    *   Other port mappings or container names if you have specific preferences.

3.  **Review `Vagrantfile` (Optional):**
    *   The `Vagrantfile` is pre-configured to use `ubuntu/focal64`, assign 4GB RAM / 2 CPUs, set up a private network (`192.168.56.150` for the VM), and forward necessary PostgreSQL ports to your host's `localhost`. You can adjust these if needed.
    *   The forwarded ports are (ensure these match `MONITOR_PORT`, `PGNODE1_PORT` etc. in `master_setup_pgauto.sh`):
        *   Host `5430` -> VM `5430` (Monitor node's internal PostgreSQL)
        *   Host `5001` -> VM `5001` (pgnode1 - initial primary)
        *   Host `5002` -> VM `5002` (pgnode2 - initial standby)
        *   Host `5003` -> VM `5003` (pgnode3 - initial standby)

4.  **Start the Vagrant Environment:**
    Open a terminal or command prompt **on your host machine**, navigate to the project directory (`pgauto_vagrant_project/`), and run:
    ```bash
    vagrant up
    ```
    *   This command will:
        *   Download the Ubuntu box image (if not already cached).
        *   Create and configure the VirtualBox VM.
        *   Run the provisioners:
            1.  `install-docker.sh` (to install Docker inside the VM).
            2.  `master_setup_pgauto.sh` (to build the custom image, deploy containers, and set up `pg_auto_failover`).
    *   This process can take a significant amount of time on the first run. Subsequent `vagrant up` commands or `vagrant reload --provision` will be faster.
    *   Monitor the output for any errors.

5.  **Verify Setup After `vagrant up` Completes:**
    The `master_setup_pgauto.sh` script will output the final cluster state.
    *   **From your host machine's terminal (in the project directory):** You can SSH into the VM for more checks:
        ```bash
        vagrant ssh
        ```
    *   **Inside the Vagrant VM (after `vagrant ssh`):**
        ```bash
        docker ps # Should show monitor_node, pgnode1, pgnode2, pgnode3 running
        docker exec -u postgres monitor_node pg_autoctl show state
        ```
        This should display one primary and two secondary nodes.

## Connecting to PostgreSQL

Once the setup is complete, you can connect to the PostgreSQL cluster nodes from your **host machine** using `psql` or any other PostgreSQL client.

*   **User:** `postgres`
*   **Password:** The `POSTGRES_SUPERUSER_PASSWORD` you set in `master_setup_pgauto.sh`.
*   **Database:** `myappdb` (or as defined by `DB_NAME` in the script).

**Connection Examples (from your host machine):**

*   **To the initial primary (`pgnode1`):**
    ```bash
    psql "postgresql://postgres:YOUR_POSTGRES_SUPERUSER_PASSWORD@localhost:5001/myappdb"
    ```

*   **To an initial standby (e.g., `pgnode2`) for read-only queries:**
    ```bash
    psql "postgresql://postgres:YOUR_POSTGRES_SUPERUSER_PASSWORD@localhost:5002/myappdb"
    ```

*   **To the `pg_auto_failover` monitor's internal PostgreSQL instance (for advanced inspection):**
    *   The monitor node user (`autoctl_node`) and password (`PG_AUTOCTL_MONITOR_PASSWORD`) are used.
    *   The port is `5430` (as configured by `MONITOR_PORT` and Vagrant port forwarding).
    *   Database is `pg_auto_failover`.
    ```bash
    psql "postgresql://autoctl_node:YOUR_PG_AUTOCTL_MONITOR_PASSWORD@localhost:5430/pg_auto_failover"
    ```

**Note on `CLIENT_IP_FOR_HBA`:** If you set `CLIENT_IP_FOR_HBA="0.0.0.0/0"` in `master_setup_pgauto.sh`, the HBA rule for the `postgres` user from your host will use `trust`, and you might not need to supply the password in the `psql` connection string *for that specific connection*. However, it's good practice to use it as the password *is* set on the `postgres` user.

## Testing the HA Cluster

Refer to standard `pg_auto_failover` testing procedures. You can perform these actions by:

*   Running `docker exec -u postgres monitor_node pg_autoctl <command>` **inside the Vagrant VM** (after `vagrant ssh`).
*   Simulating node failures using `docker stop <container_name>` **inside the Vagrant VM**.
*   Verifying data consistency and connectivity from your **host machine** using `psql`.

**Example: Perform a switchover**
1.  `vagrant ssh`
2.  (Inside VM) `docker exec -u postgres monitor_node pg_autoctl perform switchover`
3.  (Inside VM) `docker exec -u postgres monitor_node pg_autoctl show state` (to see the new primary)
4.  `exit` (from VM ssh session)
5.  (On Host) Connect from your host `psql` to the *new* primary's forwarded port (e.g., `localhost:5002` if `pgnode2` became primary).

## Vagrant Management

*   **Start and provision VM:** `vagrant up`
*   **SSH into VM:** `vagrant ssh`
*   **Stop VM:** `vagrant halt`
*   **Restart VM and re-run provisioners:** `vagrant reload --provision`
*   **Re-run provisioners on running VM:** `vagrant provision`
*   **Destroy VM (deletes everything):** `vagrant destroy -f`

## Troubleshooting

*   **`docker: command not found` during provisioning:** Ensure `install-docker.sh` is present and runs successfully before `master_setup_pgauto.sh` in your `Vagrantfile`.
*   **`Dockerfile` build errors:** Check the `DOCKERFILE_CONTENT` within `master_setup_pgauto.sh` for syntax issues. The error output from `vagrant up` will show the problematic line.
*   **Containers exiting:**
    *   `vagrant ssh` into the VM.
    *   Use `docker logs <container_name>` (e.g., `docker logs pgnode2`) to see specific error messages from `pg_autoctl` or PostgreSQL.
    *   Common issues include problems connecting to the monitor (check URI and monitor logs) or HBA issues preventing replication (check `pg_hba.conf` on the primary and replication logs).
*   **Cannot connect with `psql` from host:**
    *   Verify Vagrant port forwarding is correct in `Vagrantfile` and matches the ports exposed by Docker containers to the VM.
    *   Ensure `CLIENT_IP_FOR_HBA` in `master_setup_pgauto.sh` allows your host's IP (use `0.0.0.0/0` for initial broad testing).
    *   Check PostgreSQL logs inside the target container on the VM (via `vagrant ssh` then `docker logs ...`) to see the connecting IP and any HBA errors.
    *   Ensure no host-level firewall (Windows Firewall, macOS Firewall) is blocking the connection to `localhost` on the forwarded ports.
    *   Ensure no firewall *inside the VM* (like `ufw`) is blocking the ports if you manually enabled one. Vagrant boxes usually don't have a restrictive firewall by default.
