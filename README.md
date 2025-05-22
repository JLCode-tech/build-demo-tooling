# README.md

# Kubernetes Multi-Cluster Demo Environment (M-Series MacBook + Podman)

## Overview

This repository contains an automated GitOps-driven local Kubernetes demo environment.  
It enables team members to easily deploy repeatable Kubernetes clusters and workloads  
on Apple Silicon MacBook Pro (M1/M2) devices using:  
  
- K3s for Lightweight Kubernetes clusters  
- Podman as container runtime  
- Kamaji (multi-tenant control plane manager)  
- ArgoCD (GitOps continuous delivery)  
- Crossplane (Infrastructure Provider)  
- Sveltos (for multi-cluster add-ons management)  
- MetalLB (LoadBalancer for local infrastructure access)

## Quick Setup

1. Ensure your local machine meets all prerequisites (see docs/prereqs-macos-m2.md).

2. Identify and set your MetalLB IP address range clearly in scripts/bootstrap-mac-m2.sh to match your actual local LAN network.

3. Run the bootstrap script provided here from the project root clearly:

chmod +x scripts/bootstrap-mac-m2.sh  
./scripts/bootstrap-mac-m2.sh  

4. Upon successful completion, the bootstrap script output will include your ArgoCD IP, username, and password.  
Use these credentials to login to your ArgoCD UI dashboard.

## Folder Structure Explained

```
build-demo-tooling/
├── addons/               # Kubernetes addon manifests (Ingress, cert-manager, monitoring).
├── clusters/             # Tenant clusters (Kamaji definition YAML).
├── demos/
│   ├── f5-bnk/           # F5 BNK demo manifests.
│   └── f5-spk/           # F5 SPK demo manifests/applications.
├── docs/
│   └── prereqs-macos-m2.md  # System prerequisite steps/documentation for Mac (M-series)
├── infra/                # Infrastructure dependencies (MetalLB, Crossplane, etc.).
├── scripts/
│   └── bootstrap-mac-m2.sh # Automated setup & bootstrap script.
└── README.md             # Root documentation.
```
```