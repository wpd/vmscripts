# Claude Code Desktop Development VM

A guide for setting up a Ubuntu Desktop 24.04 VM as a development environment
for Claude Code with Chrome browser integration.

---

*Developed with [Claude](https://claude.ai) (Anthropic), April 2026.*
*Licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).*

---

## Why a Desktop VM?

Claude Code's Chrome integration — which enables a build-test-debug loop where
Claude can navigate your running web app, read console errors, and fix the
code without you switching contexts — requires a visible Chrome window running
in a real desktop session.

The approach here is to install the Ubuntu Desktop environment on top of a
server base, then enable RDP access via `xrdp`, so you can connect using
Remote Desktop on a PC or the  Windows App on a Mac without needing the
VMware console.

---

## Prerequisites

- A paid Claude plan (Pro, Max, Team, or Enterprise) — required for the Claude
  in Chrome extension

---

## Phase 1 — Install a Ubuntu Server Base

Follow the instructions in `create-ubuntu-server.sh` and its accompanying `README.server.md` to
create and install a Ubuntu Server 24.04 VM.  It is recommended that the server
be created with a minimum of 8GB of RAM and 80GB of disk space.  Once the
installer has completed and the VM has rebooted, verify that you can SSH into it
before proceeding.

---

## Phase 2 — Install the Ubuntu Desktop Environment

All commands in this phase and through Phase 6 are run via SSH unless
otherwise noted.

**1. Update the system:**

```bash
sudo apt update && sudo apt upgrade -y
```

**2. Install the full Ubuntu desktop:**

```bash
sudo apt install -y ubuntu-desktop
```

This will take several minutes. It installs GNOME and all standard desktop
components.

**3. Set the system to boot into a graphical environment:**

```bash
sudo systemctl set-default graphical.target
```

**4. Disable the network wait service** (prevents a 2-minute boot delay that
occurs after converting a server to a desktop):

```bash
sudo systemctl disable --now systemd-networkd-wait-online.service
sudo systemctl mask systemd-networkd-wait-online.service
```

**5. Install `open-vm-tools-desktop`** (if not already installed during installation):

```bash
sudo apt install -y open-vm-tools-desktop
```

**6. Reboot:**

```bash
sudo reboot
```

SSH will drop. Wait about 30 seconds then reconnect.

---

## Phase 3 — Enable RDP Access via xrdp

If the `create-ubuntu-server.sh` instructions are followed faithfully, then the
VM will have been started without the VMware GUI (`nogui`). Rather than using the
VMware console for desktop access, configure `xrdp` so you can connect
directly via Remote Desktop on Windows or the Windows App on a Mac.

**1. Install xrdp:**

```bash
sudo apt install -y xrdp
```

**2. Add xrdp to the ssl-cert group:**

```bash
sudo adduser xrdp ssl-cert
```

**3. Create the `.xsession` file** for your user account. This is required
on a clean Desktop installation to tell xrdp which session type to start.
Without it, xrdp launches but the desktop fails to load.

```bash
cat > ~/.xsession << 'EOF'
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
gnome-session --session=ubuntu
EOF
chmod +x ~/.xsession
```

> **Note:** The `.xsession` file is needed here because a clean Desktop
> install configures the system expecting Wayland, but xrdp uses Xorg. The
> file tells xrdp to start an Xorg-based GNOME session instead. This is not
> needed on a standard Ubuntu Desktop installation which
> leaves `/etc/X11/Xsession` in a compatible state.

**4. Enable and start xrdp:**

```bash
sudo systemctl enable --now xrdp
```

**5. Verify port 3389 is listening:**

```bash
ss -tlnp | grep 3389
```

### Configure port forwarding for RDP

On the **host machine**, add an RDP port forward to
`/etc/vmware/vmnet8/nat/nat.conf` under `[incomingtcp]`. Choose a host port
that does not conflict with any other VM (e.g. `3390`):

```
[incomingtcp]
# RDP forward: host port 3390 -> VM port 3389
3390 = 172.16.40.x:3389
```

Then restart VMware networking on the VMWare host:

```bash
sudo vmware-networks --stop && sudo vmware-networks --start
```

### Connect from your remote machine

In Remote Desktop on a Windows PC, or in the Windows App on a Mac, add a new PC connection:

```
<host-ip>:3390
```

Authenticate with your regular Ubuntu username and password.

> **Important:** Do not have both the VMware console and an xrdp session open
> simultaneously — this causes session conflicts that can crash or freeze the
> desktop. Always disconnect one before connecting from the other.

> **Appearance note:** xrdp sessions use Xorg rather than Wayland, so the
> desktop will look slightly different from a native console session — the
> Ubuntu vertical dash sidebar and Yaru theme may not appear. This is a
> cosmetic difference only and does not affect functionality.

---

## Phase 4 — Install Rust

Rust is installed via `rustup`, the official Rust toolchain manager. This is
the recommended approach over `apt` as it provides the current stable release
and supports toolchain management.

All of these commands can be run via and SSH session on the VM:

**1. Install build dependencies** (required for compiling Rust programs):

```bash
sudo apt install -y build-essential
```

**2. Install Rust via rustup:**

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

When prompted, press `1` to proceed with the default installation.

**3. Load Rust into the current shell:** (optional, but recommended)

```bash
source "$HOME/.cargo/env"
```

Future shell sessions will pick this up automatically.

**4. Verify the installation:**

```bash
rustc --version
cargo --version
```

**5. Optionally install useful components:**

```bash
rustup component add clippy rustfmt
```

`clippy` is the Rust linter; `rustfmt` is the code formatter.

---

## Phase 5 — Install Google Chrome

Chrome must be installed as the `.deb` package from Google directly — it is
not available in Ubuntu's standard repositories. The `.deb` package also
configures Google's APT repository so Chrome receives automatic updates.


**1. Download the Chrome package:**

```bash
wget -P /tmp https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
```

**2. Install it:**

```bash
sudo apt install -y /tmp/google-chrome-stable_current_amd64.deb
```

**3. Verify:**

```bash
google-chrome --version
```

**4. Clean up:**

```bash
rm /tmp/google-chrome-stable_current_amd64.deb
```

---

## Phase 6 — Install Claude Code

Claude Code is installed via Anthropic's native installer.

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

**Add `~/.local/bin` to your PATH** if not already present. The native
installer places the `claude` binary there, which is not in the default
`$PATH` on Ubuntu Server:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

Future shell sessions will pick this up automatically.

**Verify the installation:**

```bash
claude --version
```

**Authenticate:**

Before launching Claude Code for the first time, it is worth knowing that
the first launch will prompt you for two things:

1. **Theme preference** — choose whichever you prefer.
2. **Directory trust** — Claude Code will ask "Do you trust the files in
   this folder?" This is a security feature that checks whether you trust any
   `CLAUDE.md` or configuration files in the directory, since a malicious
   project could use those to hijack Claude's behaviour. On a personal
   development VM, it is safe to answer yes.

For this reason, it is recommended to launch Claude Code from a specific
project directory rather than from `$HOME`, so that Claude's file access is
scoped to just that project. If you do launch from `$HOME` or want to
suppress the prompt for directories you always trust, you can add them to
`~/.claude/settings.json`:

```json
{
  "trustedDirectories": ["/home/your-username/projects"]
}
```

To authenticate, run:

```bash
claude
```

On first launch, Claude Code will print a URL. Copy it from the terminal and
open it in a browser on your host PC — authentication will complete there and the
VM terminal session will activate automatically.

> **Note:** Authentication requires a paid Claude plan (Pro, Max, Team, or
> Enterprise). The free tier does not support Claude Code.

### Disassociating from your account when tearing down the VM

When you are done with the VM, you can log out of Claude Code before destroying it if you so desire with:

```bash
claude auth logout
```

This removes the stored credentials from the VM. For belt-and-suspenders
coverage, you can also revoke the sessions for the
ClaudeCode CLI and for the Chrome extension from Anthropic's side via
**Settings → Account** on [claude.ai](https://claude.ai).

Similarly, for the Chrome extension, you may sign out via the extension panel or remove it
entirely via `chrome://extensions` before destroying the VM. 

Ultimately, if you are destroying the VM, there is no need to remove the credentials from the VM prior to destroying it.  Revoking them from the Antrhopic account is sufficient, and good hygene.
---

## Phase 7 — Install the Claude in Chrome Extension

The Claude in Chrome extension must be installed from the Chrome Web Store
**from within the RDP session** — it requires a running Chrome window with a
visible desktop, and cannot be installed headlessly.

**1. Connect to the VM via RDP**.

**2. Open Google Chrome** from the application menu.

**3. Navigate to the Claude extension in the Chrome Web Store:**

```
https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn
```

**4. Click "Add to Chrome"** and follow the prompts.

**5. Sign in** to the extension with your Claude account credentials when
prompted.

**6. Pin the extension** by clicking the puzzle-piece icon in the Chrome
toolbar, then clicking the pin icon next to "Claude".

> **Requirements:** Claude in Chrome extension version 1.0.36 or higher.
> Requires a paid Claude plan. Currently supported on Google Chrome and
> Microsoft Edge only — not Brave, Arc, or other Chromium-based browsers.
> WSL is also not supported.

---

## Phase 8 — Connect Claude Code to Chrome

With both Claude Code and the Chrome extension installed, connect them so
Claude Code can control the browser.

**1. Start Claude Code** in your project directory:

```bash
cd ~/your-project
claude --chrome
```

Or start Claude Code normally and run `/chrome` from within a session to
connect.

**2. Check the connection status:**

```bash
/chrome
```

This shows whether Chrome is connected and lets you manage permissions or
reconnect if the extension has gone idle.

**3. Make Chrome the default** so you don't need `--chrome` every session:

Run `/chrome` and select "Enabled by default".

### Using the build-test-debug loop

Once connected, Claude Code can interact with your running web application
directly. Example workflows:

```
# Verify a UI change
I just updated the login form validation. Open localhost:3000, try submitting 
with invalid data, and check if the error messages appear correctly.

# Debug a console error
Open the dashboard page and check the console for any errors when the page loads.

# Design verification
Take a screenshot of the current state of localhost:3000 and compare it to 
the design spec in design.png.
```

Claude opens new tabs, shares your browser's existing login state, and pauses
to ask you to handle CAPTCHAs or login pages manually.

> **Note:** The Chrome extension's service worker can go idle during extended
> sessions. If browser tools stop working after a period of inactivity, run
> `/chrome` and select "Reconnect extension".

---

## Maintenance

**Update Claude Code** (auto-updates in the background, but to trigger
manually):

```bash
claude update
```

**Update Rust:**

```bash
rustup update
```

**Update Chrome** (updates with regular system package updates):

```bash
sudo apt update && sudo apt upgrade -y
```

---

## Troubleshooting

**xrdp connects but shows a black screen or fails to load the desktop:**
Ensure the `~/.xsession` file exists and is executable. Check xrdp logs:

```bash
sudo journalctl -u xrdp.service -n 50
cat /var/log/xrdp-sesman.log
```

**Claude Code authentication URL doesn't open automatically:**
Copy the URL from the terminal output and paste it into a browser on your Mac.
Authentication completes in the browser and the VM terminal session will
activate automatically.

**Chrome extension loses connection to Claude Code:**
Run `/chrome` from within a Claude Code session and select "Reconnect
extension". If the issue persists, restart Claude Code.

**`rustc` not found after installation:**
Run `source "$HOME/.cargo/env"` or open a new terminal session.

---

## License

This document is licensed under the [Creative Commons Attribution 4.0
International License (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).

Copyright © 2026 Patrick Doyle, developed with Claude (Anthropic).

You are free to share and adapt this material for any purpose, provided you
give appropriate credit, provide a link to the license, and indicate if changes
were made.
