#!/bin/bash

# Fixed K3s startup script to resolve the "chmod kine.sock: invalid argument" error

set -euo pipefail

# Configuration
INSTALL_DIR="${HOME}/.k3s-demo"
K3S_BIN_DIR="${INSTALL_DIR}/bin"
K3S_CONFIG_DIR="${INSTALL_DIR}/config"
K3S_DATA_DIR="${HOME}/.rancher/k3s"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*${NC}" >&2
}

# Clean up existing container and data
cleanup_k3s() {
    log_info "Cleaning up existing K3s container and problematic data..."
    
    # Stop and remove container
    podman rm -f k3s-server >/dev/null 2>&1 || true
    
    # Remove problematic socket files and kine data
    rm -rf "${K3S_DATA_DIR}/server/kine.sock" 2>/dev/null || true
    rm -rf "${K3S_DATA_DIR}/server/db" 2>/dev/null || true
    
    # Ensure directories exist with proper permissions
    mkdir -p "${K3S_CONFIG_DIR}" "${K3S_DATA_DIR}"
    chmod 755 "${K3S_CONFIG_DIR}" "${K3S_DATA_DIR}"
}

# Start K3s with fixed configuration - bypass kine socket issues
start_k3s_fixed() {
    log_info "Starting K3s with socket-bypass configuration..."
    
    # Create a completely separate data directory to avoid any existing state
    local clean_data_dir="${K3S_DATA_DIR}-clean"
    rm -rf "${clean_data_dir}"
    mkdir -p "${clean_data_dir}"
    
    # Start K3s with embedded etcd disabled and use direct SQLite
    podman run -d --name k3s-server \
        --privileged \
        --restart=unless-stopped \
        --tmpfs /tmp:noexec,nosuid,size=100m \
        --tmpfs /run:noexec,nosuid,size=100m \
        --tmpfs /var/run:noexec,nosuid,size=100m \
        -v "${clean_data_dir}:/var/lib/rancher/k3s" \
        -v "${K3S_CONFIG_DIR}:/etc/rancher/k3s" \
        -e K3S_KUBECONFIG_OUTPUT=/etc/rancher/k3s/kubeconfig.yaml \
        -e K3S_KUBECONFIG_MODE=644 \
        -e K3S_NODE_NAME=k3s-demo \
        -p 6443:6443 \
        -p 8080:8080 \
        docker.io/rancher/k3s:v1.29.4-k3s1 \
        server \
        --disable=traefik \
        --data-dir=/var/lib/rancher/k3s \
        --write-kubeconfig-mode=644 \
        --datastore-endpoint="sqlite:///var/lib/rancher/k3s/server/db/state.db?cache=shared&_fk=1" \
        --etcd-disable-snapshots \
        --kube-apiserver-arg=bind-address=0.0.0.0 \
        --kube-apiserver-arg=advertise-address=127.0.0.1
    
    local result=$?
    if [ $result -ne 0 ]; then
        log_error "Failed to start K3s container"
        return 1
    fi
    
    log_info "K3s container started successfully"
}

# Alternative approach using host networking (if the above doesn't work)
start_k3s_host_network() {
    log_info "Trying alternative approach with host networking..."
    
    podman rm -f k3s-server >/dev/null 2>&1 || true
    
    podman run -d --name k3s-server \
        --privileged \
        --restart=unless-stopped \
        --network=host \
        --tmpfs /tmp \
        --tmpfs /run \
        --tmpfs /var/run \
        -v "${K3S_DATA_DIR}:/var/lib/rancher/k3s" \
        -v "${K3S_CONFIG_DIR}:/etc/rancher/k3s" \
        -e K3S_KUBECONFIG_OUTPUT=/etc/rancher/k3s/kubeconfig.yaml \
        -e K3S_KUBECONFIG_MODE=644 \
        -e K3S_NODE_NAME=k3s-demo \
        docker.io/rancher/k3s:v1.29.4-k3s1 \
        server \
        --disable=traefik \
        --data-dir=/var/lib/rancher/k3s \
        --write-kubeconfig-mode=644
        
    log_info "K3s container started with host networking"
}

# Wait for K3s to be ready
wait_for_k3s() {
    log_info "Waiting for K3s to become ready..."
    
    for i in {1..3}; do
        if podman exec k3s-server kubectl get nodes >/dev/null 2>&1; then
            log_info "K3s is ready!"
            podman exec k3s-server kubectl get nodes
            return 0
        fi
        
        if [ $((i % 5)) -eq 0 ]; then
            log_info "Still waiting... (attempt $i/30)"
            # Show container status
            podman ps --filter name=k3s-server --format "table {{.Names}}\t{{.Status}}"
        fi
        
        sleep 10
    done
    
    log_error "K3s failed to become ready after 5 minutes"
    log_info "Container logs:"
    podman logs --tail 20 k3s-server
    return 1
}

# Check if kubeconfig was created
check_kubeconfig() {
    log_info "Checking kubeconfig..."
    
    if [ -f "${K3S_CONFIG_DIR}/kubeconfig.yaml" ]; then
        log_info "Kubeconfig found and copying to standard location..."
        
        # Also copy to the bin directory for convenience
        cp "${K3S_CONFIG_DIR}/kubeconfig.yaml" "${K3S_BIN_DIR}/../kubeconfig"
        
        # Test connectivity
        if [ -f "${K3S_BIN_DIR}/kubectl" ]; then
            export KUBECONFIG="${K3S_CONFIG_DIR}/kubeconfig.yaml"
            "${K3S_BIN_DIR}/kubectl" get nodes
        fi
        
        return 0
    else
        log_error "Kubeconfig not found at ${K3S_CONFIG_DIR}/kubeconfig.yaml"
        return 1
    fi
}

# Main function
main() {
    log_info "Starting K3s with fixed configuration..."
    
    # Clean up any existing problematic state
    cleanup_k3s
    
    # Try the first approach
    if start_k3s_fixed; then
        log_info "Waiting for container to initialize..."
        sleep 20
        
        if wait_for_k3s && check_kubeconfig; then
            log_info "✅ K3s is now running successfully!"
            exit 0
        else
            log_info "First approach failed, trying alternative..."
        fi
    fi
    
    # Try alternative approach with host networking
    log_info "Trying alternative approach..."
    cleanup_k3s
    
    if start_k3s_host_network; then
        sleep 20
        
        if wait_for_k3s && check_kubeconfig; then
            log_info "✅ K3s is now running successfully with host networking!"
            exit 0
        fi
    fi
    
    log_error "❌ All approaches failed. Please check the logs above."
    log_info "Container logs:"
    podman logs k3s-server 2>&1 || true
    exit 1
}

main "$@"