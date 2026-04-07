#!/bin/bash
# =============================================================================
# create-vm.sh
#
# Creates a new VMware Workstation Pro 25H2 VM on a Ubuntu 24.04 LTS host,
# builds a Ubuntu Server 24.04 autoinstall seed ISO, and boots the VM
# headlessly to perform an unattended installation.
#
# Prerequisites:
#   - VMware Workstation Pro 25H2 installed (provides vmcli, vmrun,
#     vmware-vdiskmanager at /usr/bin)
#   - genisoimage installed:
#       sudo apt install -y genisoimage
#   - libaio symlink created (suppresses vmrun warning on Ubuntu 24.04):
#       sudo ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 \
#                  /usr/lib/x86_64-linux-gnu/libaio.so.1
#   - Ubuntu Server 24.04 ISO downloaded
#
# Usage:
#   ./create-vm.sh <vm-name> <hostname>
#
# Arguments:
#   vm-name   Name of the VM (used for directory, VMX file, and display name)
#   hostname  Hostname to assign to the installed Ubuntu system
#
# Example:
#   ./create-vm.sh my-server my-server.local
#
# After running, the script will print instructions for monitoring the
# installation progress via vmrun and SSH.
# =============================================================================

set -euo pipefail

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <vm-name> <hostname>"
    echo ""
    echo "  vm-name   Name of the VM (directory, VMX file, and display name)"
    echo "  hostname  Hostname for the installed Ubuntu system"
    echo ""
    echo "Example: $0 my-server my-server"
    exit 1
fi

VM_NAME="$1"
INSTALL_HOSTNAME="$2"

# =============================================================================
# CONFIGURATION — edit these variables before running
# =============================================================================

# Where to create the VM directory on the host
VM_BASE_DIR="$HOME/vmware"

# Path to the Ubuntu Server 24.04 ISO on the host
UBUNTU_ISO="$(pwd)/ubuntu-24.04.4-live-server-amd64.iso"

# VM hardware settings
VM_RAM_MB=8192       # RAM in MB (must be a multiple of 4)
VM_DISK_GB=80        # Disk size in GB
VM_CPUS=2            # Number of vCPUs

# Ubuntu user account to create during installation
INSTALL_USERNAME="wpd"

# Password hash for the install user.
# Generate with: openssl passwd -6 'yourpassword'
# Replace the hash below with your own.
INSTALL_PASSWORD_HASH='$6$onnxrBvm/M6iBIyj$gZfNJ.p.sSXC5QQL/Yq.FFCyLVSUec200tsRh4Q2WOi4MQTvUX2EnMyWi6nv5zqZ8i9ccJQ1Mr0Lg2iW1egJy0'

# Path to an authorized_keys file containing one or more SSH public keys
# to install for the install user (one key per line).
# Leave empty to rely on password authentication only.
# Example: SSH_AUTHORIZED_KEYS_FILE="$HOME/.ssh/authorized_keys"
SSH_AUTHORIZED_KEYS_FILE="./authorized_keys"

# =============================================================================
# DERIVED PATHS — do not edit below this line
# =============================================================================

VM_DIR="${VM_BASE_DIR}/${VM_NAME}"
VMX="${VM_DIR}/${VM_NAME}.vmx"
VMDK="${VM_DIR}/${VM_NAME}.vmdk"
SEED_DIR="${VM_DIR}/seed"
SEED_ISO="${VM_DIR}/seed.iso"

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

echo "==> Checking prerequisites..."

for cmd in vmcli vmrun vmware-vdiskmanager genisoimage; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found in PATH. Aborting."
        echo "       Install genisoimage with: sudo apt install -y genisoimage"
        exit 1
    fi
done

if [ ! -f "$UBUNTU_ISO" ]; then
    echo "ERROR: Ubuntu ISO not found at: $UBUNTU_ISO"
    echo "       Update the UBUNTU_ISO variable in this script."
    exit 1
fi

if [ -d "$VM_DIR" ]; then
    echo "ERROR: VM directory already exists: $VM_DIR"
    echo "       Remove it or choose a different VM_NAME."
    exit 1
fi

if [ -n "$SSH_AUTHORIZED_KEYS_FILE" ] && [ ! -f "$SSH_AUTHORIZED_KEYS_FILE" ]; then
    echo "ERROR: SSH authorized keys file not found at: $SSH_AUTHORIZED_KEYS_FILE"
    echo "       Update the SSH_AUTHORIZED_KEYS_FILE variable in this script."
    exit 1
fi

if [ "$INSTALL_PASSWORD_HASH" = '$6$rounds=4096$CHANGEME$CHANGEME' ]; then
    echo "ERROR: You must set INSTALL_PASSWORD_HASH before running."
    echo "       Generate one with: openssl passwd -6 'yourpassword'"
    exit 1
fi

echo "    All prerequisites satisfied."

# =============================================================================
# STEP 1 — Create the VM with vmcli
# =============================================================================

echo ""
echo "==> Step 1: Creating VM '${VM_NAME}'..."

mkdir -p "$VM_DIR"

# Create the base VM structure (generates the .vmx file)
vmcli VM Create -n "$VM_NAME" -d "$VM_DIR" -g ubuntu-64

# Set display name
vmcli ConfigParams SetEntry displayName "$VM_NAME" "$VMX"

# Set RAM
vmcli ConfigParams SetEntry memsize "$VM_RAM_MB" "$VMX"

# Set CPU count
vmcli ConfigParams SetEntry numvcpus "$VM_CPUS" "$VMX"

# Set boot order: CD-ROM first for installation, then hard disk
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
# STEP 3 — Attach the Ubuntu ISO
# =============================================================================

echo ""
echo "==> Step 3: Attaching Ubuntu Server ISO..."

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
# STEP 5 — Build the autoinstall seed ISO
# =============================================================================

echo ""
echo "==> Step 5: Building autoinstall seed ISO..."

mkdir -p "$SEED_DIR"

# Read SSH public keys from file if provided — one key per line becomes
# one YAML list entry under authorized-keys
if [ -n "$SSH_AUTHORIZED_KEYS_FILE" ]; then
    SSH_KEY_BLOCK="  authorized-keys:"
    while IFS= read -r key; do
        # Skip blank lines and comment lines
        [[ -z "$key" || "$key" == \#* ]] && continue
        SSH_KEY_BLOCK="${SSH_KEY_BLOCK}\n    - \"${key}\""
    done < "$SSH_AUTHORIZED_KEYS_FILE"
else
    SSH_KEY_BLOCK=""
fi

# Write the user-data autoinstall configuration
cat > "${SEED_DIR}/user-data" << EOF
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
    hostname: ${INSTALL_HOSTNAME}
    username: ${INSTALL_USERNAME}
    password: "${INSTALL_PASSWORD_HASH}"

  ssh:
    install-server: true
    allow-pw: true
$([ -n "$SSH_KEY_BLOCK" ] && printf '%b' "$SSH_KEY_BLOCK")

  packages:
    - open-vm-tools

  late-commands:
    - curtin in-target -- systemctl enable ssh

  user-data:
    disable_root: true
EOF

# The meta-data file is required by cloud-init but can be empty
touch "${SEED_DIR}/meta-data"

# Build the seed ISO — must have volume label 'cidata' for cloud-init to find it
genisoimage \
    -output "$SEED_ISO" \
    -volid cidata \
    -joliet \
    -rock \
    "${SEED_DIR}/user-data" \
    "${SEED_DIR}/meta-data"

echo "    Seed ISO built: $SEED_ISO"

# =============================================================================
# STEP 7 — Attach the seed ISO as a second virtual CD-ROM
# =============================================================================

echo ""
echo "==> Step 6: Attaching seed ISO..."

vmcli Sata SetPresent sata0 1 "$VMX"
vmcli Disk SetBackingInfo sata0:1 cdrom_image "$SEED_ISO" 1 "$VMX"
vmcli Disk SetPresent sata0:1 1 "$VMX"

echo "    Seed ISO attached: $SEED_ISO"

# =============================================================================
# STEP 8 — Start the VM headlessly
# =============================================================================

echo ""
echo "==> Step 7: Starting VM headlessly..."

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
