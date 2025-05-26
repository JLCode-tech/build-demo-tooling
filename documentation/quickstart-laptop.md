# Quickstart: Laptop-Based Kubernetes Demo (Phase 1 PoC)

This guide walks you through setting up a lightweight Kubernetes demo environment on a laptop using Multipass and k3s. The environment includes a management cluster with Kamaji, ArgoCD, Crossplane, Sveltos, and (optionally) MetalLB, enabling rapid provisioning of tenant clusters for F5 BNK/SPK demos.

## Prerequisites

- **Operating System**: macOS or Linux
- **Hardware**: 8GB RAM, 4 CPUs, 50GB free disk space
- **Software**:
  - [Homebrew](https://brew.sh) (`brew`)
  - [Multipass](https://multipass.run) (`multipass`)
  - [Helm](https://helm.sh) (`helm`)
  - [jq](https://jqlang.github.io/jq/) (`jq`)

Install prerequisites on macOS/Linux:

```bash
# Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Install tools
brew install multipass helm jq
```

## Setup Instructions

1. **Clone the GitOps Repository**:
   Clone the demo GitOps repository to your local machine:

   ```bash
   git clone <your-gitops-repo-url> demo-environment-gitops
   cd demo-environment-gitops
   ```

2. **Run the Bootstrap Script**:
   Execute the `bootstrap-laptop.sh` script to set up the environment:

   ```bash
   chmod +x scripts/bootstrap-laptop.sh
   ./scripts/bootstrap-laptop.sh
   ```

   The script:
   - Creates a Multipass VM (`demo-k3s`) with k3s.
   - Installs Kamaji, ArgoCD, Crossplane, Sveltos, and (optionally) MetalLB.
   - Configures a local kubeconfig at `~/.kube/config-demo-k3s`.

3. **Verify the Setup**:
   After the script completes, verify the cluster and tools:

   ```bash
   export KUBECONFIG=~/.kube/config-demo-k3s
   kubectl get nodes
   kubectl get pods -A
   ```

   Check installed versions:

   ```bash
   helm list -A
   ```

4. **Access ArgoCD**:
   The script outputs the ArgoCD URL and admin credentials:

   ```bash
   # Example output:
   # ArgoCD URL: https://<VM-IP>:<NodePort>
   # Username: admin
   # Password: Run 'kubectl -n argocd get secrets argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d'
   ```

   Open the ArgoCD UI in your browser and log in.

5. **Create a Tenant Cluster**:
   Apply a Kamaji tenant cluster definition (e.g., from `kamaji-clusters/tenant-laptop.yaml`):

   ```bash
   kubectl apply -f kamaji-clusters/tenant-laptop.yaml
   ```

   Verify the tenant cluster:

   ```bash
   kubectl get tenantcontrolplanes -n kamaji-system
   ```

6. **Deploy a Demo**:
   Configure ArgoCD to sync F5 BNK or SPK manifests from `demos/f5-bnk/` or `demos/f5-spk/`:

   ```bash
   kubectl apply -f demos/f5-spk/
   ```

   Use Sveltos to deploy addons (e.g., monitoring, ingress) from `base-addons/`:

   ```bash
   kubectl apply -f base-addons/
   ```

## Configuration Notes

- **Kubeconfig**: Add `export KUBECONFIG=~/.kube/config-demo-k3s` to `~/.zshrc` or `~/.bash_profile` for persistent access.
- **MetalLB**: Disabled by default. To enable, edit `scripts/bootstrap-laptop.sh` and set `METALLB_ENABLED=true` with a valid LAN IP range (e.g., `192.168.1.220-192.168.1.230`).
- **GitOps**: Ensure your GitOps repository is configured as shown in the [README](README.md#configure-gitops-repository).

## Troubleshooting

- **VM Issues**: Check Multipass status with `multipass list` or restart the VM with `multipass restart demo-k3s`.
- **ArgoCD Access**: If the UI is inaccessible, verify the NodePort (`kubectl get svc argocd-server -n argocd`) and VM IP (`multipass info demo-k3s`).
- **Kamaji Failures**: Ensure cert-manager is running (`kubectl get pods -n cert-manager`).
- **Logs**: Check pod logs in relevant namespaces (e.g., `kubectl logs -n argocd deploy/argocd-server`).

## Next Steps

- Test tenant cluster provisioning with Kamaji.
- Deploy F5 BNK/SPK demos using ArgoCD.
- Explore addon management with Sveltos.
- Refer to the [README](README.md) for scaling to on-premises or cloud environments.