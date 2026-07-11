# Availability and recovery

## Assessment

`devbox-cli` is suitable for a persistent personal development session that
must recover from common relay and process failures. It is not a redundant
high-availability system: there is one Windows host, one Dev Tunnel, one host
process, and one authenticated user context.

The design favors recoverability:

- psmux keeps the development session alive across SSH and network
  disconnects.
- The server watchdog restarts a failed or stale `devtunnel host` process.
- The client validates its saved process identity and local forwarded port,
  then replaces a dead connector on the next invocation.
- Task Scheduler restarts a crashed server wrapper.

It does not provide seamless connection failover. An active terminal may
disconnect and must run `devbox` again to reattach.

## Recovery behavior

| Failure | Detection and recovery | Remaining impact |
| --- | --- | --- |
| `devtunnel host` exits | Server wrapper restarts it with 2-60 second exponential backoff. | Active SSH connections disconnect. |
| Host process remains alive but reports zero host connections | Two 30-second watchdog polls trigger a restart. | Typical detection is about 30-60 seconds. |
| Tunnel status queries repeatedly fail | Three 30-second watchdog polls trigger a restart. | A persistent network, service, or identity failure remains unavailable. |
| Known token/auth failure appears in host output | Watchdog immediately restarts the child. | Restart only helps when the cached login can refresh; interactive login may still be required. |
| Server wrapper exits | Task Scheduler retries after one minute. | Recovery requires the Windows user still to have a usable interactive logon context. |
| Client connector is dead or stale | The next `devbox` invocation checks PID, process start time, executable, and local TCP port before replacing it. | The current terminal does not reconnect automatically. |
| Windows restarts or the user logs off | OpenSSH starts as a Windows service; the Dev Tunnel task starts at the next user logon. | No remote access exists before that user logs in. psmux processes do not survive reboot. |
| Windows sleeps, hibernates, or is deallocated | Recovery starts after the machine resumes and outbound networking returns. | No redundant host takes over. |
| Windows `sshd` stops after installation | No application-level watchdog currently restarts it. | Administrator action is required if Windows service recovery does not restore it. |

The watchdog parses the human-readable `devtunnel show` host-connection field.
A future CLI output or localization change can therefore require an update.

## Availability boundary

Remote access requires all of the following:

1. The Windows machine is running and has outbound Internet and DNS access.
2. The configured Windows user is logged in.
3. Windows OpenSSH Server is running and listening on loopback TCP 22.
4. The Dev Tunnels service and relay are available.
5. The user's cached Dev Tunnels identity remains valid or can refresh
   non-interactively.
6. The client can authenticate to both the private tunnel and Windows SSH.

There is no availability SLA, secondary tunnel, secondary relay provider,
automatic user-login mechanism, or replica of the psmux session.

## Recovery objectives

These are implementation timings, not guaranteed SLOs:

- Stale host detection: approximately 30-90 seconds.
- Child restart backoff: 2 seconds, doubling to a maximum of 60 seconds.
- Task Scheduler wrapper restart: approximately one minute.
- Client connection readiness timeout: 180 seconds.

Persistent identity failures, service outages, machine shutdown, and missing
interactive logon have no automatic recovery deadline.

## Operator checks

On the Windows server:

```powershell
Get-Service sshd
Get-NetTCPConnection -State Listen -LocalPort 22
Get-ScheduledTask -TaskName 'DevboxCliHost-*' |
    Select-Object TaskName, State
Get-Content "$HOME\.devbox-cli\server\*\host.log" -Tail 100
devtunnel user show
devtunnel list
```

TCP 22 must listen only on `127.0.0.1` and `::1`.

On a client:

```text
devbox status
devbox logs
devbox restart
```

If the server log shows a persistent identity failure, sign in interactively
on Windows and run:

```powershell
devtunnel user login
Get-ScheduledTask -TaskName 'DevboxCliHost-*' | Start-ScheduledTask
```

If `sshd` is stopped, an administrator must restore the service before the
tunnel can carry SSH:

```powershell
Start-Service sshd
```

Re-running the installer is a repair operation, not a failover mechanism.
Before reusing a tunnel, pass its full canonical ID, including the cluster
suffix.

## Review priorities

The largest remaining availability gaps are:

1. The server task depends on interactive user logon.
2. Persistent Dev Tunnels authentication failure needs user intervention.
3. Runtime health checks do not verify `sshd` or perform an end-to-end SSH
   probe.
4. Client connections do not automatically reconnect.
5. The access path and psmux host are not replicated.

Address these only when the operational requirement justifies the additional
privileges and complexity. For personal development, fast reattachment is
usually safer and simpler than pretending to provide seamless failover.
