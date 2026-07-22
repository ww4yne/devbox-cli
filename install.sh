#!/bin/sh
set -eu

say() {
  printf '\n==> %s\n' "$1"
}

prompt_required() {
  prompt_text=$1
  value=''
  while [ -z "$value" ]; do
    printf '%s: ' "$prompt_text" >/dev/tty
    IFS= read -r value </dev/tty
  done
  printf '%s' "$value"
}

prompt_default() {
  prompt_text=$1
  default_value=$2
  printf '%s [%s]: ' "$prompt_text" "$default_value" >/dev/tty
  IFS= read -r value </dev/tty
  if [ -z "$value" ]; then value=$default_value; fi
  printf '%s' "$value"
}

case "$(uname -s)" in
  Darwin) ;;
  *)
    echo "install.sh currently supports macOS clients only." >&2
    exit 1
    ;;
esac

if ! command -v devtunnel >/dev/null 2>&1; then
  say "Installing Microsoft Dev Tunnels CLI"
  if command -v brew >/dev/null 2>&1; then
    brew install --cask devtunnel
  else
    curl -fsSL https://aka.ms/DevTunnelCliInstall | bash
    PATH="$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    export PATH
  fi
fi

if ! command -v devtunnel >/dev/null 2>&1; then
  echo "devtunnel was installed but is not on PATH. Reopen the terminal." >&2
  exit 1
fi

login_json=$(devtunnel user show --json 2>/dev/null || true)
if ! printf '%s' "$login_json" |
  grep -Eq '"status"[[:space:]]*:[[:space:]]*"Logged in"'; then
  say "Sign in to Microsoft Dev Tunnels"
  echo "Complete the browser or device-code login opened by devtunnel."
  devtunnel user login </dev/tty
fi

say "Client configuration"
tunnel_id=$(prompt_required "Tunnel ID")
case "$tunnel_id" in
  *[!a-z0-9.-]*|'')
    echo "Tunnel ID must use lowercase letters, digits, dots, or hyphens." >&2
    exit 1
    ;;
esac

if ! devtunnel show "$tunnel_id" --json >/dev/null 2>&1; then
  say "Refreshing Dev Tunnels login"
  devtunnel user logout >/dev/null 2>&1 || true
  devtunnel user login </dev/tty
  if ! devtunnel show "$tunnel_id" --json >/dev/null 2>&1; then
    echo "Tunnel is missing or inaccessible: $tunnel_id" >&2
    exit 1
  fi
fi

ssh_user=$(prompt_required "Remote Windows SSH user")
session_name=$(prompt_default "Persistent psmux session" "work")
case "$session_name" in
  *[!A-Za-z0-9_.-]*|'')
    echo "Invalid session name." >&2
    exit 1
    ;;
esac

printf '%s' "SSH private key path (optional; Enter for password authentication): " >/dev/tty
IFS= read -r identity_file </dev/tty
case "$identity_file" in
  "~/"*) identity_file="$HOME/${identity_file#~/}" ;;
esac

config_dir="$HOME/.config/devbox-cli"
state_root="$HOME/.local/state/devbox-cli"
bin_dir="$HOME/.local/bin"
config_file="$config_dir/config"
wrapper="$bin_dir/devbox"

mkdir -p "$config_dir" "$state_root" "$bin_dir"
{
  printf '%s\n' "$tunnel_id"
  printf '%s\n' "$ssh_user"
  printf '%s\n' "$session_name"
  printf '%s\n' "$identity_file"
  command -v devtunnel
} >"$config_file"
chmod 600 "$config_file"

cat >"$wrapper" <<'DEVBOX_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

action="${1:-connect}"
if [[ $# -gt 0 ]]; then shift; fi

config_file="${DEVBOX_CONFIG:-$HOME/.config/devbox-cli/config}"
if [[ ! -f "$config_file" ]]; then
  echo "devbox: config not found: $config_file" >&2
  exit 1
fi

DEVBOX_TUNNEL_ID="$(sed -n '1p' "$config_file")"
DEVBOX_SSH_USER="$(sed -n '2p' "$config_file")"
DEVBOX_SESSION="$(sed -n '3p' "$config_file")"
DEVBOX_IDENTITY_FILE="$(sed -n '4p' "$config_file")"
DEVBOX_DEVTUNNEL="$(sed -n '5p' "$config_file")"

state="$HOME/.local/state/devbox-cli/$DEVBOX_TUNNEL_ID"
process_file="$state/devtunnel-process"
out_log="$state/devtunnel.log"
err_log="$state/devtunnel.err.log"
known_hosts="$state/known_hosts"
lock_dir="$state/lifecycle.lock"
host_key_alias="devbox-$DEVBOX_TUNNEL_ID"
mkdir -p "$state"
lock_held=0

process_start() {
  ps -p "$1" -o lstart= 2>/dev/null |
    sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//'
}

release_lock() {
  if (( lock_held )); then
    rm -rf "$lock_dir"
    lock_held=0
  fi
}

trap release_lock EXIT
trap 'release_lock; exit 129' HUP
trap 'release_lock; exit 130' INT
trap 'release_lock; exit 143' TERM

get_connector_pid() {
  [[ -f "$process_file" ]] || return 0
  local pid expected_start current_start current_command
  pid="$(sed -n '1p' "$process_file")"
  expected_start="$(sed -n '2p' "$process_file")"
  [[ -n "$pid" && -n "$expected_start" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  current_start="$(process_start "$pid")"
  [[ "$current_start" == "$expected_start" ]] || return 0
  current_command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$current_command" in
    "$DEVBOX_DEVTUNNEL connect $DEVBOX_TUNNEL_ID"*) printf '%s' "$pid" ;;
  esac
}

get_port() {
  # The tunnel forwards several host ports (22, 2222, 8787). Only the local
  # forward for host port 22 is the SSH endpoint, so pin to it explicitly;
  # a bare "last 127.0.0.1:<port>" match would grab the agent port (8787)
  # and SSH would connect to the wrong service.
  grep -Eho \
    'Forwarding from 127\.0\.0\.1:[0-9]+ to host port 22\b' \
    "$out_log" "$err_log" 2>/dev/null |
    tail -1 |
    sed -E 's/.*127\.0\.0\.1:([0-9]+) to host port 22.*/\1/'
}

port_ready() {
  local port="${1:-}"
  [[ -n "$port" ]] && nc -z 127.0.0.1 "$port" >/dev/null 2>&1
}

acquire_lock() {
  local attempts=0 owner_pid owner_start current_start
  until mkdir "$lock_dir" 2>/dev/null; do
    owner_pid="$(sed -n '1p' "$lock_dir/owner" 2>/dev/null || true)"
    owner_start="$(sed -n '2p' "$lock_dir/owner" 2>/dev/null || true)"
    current_start=''
    if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
      current_start="$(process_start "$owner_pid")"
    fi
    if [[ -z "$owner_pid" || -z "$owner_start" ||
          "$current_start" != "$owner_start" ]]; then
      rm -rf "$lock_dir"
      continue
    fi
    attempts=$((attempts + 1))
    if (( attempts >= 300 )); then
      echo "devbox: timed out waiting for another devbox process" >&2
      return 1
    fi
    sleep 0.1
  done
  printf '%s\n%s\n' "$$" "$(process_start "$$")" >"$lock_dir/owner"
  lock_held=1
}

with_lock() {
  acquire_lock
  set +e
  "$@"
  local status=$?
  set -e
  release_lock
  return "$status"
}

stop_tunnel_locked() {
  local pid attempt
  pid="$(get_connector_pid)"
  if [[ -n "$pid" ]]; then
    if kill "$pid" 2>/dev/null; then
      for attempt in {1..100}; do
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.1
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "devbox: connector process $pid did not stop within 10 seconds" >&2
        return 1
      fi
    fi
  fi
  rm -f "$process_file"
}

stop_tunnel() {
  with_lock stop_tunnel_locked
}

start_tunnel_locked() {
  local pid port deadline start_time
  pid="$(get_connector_pid)"
  port="$(get_port)"
  if [[ -n "$pid" ]] && port_ready "$port"; then
    return
  fi

  stop_tunnel_locked || return
  : >"$out_log"
  : >"$err_log"
  nohup "$DEVBOX_DEVTUNNEL" connect "$DEVBOX_TUNNEL_ID" \
    </dev/null >"$out_log" 2>"$err_log" &
  pid=$!

  start_time=''
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    start_time="$(process_start "$pid")"
    [[ -n "$start_time" ]] && break
    sleep 0.1
  done
  if [[ -n "$start_time" ]]; then
    printf '%s\n%s\n' "$pid" "$start_time" >"$process_file"
  fi

  deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    port="$(get_port)"
    if port_ready "$port"; then return; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.5
  done

  local host_connections
  host_connections="$(
    "$DEVBOX_DEVTUNNEL" show "$DEVBOX_TUNNEL_ID" --json 2>/dev/null |
      grep -Eo '"hostConnections"[[:space:]]*:[[:space:]]*[0-9]+' |
      grep -Eo '[0-9]+$' || true
  )"
  if [[ "$host_connections" == 0 ]]; then
    echo "devbox: Dev Tunnel host is offline (Host connections: 0)." >&2
    echo "Start or wake the remote machine and ensure its tunnel host is running." >&2
    echo "For a Windows 365 Cloud PC, open it in Windows App, wait for the desktop to load, then retry." >&2
    return 1
  fi

  tail -40 "$out_log" "$err_log" >&2 || true
  echo "devbox: tunnel did not become ready" >&2
  return 1
}

start_tunnel() {
  with_lock start_tunnel_locked
}

restart_tunnel_locked() {
  stop_tunnel_locked || return
  start_tunnel_locked
}

case "$action" in
  status)
    pid="$(get_connector_pid)"
    port="$(get_port)"
    if port_ready "$port"; then ready=yes; else ready=no; fi
    printf 'tunnel=%s pid=%s port=%s ready=%s\n' \
      "$DEVBOX_TUNNEL_ID" "${pid:-none}" "${port:-none}" "$ready"
    ;;
  stop)
    stop_tunnel
    ;;
  restart)
    with_lock restart_tunnel_locked
    ;;
  logs)
    touch "$out_log" "$err_log"
    tail -f "$out_log" "$err_log"
    ;;
  shell|connect)
    start_tunnel
    port="$(get_port)"
    options=(
      -p "$port"
      -l "$DEVBOX_SSH_USER"
      -o "HostKeyAlias=$host_key_alias"
      -o CheckHostIP=no
      -o "UserKnownHostsFile=$known_hosts"
      -o StrictHostKeyChecking=ask
      -o ServerAliveInterval=15
      -o ServerAliveCountMax=3
    )
    if [[ -n "$DEVBOX_IDENTITY_FILE" ]]; then
      options+=(-i "$DEVBOX_IDENTITY_FILE" -o IdentitiesOnly=yes)
    else
      options+=(
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password,keyboard-interactive
      )
    fi
    options+=(127.0.0.1)

    if [[ "$action" == shell ]]; then
      exec ssh "${options[@]}"
    elif [[ $# -gt 0 ]]; then
      exec ssh "${options[@]}" "$@"
    else
      exec ssh -tt "${options[@]}" \
        "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command \"\$shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }; psmux new-session -A -s $DEVBOX_SESSION -- \$shell\""
    fi
    ;;
  *)
    echo "usage: devbox [connect [command...]|shell|status|stop|restart|logs]" >&2
    exit 2
    ;;
esac
DEVBOX_WRAPPER
chmod +x "$wrapper"

shell_name=$(basename "${SHELL:-/bin/zsh}")
case "$shell_name" in
  zsh) profile="$HOME/.zshrc" ;;
  bash) profile="$HOME/.bashrc" ;;
  *) profile="$HOME/.profile" ;;
esac

marker='# devbox-cli PATH'
if ! grep -Fq "$marker" "$profile" 2>/dev/null; then
  {
    printf '\n%s\n' "$marker"
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
  } >>"$profile"
fi

PATH="$bin_dir:$PATH"
export PATH

printf '\nClient setup complete.\n'
printf 'Tunnel ID : %s\n' "$tunnel_id"
printf 'SSH user  : %s\n' "$ssh_user"
printf 'Session   : %s\n' "$session_name"
printf 'Run now   : %s\n' "$wrapper"
printf 'New shells can run: devbox\n'
