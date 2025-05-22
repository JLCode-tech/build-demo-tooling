#!/bin/bash

set -e

# Functions
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

echo ""
echo "================================================================="
echo "⭐️ K3s Demo Environment Bootstrap (M-Series Mac + Podman + MetalLB)"
echo "================================================================="
echo ""

################################################################################
# Check & Install Homebrew and Podman
################################################################################

if ! command_exists brew; then
  echo "🔴 Homebrew not found. Please install Homebrew from https://brew.sh"
  exit 1
else
  echo "✅ Homebrew installed."
fi

if ! command_exists podman; then
  echo "🔶 Installing Podman..."
  brew install podman
else
  echo "✅ Podman already installed."
fi

if [[ $(podman machine list --format "{{.Running}}") != "true" ]]; then
  if [[ $(podman machine list) == "" ]]; then
    echo "🔶 Initializing Podman machine with recommended resources..."
    podman machine init --cpus=2 --memory=4096 --disk-size=20
  fi
  echo "🔶 Starting Podman machine..."
  podman machine start
else
  echo "✅ Podman machine already running."
fi

################################################################################
# Install K3s without Traefik
################################################################################

if ! command_exists k3s; then
  echo "🚀 Installing K3s WITHOUT Traefik..."
  curl -sfL https://get.k3s.io | sh -s - --disable traefik
  sudo chmod 644 /etc/rancher/k3s/k3s.yaml
else
  echo "✅ K3s already installed."
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "⏳ Waiting for K3s Kubernetes to become Ready (15 sec)..."
sleep 15
kubectl wait node --all --for=condition=Ready --timeout=60s

################################################################################
# Install Kamaji: Multi-tenant Kubernetes
################################################################################
echo "🚀 Installing Kamaji..."
kubectl apply -f https://github.com/clastix/kamaji/releases/latest/download/kamaji.yaml

################################################################################
# Install ArgoCD: GitOps continuous delivery
################################################################################
echo "🚀 Installing ArgoCD..."
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

################################################################################
# Install Crossplane: Declarative infra
################################################################################
echo "🚀 Installing Crossplane..."
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace

################################################################################
# Install Sveltos: Multi-cluster addons
################################################################################
echo "🚀 Installing Sveltos..."
kubectl apply -f https://github.com/projectsveltos/sveltos/releases/latest/download/sveltos.yaml

################################################################################
# Install MetalLB: LoadBalancer
################################################################################
echo "🚀 Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/manifests/metallb.yaml
sleep 5

echo "⚠️ Customize the IP Address Pool BELOW to your actual home/office network!"
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.240-192.168.1.250  # <== CHANGE to YOUR LAN RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-l2
  namespace: metallb-system
EOF

################################################################################
# Expose ArgoCD with a LoadBalancer IP via MetalLB
################################################################################
echo "🚀 Exposing ArgoCD via LoadBalancer service type (MetalLB)..."
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

echo "⏳ Waiting (~20 sec) for MetalLB to assign LoadBalancer IP to ArgoCD..."
sleep 20

# Retrieve External IP assigned to ArgoCD
external_ip=""
retry_count=0
max_retries=6
sleep_between_retries=10

while [ -z "$external_ip" ] && [ $retry_count -lt $max_retries ]; do
  external_ip=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || true)
  if [ -z "$external_ip" ]; then
    echo "Waiting 10 seconds for ArgoCD load balancer IP assignment..."
    sleep $sleep_between_retries
    retry_count=$((retry_count+1))
  fi
done

if [ -z "$external_ip" ]; then
  echo "⚠️ Could not retrieve MetalLB external IP. Check manually: kubectl get svc -n argocd argocd-server"
else
  echo "✅ ArgoCD Service assigned external IP: $external_ip"
fi

argonpw=$(kubectl -n argocd get secrets argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

################################################################################
# Final Setup Information
################################################################################
echo ""
echo "======================================================="
echo "✅ Demo Environment bootstrap complete!"
echo "======================================================="
echo ""
echo "🎯 Access your ArgoCD Dashboard at:"
echo "-------------------------------------------------------"
if [ -n "$external_ip" ]; then
  echo "🔑 URL: https://$external_ip"
else
  echo "🔴 External IP pending. Re-run below in a minute to get IP:"
  echo "kubectl get svc argocd-server -n argocd"
fi
echo "📌 Username: admin"
echo "🔑 Password: $argonpw"
echo ""
echo "⚠️ Add KUBECONFIG to bash or zsh profile (~/.zshrc or ~/.bash_profile):"
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml'
echo ""
echo "✅ Done 🚀 Happy demoing!"
exit 0