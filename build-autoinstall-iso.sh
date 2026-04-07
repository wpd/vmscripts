#!/bin/bash
# =============================================================================
# build-autoinstall-iso.sh
#
# Takes an Ubuntu Server 24.04 ISO and produces a new ISO with the autoinstall
# configuration baked in. The resulting ISO boots directly into the unattended
# installer with no confirmation prompt and no separate seed ISO required.
#
# The autoinstall user-data and meta-data are embedded in the ISO itself under
# /nocloud/, and the GRUB menu is patched to pass:
#   autoinstall ds=nocloud;s=/cdrom/nocloud/
# on the kernel command line.
#
# Prerequisites:
#   - xorriso installed: sudo apt install -y xorriso
#
# Usage:
#   ./build-autoinstall-iso.sh <source-iso> <output-iso>
#
# Example:
#   ./build-autoinstall-iso.sh \
#       ~/iso/ubuntu-24.04.4-live-server-amd64.iso \
#       ~/iso/ubuntu-24.04.4-autoinstall.iso
#
# Prerequisites:
#   - xorriso installed: sudo apt install -y xorriso
#
# Usage:
#   ./build-autoinstall-iso.sh <source-iso> <output-iso>
#
# Example:
#   ./build-autoinstall-iso.sh ~/iso/ubuntu-24.04.4-live-server-amd64.iso \
#                              ~/iso/ubuntu-24.04.4-autoinstall.iso
#
# After building, update UBUNTU_ISO in create-vm.sh to point to the output ISO.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — edit these variables before running
# =============================================================================

# Ubuntu user account to create during installation
INSTALL_USERNAME="wpd"

# Password hash for the install user.
# Generate with: openssl passwd -6 'yourpassword'
# INSTALL_PASSWORD_HASH='$6$rounds=4096$CHANGEME$CHANGEME'
INSTALL_PASSWORD_HASH='$6$onnxrBvm/M6iBIyj$gZfNJ.p.sSXC5QQL/Yq.FFCyLVSUec200tsRh4Q2WOi4MQTvUX2EnMyWi6nv5zqZ8i9ccJQ1Mr0Lg2iW1egJy0'

# Path to an authorized_keys file containing one or more SSH public keys
# to install for the install user (one key per line).
# Leave empty to rely on password authentication only.
# Example: SSH_AUTHORIZED_KEYS_FILE="$HOME/.ssh/authorized_keys"
SSH_AUTHORIZED_KEYS_FILE=""

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <source-iso> <output-iso>"
    echo ""
    echo "  source-iso   Path to the original Ubuntu Server 24.04 ISO"
    echo "  output-iso   Path to write the customised autoinstall ISO"
    echo ""
    echo "Example: $0 ~/iso/ubuntu-24.04.4-live-server-amd64.iso \\"
    echo "             ~/iso/ubuntu-24.04.4-autoinstall.iso"
    exit 1
fi

SOURCE_ISO="$(realpath "$1")"
OUTPUT_ISO="$(realpath "$2")"

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

echo "==> Checking prerequisites..."

if ! command -v xorriso &>/dev/null; then
    echo "ERROR: 'xorriso' not found. Install with: sudo apt install -y xorriso"
    exit 1
fi

if [ ! -f "$SOURCE_ISO" ]; then
    echo "ERROR: Source ISO not found: $SOURCE_ISO"
    exit 1
fi

if [ -f "$OUTPUT_ISO" ]; then
    echo "ERROR: Output ISO already exists: $OUTPUT_ISO"
    echo "       Remove it or choose a different output path."
    exit 1
fi

if [ -n "$SSH_AUTHORIZED_KEYS_FILE" ] && [ ! -f "$SSH_AUTHORIZED_KEYS_FILE" ]; then
    echo "ERROR: SSH authorized keys file not found: $SSH_AUTHORIZED_KEYS_FILE"
    exit 1
fi

if [ "$INSTALL_PASSWORD_HASH" = '$6$rounds=4096$CHANGEME$CHANGEME' ]; then
    echo "ERROR: You must set INSTALL_PASSWORD_HASH before running."
    echo "       Generate one with: openssl passwd -6 'yourpassword'"
    exit 1
fi

echo "    All prerequisites satisfied."

# =============================================================================
# STEP 1 — Build the files to overlay onto the ISO
# =============================================================================

WORK_DIR="$(mktemp -d)"

# Ensure cleanup on exit
trap 'echo "==> Cleaning up..." && rm -rf "$WORK_DIR"' EXIT

echo ""
echo "==> Step 1: Building overlay files..."

# Create the nocloud directory that will be added to the ISO
mkdir -p "${WORK_DIR}/nocloud"

# Build the authorized-keys block if a key file was provided
SSH_KEYS_YAML=""
if [ -n "$SSH_AUTHORIZED_KEYS_FILE" ]; then
    SSH_KEYS_YAML="  authorized-keys:"
    while IFS= read -r key; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        SSH_KEYS_YAML="${SSH_KEYS_YAML}"$'\n'"    - \"${key}\""
    done < "$SSH_AUTHORIZED_KEYS_FILE"
fi

cat > "${WORK_DIR}/nocloud/user-data" << EOF
#cloud-config
autoinstall:
  version: 1

  locale: en_US.UTF-8

  keyboard:
    layout: us

  network:
    network:
      version: 2
      ethernets:
        ens33:
          dhcp4: true

  storage:
    layout:
      name: lvm

  identity:
    hostname: CHANGEME
    username: ${INSTALL_USERNAME}
    password: "${INSTALL_PASSWORD_HASH}"

  ssh:
    install-server: true
    allow-pw: true
${SSH_KEYS_YAML}

  packages:
    - open-vm-tools

  late-commands:
    - curtin in-target -- systemctl enable ssh

  user-data:
    disable_root: true
EOF

touch "${WORK_DIR}/nocloud/meta-data"

echo "    Overlay files built."
echo ""
echo "    NOTE: The hostname in user-data is set to 'CHANGEME'."
echo "    Consider setting it post-install, or build a separate ISO per hostname."

# =============================================================================
# STEP 2 — Extract and patch the GRUB configuration
# =============================================================================

echo ""
echo "==> Step 2: Patching GRUB configuration..."

# Extract just the grub.cfg from the source ISO so we can patch it
xorriso -osirrox on \
    -indev "$SOURCE_ISO" \
    -extract /boot/grub/grub.cfg "${WORK_DIR}/grub.cfg" \
    2>/dev/null

chmod u+w "${WORK_DIR}/grub.cfg"

# Insert an autoinstall menu entry at the top of grub.cfg with a 1-second
# timeout so GRUB auto-selects it without waiting for user input
AUTOINSTALL_ENTRY='set timeout=1\n\nmenuentry "Autoinstall Ubuntu Server" {\n    set gfxpayload=keep\n    linux   /casper/vmlinuz quiet autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---\n    initrd  /casper/initrd\n}\n'

sed -i "0,/^menuentry/s||${AUTOINSTALL_ENTRY}\n&|" "${WORK_DIR}/grub.cfg"

echo "    GRUB configuration patched."

# =============================================================================
# STEP 3 — Repack the ISO using xorriso overlay mode
# =============================================================================
#
# Rather than extracting and repacking the entire ISO (which requires
# reconstructing the complex EFI/MBR/GPT boot structures), we use xorriso's
# -indev/-outdev mode to open the source ISO, overlay our changed files on
# top of it, and write a new ISO. The -boot_image any replay flag tells
# xorriso to carry over all boot structures from the source ISO exactly,
# so the output is bootable without us needing to specify any boot parameters.

echo ""
echo "==> Step 3: Building output ISO..."
echo "    Source: $SOURCE_ISO"
echo "    Output: $OUTPUT_ISO"

xorriso \
    -indev "$SOURCE_ISO" \
    -outdev "$OUTPUT_ISO" \
    -map "${WORK_DIR}/nocloud" /nocloud \
    -map "${WORK_DIR}/grub.cfg" /boot/grub/grub.cfg \
    -boot_image any replay

echo "    ISO built successfully."

# =============================================================================
# DONE
# =============================================================================

echo ""
echo "============================================================"
echo " Autoinstall ISO built successfully"
echo "============================================================"
echo ""
echo " Output ISO: $OUTPUT_ISO"
echo ""
echo " Next steps:"
echo "   1. Update UBUNTU_ISO in create-vm.sh to point to this ISO"
echo "   2. Run: ./create-vm.sh <vm-name>"
echo "============================================================"
