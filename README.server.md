# VM Creation Script

Script for creating and configuring Ubuntu Server 24.04 VMs on a Ubuntu
24.04 LTS host, entirely from the command line with no VMware GUI required.
Assumes/Tested with VMware Workstation Pro 25H2.

---

*Developed with [Claude](https://claude.ai) (Anthropic), April 2026.*
*Released under the [MIT License](#license).*

---

## Files

| File | Purpose |
|------|---------|
| `create-ubuntu-server.sh` | Main script — builds autoinstall ISO and creates VM |
| `create-ubuntu.conf.example` | User configuration template — copy to `create-ubuntu.conf` and edit |

---

## One-Time Host Setup

These steps are required once per host. They do not need to be repeated for
each new VM.

**1. Install xorriso** (used to patch the Ubuntu ISO):

```bash
sudo apt install -y xorriso
```

**2. Fix the libaio warning** (in order to suppress a harmless but noisy vmrun message):

```bash
sudo ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 \
           /usr/lib/x86_64-linux-gnu/libaio.so.1
```

---

## Configuration

Edit `create-ubuntu.conf` before running the script for the first time. Copy
`create-ubuntu.conf.example` to `create-ubuntu.conf` and edit it to suit your
environment. The script itself never needs to be edited.

```bash
# Where to create VM directories on the host
VM_BASE_DIR="$HOME/vmware"

# Path to the original Ubuntu Server 24.04 ISO (not pre-modified)
UBUNTU_SOURCE_ISO="/path/to/ubuntu-24.04.4-live-server-amd64.iso"

# VM hardware settings
VM_RAM_MB=8192       # RAM in MB (must be a multiple of 4)
VM_DISK_GB=80        # Disk size in GB
VM_CPUS=2            # Number of vCPUs

# Ubuntu user account to create during installation
INSTALL_USERNAME="???"

# Password hash for the install user.
# Generate with: openssl passwd -6 'yourpassword'
INSTALL_PASSWORD_HASH='$6$rounds=4096$CHANGEME$CHANGEME'

# Path to an authorized_keys file (optional — leave empty for password only)
SSH_AUTHORIZED_KEYS_FILE=""

# Timezone for the installed system.
# Use a tz database name, e.g. America/New_York, America/Los_Angeles, Europe/London
# List all valid values with: timedatectl list-timezones
TIMEZONE="America/New_York"
```

To generate a password hash:

```bash
openssl passwd -6 'yourpassword'
```

---

## Creating a VM

```bash
./create-ubuntu-server.sh <vm-name> [hostname]
```

The hostname defaults to the vm-name if not specified.

**Examples:**

```bash
./create-ubuntu-server.sh my-server
./create-ubuntu-server.sh MyServer my-server
```

The script will:

1. Build a customised Ubuntu Server autoinstall ISO with your configuration
   baked in
2. Create a new VM with `vmcli`
3. Replace the default 20GB disk with a correctly-sized disk
4. Attach the autoinstall ISO
5. Configure NAT networking
6. Start the VM headlessly

The installer runs unattended and reboots automatically when complete. No
interaction is required.

### Monitoring installation progress

Check whether the VM is still running:

```bash
vmrun -T ws list
```

After the installer reboots into the installed system, find the VM's IP
address:

```bash
tail -F /etc/vmware/vmnet8/dhcpd/dhcpd.leases
```

Then SSH in (if desired):

```bash
ssh <username>@<ip-address>
```

---

## Post-Installation: Configure a Static DHCP Lease

By default the VM receives a dynamic IP from VMware's DHCP server. To ensure
the VM always gets the same IP address, configure a static DHCP lease on the
host.

> **Note on VMware's NAT subnet:** VMware 25H2 automatically selects an unused
> private subnet at installation time. For this example, VMware selected
> `172.16.40.0/24`. All examples below use this subnet. If you rebuild VMware
> on a different host, verify your actual subnet first:
>
> ```bash
> grep "subnet" /etc/vmware/vmnet8/dhcpd/dhcpd.conf | head -3
> ```
>
> The safe range for static leases is `.3` through `.127`. Addresses `.1`
> (host adapter), `.2` (NAT gateway), and `.128`–`.254` (DHCP dynamic pool)
> are reserved.

**1. Find the VM's MAC address** (on the host):

```bash
grep -i "generatedAddress" ~/vmware/<vm-name>/<vm-name>.vmx
```

The value of `ethernet0.generatedAddress` is the MAC address.

**2. Edit the VMware DHCP configuration file** (on the host):

```bash
sudo vi /etc/vmware/vmnet8/dhcpd/dhcpd.conf
```

Add a static lease entry at the bottom of the file:

```
host <vm-name> {
    hardware ethernet 00:0c:29:xx:xx:xx;
    fixed-address 172.16.40.x;
}
```

Replace `00:0c:29:xx:xx:xx` with the MAC address from step 1 and
`172.16.40.x` with your chosen static IP (e.g. `172.16.40.3`).

**3. Restart VMware networking** (on the host):

```bash
sudo vmware-networks --stop && sudo vmware-networks --start
```

**4. Restart the VM so that it requests the new lease:**

```bash
vmrun -T ws reset ~/vmware/<vm-name>/<vm-name>.vmx soft
```

**5. Verify** the VM received the correct IP:

```bash
ping 172.16.40.x
```

---

## Post-Installation: Configure SSH Port Forwarding

To SSH into the VM directly from outside the host (e.g. from your Mac) without
needing to SSH into the host first, configure a port forward in VMware's NAT
configuration.

**1. Edit the NAT configuration file** (on the host):

```bash
sudo vi /etc/vmware/vmnet8/nat/nat.conf
```

Find the `[incomingtcp]` section and add a forward:

```
[incomingtcp]
# SSH forward: host port XXXX -> VM port 22
XXXX = 172.16.40.x:22
```

Replace `XXXX` with an unused port on the host (e.g. `9022`) and
`172.16.40.x` with the VM's static IP. Choose a port that does not conflict
with any other VM's port forward.

**2. Restart VMware networking** (on the host):

```bash
sudo vmware-networks --stop && sudo vmware-networks --start
```

**3. Connect** from your Mac (or any external machine):

```bash
ssh -p XXXX <username>@<host-ip>
```

---

## Note on MAC Address Stability

VMware generates the MAC address for each VM deterministically based on the
VM's file path. Specifically, it derives a UUID from a combination of the host
machine's hardware identifiers and the full path to the `.vmx` file, and then
derives the MAC address from that UUID.

The practical consequence is that if you delete a VM and recreate it using
`create-ubuntu-server.sh` with the same name in the same `VM_BASE_DIR`, the new VM will
receive the same MAC address as the old one. This means:

- Any static DHCP lease you configured in `dhcpd.conf` for the old VM will
  automatically apply to the new VM — no changes to `dhcpd.conf` required.
- Any SSH port forwards you configured in `nat.conf` will continue to work
  without modification.

The MAC address will change if you rename the VM or move it to a different
directory, since either change alters the path from which the UUID is derived.

---

## Cheat Sheet

### VM lifecycle

```bash
# Start a VM headlessly (no GUI window)
vmrun -T ws start ~/vmware/<vm-name>/<vm-name>.vmx nogui

# Start a VM with the VMware GUI console
vmrun -T ws start ~/vmware/<vm-name>/<vm-name>.vmx

# Shut down gracefully (requires open-vm-tools in guest)
vmrun -T ws stop ~/vmware/<vm-name>/<vm-name>.vmx soft

# Power off immediately (hard cut)
vmrun -T ws stop ~/vmware/<vm-name>/<vm-name>.vmx hard

# Reboot gracefully
vmrun -T ws reset ~/vmware/<vm-name>/<vm-name>.vmx soft

# Suspend
vmrun -T ws suspend ~/vmware/<vm-name>/<vm-name>.vmx
```

### VM status

```bash
# List all running VMs
vmrun -T ws list

# Get IP address of a running VM (waits until guest tools respond)
vmrun -T ws getGuestIPAddress ~/vmware/<vm-name>/<vm-name>.vmx -wait

# Query power state of a VM
vmcli ~/vmware/<vm-name>/<vm-name>.vmx Power query
```

### VM configuration

```bash
# View the full VMX configuration file
cat ~/vmware/<vm-name>/<vm-name>.vmx

# Find the MAC address of a VM
grep -i "generatedAddress" ~/vmware/<vm-name>/<vm-name>.vmx

# Set a VMX configuration parameter
vmcli ConfigParams SetEntry <key> <value> ~/vmware/<vm-name>/<vm-name>.vmx

# View virtual disk details (size, type, adapter)
head -20 ~/vmware/<vm-name>/<vm-name>.vmdk
```

### DHCP and networking (on the host)

```bash
# View the VMware NAT subnet and DHCP configuration
cat /etc/vmware/vmnet8/dhcpd/dhcpd.conf

# View current DHCP leases (shows IPs assigned to running VMs)
cat /etc/vmware/vmnet8/dhcpd/dhcpd.leases

# View the NAT port forwarding configuration
cat /etc/vmware/vmnet8/nat/nat.conf

# Restart VMware networking (required after editing dhcpd.conf or nat.conf)
sudo vmware-networks --stop && sudo vmware-networks --start
```

### Snapshot management

```bash
# Take a snapshot
vmrun -T ws snapshot ~/vmware/<vm-name>/<vm-name>.vmx <snapshot-name>

# List snapshots
vmrun -T ws listSnapshots ~/vmware/<vm-name>/<vm-name>.vmx

# Revert to a snapshot
vmrun -T ws revertToSnapshot ~/vmware/<vm-name>/<vm-name>.vmx <snapshot-name>

# Delete a snapshot
vmrun -T ws deleteSnapshot ~/vmware/<vm-name>/<vm-name>.vmx <snapshot-name>
```

---

## License

MIT License

Copyright (c) 2026 Patrick Doyle, developed with Claude (Anthropic)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
