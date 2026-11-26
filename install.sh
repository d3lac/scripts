#curl -LsO https://raw.githubusercontent.com/d3lac/scripts/main/install.sh; bash install.sh

#Created by Claude.ai
#!/usr/bin/env bash
#
# setup_debian.sh (revised) - first-boot setup and SSH hardening for Debian/Ubuntu
#
# Order of work:
#   0 pre-flight  1 collect+validate input (no changes)  2 user/sudo/key + lockout checks
#   3 SSH hardening with live auto-rollback  4 swap  5 apt + unattended-upgrades
#   6 Docker (optional)  7 TCP BBR
#
# Interactive by default. For automation, pre-set any of these variables
# (use `sudo VAR=value ./setup_debian.sh`, because sudo strips the environment):
#   TARGET_USER, SSH_PUBKEY, SWAP_GB, INSTALL_DOCKER=yes|no, DOCKER_GROUP=yes|no,
#   RESTRICT_TO_TARGET_USER=yes|no (adds AllowUsers), ASSUME_YES=yes,
#   SKIP_SSH_CONFIRM=yes (non-interactive runs only: skips the rollback gate)
#
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 022

# ------------------------------------------------------------------------------
# Paths and tunables (environment-overridable so the logic can be tested)
# ------------------------------------------------------------------------------
CONFIG_FILE="${CONFIG_FILE:-/etc/ssh/sshd_config}"
DROPIN_DIR="${DROPIN_DIR:-/etc/ssh/sshd_config.d}"
DROPIN="$DROPIN_DIR/00-hardening.conf"   # "00-" sorts first, and sshd uses first-match-wins
SWAP_FILE="${SWAP_FILE:-/swapfile}"
LOG_FILE="${LOG_FILE:-/var/log/setup_debian.log}"
BACKUP_DIR="${BACKUP_DIR:-/root/ssh_backup_$(date +%Y%m%d_%H%M%S)}"
ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"
ROLLBACK_UNIT="ssh-hardening-rollback"
ROLLBACK_SECONDS=300
# Docker's published apt signing key fingerprint (docs.docker.com/engine/install)
DOCKER_GPG_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=60 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# State (filled in by the steps below)
INTERACTIVE=false
IN_CONTAINER=false
OS_ID="" ; OS_CODENAME="" ; SSHD_BIN=""
USER_EXISTS=false ; NEED_PASSWORD=false ; USER_PASSWORD=""
APT_UPDATED=false
TMP_FILES=()

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

is_yes() { local v=${1:-}; v=${v,,}; [[ $v == y || $v == yes || $v == 1 || $v == true ]]; }

on_err()  { local rc=$?; printf '[ERROR] line %s: %s (exit %s)\n' "${BASH_LINENO[0]}" "$BASH_COMMAND" "$rc" >&2; }
cleanup() { if (( ${#TMP_FILES[@]} > 0 )); then rm -f "${TMP_FILES[@]}"; fi; }
trap on_err ERR
trap cleanup EXIT

# Trim whitespace and CRs without xargs (xargs breaks on quotes/backslashes in key comments).
trim() {
    local s=$1
    s=${s//$'\r'/}
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# prompt VAR "text" [default]: skipped if VAR is already set (env/automation).
prompt() {
    local var=$1 text=$2 def=${3:-} reply=""
    if [[ -v $var ]]; then return 0; fi
    if $INTERACTIVE; then
        read -rp "$text" reply || true
        reply=${reply:-$def}
    else
        reply=$def
    fi
    printf -v "$var" '%s' "$reply"
}

read_password() {
    local p1 p2 tries
    for tries in 1 2 3; do
        read -rsp "Set a password for '$TARGET_USER' (needed for sudo): " p1; echo
        read -rsp "Confirm password: " p2; echo
        if [[ -n $p1 && $p1 == "$p2" ]]; then USER_PASSWORD=$p1; return 0; fi
        warn "Password empty or mismatched (attempt $tries/3)."
    done
    die "Could not set a password."
}

apt_update_once() {
    if ! $APT_UPDATED; then
        apt-get update -q -o DPkg::Lock::Timeout=60
        APT_UPDATED=true
    fi
}

valid_username() { [[ ${1:-} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
user_home()      { getent passwd "$1" | cut -d: -f6; }
passwd_status()  { passwd -S "$1" 2>/dev/null | awk '{print $2}' || true; }
# Non-blank, non-comment line exists (avoids `grep -q` in a pipeline: SIGPIPE + pipefail).
has_key_lines()  { [[ -s $1 ]] && grep -Eqv '^[[:space:]]*(#|$)' "$1"; }
key_fingerprints() { ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}' || true; }

has_nopasswd_sudo() {
    local out
    command -v sudo &>/dev/null || return 1
    out=$(sudo -l -U "$1" 2>/dev/null || true)
    [[ $out == *NOPASSWD* ]]
}

# Is this shell running under sshd but NOT under tmux/screen? (A dropped SSH session
# would SIGHUP the script in the middle of an apt upgrade.)
ssh_session_at_risk() {
    local pid=$$ comm
    while [[ -n $pid ]] && (( pid > 1 )); do
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        case $comm in
            tmux*|screen*|SCREEN*) return 1 ;;
            sshd*) return 0 ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    done
    return 1
}

# Append a public key to an authorized_keys file, safely and without duplicates.
append_authorized_key() {
    local file=$1 key=$2 tmp fp existing
    touch "$file"
    tmp=$(mktemp); TMP_FILES+=("$tmp")
    printf '%s\n' "$key" > "$tmp"
    fp=$(key_fingerprints "$tmp")
    existing=$(key_fingerprints "$file")
    if [[ -n $fp && $'\n'$existing$'\n' == *$'\n'"$fp"$'\n'* ]]; then
        return 2   # already present
    fi
    # If the file lacks a trailing newline, ">>" would glue our key onto the last line.
    if [[ -s $file && -n "$(tail -c1 "$file")" ]]; then printf '\n' >> "$file"; fi
    printf '%s\n' "$key" >> "$file"
}

# Everything sshd's StrictModes and our sudo requirement need for $1 to be able to
# log in and administer the box. Prints each problem; returns non-zero if any.
verify_user_access() {
    local u=$1 home ssh_dir ak mode owner errs=0 st groups_of
    home=$(user_home "$u")
    ssh_dir="$home/.ssh"; ak="$ssh_dir/authorized_keys"

    if [[ ! -d $home ]]; then warn "Home directory '$home' does not exist."; return 1; fi

    mode=$(stat -c %a "$home"); owner=$(stat -c %U "$home")
    if (( (8#$mode & 022) != 0 )); then
        warn "Home '$home' is group/world-writable ($mode); sshd StrictModes will reject the key."; errs=$((errs+1))
    fi
    if [[ $owner != "$u" && $owner != root ]]; then
        warn "Home '$home' is owned by '$owner'."; errs=$((errs+1))
    fi
    if [[ ! -d $ssh_dir ]]; then
        warn "$ssh_dir is missing."; errs=$((errs+1))
    else
        mode=$(stat -c %a "$ssh_dir"); owner=$(stat -c %U "$ssh_dir")
        if (( (8#$mode & 077) != 0 )) || [[ $owner != "$u" ]]; then
            warn "$ssh_dir must be owned by $u with mode 700 (found $owner/$mode)."; errs=$((errs+1))
        fi
    fi
    if ! has_key_lines "$ak"; then
        warn "$ak is missing or contains no keys."; errs=$((errs+1))
    else
        mode=$(stat -c %a "$ak"); owner=$(stat -c %U "$ak")
        if (( (8#$mode & 022) != 0 )) || [[ $owner != "$u" ]]; then
            warn "$ak must be owned by $u and not group/world-writable (found $owner/$mode)."; errs=$((errs+1))
        fi
        if [[ -n $(key_fingerprints "$ak") ]]; then :; else
            warn "ssh-keygen could not parse $ak; check it for corrupt lines."; errs=$((errs+1))
        fi
    fi
    groups_of=$(id -nG "$u")
    if [[ " $groups_of " != *" sudo "* ]]; then
        warn "'$u' is not in the 'sudo' group."; errs=$((errs+1))
    fi
    # Root login will be disabled, so sudo is the only admin path: it needs a usable
    # password or a NOPASSWD rule (cloud images ship the latter with a locked password).
    st=$(passwd_status "$u")
    if [[ $st != P ]] && ! has_nopasswd_sudo "$u"; then
        warn "'$u' has a locked/empty password (status '${st:-?}') and no NOPASSWD sudo rule: sudo would be unusable."
        errs=$((errs+1))
    fi
    (( errs == 0 ))
}

# ------------------------------------------------------------------------------
# STEP 0: pre-flight
# ------------------------------------------------------------------------------
preflight() {
    echo "=== 0/7: Pre-flight checks ==="
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
    [[ -t 0 ]] && INTERACTIVE=true

    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
    OS_CODENAME=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
    case $OS_ID in
        debian|ubuntu) ;;
        *) if [[ $(. /etc/os-release; echo "${ID_LIKE:-}") == *debian* ]]; then
               warn "Untested Debian derivative '$OS_ID'; continuing."
           else die "Unsupported OS '$OS_ID' (Debian/Ubuntu only)."; fi ;;
    esac

    command -v apt-get &>/dev/null    || die "apt-get not found."
    command -v ssh-keygen &>/dev/null || die "ssh-keygen (openssh-client) not found."
    [[ -d /run/systemd/system ]]      || die "systemd is required (service control and rollback timer)."
    command -v systemd-run &>/dev/null || die "systemd-run not found."

    SSHD_BIN=$(command -v sshd || true)
    if [[ -z $SSHD_BIN && -x /usr/sbin/sshd ]]; then SSHD_BIN=/usr/sbin/sshd; fi
    [[ -n $SSHD_BIN ]] || die "OpenSSH server (sshd) is not installed."

    if command -v systemd-detect-virt &>/dev/null && systemd-detect-virt --container --quiet; then
        IN_CONTAINER=true
        warn "Container detected: swap and kernel sysctl steps will be skipped."
    fi

    if ssh_session_at_risk; then
        warn "You are connected over SSH outside tmux/screen. If the connection drops mid-run,"
        warn "apt/dpkg can be interrupted. Recommended: run 'tmux' first."
        if $INTERACTIVE && ! is_yes "${ASSUME_YES:-no}"; then
            local ans; read -rp "Continue anyway? [y/N]: " ans || true
            is_yes "$ans" || exit 1
        fi
    fi
    ok "Pre-flight passed (OS: $OS_ID ${OS_CODENAME:-})."
}

# ------------------------------------------------------------------------------
# STEP 1: collect and validate ALL input. Nothing on the system is modified here.
# ------------------------------------------------------------------------------
gather_input() {
    echo "=== 1/7: Collecting and validating input (no changes are made yet) ==="

    local default_user="${SUDO_USER:-}"
    if [[ $default_user == root ]]; then default_user=""; fi
    prompt TARGET_USER "Username to create or configure${default_user:+ [$default_user]}: " "$default_user"
    [[ -n $TARGET_USER ]]       || die "No username given."
    [[ $TARGET_USER != root ]]  || die "Refusing to use root."
    valid_username "$TARGET_USER" || die "Invalid Linux username: '$TARGET_USER'"

    local uid_min uid
    uid_min=$(awk '/^UID_MIN/ {print $2}' /etc/login.defs 2>/dev/null || true)
    uid_min=${uid_min:-1000}
    if id "$TARGET_USER" &>/dev/null; then
        USER_EXISTS=true
        uid=$(id -u "$TARGET_USER")
        (( uid >= uid_min )) || die "'$TARGET_USER' is a system account (UID $uid < $uid_min)."
        ok "User '$TARGET_USER' exists."
    else
        info "User '$TARGET_USER' will be created."
    fi

    # --- SSH public key
    prompt SSH_PUBKEY "Paste SSH public key for '$TARGET_USER' (Enter to skip if already configured): " ""
    SSH_PUBKEY=$(trim "$SSH_PUBKEY")
    if [[ -n $SSH_PUBKEY ]]; then
        [[ $SSH_PUBKEY != *"PRIVATE KEY"* ]] || die "That looks like a PRIVATE key. Paste the .pub file contents."
        [[ $SSH_PUBKEY != *$'\n'* ]]         || die "Provide exactly one key line."
        local tmp; tmp=$(mktemp); TMP_FILES+=("$tmp")
        printf '%s\n' "$SSH_PUBKEY" > "$tmp"
        [[ -n $(key_fingerprints "$tmp") ]] || die "Invalid SSH public key format."
        ok "Public key parsed."
    elif $USER_EXISTS; then
        local home; home=$(user_home "$TARGET_USER")
        has_key_lines "$home/.ssh/authorized_keys" \
            || die "No key supplied and '$TARGET_USER' has no authorized_keys. Provide a key or you would be locked out."
        info "Using the existing authorized_keys of '$TARGET_USER'."
    else
        die "A public key is required for a new user (password logins will be disabled)."
    fi

    # --- Password (only when sudo would otherwise be unusable)
    if ! $USER_EXISTS; then
        NEED_PASSWORD=true
    elif [[ $(passwd_status "$TARGET_USER") != P ]] && ! has_nopasswd_sudo "$TARGET_USER"; then
        NEED_PASSWORD=true
    fi
    if $NEED_PASSWORD; then
        $INTERACTIVE || die "'$TARGET_USER' needs a sudo password but the session is non-interactive."
        read_password
    fi

    # --- Swap
    local swapinfo; swapinfo=$(swapon --show 2>/dev/null || true)
    if [[ -n $swapinfo ]]; then info "Active swap detected:"; echo "$swapinfo"; fi
    prompt SWAP_GB "Swap size in GB (Enter/0 to skip): " 0
    [[ $SWAP_GB =~ ^[0-9]+$ ]] || die "Invalid swap size '$SWAP_GB' (whole number of GB)."
    SWAP_GB=$((10#$SWAP_GB))
    if (( SWAP_GB > 0 )); then
        local fstype avail_kb
        fstype=$(df --output=fstype / | tail -n 1 | tr -d ' ')
        avail_kb=$(df --output=avail -k / | tail -n 1 | tr -d ' ')
        if $IN_CONTAINER; then warn "Skipping swap (container)."; SWAP_GB=0
        elif [[ -e $SWAP_FILE ]]; then warn "$SWAP_FILE already exists; skipping swap."; SWAP_GB=0
        elif [[ $fstype == btrfs || $fstype == zfs ]]; then warn "Swap files on $fstype need special handling; skipping."; SWAP_GB=0
        elif (( avail_kb < (SWAP_GB + 1) * 1024 * 1024 )); then
            die "Not enough free space on / for ${SWAP_GB}GB swap (need ${SWAP_GB}GB + 1GB headroom)."
        fi
    fi

    # --- Docker
    prompt INSTALL_DOCKER "Install Docker Engine + Compose plugin? [y/N]: " no
    if is_yes "$INSTALL_DOCKER"; then
        if [[ $OS_ID != debian && $OS_ID != ubuntu ]]; then warn "Docker repo setup supports Debian/Ubuntu only; skipping."; INSTALL_DOCKER=no
        elif [[ -z $OS_CODENAME ]]; then warn "Cannot determine release codename; skipping Docker."; INSTALL_DOCKER=no
        fi
    fi
    if is_yes "$INSTALL_DOCKER"; then
        prompt DOCKER_GROUP "Add '$TARGET_USER' to the docker group? (this is root-equivalent access) [y/N]: " no
    else
        DOCKER_GROUP=no
    fi
    RESTRICT_TO_TARGET_USER=${RESTRICT_TO_TARGET_USER:-no}

    # --- Non-interactive safety: the rollback gate needs a human.
    if ! $INTERACTIVE && ! is_yes "${SKIP_SSH_CONFIRM:-no}"; then
        die "Non-interactive run: set SKIP_SSH_CONFIRM=yes to accept SSH hardening without a live confirmation gate."
    fi

    echo "------------------------------------------------------------"
    echo " Plan:"
    echo "   user            : $TARGET_USER ($($USER_EXISTS && echo existing || echo new))"
    echo "   key             : $([[ -n $SSH_PUBKEY ]] && echo 'add supplied key' || echo 'use existing authorized_keys')"
    echo "   SSH             : drop-in $DROPIN (root login, passwords OFF; keys only)"
    echo "   swap            : $([[ $SWAP_GB -gt 0 ]] && echo "${SWAP_GB}GB at $SWAP_FILE" || echo skip)"
    echo "   docker          : $(is_yes "$INSTALL_DOCKER" && echo yes || echo no) (docker group: $(is_yes "$DOCKER_GROUP" && echo yes || echo no))"
    echo "------------------------------------------------------------"
    if $INTERACTIVE && ! is_yes "${ASSUME_YES:-no}"; then
        local go; read -rp "Proceed? [y/N]: " go || true
        is_yes "$go" || die "Aborted; nothing was changed."
    fi
}

start_logging() {
    touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Logging to $LOG_FILE"
}

# ------------------------------------------------------------------------------
# STEP 2: user, sudo, key, and lockout verification for THIS user
# ------------------------------------------------------------------------------
step_user_and_keys() {
    echo "=== 2/7: User, sudo and SSH key ==="
    if ! command -v sudo &>/dev/null; then
        apt_update_once
        apt-get install "${APT_OPTS[@]}" sudo
    fi
    getent group sudo >/dev/null || die "The 'sudo' group does not exist."

    if $USER_EXISTS; then
        ok "Using existing user '$TARGET_USER'."
    else
        useradd -m -s /bin/bash "$TARGET_USER"
        ok "Created user '$TARGET_USER'."
    fi
    if [[ -n $USER_PASSWORD ]]; then
        printf '%s:%s\n' "$TARGET_USER" "$USER_PASSWORD" | chpasswd
        USER_PASSWORD=""
        ok "Password set."
    fi
    usermod -aG sudo "$TARGET_USER"
    ok "'$TARGET_USER' is in the 'sudo' group."

    local home ssh_dir ak grp rc=0
    home=$(user_home "$TARGET_USER"); ssh_dir="$home/.ssh"; ak="$ssh_dir/authorized_keys"
    grp=$(id -gn "$TARGET_USER")

    if [[ -n $SSH_PUBKEY ]]; then
        install -d -m 700 -o "$TARGET_USER" -g "$grp" "$ssh_dir"
        append_authorized_key "$ak" "$SSH_PUBKEY" || rc=$?
        case $rc in
            0) ok "SSH key added to $ak." ;;
            2) ok "SSH key already present in $ak." ;;
            *) die "Failed to write $ak." ;;
        esac
    fi
    if [[ -d $ssh_dir ]]; then
        chown -R "$TARGET_USER:$grp" "$ssh_dir"
        chmod 700 "$ssh_dir"
        if [[ -f $ak ]]; then chmod 600 "$ak"; fi
    fi

    verify_user_access "$TARGET_USER" \
        || die "Lockout protection: '$TARGET_USER' cannot be guaranteed SSH + sudo access. Not touching SSH settings."
    ok "Verified: '$TARGET_USER' has a valid key, correct permissions, and a working sudo path."
}

# ------------------------------------------------------------------------------
# STEP 3: SSH hardening via drop-in, with effective-config check and auto-rollback
# ------------------------------------------------------------------------------
ensure_include() {
    # Debian/Ubuntu ship this line at the top. If it is missing, drop-ins would be ignored.
    if ! grep -Eqi '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d/' "$CONFIG_FILE"; then
        warn "No Include for $DROPIN_DIR in $CONFIG_FILE; prepending it."
        { printf 'Include %s/*.conf\n' "$DROPIN_DIR"; cat "$BACKUP_DIR/sshd_config"; } > "$CONFIG_FILE"
    fi
}

write_dropin() {
    local kbd=$1
    {
        cat <<EOF
# Managed by setup_debian.sh. Sorts first so it wins over cloud-init/vendor drop-ins.
LogLevel VERBOSE
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
$kbd no
PermitEmptyPasswords no
AuthenticationMethods publickey
UsePAM yes
MaxAuthTries 6
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
        if is_yes "${RESTRICT_TO_TARGET_USER:-no}"; then echo "AllowUsers $TARGET_USER"; fi
    } > "$DROPIN" || return 1
    chmod 644 "$DROPIN"
}

# Write the drop-in and syntax-check it. Older OpenSSH (e.g. Debian 11) only knows
# ChallengeResponseAuthentication, so fall back to that name if needed.
apply_dropin() {
    local kbd=KbdInteractiveAuthentication err
    write_dropin "$kbd" || return 1
    if ! err=$("$SSHD_BIN" -t 2>&1); then
        if grep -qi 'kbdinteractive' <<<"$err"; then
            info "Older OpenSSH: using ChallengeResponseAuthentication instead."
            write_dropin ChallengeResponseAuthentication || return 1
            err=$("$SSHD_BIN" -t 2>&1) || { printf '%s\n' "$err" >&2; return 1; }
        else
            printf '%s\n' "$err" >&2; return 1
        fi
    fi
    return 0
}

# `sshd -t` only checks syntax. `sshd -T` prints the MERGED effective config, so this
# catches another drop-in or main-file line overriding what we intended.
verify_effective() {
    local eff line bad=0
    eff=$("$SSHD_BIN" -T 2>&1) || { printf '%s\n' "$eff" >&2; return 1; }
    for line in "passwordauthentication no" "permitrootlogin no" "pubkeyauthentication yes" \
                "usepam yes" "authenticationmethods publickey" "permitemptypasswords no"; do
        if ! grep -Fqxi -- "$line" <<<"$eff"; then
            warn "Effective config mismatch: expected '$line'"; bad=1
        fi
    done
    if ! grep -Eqix '(kbdinteractiveauthentication|challengeresponseauthentication) no' <<<"$eff"; then
        warn "Effective config mismatch: keyboard-interactive auth is not disabled"; bad=1
    fi
    if (( bad == 0 )); then
        info "Effective SSH port(s): $(awk '$1=="port"{printf "%s ", $2}' <<<"$eff")"
    fi
    return $bad
}

revert_files() {
    local prev
    rm -f "$DROPIN"
    prev="$BACKUP_DIR/sshd_config.d/$(basename "$DROPIN")"
    if [[ -f $prev ]]; then cp -a "$prev" "$DROPIN"; fi
    cat "$BACKUP_DIR/sshd_config" > "$CONFIG_FILE"
}

write_rollback_script() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'DROPIN=%q\nCONFIG_FILE=%q\nBACKUP_DIR=%q\n' "$DROPIN" "$CONFIG_FILE" "$BACKUP_DIR"
        cat <<'EOF'
# Generated by setup_debian.sh: restores the pre-hardening SSH configuration.
rm -f "$DROPIN"
prev="$BACKUP_DIR/sshd_config.d/$(basename "$DROPIN")"
if [[ -f $prev ]]; then cp -a "$prev" "$DROPIN"; fi
cat "$BACKUP_DIR/sshd_config" > "$CONFIG_FILE"
for svc in ssh sshd; do
    if systemctl is-active --quiet "$svc.service"; then systemctl reload "$svc.service"; fi
done
logger -t setup_debian "SSH hardening reverted by rollback script" 2>/dev/null || true
EOF
    } > "$ROLLBACK_SCRIPT"
    chmod 700 "$ROLLBACK_SCRIPT"
}

arm_rollback() {
    systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null || true
    systemctl reset-failed "$ROLLBACK_UNIT.service" 2>/dev/null || true
    systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_SECONDS}s" /bin/bash "$ROLLBACK_SCRIPT"
    info "Auto-rollback armed: SSH config reverts in $((ROLLBACK_SECONDS / 60)) minutes unless you confirm."
}

disarm_rollback() {
    systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
    systemctl reset-failed "$ROLLBACK_UNIT.service" 2>/dev/null || true
}

# Handles socket-activated sshd (Ubuntu 22.10+): reload the service if running,
# otherwise the socket will start it with the new config on the next connection.
reload_ssh() {
    local svc
    for svc in ssh sshd; do
        if systemctl is-active --quiet "$svc.service"; then
            systemctl reload "$svc.service"
            ok "Reloaded $svc.service."
            return 0
        fi
    done
    if systemctl is-active --quiet ssh.socket; then
        ok "ssh.socket is active; the new config applies to the next connection."
        warn "Under socket activation, Port/ListenAddress come from the socket unit, not sshd_config."
        return 0
    fi
    warn "No active ssh/sshd service or socket found."
    return 1
}

step_harden_ssh() {
    echo "=== 3/7: Hardening SSH (drop-in, effective-config check, auto-rollback) ==="
    install -d -m 700 "$BACKUP_DIR"
    cp -a "$CONFIG_FILE" "$BACKUP_DIR/sshd_config"
    if [[ -d $DROPIN_DIR ]]; then cp -a "$DROPIN_DIR" "$BACKUP_DIR/sshd_config.d"; fi
    ok "Existing SSH config backed up to $BACKUP_DIR"

    install -d -m 755 "$DROPIN_DIR" /run/sshd
    ensure_include

    if ! apply_dropin; then
        revert_files
        die "sshd rejected the new configuration; original restored."
    fi
    if ! verify_effective; then
        revert_files
        die "Effective SSH config does not match the hardening intent (something overrides it); original restored."
    fi
    ok "Syntax and effective-config checks passed."

    write_rollback_script

    if $INTERACTIVE && ! is_yes "${SKIP_SSH_CONFIRM:-no}"; then
        arm_rollback
        reload_ssh || die "Reload failed. The auto-rollback timer is still armed and will restore the old config."
        echo
        echo ">>> Open a NEW terminal NOW and verify:"
        echo ">>>     ssh $TARGET_USER@<server-ip>      (key login works)"
        echo ">>>     sudo -v                           (sudo works)"
        echo ">>> Then type 'keep' here to make the change permanent."
        echo ">>> Anything else, or no answer, reverts it (automatic in $((ROLLBACK_SECONDS / 60)) min)."
        local answer=""
        read -r -t $((ROLLBACK_SECONDS - 30)) answer || answer=""
        if [[ ${answer,,} == keep ]]; then
            disarm_rollback
            ok "SSH hardening confirmed and made permanent."
        else
            warn "Not confirmed; reverting SSH configuration now."
            bash "$ROLLBACK_SCRIPT"
            disarm_rollback
            die "SSH hardening reverted. Fix access (see $LOG_FILE), then re-run."
        fi
    else
        warn "No confirmation gate (non-interactive). Applying without live rollback."
        reload_ssh || die "Could not reload SSH. Backup is in $BACKUP_DIR"
    fi
}

# ------------------------------------------------------------------------------
# STEP 4: swap (built under a temp name, so a failed dd never leaves a broken /swapfile)
# ------------------------------------------------------------------------------
step_swap() {
    echo "=== 4/7: Swap ==="
    if (( SWAP_GB == 0 )); then ok "Swap allocation skipped."; return 0; fi

    local tmp="${SWAP_FILE}.tmp" fstype
    rm -f "$tmp"; TMP_FILES+=("$tmp")
    fstype=$(df --output=fstype / | tail -n 1 | tr -d ' ')
    info "Allocating ${SWAP_GB}GB swap file..."
    if [[ $fstype == ext4 || $fstype == xfs ]] && fallocate -l "${SWAP_GB}G" "$tmp" 2>/dev/null; then
        :
    else
        dd if=/dev/zero of="$tmp" bs=1M count=$((SWAP_GB * 1024)) status=none
    fi
    chmod 600 "$tmp"
    mkswap -q "$tmp"
    mv "$tmp" "$SWAP_FILE"
    swapon "$SWAP_FILE"

    if ! grep -Fq "$SWAP_FILE" /etc/fstab; then
        printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
    fi
    printf 'vm.swappiness=10\n' > /etc/sysctl.d/99-swap.conf
    sysctl -q -p /etc/sysctl.d/99-swap.conf || warn "Could not apply vm.swappiness now (it will apply at boot)."
    ok "${SWAP_GB}GB swap enabled and persisted."
}

# ------------------------------------------------------------------------------
# STEP 5: system update + unattended security upgrades
# ------------------------------------------------------------------------------
step_system_update() {
    echo "=== 5/7: System update and unattended upgrades ==="
    apt_update_once
    apt-get upgrade "${APT_OPTS[@]}"
    apt-get install "${APT_OPTS[@]}" unattended-upgrades curl ca-certificates gnupg
    apt-get autoremove "${APT_OPTS[@]}"
    apt-get autoclean -y -q
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    ok "System updated; automatic security upgrades enabled."
}

# ------------------------------------------------------------------------------
# STEP 6: Docker from the official apt repo, key fingerprint verified (no curl | sh)
# ------------------------------------------------------------------------------
step_docker() {
    echo "=== 6/7: Docker ==="
    if ! is_yes "$INSTALL_DOCKER"; then ok "Docker installation skipped."; return 0; fi

    if command -v docker &>/dev/null; then
        ok "Docker already installed: $(docker --version)"
    else
        local keyfile=/etc/apt/keyrings/docker.asc tmp fprs
        install -d -m 0755 /etc/apt/keyrings
        tmp=$(mktemp); TMP_FILES+=("$tmp")
        curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o "$tmp"
        fprs=$(gpg --show-keys --with-colons "$tmp" | awk -F: '$1=="fpr"{print $10}')
        grep -Fqx "$DOCKER_GPG_FPR" <<<"$fprs" \
            || die "Docker GPG key fingerprint mismatch; refusing to trust it."
        install -m 0644 "$tmp" "$keyfile"
        printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
            "$(dpkg --print-architecture)" "$keyfile" "$OS_ID" "$OS_CODENAME" > /etc/apt/sources.list.d/docker.list
        apt-get update -q -o DPkg::Lock::Timeout=60
        apt-get install "${APT_OPTS[@]}" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker
        ok "Docker installed: $(docker --version)"
    fi

    if is_yes "$DOCKER_GROUP"; then
        usermod -aG docker "$TARGET_USER"
        warn "'$TARGET_USER' is in the docker group: that is effectively passwordless root on this host."
    fi
    ok "Compose: $(docker compose version)"
}

# ------------------------------------------------------------------------------
# STEP 7: TCP BBR (non-fatal; the server is already hardened at this point)
# ------------------------------------------------------------------------------
step_bbr() {
    echo "=== 7/7: TCP BBR ==="
    if $IN_CONTAINER; then warn "Container: skipping BBR."; return 0; fi
    modprobe tcp_bbr 2>/dev/null || true
    local avail; avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if ! grep -qw bbr <<<"$avail"; then
        warn "TCP BBR is not available in this kernel. Skipping."
        return 0
    fi
    echo tcp_bbr > /etc/modules-load.d/bbr.conf      # load the module at boot
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -q -p /etc/sysctl.d/99-bbr.conf || warn "sysctl could not apply the BBR settings now."
    local active; active=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [[ $active == bbr ]]; then ok "TCP BBR enabled and persisted."
    else warn "BBR config written, but the active algorithm is '${active:-unknown}'."; fi
}

summary() {
    echo "=========================================="
    echo "=== Server Setup Complete ==="
    echo "=========================================="
    echo " Log:            $LOG_FILE"
    echo " SSH backup:     $BACKUP_DIR"
    echo " SSH drop-in:    $DROPIN"
    echo " Firewall/fail2ban are not configured by this script."
    if [[ -f /var/run/reboot-required ]]; then
        echo "[NOTICE] A reboot is required to finish applying system updates."
        echo "         Re-test SSH login as '$TARGET_USER' in a NEW terminal before 'sudo reboot'."
    fi
}

main() {
    preflight
    gather_input
    start_logging
    step_user_and_keys
    step_harden_ssh
    step_swap
    step_system_update
    step_docker
    step_bbr
    summary
}

# Run only when executed, not when sourced (lets the functions be unit-tested).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
