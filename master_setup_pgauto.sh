#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # If any command in a pipeline fails, that return code will be used as the return code of the whole pipeline.

# --- Configuration Variables ---
# Docker Image
CUSTOM_IMAGE_NAME="pgautofailover-pgsql16-focal"
CUSTOM_IMAGE_TAG="latest" # You can version your image if you like

# Network
DOCKER_NETWORK_NAME="pgautofailover_cluster_net"

# Monitor Node
MONITOR_CONTAINER_NAME="monitor_node"
MONITOR_HOSTNAME="monitor_node"
MONITOR_DATA_VOL="monitor_data_vol"
MONITOR_PGDATA_SUBDIR="monitor" # Subdirectory for monitor's data within VOL_BASE_PATH
MONITOR_PORT="5430" # Example host port for monitor's PostgreSQL

# Data Nodes (Generic)
NODE_PGDATA_SUBDIR="node"     # Subdirectory for data node's data
DB_NAME="myappdb"             # Database name to create
DB_USER_FOR_PG_AUTOCTL_CREATE="postgres" # The --username for pg_autoctl create postgres

# pgnode1 (Initial Primary)
PGNODE1_CONTAINER_NAME="pgnode1"
PGNODE1_HOSTNAME="pgnode1"
PGNODE1_DATA_VOL="pg1_data_vol"
PGNODE1_PORT="5001"

# pgnode2 (Initial Standby 1)
PGNODE2_CONTAINER_NAME="pgnode2"
PGNODE2_HOSTNAME="pgnode2"
PGNODE2_DATA_VOL="pg2_data_vol"
PGNODE2_PORT="5002"

# pgnode3 (Initial Standby 2)
PGNODE3_CONTAINER_NAME="pgnode3"
PGNODE3_HOSTNAME="pgnode3"
PGNODE3_DATA_VOL="pg3_data_vol"
PGNODE3_PORT="5003"

# Credentials (<<< --- CHANGE THESE TO STRONG, UNIQUE VALUES --- >>>)
PG_AUTOCTL_MONITOR_USER="autoctl_node"
PG_AUTOCTL_MONITOR_PASSWORD="monitorpasswordExtremelySecure18309"
POSTGRES_SUPERUSER_PASSWORD="pg_superuser_VeryStrongP@$$wOrd1!" # For the 'postgres' user

# HBA Configuration & Paths
CLIENT_IP_FOR_HBA="172.19.0.1" # The IP your host (running psql) appears as to the containers
DB_USER_FOR_CLIENT_ACCESS="postgres" # The DB user you want to allow from CLIENT_IP_FOR_HBA
VOL_BASE_PATH_IN_CONTAINER="/pgauto_vol_data" # Base path for data volumes inside container
PG_CTL_PATH_IN_CONTAINER="/usr/lib/postgresql/16/bin/pg_ctl"
ENTRYPOINT_SCRIPT_NAME="docker-entrypoint-pgautofailover.sh"

# --- Helper Functions ---
log_info() {
    echo "INFO: $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

cleanup() {
    log_info "--- Starting Cleanup ---"
    docker stop ${PGNODE3_CONTAINER_NAME} ${PGNODE2_CONTAINER_NAME} ${PGNODE1_CONTAINER_NAME} ${MONITOR_CONTAINER_NAME} >/dev/null 2>&1 || true
    docker rm ${PGNODE3_CONTAINER_NAME} ${PGNODE2_CONTAINER_NAME} ${PGNODE1_CONTAINER_NAME} ${MONITOR_CONTAINER_NAME} >/dev/null 2>&1 || true
    docker volume rm ${PGNODE3_DATA_VOL} ${PGNODE2_DATA_VOL} ${PGNODE1_DATA_VOL} ${MONITOR_DATA_VOL} >/dev/null 2>&1 || true
    docker network rm ${DOCKER_NETWORK_NAME} >/dev/null 2>&1 || true
    # Optionally, remove the image if you want to force a rebuild every time for testing the build process
    # docker rmi "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" >/dev/null 2>&1 || true
    log_info "--- Cleanup Complete ---"
}

create_network_if_not_exists() {
    log_info "Checking for Docker network ${DOCKER_NETWORK_NAME}..."
    if ! docker network inspect ${DOCKER_NETWORK_NAME} >/dev/null 2>&1; then
        log_info "Creating Docker network ${DOCKER_NETWORK_NAME}..."
        docker network create ${DOCKER_NETWORK_NAME}
    else
        log_info "Docker network ${DOCKER_NETWORK_NAME} already exists."
    fi
}

# Function to configure HBA and reload PostgreSQL
# $1: container_name
# $2: pgdata_subdir ("node" or "monitor")
configure_hba_and_reload() {
    local container_name="$1"
    local pgdata_subdir="$2"
    local pgdata_path_in_container="${VOL_BASE_PATH_IN_CONTAINER}/${pgdata_subdir}"
    local hba_conf_path="${pgdata_path_in_container}/pg_hba.conf"
    local hba_rule="host    all             ${DB_USER_FOR_CLIENT_ACCESS}      ${CLIENT_IP_FOR_HBA}/32   trust"

    log_info "Configuring pg_hba.conf for ${container_name} to allow ${DB_USER_FOR_CLIENT_ACCESS} from ${CLIENT_IP_FOR_HBA}..."
    
    # Simple append; cleanup ensures it's fresh on full reruns.
    # For truly idempotent HBA edits in a running system, one would check/replace.
    if docker exec "${container_name}" test -f "${hba_conf_path}"; then
        docker exec "${container_name}" bash -c "echo \"${hba_rule}\" >> \"${hba_conf_path}\""
        log_info "HBA rule added. Reloading PostgreSQL configuration for ${container_name}..."
        docker exec -u postgres "${container_name}" "${PG_CTL_PATH_IN_CONTAINER}" reload -D "${pgdata_path_in_container}"
        log_info "PostgreSQL configuration reloaded for ${container_name}."
    else
        log_info "WARNING: ${hba_conf_path} not found in ${container_name}. Skipping HBA config for this node."
    fi
}

# Function to set postgres superuser password
# $1: container_name
# $2: database_to_connect_to (e.g., myappdb or postgres)
set_postgres_superuser_password() {
    local container_name="$1"
    local db_to_connect="$2"
    
    log_info "Setting 'postgres' superuser password on ${container_name}..."
    # The --auth trust for data nodes or initial monitor setup should allow this
    docker exec -u postgres "${container_name}" psql -d "${db_to_connect}" \
        -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_SUPERUSER_PASSWORD}';"
    log_info "'postgres' superuser password set on ${container_name}."
}


# --- Dockerfile Content and Build ---
# Define the entrypoint script content
ENTRYPOINT_SCRIPT_CONTENT=$(cat <<'EOF'
#!/bin/bash
set -e

PG_USER="${PG_USER:-postgres}"
PG_GROUP="${PG_GROUP:-postgres}"

# ENV vars from Dockerfile expected by this script:
# VOL_BASE_PATH, MONITOR_DATA_SUBDIR, NODE_DATA_SUBDIR
# ACTUAL_MONITOR_PGDATA (calculated as ${VOL_BASE_PATH}/${MONITOR_DATA_SUBDIR})
# ACTUAL_NODE_PGDATA (calculated as ${VOL_BASE_PATH}/${NODE_DATA_SUBDIR})

# This script runs as root because the container starts as root.
if [ -d "${VOL_BASE_PATH}" ]; then
    echo "Entrypoint: Base volume path ${VOL_BASE_PATH} exists."
    # Ensure base path is owned by PG_USER, then specific subdirs.
    # This handles cases where the volume mount point itself might have root ownership.
    if [ "$(stat -c %U "${VOL_BASE_PATH}")" != "${PG_USER}" ]; then
        echo "Entrypoint: Applying chown -R ${PG_USER}:${PG_GROUP} on ${VOL_BASE_PATH}..."
        chown -R "${PG_USER}:${PG_GROUP}" "${VOL_BASE_PATH}"
    fi

    # Ensure specific subdirectories exist and are owned correctly
    # These ACTUAL_*_PGDATA vars must be set as ENV in Dockerfile or passed to container
    if [ -n "${ACTUAL_MONITOR_PGDATA}" ]; then
        mkdir -p "${ACTUAL_MONITOR_PGDATA}"
        chown "${PG_USER}:${PG_GROUP}" "${ACTUAL_MONITOR_PGDATA}"
    fi
    if [ -n "${ACTUAL_NODE_PGDATA}" ]; then
        mkdir -p "${ACTUAL_NODE_PGDATA}"
        chown "${PG_USER}:${PG_GROUP}" "${ACTUAL_NODE_PGDATA}"
    fi
    echo "Entrypoint: Ownership of ${VOL_BASE_PATH} and relevant subdirectories set."
    # ls -ld "${VOL_BASE_PATH}" "${ACTUAL_MONITOR_PGDATA}" "${ACTUAL_NODE_PGDATA}"
else
    echo "Entrypoint: WARNING - Base volume path ${VOL_BASE_PATH} does NOT exist! This might be an issue."
fi

# If the first argument is "pg_autoctl" or "postgres" or other known pg commands,
# switch to PG_USER. Otherwise, execute command as current user (root).
# This allows running other commands like 'bash' as root if needed.
if [ "$1" = 'pg_autoctl' ] || [ "$1" = 'postgres' ] || [ "$1" = 'psql' ] || [ "$1" = 'pg_ctl' ]; then
    echo "Entrypoint: Switching to user ${PG_USER} to execute: $@"
    exec gosu "${PG_USER}" "$@"
else
    echo "Entrypoint: Executing command as current user: $@"
    exec "$@"
fi
EOF
)

# Define the Dockerfile content
DOCKERFILE_CONTENT=$(cat <<EOF
# Use Ubuntu Focal (20.04) as the base image
FROM ubuntu:focal

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8

# 1. Install prerequisites, gosu, and common utils
ENV GOSU_VERSION=1.17
ENV TARGETARCH=amd64 # Adjust if on a different architecture like arm64

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        gnupg \
        ca-certificates \
        lsb-release \
        sudo \
        curl \
        locales \
        vim \
        net-tools \
    && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
       dpkg-reconfigure --frontend=noninteractive locales && \
       update-locale LANG=en_US.UTF-8 && \
    wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/\${GOSU_VERSION}/gosu-\${TARGETARCH}" && \
    wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/\${GOSU_VERSION}/gosu-\${TARGETARCH}.asc" && \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 && \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu && \
    rm /usr/local/bin/gosu.asc && \
    chmod +x /usr/local/bin/gosu && \
    gosu --version && \
    apt-get purge -y --auto-remove wget gnupg && \
    rm -rf /var/lib/apt/lists/*

# 2. Add PostgreSQL APT Repository
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt/ \$(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# 3. Install PostgreSQL 16 and pg_auto_failover packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends postgresql-common && \
    # Prevent auto-creation of a main cluster by the package installation
    sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf && \
    apt-get install -y --no-install-recommends \
        postgresql-16 \
        postgresql-client-16 \
        postgresql-16-pglogical \
        postgresql-16-auto-failover \
    && rm -rf /var/lib/apt/lists/*

# Define base path for volumes and actual PGDATA subdirectories for entrypoint script
ENV VOL_BASE_PATH=${VOL_BASE_PATH_IN_CONTAINER}
ENV MONITOR_DATA_SUBDIR=${MONITOR_PGDATA_SUBDIR}
ENV NODE_DATA_SUBDIR=${NODE_PGDATA_SUBDIR}
# These are used by the entrypoint to chown the correct final PGDATA paths
ENV ACTUAL_MONITOR_PGDATA=\${VOL_BASE_PATH}/\${MONITOR_DATA_SUBDIR}
ENV ACTUAL_NODE_PGDATA=\${VOL_BASE_PATH}/\${NODE_DATA_SUBDIR}

# 4. Create these directory structures within the image (placeholder, real data is on volume)
# Entrypoint will handle permissions on the actual volume at runtime.
RUN mkdir -p \${ACTUAL_MONITOR_PGDATA} \${ACTUAL_NODE_PGDATA} && \
    chown -R postgres:postgres \${VOL_BASE_PATH}

# Add PostgreSQL 16 bin to PATH
ENV PATH="/usr/lib/postgresql/16/bin:\${PATH}"

# Copy entrypoint script
COPY ${ENTRYPOINT_SCRIPT_NAME} /usr/local/bin/${ENTRYPOINT_SCRIPT_NAME}
RUN chmod +x /usr/local/bin/${ENTRYPOINT_SCRIPT_NAME}

ENTRYPOINT ["/usr/local/bin/${ENTRYPOINT_SCRIPT_NAME}"]
# Default command for pg_autoctl nodes
CMD ["pg_autoctl", "run"]
EOF
)

build_docker_image() {
    log_info "Checking if Docker image ${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG} exists..."
    if ! docker image inspect "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" >/dev/null 2>&1; then
        log_info "Image not found. Building ${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}..."
        # Create a temporary directory for the build context
        BUILD_CONTEXT_DIR=$(mktemp -d)
        log_info "Using temporary build context: ${BUILD_CONTEXT_DIR}"

        # Write Dockerfile and entrypoint script to the build context
        echo "${DOCKERFILE_CONTENT}" > "${BUILD_CONTEXT_DIR}/Dockerfile"
        echo "${ENTRYPOINT_SCRIPT_CONTENT}" > "${BUILD_CONTEXT_DIR}/${ENTRYPOINT_SCRIPT_NAME}"
        chmod +x "${BUILD_CONTEXT_DIR}/${ENTRYPOINT_SCRIPT_NAME}" # Make entrypoint executable in context

        # Build the image
        docker build -t "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" "${BUILD_CONTEXT_DIR}"
        
        # Clean up temporary build context directory
        rm -rf "${BUILD_CONTEXT_DIR}"
        log_info "Docker image ${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG} built successfully."
    else
        log_info "Docker image ${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG} already exists."
    fi
}


# --- Main Script Execution ---

cleanup # Clean up previous run
build_docker_image # Build image if it doesn't exist
create_network_if_not_exists

# 1. Start Monitor Node
log_info "--- Starting Monitor Node (${MONITOR_CONTAINER_NAME}) ---"
MONITOR_ACTUAL_PGDATA_IN_CONTAINER="${VOL_BASE_PATH_IN_CONTAINER}/${MONITOR_PGDATA_SUBDIR}"
docker run \
    -d \
    --name "${MONITOR_CONTAINER_NAME}" \
    --hostname "${MONITOR_HOSTNAME}" \
    -e "VOL_BASE_PATH=${VOL_BASE_PATH_IN_CONTAINER}" \
    -e "MONITOR_DATA_SUBDIR=${MONITOR_PGDATA_SUBDIR}" \
    -e "NODE_DATA_SUBDIR=${NODE_PGDATA_SUBDIR}" \
    -e "ACTUAL_MONITOR_PGDATA=${MONITOR_ACTUAL_PGDATA_IN_CONTAINER}" \
    -e "PGDATA=${MONITOR_ACTUAL_PGDATA_IN_CONTAINER}" \
    -v "${MONITOR_DATA_VOL}:${VOL_BASE_PATH_IN_CONTAINER}" \
    -p "${MONITOR_PORT}:5432" \
    --network "${DOCKER_NETWORK_NAME}" \
    "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" \
    pg_autoctl create monitor \
        --pgdata "${MONITOR_ACTUAL_PGDATA_IN_CONTAINER}" \
        --pgctl "${PG_CTL_PATH_IN_CONTAINER}" \
        --hostname "${MONITOR_HOSTNAME}" \
        --ssl-self-signed \
        --auth trust \
        --run

log_info "Waiting for monitor node to initialize (35 seconds)..."
sleep 35
# Optional: Configure HBA for monitor for direct client access
# configure_hba_and_reload "${MONITOR_CONTAINER_NAME}" "${MONITOR_PGDATA_SUBDIR}"


PG_AUTOCTL_MONITOR_URI_ENV_VAR_VALUE="postgresql://${PG_AUTOCTL_MONITOR_USER}:${PG_AUTOCTL_MONITOR_PASSWORD}@${MONITOR_HOSTNAME}:5432/pg_auto_failover?sslmode=prefer"
NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH="${VOL_BASE_PATH_IN_CONTAINER}/${NODE_PGDATA_SUBDIR}" # Common for all data nodes

# --- pgnode1 (Initial Primary) ---
log_info "--- Starting Primary Node (${PGNODE1_CONTAINER_NAME}) ---"
docker run \
    -d \
    --name "${PGNODE1_CONTAINER_NAME}" \
    --hostname "${PGNODE1_HOSTNAME}" \
    -e "VOL_BASE_PATH=${VOL_BASE_PATH_IN_CONTAINER}" \
    -e "MONITOR_DATA_SUBDIR=${MONITOR_PGDATA_SUBDIR}" \
    -e "NODE_DATA_SUBDIR=${NODE_PGDATA_SUBDIR}" \
    -e "ACTUAL_NODE_PGDATA=${NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH}" \
    -e "PGDATA=${NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH}" \
    -e "PG_AUTOCTL_MONITOR=${PG_AUTOCTL_MONITOR_URI_ENV_VAR_VALUE}" \
    -v "${PGNODE1_DATA_VOL}:${VOL_BASE_PATH_IN_CONTAINER}" \
    -p "${PGNODE1_PORT}:5432" \
    --network "${DOCKER_NETWORK_NAME}" \
    "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" \
    pg_autoctl create postgres \
        --pgdata "${NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH}" \
        --pgctl "${PG_CTL_PATH_IN_CONTAINER}" \
        --username "${DB_USER_FOR_PG_AUTOCTL_CREATE}" \
        --dbname "${DB_NAME}" \
        --hostname "${PGNODE1_HOSTNAME}" \
        --ssl-self-signed \
        --auth trust \
        --run

log_info "Waiting for ${PGNODE1_CONTAINER_NAME} to initialize and register (50 seconds)..."
sleep 50
configure_hba_and_reload "${PGNODE1_CONTAINER_NAME}" "${NODE_PGDATA_SUBDIR}"
set_postgres_superuser_password "${PGNODE1_CONTAINER_NAME}" "${DB_NAME}"


# --- pgnode2 (Initial Standby 1) ---
log_info "--- Starting Standby Node 1 (${PGNODE2_CONTAINER_NAME}) ---"
docker run \
    -d \
    --name "${PGNODE2_CONTAINER_NAME}" \
    --hostname "${PGNODE2_HOSTNAME}" \
    -e "VOL_BASE_PATH=${VOL_BASE_PATH_IN_CONTAINER}" \
    -e "MONITOR_DATA_SUBDIR=${MONITOR_PGDATA_SUBDIR}" \
    -e "NODE_DATA_SUBDIR=${NODE_PGDATA_SUBDIR}" \
    -e "ACTUAL_NODE_PGDATA=${NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH}" \
    -e "PGDATA=${NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH}" \
    -e "PG_AUTOCTL_MONITOR=${PG_AUTOCTL_MONITOR_URI_ENV_VAR_VALUE}" \
    -v "${PGNODE2_DATA_VOL}:${VOL_BASE_PATH_IN_CONTAINER}" \
    -p "${PGNODE2_PORT}:5432" \
    --network "${DOCKER_NETWORK_NAME}" \
    "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" \
    pg_autoctl create postgres \
        --pgdata "${NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH}" \
        --pgctl "${PG_CTL_PATH_IN_CONTAINER}" \
        --username "${DB_USER_FOR_PG_AUTOCTL_CREATE}" \
        --dbname "${DB_NAME}" \
        --hostname "${PGNODE2_HOSTNAME}" \
        --ssl-self-signed \
        --auth trust \
        --run

log_info "Waiting for ${PGNODE2_CONTAINER_NAME} to initialize and sync (65 seconds)..."
sleep 65
configure_hba_and_reload "${PGNODE2_CONTAINER_NAME}" "${NODE_PGDATA_SUBDIR}"


# --- pgnode3 (Initial Standby 2) ---
log_info "--- Starting Standby Node 2 (${PGNODE3_CONTAINER_NAME}) ---"
docker run \
    -d \
    --name "${PGNODE3_CONTAINER_NAME}" \
    --hostname "${PGNODE3_HOSTNAME}" \
    -e "VOL_BASE_PATH=${VOL_BASE_PATH_IN_CONTAINER}" \
    -e "MONITOR_DATA_SUBDIR=${MONITOR_PGDATA_SUBDIR}" \
    -e "NODE_DATA_SUBDIR=${NODE_PGDATA_SUBDIR}" \
    -e "ACTUAL_NODE_PGDATA=${NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH}" \
    -e "PGDATA=${NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH}" \
    -e "PG_AUTOCTL_MONITOR=${PG_AUTOCTL_MONITOR_URI_ENV_VAR_VALUE}" \
    -v "${PGNODE3_DATA_VOL}:${VOL_BASE_PATH_IN_CONTAINER}" \
    -p "${PGNODE3_PORT}:5432" \
    --network "${DOCKER_NETWORK_NAME}" \
    "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" \
    pg_autoctl create postgres \
        --pgdata "${NODE_ACTUAL_PGDATA_IN_CONTAINER_PATH}" \
        --pgctl "${PG_CTL_PATH_IN_CONTAINER}" \
        --username "${DB_USER_FOR_PG_AUTOCTL_CREATE}" \
        --dbname "${DB_NAME}" \
        --hostname "${PGNODE3_HOSTNAME}" \
        --ssl-self-signed \
        --auth trust \
        --run

log_info "Waiting for ${PGNODE3_CONTAINER_NAME} to initialize and sync (65 seconds)..."
sleep 65
configure_hba_and_reload "${PGNODE3_CONTAINER_NAME}" "${NODE_PGDATA_SUBDIR}"


# --- Final Status Check ---
log_info "--- Final Cluster Status Check ---"
sleep 25 # Extra time for all states to fully settle
log_info "Running 'docker ps' to show containers:"
docker ps -a --filter "name=${MONITOR_CONTAINER_NAME}" --filter "name=${PGNODE1_CONTAINER_NAME}" --filter "name=${PGNODE2_CONTAINER_NAME}" --filter "name=${PGNODE3_CONTAINER_NAME}"
log_info "Running 'pg_autoctl show state' on monitor:"
docker exec -u postgres "${MONITOR_CONTAINER_NAME}" pg_autoctl show state

log_info ""
log_info "--------------------------------------------------------------------"
log_info "pg_auto_failover COMPLETE END-TO-END SETUP SCRIPT FINISHED!"
log_info "--------------------------------------------------------------------"
log_info "Primary should be ${PGNODE1_CONTAINER_NAME} on port ${PGNODE1_PORT}."
log_info "Connect as user '${DB_USER_FOR_CLIENT_ACCESS}' (e.g., 'postgres')."
log_info "The 'postgres' user password is now '${POSTGRES_SUPERUSER_PASSWORD}' on all nodes."
log_info "Example psql connection to initial primary:"
log_info "psql \"postgresql://${DB_USER_FOR_CLIENT_ACCESS}:${POSTGRES_SUPERUSER_PASSWORD}@localhost:${PGNODE1_PORT}/${DB_NAME}\""
log_info "Remember: HBA rule for ${CLIENT_IP_FOR_HBA} uses 'trust', so password might not be strictly needed for psql from host."
log_info "--------------------------------------------------------------------"