#!/usr/bin/env bash
# privileged-install.sh — runs as root via pkexec.
#
# SIMPLE, REPO-STYLE INSTALL
# --------------------------
# The new driver is installed to disk while the current one keeps
# running — exactly like a distro package upgrade. No session teardown,
# no module unloading, no black screen. The switch happens at the next
# reboot. The key is nvidia-installer's own
# --allow-installation-with-running-driver flag, which makes it proceed
# with a loaded driver and skip the (impossible) live module tests.
#
# Supports apt-based distros (Ubuntu, Debian, Mint) and dnf-based
# distros (Fedora, RHEL, Nobara). Package manager is detected once at
# startup and every package-related step below branches on it.
#
# Usage: privileged-install.sh <path-to.run> [--dkms] [--hold] [--no-x-check]

set -uo pipefail

LOGFILE="/var/log/greenlight.log"
log() {
    local msg="[greenlight] $*"
    echo "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOGFILE" 2>/dev/null || true
}

RUN_FILE="${1:-}"
USE_DKMS=0
HOLD_PKG=0

[[ -z "$RUN_FILE" ]] && { log "ERROR: No .run file specified"; exit 1; }
[[ -f "$RUN_FILE" ]] || { log "ERROR: File not found: $RUN_FILE"; exit 1; }
[[ "$RUN_FILE" =~ ^/.*\.run$ ]] || { log "ERROR: Invalid run file path: $RUN_FILE"; exit 1; }

shift
for arg in "$@"; do
    case "$arg" in
        --dkms)       USE_DKMS=1 ;;
        --hold)       HOLD_PKG=1 ;;
        --no-x-check) : ;;   # always passed to the installer now; kept for compatibility
        *) log "WARNING: Unknown argument: $arg" ;;
    esac
done

# ── Detect package manager ─────────────────────────────────────────────
if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
else
    log "ERROR: Neither apt-get nor dnf found. This script supports"
    log "       apt-based (Ubuntu, Debian, Mint) and dnf-based"
    log "       (Fedora, RHEL, Nobara) distros only."
    exit 1
fi

log "==== NVIDIA driver install started ===="
log "Run file: $RUN_FILE (dkms=$USE_DKMS hold=$HOLD_PKG pkg_mgr=$PKG_MGR)"

# ── Step 1: Verify archive integrity before touching anything ────────
chmod +x "$RUN_FILE"
log "Verifying installer archive integrity…"
if ! "$RUN_FILE" --check >>"$LOGFILE" 2>&1; then
    log "ERROR: Installer failed its integrity self-check. No changes made."
    exit 1
fi
log "Integrity OK"

# ── Step 2: Build prerequisites (non-fatal if the package manager balks)
KVER="$(uname -r)"
log "Ensuring kernel headers and build tools for $KVER…"
if [[ "$PKG_MGR" == "apt" ]]; then
    apt-get install -y "linux-headers-${KVER}" build-essential dkms >>"$LOGFILE" 2>&1 \
        || log "WARNING: apt could not confirm prerequisites — continuing"
else
    dnf install -y "kernel-devel-${KVER}" "kernel-headers-${KVER}" \
        gcc make dkms >>"$LOGFILE" 2>&1 \
        || log "WARNING: dnf could not confirm prerequisites — continuing"
fi

# ── Step 3: Clear conflicting distro packages (non-fatal)
# Removing package files does not affect the running driver — the loaded
# kernel module and already-mapped libraries keep working, same as
# during a normal package-manager driver upgrade.
log "Removing distro-managed NVIDIA packages (if any)…"
if [[ "$PKG_MGR" == "apt" ]]; then
    apt-mark unhold 'nvidia*' 'libnvidia*' 2>/dev/null || true
    PKGS=$(dpkg -l 'nvidia-*' 'libnvidia-*' 'libcuda*' 'libcudnn*' 2>/dev/null \
        | awk '/^ii/{print $2}' | grep -v '^greenlight' || true)
    if [[ -n "$PKGS" ]]; then
        log "  purging: $PKGS"
        dpkg --remove --force-remove-reinstreq $PKGS >>"$LOGFILE" 2>&1 || true
        apt-get purge -y $PKGS >>"$LOGFILE" 2>&1 || true
    fi
    update-alternatives --remove-all nvidia 2>/dev/null || true
    update-alternatives --remove-all nvidia-ld.so.conf 2>/dev/null || true
else
    # Fedora driver packages typically come from RPM Fusion: akmod-nvidia,
    # xorg-x11-drv-nvidia*, kmod-nvidia*, nvidia-driver* if present.
    if dnf versionlock --help >/dev/null 2>&1; then
        dnf versionlock delete 'nvidia*' 'akmod-nvidia*' 'xorg-x11-drv-nvidia*' \
            'kmod-nvidia*' 2>/dev/null || true
    fi
    PKGS=$(rpm -qa 'akmod-nvidia*' 'xorg-x11-drv-nvidia*' 'kmod-nvidia*' \
        'nvidia-driver*' 'nvidia-settings*' 2>/dev/null || true)
    if [[ -n "$PKGS" ]]; then
        log "  removing: $PKGS"
        dnf remove -y $PKGS >>"$LOGFILE" 2>&1 || true
    fi
fi

# ── Step 4: On-disk boot config (takes effect at next boot) ───────────
log "Writing nouveau blacklist and nvidia modeset config…"
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'BLACKLIST'
blacklist nouveau
options nouveau modeset=0
BLACKLIST
cat > /etc/modprobe.d/nvidia-drm-modeset.conf << 'MODESET'
options nvidia_drm modeset=1
MODESET

# ── Step 5: Run the installer — repo-style, old driver keeps running ──
log "Running the NVIDIA installer (a few minutes; desktop stays up)…"
INSTALLER_ARGS=(
    --silent
    --accept-license
    --ui=none
    --no-x-check
    --allow-installation-with-running-driver
    --log-file-name=/var/log/nvidia-installer.log
)
[[ $USE_DKMS -eq 1 ]] && INSTALLER_ARGS+=(--dkms)

"$RUN_FILE" "${INSTALLER_ARGS[@]}" >>"$LOGFILE" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
    log "ERROR: NVIDIA installer exited with code $RC"
    log "See /var/log/nvidia-installer.log for details."
    exit $RC
fi
log "NVIDIA installer finished successfully"

# ── Step 6: Rebuild initramfs so the blacklist applies at boot ────────
log "Rebuilding initramfs…"
if [[ "$PKG_MGR" == "apt" ]]; then
    update-initramfs -u -k "$KVER" >>"$LOGFILE" 2>&1 || true
else
    dracut --force --kver "$KVER" >>"$LOGFILE" 2>&1 || true
fi

# ── Step 7: Optional package hold ──────────────────────────────────────
if [[ $HOLD_PKG -eq 1 ]]; then
    if [[ "$PKG_MGR" == "apt" ]]; then
        HELD=$(dpkg -l 'nvidia-*' 'libnvidia-*' 2>/dev/null | awk '/^ii/{print $2}' || true)
        if [[ -n "$HELD" ]]; then
            apt-mark hold $HELD >>"$LOGFILE" 2>&1 || true
            log "Held packages: $HELD"
        fi
    else
        if dnf versionlock --help >/dev/null 2>&1; then
            dnf versionlock add 'akmod-nvidia*' 'xorg-x11-drv-nvidia*' \
                'kmod-nvidia*' >>"$LOGFILE" 2>&1 || true
            log "Versionlock applied to nvidia packages"
        else
            log "WARNING: --hold requested but dnf versionlock plugin is not"
            log "         installed. Run: dnf install python3-dnf-plugin-versionlock"
        fi
    fi
fi

log "==== Done. Reboot to switch to the new driver. ===="
exit 0
