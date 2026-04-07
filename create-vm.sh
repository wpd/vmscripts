#!/bin/bash
# =============================================================================
# create-vm.sh
#
# Creates a new VMware Workstation Pro 25H2 VM on a Ubuntu 24.04 LTS host
# and boots it headlessly from a pre-built autoinstall ISO to perform an
# unattended Ubuntu Server installation.
#
# This script expects the Ubuntu ISO to already contain the autoinstall
# configuration. Use build-autoinstall-iso.sh to produce that ISO from
# a standard Ubuntu Server 24.04 download.
#
# Prerequisites:
#   - VMware Workstation Pro 25H2 installed (provides vmcli, vmrun,
#     vmware-vdiskmanager at /usr/bin)
#   - libaio symlink created (suppresses vmrun warning on Ubuntu 24.04):
#       sudo ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 \
#                  /usr/lib/x86_64-linux-gnu/libaio.so.1
#   - Autoinstall ISO built with build-autoinstall-iso.sh
#
# Usage:
#   ./create-vm.sh <vm-name>
#
# Arguments:
#   vm-name   Name of the VM (used for directory, VMX file, and display name)
#
# Example:
#   ./create-vm.sh my-server
#
# After running, the script will print instructions for monitoring the
# installation progress via vmrun and SSH.
# =============================================================================

set -euo pipefail

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <vm-name>"
    echo ""
    echo "  vm-name   Name of the VM (directory, VMX file, and display name)"
    echo ""
    echo "Example: $0 my-server"
    exit 1
fi

VM_NAME="$1"

# =============================================================================
# CONFIGURATION — edit these variables before running
# =============================================================================

# Where to create the VM directory on the host
VM_BASE_DIR="$HOME/vmware"

# Path to the autoinstall ISO built with build-autoinstall-iso.sh
UBUNTU_ISO="$(pwd)/ubuntu-24.04.4-autoinstall.iso"

# VM hardware settings
VM_RAM_MB=8192       # RAM in MB (must be a multiple of 4)
VM_DISK_GB=80        # Disk size in GB
VM_CPUS=2            # Number of vCPUs

# Username of the account created during installation — used only in the
# SSH hint printed at the end of the script.
INSTALL_USERNAME="wpd"

# =============================================================================
# DERIVED PATHS — do not edit below this line
# =============================================================================

VM_DIR="${VM_BASE_DIR}/${VM_NAME}"
VMX="${VM_DIR}/${VM_NAME}.vmx"
VMDK="${VM_DIR}/${VM_NAME}.vmdk"

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

echo "==> Checking prerequisites..."

for cmd in vmcli vmrun vmware-vdiskmanager; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found in PATH. Aborting."
        exit 1
    fi
done

if [ ! -f "$UBUNTU_ISO" ]; then
    echo "ERROR: Autoinstall ISO not found at: $UBUNTU_ISO"
    echo "       Build it with build-autoinstall-iso.sh, then update"
    echo "       the UBUNTU_ISO variable in this script."
    exit 1
fi

# Ensure the ISO path is absolute so VMware can find it regardless of
# where the script is run from.
UBUNTU_ISO="$(realpath "$UBUNTU_ISO")"

if [ -d "$VM_DIR" ]; then
    echo "ERROR: VM directory already exists: $VM_DIR"
    echo "       Remove it or choose a different vm-name."
    exit 1
fi

echo "    All prerequisites satisfied."

# =============================================================================
# STEP 1 — Create the VM with vmcli
# =============================================================================

echo ""
echo "==> Step 1: Creating VM '${VM_NAME}'..."

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
# STEP 2 — Create the virtual disk
# =============================================================================

echo ""
echo "==> Step 2: Creating ${VM_DISK_GB}GB virtual disk..."

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
# STEP 3 — Attach the autoinstall ISO
# =============================================================================

echo ""
echo "==> Step 3: Attaching autoinstall ISO..."

vmcli Sata SetPresent sata0 1 "$VMX"
vmcli Disk SetBackingInfo sata0:0 cdrom_image "$UBUNTU_ISO" 1 "$VMX"
vmcli Disk SetPresent sata0:0 1 "$VMX"

echo "    ISO attached: $UBUNTU_ISO"

# =============================================================================
# STEP 4 — Configure networking (NAT)
# =============================================================================

echo ""
echo "==> Step 4: Configuring networking..."

vmcli Ethernet SetVirtualDevice ethernet0 vmxnet3 "$VMX"
vmcli Ethernet SetConnectionType ethernet0 nat "$VMX"
vmcli Ethernet SetAddressType ethernet0 generated "" "$VMX"
vmcli Ethernet SetLinkStatePropagation ethernet0 true "$VMX"
vmcli Ethernet SetPresent ethernet0 1 "$VMX"

echo "    Network configured: NAT (vmxnet3)"

# =============================================================================
# STEP 5 — Start the VM headlessly
# =============================================================================

echo ""
echo "==> Step 5: Starting VM headlessly..."

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
