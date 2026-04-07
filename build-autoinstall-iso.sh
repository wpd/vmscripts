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
# After building, update UBUNTU_ISO in create-vm.sh to point to the output ISO.
# The separate seed ISO (sata0:1) attachment in create-vm.sh can then be
# removed since the autoinstall config is now embedded in the bootable ISO.
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
# STEP 1 — Extract the source ISO
# =============================================================================

WORK_DIR="$(mktemp -d)"
BOOT_DIR="${WORK_DIR}/bootpart"
ISO_DIR="${WORK_DIR}/iso"

# Ensure cleanup on exit
trap 'echo "==> Cleaning up..." && rm -rf "$WORK_DIR"' EXIT

echo ""
echo "==> Step 1: Extracting source ISO..."
echo "    Source: $SOURCE_ISO"
echo "    Working directory: $WORK_DIR"

mkdir -p "$BOOT_DIR" "$ISO_DIR"

xorriso -osirrox on \
    -indev "$SOURCE_ISO" \
    --extract_boot_images "$BOOT_DIR" \
    -extract / "$ISO_DIR"

# The extracted files are read-only — make them writable so we can modify them
chmod -R u+w "$ISO_DIR"

echo "    Extraction complete."

# =============================================================================
# STEP 2 — Embed the autoinstall user-data and meta-data in the ISO
# =============================================================================

echo ""
echo "==> Step 2: Embedding autoinstall configuration..."

mkdir -p "${ISO_DIR}/nocloud"

# Build the authorized-keys block if a key file was provided
SSH_KEYS_YAML=""
if [ -n "$SSH_AUTHORIZED_KEYS_FILE" ]; then
    SSH_KEYS_YAML="  authorized-keys:"
    while IFS= read -r key; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        SSH_KEYS_YAML="${SSH_KEYS_YAML}"$'\n'"    - \"${key}\""
    done < "$SSH_AUTHORIZED_KEYS_FILE"
fi

cat > "${ISO_DIR}/nocloud/user-data" << EOF
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

# meta-data is required by cloud-init but can be empty
touch "${ISO_DIR}/nocloud/meta-data"

echo "    Configuration embedded."
echo ""
echo "    NOTE: The hostname in the embedded user-data is set to 'CHANGEME'."
echo "    The hostname will be whatever you configure in create-vm.sh — but"
echo "    since it is now baked into the ISO it cannot vary per VM."
echo "    Consider setting it to a placeholder and changing it post-install,"
echo "    or build a separate ISO per hostname."

# =============================================================================
# STEP 3 — Patch the GRUB configuration
# =============================================================================

echo ""
echo "==> Step 3: Patching GRUB configuration..."

GRUB_CFG="${ISO_DIR}/boot/grub/grub.cfg"

if [ ! -f "$GRUB_CFG" ]; then
    echo "ERROR: GRUB config not found at: $GRUB_CFG"
    echo "       The source ISO may not be a standard Ubuntu Server ISO."
    exit 1
fi

# Insert an autoinstall menu entry at the top of grub.cfg, before any existing
# entries. The set timeout=1 means GRUB will auto-select it after 1 second.
AUTOINSTALL_ENTRY='set timeout=1\n\nmenuentry "Autoinstall Ubuntu Server" {\n    set gfxpayload=keep\n    linux   /casper/vmlinuz quiet autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---\n    initrd  /casper/initrd\n}\n'

# Prepend the entry before the first existing menuentry
sed -i "0,/^menuentry/s||${AUTOINSTALL_ENTRY}\n&|" "$GRUB_CFG"

echo "    GRUB configuration patched."

# =============================================================================
# STEP 4 — Update the md5sum manifest
# =============================================================================

echo ""
echo "==> Step 4: Updating md5sum manifest..."

# The ISO contains an md5sum.txt that the installer verifies at boot.
# We must update it to reflect our modified and added files.
pushd "$ISO_DIR" > /dev/null
md5sum nocloud/user-data nocloud/meta-data boot/grub/grub.cfg >> md5sum.txt
popd > /dev/null

echo "    md5sum manifest updated."

# =============================================================================
# STEP 5 — Repack the ISO
# =============================================================================

echo ""
echo "==> Step 5: Repacking ISO..."
echo "    Output: $OUTPUT_ISO"

# This xorriso command preserves the original EFI and MBR boot structures
# extracted in Step 1, producing a hybrid ISO that boots on both BIOS and
# UEFI systems — matching the boot capability of the original Ubuntu ISO.
xorriso -as mkisofs \
    -r \
    -V "ubuntu-autoinstall" \
    -J \
    -boot-load-size 4 \
    -boot-info-table \
    -input-charset utf-8 \
    -eltorito-alt-boot \
    -b "${BOOT_DIR}/eltorito_img1_bios.img" \
    -no-emul-boot \
    -o "$OUTPUT_ISO" \
    "$ISO_DIR"

echo "    ISO repacked successfully."

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
echo "   2. Remove the seed ISO attachment from create-vm.sh"
echo "      (the sata0:1 vmcli Disk commands in Step 6)"
echo "   3. Run create-vm.sh as normal — the installer will proceed"
echo "      without any confirmation prompt"
echo "============================================================"
