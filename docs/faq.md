# AMI FAQ – questions and answers as we learn

Add new questions at the bottom. Keep answers simple; put commands/logs under "Evidence".

---

## 1. Why couldn't we SSH or SSM into instances launched from yesterday's (v1) AMI?

**Short answer:** the server never finished booting. It got stuck in **emergency mode**,
a rescue mode where systemd stops and waits for someone at the keyboard. In that mode the
network services, **sshd and the SSM agent never start**, so there is nothing to connect to.
AWS saw the server wasn't responding and showed **"Instance status check failed"**.

And because the root account is locked in our hardened image, the emergency shell can't
even be used from the serial console – it just sits there.

**Why it got stuck – three problems together:**

1. **Services waiting on each other in a loop (ordering cycle).**
   We had told `nodeadm-config` to start *before* cloud-init and *after* "network is up".
   On AlmaLinux, cloud-init itself runs before "network is up". So A waits for B, B waits
   for A. systemd breaks the loop by randomly dropping some services from the boot, which
   can include important ones.

2. **The machine-id was set to `uninitialized`.**
   When sealing v1, the machine-id file was left containing the word `uninitialized`.
   systemd reads that as "this is a brand-new computer, run first-time setup". That:
   - starts the **systemd-firstboot wizard**, which asks questions (timezone, root password…) and
     **waits for keyboard input** that never comes on a cloud server, and
   - resets which services are enabled back to the OS defaults, undoing some of our settings.

   The correct way for cloud images is an **empty** machine-id file: a fresh ID is
   generated silently on first boot.

3. **The `/boot` disk mounts had no safety net.**
   `/etc/fstab` mounts `/boot` and `/boot/efi` by disk ID. On the new instance those mounts
   timed out during boot. Without the `nofail` option, a failed mount sends the whole server
   to emergency mode.
   (The disk IDs themselves are fine – they are copied into every instance with the AMI;
   the problem was the missing `nofail`.)

**How we fixed it in v2/v3:**
- Fixed the service ordering (and found/fixed a second loop between `nodeadm-run` and cloud-init).
- Masked `systemd-firstboot` and seal with an **empty** machine-id.
- Added `nofail,x-systemd.device-timeout=30s` to the `/boot` and `/boot/efi` lines.
- **Rebooted the build server before sealing** to prove it comes back cleanly. We didn't do this for v1.

**Lesson:** always reboot-test before creating the image, and check the console log
(EC2 → instance → Actions → Monitor and troubleshoot → Get system log) when an instance
fails its status check. That log shows the boot messages even when SSH is impossible.

**Evidence:** the v1 system log showed `ordering cycle` messages, first-boot prompts, a
`/boot` mount timeout and the server dropping into emergency mode. We never found the exact
reason the `/boot` mount timed out (most likely the disk wasn't detected in time early in
boot); `nofail` makes the server boot either way.

---

## 2. v2 booted fine – why didn't the node join the EKS cluster?

**Short answer:** nodeadm (the AWS "join the cluster" tool) has a built-in check that only
allows Amazon Linux. On AlmaLinux it stopped immediately, so kubelet never started.

**Evidence** (from the manager's test node):
```
nodeadm: fatal ... unsupported OS in /etc/os-release: ID="almalinux" VERSION_ID="9.8" (want amzn 2023 or 2027)
```

**Fix (v3):** we patched nodeadm (`internal/system/osrelease.go`) to accept `almalinux`,
`rhel` and `rocky` and treat them like Amazon Linux 2023. In this nodeadm version the OS
only switches two Amazon-Linux-2027-specific behaviours (DNS via systemd-resolved and
naming nodes by instance ID), so the AL2023 behaviour is the right one for AlmaLinux.
We did **not** fake `/etc/os-release`.

---

## 3. Is the cloud-init warning about `application/node.eks.aws` a problem?

**No.** cloud-init on AlmaLinux doesn't recognise the EKS part of the user data and logs
`Unhandled unknown content-type (application/node.eks.aws)`. That's only a warning.
nodeadm reads the user data directly from the instance metadata service, so the node
config still gets applied.
