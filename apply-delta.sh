#!/bin/bash
# Apply the Veefin AlmaLinux 9 hardening delta on an arm64 instance.
# Source of the delta: stock AlmaLinux 9.8 x86_64 vs Veefin-AlmaLinux9-Hardened-2.0 (9.4).
# The CIS files on that image were written by ansible-lockdown RHEL9-CIS on 2024-05-28.
# This script reproduces those settings. It does not copy the x86 /etc tree.
#
# Intentionally omitted:
#   local users and their sudoers drop-ins
#   Wazuh agent, its client key, and the registration password
#   PHP, supervisor, telnet, nano, htop, nc, EPEL
#   the x86 Inspector plugin binary
#   the Chrony rewrite that removed Amazon Time Sync
#   commenting out SHA_CRYPT_MAX_ROUNDS (that weakened hashing versus current AlmaLinux 9)
#
# Run as root on the arm64 builder: bash apply-delta.sh
# For a Docker host image:            DOCKER=1 bash apply-delta.sh
#   DOCKER=1 installs Docker CE and sets net.ipv4.ip_forward = 1 (a documented CIS 3.3.1 exception;
#   container networking does not work with forwarding off).
set -euo pipefail
DOCKER="${DOCKER:-0}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi
if [[ "$(uname -m)" != "aarch64" ]]; then
  echo "This script is for aarch64. uname -m returned $(uname -m)." >&2
  exit 1
fi

echo "Installing AIDE and firewalld..."
dnf install -y aide firewalld

install_file() {
  local path="$1"
  local mode="$2"
  local owner="${3:-root:root}"
  cat > "$path"
  chown "$owner" "$path"
  chmod "$mode" "$path"
}

echo "Writing sysctl, module, banner, and session files..."
install_file /etc/sysctl.d/60-netipv4_sysctl.conf 0644 << 'EOF'
# IPv4 settings from the Veefin hardened image (CIS 3.2 / 3.3).
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
EOF

install_file /etc/sysctl.d/60-netipv6_sysctl.conf 0644 << 'EOF'
# IPv6 settings from the Veefin hardened image.
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
EOF

install_file /etc/sysctl.d/60-kernel_sysctl.conf 0644 << 'EOF'
# CIS 1.5.3
kernel.randomize_va_space = 2
EOF

install_file /etc/modprobe.d/CIS.conf 0644 << 'EOF'
install squashfs /bin/true
install udf /bin/true
install usb-storage /bin/true
EOF

install_file /etc/modprobe.d/blacklist.conf 0644 << 'EOF'
blacklist squashfs
blacklist udf
blacklist usb-storage
blacklist tipc
EOF

install_file /etc/modprobe.d/tipc.conf 0644 << 'EOF'
install tipc /bin/true
EOF

install_file /etc/issue 0644 << 'EOF'
Authorized uses only. All activity may be monitored and reported.
EOF
install_file /etc/issue.net 0644 << 'EOF'
Authorized uses only. All activity may be monitored and reported.
EOF

install_file /etc/profile.d/tmout.sh 0644 << 'EOF'
# CIS session timeout, matching the hardened image.
TMOUT=600
export TMOUT
readonly TMOUT
EOF

sysctl --system >/dev/null

echo "Updating login, password, and sudo policy..."
sed -i \
  -e 's/^UMASK[[:space:]]\+022/UMASK\t\t027/' \
  -e 's/^PASS_MAX_DAYS[[:space:]]\+99999/PASS_MAX_DAYS\t365/' \
  -e 's/^PASS_MIN_DAYS[[:space:]]\+0/PASS_MIN_DAYS\t7/' \
  -e 's/^USERGROUPS_ENAB[[:space:]]\+yes/USERGROUPS_ENAB no/' \
  /etc/login.defs
sed -i 's/^INACTIVE=.*/INACTIVE=30/' /etc/default/useradd
sed -i 's/`umask` -eq 0 ] && umask 022/`umask` -eq 0 ] \&\& umask 027/' /etc/bashrc

grep -q '^minlen' /etc/security/pwquality.conf || cat >> /etc/security/pwquality.conf << 'EOF'
minlen = 14
minclass = 4
EOF
grep -q '^deny' /etc/security/faillock.conf || cat >> /etc/security/faillock.conf << 'EOF'
deny = 5
unlock_time = 900
EOF
if [[ -f /etc/security/pwhistory.conf ]]; then
  grep -q '^remember' /etc/security/pwhistory.conf || echo 'remember = 5' >> /etc/security/pwhistory.conf
fi

if ! getent group nosugroup >/dev/null; then
  groupadd nosugroup
fi
if grep -q '^#auth[[:space:]]\+required[[:space:]]\+pam_wheel.so use_uid' /etc/pam.d/su; then
  sed -i 's/^#auth[[:space:]]\+required[[:space:]]\+pam_wheel.so use_uid.*/auth           required        pam_wheel.so use_uid group=nosugroup/' /etc/pam.d/su
fi

authselect enable-feature with-faillock >/dev/null 2>&1 || true
authselect enable-feature with-pwhistory >/dev/null 2>&1 || true
# Faillock numbers above are what authselect reads from faillock.conf on AlmaLinux 9.

install_file /etc/sudoers.d/99-cis-defaults 0440 << 'EOF'
Defaults    use_pty
Defaults    logfile="/var/log/sudo.log"
Defaults    timestamp_timeout=15
EOF
visudo -cf /etc/sudoers.d/99-cis-defaults

echo "Updating sshd..."
install_file /etc/ssh/sshd_config.d/00-veefin-hardening.conf 0644 << 'EOF'
# Read first so these values win over 50-redhat.conf.
LogLevel INFO
LoginGraceTime 60
PermitRootLogin no
MaxAuthTries 4
MaxSessions 4
HostbasedAuthentication no
IgnoreRhosts yes
PermitEmptyPasswords no
UsePAM yes
AllowTcpForwarding no
X11Forwarding no
PermitUserEnvironment no
MaxStartups 10:30:60
DenyUsers nobody
Banner /etc/issue.net
ClientAliveInterval 15
ClientAliveCountMax 3
EOF
if [[ -f /etc/ssh/sshd_config.d/50-redhat.conf ]]; then
  sed -i 's/^X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config.d/50-redhat.conf
fi
sshd -t
systemctl reload sshd

echo "Configuring firewalld, logging, audit, and AIDE..."
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=dhcpv6-client
firewall-cmd --permanent --add-service=cockpit
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="127.0.0.1" destination not address="127.0.0.1" drop'
firewall-cmd --permanent --add-rich-rule='rule family="ipv6" source address="::1" destination not address="::1" drop'
firewall-cmd --reload

install_file /etc/rsyslog.d/60-cis.conf 0644 << 'EOF'
# Extra log files from the hardened image.
$FileCreateMode 0640
cron.*                                                   /var/log/cron
auth,authpriv.*                                          /var/log/secure
local0,local1.*                                          -/var/log/localmessages
local2,local3.*                                          -/var/log/localmessages
local4,local5.*                                          -/var/log/localmessages
local6,local7.*                                          -/var/log/localmessages
*.emerg                                                   :omusrmsg:*
*.=warning;*.=err                                        -/var/log/warn
*.crit                                                   /var/log/warn
EOF
sed -i 's/^#ForwardToSyslog=.*/ForwardToSyslog=yes/' /etc/systemd/journald.conf
grep -q '^ForwardToSyslog=yes' /etc/systemd/journald.conf || echo 'ForwardToSyslog=yes' >> /etc/systemd/journald.conf
systemctl restart systemd-journald
systemctl restart rsyslog

sed -i \
  -e 's/^max_log_file_action.*/max_log_file_action = keep_logs/' \
  -e 's/^space_left_action.*/space_left_action = email/' \
  -e 's/^admin_space_left_action.*/admin_space_left_action = halt/' \
  /etc/audit/auditd.conf

if grep -q '^Storage=' /etc/systemd/coredump.conf; then
  sed -i 's/^Storage=.*/Storage=none/' /etc/systemd/coredump.conf
else
  printf '\nStorage=none\nProcessSizeMax=0\n' >> /etc/systemd/coredump.conf
fi
sed -i 's/^#NAutoVTs=.*/NAutoVTs=0/' /etc/systemd/logind.conf
grep -q '^NAutoVTs=0' /etc/systemd/logind.conf || echo 'NAutoVTs=0' >> /etc/systemd/logind.conf
sed -i 's/^weekly$/daily/' /etc/logrotate.conf
if [[ -f /etc/sysconfig/chronyd ]]; then
  sed -i 's/^OPTIONS=.*/OPTIONS="-u chrony"/' /etc/sysconfig/chronyd
fi

grep -q '/dev/shm' /etc/fstab || echo 'tmpfs /dev/shm tmpfs defaults,nodev,noexec,nosuid 0 0' >> /etc/fstab
mount -o remount,nodev,noexec,nosuid /dev/shm

grubby --update-kernel=ALL --args="audit=1 audit_backlog_limit=8192"

install_file /etc/audit/rules.d/99_auditd.rules 0640 << 'EOF'
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d -p wa -k scope
-a always,exit -F arch=aarch64 -S execve -C uid!=euid -F auid!=-1 -F key=user_emulation
-w /var/log/sudo.log -p wa -k sudo_log_file
-a always,exit -F arch=aarch64 -S adjtimex,settimeofday,clock_settime -F key=time-change
-w /etc/localtime -p wa -k time-change
-a always,exit -F arch=aarch64 -S sethostname,setdomainname -F key=system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/sysconfig/network -p wa -k system-locale
-w /etc/sysconfig/network-scripts -p wa -k system-locale
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-a always,exit -F arch=aarch64 -S fchmodat -F auid>=1000 -F auid!=-1 -F key=perm_mod
-a always,exit -F arch=aarch64 -S fchownat,fchown -F auid>=1000 -F auid!=-1 -F key=perm_mod
-a always,exit -F arch=aarch64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=-1 -F key=perm_mod
-a always,exit -F arch=aarch64 -S mount -F auid>=1000 -F auid!=-1 -F key=mounts
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock -p wa -k logins
-a always,exit -F arch=aarch64 -S renameat,unlinkat -F auid>=1000 -F auid!=-1 -F key=delete
-w /etc/selinux -p wa -k MAC-policy
-w /usr/share/selinux -p wa -k MAC-policy
-a always,exit -F arch=aarch64 -S openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=-1 -F key=access
-a always,exit -F arch=aarch64 -S openat,truncate,ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=-1 -F key=access
-a always,exit -F arch=aarch64 -S init_module,delete_module,finit_module -F auid>=1000 -F auid!=-1 -F key=kernel_modules
-w /usr/bin/kmod -p x -k kernel_modules
-w /usr/bin/sudo -p x -k privileged
-w /usr/bin/su -p x -k privileged
-w /usr/bin/passwd -p x -k privileged
-w /usr/bin/chage -p x -k privileged
-w /usr/bin/mount -p x -k privileged
-w /usr/bin/umount -p x -k privileged
-e 2
EOF
systemctl daemon-reload
if command -v service >/dev/null 2>&1; then
  service auditd restart
else
  augenrules --load
fi

install_file /etc/cron.d/aide_cron 0644 << 'EOF'
# Run AIDE integrity check, matching the hardened image.
0 5 * * * root /usr/sbin/aide --check
EOF

echo "Installing the arm64 SSM Agent..."
dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_arm64/amazon-ssm-agent.rpm
systemctl enable --now amazon-ssm-agent

if [[ "$DOCKER" == "1" ]]; then
  echo "Installing Docker CE..."
  install_file /etc/sysctl.d/99-docker.conf 0644 << 'EOF'
# CIS 3.3.1 exception: Docker bridge networking needs IPv4 forwarding.
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null
  dnf install -y dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker run --rm hello-world
fi

echo "Checking the settings that must match the hardened image..."
fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "ok  $name=$got"
  else
    echo "MISMATCH  $name got=$got want=$want" >&2
    fail=1
  fi
}
check permitrootlogin "$(sshd -T | awk '/^permitrootlogin /{print $2}')" no
check x11forwarding "$(sshd -T | awk '/^x11forwarding /{print $2}')" no
check allowtcpforwarding "$(sshd -T | awk '/^allowtcpforwarding /{print $2}')" no
check banner "$(sshd -T | awk '/^banner /{print $2}')" /etc/issue.net
if [[ "$DOCKER" == "1" ]]; then
  check ip_forward "$(sysctl -n net.ipv4.ip_forward)" 1
  systemctl is-active docker
else
  check ip_forward "$(sysctl -n net.ipv4.ip_forward)" 0
fi
check shm "$(findmnt -n -o OPTIONS /dev/shm | tr ',' '\n' | grep -c -E '^(nodev|noexec|nosuid)$')" 3
check enforcing "$(getenforce)" Enforcing
systemctl is-active firewalld
systemctl is-active amazon-ssm-agent
if [[ "$fail" -ne 0 ]]; then
  echo "One or more checks failed." >&2
  exit 1
fi
echo "Delta applied. Reboot before creating the AMI so audit=1 is on the kernel command line."
