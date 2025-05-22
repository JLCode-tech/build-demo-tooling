#!/bin/bash
set -e

# Functions
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

VM_NAME="demo-k3s"
K3S_KUBECONFIG="$HOME/.kube/config-demo-k3s"  # MacOS local kubeconfig output

echo ""
echo "======================================================================="
echo "⭐️ K3s Environment Bootstrap (Multipass VM: macOS/Bare Metal/UDF/Cloud)"
echo "======================================================================="
echo ""

###############################
# Check Homebrew & Multipass
###############################

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

###############################
# Create & Configure Multipass VM
###############################

if ! multipass info "$VM_NAME" &>/dev/null; then
  echo "🚀 Launching new Ubuntu VM '$VM_NAME' (4 CPUs, 8GB RAM, 50GB Disk)..."
  multipass launch --name "$VM_NAME" --cpus 4 --memory 8G --disk 50G
else
  echo "✅ VM '$VM_NAME' already exists."
fi

###############################
# Install K3s in VM (without Traefik)
###############################

echo "🚀 Installing K3s within VM (WITHOUT Traefik)..."
multipass exec "$VM_NAME" -- bash -c "curl -sfL https://get.k3s.io | sh -s - --disable traefik"
sleep 10

# Check nodes ready
echo "⏳ Waiting for Kubernetes node ready (Max 2 minutes)..."
multipass exec "$VM_NAME" sudo k3s kubectl wait node --all --for=condition=Ready --timeout=120s

###############################
# Setup kubeconfig locally (macOS)
###############################

echo "🚀 Copying kubeconfig from VM to local macOS (~/.kube/config-demo-k3s)..."
multipass exec "$VM_NAME" -- sudo cat /etc/rancher/k3s/k3s.yaml > "$K3S_KUBECONFIG"
K3S_VM_IP=$(multipass info "$VM_NAME" --format json | jq -r '.info["'$VM_NAME'"].ipv4[0]')
sed -i '' "s/127.0.0.1/$K3S_VM_IP/" "$K3S_KUBECONFIG"
export KUBECONFIG="$K3S_KUBECONFIG"

echo "✅ Kubernetes nodes:"
kubectl get nodes

###############################
# Install Kamaji
###############################

echo "🚀 Installing Kamaji..."
kubectl apply -f https://github.com/clastix/kamaji/releases/latest/download/kamaji.yaml

###############################
# Install ArgoCD
###############################

echo "🚀 Installing ArgoCD..."
kubectl create ns argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

###############################
# Install Crossplane
###############################

echo "🚀 Installing Crossplane..."
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace

###############################
# Install Sveltos
###############################

echo "🚀 Installing Sveltos..."
kubectl apply -f https://github.com/projectsveltos/sveltos/releases/latest/download/sveltos.yaml

###############################
# Install MetalLB
###############################

echo "🚀 Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/manifests/metallb.yaml
sleep 10

echo "⚠️ Customize MetalLB IP Range to YOUR LAN NETWORK before continuing."
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.240-192.168.1.250  # <== ⚠️ Change to your LAN IP range
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-l2
  namespace: metallb-system
EOF

###############################
# Expose ArgoCD via MetalLB LoadBalancer IP
###############################

echo "🚀 Exposing ArgoCD via LoadBalancer..."
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
sleep 20

external_ip=""
while [ -z "$external_ip" ]; do
  external_ip=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || true
  [ -z "$external_ip" ] && sleep 10
done

argo_pwd=$(kubectl -n argocd get secrets argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

###############################
# Final Setup & Info
###############################

echo ""
echo "=========================================================="
echo "✅ Complete! You've got a clearly portable K3s environment."
echo "=========================================================="
echo "🎯 ArgoCD Dashboard:"
echo "🔑 URL: https://$external_ip"
echo "📌 Username: admin"
echo "🔑 Password: $argo_pwd"
echo ""
echo "Add the following to your ~/.zshrc or ~/.bash_profile:"
echo "export KUBECONFIG=$K3S_KUBECONFIG"
echo ""
echo "✅ Setup DONE 🚀 Happy Demoing!"