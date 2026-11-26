#Written by Gemini AI
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

CONFIG_FILE="/etc/ssh/sshd_config"
BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
SWAP_FILE="/swapfile"

# ==============================================================================
# STEP 0: Pre-flight Root Check
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (use sudo)." >&2
    exit 1
fi

# ==============================================================================
# STEP 1: Collect & Validate All Interactive Inputs Up Front
# ==============================================================================
echo "=== 1/6: Interactive Setup Prompts ==="

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

USER_EXISTS=false
if id "$TARGET_USER" &>/dev/null; then
    if [[ "$(id -u "$TARGET_USER")" -eq 0 ]]; then
        echo "[ERROR] User '$TARGET_USER' has UID 0 (root). Aborting." >&2
        exit 1
    fi
    USER_EXISTS=true
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

# ==============================================================================
# STEP 2: Create User, Grant Sudo & Install SSH Key
# ==============================================================================
echo "=== 2/6: Configuring User, Sudo & SSH Keys ==="

if [[ "$USER_EXISTS" = true ]]; then
    echo "[OK] User '$TARGET_USER' already exists."
else
    useradd -m -s /bin/bash "$TARGET_USER"
    echo "[OK] Created user '$TARGET_USER'."
    echo "Set a password for '$TARGET_USER' (required for sudo commands):"
    until passwd "$TARGET_USER"; do
        echo "[WARNING] Password setup failed. Please try again."
    done
fi

if ! command -v sudo &>/dev/null; then
    apt-get update -q
    apt-get install -y -q sudo
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

# Lockout guard: verify at least one non-root user has a non-empty authorized_keys file
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
echo "=== 3/6: Configuring Swap Memory ==="

if [[ "$SWAP_GB" != "0" ]]; then
    if [[ -e "$SWAP_FILE" ]]; then
        echo "[WARNING] $SWAP_FILE already exists. Skipping swap creation." >&2
    else
        echo "[INFO] Allocating ${SWAP_GB}GB swap file at $SWAP_FILE..."
        if ! fallocate -l "${SWAP_GB}G" "$SWAP_FILE" 2>/dev/null; then
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_GB * 1024)) status=progress
        fi
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE"
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
# STEP 4: System Update & Cleanup
# ==============================================================================
echo "=== 4/6: Updating System Packages ==="
apt-get update -q
apt-get upgrade -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
apt-get autoremove -y -q
apt-get autoclean -y -q
echo "[OK] System updated and cleaned."

# ==============================================================================
# STEP 5: Configure Unattended Upgrades
# ==============================================================================
echo "=== 5/6: Enabling Unattended Security Upgrades ==="
apt-get install -y -q unattended-upgrades apt-listchanges
echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades
echo "[OK] Automatic security updates enabled."

# ==============================================================================
# STEP 6: Backup, Harden & Reload SSH
# ==============================================================================
echo "=== 6/6: Hardening SSH Configuration ==="
if [[ -f "$CONFIG_FILE" ]]; then
    cp -p "$CONFIG_FILE" "$BACKUP_FILE"
    echo "[OK] Backup saved to $BACKUP_FILE"
else
    echo "[ERROR] $CONFIG_FILE not found." >&2
    exit 1
fi

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

if grep -rnE '^\s*(PasswordAuthentication|PermitRootLogin)\s+yes' /etc/ssh/sshd_config.d/ 2>/dev/null; then
    echo "[WARNING] A drop-in file in /etc/ssh/sshd_config.d/ sets PasswordAuthentication or PermitRootLogin to 'yes'." >&2
    echo "          Because 'Include' is at the top of sshd_config, that drop-in file will override your settings." >&2
fi

if ! sshd -t; then
    echo "[ERROR] SSH syntax validation failed! Restoring backup..." >&2
    cp -p "$BACKUP_FILE" "$CONFIG_FILE"
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

echo "=== Setup Complete ==="
if [[ -f /var/run/reboot-required ]]; then
    echo "[NOTICE] A reboot is required to finish kernel/system updates."
    echo "         Verify SSH key login as '$TARGET_USER' in a NEW terminal before running 'sudo reboot'."
fi
