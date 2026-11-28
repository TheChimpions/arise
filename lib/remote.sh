#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
# (SSH_CMD and friends are set here and read by the scripts that source this)
#
# Shared remote-execution helpers: how these scripts reach a server and run
# things on it.
#
# Security model
#   - An admin user holds sudo (password required) and does all root work.
#   - The service user (sol) runs the validator and has no sudo.
#   - Scripts and the sudo password travel over SSH stdin only: never a file,
#     never an argument, so neither shows in a process list on the server.
#   - A remote script runs under `set -euo pipefail` unless the caller set
#     REMOTE_STRICT (ascend.sh and reawaken.sh do, and set error handling in
#     each script). Its exit status is that of the helper that ran it.
#
# The caller sets SSH_KEY, SSH_HOST, SOL_USER, ADMIN_USER and DRY_RUN, then
# calls remote_init. SUDO_PASS is filled in by whoever asks for it.
#
# Works with the stock macOS bash (3.2) — no bash 4+ features in this file.

SUDO_PASS="${SUDO_PASS:-}"
# How the admin user reaches root: "sudo-pass" or "sudo-nopass". Set by
# ask_sudo_pass, which looks at the host rather than assuming.
SUDO_MODE=""

# remote_init — build the SSH options and destinations from the caller's settings.
# Password and keyboard-interactive auth are refused client-side, so a failed
# key login can never fall back to typing a password into the wrong host.
remote_init() {
  local host_key_check="accept-new"
  if [[ -n "${HOST_KEY_FP:-}" ]]; then
    pin_host_key "$SSH_HOST" "$HOST_KEY_FP" || exit 1
    host_key_check="yes"
  fi
  SSH_OPTS=(
    -o "StrictHostKeyChecking=${host_key_check}"
    -o ConnectTimeout=10
    -o IdentitiesOnly=yes
    -o PasswordAuthentication=no
    -o KbdInteractiveAuthentication=no
    -i "$SSH_KEY"
  )
  SOL_HOST="${SOL_USER}@${SSH_HOST}"
  ADMIN_HOST="${ADMIN_USER}@${SSH_HOST}"
  # Copy-pasteable form of the connection these scripts make themselves.
  # IdentitiesOnly stops ssh offering every agent key and tripping MaxAuthTries.
  SSH_CMD="ssh -o IdentitiesOnly=yes -i ${SSH_KEY}"
  if [[ -n "${KNOWN_HOSTS_FILE:-}" ]]; then
    SSH_OPTS+=(-o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}")
  fi
}

# pin_host_key <host> <SHA256:fingerprint> — make sure the key this host is
# known by is the one with that fingerprint, before anything connects to it.
#
# Without this the first connection takes whatever key it is shown
# (accept-new), and arise.sh then sends the admin password and the validator
# keypairs over it. The fingerprint comes from somewhere the network path to
# the host cannot change: the provider's console, or the server's own
#   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
#
# A key already in known_hosts with that fingerprint is enough. Otherwise the
# host is asked for its keys, and the one that matches is added. The answer to
# that question is not trusted: a key is only added when it has the fingerprint.
# Returns 1, having connected to nothing else, when no key matches.
# KNOWN_HOSTS_FILE names a file other than ~/.ssh/known_hosts.
# Returns 0 if <host> already has a key in known_hosts
host_key_known() {
  local file="${KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}"
  [[ -f "$file" ]] && ssh-keygen -F "$1" -f "$file" >/dev/null 2>&1
}

RE_HOST_KEY_FP='^SHA256:[A-Za-z0-9+/]{43}$'
pin_host_key() {
  local host="$1" want="${2%=}" file="${KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}"
  local line fp seen=""
  if [[ ! "$want" =~ $RE_HOST_KEY_FP ]]; then
    log_error "--host-key-fingerprint must look like SHA256:<43 characters>, as 'ssh-keygen -lf' prints it: $2"
    return 1
  fi
  if [[ -f "$file" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
      [[ "$fp" == "$want" ]] && return 0
    done < <(ssh-keygen -F "$host" -f "$file" 2>/dev/null)
  fi
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
    [[ -z "$fp" ]] && continue
    if [[ "$fp" == "$want" ]]; then
      mkdir -p "$(dirname "$file")"
      printf '%s\n' "$line" >> "$file"
      log_info "Host key of ${host} matches ${want} — added to ${file}"
      return 0
    fi
    seen+="${seen:+, }${fp}"
  done < <(ssh-keyscan -T 10 "$host" 2>/dev/null)
  if [[ -z "$seen" ]]; then
    log_error "Could not read a host key from ${host} to compare with ${want} — not connecting"
  else
    log_error "${host} does not have the host key ${want} — not connecting."
    log_error "It offers: ${seen}"
    log_error "Either the fingerprint is another server's, or something sits between you and this one."
  fi
  return 1
}

# Emit shell assignments for the named local variables, safely quoted, so a
# remote script can use them without any local interpolation into its body.
emit_vars() {
  local name
  for name in "$@"; do
    printf '%s=%q\n' "$name" "${!name}"
  done
}

# Wrap a script (stdin) so that the remote bash parses all of it before running
# any of it, runs it with strict error handling, and gives it /dev/null as
# stdin. A script written before this helper existed can set REMOTE_STRICT to
# the error handling its remote scripts were written for (e.g. ":" when each
# one sets its own). Without this, a command inside the script that reads stdin (apt, ssh,
# mkfs ...) would swallow the rest of the script.
wrap_script() {
  printf '%s\n' "${REMOTE_STRICT:-set -euo pipefail}" '__arise_main() {'
  cat
  printf '\n%s\n' '}' '__arise_main </dev/null'
}

# root_exec <dest> <mode> <password> <remote-command>
# Runs a command as root on the server, passing local stdin through to it.
#   mode root        — dest is root, run directly
#   mode sudo-nopass — dest has passwordless sudo
#   mode sudo-pass   — dest needs a sudo password. The password travels as the
#                      first line of SSH stdin (never argv, never a temp file).
#                      sudo -k makes sudo ignore a cached login and read it.
#                      Only for a dest whose sudo does ask: with passwordless
#                      sudo nothing reads that line and the command would get
#                      the password as its first line of input. ask_sudo_pass
#                      picks the mode from what the host actually does.
root_exec() {
  local dest="$1" mode="$2" pass="$3" cmd="$4"
  case "$mode" in
    root)        ssh "${SSH_OPTS[@]}" "$dest" "$cmd" ;;
    sudo-nopass) ssh "${SSH_OPTS[@]}" "$dest" "sudo -n $cmd" ;;
    sudo-pass)   { printf '%s\n' "$pass"; cat; } | ssh "${SSH_OPTS[@]}" "$dest" "sudo -k -S -p '' $cmd" ;;
    *)           log_error "root_exec: unknown mode $mode"; return 1 ;;
  esac
}

# Returns 0 if <dest> has passwordless sudo
sudo_is_nopass() {
  ssh "${SSH_OPTS[@]}" "$1" "sudo -k -n true" </dev/null 2>/dev/null
}

# Returns 0 if <password> is accepted by sudo for <dest>
check_sudo() {
  local dest="$1" pass="$2"
  printf '%s\n' "$pass" | ssh "${SSH_OPTS[@]}" "$dest" "sudo -k -S -p '' true" 2>/dev/null
}

# Returns 0 if key-based SSH login works for <dest>
can_ssh() {
  ssh "${SSH_OPTS[@]}" "$1" true </dev/null 2>/dev/null
}

# Like can_ssh, but allows a few seconds for sshd to come back after a reload
wait_ssh() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if can_ssh "$1"; then return 0; fi
    sleep 2
  done
  return 1
}

# Run a script (stdin) as root on the server via the admin user.
# The exit status is the script's own exit status.
root_script() {
  if $DRY_RUN; then
    echo "[DRY RUN] root script via ${ADMIN_HOST}:"
    cat
    return
  fi
  wrap_script | admin_root_exec "bash -s"
}

# admin_root_exec <remote-command> — run a command as root through the admin
# user, passing local stdin through. Refuses to run before ask_sudo_pass has
# settled how sudo behaves on the host.
admin_root_exec() {
  if [[ -z "$SUDO_MODE" ]]; then
    log_error "admin_root_exec: ask_sudo_pass has not run"
    return 1
  fi
  root_exec "$ADMIN_HOST" "$SUDO_MODE" "$SUDO_PASS" "$1"
}

# Run a script (stdin) as the sol user on the server (no sudo)
sol_script() {
  if $DRY_RUN; then
    echo "[DRY RUN] sol script on ${SOL_HOST}:"
    cat
    return
  fi
  wrap_script | ssh "${SSH_OPTS[@]}" "$SOL_HOST" "bash -s"
}

# Run a single command as sol
remote() {
  if $DRY_RUN; then
    echo "[DRY RUN] ssh $SOL_HOST: $*"
  else
    ssh "${SSH_OPTS[@]}" "$SOL_HOST" "$@" </dev/null
  fi
}

# sol_write_file <remote-path> <mode> — write stdin to a file owned by sol,
# atomically. The file never exists with wider permissions than requested, so
# this is also how keypairs and binaries are uploaded.
sol_write_file() {
  local path="$1" mode="$2"
  ssh "${SSH_OPTS[@]}" "$SOL_HOST" "umask 077 && cat > '${path}.arise-tmp' && chmod ${mode} '${path}.arise-tmp' && mv '${path}.arise-tmp' '${path}'"
}

sha256_local() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Settles how the admin user reaches root, and sets SUDO_MODE and SUDO_PASS.
# A host whose admin has passwordless sudo is never asked for a password, and
# one handed in through the environment is dropped: nothing on the host would
# read it. Otherwise the password is asked for (or taken from the environment)
# and checked.
ask_sudo_pass() {
  [[ -n "$SUDO_MODE" ]] && return 0
  if sudo_is_nopass "$ADMIN_HOST"; then
    SUDO_MODE="sudo-nopass"
    SUDO_PASS=""
    log_info "${ADMIN_HOST} has passwordless sudo — no password needed"
    return 0
  fi
  if [[ -z "$SUDO_PASS" ]]; then
    IFS= read -rsp "Enter sudo password for ${ADMIN_HOST}: " SUDO_PASS
    echo ""
  fi
  if ! check_sudo "$ADMIN_HOST" "$SUDO_PASS"; then
    SUDO_PASS=""
    log_error "Sudo password validation failed for ${ADMIN_HOST}"
    return 1
  fi
  SUDO_MODE="sudo-pass"
}
