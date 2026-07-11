# devbox-cli

One command for a persistent Windows development session over Microsoft Dev
Tunnels, OpenSSH, and psmux.

```text
local terminal -> private Dev Tunnel -> Windows OpenSSH -> psmux session
```

The remote Windows machine only makes outbound connections. No public TCP 22
rule, router port-forward, public IP, or anonymous tunnel is required.

## Install

### Windows

Run in PowerShell:

```powershell
irm https://raw.githubusercontent.com/ww4yne/devbox-cli/main/install.ps1 | iex
```

Choose:

- **Server** on the remote Windows development machine.
- **Client** on a Windows machine used to reach it.

For explicit mode selection, download or invoke the script block:

```powershell
& ([scriptblock]::Create(
    (irm https://raw.githubusercontent.com/ww4yne/devbox-cli/main/install.ps1)
)) -Mode Server
```

```powershell
& ([scriptblock]::Create(
    (irm https://raw.githubusercontent.com/ww4yne/devbox-cli/main/install.ps1)
)) -Mode Client
```

### macOS client

```bash
curl -fsSL https://raw.githubusercontent.com/ww4yne/devbox-cli/main/install.sh | sh
```

The shell installer reads prompts from `/dev/tty`, so interactive Dev Tunnels
login and configuration work correctly when the script is piped to `sh`.

## What the installers do

### Server mode

1. Installs and enables Windows OpenSSH Server.
2. Installs [psmux](https://github.com/psmux/psmux).
3. Installs Microsoft Dev Tunnels CLI.
4. Prompts for Dev Tunnels login and a unique private tunnel ID.
5. Creates or reuses the tunnel and publishes local TCP 22.
6. Installs a single-instance, self-restarting tunnel host wrapper with a
   watchdog that recovers from silent "no-host" states (relay drops and Dev
   Tunnels access-token refresh failures).
7. Registers a per-user logon task.

The tunnel is private. The installer never uses `--allow-anonymous`.
OpenSSH is configured to listen only on `127.0.0.1` and `::1`; the Dev Tunnels
host reaches it locally, so broad firewall policies cannot expose SSH directly.

### Client mode

1. Installs Microsoft Dev Tunnels CLI.
2. Prompts for login, tunnel ID, Windows SSH user, psmux session, and optional
   SSH private-key path.
3. Installs the `devbox` command and a non-secret local configuration file.
4. Keeps one local tunnel connector running and verifies its forwarded port,
   rather than trusting a stale PID.
5. Uses a stable SSH `HostKeyAlias` and tunnel-specific `known_hosts`.

## Commands

```text
devbox                     Connect and attach/create the persistent session
devbox shell               Open a plain remote shell
devbox connect hostname    Run one remote command
devbox status              Show local tunnel health
devbox restart             Restart the local tunnel connector
devbox logs                Follow connector logs
devbox stop                Stop the local tunnel connector
```

## SSH authentication

Dev Tunnels authentication and SSH authentication are separate.

- Dev Tunnels controls access to the private relay.
- OpenSSH authenticates the Windows account and verifies the host.

Leaving the private-key path empty explicitly uses password/keyboard-interactive
authentication and disables automatic public-key discovery. Providing a private
key enables key-only authentication (`IdentitiesOnly=yes`). Configure the
matching public key in the Windows account's `authorized_keys` before selecting
that mode.

The first SSH connection asks the user to verify the host-key fingerprint.

## Important behavior

- The server task is triggered at Windows user logon and runs with that user's
  Dev Tunnels login. It does not store the Windows password.
- The host wrapper runs a watchdog: it polls `devtunnel show` and scans the
  host process output, and restarts the child within ~30–90 s if the tunnel
  stops hosting after a relay drop or an access-token refresh failure (the
  "child still running but no longer hosting" state). The client waits up to
  ~180 s for a healthy forwarded port, so brief relay flaps and host restarts
  are transparent to `devbox`.
- After a full reboot, the tunnel becomes available once that user logs in.
- psmux preserves the remote process across SSH, terminal, and network
  disconnects. It does not preserve processes across a Windows reboot.
- New psmux sessions prefer PowerShell 7 (`pwsh.exe`) and fall back to the
  built-in Windows PowerShell 5 (`powershell.exe`) when PS7 is unavailable.
- Tunnel IDs are independent of the local `devbox` command name.

## Safer installation

`irm | iex` and `curl | sh` are convenient but execute the current `main`
branch. Review or download the scripts first when change control matters:

```powershell
irm https://raw.githubusercontent.com/ww4yne/devbox-cli/main/install.ps1 `
    -OutFile install.ps1
Get-FileHash .\install.ps1 -Algorithm SHA256
notepad .\install.ps1
.\install.ps1
```

```bash
curl -fLo install.sh \
  https://raw.githubusercontent.com/ww4yne/devbox-cli/main/install.sh
shasum -a 256 install.sh
less install.sh
sh install.sh
```

For reproducible automation, use a tagged release URL or pin a commit instead
of executing `main`.

## Requirements

- Server: Windows 10/11, Windows Server, Windows 365, or Microsoft Dev Box.
- Windows installer: PowerShell 5.1+ and winget.
- macOS installer: POSIX `sh`; Homebrew is preferred but not mandatory.
- Host and client must authenticate to the same private tunnel or have explicit
  access.

Official Dev Tunnels documentation:
<https://learn.microsoft.com/azure/developer/dev-tunnels/get-started>

## License

MIT
