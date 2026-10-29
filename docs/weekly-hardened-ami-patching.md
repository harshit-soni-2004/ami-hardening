# Weekly Hardened AMI patching

This is the procedure used to patch `Veefin-AlmaLinux9-Hardened` in ap-south-1. Repeat it each week on a temporary instance. Do not patch a running production server in place.

The scan runs on a launched instance. It does not scan the AMI object itself. The original AMI never changes. A new AMI is published only after the patched instance is rescanned.

## This week's result (8 October 2026)

| Item | Value |
| --- | --- |
| Source AMI | `ami-01dd042ad2d0034c6` (`Veefin-AlmaLinux9-Hardened-2.0`) |
| New AMI | `ami-0c81bfee8c8088f65` (`Veefin-AlmaLinux9-Hardened-2026-10-08`) |
| Region | ap-south-1 (Mumbai) |
| OS before | AlmaLinux 9.4, kernel `5.14.0-427.18.1.el9_4` |
| OS after | AlmaLinux 9.8, kernel `5.14.0-687.54.1.el9_8` |
| Findings before | 9,305 High or Critical (9,298 High, 7 Critical), 866 distinct CVEs |
| Findings after | 4,380 High, 0 Critical, 593 distinct CVEs |
| Package updates still available | None (`dnf check-update` exit code 0) |
| Build instance | `i-01bc7ae80943c6fc1` (`veesec-ami-scan-test`), terminated after the AMI became Available |
| Local reports | `C:\Workspace\vulnerability-report-before.txt`, `C:\Workspace\vulnerability-report-after-fix.txt` |

All 7 Critical findings were cleared. The remaining 593 CVEs are marked `fixed` by Trivy, but AlmaLinux has not published an installable package for them. They are exceptions for this cycle, not missed updates.

The second-instance validation scan from the new AMI was not run before the build instance was terminated. Launch one temporary instance from `ami-0c81bfee8c8088f65` and repeat the Trivy scan before this AMI is given to other teams.

## What you need each week

- Permission to launch EC2 instances and create AMIs in the development account.
- The current Hardened AMI id.
- An SSH key pair whose `.pem` file is on your PC.
- Outbound access from the instance to AlmaLinux repositories and the Trivy repository.
- Enough disk for the update. This image's root filesystem is about 6.8 GB. A full minor-version jump filled it. Start from the current AMI, and if `df -h` shows less than 2 GB free before the update, stop and ask before growing the volume.

Use a temporary name such as `ami-patch-YYYYMMDD`. Use `t3.micro` only for this AlmaLinux image. It has about 1 GB of RAM, so `dnf` and Trivy need a 2 GB swap file.

## 1. Launch the test instance

1. EC2 → AMIs → select the current Hardened AMI → **Launch instance from AMI**.
2. Name: `ami-patch-YYYYMMDD`.
3. Instance type: `t3.micro`.
4. Key pair: your scan key.
5. Network: default VPC, auto-assign public IP enabled.
6. Security group: allow SSH (port 22) from **My IP** only. Do not leave the source as `0.0.0.0/0`.
7. Root volume: 8 GB gp3 is enough when at least 2 GB is free inside the OS. Do not add EFS or FSx.
8. Launch and wait until the state is **Running** and all status checks pass.

The original AMI is unchanged at this point.

## 2. Connect

The AMI metadata lists the user as `root`. This image rejects root login. Connect as `ec2-user`.

On Windows, if SSH reports `UNPROTECTED PRIVATE KEY FILE` or `Bad permissions` for `BUILTIN\Users`:

```powershell
icacls C:\Workspace\your-key.pem /inheritance:r
icacls C:\Workspace\your-key.pem /grant:r "${env:USERNAME}:(R)"
icacls C:\Workspace\your-key.pem /remove "BUILTIN\Users"
ssh -i C:\Workspace\your-key.pem ec2-user@<public-ip>
```

`${env:USERNAME}` is not a placeholder. Paste it exactly. PowerShell substitutes your Windows login.

A successful login looks like:

```text
[ec2-user@ip-172-31-... ~]$
```

If the first SSH attempt sits on a blank line, wait 20 seconds and retry. A later `Permission denied (publickey)` for `root` means the network path is fine and the user name is wrong. Use `ec2-user`.

## 3. Record the baseline

```bash
cat /etc/os-release
uname -a
df -h
systemctl --type=service --state=running
sudo ss -tulpn
```

Save this output. Expected starting point for the current image is AlmaLinux 9.x on x86_64, with `sshd` listening on port 22 and `chronyd` listening only on localhost.

## 4. Add swap, then install Trivy

`t3.micro` kills `dnf` with the message `Killed` when memory runs out. Create swap before installing or scanning:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
free -h
```

`free -h` should show about 2 GB of swap. If `fallocate` says `No space left on device` and `/swapfile` already exists, do not create another one. Run `sudo swapon /swapfile`.

Install Trivy from the official AlmaLinux RPM repository:

```bash
sudo tee /etc/yum.repos.d/trivy.repo << 'EOF'
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://aquasecurity.github.io/trivy-repo/rpm/public.key
EOF
sudo dnf install -y trivy
trivy --version
```

The quoted `'EOF'` is required so `$basearch` is written into the repo file.

## 5. Baseline scan

```bash
sudo trivy rootfs / --severity HIGH,CRITICAL --format table --output /home/ec2-user/vulnerability-report-before.txt
```

The first run downloads the vulnerability database (about 120 MB) and can sit for several minutes. Read the summary:

```bash
sudo grep -m1 '^Total:' /home/ec2-user/vulnerability-report-before.txt
sudo grep -oE 'CVE-[0-9]+-[0-9]+' /home/ec2-user/vulnerability-report-before.txt | sort -u | wc -l
```

The `Total:` line counts each package and CVE pair. The `wc -l` line counts distinct CVE ids. Record both.

Warnings about large files under `/var/log/audit/` are memory warnings. They are not vulnerabilities. SSH host keys and `/var/lib/amazon/ssm/credentials` may appear as secrets. Those are this instance's own keys. Do not delete them to clear the finding.

## 6. Patch

```bash
sudo dnf update -y
```

On a `t3.micro` that is several minor versions behind, this takes 15 to 40 minutes. It is still working during long pauses on `Downloading packages` or `Running transaction`. Stop only if there is no new output for 20 minutes, or if the output says `Killed` or `No space left on device`.

`Complete!` means the vendor packages that the enabled repositories offered are installed. Then:

```bash
sudo needs-restarting -r
```

A new kernel requires a reboot. This week the reboot was required because the kernel changed. Run:

```bash
sudo reboot
```

The SSH session disconnects. Wait about a minute and connect again with the same `ssh` command. Confirm the new kernel:

```bash
uname -a
```

Swap does not survive a reboot. The swap file is still on disk, so turn it back on instead of creating a second file:

```bash
sudo swapon /swapfile
sudo dnf clean all
df -h /
```

`dnf clean all` deletes cached packages and frees space for the rescan.

## 7. Rescan

```bash
sudo trivy rootfs / --severity HIGH,CRITICAL --scanners vuln --format table --output /home/ec2-user/vulnerability-report-after-fix.txt
sudo grep -m1 '^Total:' /home/ec2-user/vulnerability-report-after-fix.txt
sudo grep -oE 'CVE-[0-9]+-[0-9]+' /home/ec2-user/vulnerability-report-after-fix.txt | sort -u | wc -l
```

`--scanners vuln` skips secret scanning so the small instance is less likely to run out of memory.

Check whether any installed package is still behind the repositories:

```bash
sudo dnf check-update --refresh
echo "dnf-exit:$?"
```

- Exit code **0** and no package list: there is nothing left to install. Remaining Trivy rows are exceptions.
- Exit code **100**: more packages are listed. Review that list, then run `sudo dnf update -y` again and rescan.

To see whether remaining findings have a vendor fix:

```bash
sudo python3 - << 'PY'
import json, subprocess
from collections import Counter
raw = subprocess.check_output([
    "trivy", "rootfs", "/", "--severity", "HIGH,CRITICAL",
    "--scanners", "vuln", "--format", "json", "--quiet"
], text=True)
c = Counter()
for result in json.loads(raw).get("Results", []):
    for vuln in result.get("Vulnerabilities") or []:
        c[vuln.get("Status", "unknown")] += 1
for status, count in c.most_common():
    print(f"{status}: {count}")
PY
```

`fixed` with `dnf-exit:0` means Trivy knows a patched version that AlmaLinux has not published in the enabled repositories yet. Do not remove or downgrade packages to force the count to zero. Write those CVEs down as exceptions: CVE, severity, package, reason, and the date of this scan.

## 8. Check the system

```bash
systemctl --type=service --state=running
sudo ss -tulpn
```

Before creating the AMI, `sshd` and `amazon-ssm-agent` should be running. `chronyd` should be listening on localhost only. Investigate any service that was running in the baseline and is now failed.

## 9. Copy the reports, then clean the instance

From the instance:

```bash
sudo chown ec2-user:ec2-user /home/ec2-user/vulnerability-report-*.txt
sudo chmod 644 /home/ec2-user/vulnerability-report-*.txt
```

From PowerShell on your PC:

```powershell
scp -i C:\Workspace\your-key.pem ec2-user@<public-ip>:~/vulnerability-report-before.txt C:\Workspace\
scp -i C:\Workspace\your-key.pem ec2-user@<public-ip>:~/vulnerability-report-after-fix.txt C:\Workspace\
```

`100%` in the `scp` output means the file is on your PC. Then remove the scan tools so they are not baked into the AMI:

```bash
sudo dnf remove -y trivy
sudo rm -f /etc/yum.repos.d/trivy.repo
sudo swapoff /swapfile
sudo rm -f /swapfile /home/ec2-user/vulnerability-report-*.txt
sudo rm -rf /root/.cache/trivy /home/ec2-user/.cache/trivy
sudo cloud-init clean --logs
history -c
rm -f ~/.bash_history
exit
```

## 10. Create the AMI

EC2 → Instances → select only the patch instance → **Actions → Image and templates → Create image**.

- Name: `Veefin-AlmaLinux9-Hardened-YYYY-MM-DD`
- Description: source AMI id, resulting AlmaLinux version, Critical count, and the number of High CVEs left with no installable package.
- Boot mode: **Default**.
- **Reboot instance**: checked.
- Keep the existing 8 GB gp3 root volume. Encryption enabled is correct. Delete on termination applies only to future instances launched from this AMI.

Click **Create image**. The status stays **Pending** for about 5 to 15 minutes. Refresh **EC2 → AMIs** until it is **Available**. Do not terminate the instance while the status is Pending.

This week's AMI is `ami-0c81bfee8c8088f65`.

## 11. Terminate only the test instance

After the new AMI is **Available**:

1. EC2 → Instances.
2. Search for that week's instance id. Do not rely on the unfiltered instance list. This account has many other running servers.
3. Select only the patch instance.
4. **Instance state → Terminate instance**.
5. Leave **Skip OS shutdown** unchecked.
6. Confirm **Terminate (delete)**.

The root disk of the test instance is deleted. The AMI and its snapshot remain. The previous AMI stays in place for rollback. Do not deregister it in the same week.

## 12. Validate the new AMI

Launch a new temporary `t3.micro` from the **new** AMI, not from the original one. Connect as `ec2-user`.

```bash
cat /etc/os-release
uname -a
```

Confirm the AlmaLinux version and kernel match the patch notes. Add swap, install Trivy again, and run the same High and Critical scan. Critical should remain 0, and the High count should match the after-fix report. Then remove Trivy and terminate this validation instance too.

## Cost

While the test instance runs in ap-south-1 it costs about $0.017 per hour: $0.0112 for `t3.micro`, $0.005 for the public IPv4 address, and about $0.001 for the 8 GB gp3 disk. Terminate it after the AMI is Available. The private AMI has no software fee. Its snapshot costs about $0.05 per GB-month, which is under $1 per month for this image.

## Weekly close-out

Record these in the ticket:

- Source AMI id and new AMI id
- OS and kernel before and after
- High and Critical counts before and after, plus distinct CVE counts
- `dnf check-update` exit code
- Exception statement for CVEs that remain because no package is available
- Confirmation that `sshd` and `amazon-ssm-agent` were running
- Confirmation that the build instance was terminated and the previous AMI was kept
- Paths of the two saved reports
