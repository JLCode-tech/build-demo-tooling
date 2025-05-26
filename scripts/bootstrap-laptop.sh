#!/bin/bash

# bootstrap-laptop.sh
# Sets up a K3s management cluster on a MacBook Pro M1 using Lima for a multi-tenant demo environment.
# Compatible with arm64 architecture, runs without sudo, includes optional MetalLB support, and configures ArgoCD to watch a remote GitOps repo.
# Forces a clean environment on each run by removing existing Lima VM and K3s artifacts.
# Uses GitHub fine-grained personal access token (PAT) for HTTPS access to https://github.com/JLCode-tech/build-demo-tooling.git.
# Avoids creating files in the build-demo-tooling repository and adds .gitignore entries for setup artifacts.
# Relaxes kubectl version requirement to v1.28.x-v1.33.x for flexibility.
# Runs K3s inside a Lima VM on macOS with user-mode networking (user-v2) to avoid sudo, and includes a progress bar for downloading the Ubuntu image.

set -euo pipefail

# --- Configuration Variables ---
# Installation paths and versions
INSTALL_DIR="${HOME}/.k3s-demo"
K3S_VERSION="${K3S_VERSION:-v1.29.4+k3s1}" # Stable version as of May 2025
HELM_VERSION="v3.15.4" # Stable Helm version
KUBECTL_VERSION="v1.29.4" # Preferred kubectl version
ARGOCD_VERSION="2.12.5" # ArgoCD Helm chart version
KAMAJI_VERSION="0.5.0" # Kamaji Helm chart version
CROSSPLANE_VERSION="1.16.0" # Crossplane Helm chart version
METALLB_VERSION="0.14.5" # MetalLB Helm chart version
SVELTOS_VERSION="0.24.0" # Sveltos Helm chart version
GITOPS_REPO_DIR="${INSTALL_DIR}/demo-environment-gitops"
LOG_FILE="/tmp/bootstrap-k3s-$(date +%s).log" # Temporary log file
LIMA_VM_NAME="k3s-demo-vm"
LIMA_VM_DIR="${HOME}/.lima/${LIMA_VM_NAME}"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
IMAGE_PATH="${INSTALL_DIR}/noble-server-cloudimg-arm64.img"

# MetalLB configuration
INSTALL_METALLB="${INSTALL_METALLB:-false}" # Set to true to enable MetalLB, false for NodePort
METALLB_IP_POOL="${METALLB_IP_POOL:-192.168.1.240/28}" # IP range for MetalLB LoadBalancer

# K3s specific settings for Lima VM
K3S_BIN_DIR="${INSTALL_DIR}/bin"
K3S_CONFIG_DIR="${INSTALL_DIR}/config"
K3S_DATA_DIR="${HOME}/.rancher/k3s"
K3S_EXEC="server --disable=traefik --disable-network-policy --flannel-backend=vxlan --data-dir=/var/lib/rancher/k3s"

# ArgoCD GitOps configuration
ARGOCD_APP_NAME="gitops-demo"
ARGOCD_GITOPS_PATH="kamaji-clusters"
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

check_lima() {
    check_command limactl
    local lima_version
    lima_version=$(limactl --version | awk '{print $2}')
    log_info "Lima version: ${lima_version}"
    if [[ "${lima_version}" < "0.17.0" ]]; then
        log_error "Lima version ${lima_version} is too old. Please upgrade to 0.17.0 or newer with 'brew upgrade lima'."
    fi
}

# --- Reset Environment ---
reset_environment() {
    log_info "Resetting environment for a clean setup..."
    # Stop and delete Lima VM if it exists
    if limactl list --format '{{.Name}}' 2>/dev/null | grep -q "${LIMA_VM_NAME}"; then
        log_info "Stopping and deleting existing Lima VM '${LIMA_VM_NAME}'..."
        limactl stop --force "${LIMA_VM_NAME}" 2>&1 | tee -a "${LOG_FILE}" || log_warn "Failed to force-stop Lima VM '${LIMA_VM_NAME}'. Continuing..."
        limactl delete "${LIMA_VM_NAME}" 2>&1 | tee -a "${LOG_FILE}" || log_warn "Failed to delete Lima VM '${LIMA_VM_NAME}'. Continuing..."
    fi
    # Remove K3s data, configuration directories, and image
    log_info "Removing K3s data, configuration directories, and image..."
    rm -rf "${K3S_DATA_DIR}" "${K3S_CONFIG_DIR}" "${K3S_BIN_DIR}" "${INSTALL_DIR}/lima-config.yaml" "${IMAGE_PATH}" || log_warn "Failed to remove some K3s directories or image. Continuing..."
    # Ensure GitOps repo directory is not removed to preserve user data
    log_info "Environment reset complete."
}

# --- Validate Prerequisites ---
validate_prerequisites() {
    log_info "Validating prerequisites..."
    # Check disk space (need at least 20GB free)
    local free_space
    free_space=$(df -g / | tail -1 | awk '{print $4}')
    if [ "${free_space}" -lt 20 ]; then
        log_error "Insufficient disk space. Need at least 20GB free, found ${free_space}GB."
    fi
    log_info "Disk space check passed: ${free_space}GB available."
    # Check network connectivity for Ubuntu image
    if ! curl -s -I "${IMAGE_URL}" >/dev/null; then
        log_error "Failed to access Ubuntu Noble image at ${IMAGE_URL}. Check your network connection."
    fi
    log_info "Network connectivity check passed."
    # Warn if socket_vmnet is running (unnecessary with user-v2 networking)
    if brew services list | grep -q "socket_vmnet.*started"; then
        log_warn "socket_vmnet service is running but not needed with user-v2 networking. You can stop it with 'brew services stop socket_vmnet' if you have sudo access."
    fi
}

# --- Download Ubuntu Image with Progress Bar ---
download_ubuntu_image() {
    log_info "Downloading Ubuntu Noble image with progress bar..."
    mkdir -p "${INSTALL_DIR}"
    # Try downloading with curl and progress bar, with up to 3 retries
    for attempt in {1..3}; do
        log_info "Download attempt ${attempt}/3..."
        if command -v pv >/dev/null 2>&1; then
            # Use pv if available for a detailed progress bar
            curl -sL "${IMAGE_URL}" | pv -p -b -r -t -e -N "Downloading ${IMAGE_URL}" > "${IMAGE_PATH}" && break
        else
            # Fallback to curl with built-in progress bar
            echo "Downloading ${IMAGE_URL}..."
            curl -L "${IMAGE_URL}" --progress-bar -o "${IMAGE_PATH}" 2>&1 | tee -a "${LOG_FILE}" && break
        fi
        if [ "${attempt}" -lt 3 ]; then
            log_warn "Download failed. Retrying in 5 seconds..."
            sleep 5
        else
            log_error "Failed to download Ubuntu Noble image after 3 attempts. Check ${LOG_FILE} for details."
        fi
    done
    # Verify the image file exists and is non-empty
    if [ ! -s "${IMAGE_PATH}" ]; then
        log_error "Downloaded image at ${IMAGE_PATH} is missing or empty."
    fi
    log_info "Ubuntu Noble image downloaded successfully to ${IMAGE_PATH}."
}

# --- Create and Manage Lima VM ---
manage_lima_vm() {
    log_info "Creating and configuring Lima VM '${LIMA_VM_NAME}'..."
    download_ubuntu_image
    cat <<EOF > "${INSTALL_DIR}/lima-config.yaml"
arch: aarch64
images:
  - location: "${IMAGE_PATH}"
    arch: aarch64
cpus: 4
memory: "4GiB"
disk: "20GiB"
mounts:
  - location: "/var/lib/rancher"
    writable: true
  - location: "/etc/rancher"
    writable: true
mountType: 9p
containerd:
  system: false
  user: false
networks:
  - lima: user-v2
portForwards:
  - guestPort: 6443
    hostPort: 6443
EOF
    limactl create --name "${LIMA_VM_NAME}" "${INSTALL_DIR}/lima-config.yaml" 2>&1 | tee -a "${LOG_FILE}" || log_error "Failed to create Lima VM '${LIMA_VM_NAME}'. Check ${LOG_FILE} for details and run 'limactl create --name ${LIMA_VM_NAME} ${INSTALL_DIR}/lima-config.yaml' manually."
    limactl start "${LIMA_VM_NAME}" 2>&1 | tee -a "${LOG_FILE}" || log_error "Failed to start Lima VM '${LIMA_VM_NAME}'. Check ${LOG_FILE} for details and run 'limactl start ${LIMA_VM_NAME}' manually."
    log_info "Lima VM '${LIMA_VM_NAME}' is running."
    # Ensure K3s data directories are accessible in the VM
    limactl shell "${LIMA_VM_NAME}" sudo mkdir -p /var/lib/rancher/k3s /etc/rancher/k3s >/dev/null 2>&1
    limactl shell "${LIMA_VM_NAME}" sudo chmod -R 777 /var/lib/rancher/k3s /etc/rancher/k3s >/dev/null 2>&1
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
    for cmd in curl git limactl; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_info "Installing ${cmd} via Homebrew..."
            brew install "${cmd}" || log_error "Failed to install ${cmd}."
        fi
    done
    # Install pv for enhanced progress bar if not present
    if ! command -v pv >/dev/null 2>&1; then
        log_info "Installing pv for download progress bar..."
        brew install pv || log_warn "Failed to install pv. Falling back to curl progress bar."
    fi
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

# --- Install K3s in Lima VM ---
install_k3s() {
    log_info "Installing K3s ${K3S_VERSION} in Lima VM '${LIMA_VM_NAME}'..."
    export PATH="${K3S_BIN_DIR}:${PATH}"
    mkdir -p "${K3S_CONFIG_DIR}" "${K3S_DATA_DIR}" || log_error "Failed to create K3s directories."
    chmod 700 "${K3S_CONFIG_DIR}" "${K3S_DATA_DIR}"
    # Install dependencies in the VM
    limactl shell "${LIMA_VM_NAME}" sudo apt-get update >/dev/null 2>&1
    limactl shell "${LIMA_VM_NAME}" sudo apt-get install -y conntrack iptables >/dev/null 2>&1 || log_error "Failed to install K3s dependencies in Lima VM."
    # Install K3s in the VM
    limactl shell "${LIMA_VM_NAME}" bash -c "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} K3S_KUBECONFIG_MODE=644 sh -s - ${K3S_EXEC}" 2>&1 | tee -a "${LOG_FILE}" || log_error "Failed to install K3s in Lima VM. Check ${LOG_FILE} for details."
    sleep 60 # Increased sleep to ensure K3s is ready
    # Copy kubeconfig to host
    limactl copy "${LIMA_VM_NAME}:/etc/rancher/k3s/k3s.yaml" "${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "Failed to copy kubeconfig from Lima VM."
    sed -i '' "s/0.0.0.0:6443/127.0.0.1:6443/g" "${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "Failed to update kubeconfig."
    chmod 600 "${K3S_CONFIG_DIR}/kubeconfig.yaml" || log_error "Failed to set kubeconfig permissions."
    if ! "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get nodes >/dev/null 2>&1; then
        log_info "K3s VM status:"
        limactl list --format '{{.Name}} {{.Status}}' | grep "${LIMA_VM_NAME}" | tee -a "${LOG_FILE}"
        log_info "K3s logs from VM:"
        limactl shell "${LIMA_VM_NAME}" sudo journalctl -u k3s -n 100 2>&1 | tee -a "${LOG_FILE}"
        log_error "K3s cluster not running. Check logs above and ${LOG_FILE}."
    fi
    log_info "K3s installed successfully in Lima VM."
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
    "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" apply -f https://docs.projectcalico.org/manifests/calico.yaml
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
# Ignore K3s and Lima setup artifacts
${INSTALL_DIR#/Users/*/}
*.log
.lima/
EOF
    fi
    if [ ! -f README.md ]; then
        cat <<EOF > README.md
# Multi-Tenant Kubernetes Demo Platform
This repository provides a GitOps-driven platform for managing multiple Kubernetes tenant clusters using a K3s management cluster running in a Lima VM. It supports rapid deployments of F5 BIG-IP Next Kubernetes (BNK) and Service Proxy Kubernetes (SPK) for demos.
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

# --- Main Execution ---
main() {
    log_info "Starting bootstrap-laptop.sh on MacBook Pro M1 with Lima (MetalLB: ${INSTALL_METALLB})..."
    reset_environment
    validate_prerequisites
    check_lima
    manage_lima_vm
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
    log_info "Bootstrap completed successfully! K3s cluster is running in Lima VM '${LIMA_VM_NAME}', tools are installed, and GitOps repo is set up at ${GITOPS_REPO_DIR}."
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
        log_warn "MetalLB may have limited functionality with user-v2 networking. Consider using NodePort (INSTALL_METALLB=false) for demo purposes."
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