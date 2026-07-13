[CmdletBinding()]
param(
    [ValidateSet('Server', 'Client')]
    [string]$Mode,
    [string]$TunnelId,
    [string]$SshUser,
    [string]$SessionName = 'work',
    [string]$IdentityFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# PowerShell 7.4+ turns any native-command non-zero exit into a terminating
# error when ErrorActionPreference is Stop. This installer checks
# $LASTEXITCODE explicitly (e.g. "does this tunnel already exist?"), so opt
# out of that behavior to keep those idempotent checks working.
$PSNativeCommandUseErrorActionPreference = $false

if ($env:OS -ne 'Windows_NT') {
    throw 'install.ps1 supports Windows only. On macOS, use install.sh.'
}

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Read-Required([string]$Prompt, [string]$Default = '') {
    while ($true) {
        $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $value = Read-Host $label
        if (-not $value) { $value = $Default }
        if ($value) { return $value.Trim() }
    }
}

function Select-Mode {
    while ($true) {
        $answer = (Read-Host 'Install mode: [S]erver or [C]lient').Trim()
        switch -Regex ($answer) {
            '^(s|server)$' { return 'Server' }
            '^(c|client)$' { return 'Client' }
        }
        Write-Warning 'Enter Server or Client.'
    }
}

function Assert-TunnelId([string]$Value) {
    if ($Value -notmatch '^[a-z0-9][a-z0-9.-]+$') {
        throw 'Tunnel ID must use lowercase letters, digits, dots, or hyphens.'
    }
}

function Assert-SessionName([string]$Value) {
    if ($Value -notmatch '^[A-Za-z0-9_.-]+$') {
        throw 'Session name may use letters, digits, dots, underscores, or hyphens.'
    }
}

function Install-WingetPackage(
    [string]$PackageId,
    [string]$CommandName
) {
    if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
        Write-Host "$CommandName is already installed."
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is required. Install or update App Installer first.'
    }

    Write-Step "Installing $PackageId"
    winget install --id $PackageId --exact `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $PackageId (exit $LASTEXITCODE)."
    }
}

function Resolve-Devtunnel {
    $command = Get-Command devtunnel -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $binary = Get-ChildItem $packages -Filter devtunnel.exe -Recurse `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($binary) { return $binary.FullName }

    throw 'devtunnel CLI was installed but could not be located.'
}

function Test-DevtunnelLogin([string]$Devtunnel) {
    $ErrorActionPreference = 'SilentlyContinue'
    $json = & $Devtunnel user show --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $false }
    try {
        return (($json | ConvertFrom-Json).status -eq 'Logged in')
    }
    catch {
        return $false
    }
}

function Ensure-DevtunnelLogin(
    [string]$Devtunnel,
    [switch]$Force
) {
    $ErrorActionPreference = 'SilentlyContinue'
    if (-not $Force -and (Test-DevtunnelLogin $Devtunnel)) {
        Write-Host 'Dev Tunnels login is already active.'
        return
    }

    if ($Force) {
        & $Devtunnel user logout *> $null
    }
    Write-Step 'Sign in to Microsoft Dev Tunnels'
    Write-Host 'Complete the browser or device-code login opened by devtunnel.'
    & $Devtunnel user login
    if ($LASTEXITCODE -ne 0) {
        throw "Dev Tunnels login failed (exit $LASTEXITCODE)."
    }
}

function Invoke-AsAdministrator([string]$Script) {
    $bytes = [Text.Encoding]::Unicode.GetBytes($Script)
    $encoded = [Convert]::ToBase64String($bytes)
    $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-EncodedCommand',
            $encoded
        )
    if ($process.ExitCode -ne 0) {
        throw "Elevated configuration failed (exit $($process.ExitCode))."
    }
}

function Install-OpenSshServer {
    Write-Step 'Installing and enabling OpenSSH Server'
    Invoke-AsAdministrator @'
$ErrorActionPreference = 'Stop'
$capability = Get-WindowsCapability -Online |
    Where-Object Name -Like 'OpenSSH.Server*' |
    Select-Object -First 1
if (-not $capability) { throw 'OpenSSH.Server capability is unavailable.' }
if ($capability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}
$configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
$config = Get-Content $configPath
$activeListeners = @(
    $config |
        Where-Object { $_ -match '^\s*ListenAddress\s+(\S+)' } |
        ForEach-Object { $Matches[1] }
)
$unsafeListeners = @(
    $activeListeners |
        Where-Object { $_ -notin @('127.0.0.1', '::1') }
)
if ($unsafeListeners) {
    throw (
        'sshd_config already contains non-loopback ListenAddress values: ' +
        ($unsafeListeners -join ', ')
    )
}
if ($config -notcontains '# devbox-cli: loopback-only SSH') {
    Add-Content $configPath (
        "`r`n# devbox-cli: loopback-only SSH`r`n" +
        "ListenAddress 127.0.0.1`r`n" +
        "ListenAddress ::1`r`n"
    )
}
Set-Service sshd -StartupType Automatic
Restart-Service sshd -ErrorAction SilentlyContinue
if ((Get-Service sshd).Status -ne 'Running') {
    Start-Service sshd
}
Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
    -ErrorAction SilentlyContinue
$listeners = @(
    Get-NetTCPConnection -State Listen -LocalPort 22 `
        -ErrorAction SilentlyContinue
)
if (-not $listeners) {
    throw 'sshd is not listening on TCP 22.'
}
$nonLoopback = @(
    $listeners |
        Where-Object LocalAddress -NotIn @('127.0.0.1', '::1')
)
if ($nonLoopback) {
    throw 'sshd is listening beyond loopback; refusing unsafe configuration.'
}
'@
}

function Test-CloudPcHost {
    # Detects a Windows 365 Cloud PC via Azure IMDS. On a non-CPC Windows
    # box, 169.254.169.254 is unreachable and this returns $false quickly.
    try {
        $imds = Invoke-RestMethod `
            -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' `
            -Headers @{ Metadata = 'true' } -TimeoutSec 3 -ErrorAction Stop
        return ($imds.compute.name -like 'CPC_*')
    } catch {
        return $false
    }
}

function Set-CloudPcAlwaysAwake {
    # Windows 365 Cloud PCs opt into Cost-Saving Hibernation: the CPC
    # service (RdAgent / AgentMainService) can call
    # SetSuspendState(Hibernate) on the guest when Windows App has been
    # disconnected for a while (observed cadence on Enterprise CPCs:
    # nightly ~22:00 plus ~60 min after each RDP disconnect). While the
    # guest is hibernated, `devtunnel host` and every other outbound
    # connection is frozen; unattended tunnel access breaks until Windows
    # App reconnects and wakes the CPC.
    #
    # Disabling hibernation on the guest blocks that SetSuspendState call,
    # so devbox-cli's tunnel host stays reachable without an interactive
    # RDP session. The `requestsoverride` line additionally marks the
    # running devtunnel process as a system wake-lock, defending against
    # any idle-timer-based suspend that might exist alongside.
    Write-Step 'Cloud PC detected: disabling hibernation to keep the tunnel host reachable'
    Invoke-AsAdministrator @'
$ErrorActionPreference = 'Stop'
powercfg /hibernate off | Out-Null
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change standby-timeout-dc 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-dc 0 | Out-Null
powercfg /requestsoverride PROCESS devtunnel.exe SYSTEM | Out-Null
$hibernate = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' `
    -ErrorAction Stop
if ($hibernate.HibernateEnabled -ne 0) {
    throw 'Failed to disable hibernation.'
}
'@
}

function Install-ServerHostScript([string]$SelectedTunnelId) {
    $serverDir = Join-Path $HOME '.devbox-cli\server'
    $hostScript = Join-Path $serverDir 'host.ps1'
    New-Item -ItemType Directory -Path $serverDir -Force | Out-Null

    $content = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TunnelId
)

$ErrorActionPreference = 'Continue'
$stateDir = Join-Path $HOME ".devbox-cli\server\$TunnelId"
$logFile = Join-Path $stateDir 'host.log'
$maxLogBytes = 10MB
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

# Watchdog tuning. The child `devtunnel host` can enter a "silent no-host"
# state after a relay drop or an access-token refresh failure: the process
# keeps running but stops hosting. The watchdog restarts the child on:
#   - host connections 0 for 2 consecutive polls (~60s);
#   - `devtunnel show` failing for 3 consecutive polls (~90s auth/net outage);
#   - an auth/token failure printed by the child (immediate).
$WatchdogIntervalSec  = 30
$WatchdogMaxZeroPolls = 2
$WatchdogMaxNullPolls = 3
$AuthFailurePattern =
    '(?i)(access token is not valid|Refreshing tunnel access token failed|' +
    'Error connecting host tunnel session|response status code:\s*Unauthorized)'

function Resolve-Devtunnel {
    $command = Get-Command devtunnel -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $binary = Get-ChildItem $packages -Filter devtunnel.exe -Recurse `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($binary) { return $binary.FullName }
    throw 'devtunnel CLI not found.'
}

function Rotate-Log {
    if ((Test-Path $logFile) -and
        (Get-Item $logFile).Length -ge $maxLogBytes) {
        Remove-Item "$logFile.1" -Force -ErrorAction SilentlyContinue
        Move-Item $logFile "$logFile.1" -Force
    }
}

function Write-HostLog([string]$msg) {
    Add-Content -LiteralPath $logFile `
        -Value ('[{0:u}] {1}' -f (Get-Date), $msg) -Encoding utf8
}

function Drain-Sidecar([string]$path, [ref]$posRef) {
    # Appends new child output to the log; returns the new chunk (or '').
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $stream.Length
            if ($len -gt $posRef.Value) {
                $stream.Seek($posRef.Value, 'Begin') | Out-Null
                $reader = New-Object System.IO.StreamReader($stream)
                $chunk = $reader.ReadToEnd()
                if ($chunk.Length -gt 0) {
                    Add-Content -LiteralPath $logFile `
                        -Value $chunk.TrimEnd("`r", "`n") -Encoding utf8
                }
                $posRef.Value = $len
                return $chunk
            }
        } finally { $stream.Close() }
    } catch {
        Write-HostLog "drain-sidecar error on ${path}: $($_.Exception.Message)"
    }
    return ''
}

function Get-HostConnectionCount([string]$exe, [string]$tunnel) {
    # Int32 host connection count, or $null if the query failed.
    try {
        $out = & $exe show $tunnel 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        foreach ($line in $out) {
            if ($line -match '^\s*Host connections\s*:\s*(\d+)') {
                return [int]$matches[1]
            }
        }
        return $null
    } catch { return $null }
}

function Stop-Child($proc) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop }
    catch { Write-HostLog "watchdog: kill failed: $($_.Exception.Message)" }
}

$safeId = $TunnelId -replace '[^A-Za-z0-9_.-]', '_'
$createdNew = $false
$mutex = [Threading.Mutex]::new(
    $true,
    "Local\DevboxCliHost-$safeId",
    [ref]$createdNew
)
if (-not $createdNew) { exit 0 }

$devtunnel = Resolve-Devtunnel
$sidecarOut = Join-Path $stateDir 'child.out.log'
$sidecarErr = Join-Path $stateDir 'child.err.log'
$backoffSec = 2
$backoffMax = 60

try {
    Rotate-Log
    Write-HostLog "wrapper start (pid=$PID, tunnel=$TunnelId)"
    while ($true) {
        Rotate-Log
        $startedAt = Get-Date
        Set-Content -LiteralPath $sidecarOut -Value '' -Encoding utf8 -NoNewline
        Set-Content -LiteralPath $sidecarErr -Value '' -Encoding utf8 -NoNewline
        $outPos = 0L
        $errPos = 0L

        Write-HostLog "starting: devtunnel host $TunnelId"
        $proc = Start-Process -FilePath $devtunnel `
            -ArgumentList @('host', $TunnelId) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $sidecarOut `
            -RedirectStandardError  $sidecarErr

        $zeroPolls = 0
        $nullPolls = 0
        $watchdogKill = $false

        while (-not $proc.HasExited) {
            Start-Sleep -Seconds $WatchdogIntervalSec
            $chunk = (Drain-Sidecar $sidecarOut ([ref]$outPos)) +
                     (Drain-Sidecar $sidecarErr ([ref]$errPos))
            if ($proc.HasExited) { break }

            if ($chunk -match $AuthFailurePattern) {
                Write-HostLog "watchdog: auth/token failure in host output, restarting child pid=$($proc.Id)"
                Stop-Child $proc
                $watchdogKill = $true
                break
            }

            $count = Get-HostConnectionCount $devtunnel $TunnelId
            if ($null -eq $count) {
                $nullPolls++
                Write-HostLog "watchdog: status query failed (null poll $nullPolls/$WatchdogMaxNullPolls)"
                if ($nullPolls -ge $WatchdogMaxNullPolls) {
                    Write-HostLog "watchdog: persistent query failure, killing child pid=$($proc.Id)"
                    Stop-Child $proc
                    $watchdogKill = $true
                    break
                }
                continue
            }
            $nullPolls = 0

            if ($count -ge 1) {
                if ($zeroPolls -gt 0) {
                    Write-HostLog "watchdog: host healthy (connections=$count)"
                }
                $zeroPolls = 0
            } else {
                $zeroPolls++
                Write-HostLog "watchdog: host connections=0 (poll $zeroPolls/$WatchdogMaxZeroPolls)"
                if ($zeroPolls -ge $WatchdogMaxZeroPolls) {
                    Write-HostLog "watchdog: stale host, killing child pid=$($proc.Id)"
                    Stop-Child $proc
                    $watchdogKill = $true
                    break
                }
            }
        }

        if (-not $proc.HasExited) { $proc.WaitForExit(5000) | Out-Null }
        Drain-Sidecar $sidecarOut ([ref]$outPos) | Out-Null
        Drain-Sidecar $sidecarErr ([ref]$errPos) | Out-Null

        $ranSec = [int]((Get-Date) - $startedAt).TotalSeconds
        $reason = if ($watchdogKill) { 'watchdog-killed' } else { 'exited' }
        Write-HostLog "$reason after ${ranSec}s"

        if ($ranSec -ge 60) { $backoffSec = 2 }
        Write-HostLog "sleeping ${backoffSec}s before restart"
        Start-Sleep -Seconds $backoffSec
        if ($backoffSec -lt $backoffMax) {
            $backoffSec = [Math]::Min($backoffMax, $backoffSec * 2)
        }
    }
}
finally {
    Write-HostLog "wrapper exit (pid=$PID)"
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
'@
    Set-Content -Path $hostScript -Value $content -Encoding UTF8

    $taskName = "DevboxCliHost-$SelectedTunnelId"
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powerShell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $powerShell) {
        $powerShell = (Get-Command powershell.exe).Source
    }

    # Interactive logon tasks can still flash or retain a console window even
    # when PowerShell receives -WindowStyle Hidden. Launch through WScript with
    # window style 0 instead; waitOnReturn keeps Task Scheduler supervision.
    $launcherScript = Join-Path $serverDir 'host-hidden.vbs'
    $hostCommand = (
        '"{0}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
        '-File "{1}" -TunnelId "{2}"'
    ) -f $powerShell, $hostScript, $SelectedTunnelId
    $escapedHostCommand = $hostCommand.Replace('"', '""')
    @"
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("$escapedHostCommand", 0, True)
WScript.Quit exitCode
"@ | Set-Content -Path $launcherScript -Encoding ASCII

    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $action = New-ScheduledTaskAction -Execute $wscript -Argument (
        '//B //NoLogo "{0}"' -f $launcherScript
    )
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser `
        -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Hosts private SSH access through Microsoft Dev Tunnels.' `
        -Force | Out-Null

    Start-ScheduledTask -TaskName $taskName
    return $taskName
}

function Get-CanonicalTunnelId([string[]]$ShowOutput) {
    foreach ($line in $ShowOutput) {
        if ($line -match '^\s*Tunnel ID\s*:\s*(\S+)\s*$') {
            return $matches[1]
        }
    }
    throw 'Could not read the canonical tunnel ID from devtunnel show.'
}

function Ensure-Tunnel(
    [string]$Devtunnel,
    [string]$SelectedTunnelId
) {
    $ErrorActionPreference = 'SilentlyContinue'
    $showOutput = @()

    if ($SelectedTunnelId) {
        $showOutput = @(& $Devtunnel show $SelectedTunnelId 2>$null)
    }

    if (-not $SelectedTunnelId -or $LASTEXITCODE -ne 0) {
        $label = if ($SelectedTunnelId) { $SelectedTunnelId } else { 'a unique ID' }
        Write-Step "Creating private tunnel with $label"
        $createArguments = @('create')
        if ($SelectedTunnelId) { $createArguments += $SelectedTunnelId }
        $createArguments += @(
            '--description',
            'Persistent SSH development access'
        )
        $createOutput = @(& $Devtunnel @createArguments 2>&1)
        if ($createOutput) { Write-Host ($createOutput -join [Environment]::NewLine) }
        if ($LASTEXITCODE -ne 0) {
            throw (
                "Could not show or create tunnel '$SelectedTunnelId'. " +
                'Verify Dev Tunnels login. To reuse a tunnel, pass the full ' +
                'ID shown by `devtunnel list` (including its cluster suffix).'
            )
        }

        # `create` makes the new tunnel the CLI default. Querying without an ID
        # obtains the service-assigned cluster suffix without guessing it.
        $showOutput = @(& $Devtunnel show 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw 'Tunnel was created but its canonical ID could not be read.'
        }
    }

    $canonicalId = Get-CanonicalTunnelId $showOutput
    Write-Host "Tunnel ID: $canonicalId"

    $accessJson = & $Devtunnel access list $canonicalId --json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect access controls for $canonicalId."
    }
    $accessEntries = @(($accessJson | ConvertFrom-Json).accessControlEntries)
    if ($accessEntries.Count -gt 0) {
        throw (
            "Tunnel $canonicalId has custom access controls. " +
            'Use a fresh private tunnel ID or review/reset its ACL manually.'
        )
    }

    $json = & $Devtunnel port list $canonicalId --json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list ports for tunnel $canonicalId."
    }
    $ports = ($json | ConvertFrom-Json).ports
    if (-not ($ports | Where-Object portNumber -eq 22)) {
        Write-Step 'Publishing the OpenSSH port'
        & $Devtunnel port create $canonicalId `
            --port-number 22 --protocol auto --description OpenSSH
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to publish SSH port 22.'
        }

        $json = & $Devtunnel port list $canonicalId --json
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to verify ports for tunnel $canonicalId."
        }
        $portsAfterCreate = ($json | ConvertFrom-Json).ports
        if (-not ($portsAfterCreate | Where-Object portNumber -eq 22)) {
            throw "Tunnel $canonicalId does not list port 22 after creation."
        }
    }

    $portAccessJson = & $Devtunnel access list $canonicalId `
        --port-number 22 --json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect port-level access controls for $canonicalId."
    }
    $portAccessEntries = @(
        ($portAccessJson | ConvertFrom-Json).accessControlEntries
    )
    if ($portAccessEntries.Count -gt 0) {
        throw (
            "Tunnel port 22 on $canonicalId has custom access controls. " +
            'Use a fresh private tunnel ID or review/reset its ACL manually.'
        )
    }

    return $canonicalId
}

function Wait-TunnelHost([string]$Devtunnel, [string]$TunnelId) {
    $ErrorActionPreference = 'SilentlyContinue'
    Write-Step 'Waiting for the tunnel host connection'
    $deadline = (Get-Date).AddSeconds(120)

    do {
        Start-Sleep -Seconds 3
        $showOutput = @(& $Devtunnel show $TunnelId 2>$null)
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $showOutput) {
                if ($line -match '^\s*Host connections\s*:\s*(\d+)\s*$') {
                    if ([int]$matches[1] -ge 1) {
                        Write-Host 'Tunnel host connection is ready.'
                        return
                    }
                }
            }
        }
    } while ((Get-Date) -lt $deadline)

    $log = Join-Path $HOME ".devbox-cli\server\$TunnelId\host.log"
    if (Test-Path $log) {
        Write-Host 'Last host log lines:' -ForegroundColor Yellow
        Get-Content $log -Tail 30
    }
    throw "Tunnel $TunnelId did not establish a host connection within 120 seconds."
}

function Install-Server([string]$SelectedTunnelId) {
    Install-OpenSshServer
    if (Test-CloudPcHost) { Set-CloudPcAlwaysAwake }
    Install-WingetPackage -PackageId marlocarlo.psmux -CommandName psmux
    Install-WingetPackage -PackageId Microsoft.devtunnel -CommandName devtunnel

    $devtunnel = Resolve-Devtunnel
    Ensure-DevtunnelLogin $devtunnel

    if ($SelectedTunnelId) { Assert-TunnelId $SelectedTunnelId }
    $SelectedTunnelId = Ensure-Tunnel $devtunnel $SelectedTunnelId
    $taskName = Install-ServerHostScript $SelectedTunnelId
    Wait-TunnelHost $devtunnel $SelectedTunnelId

    $remoteUser = (& whoami).Trim()
    Write-Host "`nServer setup complete." -ForegroundColor Green
    Write-Host "Tunnel ID : $SelectedTunnelId"
    Write-Host "SSH user  : $remoteUser"
    Write-Host "Task      : $taskName"
    Write-Host 'No public TCP 22 rule or anonymous tunnel access was created.'
    Write-Host 'Install a client next, then verify SSH authentication.'
}

function Install-ClientWrapper(
    [string]$SelectedTunnelId,
    [string]$SelectedSshUser,
    [string]$SelectedSessionName,
    [string]$SelectedIdentityFile
) {
    $clientDir = Join-Path $HOME '.devbox-cli\client'
    $binDir = Join-Path $HOME 'bin'
    $configFile = Join-Path $clientDir 'config.json'
    $scriptFile = Join-Path $binDir 'devbox.ps1'
    $shimFile = Join-Path $binDir 'devbox.cmd'

    New-Item -ItemType Directory -Path $clientDir, $binDir -Force | Out-Null

    [ordered]@{
        TunnelId = $SelectedTunnelId
        SshUser = $SelectedSshUser
        SessionName = $SelectedSessionName
        IdentityFile = $SelectedIdentityFile
        HostKeyAlias = "devbox-$SelectedTunnelId"
    } | ConvertTo-Json | Set-Content $configFile -Encoding UTF8

    $clientScript = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('connect', 'shell', 'status', 'stop', 'restart', 'logs')]
    [string]$Action = 'connect',
    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$RemoteCommand
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$configFile = Join-Path $HOME '.devbox-cli\client\config.json'
if (-not (Test-Path $configFile)) {
    throw "Client config not found: $configFile"
}
$config = Get-Content $configFile -Raw | ConvertFrom-Json

$stateDir = Join-Path $HOME ".devbox-cli\client\$($config.TunnelId)"
$processFile = Join-Path $stateDir 'devtunnel-process.json'
$outLog = Join-Path $stateDir 'devtunnel.log'
$errLog = Join-Path $stateDir 'devtunnel.err.log'
$knownHosts = Join-Path $stateDir 'known_hosts'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

function Resolve-Devtunnel {
    $command = Get-Command devtunnel -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $binary = Get-ChildItem $packages -Filter devtunnel.exe -Recurse `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($binary) { return $binary.FullName }
    throw 'devtunnel CLI not found.'
}

function Get-TunnelProcess {
    if (-not (Test-Path $processFile)) { return $null }
    try {
        $metadata = Get-Content $processFile -Raw | ConvertFrom-Json
        $process = Get-Process -Id ([int]$metadata.ProcessId) `
            -ErrorAction SilentlyContinue
        if (-not $process) { return $null }
        if ($process.Path -ne $metadata.ExecutablePath) { return $null }
        $expectedStartTicks = if ($metadata.StartTimeUtcTicks) {
            [long]$metadata.StartTimeUtcTicks
        }
        else {
            ([DateTimeOffset]$metadata.StartTimeUtc).UtcDateTime.Ticks
        }
        if ($process.StartTime.ToUniversalTime().Ticks -ne
            $expectedStartTicks) {
            return $null
        }
        return $process
    }
    catch {
        return $null
    }
}

function Get-TunnelPort {
    foreach ($file in @($outLog, $errLog)) {
        if (-not (Test-Path $file)) { continue }
        $match = Get-Content $file -Tail 100 |
            Select-String (
                '(?:listening on|Forwarding from)\s+127\.0\.0\.1:(\d+)'
            ) |
            Select-Object -Last 1
        if ($match) {
            return [int]$match.Matches[0].Groups[1].Value
        }
    }
    $process = Get-TunnelProcess
    if ($process) {
        $listener = Get-NetTCPConnection -State Listen `
            -OwningProcess $process.Id -ErrorAction SilentlyContinue |
            Where-Object LocalAddress -In @('127.0.0.1', '::1') |
            Select-Object -First 1
        if ($listener) { return [int]$listener.LocalPort }
    }
    return 0
}

function Test-TcpPort([int]$Port) {
    if (-not $Port) { return $false }
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $result = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        return $result.AsyncWaitHandle.WaitOne(300) -and $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Invoke-WithTunnelLock([scriptblock]$Operation) {
    $safeId = $config.TunnelId -replace '[^A-Za-z0-9_.-]', '_'
    $mutex = [Threading.Mutex]::new(
        $false,
        "Local\DevboxCliClient-$safeId"
    )
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(30))) {
        $mutex.Dispose()
        throw 'Timed out waiting for another devbox process.'
    }
    try {
        & $Operation
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Stop-TunnelUnsafe {
    $process = Get-TunnelProcess
    if ($process) {
        Stop-Process -Id $process.Id
    }
    Remove-Item $processFile -ErrorAction SilentlyContinue
}

function Stop-Tunnel {
    Invoke-WithTunnelLock { Stop-TunnelUnsafe }
}

function Start-Tunnel {
    Invoke-WithTunnelLock {
        $process = Get-TunnelProcess
        $port = Get-TunnelPort
        if ($process -and (Test-TcpPort $port)) {
            return
        }

        Stop-TunnelUnsafe
        Set-Content $outLog ''
        Set-Content $errLog ''
        $executable = Resolve-Devtunnel
        $process = Start-Process -FilePath $executable `
            -ArgumentList @('connect', $config.TunnelId) `
            -RedirectStandardOutput $outLog `
            -RedirectStandardError $errLog `
            -WindowStyle Hidden -PassThru
        $process.Refresh()
        [ordered]@{
            ProcessId = $process.Id
            ExecutablePath = $process.Path
            StartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            StartTimeUtcTicks = $process.StartTime.ToUniversalTime().Ticks
        } | ConvertTo-Json | Set-Content $processFile -Encoding UTF8

        $deadline = (Get-Date).AddSeconds(180)
        while ((Get-Date) -lt $deadline) {
            $port = Get-TunnelPort
            if (Test-TcpPort $port) { return }
            if ($process.HasExited) { break }
            Start-Sleep -Milliseconds 500
        }

        Get-Content $outLog, $errLog -Tail 40 -ErrorAction SilentlyContinue
        throw 'Dev Tunnel did not become ready.'
    }
}

function Get-SshArguments {
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]]@(
        '-p', "$(Get-TunnelPort)",
        '-l', "$($config.SshUser)",
        '-o', "HostKeyAlias=$($config.HostKeyAlias)",
        '-o', 'CheckHostIP=no',
        '-o', "UserKnownHostsFile=$knownHosts",
        '-o', 'StrictHostKeyChecking=ask',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=3'
    ))
    if ($config.IdentityFile) {
        $arguments.AddRange([string[]]@(
            '-i', "$($config.IdentityFile)",
            '-o', 'IdentitiesOnly=yes'
        ))
    }
    else {
        $arguments.AddRange([string[]]@(
            '-o', 'PubkeyAuthentication=no',
            '-o', 'PreferredAuthentications=password,keyboard-interactive'
        ))
    }
    $arguments.Add('127.0.0.1')
    return $arguments.ToArray()
}

switch ($Action) {
    'status' {
        $process = Get-TunnelProcess
        $port = Get-TunnelPort
        [pscustomobject]@{
            TunnelId = $config.TunnelId
            ProcessId = if ($process) { $process.Id } else { $null }
            Port = $port
            Ready = [bool]$process -and (Test-TcpPort $port)
        }
    }
    'stop' { Stop-Tunnel }
    'restart' { Stop-Tunnel; Start-Tunnel }
    'logs' {
        Get-Content $outLog, $errLog -Tail 100 -Wait `
            -ErrorAction SilentlyContinue
    }
    'shell' {
        Start-Tunnel
        $sshArgs = Get-SshArguments
        & ssh @sshArgs
        exit $LASTEXITCODE
    }
    'connect' {
        Start-Tunnel
        $sshArgs = Get-SshArguments
        if ($RemoteCommand) {
            & ssh @sshArgs @RemoteCommand
        }
        else {
            $remote = (
                'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ' +
                '-Command "$shell = if (Get-Command pwsh.exe ' +
                '-ErrorAction SilentlyContinue) { ''pwsh.exe'' } else { ' +
                '''powershell.exe'' }; psmux new-session -A -s ' +
                $config.SessionName + ' -- $shell"'
            )
            & ssh -tt @sshArgs $remote
        }
        exit $LASTEXITCODE
    }
}
'@
    Set-Content $scriptFile $clientScript -Encoding UTF8
    Set-Content $shimFile @'
@echo off
where pwsh >nul 2>nul
if errorlevel 1 goto windowsPowerShell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0devbox.ps1" %*
exit /b %ERRORLEVEL%
:windowsPowerShell
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0devbox.ps1" %*
exit /b %ERRORLEVEL%
'@ -Encoding ASCII

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathParts = @($userPath -split ';' | Where-Object { $_ })
    if ($binDir -notin $pathParts) {
        $newPath = (@($pathParts) + $binDir) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
    if ($env:Path -notlike "*$binDir*") {
        $env:Path = "$env:Path;$binDir"
    }
}

function Install-Client(
    [string]$SelectedTunnelId,
    [string]$SelectedSshUser,
    [string]$SelectedSessionName,
    [string]$SelectedIdentityFile,
    [bool]$SessionNameWasSpecified,
    [bool]$IdentityFileWasSpecified
) {
    Install-WingetPackage -PackageId Microsoft.devtunnel -CommandName devtunnel
    $devtunnel = Resolve-Devtunnel
    Ensure-DevtunnelLogin $devtunnel

    if (-not $SelectedTunnelId) {
        $SelectedTunnelId = Read-Required 'Tunnel ID'
    }
    Assert-TunnelId $SelectedTunnelId

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & $devtunnel show $SelectedTunnelId --json *> $null
        if ($LASTEXITCODE -ne 0) {
            Ensure-DevtunnelLogin $devtunnel -Force
            & $devtunnel show $SelectedTunnelId --json *> $null
            if ($LASTEXITCODE -ne 0) {
                throw "Tunnel is missing or inaccessible: $SelectedTunnelId"
            }
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }

    if (-not $SelectedSshUser) {
        $SelectedSshUser = Read-Required 'Remote Windows SSH user'
    }
    if (-not $SessionNameWasSpecified) {
        $SelectedSessionName = Read-Required 'Persistent psmux session' `
            $SelectedSessionName
    }
    Assert-SessionName $SelectedSessionName

    if (-not $IdentityFileWasSpecified) {
        $SelectedIdentityFile = Read-Host (
            'SSH private key path (optional; Enter for password authentication)'
        )
    }
    if ($SelectedIdentityFile) {
        $SelectedIdentityFile = $ExecutionContext.SessionState.Path.
            GetUnresolvedProviderPathFromPSPath($SelectedIdentityFile)
    }

    Install-ClientWrapper $SelectedTunnelId $SelectedSshUser `
        $SelectedSessionName $SelectedIdentityFile

    Write-Host "`nClient setup complete." -ForegroundColor Green
    Write-Host "Tunnel ID : $SelectedTunnelId"
    Write-Host "SSH user  : $SelectedSshUser"
    Write-Host "Session   : $SelectedSessionName"
    Write-Host 'Open a new terminal, then run: devbox'
}

if (-not $Mode) { $Mode = Select-Mode }
switch ($Mode) {
    'Server' { Install-Server -SelectedTunnelId $TunnelId }
    'Client' {
        Install-Client -SelectedTunnelId $TunnelId `
            -SelectedSshUser $SshUser `
            -SelectedSessionName $SessionName `
            -SelectedIdentityFile $IdentityFile `
            -SessionNameWasSpecified $PSBoundParameters.ContainsKey('SessionName') `
            -IdentityFileWasSpecified $PSBoundParameters.ContainsKey('IdentityFile')
    }
}
