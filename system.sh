#!/usr/bin/env bash
#
#  ███████╗██╗   ██╗███████╗████████╗███████╗███╗   ███╗
#  ██╔════╝╚██╗ ██╔╝██╔════╝╚══██╔══╝██╔════╝████╗ ████║
#  ███████╗ ╚████╔╝ ███████╗   ██║   █████╗  ██╔████╔██║
#  ╚════██║  ╚██╔╝  ╚════██║   ██║   ██╔══╝  ██║╚██╔╝██║
#  ███████║   ██║   ███████║   ██║   ███████╗██║ ╚═╝ ██║
#  ╚══════╝   ╚═╝   ╚══════╝   ╚═╝   ╚══════╝╚═╝     ╚═╝
#
# Look at a validator host and say which of the other scripts applies to it:
#
#   arise.sh    a server with no validator yet
#   ascend.sh   install or upgrade the Hexis Agave client
#   reawaken.sh   move to Firedancer, upgrade it, or go back to Agave
#
#   system.sh --host <ip> --ssh-key <key>             what is there, what you can do
#   system.sh <goal> --host <ip> --ssh-key <key>      run the step that gets you there
#
# Without a goal nothing is run and nothing on the host is changed. With one,
# the command is shown and handed to the script that owns it, which asks before
# it stops or starts a validator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for lib in hexis.sh firedancer.sh; do
  if [[ ! -f "${ROOT}/lib/${lib}" ]]; then
    echo "Missing ${ROOT}/lib/${lib} — run this from a checkout, not as a lone copied file" >&2
    exit 1
  fi
done
# shellcheck source=lib/hexis.sh
source "${ROOT}/lib/hexis.sh"
# shellcheck source=lib/firedancer.sh
source "${ROOT}/lib/firedancer.sh"

AGAVE_ASSET="agave-validator-linux-amd64"
FD_ASSET_GENERIC="firedancer-linux-amd64"

GOAL=""
SSH_HOST=""
SSH_KEY=""
SOL_USER="sol"
ADMIN_USER="monarch"
AGAVE_SERVICE="sol"
TAG=""
PRINT_ONLY=false
PASS=()

usage() {
  cat <<EOF
Usage: $0 [goal] --host <ip-or-hostname> --ssh-key <path> [OPTIONS] [-- <args for the script>]

Without a goal: report what runs on the host and list what can be done from there.

Goals:
  upgrade      Newest release of the client the host runs today
  hexis        Onto the Hexis Agave client (from Jito or plain Agave)
  firedancer   Onto Firedancer with the Hexis Concorde: stages it, and on the
               next call, once it is staged, cuts over
  agave        Back from Firedancer to the Agave client validator.sh describes

Moving between Jito and Agave, leaving Hexis, or upgrading a Jito or Agave build
is done by arise.sh: run it again with the flags the host was set up with, the
new --client / --client-version, and --restart. It needs your keys, so it is not
run from here.

Options:
  --tag <tag>          Release to use instead of the newest
  --user <name>        Validator user (default: ${SOL_USER})
  --admin-user <name>  Admin user that holds sudo (default: ${ADMIN_USER})
  --agave-service <n>  Agave systemd unit (default: ${AGAVE_SERVICE})
  --print              Show the command for the goal, do not run it
  -h, --help           Show this help

Everything after '--' goes to the script that is run, e.g. '-- --dry-run' or '-- --now'.
EOF
  exit 1
}

case "${1:-}" in
  upgrade|hexis|firedancer|agave) GOAL="$1"; shift ;;
esac

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)          SSH_HOST="$2"; shift 2 ;;
    --ssh-key)       SSH_KEY="$2"; shift 2 ;;
    --user)          SOL_USER="$2"; shift 2 ;;
    --admin-user)    ADMIN_USER="$2"; shift 2 ;;
    --agave-service) AGAVE_SERVICE="$2"; shift 2 ;;
    --tag)           TAG="$2"; shift 2 ;;
    --print)         PRINT_ONLY=true; shift ;;
    --)              shift; PASS=("$@"); break ;;
    -h|--help)       usage ;;
    *) log_error "Unknown option or goal: $1"; usage ;;
  esac
done

[[ -z "$SSH_HOST" ]] && { log_error "--host is required";    usage; }
[[ -z "$SSH_KEY"  ]] && { log_error "--ssh-key is required"; usage; }
[[ ! -f "$SSH_KEY" ]] && { log_error "SSH key not found: $SSH_KEY"; exit 1; }

SSH_HOST="${SSH_HOST##*@}"
SOL_HOST="${SOL_USER}@${SSH_HOST}"
VALIDATOR_SH="/home/${SOL_USER}/validator.sh"
FD_DIR="/home/${SOL_USER}/firedancer"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o IdentitiesOnly=yes -i $SSH_KEY"
HOST_ARGS="--host ${SSH_HOST} --ssh-key ${SSH_KEY}"
[[ "$SOL_USER" != "sol" ]] && HOST_ARGS+=" --user ${SOL_USER}"
[[ "$ADMIN_USER" != "monarch" ]] && HOST_ARGS+=" --admin-user ${ADMIN_USER}"
# What arise.sh needs to change the client or version of a host it set up
ARISE_HINT="./arise.sh ${HOST_ARGS} --identity <staked_identity.json> --vote-account <pubkey> --network <net> --client <jito|agave> --client-version <tag> --restart"

# shellcheck disable=SC2086
probe() { ssh -n $SSH_OPTS "$SOL_HOST" "$@" 2>/dev/null || true; }
fact() { sed -n "s/^$1=//p" <<<"$FACTS" | head -1; }

# ---------------------------------------------------------------------------
# What is on the host
# ---------------------------------------------------------------------------
STATE=""
SOURCE=""
HEXIS_DIR=""
VSH=""
if ! probe "echo ok" | grep -q ok; then
  STATE="unreachable"
else
  VSH=$(probe "cat ${VALIDATOR_SH}")
  [[ -z "$VSH" ]] && STATE="fresh"
fi

# A Firedancer that is running from somewhere other than ${FD_DIR}: one these
# scripts did not install, e.g. an upstream build taking Jito bundles. Found by
# its process, since it has no validator.sh and may have any unit name.
OTHER_FD=""
OTHER_FD_KIND=""
if [[ "$STATE" != "unreachable" ]]; then
  OTHER_FD=$(probe ": other-firedancer
ps -eo args 2>/dev/null | awk '\$1 ~ /(^|\\/)(firedancer|fdctl)\$/ && \$2 == \"run\" { for (i = 3; i < NF; i++) if (\$i == \"--config\") { print \$(i + 1); exit } }'")
  if [[ -n "$OTHER_FD" && "$OTHER_FD" != "${FD_DIR}/config.toml" ]]; then
    OTHER_FD_KIND=$(probe ": other-firedancer-kind
if grep -q '^\[arb\]' '${OTHER_FD}' 2>/dev/null; then echo hexis
elif awk '/^[[:space:]]*\[/ { t = \$0 } t ~ /tiles\.bundle/ && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true/ { f = 1 } END { exit !f }' '${OTHER_FD}' 2>/dev/null; then echo jito
else echo plain; fi")
    STATE="other-firedancer"
  else
    OTHER_FD=""
  fi
fi

FACTS=""
CLUSTER_GENESIS=$(fd_vsh_flag "$VSH" "--expected-genesis-hash")
NOT_MAINNET=false
[[ -n "$CLUSTER_GENESIS" && "$CLUSTER_GENESIS" != "$MAINNET_GENESIS_HASH" ]] && NOT_MAINNET=true

if [[ -z "$STATE" ]]; then
  SOURCE=$(fd_detect_source "$VSH")
  [[ "$SOURCE" == "hexis" ]] && HEXIS_DIR=$(dirname "$(fd_vsh_flag "$VSH" "--arb-config")")
  FACTS=$(probe ": system-facts
echo \"agave_active=\$(systemctl is-active ${AGAVE_SERVICE} 2>/dev/null)\"
echo \"fd_active=\$(systemctl is-active firedancer 2>/dev/null)\"
echo \"fd_enabled=\$(systemctl is-enabled firedancer 2>/dev/null)\"
echo \"fd_release=\$(readlink ${FD_DIR}/firedancer 2>/dev/null | sed -e 's|^releases/||' -e 's|/firedancer\$||')\"
echo \"fd_config=\$(test -f ${FD_DIR}/config.toml && echo yes || echo no)\"
echo \"fd_previous=\$(cat ${FD_DIR}/.previous-release 2>/dev/null)\"
echo \"jag_snap=\$(ss -lnt 2>/dev/null | grep -q ':18899 ' && echo up || echo down)\"
echo \"perch_local=\$($(perch_local_rpc_dead_cmd "$SOL_USER"))\"
echo \"agave_release=\$(readlink ${HEXIS_DIR:-/nonexistent}/agave-validator 2>/dev/null | sed -e 's|^releases/||' -e 's|/agave-validator\$||')\"")
  if [[ "$(fact fd_enabled)" == "enabled" ]]; then
    STATE="firedancer"
  else
    STATE="$SOURCE"
  fi
fi

case "$SOURCE" in
  hexis) SOURCE_LABEL="Hexis Agave" ;;
  jito)  SOURCE_LABEL="Jito" ;;
  *)     SOURCE_LABEL="plain Agave" ;;
esac

# ---------------------------------------------------------------------------
# Newest releases
# ---------------------------------------------------------------------------
NEW_AGAVE=""
NEW_FD=""
if [[ -n "$TAG" ]]; then
  NEW_AGAVE="$TAG"
  NEW_FD="$TAG"
elif command -v gh &>/dev/null && gh auth status &>/dev/null; then
  RELEASES=$(hexis_release_lines 2>/dev/null || true)
  NEW_AGAVE=$(hexis_latest_tag "$RELEASES" "$AGAVE_ASSET" || true)
  NEW_FD=$(hexis_latest_tag "$RELEASES" "$FD_ASSET_GENERIC" || true)
fi

# ---------------------------------------------------------------------------
# Routing: goal -> the one command that moves this host towards it
# ---------------------------------------------------------------------------
# Sets CMD (empty when there is nothing to run) and NOTE (why, or what follows).
route() {
  CMD=""; NOTE=""
  local fd_staged="no"
  if $NOT_MAINNET && [[ "$1" != "agave" ]]; then
    NOTE="the Hexis builds are mainnet only, and this validator is on another cluster (genesis ${CLUSTER_GENESIS:0:8}…)"
    return 0
  fi
  [[ -n "$(fact fd_release)" && "$(fact fd_config)" == "yes" ]] && fd_staged="yes"

  case "$1" in
    upgrade)
      case "$STATE" in
        firedancer)
          if [[ -z "$NEW_FD" ]]; then NOTE="could not read the release list — pass --tag"
          elif [[ "$NEW_FD" == "$(fact fd_release)" ]]; then NOTE="already on ${NEW_FD}"
          else CMD="./reawaken.sh upgrade ${HOST_ARGS} --fd-tag '${NEW_FD}'"; fi ;;
        hexis)
          if [[ -z "$NEW_AGAVE" ]]; then NOTE="could not read the release list — pass --tag"
          elif [[ "$NEW_AGAVE" == "$(fact agave_release)" ]]; then NOTE="already on ${NEW_AGAVE}"
          else CMD="./ascend.sh upgrade ${HOST_ARGS} --hexis-tag '${NEW_AGAVE}' --restart"; fi ;;
        *) NOTE="${SOURCE_LABEL} is built on the host, so arise.sh upgrades it: run it again with the flags the host was set up with, plus --client-version <tag> --restart" ;;
      esac ;;
    hexis)
      case "$STATE" in
        hexis)      NOTE="already runs the Hexis Agave client (goal: upgrade)" ;;
        firedancer) NOTE="runs Firedancer — 'agave' goes back to the Agave client it ran before" ;;
        *)
          if [[ -z "$NEW_AGAVE" ]]; then NOTE="could not read the release list — pass --tag"
          else CMD="./ascend.sh migrate ${HOST_ARGS} --hexis-tag '${NEW_AGAVE}' --restart"; NOTE="pass the Hexis signer after '--': -- --hexis-signer <signing_key.json>"; fi ;;
      esac ;;
    firedancer)
      if [[ "$STATE" == "firedancer" && "$(fact fd_active)" == "active" ]] \
         && [[ "$(fact jag_snap)" == "up" || "$(fact perch_local)" == "yes" ]]; then
        # A cutover that needed a reboot for huge pages: Firedancer came up by
        # itself and the last steps (jag-snap, perch's endpoints) are still to do.
        CMD="./reawaken.sh cutover ${HOST_ARGS}"
        NOTE="Firedancer is running; this finishes the cutover (jag-snap and perch still point at Agave's RPC)"
      elif [[ "$STATE" == "firedancer" ]]; then
        NOTE="already runs Firedancer (goal: upgrade)"
      elif [[ "$fd_staged" == "yes" ]]; then
        CMD="./reawaken.sh cutover ${HOST_ARGS}"
        NOTE="$(fact fd_release) is staged; this stops ${SOURCE_LABEL} and starts it"
      elif [[ -z "$NEW_FD" ]]; then
        NOTE="could not read the release list — pass --tag"
      else
        CMD="./reawaken.sh stage ${HOST_ARGS} --fd-tag '${NEW_FD}'"
        NOTE="stages only; run the same goal again to cut over"
      fi ;;
    agave)
      if [[ "$STATE" == "firedancer" ]]; then
        CMD="./reawaken.sh rollback ${HOST_ARGS}"
      else
        NOTE="already runs ${SOURCE_LABEL}"
      fi ;;
  esac
}

# ---------------------------------------------------------------------------
# Hosts with no validator: only arise.sh applies, and it needs your keys
# ---------------------------------------------------------------------------
if [[ "$STATE" == "unreachable" || "$STATE" == "fresh" ]]; then
  if [[ "$STATE" == "unreachable" ]]; then
    log_warn "Cannot SSH to ${SOL_HOST} with ${SSH_KEY}."
    log_warn "If this is a new server, the ${SOL_USER} user does not exist yet:"
  else
    log_info "${SOL_HOST} is reachable but has no ${VALIDATOR_SH}: no validator is set up."
  fi
  echo ""
  echo "  ./arise.sh --host ${SSH_HOST} --ssh-key ${SSH_KEY} \\"
  echo "      --identity <staked_identity.json> --vote-account <pubkey> \\"
  echo "      --commission-bps <bps> --network mainnet"
  echo ""
  echo "  It needs your keys and choices, so it is not run from here: ./arise.sh --help"
  [[ -n "$GOAL" ]] && exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# A Firedancer from somewhere else: reported, never touched
# ---------------------------------------------------------------------------
if [[ "$STATE" == "other-firedancer" ]]; then
  case "$OTHER_FD_KIND" in
    hexis) OTHER_LABEL="Firedancer with the Hexis Concorde" ;;
    jito)  OTHER_LABEL="Firedancer taking Jito bundles" ;;
    *)     OTHER_LABEL="Firedancer" ;;
  esac
  echo ""
  echo "  Host:            ${SOL_HOST}"
  echo "  Runs:            ${OTHER_LABEL}, config ${OTHER_FD}"
  echo ""
  log_warn "That Firedancer was not installed by these scripts (theirs lives in ${FD_DIR}),"
  log_warn "so nothing here upgrades, moves or rolls it back. reawaken.sh starts from a"
  log_warn "validator.sh, which this host ${VSH:+has but is not running from}${VSH:-does not have}."
  [[ -n "$GOAL" ]] && exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
describe_fd() {
  if [[ -z "$(fact fd_release)" ]]; then echo "not installed"
  elif [[ "$STATE" == "firedancer" ]]; then echo "$(fact fd_release), firedancer.service $(fact fd_active)"
  else echo "$(fact fd_release) staged, not running"; fi
}

echo ""
echo "  Host:            ${SOL_HOST}"
if [[ "$STATE" == "firedancer" ]]; then
  echo "  Runs:            Firedancer with the Hexis Concorde"
  echo "  Agave:           ${SOURCE_LABEL}${HEXIS_DIR:+ $(fact agave_release)}, ${AGAVE_SERVICE}.service $(fact agave_active) (kept for going back)"
else
  echo "  Runs:            ${SOURCE_LABEL}${HEXIS_DIR:+ $(fact agave_release)}, ${AGAVE_SERVICE}.service $(fact agave_active)"
fi
echo "  Firedancer:      $(describe_fd)"
echo "  Newest releases: Hexis Agave ${NEW_AGAVE:-unknown}   Firedancer ${NEW_FD:-unknown}"
echo ""

if [[ -z "$GOAL" ]] && $NOT_MAINNET; then
  route upgrade
  echo "  From here:       nothing — ${NOTE}"
  echo ""
  exit 0
fi

if [[ -z "$GOAL" ]]; then
  echo "  From here:"
  for g in upgrade hexis firedancer agave; do
    route "$g"
    [[ -z "$CMD" ]] && continue
    printf '    %-11s %s\n' "$g" "$CMD"
    [[ -n "$NOTE" ]] && printf '    %-11s   (%s)\n' "" "$NOTE"
  done
  route upgrade
  [[ -z "$CMD" && "$NOTE" == already* ]] && echo "    upgrade     nothing to do: ${NOTE}"
  echo ""
  echo "  Run one of them:  $0 <goal> ${HOST_ARGS}"
  echo ""
  echo "  Jito <-> Agave, leaving Hexis, or a new Jito/Agave version — arise.sh, with"
  echo "  the flags this host was set up with:"
  echo "    ${ARISE_HINT}"
  if [[ "$STATE" == "firedancer" ]]; then
    echo "  Here that installs the client beside Firedancer; 'agave' above then switches to it."
  fi
  echo ""
  exit 0
fi

route "$GOAL"
if [[ -z "$CMD" ]]; then
  if [[ "$NOTE" == already* ]]; then
    log_info "Nothing to do for '${GOAL}': ${SOL_HOST} ${NOTE}"
    exit 0
  fi
  log_error "'${GOAL}' does not apply to ${SOL_HOST}: ${NOTE}"
  exit 1
fi

[[ ${#PASS[@]} -gt 0 ]] && CMD+="$(printf ' %q' "${PASS[@]}")"
[[ -n "$NOTE" ]] && log_info "$NOTE"
if $PRINT_ONLY; then
  log_info "Would run: ${CMD}"
  exit 0
fi
log_info "Running: ${CMD}"
echo ""
cd "$ROOT"
eval "exec ${CMD}"
