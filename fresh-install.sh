#Created by Gemini AI

#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

CONFIG_FILE="/etc/ssh/sshd_config"
BACKUP_DIR="/root/ssh_backup_$(date +%Y%m%d_%H%M%S)"
SWAP_FILE="/swapfile"
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=60 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ==============================================================================
# STEP 0: Pre-flight Root & Environment Check
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (use sudo)." >&2
    exit 1
fi

if ! command -v sshd &>/dev/null; then
    echo "[ERROR] OpenSSH server (sshd) is not installed." >&2
    exit 1
fi

# ==============================================================================
# STEP 1: Complete All Interactive User Prompts Up Front
# ==============================================================================
echo "=== 1/7: Interactive Configuration ==="

# 1a. Target Username
DEFAULT_USER="${SUDO_USER:-}"
if [[ -n "$DEFAULT_USER" && "$DEFAULT_USER" != "root" ]]; then
    read -rp "Enter username to create or configure [default: $DEFAULT_USER]: " TARGET_USER
    TARGET_USER="${TARGET_USER:-$DEFAULT_USER}"
else
    read -rp "Enter username to create or configure: " TARGET_USER
fi

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    echo "[ERROR] Invalid username. Must be a non-empty, non-root username." >&2
    exit 1
fi

if ! [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    echo "[ERROR] Invalid Linux username format: '$TARGET_USER'" >&2
    exit 1
fi

if id "$TARGET_USER" &>/dev/null; then
    if [[ "$(id -u "$TARGET_USER")" -eq 0 ]]; then
        echo "[ERROR] User '$TARGET_USER' has UID 0 (root). Aborting." >&2
        exit 1
    fi
    echo "[OK] User '$TARGET_USER' already exists."
else
    useradd -m -s /bin/bash "$TARGET_USER"
    echo "[OK] Created user '$TARGET_USER'."
    echo "Set a password for '$TARGET_USER' (required for sudo commands):"
    until passwd "$TARGET_USER"; do
        echo "[WARNING] Password setup failed. Please try again."
    done
fi

# 1b. SSH Public Key
read -rp "Paste SSH public key for '$TARGET_USER' (or press Enter to skip if already configured): " USER_PUB_KEY
if [[ -n "$USER_PUB_KEY" ]]; then
    USER_PUB_KEY="$(echo "$USER_PUB_KEY" | xargs)"
    if ! echo "$USER_PUB_KEY" | ssh-keygen -l -f - &>/dev/null; then
        echo "[ERROR] Invalid SSH public key format. Ensure you pasted the .pub file contents." >&2
        exit 1
    fi
fi

# 1c. Swap Size
if swapon --show | grep -q .; then
    echo "[INFO] Active swap already detected:"
    swapon --show
fi

read -rp "Enter swap size in GB to allocate (e.g., 2 for 2GB, or press Enter/0 to skip): " SWAP_GB
SWAP_GB="${SWAP_GB:-0}"

if [[ "$SWAP_GB" != "0" ]]; then
    if ! [[ "$SWAP_GB" =~ ^[1-9][0-9]*$ ]]; then
        echo "[ERROR] Invalid swap size '$SWAP_GB'. Enter a positive whole number (e.g., 2)." >&2
        exit 1
    fi
    AVAIL_KB=$(df --output=avail / | tail -n 1 | xargs)
    REQ_KB=$(( (SWAP_GB + 1) * 1024 * 1024 ))
    if (( AVAIL_KB < REQ_KB )); then
        echo "[ERROR] Insufficient disk space on / for ${SWAP_GB}GB swap (need at least $((SWAP_GB + 1))GB free)." >&2
        exit 1
    fi
fi

# 1d. Docker Installation
read -rp "Install Docker Engine and Docker Compose? [y/N]: " INSTALL_DOCKER_INPUT
INSTALL_DOCKER=false
if [[ "${INSTALL_DOCKER_INPUT,,}" =~ ^(y|yes)$ ]]; then
    INSTALL_DOCKER=true
fi

echo "=== All prompts complete. Running unattended setup... ==="

# ==============================================================================
# STEP 2: Configure Sudo & SSH Public Key (With Lockout Protection)
# ==============================================================================
echo "=== 2/7: Configuring Sudo & SSH Keys ==="

if ! command -v sudo &>/dev/null; then
    apt-get update -q -o DPkg::Lock::Timeout=60
    apt-get install "${APT_OPTS[@]}" sudo
fi

usermod -aG sudo "$TARGET_USER"
echo "[OK] Added '$TARGET_USER' to the 'sudo' group."

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
SSH_DIR="$TARGET_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

if [[ -n "$USER_PUB_KEY" ]]; then
    mkdir -p "$SSH_DIR"
    touch "$AUTH_KEYS"
    if grep -Fqx "$USER_PUB_KEY" "$AUTH_KEYS"; then
        echo "[OK] SSH key already present in $AUTH_KEYS."
    else
        echo "$USER_PUB_KEY" >> "$AUTH_KEYS"
        echo "[OK] SSH public key added to $AUTH_KEYS."
    fi
    chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$AUTH_KEYS"
fi

# Verify at least one non-root user has a valid authorized_keys file
KEY_FOUND=false
while IFS=: read -r username _ uid _ _ homedir _; do
    if [[ "$uid" -ge 1000 && "$username" != "nobody" && -s "$homedir/.ssh/authorized_keys" ]]; then
        KEY_FOUND=true
        echo "[OK] Verified authorized_keys for user: $username"
        break
    fi
done < /etc/passwd

if [[ "$KEY_FOUND" = false ]]; then
    echo "[ABORT] No non-root user has a non-empty ~/.ssh/authorized_keys file." >&2
    echo "        Stopping before disabling PasswordAuthentication to prevent lockout." >&2
    exit 1
fi

# ==============================================================================
# STEP 3: Allocate & Enable Swap (Before Heavy APT Operations)
# ==============================================================================
echo "=== 3/7: Configuring Swap Memory ==="

if [[ "$SWAP_GB" != "0" ]]; then
    if [[ -e "$SWAP_FILE" ]]; then
        echo "[WARNING] $SWAP_FILE already exists. Skipping swap creation." >&2
    else
        echo "[INFO] Allocating ${SWAP_GB}GB swap file at $SWAP_FILE..."
        FS_TYPE=$(df -T / | awk 'NR==2 {print $2}')
        if [[ "$FS_TYPE" == "ext4" || "$FS_TYPE" == "xfs" ]] && fallocate -l "${SWAP_GB}G" "$SWAP_FILE" 2>/dev/null; then
            true
        else
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_GB * 1024)) status=none
        fi

        chmod 600 "$SWAP_FILE"
        mkswap -q "$SWAP_FILE"
        swapon "$SWAP_FILE"

        if ! grep -Fq "$SWAP_FILE" /etc/fstab; then
            echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        fi

        echo "vm.swappiness=10" > /etc/sysctl.d/99-swap.conf
        sysctl -q -p /etc/sysctl.d/99-swap.conf
        echo "[OK] ${SWAP_GB}GB swap enabled and persisted."
    fi
else
    echo "[OK] Swap allocation skipped."
fi

# ==============================================================================
# STEP 4: System Update, Cleanup & Unattended Upgrades
# ==============================================================================
echo "=== 4/7: Updating System & Enabling Unattended Upgrades ==="
apt-get update -q -o DPkg::Lock::Timeout=60
apt-get upgrade "${APT_OPTS[@]}"
apt-get install "${APT_OPTS[@]}" unattended-upgrades apt-listchanges curl ca-certificates
apt-get autoremove "${APT_OPTS[@]}"
apt-get autoclean -y -q

echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades
echo "[OK] System updated and automatic security upgrades enabled."

# ==============================================================================
# STEP 5: Install Docker Engine & Docker Compose (Optional)
# ==============================================================================
echo "=== 5/7: Docker Installation ==="

if [[ "$INSTALL_DOCKER" = true ]]; then
    if command -v docker &>/dev/null; then
        echo "[OK] Docker is already installed: $(docker --version)"
    else
        echo "[INFO] Downloading and running Docker convenience script..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh

        systemctl enable --now docker
        echo "[OK] Docker installed and started: $(docker --version)"
    fi

    usermod -aG docker "$TARGET_USER"
    echo "[OK] Added '$TARGET_USER' to the 'docker' group."
    echo "[OK] Compose version: $(docker compose version)"
else
    echo "[OK] Docker installation skipped."
fi

# ==============================================================================
# STEP 6: Enable TCP BBR Congestion Control
# ==============================================================================
echo "=== 6/7: Configuring TCP BBR ==="
modprobe tcp_bbr 2>/dev/null || true

if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    cat << 'EOF' > /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -q --system

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]]; then
        echo "[OK] TCP BBR congestion control enabled and persisted."
    else
        echo "[WARNING] BBR config written, but active algorithm is $(sysctl -n net.ipv4.tcp_congestion_control)." >&2
    fi
else
    echo "[WARNING] TCP BBR is not available in the running kernel. Skipping." >&2
fi

# ==============================================================================
# STEP 7: Backup, Harden & Reload SSH
# ==============================================================================
echo "=== 7/7: Hardening SSH Configuration ==="
mkdir -p "$BACKUP_DIR"
cp -p "$CONFIG_FILE" "$BACKUP_DIR/sshd_config"
if [[ -d /etc/ssh/sshd_config.d ]]; then
    cp -rp /etc/ssh/sshd_config.d "$BACKUP_DIR/"
    # Neutralize cloud-init or vendor drop-in overrides that re-enable password/root login
    find /etc/ssh/sshd_config.d -type f -name '*.conf' -exec \
        sed -i -E 's/^\s*(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)\s+yes/# [Disabled by setup_debian.sh] &/I' {} +
fi
echo "[OK] Existing SSH configs backed up to $BACKUP_DIR"

cat << 'EOF' > "$CONFIG_FILE"
Include /etc/ssh/sshd_config.d/*.conf

# Logging
LogLevel VERBOSE

# Authentication & Security
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
MaxSessions 2
UsePAM no

# Forwarding & Session Controls
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
Compression no
ClientAliveInterval 300
ClientAliveCountMax 2

# Mandatory Subsystems
Subsystem	sftp	/usr/lib/openssh/sftp-server
EOF

chmod 644 "$CONFIG_FILE"

if ! sshd -t; then
    echo "[ERROR] SSH syntax validation failed! Restoring backup..." >&2
    cp -p "$BACKUP_DIR/sshd_config" "$CONFIG_FILE"
    [[ -d "$BACKUP_DIR/sshd_config.d" ]] && cp -rp "$BACKUP_DIR/sshd_config.d/." /etc/ssh/sshd_config.d/
    exit 1
fi
echo "[OK] SSH syntax validation passed."

if systemctl is-active --quiet ssh; then
    systemctl reload ssh
    echo "[OK] Reloaded 'ssh' service."
elif systemctl is-active --quiet sshd; then
    systemctl reload sshd
    echo "[OK] Reloaded 'sshd' service."
else
    echo "[ERROR] Could not detect an active ssh/sshd systemd service." >&2
    exit 1
fi

echo "=========================================="
echo "=== Server Setup Complete ==="
echo "=========================================="
if [[ -f /var/run/reboot-required ]]; then
    echo "[NOTICE] A system reboot is required to finish applying kernel/system updates."
    echo "         Test SSH key login as '$TARGET_USER' in a NEW terminal before running 'sudo reboot'."
fi
