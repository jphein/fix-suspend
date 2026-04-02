#!/usr/bin/env bash
#
# fix-suspend.sh — Fix suspend/hibernate on Dell Precision 3551
#
# What this does:
#   1. Installs HWE kernel for latest hardware/driver support
#   2. Switches from s2idle to deep (S3) sleep via GRUB
#   3. Enables hibernate resume from swap file (GRUB + initramfs)
#   4. Configures suspend-then-hibernate (suspends, then hibernates after 60min)
#   5. Disables spurious ACPI wake sources (XHC/USB, PCI, ethernet)
#   6. Disables GPE6E storm (known Dell ACPI bug — thousands of spurious interrupts)
#   7. Fixes ALPS touchpad jitter/zoom via udev hwdb fuzz + libinput size hint
#   8. Ensures nvidia suspend/resume services are correct
#   9. Rebuilds initramfs so hibernate resume actually works
#
# Run: sudo bash fix-suspend.sh
# After: reboot for all changes to take effect

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!!]${NC} $1"; }
step()  { echo -e "\n${GREEN}==>${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: run this script as root (sudo bash $0)${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Install HWE kernel for latest hardware support
# ---------------------------------------------------------------------------
step "Ensuring HWE kernel is installed"

UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "")
if [[ -n "$UBUNTU_VER" ]]; then
    HWE_PKG="linux-generic-hwe-${UBUNTU_VER}"
    if dpkg -l "$HWE_PKG" &>/dev/null; then
        HWE_KVER=$(dpkg -l "$HWE_PKG" | awk '/^ii/{print $3}')
        info "HWE kernel already installed: ${HWE_PKG} (${HWE_KVER})"
    else
        info "Installing HWE kernel: ${HWE_PKG}"
        apt-get update -qq
        apt-get install -y "$HWE_PKG"
        info "HWE kernel installed — will be active after reboot"
    fi
else
    warn "Could not detect Ubuntu version — skipping HWE kernel check"
fi

# ---------------------------------------------------------------------------
# 2. GRUB: deep sleep + hibernate resume
# ---------------------------------------------------------------------------

step "Configuring GRUB for deep (S3) sleep and hibernate resume"

ROOT_UUID=$(findmnt -no UUID /)
SWAP_OFFSET=$(filefrag -v /swap.img | awk 'NR==4 {gsub(/\./,""); print $4}')

if [[ -z "$SWAP_OFFSET" ]]; then
    warn "Could not determine swap file offset — skipping hibernate resume params"
    RESUME_PARAMS=""
else
    RESUME_PARAMS="resume=UUID=${ROOT_UUID} resume_offset=${SWAP_OFFSET}"
    info "Swap file offset: ${SWAP_OFFSET}"
fi

GRUB_FILE="/etc/default/grub"
cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"

# Build the new cmdline
CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/\1/')

# Strip any existing values we're about to set
CLEANED=$(echo "$CURRENT" | sed -E \
    -e 's/mem_sleep_default=[^ ]*//g' \
    -e 's/resume=[^ ]*//g' \
    -e 's/resume_offset=[^ ]*//g' \
    -e 's/  +/ /g' -e 's/^ //' -e 's/ $//')

NEW_CMDLINE="${CLEANED} mem_sleep_default=deep ${RESUME_PARAMS}"
NEW_CMDLINE=$(echo "$NEW_CMDLINE" | sed 's/  */ /g; s/^ //; s/ $//')

sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" "$GRUB_FILE"
info "GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\""

update-grub
info "GRUB updated"

# ---------------------------------------------------------------------------
# 3. Initramfs: configure resume device so hibernate actually resumes
# ---------------------------------------------------------------------------
step "Configuring initramfs for hibernate resume"

if [[ -n "$SWAP_OFFSET" ]]; then
    mkdir -p /etc/initramfs-tools/conf.d

    # For swap-file-on-root, the kernel boot params (resume=UUID=... resume_offset=...)
    # handle everything. The initramfs RESUME variable must either point to the
    # underlying block device or be "none" — using the root UUID causes a spurious
    # warning because initramfs looks for a swap signature and won't find one on root.
    # Setting RESUME=none tells initramfs to leave resume to the kernel params.
    cat > /etc/initramfs-tools/conf.d/resume <<EOF
RESUME=none
EOF
    info "Initramfs resume config written (RESUME=none, kernel params handle swap file)"

    update-initramfs -u -k all
    info "Initramfs rebuilt for all kernels"
else
    warn "Skipping initramfs resume config (no swap offset)"
fi

# ---------------------------------------------------------------------------
# 4. systemd: suspend-then-hibernate after 60 minutes on battery
# ---------------------------------------------------------------------------
step "Configuring suspend-then-hibernate"

mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/99-fix-suspend.conf <<EOF
[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
SuspendState=mem
HibernateDelaySec=60min
EOF
info "Sleep config written to /etc/systemd/sleep.conf.d/99-fix-suspend.conf"

# Make lid close and power button use suspend-then-hibernate
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-fix-suspend.conf <<EOF
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
HandlePowerKey=suspend-then-hibernate
HandleSuspendKey=suspend-then-hibernate
EOF
info "Logind config: lid close -> suspend-then-hibernate"

# ---------------------------------------------------------------------------
# 5. Disable spurious ACPI wake sources
# ---------------------------------------------------------------------------
step "Disabling spurious wake sources"

# These devices are known to cause immediate wake on Dell Precision 3551:
# - XHC (USB controller) — #1 offender
# - GLAN (ethernet)
# - PEG0, RP01, RP06, RP09, RP17 (PCI bridges — not needed for wake on a laptop)
DISABLE_WAKEUP=(XHC GLAN PEG0 RP01 RP06 RP09 RP17)

cat > /etc/systemd/system/fix-suspend-wakeup.service <<EOF
[Unit]
Description=Disable spurious ACPI wake sources and GPE storms
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
for dev in XHC GLAN PEG0 RP01 RP06 RP09 RP17; do \
    if grep -q "^\${dev}.*enabled" /proc/acpi/wakeup; then \
        echo \$dev > /proc/acpi/wakeup; \
    fi; \
done; \
for gpe in /sys/firmware/acpi/interrupts/gpe*; do \
    count=\$(awk "{print \\\$1}" "\$gpe" 2>/dev/null); \
    if [ "\${count:-0}" -gt 100 ]; then \
        echo disable > "\$gpe" 2>/dev/null || true; \
    fi; \
done'

[Install]
WantedBy=multi-user.target
EOF

# Remove the old service name if it exists from a previous run
if systemctl is-enabled disable-wakeup.service &>/dev/null; then
    systemctl disable --now disable-wakeup.service 2>/dev/null || true
    rm -f /etc/systemd/system/disable-wakeup.service
fi

systemctl daemon-reload
systemctl enable --now fix-suspend-wakeup.service
info "Disabled wake from: ${DISABLE_WAKEUP[*]}"
info "GPE storm mitigation enabled"

# ---------------------------------------------------------------------------
# 6. Nvidia suspend/resume
# ---------------------------------------------------------------------------
step "Verifying nvidia suspend/resume setup"

# nvidia driver 580 already has PreserveVideoMemoryAllocations=1 set
# Just make sure the systemd services are enabled
for svc in nvidia-suspend nvidia-hibernate nvidia-resume; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
        systemctl enable "${svc}.service" 2>/dev/null || true
    fi
done

# Verify the modprobe option is set
if grep -q "NVreg_PreserveVideoMemoryAllocations=1" /etc/modprobe.d/*.conf 2>/dev/null; then
    info "Nvidia VRAM preservation: already configured"
else
    echo "options nvidia NVreg_PreserveVideoMemoryAllocations=1" >> /etc/modprobe.d/nvidia-suspend.conf
    echo "options nvidia NVreg_TemporaryFilePath=/var" >> /etc/modprobe.d/nvidia-suspend.conf
    info "Nvidia VRAM preservation: configured"
fi

# ---------------------------------------------------------------------------
# 7. Fix ALPS touchpad jitter, cursor zoom, and phantom clicks
# ---------------------------------------------------------------------------
step "Fixing ALPS touchpad behavior"

# The ALPS I2C touchpad (0488:121F) on the Precision 3551 has no pressure
# axis and very low resolution (12 units/mm). This causes:
#   - Cursor "zooming off" from acceleration overreacting to jittery coords
#   - Random clicks from tap-to-click firing on accidental brushes
#
# Fix 1: Add fuzz to X/Y axes via udev hwdb — filters micro-jitter at the
#         kernel input layer before libinput ever sees it
# Fix 2: Set proper size hint so libinput calculates acceleration correctly
#         (the touchpad reports 12 u/mm but the actual pad is ~100x55mm)

# --- udev hwdb: add fuzz to filter jitter ---
HWDB_FILE="/etc/udev/hwdb.d/99-touchpad-fuzz.hwdb"
cat > "$HWDB_FILE" <<'EOF'
# Dell Precision 3551 ALPS I2C Touchpad (0488:121F)
# Add fuzz to X/Y axes to filter jitter that causes cursor zoom/drift
evdev:name:DELL09C2:00 0488:121F Touchpad:*
 EVDEV_ABS_00=::+4
 EVDEV_ABS_01=::+4
 EVDEV_ABS_35=::+4
 EVDEV_ABS_36=::+4
EOF
info "Udev hwdb fuzz rule written to ${HWDB_FILE}"

systemd-hwdb update
udevadm trigger /dev/input/event5 2>/dev/null || udevadm trigger
info "Hwdb updated and udev triggered"

# --- libinput quirk: size hint for correct acceleration ---
QUIRKS_DIR="/etc/libinput"
QUIRKS_FILE="${QUIRKS_DIR}/local-overrides.quirks"
QUIRKS_ENTRY="[Dell Precision 3551 Touchpad]
MatchBus=i2c
MatchVendor=0x0488
MatchProduct=0x121F
MatchDMIModalias=dmi:*svnDellInc.:pnPrecision3551*
MatchUdevType=touchpad
AttrSizeHint=100x55"

mkdir -p "$QUIRKS_DIR"
# Remove old entry if present, then write new one
if [[ -f "$QUIRKS_FILE" ]]; then
    sed -i '/\[Dell Precision 3551 Touchpad\]/,/^$/d' "$QUIRKS_FILE"
fi
echo "" >> "$QUIRKS_FILE"
echo "$QUIRKS_ENTRY" >> "$QUIRKS_FILE"
info "Libinput size hint quirk installed to ${QUIRKS_FILE}"

# ---------------------------------------------------------------------------
# 8. Apply what we can immediately (without reboot)
# ---------------------------------------------------------------------------
step "Applying immediate changes (full effect after reboot)"

# Switch to deep sleep now
if [[ -f /sys/power/mem_sleep ]]; then
    echo deep > /sys/power/mem_sleep
    info "mem_sleep set to deep for current session"
fi

# Disable wake sources now
for dev in "${DISABLE_WAKEUP[@]}"; do
    if grep -q "^${dev}.*enabled" /proc/acpi/wakeup; then
        echo "$dev" > /proc/acpi/wakeup
    fi
done
info "Wake sources disabled for current session"

# Disable GPE storm now
for gpe in /sys/firmware/acpi/interrupts/gpe*; do
    count=$(awk '{print $1}' "$gpe" 2>/dev/null)
    if [[ "${count:-0}" -gt 100 ]]; then
        echo disable > "$gpe" 2>/dev/null || true
        info "Disabled runaway $(basename "$gpe") (${count} interrupts)"
    fi
done

# Signal logind to reload config (does NOT restart the session)
systemctl kill -s HUP systemd-logind
info "systemd-logind config reloaded"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Suspend fix applied successfully${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Sleep mode:      s2idle -> deep (S3)"
echo "  Lid close:       suspend-then-hibernate (60min)"
echo "  Power button:    suspend-then-hibernate (60min)"
echo "  Wake sources:    XHC, GLAN, PCI bridges disabled"
echo "  GPE storm:       runaway GPEs disabled"
echo "  Touchpad:        phantom drift fixed (pressure quirk)"
echo "  Nvidia:          VRAM preserved across suspend"
echo "  Hibernate:       resume from /swap.img (GRUB + initramfs)"
echo ""
echo -e "  ${YELLOW}Reboot to apply all changes permanently.${NC}"
echo -e "  You can test suspend now: ${GREEN}systemctl suspend${NC}"
echo ""
