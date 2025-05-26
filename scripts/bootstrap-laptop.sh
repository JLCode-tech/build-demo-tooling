#!/bin/bash

# bootstrap-laptop.sh
# Sets up a K3s management cluster on a MacBook Pro M1 using Podman for a multi-tenant demo environment.
# Compatible with arm64 architecture, runs without sudo, includes optional MetalLB support, and configures ArgoCD to watch a remote GitOps repo.
# Idempotent: Can be run multiple times to ensure consistent state or apply updates.

set -euo pipefail

# --- Configuration Variables ---
# Installation paths and versions
INSTALL_DIR="${HOME}/.k3s-demo"
K3S_VERSION="${K3S_VERSION:-v1.29.4+k3s1}" # Stable version as of May 2025
HELM_VERSION="v3.15.4" # Stable Helm version
KUBECTL_VERSION="v1.29.4" # Match K3s version
ARGOCD_VERSION="2.12.5" # ArgoCD Helm chart version
KAMAJI_VERSION="0.5.0" # Kamaji Helm chart version
CROSSPLANE_VERSION="1.16.0" # Crossplane Helm chart version
METALLB_VERSION="0.14.5" # MetalLB Helm chart version
SVELTOS_VERSION="0.24.0" # Sveltos Helm chart version
GITOPS_REPO_DIR="${INSTALL_DIR}/demo-environment-gitops"
LOG_FILE="${INSTALL_DIR}/bootstrap.log"

# MetalLB configuration
INSTALL_METALLB="${INSTALL_METALLB:-false}" # Set to true to enable MetalLB, false for NodePort
METALLB_IP_POOL="${METALLB_IP_POOL:-192.168.1.240/28}" # IP range for MetalLB LoadBalancer

# K3s specific settings for non-root Podman
K3S_BIN_DIR="${INSTALL_DIR}/bin"
K3S_CONFIG_DIR="${INSTALL_DIR}/config"
K3S_DATA_DIR="${HOME}/.rancher/k3s"
K3S_EXEC="server --disable=traefik --data-dir=${K3S_DATA_DIR} --kubelet-arg=provider-id=host://localhost"

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
    podman system service --time=0 >/dev/null 2>&1 || {
        log_info "Starting Podman system service..."
        podman system service --time=0 &
        sleep 2
    }
}

check_git_credentials() {
    log_info "Checking Git credentials for ${GITOPS_REMOTE_URL}..."
    git ls-remote "${GITOPS_REMOTE_URL}" >/dev/null 2>&1 || {
        log_error "Failed to access ${GITOPS_REMOTE_URL}. Ensure you have write access and Git credentials configured.\n" \
                  "1. For HTTPS: Set up a personal access token (https://github.com/settings/tokens) and configure it with 'git config --global credential.helper osxkeychain'.\n" \
                  "2. For SSH: Ensure your SSH key is added to your GitHub account (https://github.com/settings/keys) and loaded in your SSH agent ('ssh-add')."
    }
}

# --- Check Existing Resources ---
check_existing_resources() {
    log_info "Checking existing resources for idempotency..."

    # Check K3s
    if [ -f "${K3S_BIN_DIR}/k3s" ]; then
        if "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get nodes >/dev/null 2>&1; then
            log_info "K3s is already running."
        else
            log_warn "K3s binary found but cluster is not running. Attempting to start..."
        fi
    fi

    # Check Helm releases
    if command -v helm >/dev/null 2>&1 && [ -f "${K3S_CONFIG_DIR}/kubeconfig.yaml" ]; then
        helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q kamaji && log_info "Kamaji Helm release already exists."
        helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q argocd && log_info "ArgoCD Helm release already exists."
        helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q crossplane && log_info "Crossplane Helm release already exists."
        [ "${INSTALL_METALLB}" = true ] && helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q metallb && log_info "MetalLB Helm release already exists."
        helm --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" list -A | grep -q sveltos && log_info "Sveltos Helm release already exists."
    fi

    # Check GitOps repo
    if [ -d "${GITOPS_REPO_DIR}/.git" ]; then
        log_info "GitOps repository already exists at ${GITOPS_REPO_DIR}."
    fi

    # Check ArgoCD Application
    if [ -f "${K3S_CONFIG_DIR}/kubeconfig.yaml" ] && "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get application -n argocd "${ARGOCD_APP_NAME}" >/dev/null 2>&1; then
        log_info "ArgoCD Application '${ARGOCD_APP_NAME}' already exists."
    fi
}

# --- Setup Directories ---
setup_directories() {
    log_info "Creating installation directories..."
    mkdir -p "${INSTALL_DIR}" "${K3S_BIN_DIR}" "${K3S_CONFIG_DIR}" || log_error "Failed to create directories."
    touch "${LOG_FILE}" || log_error "Failed to create log file."
    # Ensure GitOps repo directory is readable/writable
    [ -d "${GITOPS_REPO_DIR}" ] && chmod -R u+rwX "${GITOPS_REPO_DIR}" || true
}

# --- Install Dependencies ---
install_dependencies() {
    log_info "Checking and installing dependencies..."
    check_command brew
    for cmd in curl git kubectl helm; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_info "Installing ${cmd} via Homebrew..."
            brew install "${cmd}" || log_error "Failed to install ${cmd}."
        fi
    done

    # Ensure kubectl matches K3s version
    if ! kubectl version --client --output=json | grep -q "${KUBECTL_VERSION}"; then
        log_info "Installing kubectl ${KUBECTL_VERSION}..."
        curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/arm64/kubectl" || log_error "Failed to download kubectl."
        chmod +x kubectl
        mv kubectl "${K3S_BIN_DIR}/kubectl" || log_error "Failed to install kubectl."
    fi

    # Ensure Helm is installed
    if ! helm version --short | grep -q "${HELM_VERSION}"; then
        log_info "Installing Helm ${HELM_VERSION}..."
        curl -LO "https://get.helm.sh/helm-${HELM_VERSION}-darwin-arm64.tar.gz" || log_error "Failed to download Helm."
        tar -zxvf helm-${HELM_VERSION}-darwin-arm64.tar.gz
        mv darwin-arm64/helm "${K3S_BIN_DIR}/helm" || log_error "Failed to install Helm."
        rm -rf helm-${HELM_VERSION}-darwin-arm64.tar.gz darwin-arm64
    fi
}

# --- Install K3s with Podman ---
install_k3s() {
    if [ -f "${K3S_BIN_DIR}/k3s" ] && "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get nodes >/dev/null 2>&1; then
        log_info "K3s is already installed and running. Skipping installation."
        return
    fi

    log_info "Installing K3s ${K3S_VERSION}..."
    export PATH="${K3S_BIN_DIR}:${PATH}"
    export K3S_KUBECONFIG_OUTPUT="${K3S_CONFIG_DIR}/kubeconfig.yaml"
    export K3S_KUBECONFIG_MODE="644"
    export INSTALL_K3S_VERSION="${K3S_VERSION}"
    export INSTALL_K3S_BIN_DIR="${K3S_BIN_DIR}"
    export INSTALL_K3S_EXEC="${K3S_EXEC}"
    export CONTAINER_RUNTIME_ENDPOINT="unix:///var/run/podman/podman.sock"

    # Download K3s install script
    curl -sfL https://get.k3s.io > "${INSTALL_DIR}/install.sh" || log_error "Failed to download K3s install script."
    chmod +x "${INSTALL_DIR}/install.sh"

    # Modify install.sh for Podman and non-root
    sed -i '' 's/sudo //g' "${INSTALL_DIR}/install.sh"
    sed -i '' 's|/usr/local/bin|'"${K3S_BIN_DIR}"'|g' "${INSTALL_DIR}/install.sh"
    sed -i '' 's|/etc/systemd/system|'"${K3S_CONFIG_DIR}"'|g' "${INSTALL_DIR}/install.sh"

    # Run K3s install
    sh "${INSTALL_DIR}/install.sh" || log_error "K3s installation failed."

    # Verify K3s is running
    sleep 10
    "${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" get nodes || log_error "K3s cluster not running."
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

    # Retrieve ArgoCD admin password
    local admin_password
    admin_password=$("${K3S_BIN_DIR}/kubectl" --kubeconfig="${K3S_CONFIG_DIR}/kubeconfig.yaml" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null) || log_warn "Failed to retrieve ArgoCD admin password. Secret may not be ready yet."

    # Log access instructions
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

    # Apply MetalLB IP pool
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

    # Check if local repo exists
    if [ -d "${GITOPS_REPO_DIR}/.git" ]; then
        log_info "GitOps repository already exists at ${GITOPS_REPO_DIR}. Pulling latest changes..."
        cd "${GITOPS_REPO_DIR}"
        git fetch origin
        git checkout "${GITOPS_BRANCH}" || git checkout -b "${GITOPS_BRANCH}"
        git pull origin "${GITOPS_BRANCH}" --rebase || log_warn "No changes pulled from ${GITOPS_REMOTE_URL}."
    else
        # Clone or initialize the repository
        if git ls-remote "${GITOPS_REMOTE_URL}" >/dev/null 2>&1; then
            log_info "Cloning existing repository from ${GITOPS_REMOTE_URL}..."
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

    # Create directory structure if not exists
    mkdir -p documentation infra-setup/{metal3,metallb,crossplane-provider} kamaji-clusters base-addons demos/{f5-bnk,f5-spk,other-products} clusters-apps/{example-app1,example-app2} scripts || log_error "Failed to create GitOps repo structure."

    # Create basic README if not exists
    if [ ! -f README.md ]; then
        cat <<EOF > README.md
# Multi-Tenant Kubernetes Demo Platform
This repository provides a GitOps-driven platform for managing multiple Kubernetes tenant clusters using a k3s management cluster. It supports rapid deployments of F5 BIG-IP Next Kubernetes (BNK) and Service Proxy Kubernetes (SPK) for demos.
See documentation/ for quickstart guides.
EOF
    fi

    # Create placeholder quickstart docs if not exists
    for env in laptop onprem cloud; do
        if [ ! -f "documentation/quickstart-${env}.md" ]; then
            echo "# Quickstart for ${env} environment" > "documentation/quickstart-${env}.md"
        fi
    done

    # Create placeholder tenant manifests if not exists
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

    # Create bootstrap script placeholder if not exists
    if [ ! -f scripts/bootstrap-laptop.sh ]; then
        cat <<EOF > scripts/bootstrap-laptop.sh
#!/bin/bash
# Placeholder for bootstrap-laptop.sh
echo "Bootstrap script for laptop environment"
EOF
        chmod +x scripts/bootstrap-laptop.sh
    fi

    # Commit and push changes
    git add . >/dev/null 2>&1
    if git diff --cached --quiet; then
        log_info "No changes to commit in GitOps repository."
    else
        git commit -m "Update GitOps repository structure" || log_warn "No changes to commit."
        git push -u origin "${GITOPS_BRANCH}" || log_error "Failed to push to ${GITOPS_REMOTE_URL}. Ensure Git credentials are configured."
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

    # Check existing resources
    check_existing_resources

    # Check Podman and dependencies
    check_podman
    install_dependencies
    setup_directories

    # Install K3s
    install_k3s

    # Setup Helm repositories
    setup_helm_repos

    # Install tools
    install_kamaji
    install_argocd
    install_crossplane
    install_metallb
    install_sveltos

    # Setup GitOps repository
    setup_gitops_repo

    # Configure ArgoCD to watch GitOps repo
    configure_argocd_gitops

    log_info "Bootstrap completed successfully! K3s cluster is running, tools are installed, and GitOps repo is set up at ${GITOPS_REPO_DIR}."
    log_info "Kubeconfig is available at ${K3S_CONFIG_DIR}/kubeconfig.yaml"

    # Provide access instructions
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
        [ -n "${node_port}" ] && log_info "ArgoCD is configured with NodePort. Access it at http://localhost:${node_port}"
    fi
    log_info "ArgoCD is watching ${GITOPS_REMOTE_URL}/${ARGOCD_GITOPS_PATH} (branch: ${GITOPS_BRANCH}) for tenant cluster definitions."
    log_info "Next steps: Add F5 BNK/SPK manifests to ${GITOPS_REPO_DIR}/demos/ and push to ${GITOPS_REMOTE_URL}."
}

# Run main with error handling
main || log_error "Bootstrap failed. Check ${LOG_FILE} for details."