# AMI Hardening Automation & Security Baseline

Automation scripts and procedures for building, hardening, and maintaining Linux AMIs (AlmaLinux 9 on ARM64 / x86_64).

## Overview

This repository contains security hardening delta scripts and SSH access provisioning tools used to align base AMIs with CIS benchmarks and organizational compliance standards:

- **`apply-delta.sh`**: Reproduces CIS Linux hardening deltas on ARM64 (`aarch64`) / x86_64 instances. Installs AIDE, firewalld, configures strict sysctl parameters (`net.ipv4.ip_forward`, redirects, source routing), and locks down kernel modules and banners.
- **`add-team-keys.sh`**: Safely provisions authorized developer SSH public keys from a CSV file. Ensures passwords stay locked, enforces public key auth, and strictly rejects any private keys.
- **`docs/`**: Operational documentation including:
  - `weekly-hardened-ami-patching.md`: Weekly validation and patch cycle workflows.
  - `what-we-did.md`: Architectural details of kernel and system adjustments.
  - `faq.md`: Frequently asked questions and troubleshooting guides.

## Usage

### 1. Apply Hardening Delta
Run as root on the target builder instance:
```bash
sudo bash apply-delta.sh
```

For container host configurations (enables container networking forwarding exceptions):
```bash
sudo DOCKER=1 bash apply-delta.sh
```

### 2. Provision Authorized Public Keys
```bash
sudo bash add-team-keys.sh /path/to/public_keys.csv
```

## Security Notice

- Never commit private keys (`.pem`, `.id_rsa`) or production key CSV files to this repository.
