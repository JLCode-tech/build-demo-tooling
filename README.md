# Multi-Tenant Kubernetes Demo Platform

This project provides a lightweight, automated platform for managing multiple Kubernetes tenant clusters using a single management cluster. It enables rapid, repeatable deployments of F5 BIG-IP Next Kubernetes (BNK) and Service Proxy Kubernetes (SPK) for business development (BD) and sales demos.

## Overview

- **Goal**: Use a single lightweight Kubernetes (k3s) management cluster to bootstrap and manage multiple tenant clusters for easy, repeatable demos.
- **Key Features**:
  - Automated lifecycle management (create, update, delete) of tenant clusters.
  - Reusable cluster templates for consistent deployments.
  - GitOps-driven configuration with ArgoCD for declarative, version-controlled setups.
  - Automated deployment of F5 BNK or SPK on tenant clusters.
  - Support for laptop, on-premises, and public cloud environments.

## Architecture

The platform uses a single **k3s management cluster** to orchestrate tenant clusters, leveraging the following tools:

### Tools and Roles

- **Kamaji**: Manages tenant cluster control planes for efficient multi-tenancy without dedicated VMs.
- **ArgoCD**: GitOps tool for continuous deployment and configuration management from Git repositories.
- **Crossplane**: Declarative infrastructure provisioning (cloud or on-premises) using Kubernetes YAML manifests.
- **Metal3.io**: Provisions bare-metal nodes (optional, for dedicated hardware scenarios).
- **Sveltos**: Simplifies declarative management of addons (e.g., logging, monitoring, ingress) across multiple clusters.

### Architecture Diagram

```
+---------------------------------------------------------------+
| Management Cluster (k3s)                                      |
|---------------------------------------------------------------|
| Kamaji   | Sveltos | ArgoCD   | Crossplane | Metal3.io (opt.) |
| Tenant   | Addon   | GitOps   | Infra      | Bare-metal       |
| Control  | Mgmt    | Delivery | Provision  | Provisioning     |
+---------------------------------------------------------------+
          ↓ Tenant Clusters (auto-provisioned) ↓
+---------------------------------------------+
| Tenant-a | F5 BNK                           |
| Tenant-b | F5 SPK                           |
| Tenant-c | Base Kubernetes                 |
| ...      |                                 |
+---------------------------------------------+
```

## Workflow

1. **Setup Management Cluster**:
   - Deploy k3s (lightweight Kubernetes).
   - Install Kamaji, ArgoCD, Crossplane, Sveltos, and (optionally) Metal3.io.
2. **Provision Tenant Clusters**:
   - Kamaji creates tenant control planes.
   - Crossplane (and Metal3.io, if needed) provisions worker nodes.
3. **Configure with GitOps**:
   - ArgoCD syncs cluster configurations (RBAC, networking, monitoring) from Git.
   - Sveltos deploys consistent addons across clusters.
4. **Deploy F5 Products**:
   - ArgoCD applies F5 BNK or SPK manifests from Git.
   - Sveltos ensures consistent addon deployments for demos.

### Example Demo Scenario

1. A team member requests an F5 SPK demo.
2. Kamaji provisions a tenant cluster control plane (~minutes).
3. Crossplane/Metal3 provisions worker nodes.
4. ArgoCD syncs base configurations (e.g., Prometheus, Grafana, ingress).
5. Sveltos applies multi-cluster addons.
6. ArgoCD deploys F5 SPK manifests, making the cluster demo-ready.

## Implementation Steps

### 1. Bootstrap Management Cluster
Install k3s on your chosen environment (laptop, on-premises, or cloud):

```bash
curl -sfL https://get.k3s.io | sh -
kubectl get nodes
```

### 2. Install Core Tools
Deploy Kamaji, ArgoCD, Crossplane, Sveltos, and (optionally) Metal3.io using Helm or manifests:
- **Kamaji**: [clastix/kamaji](https://github.com/clastix/kamaji)
- **ArgoCD**: [argo-cd.readthedocs.io](https://argo-cd.readthedocs.io/)
- **Crossplane**: [crossplane.io/docs](https://crossplane.io/docs)
- **Metal3.io**: [metal3.io](https://metal3.io)
- **Sveltos**: [projectsveltos/sveltos](https://github.com/projectsveltos/sveltos)

Example: Install ArgoCD with Helm:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --version=x.y.z -n argocd --create-namespace
```

### 3. Configure GitOps Repository
Structure your Git repository for portability and automation:

```
demo-environment-gitops/
├── README.md
├── documentation/
│   ├── quickstart-laptop.md
│   ├── quickstart-onprem.md
│   └── quickstart-cloud.md
├── infra-setup/
│   ├── crossplane-provider/  # Cloud/on-prem infrastructure
│   ├── metallb/             # Load balancer manifests
│   └── metal3/              # Bare-metal provisioning
├── kamaji-clusters/         # Tenant cluster definitions
│   ├── tenant-laptop.yaml
│   ├── tenant-onprem.yaml
│   └── tenant-cloud.yaml
├── base-addons/             # Monitoring, ingress, storage
├── demos/                   # F5 product manifests
│   ├── f5-bnk/
│   └── f5-spk/
├── clusters-apps/           # Optional advanced demo apps
└── scripts/                 # Bootstrap scripts
    ├── bootstrap-laptop.sh
    ├── bootstrap-onprem.sh
    └── bootstrap-cloud.sh
```

### 4. Deploy F5 Products
- Add F5 BNK/SPK manifests to `demos/f5-bnk/` or `demos/f5-spk/`.
- ArgoCD applies these manifests to tenant clusters.
- Use Sveltos for consistent multi-cluster addon deployments.

## Benefits

- **Rapid Demos**: Spin up tenant clusters in minutes for sales/BD teams.
- **Consistency**: GitOps ensures repeatable, version-controlled configurations.
- **Multi-Tenancy**: Kamaji enables efficient tenant cluster management.
- **Flexibility**: Supports laptop, on-premises, and cloud environments.
- **Automation**: Crossplane and Metal3 streamline infrastructure provisioning.

## Recommended Tooling

### Core Infrastructure
- **Kubernetes**: k3s (lightweight, portable).
- **IaC**: Crossplane (cloud/on-prem provisioning).
- **Bare-Metal**: Metal3.io (optional).
- **GitOps**: ArgoCD.
- **Multi-Cluster Addons**: Sveltos.
- **Container Registry**: Docker Hub, Harbor, or cloud-native registries (ECR/ACR/GCR).

### Observability & Security
- **Monitoring**: Prometheus, Grafana, Loki, OpenTelemetry.
- **Ingress**: Nginx, Traefik, or F5 CIS.
- **Storage**: Longhorn, Rook/Ceph, or OpenEBS.
- **Secrets**: Vault, Sealed Secrets, or External Secrets.
- **DNS/Certs**: External DNS, cert-manager.
- **Backup**: Velero or Kasten.
- **Load Balancer**: MetalLB.

### Optional Tools
- **CI/CD**: GitHub Actions, Tekton, or GitLab Runner.
- **Service Mesh**: Istio, Linkerd, or Kuma.
- **Log Aggregation**: Grafana Loki or Elastic Stack.

## Supported Environments

| Environment | Tools | Notes |
|-------------|-------|-------|
| **Laptop** | k3s, Kamaji, ArgoCD, Crossplane, MetalLB, Sveltos | Lightweight, portable demos. |
| **On-Premises** | k3s, Kamaji, ArgoCD, Crossplane, Metal3.io, MetalLB, Sveltos | Bare-metal or VM-based, uses Metal3 for hardware. |
| **Cloud (AWS/Azure/GCP)** | k3s or cloud-managed Kubernetes, Kamaji, ArgoCD, Crossplane, cloud LB, Sveltos | Cloud-native integrations via Crossplane. |

## Roadmap

1. **Phase 1 (PoC)**:
   - Test k3s + Kamaji + ArgoCD + MetalLB + Crossplane on a laptop.
   - Validate multi-tenant cluster provisioning.
2. **Phase 2 (On-Premises)**:
   - Deploy to a UDF lab or datacenter.
   - Add Metal3.io for bare-metal provisioning.
3. **Phase 3 (Cloud)**:
   - Extend to AWS, Azure, or GCP with Crossplane cloud providers.
   - Document playbooks for sales/BD teams.

## Next Steps

- Start with a laptop-based PoC to validate core components.
- Test each tool (Kamaji, ArgoCD, Crossplane, Sveltos) independently.
- Build documentation and scripts for repeatability.
- Expand to on-premises or cloud environments as needed.