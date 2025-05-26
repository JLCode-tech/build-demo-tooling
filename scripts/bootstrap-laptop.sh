#!/bin/bash

# bootstrap-laptop.sh
# Sets up a K3s management cluster on a MacBook Pro M1 using Podman for a multi-tenant demo environment.
# Compatible with arm64 architecture, runs without sudo, includes optional MetalLB support, and configures ArgoCD to watch a remote GitOps repo.
# Idempotent: Can be run multiple times to ensure consistent state or apply updates.
# Uses GitHub fine-grained personal access token (PAT) for HTTPS access to https://github.com/JLCode-tech/build-demo-tooling.git.
# Avoids creating files in the build-demo-tooling repository and adds .gitignore entries for setup artifacts.
# Relaxes kubectl version requirement to v1.28.x-v1.33.x for flexibility.
# Runs K3s as a Podman container on macOS to avoid systemd/openrc dependency.
# Ensures Podman machine is initialized and running, with dynamic socket detection.

set -euo pipefail

# --- Configuration Variables ---
# Installation paths and versions
INSTALL_DIR="${HOME}/.k3s-demo"
K3S_VERSION="${K3S_VERSION:-v1.29.4-k3s1}" # Stable version as of May 2025
HELM_VERSION="v3.15.4" # Stable Helm version
KUBECTL_VERSION="v1.29.4" # Preferred kubectl version
ARGOCD_VERSION="2.12.5" # ArgoCD Helm chart version
KAMAJI_VERSION="0.5.0" # Kamaji Helm chart version
CROSSPLANE_VERSION="1.16.0" # Crossplane Helm chart version
METALLB_VERSION="0.14.5" # MetalLB Helm chart version
SVELTOS_VERSION="0.24.0" # Sveltos Helm chart version
GITOPS_REPO_DIR="${INSTALL_DIR}/demo-environment-gitops"
LOG_FILE="/tmp/bootstrap-k3s-$(date +%s).log" # Temporary log file

# MetalLB configuration
INSTALL_METALLB="${INSTALL_METALLB:-false}" # Set to true to enable MetalLB, false for NodePort
METALLB_IP_POOL="${METALLB_IP_POOL:-192.168.1.240/28}" # IP range for MetalLB LoadBalancer

# K3s specific settings for non-root Podman
K3S_BIN_DIR="${INSTALL_DIR}/bin"
K3S_CONFIG_DIR="${INSTALL_DIR}/config"
K3S_DATA_DIR="${HOME}/.rancher/k3s"
K3S_EXEC="server --disable=traefik --disable-network-policy --flannel-backend=vxlan --data-dir=${K3S_DATA_DIR}"
#K3S_EXEC="server --disable=traefik --data-dir=${K3S_DATA_DIR} --kubelet-arg=provider-id=host://localhost"

# ArgoCD GitOps configuration
ARGOCD_APP_NAME="gitops-demo"
ARGOCD_GITOPS_PATH="kamaji-clusters" # Path to watch in the Git repo
GITOPS_REMOTE_URL="https://github.com/JLCode-tech/build-demo-tooling.git"
GITOPS_BRANCH="main"

# --- Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Logging Functions ---
log_info() {
    echo -e "${GREEN}[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*${NC}" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*${NC}" | tee -a "${LOG_FILE}" >&2
    exit 1
}

log_warn() {
    echo -e "${YELLOW}[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $*${NC}" | tee -a "${LOG_FILE}" >&2
}

# --- Error Handling ---
check_command() {
    command -v "$1" >/dev/null 2>&1 || log_error "Required command '$1' not found. Please install it."
}

check_podman() {
    podman --version >/dev/null 2>&1 || log_error "Podman is required but not installed. Install via 'brew install podman'."
    local podman_version
    podman_version=$(podman --version | awk '{print $3}')
    log_info "Podman version: ${podman_version}"
    if [[ "${podman_version}" < "4.0.0" ]]; then
        log_error "Podman version ${podman_version} is too old. Please upgrade to 4.0.0 or newer with 'brew upgrade podman'."
    fi

    # Check Podman machine initialization
    if ! podman machine list --format '{{.Name}}' 2>/dev/null | grep -q "podman-machine-default"; then
        log_info "No Podman machine found. Initializing podman-machine-default with cgroup support..."
        podman machine init --cpus 5 --memory 2048 --disk-size 100 --cgroup-manager cgroupfs >/dev/null 2>&1 || log_error "Failed to initialize Podman machine. Run 'podman machine init --cgroup-manager cgroupfs' manually and check for errors."
    fi

    # Check Podman machine status
    if ! podman machine list --format '{{.Running}}' 2>/dev/null | grep -q true; then
        log_info "Podman machine is not running. Starting podman-machine-default..."
        podman machine start >/dev/null 2>&1 || log_error "Failed to start Podman machine. Run 'podman machine start' manually and check for errors."
        sleep 5
    fi

    # Verify and set Podman connection
    log_info "Checking Podman connections..."
    podman system connection list 2>&1 | tee -a "${LOG_FILE}"
    if ! podman system connection list --format '{{.Name}}' 2>/dev/null | grep -q "podman-machine-default"; then
        log_error "No podman-machine-default connection found. Run 'podman system connection list' and set default with 'podman system connection default podman-machine-default'."
    fi
    podman system connection default podman-machine-default >/dev/null 2>&1 || log_error "Failed to set podman-machine-default as default connection."

    # Get Podman socket path dynamically with retries
    local podman_socket=""
    local retries=3
    local wait=3
    for ((i=1; i<=retries; i++)); do
        podman_socket=$(podman machine inspect podman-machine-default --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || echo "")
        if [ -n "${podman_socket}" ] && [ -S "${podman_socket}" ]; then
            log_info "Podman socket found at ${podman_socket}"
            break
        fi
        log_info "Attempt $i/$retries: Podman socket not found. Starting system service and retrying in ${wait}s..."
        podman system service --timeout=0 >/dev/null 2>&1 || podman system service >/dev/null 2>&1 &
        sleep ${wait}
        if [ $i -eq ${retries} ]; then
            podman_socket="/var/folders/5n/03y3qk412l10xzcylyd71t9c0000gp/T/podman/podman-machine-default-api.sock"
            if [ ! -S "${podman_socket}" ]; then
                log_error "Podman socket ${podman_socket} not found after retries. Ensure Podman machine is running ('podman machine start'), verify connection ('podman system connection list'), and check 'podman machine inspect podman-machine-default'."
            fi
        fi
    done
    log_info "Podman socket confirmed at ${podman_socket}"
    PODMAN_SOCKET="${podman_socket}"
}

check_git_credentials() {
    log_info "Checking Git credentials for ${GITOPS_REMOTE_URL}..."
    if ! git config --global credential.helper | grep -q "osxkeychain"; then
        log_info "Configuring macOS keychain for Git credentials..."
        git config --global credential.helper osxkeychain || log_error "Failed to configure Git credential helper."
    fi
    if ! git ls-remote "${GITOPS_REMOTE_URL}" >/dev/null 2>&1; then
        log_error "Failed to access ${GITOPS_REMOTE_URL}. Ensure you have a fine-grained personal access token (PAT) with write access.\n" \
                  "Steps to create a PAT:\n" \
                  "1. Go to https://github.com/settings/tokens?type=beta and click 'Generate new token'.\n" \
                  "2. Select 'Fine-grained token', name it, and set permissions: 'Contents' (read and write) for repository access.\n" \
                  "3. Generate the token and copy it.\n" \
                  "4. Run the script again; when prompted, enter your GitHub username and the PAT as the password.\n" \
                  "5. The PAT will be cached in macOS keychain for future use."
    fi
}

# --- Check Existing Resources ---
check_existing_resources() {
log_info "Checking existing resources for idempotency..."
    if [ -f "${K3S_BIN_DIR}/kubectl" ] && [ -f "${K3S_CONFIG_DIR}/kubeconfig.yaml" ]; then
        if "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get nodes >/dev/null 2>&1; then
            log_info "K3s is already running."
        else
            log_warn "K3s kubectl found but cluster is not running. Attempting to start..."
            # Attempt to restart Podman machine to ensure cgroup support
            podman machine stop >/dev/null 2>&1
            podman machine start >/dev/null 2>&1 || log_error "Failed to restart Podman machine."
            sleep 5
        fi
    fi
    if command -v kubectl >/dev/null 2>&1; then
        local kubectl_version
        kubectl_version=$(kubectl version --client --output=json | grep -o '"gitVersion": "[^"]*"' | cut -d'"' -f4)
        if [[ "${kubectl_version}" =~ ^v1\.(28|29|30|31|32|33)\. ]]; then
            log_info "kubectl ${kubectl_version} is compatible (v1.28.x-v1.33.x)."
        else
            log_warn "kubectl ${kubectl_version} is not within v1.28.x-v1.33.x. May cause compatibility issues."
        fi
    fi
    if command -v helm >/dev/null 2>&1 && helm version --short | grep -q "${HELM_VERSION}"; then
        log_info "Helm ${HELM_VERSION} is already installed."
    fi
    if command -v helm >/dev/null 2>&1 && [ -f "${K3S_CONFIG_DIR}/kubeconfig.yaml" ]; then
        helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q kamaji && log_info "Kamaji Helm release already exists."
        helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q argocd && log_info "ArgoCD Helm release already exists."
        helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q crossplane && log_info "Crossplane Helm release already exists."
        [ "${INSTALL_METALLB}" = true ] && helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q metallb && log_info "MetalLB Helm release already exists."
        helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q sveltos && log_info "Sveltos Helm release already exists."
    fi
    if [ -d "${GITOPS_REPO_DIR}/.git" ]; then
        log_info "GitOps repository already exists at ${GITOPS_REPO_DIR}."
    fi
    if [ -f "${K3S_CONFIG_DIR}/kubeconfig.yaml" ] && "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get application -n argocd "${ARGOCD_APP_NAME}" >/dev/null 2>&1; then
        log_info "ArgoCD Application '${ARGOCD_APP_NAME}' already exists."
    fi
}

# --- Setup Directories ---
setup_directories() {
    log_info "Creating installation directories..."
    mkdir -p "${INSTALL_DIR}" "${K3S_BIN_DIR}" "${K3S_CONFIG_DIR}" "${K3S_DATA_DIR}" || log_error "Failed to create directories."
    chmod 700 "${K3S_CONFIG_DIR}" "${K3S_DATA_DIR}" || log_error "Failed to set directory permissions."
    [ -d "${GITOPS_REPO_DIR}" ] && chmod -R u+rwX "${GITOPS_REPO_DIR}" || true
}

# --- Install Dependencies ---
install_dependencies() {
    log_info "Checking and installing dependencies..."
    check_command brew
    for cmd in curl git; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_info "Installing ${cmd} via Homebrew..."
            brew install "${cmd}" || log_error "Failed to install ${cmd}."
        fi
    done
    if ! command -v kubectl >/dev/null 2>&1; then
        log_info "Installing kubectl ${KUBECTL_VERSION}..."
        curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/arm64/kubectl" || log_error "Failed to download kubectl."
        chmod +x kubectl
        mkdir -p "${K3S_BIN_DIR}" || log_error "Failed to create ${K3S_BIN_DIR}."
        mv kubectl "${K3S_BIN_DIR}/kubectl" || log_error "Failed to install kubectl."
    else
        local kubectl_version
        kubectl_version=$(kubectl version --client --output=json | grep -o '"gitVersion": "[^"]*"' | cut -d'"' -f4)
        if [[ ! "${kubectl_version}" =~ ^v1\.(28|29|30|31|32|33)\. ]]; then
            log_info "Installing kubectl ${KUBECTL_VERSION} due to incompatible version ${kubectl_version}..."
            curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/arm64/kubectl" || log_error "Failed to download kubectl."
            chmod +x kubectl
            mkdir -p "${K3S_BIN_DIR}" || log_error "Failed to create ${K3S_BIN_DIR}."
            mv kubectl "${K3S_BIN_DIR}/kubectl" || log_error "Failed to install kubectl."
        else
            log_info "kubectl ${kubectl_version} is already installed at $(which kubectl)."
        fi
    fi
    if ! command -v helm >/dev/null 2>&1; then
        log_info "Installing Helm ${HELM_VERSION}..."
        curl -LO "https://get.helm.sh/helm-${HELM_VERSION}-darwin-arm64.tar.gz" || log_error "Failed to download Helm."
        tar -zxvf helm-${HELM_VERSION}-darwin-arm64.tar.gz
        mkdir -p "${K3S_BIN_DIR}" || log_error "Failed to create ${K3S_BIN_DIR}."
        mv darwin-arm64/helm "${K3S_BIN_DIR}/helm" || log_error "Failed to install Helm."
        rm -rf helm-${HELM_VERSION}-darwin-arm64.tar.gz darwin-arm64
    else
        local helm_version
        helm_version=$(helm version --short | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "")
        if [[ "${helm_version}" != "${HELM_VERSION}" ]]; then
            log_info "Installing Helm ${HELM_VERSION} due to version mismatch (found ${helm_version})..."
            curl -LO "https://get.helm.sh/helm-${HELM_VERSION}-darwin-arm64.tar.gz" || log_error "Failed to download Helm."
            tar -zxvf helm-${HELM_VERSION}-darwin-arm64.tar.gz
            mkdir -p "${K3S_BIN_DIR}" || log_error "Failed to create ${K3S_BIN_DIR}."
            mv darwin-arm64/helm "${K3S_BIN_DIR}/helm" || log_error "Failed to install Helm."
            rm -rf helm-${HELM_VERSION}-darwin-arm64.tar.gz darwin-arm64
        else
            log_info "Helm ${helm_version} is already installed at $(which helm)."
        fi
    fi
}

# --- Install K3s with Podman ---
install_k3s() {
    if [ -f "${K3S_BIN_DIR}/kubectl" ] && [ -f "${K3S_CONFIG_DIR}/kubeconfig.yaml" ] && "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get nodes >/dev/null 2>&1; then
        log_info "K3s is already installed and running. Skipping installation."
        return
    fi
    log_info "Installing K3s ${K3S_VERSION} as a Podman container..."
    export PATH="${K3S_BIN_DIR}:${PATH}"
    mkdir -p "${K3S_CONFIG_DIR}" "${K3S_DATA_DIR}" || log_error "Failed to create K3s directories."
    chmod 700 "${K3S_CONFIG_DIR}" "${K3S_DATA_DIR}"
    if podman ps -a --format '{{.Names}}' | grep -q "^k3s-server$"; then
        log_info "Removing existing K3s container..."
        podman rm -f k3s-server >/dev/null 2>&1
    fi
    podman rm -f k3s-server
    rm -rf ~/.rancher/k3s/*
    podman run -d --name k3s-server \
        --privileged \
        --cgroupns=host \
        -v "${K3S_DATA_DIR}:/var/lib/rancher/k3s" \
        -v "${K3S_CONFIG_DIR}:/etc/rancher/k3s" \
        -e K3S_KUBECONFIG_OUTPUT=/etc/rancher/k3s/kubeconfig.yaml \
        -e K3S_KUBECONFIG_MODE=644 \
        -p 6443:6443 \
        docker.io/rancher/k3s:${K3S_VERSION} \
        ${K3S_EXEC}|| log_error "Failed to start K3s container."
    sleep 30
    if [ ! -f "${K3S_CONFIG_DIR}/kubeconfig.yaml" ]; then
        log_error "Kubeconfig not found at ${K3S_CONFIG_DIR}/kubeconfig.yaml."
    fi
    sed -i '' "s/0.0.0.0:6443/127.0.0.1:6443/g" "${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "Failed to update kubeconfig."
    chmod 600 "${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "Failed to set kubeconfig permissions."
    if ! "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get nodes >/dev/null 2>&1; then
        log_info "K3s container status:"
        podman ps -a --filter name=k3s-server | tee -a "${LOG_FILE}"
        log_info "K3s container logs:"
        podman logs k3s-server 2>&1 | tee -a "${LOG_FILE}"
        log_error "K3s cluster not running. Check container logs above and ${LOG_FILE}."
    fi
    log_info "K3s installed successfully."
}

# --- Setup Helm Repositories ---
setup_helm_repos() {
    log_info "Adding Helm repositories..."
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || log_error "Failed to add Argo Helm repo."
    helm repo add crossplane https://charts.crossplane.io/stable >/dev/null 2>&1 || log_error "Failed to add Crossplane Helm repo."
    helm repo add clastix https://clastix.github.io/charts >/dev/null 2>&1 || log_error "Failed to add Clastix (Kamaji) Helm repo."
    helm repo add projectsveltos https://projectsveltos.github.io/helm-charts >/dev/null 2>&1 || log_error "Failed to add Sveltos Helm repo."
    if [ "${INSTALL_METALLB}" = true ]; then
        helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || log_error "Failed to add MetalLB Helm repo."
    fi
    helm repo update >/dev/null 2>&1 || log_error "Failed to update Helm repos."
}

# --- Install Tools ---
install_calico() {
    kubectl --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" apply -f https://docs.projectcalico.org/manifests/calico.yaml
    sleep 60
}

install_kamaji() {
    log_info "Installing or updating Kamaji..."
    helm upgrade --install kamaji clastix/kamaji --version "${KAMAJI_VERSION}" -n kamaji --create-namespace \
        --set controller.manager.replicas=1 \
        --set controller.manager.resources.requests.cpu="100m" \
        --set controller.manager.resources.requests.memory="128Mi" \
        --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "Kamaji installation failed."
}

install_argocd() {
    log_info "Installing or updating ArgoCD..."
    local service_type="NodePort"
    if [ "${INSTALL_METALLB}" = true ]; then
        service_type="LoadBalancer"
    fi
    helm upgrade --install argocd argo/argo-cd --version "${ARGOCD_VERSION}" -n argocd --create-namespace \
        --set crds.install=true \
        --set server.service.type="${service_type}" \
        --set server.resources.requests.cpu="50m" \
        --set server.resources.requests.memory="64Mi" \
        --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "ArgoCD installation failed."
    local admin_password
    admin_password=$("${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null) || log_warn "Failed to retrieve ArgoCD admin password. Secret may not be ready yet."
    if [ -n "${admin_password}" ]; then
        log_info "ArgoCD admin credentials: username=admin, password=${admin_password}"
    fi
    if [ "${INSTALL_METALLB}" = true ]; then
        log_info "ArgoCD is using LoadBalancer with MetalLB. Check external IP with:"
        log_info "  kubectl --kubeconfig=${K3S_CONFIG_DIR}/kubeconfig.yaml -n argocd get svc argocd-server"
    else
        local node_port
        node_port=$("${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" -n argocd get svc argocd-server -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null) || log_warn "Failed to retrieve ArgoCD NodePort. Service may not be ready yet."
        [ -n "${node_port}" ] && log_info "ArgoCD is using NodePort. Access it at http://localhost:${node_port}"
    fi
}

install_crossplane() {
    log_info "Installing or updating Crossplane..."
    helm upgrade --install crossplane crossplane/crossplane --version "${CROSSPLANE_VERSION}" -n crossplane-system --create-namespace \
        --set resourcesCrossplane.requests.cpu="100m" \
        --set resourcesCrossplane.requests.memory="128Mi" \
        --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "Crossplane installation failed."
}

install_metallb() {
    if [ "${INSTALL_METALLB}" != true ]; then
        log_info "Skipping MetalLB installation (INSTALL_METALLB=false)."
        return
    fi
    log_info "Installing or updating MetalLB..."
    helm upgrade --install metallb metallb/metallb --version "${METALLB_VERSION}" -n metallb-system --create-namespace \
        --set controller.resources.requests.cpu="50m" \
        --set controller.resources.requests.memory="64Mi" \
        --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "MetalLB installation failed."
    log_info "Applying MetalLB IP pool: ${METALLB_IP_POOL}"
    cat <<EOF | "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_IP_POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default
EOF
}

install_sveltos() {
    log_info "Installing or updating Sveltos..."
    helm upgrade --install sveltos projectsveltos/sveltos --version "${SVELTOS_VERSION}" -n projectsveltos --create-namespace \
        --set resources.requests.cpu="50m" \
        --set resources.requests.memory="64Mi" \
        --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "Sveltos installation failed."
}

# --- Setup GitOps Repository Structure ---
setup_gitops_repo() {
    log_info "Setting up GitOps repository for ${GITOPS_REMOTE_URL}..."
    check_git_credentials
    if [ -d "${GITOPS_REPO_DIR}/.git" ]; then
        log_info "GitOps repository already exists at ${GITOPS_REPO_DIR}. Pulling latest changes..."
        cd "${GITOPS_REPO_DIR}"
        git fetch origin
        git checkout "${GITOPS_BRANCH}" || git checkout -b "${GITOPS_BRANCH}"
        git pull origin "${GITOPS_BRANCH}" --rebase || log_warn "No changes pulled from ${GITOPS_REMOTE_URL}."
    else
        if git ls-remote "${GITOPS_REMOTE_URL}" >/dev/null 2>&1; then
            log_info "Cloning existing repository from ${GITOPS_REMOTE_URL}..."
            mkdir -p "${INSTALL_DIR}"
            git clone "${GITOPS_REMOTE_URL}" "${GITOPS_REPO_DIR}" || log_error "Failed to clone ${GITOPS_REMOTE_URL}."
            cd "${GITOPS_REPO_DIR}"
            git checkout "${GITOPS_BRANCH}" || git checkout -b "${GITOPS_BRANCH}"
        else
            log_info "Initializing new repository at ${GITOPS_REPO_DIR}..."
            mkdir -p "${GITOPS_REPO_DIR}"
            cd "${GITOPS_REPO_DIR}"
            git init
            git remote add origin "${GITOPS_REMOTE_URL}" || log_error "Failed to set remote origin ${GITOPS_REMOTE_URL}."
            git checkout -b "${GITOPS_BRANCH}"
        fi
    fi
    mkdir -p documentation infra-setup/{metal3,metallb,crossplane-provider} kamaji-clusters base-addons demos/{f5-bnk,f5-spk,other-products} clusters-apps/{example-app1,example-app2} scripts || log_error "Failed to create GitOps repo structure."
    if [ ! -f .gitignore ]; then
        cat <<EOF > .gitignore
# Ignore K3s setup artifacts
${INSTALL_DIR#/Users/*/}
*.log
EOF
    fi
    if [ ! -f README.md ]; then
        cat <<EOF > README.md
# Multi-Tenant Kubernetes Demo Platform
This repository provides a GitOps-driven platform for managing multiple Kubernetes tenant clusters using a k3s management cluster. It supports rapid deployments of F5 BIG-IP Next Kubernetes (BNK) and Service Proxy Kubernetes (SPK) for demos.
See documentation/ for quickstart guides.
EOF
    fi
    for env in laptop onprem cloud; do
        if [ ! -f "documentation/quickstart-${env}.md" ]; then
            echo "# Quickstart for ${env} environment" > "documentation/quickstart-${env}.md"
        fi
    done
    if [ ! -f kamaji-clusters/tenant-laptop-demo.yaml ]; then
        cat <<EOF > kamaji-clusters/tenant-laptop-demo.yaml
apiVersion: kamaji.clastix.io/v1alpha1
kind: TenantControlPlane
metadata:
  name: tenant-laptop-demo
  namespace: default
spec:
  kubernetesVersion: "v1.29.0"
  replicas: 1
  serviceType: ${INSTALL_METALLB:+LoadBalancer}${INSTALL_METALLB:-NodePort}
EOF
    fi
    if [ ! -f scripts/bootstrap-laptop.sh ]; then
        cat <<EOF > scripts/bootstrap-laptop.sh
#!/bin/bash
# Placeholder for bootstrap-laptop.sh
echo "Bootstrap script for laptop environment"
EOF
        chmod +x scripts/bootstrap-laptop.sh
    fi
    git add . >/dev/null 2>&1
    if git diff --cached --quiet; then
        log_info "No changes to commit in GitOps repository."
    else
        git commit -m "Update GitOps repository structure" || log_warn "No changes to commit."
        git push -u origin "${GITOPS_BRANCH}" || log_error "Failed to push to ${GITOPS_REMOTE_URL}. Ensure your PAT is cached in macOS keychain."
        log_info "GitOps repository updated and pushed to ${GITOPS_REMOTE_URL}."
    fi
    cd - >/dev/null
}

# --- Configure ArgoCD to Watch GitOps Repository ---
configure_argocd_gitops() {
    log_info "Configuring ArgoCD to watch remote GitOps repository at ${GITOPS_REMOTE_URL}..."
    if "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get application -n argocd "${ARGOCD_APP_NAME}" >/dev/null 2>&1; then
        log_info "ArgoCD Application '${ARGOCD_APP_NAME}' already exists. Updating configuration..."
    fi
    cat <<EOF | "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGOCD_APP_NAME}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GITOPS_REMOTE_URL}
    path: ${ARGOCD_GITOPS_PATH}
    targetRevision: ${GITOPS_BRANCH}
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
    log_info "ArgoCD Application '${ARGOCD_APP_NAME}' configured to watch ${GITOPS_REMOTE_URL}/${ARGOCD_GITOPS_PATH} on branch ${GITOPS_BRANCH}."
}

# --- Main Execution ---
main() {
    log_info "Starting bootstrap-laptop.sh on MacBook Pro M1 (MetalLB: ${INSTALL_METALLB})..."
    check_existing_resources
    check_podman
    install_dependencies
    setup_directories
    install_k3s
    setup_helm_repos
    install_calico
    install_kamaji
    install_argocd
    install_crossplane
    install_metallb
    install_sveltos
    setup_gitops_repo
    configure_argocd_gitops
    log_info "Bootstrap completed successfully! K3s cluster is running, tools are installed, and GitOps repo is set up at ${GITOPS_REPO_DIR}."
    log_info "Kubeconfig is available at ${K3S_CONFIG_DIR}/kubeconfig.yaml"
    log_info "Logs are available at ${LOG_FILE}"
    local admin_password
    admin_password=$("${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null) || log_warn "Failed to retrieve ArgoCD admin password. Secret may not be ready yet."
    if [ -n "${admin_password}" ]; then
        log_info "ArgoCD admin credentials: username=admin, password=${admin_password}"
    fi
    if [ "${INSTALL_METALLB}" = true ]; then
        log_info "ArgoCD is configured with LoadBalancer. Check external IP with:"
        log_info "  kubectl --kubeconfig=${K3S_CONFIG_DIR}/kubeconfig.yaml -n argocd get svc argocd-server"
    else
        local node_port
        node_port=$("${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" -n argocd get svc argocd-server -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null) || log_warn "Failed to retrieve ArgoCD NodePort. Service may not be ready yet."
        [ -n "${node_port}" ] && log_info "ArgoCD is using NodePort. Access it at http://localhost:${node_port}"
    fi
    log_info "ArgoCD is watching ${GITOPS_REMOTE_URL}/${ARGOCD_GITOPS_PATH} (branch: ${GITOPS_BRANCH}) for tenant cluster definitions."
    log_info "Next steps: Add F5 BNK/SPK manifests to ${GITOPS_REPO_DIR}/demos/ and push to ${GITOPS_REMOTE_URL}."
}

# Run main with error handling
main || log_error "Bootstrap failed. Check ${LOG_FILE} for details."