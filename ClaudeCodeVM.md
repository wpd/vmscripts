# Claude Code Development VM on VMware Workstation Pro 25H2

## Overview

This guide covers:
1. Creating a VM in VMware Workstation Pro 25H2 with a single virtual disk
2. Installing Ubuntu Desktop 24.04 directly (no server conversion required)
3. Installing VMware Tools
4. Enabling GNOME Remote Desktop (RDP)
5. Configuring VMware NAT port forwarding for SSH and RDP access

**Disk layout:**
- 1 x 80 GB disk — houses the entire installation including `/home`

---

## Phase 1 — Create the VM in VMware Workstation Pro 25H2

1. Click **Create a New Virtual Machine**

2. Select **Typical (recommended)** and click Next

3. Select **Installer disc image file (ISO)**, browse to your Ubuntu Desktop
   24.04 ISO, and click Next

4. Fill in your name, username, and password if Easy Install prompts you — or
   if you prefer to install manually, select **I will install the operating
   system later** and attach the ISO via the CD/DVD device in Customize
   Hardware. Either approach works for a single-disk Desktop installation.

5. Give the VM a name (e.g. `ClaudeCodeVM`) and choose a location, click Next

6. Set disk size to **80 GB**, select **Store virtual disk as a single file**,
   click Next

7. Click **Customize Hardware** to adjust processors and RAM:
   - Set RAM to **8192 MB** (8 GB)
   - Accept the default processor configuration (the exact split between
     processors and cores per processor does not matter for Ubuntu)
   - Verify the CD/DVD device is pointing at your Ubuntu Desktop 24.04 ISO
   - Click **Close**

8. Click **Finish** to create the VM

---

## Phase 2 — Install Ubuntu Desktop 24.04

Power on the VM and work through the installer.

> **Note:** Ubuntu Desktop 24.04 uses a different installer (the new Flutter-based
> installer) than Ubuntu Server. The steps below reflect that experience.

1. Select your language and click **Next**

2. Select your accessibility options (or skip) and click **Next**

3. Select your keyboard layout and click **Next**

4. Select **Connect to the internet** if prompted, or skip and click **Next**

5. On the installation type screen, select **Install Ubuntu** and click **Next**

6. Select **Interactive installation** and click **Next**

7. Select **Default selection** (standard desktop apps) and click **Next**
   - Optionally select **Extended selection** if you want additional apps

8. On the additional options screen, check **Install third-party software for
   graphics and Wi-Fi hardware** if desired, then click **Next**

9. On the disk setup screen, select **Erase disk and install Ubuntu** — since
   this is a fresh VM with a single virtual disk this is the correct choice,
   click **Next**

10. Review the disk layout and click **Next**

11. Set your timezone — select **New York** (or search for it), click **Next**

12. Create your user account:
    - Your name
    - Computer name (hostname)
    - Username
    - Password
    - Click **Next**

13. Review the installation summary and click **Install**

14. Wait for the installation to complete, then click **Restart Now**

15. When prompted to remove the installation medium, press Enter (VMware will
    handle this automatically)

16. Once the system has rebooted and you have logged in, open a terminal and
    update the system:

```bash
sudo apt update
sudo apt upgrade -y
```

17. Reboot:

```bash
sudo reboot
```

---

## Phase 3 — Enable SSH

Unlike Ubuntu Server, Ubuntu Desktop 24.04 does not install or enable the SSH
server by default. Install and enable it so you can access the VM from the
command line without needing the VMware console or RDP.

**1. Install the OpenSSH server:**

```bash
sudo apt install -y openssh-server
```

**2. Enable the SSH service so it starts automatically on boot:**

```bash
sudo systemctl enable ssh
```

**3. Start the SSH service:**

```bash
sudo systemctl start ssh
```

**4. Verify the SSH service is running:**

```bash
systemctl status ssh
```

You should see `active (running)`.

**5. Verify port 22 is listening:**

```bash
ss -tlnp | grep 22
```

---

## Phase 4 — Configure a Static DHCP Lease

To ensure the VM always receives the same IP address, configure a static lease
in VMware's DHCP server on the **host machine**.

> **Note on VMware's NAT subnet:** VMware 25H2 automatically selects an unused
> private subnet at installation time — it does not use a fixed default. On
> this host, VMware selected `172.16.40.0/24`. All examples below use this
> subnet. If you rebuild VMware on a different host, verify your actual subnet
> first by reading `/etc/vmware/vmnet8/dhcpd/dhcpd.conf`.

**1. Find the VM's IP address** (from a terminal on the VM):

```bash
ip addr show
```

Look for the `inet` line under your network interface (typically `ens33` in a
VMware VM). The IP address will appear in the form `172.16.40.x/24`.

**2. Find the VM's MAC address** (on the host machine):

```bash
grep -i "generatedAddress" /path/to/your/vm/ClaudeCodeVM.vmx
```

The output will look like:

```
ethernet0.generatedAddress = "00:0c:29:xx:xx:xx"
```

**3. Confirm the NAT subnet** by reading the DHCP config file on the host:

```bash
cat /etc/vmware/vmnet8/dhcpd/dhcpd.conf
```

Near the top you will see a `subnet` block like this:

```
subnet 172.16.40.0 netmask 255.255.255.0 {
    range 172.16.40.128 172.16.40.254;
    ...
}
```

Per the VMware 25H2 documentation, the DHCP server dynamically assigns
addresses in the range `net.128` through `net.254`. Addresses `net.3` through
`net.127` are available for static assignments. `net.1` is reserved for the
host virtual network adapter and `net.2` is reserved for the NAT device. On
this host, choose a static IP in the range `172.16.40.3` to `172.16.40.127`.

**4. Add a static lease entry** to the DHCP config file on the host:

```bash
sudo vi /etc/vmware/vmnet8/dhcpd/dhcpd.conf
```

Scroll to the bottom and add:

```
host ClaudeCodeVM {
    hardware ethernet 00:0c:29:xx:xx:xx;
    fixed-address 172.16.40.x;
}
```

Replace `00:0c:29:xx:xx:xx` with your VM's actual MAC address and
`172.16.40.x` with your chosen static IP. Save the file.

**5. Restart VMware networking services** on the host:

```bash
sudo vmware-networks --stop
sudo vmware-networks --start
```

**6. Renew the DHCP lease** in the VM.

> **Note:** Ubuntu 24.04 Desktop uses NetworkManager. The following command
> lists your network connections and their names. Look for the connection
> associated with your ethernet interface (`ens33`) — you will need its name
> for the next step.

```bash
nmcli connection show
```

The output will look something like this:

```
NAME           UUID                                  TYPE      DEVICE
netplan-ens33  14f59568-5076-387a-aef6-10adfcca2e26  ethernet  ens33
lo             6f0a0746-7bac-4ffc-9584-b5c6cf704afc  loopback  lo
```

Use the name from the **NAME** column for your ethernet connection in the
following commands. Based on the output above, the connection name is
`netplan-ens33`:

```bash
nmcli connection down netplan-ens33
```

```bash
nmcli connection up netplan-ens33
```

Verify the new IP address:

```bash
ip addr show
```

---

## Phase 5 — Configure Port Forwarding in VMware NAT

Since the remote host already uses ports 22 (SSH) and 3389 (RDP), forward
different host ports to the VM's standard SSH and RDP ports. All configuration
is done by editing VMware's NAT configuration file on the **host machine**.

> **Note:** The NAT configuration file on a Linux host is
> `/etc/vmware/vmnet8/nat/nat.conf`. The 25H2 documentation confirms this is
> the correct location for port forwarding configuration on a Linux host.

**1. Stop VMware networking services** before editing the file:

```bash
sudo vmware-networks --stop
```

**2. Open the NAT configuration file:**

```bash
sudo vi /etc/vmware/vmnet8/nat/nat.conf
```

**3. Find the `[incomingtcp]` section** and add your port forwarding rules
beneath it. Replace `172.16.40.x` with your VM's actual static IP:

```
[incomingtcp]
# SSH forward: host port XXXX -> VM port 22
XXXX = 172.16.40.x:22
# RDP forward: host port YYYY -> VM port 3389
YYYY = 172.16.40.x:3389
```

> Choose host ports that do not conflict with any ports already in use on the
> host machine or by other VMs.

Save the file.

**4. Restart VMware networking services:**

```bash
sudo vmware-networks --start
```

**5. Verify the ports are now listening** on the host:

```bash
ss -tlnp | grep -E 'XXXX|YYYY'
```

---

## Phase 6 — Enable RDP Access via xrdp

> **Background:** Ubuntu 24.04 Desktop includes a built-in RDP server via
> `gnome-remote-desktop`, but it has known compatibility issues with Windows
> App on Mac when installed on a clean Desktop installation. The reliable
> solution is `xrdp`, which is the same approach used on the physical server.
>
> **Important limitations to be aware of:**
> - xrdp creates an independent Xorg-based GNOME session, which looks slightly
>   different from the native Wayland console session (different theme, no
>   Ubuntu vertical dash sidebar).
> - Do **not** connect from two places simultaneously (e.g. xrdp and the
>   VMware console at the same time). xrdp does not handle session conflicts
>   gracefully and can cause the session to crash and freeze. Always disconnect
>   from one before connecting from the other.

**1. Install xrdp:**

```bash
sudo apt install -y xrdp
```

**2. Add xrdp to the ssl-cert group:**

```bash
sudo adduser xrdp ssl-cert
```

**3. Create a `.xsession` file** to configure the correct GNOME session type
for xrdp. Without this, xrdp will fail to start a desktop session on a clean
Ubuntu Desktop 24.04 installation:

```bash
cat > ~/.xsession << 'EOF'
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
gnome-session --session=ubuntu
EOF
chmod +x ~/.xsession
```

> **Note:** This `.xsession` file is required on a clean Ubuntu Desktop
> install but is not needed on a server-converted-to-desktop install (as in
> `server.md`). The difference is that the server conversion path leaves
> `/etc/X11/Xsession` configured in a way that is compatible with Xorg, while
> a clean Desktop install configures it expecting Wayland.

**4. Enable and start xrdp:**

```bash
sudo systemctl enable --now xrdp
```

**5. Verify port 3389 is listening:**

```bash
ss -tlnp | grep 3389
```

---

### Connecting from Windows App on your Mac

In Windows App, add a new PC connection with the following PC name (using the
port forward configured in Phase 5):

```
remote_host_ip:YYYY
```

Authenticate with your regular Ubuntu username and password. You do not need
separate "door" credentials as with `gnome-remote-desktop`.

> **Tip:** Once connected via RDP, clipboard sharing between your Mac and the
> VM works correctly, making it much easier to copy and paste commands between
> your browser and the VM terminal.



---

## Phase 7 — Install Claude Code

Please refer to the Claude Code documentation at https://docs.claude.ai for
the most current installation instructions, as these may change between
releases.
