#!/usr/bin/env bash
#
#  ██████╗ ███████╗ █████╗ ██╗    ██╗ █████╗ ██╗  ██╗███████╗███╗   ██╗
#  ██╔══██╗██╔════╝██╔══██╗██║    ██║██╔══██╗██║ ██╔╝██╔════╝████╗  ██║
#  ██████╔╝█████╗  ███████║██║ █╗ ██║███████║█████╔╝ █████╗  ██╔██╗ ██║
#  ██╔══██╗██╔══╝  ██╔══██║██║███╗██║██╔══██║██╔═██╗ ██╔══╝  ██║╚██╗██║
#  ██║  ██║███████╗██║  ██║╚███╔███╔╝██║  ██║██║  ██╗███████╗██║ ╚████║
#  ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝
#
# Move a running validator onto Firedancer with the Hexis Concorde.
#
#   reawaken.sh stage     Put the binary, config, arb signer, unit and firewall rules in
#                       place. Reads the existing validator.sh — Hexis Agave, Jito or
#                       plain Agave — for everything it can. Does NOT touch the running
#                       validator, and is safe to repeat (also how you upgrade).
#   reawaken.sh cutover   Stop Agave at a safe window and start Firedancer.
#   reawaken.sh rollback  Stop Firedancer and bring Agave back.
#   reawaken.sh upgrade   On a host already running Firedancer: stage a newer release,
#                       wait for a safe window and restart onto it. --previous
#                       goes back to the release that ran before.
#   reawaken.sh status    Show which client is installed and running.
#
# Only cutover, rollback and upgrade stop or start a validator, and all ask first.

# The FDC_* variables set below are read by fd_render_base_config in lib/firedancer.sh.
# shellcheck disable=SC2034
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
for lib in hexis.sh firedancer.sh remote.sh; do
  if [[ ! -f "${LIB_DIR}/${lib}" ]]; then
    echo "Missing ${LIB_DIR}/${lib} — run this from a checkout, not as a lone copied file" >&2
    exit 1
  fi
done
# shellcheck source=lib/hexis.sh
source "${LIB_DIR}/hexis.sh"
# shellcheck source=lib/firedancer.sh
source "${LIB_DIR}/firedancer.sh"
# shellcheck source=lib/remote.sh
source "${LIB_DIR}/remote.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MODE=""
SSH_HOST=""
SSH_KEY=""
SOL_USER="sol"
ADMIN_USER="monarch"          # holds sudo; sol does not
VALIDATOR_SH=""              # defaults to /home/$SOL_USER/validator.sh
AGAVE_SERVICE="sol"
DRY_RUN=false
ASSUME_YES=false
NOW=false
# Minutes with no leader slot ahead before the validator is stopped. A move
# between clients gets the long one: it can need a reboot for huge pages and, at
# worst, an hour of snapshot download. An upgrade restarts from a snapshot that
# is already on disk.
MIN_IDLE_TIME=""
MIN_IDLE_TIME_MIGRATE="90"
MIN_IDLE_TIME_UPGRADE="20"
MAX_DELINQUENT_STAKE="5"
SKIP_SNAPSHOT_CHECK=true

FD_TAG=""
FD_BINARY=""
FD_ASSET=""                  # picked from the host's CPU when empty
FD_PREVIOUS=false
FD_DIR=""                    # defaults to /home/$SOL_USER/firedancer
FD_USER=""                   # defaults to $SOL_USER — see usage
FD_BASE=""                   # defaults to <agave ledger>/firedancer
FD_ACCOUNTS=""               # defaults to <agave accounts>/firedancer/accounts.db
FD_INTERFACE=""
FD_METRICS_ADDR=""
FD_ENABLE_RPC=false
FD_SNAPSHOT_ALLOW_ANY=false
SNAPSHOT_MIRROR=""           # defaults to FD_SNAPSHOT_MIRROR in lib/firedancer.sh
SNAPSHOT_PREFETCH=true
FD_BUNDLE_URL=""
FD_COMMISSION_BPS=""
FD_NO_BLOCK_ENGINE=false
FD_SHRED_DESTS=""
FD_SHRED_DESTS_SET=false
FD_SIGNER=""
FD_GENERATE_SIGNER=false
FD_CONCORDE_TABLES=""
FD_JUPITER_LEDGER=""
FD_JUPITER_LEDGER_SET=false
FD_OKX_LEDGER=""
FD_OKX_LEDGER_SET=false

usage() {
  cat <<EOF
Usage: $0 <stage|cutover|rollback|upgrade|status> [OPTIONS]

Modes:
  stage      Install Firedancer next to the validator that is running, without
             touching it: binary, arb signer, config.toml, firedancer.service
             (not enabled) and firewall rules. Repeat it to change the config
             or to stage a newer release.
  cutover    Wait for a restart window, stop and disable ${AGAVE_SERVICE}.service, carry the
             vote history over, enable and start firedancer.service. Retires
             jag-snap: Firedancer serves no snapshots.
  rollback   The reverse: stop and disable Firedancer, release its huge pages,
             enable and start ${AGAVE_SERVICE}.service, bring jag-snap back.
  upgrade    For a host that already runs Firedancer. Stages the release given
             with --fd-tag or --fd-binary exactly as 'stage' does, waits for a
             window with no leader slot, and restarts Firedancer onto it.
             With --previous it switches back to the release that ran before.
  status     Read-only report.

Required:
  --host <ip-or-hostname>       Validator host
  --ssh-key <path>              SSH private key for the validator user

Binary (stage, upgrade):
  --fd-tag <tag>                Hexis Firedancer release, e.g. 'v26.10.8+concorde.4'.
                                Fetched with your local gh CLI and verified against
                                the release checksums
  --fd-binary <path>            Pre-downloaded binary instead
  --previous                    upgrade only: the release that was active before the
                                current one, instead of a new one
  --fd-asset <name>             Build to take from the release. Default: picked from
                                the host's CPU (zen5, zen4, or the generic AVX2 build)

Arb signer (stage):
  --hexis-signer <path>         The signing_key.json Hexis gave you. Not needed when
                                the host already runs the Hexis Agave client — its
                                signer is reused
  --generate-signer             Make a new signer on the host. MarginFi flash loans
                                stay off until Hexis is given its own MarginFi account
  --jupiter-token-ledger <pk>   Default: the value in arb-config.toml, or the Hexis
  --okx-token-ledger <pk>       default with --hexis-signer. "" for none

Block Engine (stage; read from validator.sh when it ran Jito or Hexis):
  --block-engine-url <url>      Required for a plain Agave source, unless
  --no-block-engine             you want no bundles at all
  --commission-bps <bps>        Jito tip commission

Config (stage):
  --shred-destinations <list>   Extra receivers for the shreds of your own blocks.
                                Default: the validator.sh --shred-receiver-address list
  --interface <iface>           NIC to bind. Default: Firedancer picks the default route
  --metrics-address <ip>        Address the Prometheus metrics listen on. Default: the
                                host's public IPv4. Hexis reads it on port ${FD_METRICS_PORT}
  --snapshot-allow-any          Take snapshots from any gossip peer (Firedancer's
                                default). Without it, a validator.sh with three or
                                more --known-validator keeps to exactly those
  --snapshot-mirror <url>       Where cutover and upgrade fetch the full snapshot from
                                before the restart. Default: ${FD_SNAPSHOT_MIRROR}
  --no-snapshot-prefetch        Do not fetch it; Firedancer downloads from its peers
  --enable-rpc                  Run the RPC server. Off in the Concorde build: its core
                                goes to the arb tiles
  --concorde-tables <path>      The Concorde's config tables. Default: fetched from the
                                ${FD_DOCS_BRANCH} branch of ${HEXIS_REPO}

Paths:
  --user <name>                 Validator user (default: ${SOL_USER})
  --admin-user <name>           User that holds sudo (default: ${ADMIN_USER}). All root
                                work goes through it; the validator user has no sudo
  --validator-script <path>     Agave startup script (default: /home/<user>/validator.sh)
  --agave-service <name>        Agave systemd unit (default: ${AGAVE_SERVICE})
  --fd-dir <path>               Binary and config (default: /home/<user>/firedancer)
  --fd-user <name>              User Firedancer drops to (default: the validator user,
                                which can already read the identity keys)
  --fd-base <path>              Firedancer data (default: <agave ledger>/firedancer)
  --fd-accounts <path>          accounts.db (default: <agave accounts>/firedancer/accounts.db)

Restart window (cutover, rollback, upgrade):
  --min-idle-time <min>         Default: ${MIN_IDLE_TIME_MIGRATE} for cutover and rollback, ${MIN_IDLE_TIME_UPGRADE} for upgrade
  --max-delinquent-stake <pct>  Default: ${MAX_DELINQUENT_STAKE} (cutover only)
  --wait-for-new-snapshot       Wait for a new snapshot before stopping Agave
  --now                         Do not wait for a window

Other:
  --yes                         Do not prompt
  --dry-run                     Print what would happen, change nothing
  -h, --help                    Show this help
EOF
  exit 1
}

[[ $# -eq 0 ]] && usage
case "$1" in
  stage|cutover|rollback|upgrade|status) MODE="$1"; shift ;;
  -h|--help) usage ;;
  *) log_error "First argument must be 'stage', 'cutover', 'rollback', 'upgrade' or 'status'"; usage ;;
esac

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)             SSH_HOST="$2"; shift 2 ;;
    --ssh-key)          SSH_KEY="$2"; shift 2 ;;
    --user)             SOL_USER="$2"; shift 2 ;;
    --admin-user)       ADMIN_USER="$2"; shift 2 ;;
    --validator-script) VALIDATOR_SH="$2"; shift 2 ;;
    --agave-service)    AGAVE_SERVICE="$2"; shift 2 ;;
    --fd-tag)           FD_TAG="$2"; shift 2 ;;
    --fd-binary)        FD_BINARY="$2"; shift 2 ;;
    --fd-asset)         FD_ASSET="$2"; shift 2 ;;
    --previous)         FD_PREVIOUS=true; shift ;;
    --fd-dir)           FD_DIR="$2"; shift 2 ;;
    --fd-user)          FD_USER="$2"; shift 2 ;;
    --fd-base)          FD_BASE="$2"; shift 2 ;;
    --fd-accounts)      FD_ACCOUNTS="$2"; shift 2 ;;
    --interface)        FD_INTERFACE="$2"; shift 2 ;;
    --metrics-address)  FD_METRICS_ADDR="$2"; shift 2 ;;
    --enable-rpc)       FD_ENABLE_RPC=true; shift ;;
    --snapshot-allow-any) FD_SNAPSHOT_ALLOW_ANY=true; shift ;;
    --snapshot-mirror)  SNAPSHOT_MIRROR="$2"; shift 2 ;;
    --no-snapshot-prefetch) SNAPSHOT_PREFETCH=false; shift ;;
    --block-engine-url) FD_BUNDLE_URL="$2"; shift 2 ;;
    --commission-bps)   FD_COMMISSION_BPS="$2"; shift 2 ;;
    --no-block-engine)  FD_NO_BLOCK_ENGINE=true; shift ;;
    --shred-destinations) FD_SHRED_DESTS="$2"; FD_SHRED_DESTS_SET=true; shift 2 ;;
    --hexis-signer)     FD_SIGNER="$2"; shift 2 ;;
    --generate-signer)  FD_GENERATE_SIGNER=true; shift ;;
    --concorde-tables)  FD_CONCORDE_TABLES="$2"; shift 2 ;;
    --jupiter-token-ledger) FD_JUPITER_LEDGER="$2"; FD_JUPITER_LEDGER_SET=true; shift 2 ;;
    --okx-token-ledger) FD_OKX_LEDGER="$2"; FD_OKX_LEDGER_SET=true; shift 2 ;;
    --min-idle-time)    MIN_IDLE_TIME="$2"; shift 2 ;;
    --max-delinquent-stake) MAX_DELINQUENT_STAKE="$2"; shift 2 ;;
    --wait-for-new-snapshot) SKIP_SNAPSHOT_CHECK=false; shift ;;
    --now)              NOW=true; shift ;;
    --yes)              ASSUME_YES=true; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    -h|--help)          usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
[[ -z "$SSH_HOST" ]] && { log_error "--host is required";    usage; }
[[ -z "$SSH_KEY"  ]] && { log_error "--ssh-key is required"; usage; }
[[ ! -f "$SSH_KEY" ]] && { log_error "SSH key not found: $SSH_KEY"; exit 1; }

SSH_HOST="${SSH_HOST##*@}"
SOL_HOST="${SOL_USER}@${SSH_HOST}"
VALIDATOR_SH="${VALIDATOR_SH:-/home/${SOL_USER}/validator.sh}"
FD_DIR="${FD_DIR:-/home/${SOL_USER}/firedancer}"
FD_USER="${FD_USER:-$SOL_USER}"
FD_BIN="${FD_DIR}/firedancer"
FD_CONFIG="${FD_DIR}/config.toml"
if [[ -z "$MIN_IDLE_TIME" ]]; then
  MIN_IDLE_TIME="$MIN_IDLE_TIME_MIGRATE"
  [[ "$MODE" == "upgrade" ]] && MIN_IDLE_TIME="$MIN_IDLE_TIME_UPGRADE"
fi
FD_SIGNER_PATH="${FD_DIR}/arb-signer.json"
FD_UNIT="/etc/systemd/system/firedancer.service"

FD_PREVIOUS_FILE="${FD_DIR}/.previous-release"

if $FD_PREVIOUS && [[ "$MODE" != "upgrade" ]]; then
  log_error "--previous only goes with 'upgrade'"
  exit 1
fi
if [[ "$MODE" == "upgrade" ]]; then
  if $FD_PREVIOUS && [[ -n "$FD_TAG" || -n "$FD_BINARY" ]]; then
    log_error "Pass either --previous or a release (--fd-tag, --fd-binary), not both"
    exit 1
  fi
  if ! $FD_PREVIOUS && [[ -z "$FD_TAG" && -z "$FD_BINARY" ]]; then
    log_error "upgrade needs the release to move to: --fd-tag, --fd-binary or --previous"
    exit 1
  fi
fi

if [[ "$MODE" == "stage" ]] || { [[ "$MODE" == "upgrade" ]] && ! $FD_PREVIOUS; }; then
  if [[ -n "$FD_TAG" && -n "$FD_BINARY" ]]; then
    log_error "Pass either --fd-tag or --fd-binary, not both"
    exit 1
  fi
  if [[ -n "$FD_SIGNER" ]] && $FD_GENERATE_SIGNER; then
    log_error "Pass either --hexis-signer or --generate-signer, not both"
    exit 1
  fi
  if [[ -n "$FD_BUNDLE_URL" ]] && $FD_NO_BLOCK_ENGINE; then
    log_error "Pass either --block-engine-url or --no-block-engine, not both"
    exit 1
  fi
  for f in "$FD_BINARY" "$FD_SIGNER" "$FD_CONCORDE_TABLES"; do
    [[ -n "$f" && ! -f "$f" ]] && { log_error "File not found: $f"; exit 1; }
  done
  if [[ -n "$FD_TAG" || -z "$FD_CONCORDE_TABLES" ]]; then
    command -v gh &>/dev/null || { log_error "This needs the gh CLI locally (release download and the Concorde config tables)"; exit 1; }
    gh auth status &>/dev/null || { log_error "gh is not authenticated — run 'gh auth login' with an account that can see ${HEXIS_REPO}"; exit 1; }
  fi
fi

# Connection settings, and the helpers that use them (root_script, sol_script,
# remote, sol_write_file), come from lib/remote.sh. Root work goes through the
# admin user; sol has no sudo.
remote_init
# Each remote script in this file sets its own error handling.
REMOTE_STRICT=":"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Always runs, even under --dry-run. For reads that must not be faked.
probe() { ssh -n "${SSH_OPTS[@]}" "$SOL_HOST" "$@" 2>/dev/null || true; }

confirm() {
  $ASSUME_YES && return 0
  $DRY_RUN && return 1
  local reply
  read -rp "$1 [type 'yes' to continue]: " reply
  [[ "$reply" == "yes" ]]
}

need_sudo() {
  $DRY_RUN && return 0
  ask_sudo_pass || exit 1
}

fact() { sed -n "s/^$1=//p" <<<"$FACTS" | head -1; }

# How long to wait between looks at a host that is rebooting
REBOOT_POLL_SECONDS="${REBOOT_POLL_SECONDS:-10}"

# huge_page_outlook <required 1 GiB pages> — one line on whether the first
# Firedancer start is likely to need a reboot. Whether the kernel can find that
# many contiguous gigabytes is only known when it is asked, after Agave has
# stopped, so this says what is known and does not guess beyond it.
huge_page_outlook() {
  local need="$1" have days
  have=$(fact hp1g_total); days=$(fact uptime_days)
  [[ "$need" =~ ^[0-9]+$ && "$have" =~ ^[0-9]+$ ]] || return 0
  if [[ "$(fact fd_active)" == "active" ]]; then
    echo "${need} one-GiB pages, held by the running Firedancer"
  elif (( have >= need )); then
    echo "${need} one-GiB pages needed, ${have} already reserved — no reboot needed"
  elif [[ "$days" =~ ^[0-9]+$ ]] && (( days < 1 )); then
    echo "${need} one-GiB pages needed, ${have} reserved. Booted today, so they are usually found without a reboot"
  else
    echo "${need} one-GiB pages needed, ${have} reserved. Up ${days:-?} day(s): expect cutover to need a reboot, which it offers"
  fi
}

# The remote cutover script exits with this when Firedancer could not get its
# 1 GiB pages: everything else is done and only a reboot is missing.
EXIT_NEEDS_REBOOT=42

# reboot_for_huge_pages — Agave is stopped, Firedancer is enabled and could not
# reserve its pages. Offers the reboot, waits for the host to come back as a new
# boot, and for Firedancer to be running on it. Returns 1 when the operator
# declines or the host does not come back in time; says what is left to do.
reboot_for_huge_pages() {
  local old_boot new_boot i state=""
  echo ""
  log_warn "Firedancer could not reserve its 1 GiB pages: memory on ${SOL_HOST} is too fragmented."
  log_warn "${AGAVE_SERVICE}.service is stopped and disabled, firedancer.service is enabled, and"
  log_warn "jag-snap and perch are already taken care of. A reboot is all that is missing:"
  log_warn "Firedancer starts by itself and takes its pages first thing. The validator is"
  log_warn "not voting until then."
  if ! confirm "Reboot ${SOL_HOST} now?"; then
    log_warn "Not rebooted. Reboot it yourself; nothing needs to be run afterwards:"
    log_warn "  ${SSH_CMD} -t ${ADMIN_HOST} 'sudo systemctl reboot'"
    log_warn "Or go back to Agave: $0 rollback --host ${SSH_HOST} --ssh-key ${SSH_KEY}"
    return 1
  fi
  old_boot=$(fact boot_id)
  log_info "Rebooting ${SOL_HOST}"
  # The connection drops as the host goes down, so the status says nothing
  echo "systemctl reboot" | admin_root_exec "bash -s" >/dev/null 2>&1 || true

  log_info "Waiting for it to come back (up to 15 minutes)"
  new_boot=""
  for ((i = 0; i < 90; i++)); do
    sleep "$REBOOT_POLL_SECONDS"
    new_boot=$(probe "cat /proc/sys/kernel/random/boot_id")
    [[ -n "$new_boot" && "$new_boot" != "$old_boot" ]] && break
    new_boot=""
  done
  if [[ -z "$new_boot" ]]; then
    log_error "${SOL_HOST} has not come back. When it does, Firedancer starts by itself. Check with:"
    log_error "  $0 status --host ${SSH_HOST} --ssh-key ${SSH_KEY}"
    return 1
  fi
  log_info "${SOL_HOST} is back. Waiting for firedancer.service"
  for ((i = 0; i < 30; i++)); do
    state=$(probe "systemctl is-active firedancer")
    [[ "$state" == "active" || "$state" == "failed" ]] && break
    sleep "$REBOOT_POLL_SECONDS"
  done
  if [[ "$state" != "active" ]]; then
    log_error "firedancer.service is '${state:-unknown}' after the reboot. Look at:"
    log_error "  ${SSH_CMD} -t ${ADMIN_HOST} 'sudo journalctl -u firedancer -n 50'"
    log_error "Or go back to Agave: $0 rollback --host ${SSH_HOST} --ssh-key ${SSH_KEY}"
    return 1
  fi
  log_info "firedancer.service started after the reboot"
}

# required_gigantic_pages <firedancer mem output>
required_gigantic_pages() { sed -n 's/.*Required Gigantic Pages *\([0-9][0-9]*\).*/\1/p' <<<"$1" | head -1; }

# fd_prefetch_snapshot <agave snapshot dir or ""> — before the validator stops,
# fetch the current full snapshot from the mirror into Firedancer's snapshot
# directory, so the start that follows loads it from disk instead of spending
# an hour downloading it. See fd_render_snapshot_prefetch for what it checks.
fd_prefetch_snapshot() {
  $SNAPSHOT_PREFETCH || return 0
  local cfg snaps log user mirror="${SNAPSHOT_MIRROR:-$FD_SNAPSHOT_MIRROR}"
  cfg=$(probe "cat ${FD_CONFIG}")
  snaps=$(fd_toml_get "$cfg" "snapshots")
  log=$(fd_toml_get "$cfg" "path")
  user=$(fd_toml_get "$cfg" "user")
  [[ -z "$snaps" || -z "$user" ]] && return 0
  if $DRY_RUN; then
    echo "[DRY RUN] pre-download the full snapshot from ${mirror} into ${snaps}, if a trusted validator serves the same one"
    return 0
  fi
  log_info "Pre-downloading the full snapshot from ${mirror} — the validator keeps running"
  root_script <<SCRIPT
$(fd_render_snapshot_prefetch "$mirror" "$snaps" "$user" "$FD_CONFIG" "$log" "${1:-}" "$(fd_vsh_flag "$VSH" "--rpc-port")")
SCRIPT
}

# Runs 'firedancer mem' on a config file and prints its output. That command
# parses the whole config against this exact build and changes nothing, so it
# is the check that the file will boot. It exits 0 even when the parse fails,
# so success is judged by the summary it prints, not by its status.
mem_check() {
  local config="$1" bin="${2:-$FD_BIN}" script
  script="${bin} mem --config ${config} 2>&1 | grep -E 'Total Tiles|Total Memory Locked|Required (Gigantic|Huge) Pages|unrecognized key|ERR |EMERG|CRIT|ALERT' | head -20"
  if [[ "$FD_USER" == "$SOL_USER" ]]; then
    probe "$script"
  else
    # The log directory belongs to the Firedancer user, which sol cannot write
    printf '%s\n' "$script" | admin_root_exec "bash -s" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Preflight: what is on this host
# ---------------------------------------------------------------------------
log_info "Mode: ${MODE}  Host: ${SOL_HOST}  Firedancer dir: ${FD_DIR}"

if ! probe "echo ok" | grep -q ok; then
  log_error "Cannot SSH to ${SOL_HOST}"
  exit 1
fi

# The heredoc is expanded here on purpose: it carries this script's paths.
# shellcheck disable=SC2087
FACTS=$(ssh "${SSH_OPTS[@]}" "$SOL_HOST" "bash -s -- host-facts" 2>/dev/null <<FACTSEOF || true
echo "vendor=\$(awk -F': ' '/^vendor_id/{print \$2; exit}' /proc/cpuinfo)"
echo "family=\$(awk -F': ' '/^cpu family/{print \$2; exit}' /proc/cpuinfo)"
echo "model=\$(awk -F': ' '/^model name/{print \$2; exit}' /proc/cpuinfo)"
echo "flags=\$(grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | grep -xE 'avx2|avx512f' | tr '\n' ' ')"
echo "glibc=\$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\$')"
echo "mem_gib=\$(awk '/^MemTotal/{printf "%d", \$2/1048576}' /proc/meminfo)"
echo "hp1g_total=\$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null)"
echo "uptime_days=\$(awk '{printf "%d", \$1/86400}' /proc/uptime)"
echo "boot_id=\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
echo "ip=\$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="src") print \$(i+1)}' | head -1)"
echo "doublezero=\$(ip link show doublezero0 >/dev/null 2>&1 && echo yes || echo no)"
echo "ufw=\$(grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf && echo active || echo inactive)"
echo "agave_active=\$(systemctl is-active ${AGAVE_SERVICE} 2>/dev/null)"
echo "agave_enabled=\$(systemctl is-enabled ${AGAVE_SERVICE} 2>/dev/null)"
echo "fd_active=\$(systemctl is-active firedancer 2>/dev/null)"
echo "fd_enabled=\$(systemctl is-enabled firedancer 2>/dev/null)"
echo "fd_unit=\$(test -f ${FD_UNIT} && echo yes || echo no)"
echo "fd_release=\$(readlink ${FD_BIN} 2>/dev/null | sed -e 's|^releases/||' -e 's|/firedancer\$||')"
echo "fd_version=\$(${FD_BIN} version 2>/dev/null | head -1)"
echo "fd_config=\$(test -f ${FD_CONFIG} && echo yes || echo no)"
echo "fd_signer=\$(test -e ${FD_SIGNER_PATH} && echo yes || echo no)"
echo "vsh=\$(test -f ${VALIDATOR_SH} && echo yes || echo no)"
FACTSEOF
)

if [[ "$(fact vsh)" != "yes" ]]; then
  log_error "No validator startup script at ${VALIDATOR_SH} — pass --validator-script"
  exit 1
fi

VSH=$(probe "cat ${VALIDATOR_SH}")
SOURCE=$(fd_detect_source "$VSH")
case "$SOURCE" in
  hexis) SOURCE_LABEL="Hexis Agave" ;;
  jito)  SOURCE_LABEL="Jito" ;;
  *)     SOURCE_LABEL="plain Agave" ;;
esac

AGAVE_LEDGER=$(fd_vsh_flag "$VSH" "--ledger")
# Agave keeps its snapshots in the ledger unless --snapshots says otherwise
AGAVE_SNAPSHOTS=$(fd_vsh_flag "$VSH" "--snapshots")
AGAVE_SNAPSHOTS="${AGAVE_SNAPSHOTS:-$AGAVE_LEDGER}"
AGAVE_IDENTITY=$(fd_vsh_flag "$VSH" "--identity")
if [[ -z "$AGAVE_LEDGER" || -z "$AGAVE_IDENTITY" ]]; then
  log_error "Could not find --ledger and --identity in ${VALIDATOR_SH}"
  exit 1
fi

# Which keys these paths really are: identity.json is usually a symlink that
# decides whether this host is the staked validator or a spare.
AGAVE_VOTERS=$(fd_vsh_flag_all "$VSH" "--authorized-voter" | grep -vxF "$AGAVE_IDENTITY" | paste -sd' ' - || true)
# shellcheck disable=SC2086
KEY_INFO=$(probe "$(fd_key_info_cmd "$AGAVE_IDENTITY" $AGAVE_VOTERS)")
IDENTITY_LABEL=$(fd_key_label "$KEY_INFO" "$AGAVE_IDENTITY")
IDENTITY_PUBKEY=$(grep -m1 -F "${AGAVE_IDENTITY}|" <<<"$KEY_INFO" | cut -d'|' -f3 || true)

# The binary systemd is running right now, for admin-RPC calls against it
AGAVE_EXEC=$(grep -m1 -E '^[[:space:]]*exec[[:space:]]' <<<"$VSH" | awk '{print $2}' || true)
if [[ -n "$AGAVE_EXEC" && "$AGAVE_EXEC" != /* ]]; then
  AGAVE_EXEC=$(probe "p=\$(grep -m1 '^PATH=' ${VALIDATOR_SH} | sed 's/^PATH=//'); PATH=\"\${p:-\$PATH}\" command -v ${AGAVE_EXEC} || true")
fi

# jag-snap fronts Agave's RPC on 18899 to serve snapshots. Firedancer makes no
# snapshots and does not advertise an RPC address, so the proxy has nothing to
# do there: cutover retires it and rollback brings it back.
JAG_SNAP_PORT="18899"
USES_JAG_SNAP=false
[[ "$(fd_vsh_flag "$VSH" "--public-rpc-address")" == *":${JAG_SNAP_PORT}" ]] && USES_JAG_SNAP=true

RUNNING="nothing"
[[ "$(fact agave_active)" == "active" ]] && RUNNING="${SOURCE_LABEL} (${AGAVE_SERVICE}.service)"
[[ "$(fact fd_active)" == "active" ]] && RUNNING="Firedancer (firedancer.service)"

log_info "Startup script: ${SOURCE_LABEL}   Running now: ${RUNNING}"

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
if [[ "$MODE" == "status" ]]; then
  echo ""
  echo "  Host CPU:        $(fact model)  ($(fact mem_gib) GiB RAM, glibc $(fact glibc))"
  echo "  Agave:           ${AGAVE_SERVICE}.service $(fact agave_active) / $(fact agave_enabled)   (${SOURCE_LABEL})"
  echo "  Firedancer:      firedancer.service $(fact fd_active) / $(fact fd_enabled)"
  echo "  Staged release:  ${FD_DIR}: $(fact fd_release) $(fact fd_version)"
  echo "  Staged config:   $(fact fd_config)   unit: $(fact fd_unit)   arb signer: $(fact fd_signer)"
  if [[ "$(fact fd_config)" == "yes" ]]; then
    # Read as the validator user; says nothing when the config is not readable to it
    OUTLOOK=$(huge_page_outlook "$(required_gigantic_pages "$(probe "${FD_BIN} mem --config ${FD_CONFIG} 2>&1")")")
    [[ -n "$OUTLOOK" ]] && echo "  Huge pages:      ${OUTLOOK}"
  fi
  echo ""
  exit 0
fi

# ---------------------------------------------------------------------------
# cutover / rollback
# ---------------------------------------------------------------------------
if [[ "$MODE" == "cutover" || "$MODE" == "rollback" ]]; then
  if [[ "$(fact fd_unit)" != "yes" || "$(fact fd_config)" != "yes" ]]; then
    log_error "Firedancer is not staged on ${SOL_HOST} — run '$0 stage' first"
    exit 1
  fi
  FD_CONFIG_TEXT=$(probe "cat ${FD_CONFIG}")
  FD_BASE=$(fd_toml_get "$FD_CONFIG_TEXT" "base")
  FD_USER=$(fd_toml_get "$FD_CONFIG_TEXT" "user")
  FD_SNAPSHOTS_DIR=$(fd_toml_get "$FD_CONFIG_TEXT" "snapshots")
  FD_ACCOUNTS_DIR=$(fd_toml_get "$FD_CONFIG_TEXT" "accounts")
  [[ -n "$FD_ACCOUNTS_DIR" ]] && FD_ACCOUNTS_DIR=$(dirname "$FD_ACCOUNTS_DIR")
  if [[ -z "$FD_BASE" || -z "$FD_USER" ]]; then
    log_error "Could not read [paths] base and user from ${FD_CONFIG}"
    exit 1
  fi
fi

if [[ "$MODE" == "cutover" ]]; then
  # Firedancer serves no snapshots, so the proxy in front of Agave's RPC goes.
  # The container is kept, not removed: a rollback only has to start it again.
  JAG_SNAP_RETIRE=""
  if $USES_JAG_SNAP; then
    JAG_SNAP_RETIRE="if command -v docker >/dev/null 2>&1 && [ \"\$(docker inspect -f '{{.State.Running}}' jag-snap 2>/dev/null)\" = true ]; then
  docker update --restart no jag-snap >/dev/null
  docker stop jag-snap >/dev/null
  echo \"jag-snap stopped (container kept for a rollback)\"
fi
if ufw status 2>/dev/null | grep -q 'Status: active' && ufw status | grep -q '^${JAG_SNAP_PORT}/tcp'; then
  ufw delete allow ${JAG_SNAP_PORT}/tcp >/dev/null 2>&1 || true
  echo \"ufw: closed ${JAG_SNAP_PORT}/tcp\"
fi"
  fi

  # Reached when Firedancer came up by itself after a failed cutover, e.g. on the
  # reboot that a huge page failure needs. Only the jag-snap step is left to do.
  if [[ "$(fact fd_active)" == "active" ]]; then
    log_info "Firedancer is already running on ${SOL_HOST} — nothing to cut over"
    if $DRY_RUN; then
      $USES_JAG_SNAP && echo "[DRY RUN] stop the jag-snap container and close ${JAG_SNAP_PORT}/tcp, if still up"
      echo "[DRY RUN] drop this host's own RPC from perch's endpoints, if the host runs perch"
      echo "[DRY RUN] point perch at Firedancer's metrics, if the host runs perch ${PERCH_FIREDANCER_MIN} or newer"
    else
      need_sudo
      root_script <<SCRIPT
${JAG_SNAP_RETIRE}
$(perch_local_rpc_off_cmd "$SOL_USER")
$(perch_firedancer_on_cmd "$SOL_USER" "$FD_CONFIG")
SCRIPT
    fi
    exit 0
  fi

  if $DRY_RUN; then
    echo "[DRY RUN] check ${FD_CONFIG} with 'firedancer mem'"
    fd_prefetch_snapshot "$AGAVE_SNAPSHOTS"
    if [[ "$(fact agave_active)" == "active" ]] && ! $NOW; then
      echo "[DRY RUN] wait for a restart window (min-idle-time ${MIN_IDLE_TIME}m, max-delinquent-stake ${MAX_DELINQUENT_STAKE}%)"
    fi
    echo "[DRY RUN] perch maint restart ${PERCH_DEADLINE_FIREDANCER}, if the host runs perch"
    echo "[DRY RUN] systemctl stop ${AGAVE_SERVICE}; systemctl disable ${AGAVE_SERVICE}"
    echo "[DRY RUN] copy vote_history-${IDENTITY_PUBKEY:-<identity>}.bin from ${AGAVE_LEDGER} to ${FD_BASE}; move any other identity's aside"
    [[ -n "$FD_SNAPSHOTS_DIR" ]] && echo "[DRY RUN] seed ${FD_SNAPSHOTS_DIR} with the newest snapshot in ${AGAVE_SNAPSHOTS}"
    $USES_JAG_SNAP && echo "[DRY RUN] stop the jag-snap container and close ${JAG_SNAP_PORT}/tcp"
    echo "[DRY RUN] drop this host's own RPC from perch's endpoints, if the host runs perch"
    echo "[DRY RUN] point perch at Firedancer's metrics, if the host runs perch ${PERCH_FIREDANCER_MIN} or newer"
    echo "[DRY RUN] drop the page cache and compact memory, to make room for the 1 GiB pages"
    echo "[DRY RUN] systemctl enable firedancer; systemctl start firedancer, identity ${IDENTITY_LABEL}"
    echo "[DRY RUN] if the 1 GiB pages still cannot be reserved: offer to reboot, then wait for Firedancer to come up"
    exit 0
  fi

  # Hosts staged before stage installed log rotation get it here
  FD_LOG_PATH=$(fd_toml_get "$FD_CONFIG_TEXT" "path")
  LOGROTATE_STEP=""
  [[ -n "$FD_LOG_PATH" ]] && LOGROTATE_STEP=$(fd_render_logrotate_install "$FD_LOG_PATH")
  SNAPSHOT_SEED_STEP=""
  if [[ -n "$FD_SNAPSHOTS_DIR" ]]; then
    SNAPSHOT_SEED_STEP="mkdir -p \"${FD_SNAPSHOTS_DIR}\"
$(fd_render_snapshot_seed "$AGAVE_SNAPSHOTS" "$FD_SNAPSHOTS_DIR" "$FD_USER")"
  fi
  if [[ -z "$IDENTITY_PUBKEY" ]]; then
    log_error "Could not read the pubkey of ${AGAVE_IDENTITY} on ${SOL_HOST} — it decides which vote history is carried over"
    exit 1
  fi
  need_sudo
  CHECK=$(mem_check "$FD_CONFIG")
  if ! grep -q "Total Memory Locked" <<<"$CHECK"; then
    log_error "${FD_CONFIG} does not pass 'firedancer mem' — not cutting over:"
    echo "$CHECK"
    exit 1
  fi
  log_info "Config check passed: $(grep -m1 'Total Memory Locked' <<<"$CHECK" | sed -E 's/^ +//; s/ +/ /g')"

  echo ""
  if [[ "$RUNNING" == "nothing" ]]; then
    log_warn "This starts Firedancer on ${SOL_HOST} with"
  else
    log_warn "This stops ${RUNNING} on ${SOL_HOST} and starts Firedancer with"
  fi
  log_warn "  identity          ${IDENTITY_LABEL}"
  for voter in $AGAVE_VOTERS; do
    log_warn "  authorized voter  $(fd_key_label "$KEY_INFO" "$voter")"
  done
  log_warn "Firedancer loads a snapshot on every start, so the validator is not voting until"
  log_warn "that has loaded and it has caught up. Agave's newest one in ${AGAVE_SNAPSHOTS}"
  log_warn "is handed over, or the current one is fetched first while ${RUNNING} still runs;"
  log_warn "if neither can be done, the start downloads it (about an hour)."
  confirm "Cut ${SOL_HOST} over to Firedancer?" || { log_info "Nothing changed"; exit 0; }

  fd_prefetch_snapshot "$AGAVE_SNAPSHOTS"

  if [[ "$(fact agave_active)" == "active" ]] && ! $NOW; then
    WINDOW_ARGS="wait-for-restart-window --min-idle-time ${MIN_IDLE_TIME} --max-delinquent-stake ${MAX_DELINQUENT_STAKE}"
    $SKIP_SNAPSHOT_CHECK && WINDOW_ARGS+=" --skip-new-snapshot-check"
    log_info "Waiting for a restart window (min-idle-time ${MIN_IDLE_TIME}m, max-delinquent-stake ${MAX_DELINQUENT_STAKE}%)"
    remote "${AGAVE_EXEC:-agave-validator} --ledger ${AGAVE_LEDGER} ${WINDOW_ARGS}"
  fi

  log_info "Stopping ${AGAVE_SERVICE}.service and starting firedancer.service"
  # Not under set -e here: the status of the remote script decides what happens next
  root_script <<SCRIPT && CUTOVER_RC=0 || CUTOVER_RC=$?
set -e
$(perch_maint_cmd "$SOL_USER" "$PERCH_DEADLINE_FIREDANCER" root)
systemctl stop ${AGAVE_SERVICE}
systemctl disable ${AGAVE_SERVICE} >/dev/null 2>&1 || true
echo "${AGAVE_SERVICE}.service stopped and disabled"

# Firedancer refuses to boot when the directory holds a vote history for some
# other identity and none for its own, so only this identity's file goes in and
# any other is moved aside. tower-1_9-*.bin is the pre-Alpenglow record: unused.
mkdir -p "${FD_BASE}/other-identities"
for f in ${FD_BASE}/vote_history-*.bin ${FD_BASE}/tower-1_9-*.bin; do
  [ -f "\$f" ] || continue
  [ "\$(basename "\$f")" = "vote_history-${IDENTITY_PUBKEY}.bin" ] && continue
  mv -f "\$f" "${FD_BASE}/other-identities/"
  echo "moved aside \$(basename "\$f") (not the identity Firedancer starts as)"
done
rmdir "${FD_BASE}/other-identities" 2>/dev/null || true
if [ -f "${AGAVE_LEDGER}/vote_history-${IDENTITY_PUBKEY}.bin" ]; then
  cp -a "${AGAVE_LEDGER}/vote_history-${IDENTITY_PUBKEY}.bin" "${FD_BASE}/"
  $(fd_chown_cmd "$FD_USER") "${FD_BASE}/vote_history-${IDENTITY_PUBKEY}.bin"
  echo "carried over vote_history-${IDENTITY_PUBKEY}.bin"
else
  echo "no vote history for ${IDENTITY_PUBKEY} in ${AGAVE_LEDGER} — Firedancer starts without one"
fi

# Agave's newest snapshot, so Firedancer need not download the full one again
${SNAPSHOT_SEED_STEP}

# Firedancer checks owner, group and mode of its directories before it starts
for d in "${FD_BASE}" "${FD_SNAPSHOTS_DIR}" "${FD_ACCOUNTS_DIR}"; do
  [ -d "\$d" ] && $(fd_chown_cmd "$FD_USER") "\$d"
done
[ -d "${FD_SNAPSHOTS_DIR}" ] && chmod ${FD_SNAPSHOTS_MODE} "${FD_SNAPSHOTS_DIR}"

${LOGROTATE_STEP}
$(fd_render_nofile_sysctl)

# Everything that follows Agave is done before Firedancer starts, so that a
# start which needs a reboot leaves nothing to come back for. rollback undoes both.
${JAG_SNAP_RETIRE}
$(perch_local_rpc_off_cmd "$SOL_USER")
$(perch_firedancer_on_cmd "$SOL_USER" "$FD_CONFIG")

# Firedancer needs its 1 GiB pages as contiguous memory. With Agave gone, give
# the page cache back and let the kernel compact what is free: on a host that
# has been up for a while this is what can make the reboot unnecessary.
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true

systemctl daemon-reload
systemctl reset-failed firedancer 2>/dev/null || true
systemctl enable firedancer >/dev/null 2>&1
if ! systemctl start firedancer; then
  echo "firedancer.service failed to start:"
  journalctl -u firedancer --no-pager -n 25
  if journalctl -u firedancer --no-pager -n 25 | grep -q "reserve gigantic pages"; then
    exit ${EXIT_NEEDS_REBOOT}
  fi
  echo "${AGAVE_SERVICE}.service is stopped and disabled. Fix the cause and run cutover again, or run rollback."
  exit 1
fi
echo "firedancer.service started"
SCRIPT
  if (( CUTOVER_RC == EXIT_NEEDS_REBOOT )); then
    reboot_for_huge_pages || exit 1
  elif (( CUTOVER_RC != 0 )); then
    exit "$CUTOVER_RC"
  fi

  echo ""
  log_info "============================================"
  log_info "cutover complete — Firedancer is booting"
  log_info "============================================"
  log_info "Watch it load the snapshot and catch up:"
  log_info "  ${SSH_CMD} -t ${ADMIN_HOST} 'sudo journalctl -u firedancer -f'"
  log_info "  ${SSH_CMD} -t ${ADMIN_HOST} 'sudo ${FD_BIN} ready --config ${FD_CONFIG}'"
  log_info "Then check the Control port and tell Hexis it is up:"
  log_info "  ${SSH_CMD} ${SOL_HOST} 'ss -lntp | grep ${FD_CONTROL_PORT}'"
  log_info ""
  log_info "The arb tiles start enabled — there is no arb-enable step on Firedancer."
  $USES_JAG_SNAP && log_info "jag-snap is stopped and ${JAG_SNAP_PORT}/tcp is closed: this host no longer serves snapshots."
  log_info "Back to Agave: $0 rollback --host ${SSH_HOST} --ssh-key ${SSH_KEY}"
  exit 0
fi

if [[ "$MODE" == "rollback" ]]; then
  if [[ "$(fact agave_active)" == "active" ]]; then
    log_info "${AGAVE_SERVICE}.service is already running on ${SOL_HOST} — nothing to roll back"
    exit 0
  fi

  if $DRY_RUN; then
    if [[ "$(fact fd_active)" == "active" ]] && ! $NOW; then
      echo "[DRY RUN] firedancer wait --min-idle-seconds $((MIN_IDLE_TIME * 60))"
    fi
    echo "[DRY RUN] perch maint restart ${PERCH_DEADLINE_FIREDANCER}, if the host runs perch"
    echo "[DRY RUN] systemctl stop firedancer; systemctl disable firedancer"
    echo "[DRY RUN] firedancer configure fini all (release the huge pages)"
    echo "[DRY RUN] copy vote history from ${FD_BASE} to ${AGAVE_LEDGER}"
    echo "[DRY RUN] systemctl enable ${AGAVE_SERVICE}; systemctl start ${AGAVE_SERVICE}"
    $USES_JAG_SNAP && echo "[DRY RUN] start the jag-snap container and reopen ${JAG_SNAP_PORT}/tcp"
    echo "[DRY RUN] put perch's config from before Firedancer back, if there is one"
    echo "[DRY RUN] stop perch reading Firedancer's metrics, if it was"
    exit 0
  fi

  need_sudo
  echo ""
  log_warn "This stops Firedancer on ${SOL_HOST} and starts ${SOURCE_LABEL} from ${VALIDATOR_SH}."
  confirm "Roll ${SOL_HOST} back to Agave?" || { log_info "Nothing changed"; exit 0; }

  WAIT_STEP=""
  if [[ "$(fact fd_active)" == "active" ]] && ! $NOW; then
    log_info "Waiting for a window with no leader slot within ${MIN_IDLE_TIME} minutes"
    WAIT_STEP="${FD_BIN} wait --config ${FD_CONFIG} --min-idle-seconds $((MIN_IDLE_TIME * 60))"
  fi

  root_script <<SCRIPT
set -e
${WAIT_STEP}
$(perch_maint_cmd "$SOL_USER" "$PERCH_DEADLINE_FIREDANCER" root)
systemctl stop firedancer || true
systemctl disable firedancer >/dev/null 2>&1 || true
echo "firedancer.service stopped and disabled"

# Agave needs the memory Firedancer reserved as huge pages
${FD_BIN} configure fini all --config ${FD_CONFIG} >/dev/null 2>&1 || echo "configure fini did not complete — check 'grep Huge /proc/meminfo'"

for f in ${FD_BASE}/vote_history-*.bin; do
  [ -f "\$f" ] || continue
  cp -a "\$f" "${AGAVE_LEDGER}/"
  $(fd_chown_cmd "$SOL_USER") "${AGAVE_LEDGER}/\$(basename "\$f")"
  echo "carried back \$(basename "\$f")"
done

systemctl enable ${AGAVE_SERVICE} >/dev/null 2>&1
systemctl start ${AGAVE_SERVICE}
echo "${AGAVE_SERVICE}.service started"

$(perch_local_rpc_on_cmd "$SOL_USER")
$(perch_firedancer_off_cmd "$SOL_USER")
if ${USES_JAG_SNAP}; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow ${JAG_SNAP_PORT}/tcp >/dev/null
    echo "ufw: reopened ${JAG_SNAP_PORT}/tcp"
  fi
  if command -v docker >/dev/null 2>&1 && docker inspect jag-snap >/dev/null 2>&1; then
    docker update --restart unless-stopped jag-snap >/dev/null
    docker start jag-snap >/dev/null
    echo "jag-snap started"
  else
    echo "no jag-snap container on this host — rebuild it to serve snapshots again"
  fi
fi
SCRIPT

  echo ""
  log_info "rollback complete — ${SOURCE_LABEL} is starting"
  log_info "  ${SSH_CMD} ${SOL_HOST} 'solana catchup --our-localhost'"
  if [[ "$SOURCE" == "hexis" ]]; then
    log_info "The arb boots disabled on Agave. Once it has caught up:"
    log_info "  ${SSH_CMD} ${SOL_HOST} '$(dirname "$(fd_vsh_flag "$VSH" "--arb-config")")/arb-enable.sh'"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# upgrade
# ---------------------------------------------------------------------------

# fd_restart_onto <release the running process came from> <label of the new one>
# Waits for a window with the binary that is running — the new one may not read
# the old one's shared memory — then restarts the unit and reports the result.
fd_restart_onto() {
  local old_release="$1" label="$2" wait_bin="$FD_BIN" wait_step="" log_step=""
  [[ -n "$old_release" ]] && wait_bin="${FD_DIR}/releases/${old_release}/firedancer"

  if $DRY_RUN; then
    fd_prefetch_snapshot ""
    if [[ "$(fact fd_active)" == "active" ]] && ! $NOW; then
      echo "[DRY RUN] ${wait_bin} wait --min-idle-seconds $((MIN_IDLE_TIME * 60))"
    fi
    echo "[DRY RUN] perch maint restart ${PERCH_DEADLINE_FIREDANCER}, if the host runs perch"
    echo "[DRY RUN] systemctl restart firedancer (onto ${label})"
    return 0
  fi

  echo ""
  log_warn "This restarts Firedancer on ${SOL_HOST} onto ${label}, with"
  log_warn "  identity          ${IDENTITY_LABEL}"
  log_warn "Firedancer loads a snapshot on every start, so the validator is not voting until"
  log_warn "that has loaded and it has caught up. The full snapshot is fetched first, while it"
  log_warn "still runs; if that cannot be done, the start downloads it (about an hour)."
  if ! confirm "Restart Firedancer on ${SOL_HOST}?"; then
    log_warn "Not restarted. ${label} is staged and is what the next start runs;"
    log_warn "  $0 upgrade --previous puts the earlier release back."
    return 0
  fi

  fd_prefetch_snapshot ""

  if [[ "$(fact fd_active)" == "active" ]] && ! $NOW; then
    log_info "Waiting for a window with no leader slot within ${MIN_IDLE_TIME} minutes"
    wait_step="test -x ${wait_bin} && ${wait_bin} wait --config ${FD_CONFIG} --min-idle-seconds $((MIN_IDLE_TIME * 60))"
  fi
  local log_path
  log_path=$(fd_toml_get "$(probe "cat ${FD_CONFIG}")" "path")
  [[ -n "$log_path" ]] && log_step=$(fd_render_logrotate_install "$log_path")

  root_script <<SCRIPT
set -e
${wait_step}
$(perch_maint_cmd "$SOL_USER" "$PERCH_DEADLINE_FIREDANCER" root)
${log_step}
$(fd_render_nofile_sysctl)
systemctl daemon-reload
systemctl reset-failed firedancer 2>/dev/null || true
if ! systemctl restart firedancer; then
  echo "firedancer.service failed to start:"
  journalctl -u firedancer --no-pager -n 25
  echo "Back to the release that ran before: $0 upgrade --previous --host ${SSH_HOST} --ssh-key ${SSH_KEY}"
  exit 1
fi
echo "firedancer.service restarted"
SCRIPT

  echo ""
  log_info "============================================"
  log_info "upgrade complete — Firedancer is booting on ${label}"
  log_info "============================================"
  log_info "  ${SSH_CMD} -t ${ADMIN_HOST} 'sudo journalctl -u firedancer -f'"
  log_info "Back to the release that ran before:"
  log_info "  $0 upgrade --previous --host ${SSH_HOST} --ssh-key ${SSH_KEY}"
}

if [[ "$MODE" == "upgrade" ]]; then
  if [[ "$(fact fd_unit)" != "yes" || "$(fact fd_config)" != "yes" || -z "$(fact fd_release)" ]]; then
    log_error "Firedancer is not installed on ${SOL_HOST} — use '$0 stage' and then 'cutover'"
    exit 1
  fi
  if [[ "$(fact fd_enabled)" != "enabled" ]]; then
    log_error "Firedancer is staged on ${SOL_HOST} but ${RUNNING} is what runs there."
    log_error "  upgrade is for a host already on Firedancer. To stage a newer release: '$0 stage --fd-tag ...'"
    exit 1
  fi
  OLD_RELEASE="$(fact fd_release)"
  log_info "Firedancer release now: ${OLD_RELEASE} ($(fact fd_version))"
fi

if [[ "$MODE" == "upgrade" ]] && $FD_PREVIOUS; then
  PREV_RELEASE=$(probe "cat ${FD_PREVIOUS_FILE} 2>/dev/null")
  if [[ -z "$PREV_RELEASE" ]]; then
    log_error "No earlier release is recorded in ${FD_PREVIOUS_FILE} — nothing to go back to"
    exit 1
  fi
  if [[ "$PREV_RELEASE" == "$OLD_RELEASE" ]]; then
    log_info "${PREV_RELEASE} is already the staged release"
    exit 0
  fi
  PREV_BIN="${FD_DIR}/releases/${PREV_RELEASE}/firedancer"
  if [[ "$(probe "test -x ${PREV_BIN} && echo yes")" != "yes" ]]; then
    log_error "${PREV_BIN} is no longer on ${SOL_HOST}"
    exit 1
  fi
  log_info "Going back: ${OLD_RELEASE} -> ${PREV_RELEASE}"

  if $DRY_RUN; then
    echo "[DRY RUN] check ${FD_CONFIG} with ${PREV_BIN} mem"
    echo "[DRY RUN] point ${FD_BIN} at releases/${PREV_RELEASE}/firedancer"
  else
    need_sudo
    # A config refreshed for the newer release may carry keys the older one refuses
    CHECK=$(mem_check "$FD_CONFIG" "$PREV_BIN")
    if ! grep -q "Total Memory Locked" <<<"$CHECK"; then
      log_error "${PREV_RELEASE} does not accept ${FD_CONFIG} — nothing has been changed:"
      echo "$CHECK"
      log_error "Put back the config it ran with (${FD_CONFIG}.bak.*) and run this again"
      exit 1
    fi
    sol_script <<SCRIPT
set -e
cd ${FD_DIR}
ln -s "releases/${PREV_RELEASE}/firedancer" .firedancer.next
mv -T .firedancer.next firedancer
echo "${OLD_RELEASE}" > ${FD_PREVIOUS_FILE}
echo "active: \$(readlink firedancer)"
SCRIPT
  fi
  fd_restart_onto "$OLD_RELEASE" "$PREV_RELEASE"
  exit 0
fi

# ===========================================================================
# stage  (and the staging half of upgrade)
# ===========================================================================

# --- Hardware and OS -------------------------------------------------------
log_info "Host: $(fact model), $(fact mem_gib) GiB RAM, glibc $(fact glibc)"

if [[ -z "$FD_ASSET" ]]; then
  FD_ASSET=$(fd_pick_asset "$(fact vendor)" "$(fact family)" "$(fact flags)") || {
    log_error "This CPU has no AVX2 — no Hexis Firedancer build runs on it"
    exit 1
  }
fi
log_info "Build: ${FD_ASSET}"

if [[ -n "$(fact glibc)" ]] && ! fd_version_ge "$(fact glibc)" "$FD_MIN_GLIBC"; then
  log_error "glibc $(fact glibc) is older than the ${FD_MIN_GLIBC} this build needs (Ubuntu 24.04 or newer)"
  exit 1
fi

# --- What the Agave setup tells us ------------------------------------------
reject_placeholder() {
  if [[ "$2" == *"FILL_IN"* ]]; then
    log_error "${VALIDATOR_SH} still has a placeholder for $1: $2"
    log_error "  Fill it in there, or pass the value to this script"
    exit 1
  fi
}

FDC_USER="$FD_USER"
FDC_IDENTITY="$AGAVE_IDENTITY"
FDC_VOTE_ACCOUNT=$(fd_vsh_flag "$VSH" "--vote-account")
FDC_AUTH_VOTERS=$(fd_vsh_flag_all "$VSH" "--authorized-voter" | grep -vxF "$AGAVE_IDENTITY" | paste -sd, - || true)
FDC_ENTRYPOINTS=$(fd_vsh_flag_all "$VSH" "--entrypoint" | paste -sd, -)
FDC_GENESIS_HASH=$(fd_vsh_flag "$VSH" "--expected-genesis-hash")
FDC_SHRED_VERSION=$(fd_vsh_flag "$VSH" "--expected-shred-version")
FDC_INTERFACE="$FD_INTERFACE"
FDC_RPC="$FD_ENABLE_RPC"

if [[ -z "$FDC_VOTE_ACCOUNT" ]]; then
  log_warn "No --vote-account in ${VALIDATOR_SH} — Firedancer will not vote"
fi
if [[ -z "$FDC_ENTRYPOINTS" || -z "$FDC_GENESIS_HASH" ]]; then
  log_error "Could not find --entrypoint and --expected-genesis-hash in ${VALIDATOR_SH}"
  exit 1
fi
if [[ "$FDC_GENESIS_HASH" != "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d" ]]; then
  log_error "The Hexis Concorde is mainnet only, and ${VALIDATOR_SH} is not a mainnet config"
  exit 1
fi

AGAVE_ACCOUNTS=$(fd_vsh_flag "$VSH" "--accounts")
FDC_BASE="${FD_BASE:-${AGAVE_LEDGER}/firedancer}"
FDC_ACCOUNTS="${FD_ACCOUNTS:-${AGAVE_ACCOUNTS:-${AGAVE_LEDGER}}/firedancer/accounts.db}"
# Not Agave's snapshot directory: Firedancer prunes the one it is given, and a
# rollback wants Agave's own snapshots still there.
FDC_SNAPSHOTS="${FDC_BASE}/snapshots"
FDC_LOG="${FDC_BASE}/firedancer.log"

# Snapshot sources: keep the trust the operator already chose, when it is wide
# enough to boot from. Hexis asks for three or more, or Firedancer's default.
KNOWN_VALIDATORS=$(fd_vsh_flag_all "$VSH" "--known-validator" | paste -sd, - || true)
KNOWN_COUNT=$(fd_vsh_flag_all "$VSH" "--known-validator" | grep -c . || true)
FDC_SNAPSHOT_ALLOW_LIST=""
if ! $FD_SNAPSHOT_ALLOW_ANY && (( KNOWN_COUNT >= 3 )); then
  FDC_SNAPSHOT_ALLOW_LIST="$KNOWN_VALIDATORS"
fi

# Block Engine
FDC_BUNDLE_URL=""
if ! $FD_NO_BLOCK_ENGINE; then
  FDC_BUNDLE_URL="${FD_BUNDLE_URL:-$(fd_vsh_flag "$VSH" "--block-engine-url")}"
  reject_placeholder "--block-engine-url" "$FDC_BUNDLE_URL"
  if [[ -z "$FDC_BUNDLE_URL" ]]; then
    log_error "${VALIDATOR_SH} has no --block-engine-url. Pass --block-engine-url <url> for the region"
    log_error "  closest to this host, or --no-block-engine to run with no bundles"
    exit 1
  fi
  FDC_TIP_PAY=$(fd_vsh_flag "$VSH" "--tip-payment-program-pubkey");       FDC_TIP_PAY="${FDC_TIP_PAY:-$FD_TIP_PAYMENT_PROGRAM}"
  FDC_TIP_DIST=$(fd_vsh_flag "$VSH" "--tip-distribution-program-pubkey"); FDC_TIP_DIST="${FDC_TIP_DIST:-$FD_TIP_DISTRIBUTION_PROGRAM}"
  FDC_TIP_AUTH=$(fd_vsh_flag "$VSH" "--merkle-root-upload-authority");    FDC_TIP_AUTH="${FDC_TIP_AUTH:-$FD_TIP_DISTRIBUTION_AUTHORITY}"
  FDC_COMMISSION_BPS="${FD_COMMISSION_BPS:-$(fd_vsh_flag "$VSH" "--commission-bps")}"
  if [[ -z "$FDC_COMMISSION_BPS" ]]; then
    log_error "No Jito tip commission to carry over — pass --commission-bps <bps>"
    exit 1
  fi
fi

# Shred receivers
if $FD_SHRED_DESTS_SET; then
  FDC_SHRED_DESTS="$FD_SHRED_DESTS"
else
  FDC_SHRED_DESTS=$(fd_vsh_flag_all "$VSH" "--shred-receiver-address" | paste -sd, - || true)
fi
reject_placeholder "--shred-receiver-address" "$FDC_SHRED_DESTS"
FDC_RSS_SIMPLE=false
[[ "$FDC_SHRED_DESTS" == *"${FD_DOUBLEZERO_GROUP}:"* ]] && FDC_RSS_SIMPLE=true

FDC_METRICS_ADDR="${FD_METRICS_ADDR:-$(fact ip)}"
if [[ -z "$FDC_METRICS_ADDR" ]]; then
  log_error "Could not work out this host's IPv4 — pass --metrics-address"
  exit 1
fi

# --- Arb signer and token ledgers --------------------------------------------
ARB_CONFIG_PATH=""
ARB_CONFIG_TEXT=""
SIGNER_FROM=""       # host path | upload | generate | keep
if [[ "$SOURCE" == "hexis" ]]; then
  ARB_CONFIG_PATH=$(fd_vsh_flag "$VSH" "--arb-config")
  ARB_CONFIG_TEXT=$(probe "cat ${ARB_CONFIG_PATH}")
fi

if [[ -n "$FD_SIGNER" ]]; then
  SIGNER_FROM="upload"
elif $FD_GENERATE_SIGNER; then
  SIGNER_FROM="generate"
elif [[ "$(fact fd_signer)" == "yes" ]]; then
  SIGNER_FROM="keep"
elif [[ -n "$ARB_CONFIG_TEXT" ]]; then
  SIGNER_FROM=$(fd_toml_get "$ARB_CONFIG_TEXT" "signer_path")
fi
if [[ -z "$SIGNER_FROM" ]]; then
  log_error "No arb signer: ${SOURCE_LABEL} has none to reuse. Pass --hexis-signer <signing_key.json>,"
  log_error "  or --generate-signer to make one (flash loans stay off until Hexis has its MarginFi account)"
  exit 1
fi

# Token ledgers travel with the signer: the ones in arb-config.toml, or the
# Hexis defaults when the signer is the one Hexis issues.
JUP_LEDGER=""; OKX_LEDGER=""
if [[ -n "$ARB_CONFIG_TEXT" ]]; then
  JUP_LEDGER=$(fd_toml_get "$ARB_CONFIG_TEXT" "jupiter_token_ledger")
  OKX_LEDGER=$(fd_toml_get "$ARB_CONFIG_TEXT" "okx_token_ledger")
elif [[ "$SIGNER_FROM" == "upload" ]]; then
  JUP_LEDGER="$HEXIS_JUPITER_TOKEN_LEDGER"
  OKX_LEDGER="$HEXIS_OKX_TOKEN_LEDGER"
fi
$FD_JUPITER_LEDGER_SET && JUP_LEDGER="$FD_JUPITER_LEDGER"
$FD_OKX_LEDGER_SET && OKX_LEDGER="$FD_OKX_LEDGER"

# --- The Concorde's own tables ------------------------------------------------
if [[ -n "$FD_CONCORDE_TABLES" ]]; then
  CONCORDE_TEXT=$(cat "$FD_CONCORDE_TABLES")
else
  log_info "Fetching the Concorde config tables from ${HEXIS_REPO} (${FD_DOCS_BRANCH})"
  CONCORDE_TEXT=$(fd_fetch_concorde_tables) || { log_error "Could not fetch config.toml.example — pass --concorde-tables <path>"; exit 1; }
fi
if ! grep -q '^\[arb\]' <<<"$CONCORDE_TEXT" || ! grep -qE '^[[:space:]]*signer_key_path[[:space:]]*=' <<<"$CONCORDE_TEXT"; then
  log_error "The Concorde config tables have no [arb] table with signer_key_path — refusing to guess"
  exit 1
fi

CONFIG_TEXT="$(fd_render_base_config reawaken.sh)

$(fd_render_concorde_tables "$CONCORDE_TEXT" "$FD_SIGNER_PATH" "$JUP_LEDGER" "$OKX_LEDGER")"

# --- Plan ------------------------------------------------------------------
echo ""
if [[ "$MODE" == "upgrade" ]]; then
  log_info "Plan for ${SOL_HOST} (Firedancer ${OLD_RELEASE} -> ${FD_TAG:-$(basename "$FD_BINARY")}; settings from ${VALIDATOR_SH}):"
else
  log_info "Plan for ${SOL_HOST} (${SOURCE_LABEL} -> Firedancer with the Concorde):"
fi
log_info "  Identity:       ${IDENTITY_LABEL}"
log_info "  Vote account:   ${FDC_VOTE_ACCOUNT:-none}"
for voter in $AGAVE_VOTERS; do
  log_info "  Auth voter:     $(fd_key_label "$KEY_INFO" "$voter")"
done
log_info "  Data:           ${FDC_BASE}   accounts: ${FDC_ACCOUNTS}"
log_info "  Runs as:        ${FDC_USER} (after starting as root)"
if [[ -n "$FDC_BUNDLE_URL" ]]; then
  log_info "  Block Engine:   ${FDC_BUNDLE_URL}  commission ${FDC_COMMISSION_BPS} bps"
  if [[ "$FDC_TIP_AUTH" != "$FD_TIP_DISTRIBUTION_AUTHORITY" ]]; then
    log_warn "  Tip authority:  ${FDC_TIP_AUTH}, carried over from ${VALIDATOR_SH}."
    log_warn "                  The Hexis Firedancer docs use ${FD_TIP_DISTRIBUTION_AUTHORITY} — confirm which is current"
  fi
else
  log_warn "  Block Engine:   OFF — no bundles, no bundle tips"
fi
log_info "  Leader shreds:  ${FDC_SHRED_DESTS:-none}"
if [[ -n "$FDC_SNAPSHOT_ALLOW_LIST" ]]; then
  log_info "  Snapshots from: the ${KNOWN_COUNT} known validators in ${VALIDATOR_SH}"
else
  log_info "  Snapshots from: any gossip peer (Firedancer's default)"
fi
log_info "  Metrics:        ${FDC_METRICS_ADDR}:${FD_METRICS_PORT}  (open to ${FD_METRICS_ALLOW})"
log_info "  Control:        port ${FD_CONTROL_PORT}  (open to ${FD_CONTROL_ALLOW})"
case "$SIGNER_FROM" in
  upload)   log_info "  Arb signer:     ${FD_SIGNER} (uploaded)" ;;
  generate) log_warn "  Arb signer:     generated on the host — fund it; flash loans off until Hexis has its MarginFi account" ;;
  keep)     log_info "  Arb signer:     ${FD_SIGNER_PATH} (already installed)" ;;
  *)        log_info "  Arb signer:     ${SIGNER_FROM} (the Hexis Agave signer)" ;;
esac
log_info "  Token ledgers:  jupiter ${JUP_LEDGER:-none}, okx ${OKX_LEDGER:-none}"
if $FD_ENABLE_RPC; then
  log_info "  RPC:            on (127.0.0.1:8899)"
else
  log_warn "  RPC:            off — anything reading 127.0.0.1:8899 on this host (solana catchup) stops working"
fi
log_warn "  Snapshots:      none made or served. Cutover and upgrade fetch the full one before the restart"
if $USES_JAG_SNAP; then
  log_warn "  jag-snap:       retired at cutover (container stopped, ${JAG_SNAP_PORT}/tcp closed); rollback brings it back"
fi
echo ""

if $DRY_RUN; then
  echo "[DRY RUN] ${FD_CONFIG} would be:"
  echo "$CONFIG_TEXT"
  echo ""
  echo "[DRY RUN] ${FD_UNIT} would be:"
  fd_render_unit "$FD_BIN" "$FD_CONFIG" "$AGAVE_SERVICE"
  echo ""
  [[ "$MODE" == "upgrade" ]] && fd_restart_onto "$OLD_RELEASE" "${FD_TAG:-$(basename "$FD_BINARY")}"
  echo "[DRY RUN] nothing was changed on ${SOL_HOST}"
  exit 0
fi

need_sudo

# --- Binary ------------------------------------------------------------------
DL_DIR=""
cleanup() { [[ -n "$DL_DIR" ]] && rm -rf "$DL_DIR"; return 0; }
trap cleanup EXIT

if [[ -n "$FD_TAG" ]]; then
  log_info "Downloading ${FD_ASSET} from ${FD_TAG}"
  DL_DIR=$(mktemp -d)
  FD_BINARY=$(fd_download "$FD_TAG" "$FD_ASSET" "$DL_DIR") || exit 1
fi

if [[ -n "$FD_BINARY" ]]; then
  remote "mkdir -p ${FD_DIR}/releases && chmod 750 ${FD_DIR}"
  sol_write_file "${FD_DIR}/firedancer.incoming" 755 < "$FD_BINARY"

  NEW_VERSION=$(probe "${FD_DIR}/firedancer.incoming version 2>/dev/null | head -1")
  if [[ -z "$NEW_VERSION" ]]; then
    log_error "The uploaded binary does not run on this host — nothing has been changed"
    log_error "  local file: ${FD_BINARY}"
    WHY=$(probe "${FD_DIR}/firedancer.incoming version 2>&1 | head -5; echo \"exit code \${PIPESTATUS[0]}\"")
    if [[ -z "$WHY" ]]; then
      log_error "  no response from ${SOL_HOST} — the SSH connection probably dropped. Re-run once it is back"
      exit 1
    fi
    while IFS= read -r line; do log_error "  host says: ${line}"; done <<< "$WHY"
    log_error "  (an Illegal instruction means the build is for a newer CPU — try --fd-asset firedancer-linux-amd64)"
    remote "rm -f ${FD_DIR}/firedancer.incoming"
    exit 1
  fi
  RELEASE_NAME="${FD_TAG:-${NEW_VERSION%% *}}"
  log_info "Staging ${RELEASE_NAME} (${NEW_VERSION})"

  # Versioned directory plus an atomically renamed symlink, as ascend.sh does. A
  # running Firedancer keeps its open inode until it exits.
  sol_script <<SCRIPT
set -e
cd ${FD_DIR}
mkdir -p "releases/${RELEASE_NAME}"
mv firedancer.incoming "releases/${RELEASE_NAME}/firedancer"
# Remembered for 'upgrade --previous'
was="\$(readlink firedancer 2>/dev/null | sed -e 's|^releases/||' -e 's|/firedancer\$||')"
if [ -n "\$was" ] && [ "\$was" != "${RELEASE_NAME}" ]; then echo "\$was" > ${FD_PREVIOUS_FILE}; fi
ln -s "releases/${RELEASE_NAME}/firedancer" .firedancer.next
mv -T .firedancer.next firedancer
echo "active: \$(readlink firedancer)"
SCRIPT
elif [[ -z "$(fact fd_release)" ]]; then
  log_error "No Firedancer binary on ${SOL_HOST} yet — pass --fd-tag or --fd-binary"
  exit 1
else
  log_info "Keeping the staged binary: $(fact fd_release) ($(fact fd_version))"
fi

# --- Directories and the arb signer --------------------------------------------
if [[ "$SIGNER_FROM" == "upload" ]]; then
  # Streamed over SSH and created mode 600 — never readable by anyone else
  sol_write_file "${FD_SIGNER_PATH}.incoming" 600 < "$FD_SIGNER"
fi

case "$SIGNER_FROM" in
  upload)   SIGNER_STEP="install -o root -g root -m 0600 ${FD_SIGNER_PATH}.incoming ${FD_SIGNER_PATH} && rm -f ${FD_SIGNER_PATH}.incoming" ;;
  generate) SIGNER_STEP="test -e ${FD_SIGNER_PATH} || ${FD_BIN} keys new ${FD_SIGNER_PATH}; chown root:root ${FD_SIGNER_PATH}; chmod 0600 ${FD_SIGNER_PATH}" ;;
  keep)     SIGNER_STEP="true" ;;
  *)        SIGNER_STEP="install -o root -g root -m 0600 ${SIGNER_FROM} ${FD_SIGNER_PATH}" ;;
esac

log_info "Preparing directories and the arb signer"
root_script <<SCRIPT
set -e
if ! id -u ${FDC_USER} >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin ${FDC_USER}
  echo "created user ${FDC_USER}"
fi
mkdir -p "${FDC_BASE}" "${FDC_SNAPSHOTS}" "\$(dirname "${FDC_ACCOUNTS}")"
$(fd_chown_cmd "$FDC_USER") "${FDC_BASE}" "${FDC_SNAPSHOTS}" "\$(dirname "${FDC_ACCOUNTS}")"
chmod ${FD_SNAPSHOTS_MODE} "${FDC_SNAPSHOTS}"

# Firedancer reads the signer as root at boot, before it drops privileges
${SIGNER_STEP}
echo "arb signer: \$(${FD_BIN} keys pubkey ${FD_SIGNER_PATH} 2>/dev/null || echo unreadable)"
SCRIPT

# --- Config: write, check against the real binary, then install -----------------
printf '%s\n' "$CONFIG_TEXT" | sol_write_file "${FD_CONFIG}.new" 640

log_info "Checking the config with 'firedancer mem'"
CHECK=$(mem_check "${FD_CONFIG}.new")
if ! grep -q "Total Memory Locked" <<<"$CHECK"; then
  log_error "Firedancer rejects the generated config — it has NOT been installed:"
  echo "${CHECK:-  (no output — the SSH connection may have dropped)}"
  log_error "Left for inspection at ${FD_CONFIG}.new"
  exit 1
fi
while IFS= read -r line; do log_info "  $(sed -E 's/^ +//; s/ +/ /g' <<<"$line")"; done < <(grep -E "Total|Required" <<<"$CHECK")

HUGE_PAGE_OUTLOOK=$(huge_page_outlook "$(required_gigantic_pages "$CHECK")")
LOCKED_GIB=$(grep -m1 "Total Memory Locked" <<<"$CHECK" | grep -oE '[0-9]+ GiB' | head -1 | grep -oE '[0-9]+' || true)
MEM_GIB=$(fact mem_gib)
if [[ -n "$LOCKED_GIB" && -n "$MEM_GIB" ]]; then
  if (( LOCKED_GIB + 16 > MEM_GIB )); then
    log_error "Firedancer locks ${LOCKED_GIB} GiB and this host has ${MEM_GIB} GiB — it will not start"
    exit 1
  elif (( LOCKED_GIB * 100 > MEM_GIB * 75 )); then
    log_warn "Firedancer locks ${LOCKED_GIB} GiB of this host's ${MEM_GIB} GiB — little is left for anything else"
  fi
fi

if [[ "$(fact fd_config)" == "yes" ]]; then
  DIFF_OUT=$(probe "diff -u ${FD_CONFIG} ${FD_CONFIG}.new")
  if [[ -z "$DIFF_OUT" ]]; then
    log_info "${FD_CONFIG} is unchanged"
    remote "rm -f ${FD_CONFIG}.new"
  else
    echo ""
    echo "$DIFF_OUT"
    echo ""
    if confirm "Replace ${FD_CONFIG} with this?"; then
      remote "cp -a ${FD_CONFIG} ${FD_CONFIG}.bak.\$(date +%Y%m%d%H%M%S) && mv ${FD_CONFIG}.new ${FD_CONFIG}"
      log_info "Config replaced — the previous one is kept as ${FD_CONFIG}.bak.*"
    else
      remote "rm -f ${FD_CONFIG}.new"
      log_warn "Left ${FD_CONFIG} as it was"
    fi
  fi
else
  remote "mv ${FD_CONFIG}.new ${FD_CONFIG}"
  log_info "Config installed at ${FD_CONFIG}"
fi

# --- systemd unit and firewall -----------------------------------------------
UNIT_TEXT="$(fd_render_unit "$FD_BIN" "$FD_CONFIG" "$AGAVE_SERVICE")"
UFW_RULES=""
for src in $FD_CONTROL_ALLOW; do
  UFW_RULES+="ufw allow from ${src} to any port ${FD_CONTROL_PORT} proto tcp >/dev/null
"
done
UFW_RULES+="ufw allow from ${FD_METRICS_ALLOW} to any port ${FD_METRICS_PORT} proto tcp >/dev/null
"
for port in $FD_P2P_UDP_PORTS; do
  UFW_RULES+="ufw allow ${port}/udp >/dev/null
"
done

log_info "Installing firedancer.service (not enabled), log rotation and the firewall rules"
root_script <<SCRIPT
set -e
cat > ${FD_UNIT} <<'UNITEOF'
${UNIT_TEXT}
UNITEOF
$(fd_render_logrotate_install "$FDC_LOG")
$(fd_render_nofile_sysctl)
systemctl daemon-reload
echo "firedancer.service installed — enabled: \$(systemctl is-enabled firedancer 2>/dev/null || true)"

if ufw status 2>/dev/null | grep -q "Status: active"; then
${UFW_RULES}  echo "ufw: Control ${FD_CONTROL_PORT} from ${FD_CONTROL_ALLOW}; metrics ${FD_METRICS_PORT} from ${FD_METRICS_ALLOW}; p2p udp ${FD_P2P_UDP_PORTS}"
else
  echo "ufw is not active — firewall ${FD_CONTROL_PORT}/tcp and ${FD_METRICS_PORT}/tcp to the Hexis addresses yourself"
fi
SCRIPT

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$MODE" == "upgrade" ]]; then
  # Config and signer are checked above; the config must also pass with the new binary
  CHECK=$(mem_check "$FD_CONFIG")
  if ! grep -q "Total Memory Locked" <<<"$CHECK"; then
    log_error "${FD_CONFIG} does not pass 'firedancer mem' with the new release — not restarting:"
    echo "$CHECK"
    exit 1
  fi
  fd_restart_onto "$OLD_RELEASE" "$(probe "readlink ${FD_BIN}" | sed -e 's|^releases/||' -e 's|/firedancer$||')"
  exit 0
fi

echo ""
log_info "============================================"
log_info "stage complete — ${RUNNING} is still what runs on ${SOL_HOST}"
log_info "============================================"
log_info "Staged:  ${FD_BIN} -> $(probe "readlink ${FD_BIN}")"
log_info "         ${FD_CONFIG}, ${FD_SIGNER_PATH}, ${FD_UNIT}"
log_info ""
[[ -n "${HUGE_PAGE_OUTLOOK:-}" ]] && log_info "Huge pages: ${HUGE_PAGE_OUTLOOK}"
log_info "Nothing was stopped or started. When you are ready:"
log_info "  $0 cutover --host ${SSH_HOST} --ssh-key ${SSH_KEY}"
log_info "and to go back to Agave afterwards:"
log_info "  $0 rollback --host ${SSH_HOST} --ssh-key ${SSH_KEY}"
