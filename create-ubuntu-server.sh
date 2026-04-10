#!/bin/bash
# =============================================================================
# create-ubuntu-server.sh
#
# Developed with Claude (Anthropic), April 2026.
#
# MIT License
# Copyright (c) 2026 Patrick Doyle, developed with Claude (Anthropic)
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
# =============================================================================
# =============================================================================
# create-ubuntu-server.sh
#
# Builds a customised Ubuntu Server 24.04 autoinstall ISO and uses it to
# create and boot a new VMware Workstation Pro 25H2 VM on a Ubuntu 24.04 LTS
# host. The installation runs headlessly and requires no user interaction.
#
# Prerequisites:
#   - VMware Workstation Pro 25H2 installed (provides vmcli, vmrun,
#     vmware-vdiskmanager at /usr/bin)
#   - xorriso installed: sudo apt install -y xorriso
#   - libaio symlink created (suppresses vmrun warning on Ubuntu 24.04):
#       sudo ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 \
#                  /usr/lib/x86_64-linux-gnu/libaio.so.1
#
# Configuration is read from create-ubuntu.conf in the same directory as this
# script. Edit that file to set your ISO path, hardware settings, etc.
#
# Usage:
#   ./create-ubuntu-server.sh <vm-name> [<hostname>]
#
# Arguments:
#   vm-name    Name of the VM (directory, VMX file, and display name)
#   hostname   Hostname to assign to the installed Ubuntu system defaults to
#.             <vm-name> if not specified.
#
# Example:
#   ./create-ubuntu-server.sh my-server my-server
#
# After running, the script will print instructions for monitoring the
# installation progress via vmrun and SSH.
# =============================================================================

set -euo pipefail

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/create-ubuntu.conf"

if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONF_FILE"
    echo "       Create it alongside this script. See create-ubuntu.conf for a template."
    exit 1
fi

# shellcheck source=create-ubuntu.conf
source "$CONF_FILE"

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <vm-name> [hostname]"
    echo ""
    echo "  vm-name    Name of the VM (directory, VMX file, and display name)"
    echo "  hostname   Hostname for the installed Ubuntu system"
    echo "             (optional, defaults to vm-name if not specified)"
    echo ""
    echo "Example: $0 my-server"
    echo "Example: $0 my-server my-server.local"
    exit 1
fi

VM_NAME="$1"
INSTALL_HOSTNAME="${2:-$VM_NAME}"

# =============================================================================
# DERIVED PATHS
# =============================================================================

VM_DIR="${VM_BASE_DIR}/${VM_NAME}"
VMX="${VM_DIR}/${VM_NAME}.vmx"
VMDK="${VM_DIR}/${VM_NAME}.vmdk"

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

echo "==> Checking prerequisites..."

for cmd in vmcli vmrun vmware-vdiskmanager xorriso; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found in PATH. Aborting."
        echo "       Install xorriso with: sudo apt install -y xorriso"
        exit 1
    fi
done

SOURCE_ISO="$(realpath "$UBUNTU_SOURCE_ISO")"

if [ ! -f "$SOURCE_ISO" ]; then
    echo "ERROR: Source ISO not found: $SOURCE_ISO"
    echo "       Update UBUNTU_SOURCE_ISO in create-ubuntu.conf."
    exit 1
fi

if [ -n "$SSH_AUTHORIZED_KEYS_FILE" ] && [ ! -f "$SSH_AUTHORIZED_KEYS_FILE" ]; then
    echo "ERROR: SSH authorized keys file not found: $SSH_AUTHORIZED_KEYS_FILE"
    echo "       Update SSH_AUTHORIZED_KEYS_FILE in create-ubuntu.conf."
    exit 1
fi

if [ "$INSTALL_PASSWORD_HASH" = '$6$rounds=4096$CHANGEME$CHANGEME' ]; then
    echo "ERROR: You must set INSTALL_PASSWORD_HASH in create-ubuntu.conf."
    echo "       Generate one with: openssl passwd -6 'yourpassword'"
    exit 1
fi

if [ -d "$VM_DIR" ]; then
    echo "ERROR: VM directory already exists: $VM_DIR"
    echo "       Remove it or choose a different vm-name."
    exit 1
fi

if [ -z "$TIMEZONE" ]; then
    echo "ERROR: TIMEZONE is not set in create-ubuntu.conf."
    echo "       Example: TIMEZONE=\"America/New_York\""
    echo "       List valid values with: timedatectl list-timezones"
    exit 1
fi

echo "    All prerequisites satisfied."

# =============================================================================
# STEP 1 — Build the autoinstall ISO
# =============================================================================

WORK_DIR="$(mktemp -d)"
AUTOINSTALL_ISO="${WORK_DIR}/autoinstall.iso"

# Clean up temp directory on exit (after VM has started, ISO is no longer needed)
trap 'echo "==> Cleaning up temp files..." && rm -rf "$WORK_DIR"' EXIT

echo ""
echo "==> Step 1: Building autoinstall ISO..."

mkdir -p "${WORK_DIR}/nocloud"

# Build the authorized-keys YAML block if a key file was provided
SSH_KEYS_YAML=""
if [ -n "$SSH_AUTHORIZED_KEYS_FILE" ]; then
    SSH_KEYS_YAML="    authorized-keys:"
    while IFS= read -r key; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        SSH_KEYS_YAML="${SSH_KEYS_YAML}"$'\n'"      - \"${key}\""
    done < "$SSH_AUTHORIZED_KEYS_FILE"
fi

cat > "${WORK_DIR}/nocloud/user-data" << EOF
#cloud-config
autoinstall:
  version: 1

  locale: en_US.UTF-8

  timezone: ${TIMEZONE}

  keyboard:
    layout: us

  network:
    network:
      version: 2
      ethernets:
        any-nic:
          match:
            name: "en*"
          dhcp4: true

  storage:
    layout:
      name: lvm

  identity:
    hostname: ${INSTALL_HOSTNAME}
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

# Extract grub.cfg from the source ISO and patch it to add the autoinstall
# entry with a 1-second timeout so GRUB auto-selects it
xorriso -osirrox on \
    -indev "$SOURCE_ISO" \
    -extract /boot/grub/grub.cfg "${WORK_DIR}/grub.cfg" \
    2>/dev/null

chmod u+w "${WORK_DIR}/grub.cfg"

# AUTOINSTALL_ENTRY — origin and verification
#
# This GRUB menu entry was derived by inspecting the existing menuentry blocks
# in the grub.cfg extracted from the Ubuntu 24.04.4 live server ISO. The
# existing entries use the form:
#
#   linux /casper/vmlinuz <options> ---
#   initrd /casper/initrd
#
# The paths /casper/vmlinuz and /casper/initrd are standard for Ubuntu live
# server ISOs and have been consistent across Ubuntu 20.04, 22.04, and 24.04.
#
# Two kernel parameters are added to trigger unattended installation:
#
#   set gfxpayload=keep
#     Tells GRUB to keep the current graphics mode when handing off to the
#     kernel, rather than switching to a text-mode console. This is copied
#     directly from the existing menuentry blocks in the Ubuntu ISO's grub.cfg
#     and ensures the installer's display behaviour matches what Ubuntu expects.
#     Omitting it can cause display corruption or a blank screen during boot on
#     some hardware and hypervisor configurations.
#
#   autoinstall
#     Tells the Ubuntu subiquity installer to run in automated mode. Without
#     this parameter, the installer pauses at "Continue with autoinstall?"
#     even when a valid cloud-init datasource is present.
#
#   ds=nocloud;s=/cdrom/nocloud/
#     Tells cloud-init to read its user-data and meta-data from the nocloud
#     datasource at the path /cdrom/nocloud/ on the mounted ISO. /cdrom is
#     the standard mount point for the installation media in the Ubuntu live
#     environment. The semicolon is escaped as \; because GRUB uses semicolons
#     as command separators.
#
# set timeout=1 causes GRUB to auto-select this entry after 1 second rather
# than waiting indefinitely, which is required for fully headless operation.
#
# The sed command prepends this entry before the first existing menuentry in
# grub.cfg, making it the default boot selection. The pattern
# "0,/^menuentry/s||ENTRY\n&|" matches only the first occurrence of a line
# beginning with "menuentry" and inserts our entry above it, leaving all
# original entries intact below as fallbacks.
#
# To verify or update this entry for a new Ubuntu ISO version:
#   xorriso -osirrox on -indev <new-iso> \
#       -extract /boot/grub/grub.cfg /tmp/grub-check.cfg 2>/dev/null
#   cat /tmp/grub-check.cfg
# Confirm that /casper/vmlinuz and /casper/initrd paths are unchanged.
AUTOINSTALL_ENTRY='set timeout=1\n\nmenuentry "Autoinstall Ubuntu Server" {\n    set gfxpayload=keep\n    linux   /casper/vmlinuz quiet autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---\n    initrd  /casper/initrd\n}\n'

sed -i "0,/^menuentry/s||${AUTOINSTALL_ENTRY}\n&|" "${WORK_DIR}/grub.cfg"

# Overlay the nocloud directory and patched grub.cfg onto the source ISO,
# preserving all EFI/MBR/GPT boot structures via -boot_image any replay
xorriso \
    -indev "$SOURCE_ISO" \
    -outdev "$AUTOINSTALL_ISO" \
    -map "${WORK_DIR}/nocloud" /nocloud \
    -map "${WORK_DIR}/grub.cfg" /boot/grub/grub.cfg \
    -boot_image any replay \
    2>/dev/null

echo "    Autoinstall ISO built."

# =============================================================================
# STEP 2 — Create the VM with vmcli
# =============================================================================

echo ""
echo "==> Step 2: Creating VM '${VM_NAME}'..."

mkdir -p "$VM_DIR"

# Create the base VM structure (generates the .vmx file and a default 20GB disk)
vmcli VM Create -n "$VM_NAME" -d "$VM_DIR" -g ubuntu-64

# Set display name
vmcli ConfigParams SetEntry displayName "$VM_NAME" "$VMX"

# Set RAM
vmcli ConfigParams SetEntry memsize "$VM_RAM_MB" "$VMX"

# Set CPU count
vmcli ConfigParams SetEntry numvcpus "$VM_CPUS" "$VMX"

# Boot order: try disk first; on first boot the disk is blank so BIOS falls
# through to the CD-ROM automatically. After installation the disk boots directly.
vmcli ConfigParams SetEntry bios.bootOrder "hdd,cdrom" "$VMX"

# Disable the boot delay (speeds up headless boots)
vmcli ConfigParams SetEntry bios.bootDelay "0" "$VMX"

echo "    VM created: $VMX"

# =============================================================================
# STEP 3 — Create the virtual disk
# =============================================================================

echo ""
echo "==> Step 3: Creating ${VM_DISK_GB}GB virtual disk..."

# vmcli VM Create auto-creates a default 20GB disk. Remove it and replace it
# with a correctly-sized disk using vmware-vdiskmanager.
rm -f "$VMDK"

# Type 0 = single growable virtual disk (thin provisioned)
# Adapter lsilogic is standard for Linux guests
vmware-vdiskmanager -c -t 0 -s "${VM_DISK_GB}GB" -a lsilogic "$VMDK"

# Attach the disk to the VM via NVMe controller (default for 25H2 ubuntu-64)
vmcli nvme SetPresent nvme0 1 "$VMX"
vmcli Disk SetBackingInfo nvme0:0 disk "${VM_NAME}.vmdk" 1 "$VMX"
vmcli Disk SetPresent nvme0:0 1 "$VMX"

echo "    Disk created and attached: $VMDK"

# =============================================================================
# STEP 4 — Attach the autoinstall ISO
# =============================================================================

echo ""
echo "==> Step 4: Attaching autoinstall ISO..."

vmcli Sata SetPresent sata0 1 "$VMX"
vmcli Disk SetBackingInfo sata0:0 cdrom_image "$AUTOINSTALL_ISO" 1 "$VMX"
vmcli Disk SetPresent sata0:0 1 "$VMX"

echo "    ISO attached."

# =============================================================================
# STEP 5 — Configure networking (NAT)
# =============================================================================

echo ""
echo "==> Step 5: Configuring networking..."

vmcli Ethernet SetVirtualDevice ethernet0 vmxnet3 "$VMX"
vmcli Ethernet SetConnectionType ethernet0 nat "$VMX"
vmcli Ethernet SetAddressType ethernet0 generated "" "$VMX"
vmcli Ethernet SetLinkStatePropagation ethernet0 true "$VMX"
vmcli Ethernet SetPresent ethernet0 1 "$VMX"

echo "    Network configured: NAT (vmxnet3)"

# =============================================================================
# STEP 6 — Start the VM headlessly
# =============================================================================

echo ""
echo "==> Step 6: Starting VM headlessly..."

vmrun -T ws start "$VMX" nogui

echo "    VM started. Installation is running in the background."

# =============================================================================
# NEXT STEPS
# =============================================================================

echo ""
echo "============================================================"
echo " VM '${VM_NAME}' is installing Ubuntu Server 24.04"
echo "============================================================"
echo ""
echo " Check VM power state:"
echo "   vmrun -T ws list"
echo ""
echo " The VM will reboot automatically when installation completes."
echo " After reboot, find the VM's IP address with:"
echo "   vmrun -T ws getGuestIPAddress '$VMX' -wait"
echo ""
echo " Then SSH in:"
echo "   ssh ${INSTALL_USERNAME}@<ip-address>"
echo ""
echo " NOTE: getGuestIPAddress requires open-vm-tools to be running"
echo "       in the guest, which is installed by the autoinstall config."
echo "============================================================"
