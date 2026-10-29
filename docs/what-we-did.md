# What we did to the hardened AlmaLinux AMI (in simple words)

## The goal

We had a hardened AlmaLinux 9 image for ARM (Graviton) servers:
`ami-03f31895daf07e6b7` (Veefin-AlmaLinux9-Hardened-9.8-arm64-v1).

The manager wanted the same image turned into an **EKS worker node image**, i.e. a server
that, when launched, automatically joins our Kubernetes 1.32 cluster as a node.
Our job was only to **build and hand over the AMI**. Testing it in the EKS cluster is the
manager's job.

A normal Linux server can't run Kubernetes pods. To make it a worker node we had to add
the Kubernetes pieces, loosen a few security settings that block Kubernetes networking,
and make sure it boots cleanly on any new instance.

## What we added (the Kubernetes pieces)

| Piece | What it is, simply | Version |
|---|---|---|
| containerd | The program that actually runs containers | 1.7.29 |
| runc | The low-level tool containerd uses to start each container | 1.3.3 |
| CNI plugins | Networking helpers that give pods their network | v1.6.1 |
| pause image | A tiny container every pod needs; pre-loaded so nodes don't download it | eks-distro pause 3.10 |
| kubelet | The Kubernetes agent on each node; talks to the cluster | 1.32.13 (official AWS build) |
| ecr-credential-provider | Lets the node pull images from our private ECR | from the same AWS release |
| nodeadm | The AWS tool that reads the cluster details at boot and starts kubelet | built from AWS source (v20261012), with our patch |

`nodeadm` is the "join the cluster" step. At boot it reads a small config (NodeConfig)
that Terraform puts in the instance's user data (cluster name, API endpoint, certificate),
configures containerd and kubelet, and starts them.

## What we changed in the OS

**Kernel / network settings** (needed by the AWS VPC CNI and kube-proxy):
- Turned on IP forwarding (pods' traffic passes through the node).
- Set reverse-path filtering to "loose" (pods use extra network cards; strict mode drops their traffic).
- Loaded kernel modules for container networking (overlay, br_netfilter, vxlan, etc.).
- Reserved a few ports that Kubernetes components use.

**Services:**
- **firewalld turned off** – Kubernetes manages the node's firewall rules itself (iptables); firewalld fights with it. Security is handled by AWS security groups.
- **nm-cloud-setup turned off** – a RHEL/Alma network helper that messes with the extra network cards the VPC CNI adds. AWS requires it off.
- **NetworkManager told to ignore pod network cards** – it only manages the main card (eth0).
- **systemd-firstboot turned off** – stops the "first boot setup wizard" that waits for keyboard input.

**Disk config (`/etc/fstab`):**
- Added `nofail` to the `/boot` and `/boot/efi` lines, so if those disks are slow to appear the server
  still boots instead of stopping in "emergency mode".

**Kept as-is:**
- SELinux stays **Enforcing** (we added the container SELinux policy so containers work with it).
- SSM Agent stays enabled.
- All other hardening (auditd, AIDE, SSH settings, etc.) stays. We only told AIDE to ignore
  folders that Kubernetes changes constantly, and rebuilt its database.

## The three versions

### v1 (yesterday) – didn't boot
Built and handed over, but instances launched from it got stuck at boot (failed status check),
so nobody could SSH/SSM in. See the FAQ for the reasons. We threw it away and rebuilt.

### v2 – `ami-07acbb9d74e1dc347`
Rebuilt from the original hardened AMI with the boot fixes:
- firstboot wizard disabled, and machine-id left **empty** (the correct way for images)
- `/boot` mounts made `nofail`
- fixed two "services waiting on each other in a loop" problems (nodeadm vs cloud-init)
- tested two reboots: clean, no emergency mode, SSH/SSM fine

It booted fine, but the manager's test node **didn't join the cluster**: nodeadm refused to run
because it only accepts Amazon Linux (see FAQ).

### v3 – (fill in AMI ID)
Same as v2, plus **one small patch to nodeadm** so it accepts AlmaLinux (and RHEL/Rocky)
and treats it like Amazon Linux 2023. We tested it on the build server: nodeadm now says
`Detected OS distro al2023` while `/etc/os-release` still says AlmaLinux (we didn't fake the OS).

No Terraform change needed: keep `ami_type = AL2023_ARM_64_STANDARD` and the same user data,
just swap the AMI ID.

## How we build and "seal" an image (the routine)

1. Launch a build instance (t4g.medium – smaller ones run out of memory compiling nodeadm).
2. Install / change things over SSH.
3. Reboot once and check for boot errors.
4. Clean up build tools, rebuild the AIDE database.
5. **Seal**: wipe the instance's identity so every new instance gets its own –
   empty machine-id, delete SSH host keys, reset cloud-init, clear logs, remove our SSH key – then shut down.
6. Create the AMI from the stopped instance (never start the sealed instance again).
7. Share the AMI with account `231866326739`.

## Known open points

- **cloud-init warning** `Unhandled unknown content-type (application/node.eks.aws)` – harmless, nodeadm reads the config itself.
- **auditd** is set to halt the server if the audit disk fills up. Risky for a node; waiting on security team approval to change.
- **Not built with Packer** – done manually because of the deadline. Should be automated later.
- **EKS 1.32** is in extended support (costs more per cluster hour); plan an upgrade.
- **nodeadm patch** must be re-applied whenever we update nodeadm.
- **Clean-up**: deregister v1 (and v2 once v3 is confirmed), delete their snapshots, terminate build/test instances.
