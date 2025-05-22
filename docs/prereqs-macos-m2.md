# Prerequisites for Kubernetes Multi-Cluster Demo (MacBook M-Series + Podman)

Before running the Kubernetes demo environment setup, carefully ensure you have satisfied the following requirements on your M-Series Mac computer (M1 or M2).

## Hardware and Software Requirements

- Apple Silicon Mac (M1/M2 chip).
- macOS Ventura (13.x) or Monterey (12.x).
- Active internet connection (required for downloads).
- User with sudo privileges (Administrator access).

## Install Homebrew

Homebrew is required.  
Use the following if not already installed:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew update
```

## Install Podman Container Engine

Install Podman with Homebrew and configure machine VM clearly:

```bash
brew install podman
podman machine init --cpus=2 --memory=4096 --disk-size=20
podman machine start
```

Verify Podman installation and VM running successfully:

```bash
podman info
```

## Kubernetes CLI (`kubectl`)

Kubectl will automatically be installed via bootstrap script.  
(Optional) if you wish to install manually:

```bash
brew install kubectl
```

## Selecting IP range for MetalLB Load-balancer (Important!)

Clearly identify your current LAN network subnet using:

```bash
ifconfig en0
```

Example output typically:

```
inet 192.168.1.52 netmask 0xffffff00 broadcast 192.168.1.255
```

Example subnet above: `192.168.1.0/24`.  
Choose a small range of unused IP addresses at the higher end of your subnet (eg. `192.168.1.240-192.168.1.250`).  

Double-check carefully to ensure these IP addresses are not already assigned elsewhere on your LAN to avoid conflicts.

IMPORTANT: Clearly edit this IP range into `scripts/bootstrap-mac-m2.sh` BEFORE running the script.