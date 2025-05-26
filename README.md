# Automated pg_auto_failover Cluster Setup on Docker

This project provides a single bash script (`master_setup_pgauto.sh`) to automate the complete setup of a pg_auto_failover cluster with PostgreSQL 16 on Docker. It handles everything from building the custom Docker image to configuring a 4-node cluster (1 monitor, 1 primary, 2 standbys).

## Features

-   **Automated Docker Image Build:** Dynamically generates a Dockerfile and builds a custom image with PostgreSQL 16, pg_auto_failover, and necessary tools if the image doesn't already exist.
-   **Full Cluster Deployment:** Sets up a 4-node pg_auto_failover cluster:
    -   1 Monitor Node
    -   1 Primary Data Node
    -   2 Standby Data Nodes
-   **Automated Configuration:**
    -   Initializes all pg_auto_failover nodes.
    -   Configures `pg_hba.conf` on each data node to allow client connections from a specified IP (for testing/management).
    -   Sets a strong password for the `postgres` superuser on the primary, which then replicates to standbys.
-   **Idempotent (with cleanup):** The script includes a cleanup function to remove existing containers, volumes, and networks from previous runs, ensuring a fresh setup each time.
-   **Parameterized:** Key settings like image name, container names, ports, and passwords can be configured via variables at the top of the script.

## Prerequisites

1.  **Linux Environment:** A Linux host or WSL2 (Windows Subsystem for Linux) environment with bash.
2.  **Docker:** Docker Engine and Docker CLI must be installed and running.
    -   The user running the script should have permissions to interact with Docker (either by being in the `docker` group or by running the script with `sudo`, though the former is recommended).
3.  **Internet Access:** Required for downloading base images, packages during the Docker image build, and potentially for gosu GPG key verification.
4.  **Basic Utilities:** `curl`, `gpg`, `mktemp` should be available (standard on most Linux distros).

## Setup and Configuration

1.  **Clone or Download:**
    Get the `master_setup_pgauto.sh` script into a directory on your Linux system/WSL2.

2.  **Review and Edit Configuration:**
    Open `master_setup_pgauto.sh` in a text editor. Carefully review and **modify the variables** in the "Configuration Variables" section at the top, especially:
    *   `CUSTOM_IMAGE_NAME` & `CUSTOM_IMAGE_TAG`: If you want to name/tag your Docker image differently.
    *   **Passwords (CRITICAL):**
        *   `PG_AUTOCTL_MONITOR_PASSWORD`: Password for the `autoctl_node` user that data nodes use to connect to the monitor.
        *   `POSTGRES_SUPERUSER_PASSWORD`: Password to be set for the `postgres` superuser on all data nodes.
        **Ensure these are strong and unique!**
    *   `CLIENT_IP_FOR_HBA`: The IP address of the machine from which you intend to connect to the PostgreSQL instances using `psql` or other clients. For local testing from the same host where Docker is running (e.g., from your WSL2 terminal to Docker containers in WSL2), `172.17.0.1` or `172.19.0.1` (or similar, depending on your Docker network bridge IP) is common. If testing from a different machine, set this to the connecting machine's IP or `0.0.0.0/0` **for initial testing only (insecure)**.
    *   Ports (`MONITOR_PORT`, `PGNODE1_PORT`, etc.): Change if the defaults conflict with other services.

3.  **Make the Script Executable:**
    ```bash
    chmod +x master_setup_pgauto.sh
    ```

## Usage

1.  **Navigate to the script's directory:**
    ```bash
    cd /path/to/your/script_directory
    ```

2.  **Run the script:**
    ```bash
    ./master_setup_pgauto.sh
    ```

The script will output its progress. This includes:
    -   Cleaning up any previous deployments.
    -   Building the Docker image (if it's the first run or the image was removed).
    -   Starting and configuring the monitor node.
    -   Starting and configuring the primary data node.
    -   Starting and configuring the two standby data nodes.
    -   A final status check displaying the `pg_autoctl show state` output.

## After Setup

Once the script completes successfully:

*   **PostgreSQL Access:**
    *   The initial primary node (`pgnode1` by default) will be accessible on `localhost:<PGNODE1_PORT>` (e.g., `localhost:5001`).
    *   Standby nodes (`pgnode2`, `pgnode3`) will be accessible on their respective ports for read-only queries.
    *   Connect as the `postgres` user with the `POSTGRES_SUPERUSER_PASSWORD` you set in the script.
        Example:
        ```bash
        psql "postgresql://postgres:YOUR_POSTGRES_SUPERUSER_PASSWORD@localhost:5001/myappdb"
        ```
        (Note: The `pg_hba.conf` rule added by the script for `CLIENT_IP_FOR_HBA` uses `trust` by default for the `postgres` user, so a password might not be strictly required for that specific client IP connection initially, but it's good practice to use it.)

*   **pg_auto_failover Commands:**
    You can interact with the cluster using `pg_autoctl` commands by executing them inside the `monitor_node` container as the `postgres` user:
    ```bash
    # Show cluster state
    docker exec -u postgres monitor_node pg_autoctl show state

    # Show events
    docker exec -u postgres monitor_node pg_autoctl show events

    # Perform a manual switchover
    docker exec -u postgres monitor_node pg_autoctl perform switchover
    ```

*   **Testing:**
    Refer to standard pg_auto_failover testing procedures:
    -   Verify data replication to standbys.
    -   Test graceful switchovers.
    -   Simulate primary node failure (e.g., `docker stop <primary_container_name>`) and observe automatic failover.
    -   Verify re-integration of a failed node once it's brought back online.

## Cleanup

To remove all components created by the script (containers, volumes, network):

Simply re-run the script. The `cleanup` function at the beginning will handle this.
```bash
./master_setup_pgauto.sh
