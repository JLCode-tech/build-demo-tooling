#!/bin/bash
set -e

# Functions
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

VM_NAME="demo-k3s"
K3S_KUBECONFIG="$HOME/.kube/config-demo-k3s"

echo ""
echo "======================================================================="
echo "⭐️ Portable K3s Environment Bootstrap (Multipass VM on macOS/Linux)"
echo "======================================================================="
echo ""

################################################################################
# Check Homebrew & Multipass prerequisites
################################################################################

if ! command_exists brew; then
  echo "🔴 Homebrew not found. Install from https://brew.sh before continuing."
  exit 1
else
  echo "✅ Homebrew installed."
fi

if ! command_exists multipass; then
  echo "🔶 Installing Multipass..."
  brew install multipass
else
  echo "✅ Multipass already installed."
fi

if ! command_exists helm; then
  echo "🔶 Installing Helm via Homebrew..."
  brew install helm
else
  echo "✅ Helm already installed."
fi

if ! command_exists jq; then
  echo "🔶 Installing jq (required JSON processing)..."
  brew install jq
else
  echo "✅ jq installed."
fi

################################################################################
# Create & Configure Multipass VM
################################################################################

VM_NAME="demo-k3s"
if ! multipass info "$VM_NAME" &>/dev/null; then
  echo "🚀 Launching Ubuntu VM '$VM_NAME' (4 CPUs, 8GB RAM, 50GB Disk)..."
  multipass launch --name "$VM_NAME" --cpus 4 --memory 8G --disk 50G
else
  echo "✅ VM '$VM_NAME' already exists."
fi

################################################################################
# Install K3s inside VM (without Traefik)
################################################################################

echo "🚀 Installing K3s (WITHOUT Traefik)..."
multipass exec "$VM_NAME" -- bash -c "curl -sfL https://get.k3s.io | sh -s - --disable traefik"
sleep 10

# Wait until Kubernetes node is Ready
echo "⏳ Waiting for Kubernetes node readiness (up to 120 seconds)..."
multipass exec "$VM_NAME" -- bash -c "sudo k3s kubectl wait node --all --for=condition=Ready --timeout=120s"

################################################################################
# Configure Local Kubeconfig (macOS local)
################################################################################

KUBECONFIG_LOCAL="$HOME/.kube/config-demo-k3s"
echo "🚀 Copying VM kubeconfig to local machine ($KUBECONFIG_LOCAL)..."
multipass exec "$VM_NAME" -- sudo cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG_LOCAL"
K3S_VM_IP=$(multipass info "$VM_NAME" --format json | jq -r '.info["'$VM_NAME'"].ipv4[0]')
sed -i '' "s/127.0.0.1/$K3S_VM_IP/" "$KUBECONFIG_LOCAL"
export KUBECONFIG="$KUBECONFIG_LOCAL"
kubectl get nodes

################################################################################
# Install cert-manager (prerequisite for Kamaji)
################################################################################

echo "🚀 Installing cert-manager via Helm..."
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.14.5 \
  --set installCRDs=true
sleep 20
kubectl rollout status deploy/cert-manager -n cert-manager --timeout=2m

################################################################################
# Install Kamaji (helm chart now clearly recommended)
################################################################################

echo "🚀 Installing Kamaji via Helm..."
helm repo add clastix https://clastix.github.io/charts
helm repo update
helm upgrade --install kamaji clastix/kamaji --namespace kamaji-system --create-namespace
sleep 15
kubectl rollout status deployment/kamaji -n kamaji-system --timeout=2m

################################################################################
# Install ArgoCD
################################################################################

echo "🚀 Installing ArgoCD..."
kubectl create ns argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
sleep 30
kubectl rollout status deploy/argocd-server -n argocd --timeout=2m

################################################################################
# Install Crossplane
################################################################################

echo "🚀 Installing Crossplane..."
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm upgrade --install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace

################################################################################
# Install Sveltos
################################################################################

echo "🚀 Installing Sveltos..."
helm repo add projectsveltos https://projectsveltos.github.io/helm-charts
helm repo update
helm upgrade --install projectsveltos projectsveltos/projectsveltos -n projectsveltos --create-namespace --set agent.managementCluster=true
helm list -n projectsveltos

################################################################################
# Install MetalLB: clearly update LAN address below
################################################################################

################################################################################
# Install MetalLB (Helm-based clearly idempotent method)
################################################################################
#echo "🚀 Installing MetalLB via Helm..."
#helm repo add metallb https://metallb.github.io/metallb
#helm repo update

#helm upgrade --install metallb metallb/metallb \
#  --namespace metallb-system --create-namespace \
#  --version 0.14.5

# Wait for MetalLB deployment readiness (avoid webhook endpoint error)
#kubectl wait deploy -n metallb-system metallb-controller \
#  --for condition=Available=True --timeout=120s

#sleep 10

#echo "⚠️ Ensure you adjust the MetalLB IP addresses clearly below:"
#kubectl apply -f - <<EOF
#apiVersion: metallb.io/v1beta1
#kind: IPAddressPool
#metadata:
#  name: local-pool
#  namespace: metallb-system
#spec:
#  addresses:
#  - 192.168.1.220-192.168.1.230 # ⚠️ Adjust to your LAN IP range clearly here!
#---
#apiVersion: metallb.io/v1beta1
#kind: L2Advertisement
#metadata:
#  name: local-l2
#  namespace: metallb-system
#EOF

################################################################################
# Expose ArgoCD UI via NodePort
################################################################################

kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
sleep 30

################################################################################
# Final clearly displayed information (MULTIPASS clearly corrected)
################################################################################
ARGO_NODEPORT=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
MULTIPASS_VM_IP=$(multipass info "$VM_NAME" --format json | jq -r '.info["'$VM_NAME'"].ipv4[0]')
ARGO_PWD=$(kubectl -n argocd get secrets argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "======================================"
echo "🎯 K3s Demo Bootstrap Successful"
echo "======================================"
echo "🔑 ArgoCD URL clearly accessible at:"
echo "  https://$MULTIPASS_VM_IP:$ARGO_NODEPORT"
echo "📌 Username : admin"
echo "🔑 Password : $ARGO_PWD"
echo ""
echo "✅ Add to ~/.zshrc or ~/.bash_profile:"
echo "export KUBECONFIG=$KUBECONFIG_LOCAL"
echo ""
echo "🚀 Installation Complete!"