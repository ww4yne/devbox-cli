# Reverse SSH through an operator-managed bastion

## Status and scope

This is an optional integration pattern, not a transport managed by the
`devbox-cli` installer. Use it when a client has native OpenSSH but cannot
install the Dev Tunnels CLI.

The Windows machine still accepts no direct inbound SSH. It creates an outbound
reverse tunnel to a bastion:

```text
OpenSSH-only client
  -> public SSH endpoint on bastion
  -> bastion loopback reverse port
  -> outbound reverse tunnel from Windows
  -> Windows OpenSSH on 127.0.0.1:22
  -> psmux session
```

The bastion is operator-owned infrastructure. An implementation agent must
verify its contract and stop with a clear error if the required privileges or
settings are unavailable. It must not silently weaken SSH, firewall, or host-key
policy.

## Required inputs

Collect these values before changing either machine:

| Input | Example placeholder | Purpose |
| --- | --- | --- |
| Bastion host | `bastion.example.com` | Public DNS name or stable address |
| Bastion SSH port | `22` or `443` | Client and Windows outbound endpoint |
| Bastion user | `devbox-tunnel` | Dedicated key-only SSH account |
| Reverse listen port | `22001` | Unique port for one Windows host |
| Windows SSH user | `DOMAIN\user` | Authentication on the final hop |
| psmux session | `work` | Persistent session name |
| Bastion host key | Verified fingerprint and key | Pinning for both peers |
| Windows-to-bastion key | Private key path on Windows | Reverse-tunnel authentication |
| Client-to-bastion key | Private key path on the client | Jump authentication |

Do not copy real private keys, passwords, access tokens, hostnames, or
fingerprints into this repository.

## Bastion contract

The bastion operator must provide:

1. A reachable raw TCP SSH endpoint. Port 443 is optional; it is not equivalent
   to an HTTP proxy.
2. Public-key authentication for a dedicated account. Password and
   keyboard-interactive authentication should be disabled.
3. TCP forwarding for the reverse listener and the client's jump connection.
4. `GatewayPorts no`, so the reverse listener remains loopback-only.
5. A unique, operator-approved reverse port for each Windows host.
6. A stable, independently verified SSH host key.
7. Service supervision, logging, patching, and a documented rollback owner.

A baseline `sshd_config` policy for a dedicated single account is:

```text
Match User devbox-tunnel
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding yes
    GatewayPorts no
    PermitListen 127.0.0.1:22001
    PermitOpen 127.0.0.1:22001
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
```

Directive support varies by OpenSSH version. Validate the configuration with
the platform's `sshd -t` mechanism before reloading. For stronger isolation,
use separate reverse-tunnel and client-jump accounts: allow only remote
forwarding plus `PermitListen` for the former, and only local forwarding plus
`PermitOpen` for the latter.

The reverse listener must not bind a public interface. Verify that the assigned
port is reachable from the bastion itself at `127.0.0.1`, but not from an
external machine.

## Windows host design

Reuse the normal server prerequisites:

- Windows OpenSSH Server listens only on `127.0.0.1:22` and `[::1]:22`.
- The inbound OpenSSH firewall rule remains disabled.
- psmux is installed.
- The built-in OpenSSH client is available.

Provision a dedicated private key readable only by the Windows user and a
dedicated `known_hosts` file containing the verified bastion key. The persistent
reverse command is:

```powershell
ssh.exe -N -T `
    -o BatchMode=yes `
    -o ExitOnForwardFailure=yes `
    -o ServerAliveInterval=15 `
    -o ServerAliveCountMax=3 `
    -o TCPKeepAlive=yes `
    -o StrictHostKeyChecking=yes `
    -o "UserKnownHostsFile=C:\path\to\bastion_known_hosts" `
    -o IdentitiesOnly=yes `
    -i C:\path\to\bastion_identity `
    -p 22 `
    -R 127.0.0.1:22001:127.0.0.1:22 `
    devbox-tunnel@bastion.example.com
```

Replace every placeholder; do not make the sample port or identity paths into
defaults.

Run the command under a per-user scheduled task with these properties:

- Trigger at user logon and start when available.
- No execution time limit.
- Ignore duplicate instances.
- Restart on failure.
- Hide the console window.
- Supervise `ssh.exe` in a loop with bounded exponential backoff.
- Log starts, exits, exit codes, and backoff without logging key material.

`ExitOnForwardFailure=yes` is mandatory: a port collision or forwarding-policy
failure must fail visibly instead of leaving a healthy-looking SSH process.
Keep strict host-key checking enabled and use key-only bastion authentication so
the task never waits for a prompt.

This extension can coexist with Dev Tunnels. It must not modify or disable the
existing Dev Tunnel task.

## Native OpenSSH client profile

The client needs no `devbox-cli` or Dev Tunnels installation. A minimal
`~/.ssh/config` profile is:

```sshconfig
Host devbox-bastion
    HostName bastion.example.com
    Port 22
    User devbox-tunnel
    IdentityFile ~/.ssh/devbox_bastion
    IdentitiesOnly yes
    UserKnownHostsFile ~/.ssh/devbox_bastion_known_hosts
    StrictHostKeyChecking yes
    ServerAliveInterval 15
    ServerAliveCountMax 3

Host devbox
    HostName 127.0.0.1
    Port 22001
    User DOMAIN\user
    ProxyJump devbox-bastion
    HostKeyAlias devbox-via-bastion
    CheckHostIP no
    UserKnownHostsFile ~/.ssh/devbox_windows_known_hosts
    StrictHostKeyChecking yes
    PubkeyAuthentication no
    PreferredAuthentications password,keyboard-interactive
    RequestTTY force
    RemoteCommand powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }; psmux new-session -A -s work -- $shell"
```

The bastion and Windows host use separate `known_hosts` files and identities.
`HostKeyAlias` keeps Windows host verification stable even though the endpoint
is bastion loopback. If Windows key authentication is deliberately configured,
replace the final-hop password settings with a dedicated identity and
`IdentitiesOnly yes`.

Remove `RequestTTY` and `RemoteCommand` when the profile should open a plain
Windows shell instead of attaching psmux.

## Optional SSH on TCP 443

Some restricted networks allow outbound TCP 443 but not the bastion's normal
SSH port. This is a bastion deployment concern, not a `devbox-cli` feature.

If TCP 443 already serves HTTPS, the operator may place a layer-4 protocol
multiplexer in front of SSH and TLS:

```text
public TCP 443
  -> protocol multiplexer
       SSH -> loopback SSH service
       TLS -> loopback HTTPS service
```

Requirements:

- Route by detected protocol, not client source IP; enterprise egress
  addresses can change.
- Preserve HTTPS certificates, SNI routing, and the existing HTTP application.
- Keep the original SSH endpoint available for rollback while deploying.
- Test SSH banner exchange and authenticated login, not only TCP connect.
- Test every existing HTTPS hostname after the change.
- Document that raw SSH on 443 does not bypass an explicit HTTP proxy.

Set the profile's `Port` to `443` only after the operator validates this path.

## Implementation sequence for an AI agent

1. Confirm the bastion owner, admin access, rollback method, supported OpenSSH
   directives, and assigned reverse port.
2. Verify Windows `sshd`, psmux, loopback-only listeners, and outbound
   connectivity to the bastion.
3. Create or provision dedicated keys and pin host keys through a trusted
   channel.
4. Configure and validate the bastion forwarding contract.
5. Run the reverse command interactively once and confirm
   `ExitOnForwardFailure` does not report an error.
6. Confirm the reverse port listens only on bastion loopback.
7. Install the supervised Windows scheduled task.
8. Generate the client profile without embedding private material.
9. Connect using only native OpenSSH and verify Windows authentication and
   psmux reattachment.
10. Kill the reverse `ssh.exe` process and verify task recovery.
11. Disconnect the client and verify the psmux workload survives.
12. Record machine reboot and user-logon behavior; do not claim access before
    interactive logon unless a different, explicitly approved service identity
    is used.

## Acceptance criteria

The extension is complete only when:

- Windows TCP 22 is not externally reachable.
- The bastion reverse port is loopback-only and uniquely assigned.
- Both SSH host keys are pinned.
- Bastion authentication is non-interactive and key-only.
- The Windows task recovers after `ssh.exe` exits.
- A stock OpenSSH client reaches and reattaches the expected psmux session.
- A dropped client connection does not terminate the psmux workload.
- Failure logs identify port collision, host-key, authentication, and network
  errors without exposing secrets.
- Removing the task and bastion authorization closes the extension path without
  affecting Dev Tunnels.

## Availability boundary

Reverse SSH adds a second independently operated access path only when it is
deployed alongside Dev Tunnels. By itself it is still a single path and depends
on the Windows user logon, the bastion, its SSH endpoint, outbound networking,
and two sets of SSH credentials.

The project makes no availability or security guarantee for an unmanaged
bastion. Treat its configuration as infrastructure with an explicit owner,
monitoring, patching, backup, and rollback plan.
