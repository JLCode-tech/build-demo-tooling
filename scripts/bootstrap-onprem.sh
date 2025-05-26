#!/bin/bash
# bootstrap-onprem.sh - On-Prem (UDF/VM) K3s Multi-Tenant Bootstrap
# Clean reset ("Nuke-and-Pave") each execution
# GitOps Repo (readonly): https://github.com/JLCode-tech/build-demo-tooling.git

set -euo pipefail

## Color Codes ##
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

## Global Variables ##
INSTALL_DIR="/opt/k3s-onprem"
K3S_VERSION="v1.33.0+k3s1"
HELM_VERSION="v3.14.3"
ARGOCD_VERSION="8.0.10"
CROSSPLANE_VERSION="1.20.0"
CERT_MANAGER_VERSION="v1.17.2"
KAMAJI_VERSION="0.0.0+latest"
METALLB_VERSION="0.14.9"
SVELTOS_VERSION="0.54.0"
GITOPS_REPO_URL="https://github.com/JLCode-tech/build-demo-tooling.git"
GITOPS_REPO_DIR="${INSTALL_DIR}/build-demo-tooling"
LOG_FILE="/tmp/bootstrap-onprem-$(date +%Y%m%d_%H%M%S).log"
INSTALL_METALLB="false"  # Set to "false" if you want to skip installing MetalLB
METALLB_IP_POOL="10.10.20.240/28"  # Update per your networking requirements

## Logging Functions ##
log_info() { echo -e "${GREEN}[INFO]$(date '+%Y-%m-%d %H:%M:%S') $*${NC}" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S') $*${NC}" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S') $*${NC}" | tee -a "$LOG_FILE"; exit 1; }

## Error Checking ##
check_command() { command -v "$1" >/dev/null 2>&1 || log_error "Command '$1' not found. Aborting."; }

## Clean Reset ##
clean_environment() {
    log_warn "Commencing COMPLETE RESET ('Nuke-and-Pave'). ALL previous state will be permanently lost!"
    "/usr/local/bin/k3s-uninstall.sh" &>/dev/null || true
    sleep 5
    sudo rm -rf "$INSTALL_DIR" /etc/rancher /var/lib/rancher /var/lib/kubelet ~/.kube ~/.helm ~/.config/helm
    sudo rm -f /usr/local/bin/helm /usr/local/bin/kubectl
    log_info "Environment reset complete."
}

## K3s Installation ##
install_k3s() {
    log_info "Installing K3s (${K3S_VERSION})..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
        --disable=traefik \
        --disable-network-policy \
        --flannel-backend=vxlan \
        --write-kubeconfig-mode=644 || log_error "K3s installation failed."
    sudo mkdir -p "${INSTALL_DIR}/config"
    sudo cp /etc/rancher/k3s/k3s.yaml "${INSTALL_DIR}/config/kubeconfig.yaml"
    sudo sed -i "s/127.0.0.1/$(hostname -I | awk '{print $1}')/" "${INSTALL_DIR}/config/kubeconfig.yaml"
    export KUBECONFIG="${INSTALL_DIR}/config/kubeconfig.yaml"
    log_info "K3s installed and configured."
}

## Helm Installation & Setup ##
install_helm() {
    log_info "Installing Helm (${HELM_VERSION})..."
    curl -fsSL "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3" | bash || log_error "Helm installation failed."
}

## Helm Deployments ##
deploy_charts() {
    log_info "Adding and updating Helm repositories..."
    helm repo add clastix https://clastix.github.io/charts
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo add crossplane-stable https://charts.crossplane.io/stable
    helm repo add metallb https://metallb.github.io/metallb
    helm repo add projectsveltos https://projectsveltos.github.io/helm-charts
    helm repo add cert-manager https://charts.jetstack.io
    helm repo update
    log_info "Deploying Helm charts..."
    helm upgrade --install cert-manager cert-manager/cert-manager --version "$CERT_MANAGER_VERSION" -n cert-manager --create-namespace --set installCRDs=true
    helm upgrade --install kamaji clastix/kamaji --version "$KAMAJI_VERSION" -n kamaji-system --create-namespace --set image.tag=latest
    helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_VERSION" -n argocd --create-namespace
    helm upgrade --install crossplane crossplane-stable/crossplane --version "$CROSSPLANE_VERSION" -n crossplane-system --create-namespace
    helm upgrade --install sveltos projectsveltos/projectsveltos --version "$SVELTOS_VERSION" -n projectsveltos --create-namespace
    helm upgrade --install sveltos-crds projectsveltos/sveltos-crds --version "$SVELTOS_VERSION" -n projectsveltos
    helm upgrade --install sveltos-dashboard projectsveltos/sveltos-dashboard --version "$SVELTOS_VERSION" -n projectsveltos
    if [ "${INSTALL_METALLB}" = "true" ]; then
      helm upgrade --install metallb metallb/metallb --version "$METALLB_VERSION" -n metallb-system --create-namespace
      kubectl apply -f- <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: demo-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_IP_POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - demo-pool
EOF
    else
      log_info "Skipping MetalLB as per configuration."
    fi
    log_info "Helm deployments complete."
}

## Clone GitOps Repository (readonly) ##
clone_gitops_repo() {
    log_info "Cloning existing GitOps repo (readonly): ${GITOPS_REPO_URL}"
    git clone "${GITOPS_REPO_URL}" "${GITOPS_REPO_DIR}" || log_error "Failed to clone given GitOps repository."
    log_info "Repo cloned at: ${GITOPS_REPO_DIR}"
}

## Main Execution ##
main() {
    log_info "== BOOTSTRAP-ONPREM INITIATED =="
    check_command curl
    check_command git

    clean_environment
    sudo mkdir -p "$INSTALL_DIR" && sudo chmod 755 "$INSTALL_DIR"

    install_k3s
    install_helm
    deploy_charts
    clone_gitops_repo

    ARGO_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
    log_info "== BOOTSTRAP COMPLETE =="
    log_info "Kubeconfig location: ${INSTALL_DIR}/config/kubeconfig.yaml"
    log_info "ArgoCD credentials - URL: $(kubectl -n argocd get svc argocd-server)"
    log_info "ArgoCD Username: admin"
    log_info "ArgoCD Password: ${ARGO_PWD}"
    log_info "Complete log file: ${LOG_FILE}"
}

main "$@"