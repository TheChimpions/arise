#!/usr/bin/env bash
#
#   █████╗ ███████╗ ██████╗███████╗███╗   ██╗██████╗
#  ██╔══██╗██╔════╝██╔════╝██╔════╝████╗  ██║██╔══██╗
#  ███████║███████╗██║     █████╗  ██╔██╗ ██║██║  ██║
#  ██╔══██║╚════██║██║     ██╔══╝  ██║╚██╗██║██║  ██║
#  ██║  ██║███████║╚██████╗███████╗██║ ╚████║██████╔╝
#  ╚═╝  ╚═╝╚══════╝ ╚═════╝╚══════╝╚═╝  ╚═══╝╚═════╝
#
# Hexis arb client: upgrade an existing install, or migrate a running validator onto it.
#
#   ascend.sh upgrade   Swap the Hexis validator binary on a box that already runs it
#   ascend.sh migrate   Put the Hexis arb client onto an existing Jito/Agave validator
#
# Neither mode formats disks, tunes the kernel, or hardens SSH — that is arise.sh.
# Neither restarts the validator unless you pass --restart.
#
# See HEXIS-UPGRADE.md for the same procedure done by hand.

set -euo pipefail

# Shared Hexis defaults, logging and rendering helpers
HEXIS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hexis.sh"
if [[ ! -f "$HEXIS_LIB" ]]; then
  echo "Missing $HEXIS_LIB — run this from a checkout, not as a lone copied file" >&2
  exit 1
fi
# shellcheck source=lib/hexis.sh
source "$HEXIS_LIB"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MODE=""
STAGE_ONLY=false
PROMOTE_RELEASE=""
LIST_RELEASES=false
SSH_HOST=""
SSH_KEY=""
SOL_USER="sol"
HEXIS_DIR=""                 # defaults to /home/$SOL_USER/hexis
VALIDATOR_SH=""              # defaults to /home/$SOL_USER/validator.sh
LEDGER_PATH=""               # parsed out of validator.sh when not given
DRY_RUN=false
ASSUME_YES=false
RESTART=false
MIN_IDLE_TIME="20"
MAX_DELINQUENT_STAKE="5"
SKIP_SNAPSHOT_CHECK=true
METRICS_CONFIG=""            # set after the lib is sourced; "" means leave it alone
METRICS_CONFIG_SET=false
FIX_METRICS=false

# Config defaults live in lib/hexis.sh; these are the ascend-only knobs.
HEXIS_TAG=""
HEXIS_BINARY=""
HEXIS_SETUP_BINARY=""
HEXIS_CONFIG=""              # arb-config.toml to upload verbatim
HEXIS_SIGNER=""
HEXIS_CONTROL=true


usage() {
  cat <<EOF
Usage: $0 <upgrade|migrate|promote> [OPTIONS]

Modes:
  upgrade   Stage a new Hexis validator release and make it active. Releases live
            in <hexis-dir>/releases/<tag>/ and <hexis-dir>/agave-validator is a
            symlink to the active one, so validator.sh never needs editing.
  migrate   Install the Hexis arb client onto a validator that is already
            running (Jito or plain Agave) and patch its validator.sh.
  promote   Point the symlink at an already-staged release, or roll back to an
            older one. Takes effect on the next restart.

Staging (upgrade):
  --stage-only                  Upload the release but leave the symlink alone, so
                                an unplanned restart still comes up on the current
                                version. Activate later with '$0 promote'
Promote:
  --release <name>              Release directory to activate
  --list                        List staged releases and exit

Required:
  --host <ip-or-hostname>       Validator host
  --ssh-key <path>              SSH private key for the sol user

Binary source (upgrade always, migrate always):
  --hexis-tag <tag>             Release tag, fetched with your local gh CLI and
                                verified against the release checksums
  --hexis-binary <path>         Pre-downloaded agave-validator binary instead
  --hexis-setup-tag <tag>       hexis-setup release (default: ${HEXIS_SETUP_TAG})
  --hexis-setup-binary <path>   Pre-downloaded hexis-setup binary

Paths:
  --user <name>                 Validator user (default: ${SOL_USER})
  --hexis-dir <path>            Install dir (default: /home/<user>/hexis)
  --validator-script <path>     Startup script (default: /home/<user>/validator.sh)
  --ledger <path>               Ledger dir (default: parsed from validator.sh)

Restart:
  --restart                     After installing, exit the validator gracefully so
                                systemd restarts it on the new binary
  --min-idle-time <min>         exit --min-idle-time (default: ${MIN_IDLE_TIME})
  --max-delinquent-stake <pct>  exit --max-delinquent-stake (default: ${MAX_DELINQUENT_STAKE})
  --skip-new-snapshot-check     Do not wait for a new snapshot before exiting (default)
  --wait-for-new-snapshot       Wait for a new snapshot before exiting

Cluster metrics:
  --metrics-config <str>        SOLANA_METRICS_CONFIG to add to validator.sh when it
                                has none. Defaults to the SFDP endpoint. Pass "" to
                                leave the file alone
  --fix-metrics                 Add that export to a validator.sh that is already
                                running Hexis and has no cluster metrics. Works in
                                any mode. Takes effect on the next restart

Config (migrate; upgrade only honours --hexis-config):
  --hexis-config <path>         Upload this arb-config.toml verbatim
  --hexis-signer <path>         Arb signer keypair — the signing_key.json Hexis gave
                                you. Generated when omitted
  --hexis-profit-wallet <pk>    Address the program pays profit into. Defaults to the
                                Hexis shared rewards pool
  --hexis-program-id <pubkey>
  --hexis-jup-key <key>
  --hexis-metrics-config <str>
  --hexis-lookup-tables <list>
  --hexis-jupiter-token-ledger <pubkey>
  --hexis-okx-token-ledger <pubkey>
  --hexis-base-mints <list>
  --hexis-marginfi-account <pk> marginfi v2 account for flash loans. Defaults to the
                                one from the Hexis config
  --no-hexis-flash-loans        Drop [flash_loan] entirely — flash loans off
  --hexis-marginfi-banks <list>
  --hexis-marginfi-program-id <pubkey>
  --hexis-control-bind <addr>   Default: ${HEXIS_CONTROL_BIND}
  --hexis-control-allow <cidr>  Default: ${HEXIS_CONTROL_ALLOW}
  --no-hexis-control            Skip the Control table and the firewall rule

Other:
  --yes                         Do not prompt before rewriting validator.sh
  --dry-run                     Print what would happen, change nothing
  -h, --help                    Show this help
EOF
  exit 1
}

[[ $# -eq 0 ]] && usage
case "$1" in
  upgrade|migrate|promote) MODE="$1"; shift ;;
  -h|--help)       usage ;;
  *) log_error "First argument must be 'upgrade', 'migrate' or 'promote'"; usage ;;
esac

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)            SSH_HOST="$2";  shift 2 ;;
    --ssh-key)         SSH_KEY="$2";   shift 2 ;;
    --user)            SOL_USER="$2";  shift 2 ;;
    --hexis-dir)       HEXIS_DIR="$2"; shift 2 ;;
    --validator-script) VALIDATOR_SH="$2"; shift 2 ;;
    --ledger)          LEDGER_PATH="$2"; shift 2 ;;
    --hexis-tag)       HEXIS_TAG="$2"; shift 2 ;;
    --hexis-binary)    HEXIS_BINARY="$2"; shift 2 ;;
    --hexis-setup-tag) HEXIS_SETUP_TAG="$2"; shift 2 ;;
    --hexis-setup-binary) HEXIS_SETUP_BINARY="$2"; shift 2 ;;
    --hexis-config)    HEXIS_CONFIG="$2"; shift 2 ;;
    --hexis-signer)    HEXIS_SIGNER="$2"; shift 2 ;;
    --hexis-profit-wallet) HEXIS_PROFIT_WALLET="$2"; shift 2 ;;
    --hexis-program-id) HEXIS_PROGRAM_ID="$2"; shift 2 ;;
    --hexis-jup-key)   HEXIS_JUP_KEY="$2"; shift 2 ;;
    --hexis-metrics-config) HEXIS_METRICS_CONFIG="$2"; shift 2 ;;
    --hexis-lookup-tables) HEXIS_LOOKUP_TABLES="$2"; shift 2 ;;
    --hexis-jupiter-token-ledger) HEXIS_JUPITER_TOKEN_LEDGER="$2"; shift 2 ;;
    --hexis-okx-token-ledger) HEXIS_OKX_TOKEN_LEDGER="$2"; shift 2 ;;
    --hexis-base-mints) HEXIS_BASE_MINTS="$2"; shift 2 ;;
    --hexis-marginfi-account) HEXIS_MARGINFI_ACCOUNT="$2"; shift 2 ;;
    --no-hexis-flash-loans) HEXIS_MARGINFI_ACCOUNT=""; shift ;;
    --hexis-marginfi-banks) HEXIS_MARGINFI_BANKS="$2"; shift 2 ;;
    --hexis-marginfi-program-id) HEXIS_MARGINFI_PROGRAM_ID="$2"; shift 2 ;;
    --hexis-control-bind) HEXIS_CONTROL_BIND="$2"; shift 2 ;;
    --hexis-control-allow) HEXIS_CONTROL_ALLOW="$2"; shift 2 ;;
    --no-hexis-control) HEXIS_CONTROL=false; shift ;;
    --stage-only)      STAGE_ONLY=true; shift ;;
    --release)         PROMOTE_RELEASE="$2"; shift 2 ;;
    --list)            LIST_RELEASES=true; shift ;;
    --restart)         RESTART=true;   shift ;;
    --min-idle-time)   MIN_IDLE_TIME="$2"; shift 2 ;;
    --max-delinquent-stake) MAX_DELINQUENT_STAKE="$2"; shift 2 ;;
    --skip-new-snapshot-check) SKIP_SNAPSHOT_CHECK=true; shift ;;
    --wait-for-new-snapshot) SKIP_SNAPSHOT_CHECK=false; shift ;;
    --metrics-config) METRICS_CONFIG="$2"; METRICS_CONFIG_SET=true; shift 2 ;;
    --fix-metrics)     FIX_METRICS=true; shift ;;
    --yes)             ASSUME_YES=true; shift ;;
    --dry-run)         DRY_RUN=true;   shift ;;
    -h|--help)         usage ;;
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
HEXIS_DIR="${HEXIS_DIR:-/home/${SOL_USER}/hexis}"
VALIDATOR_SH="${VALIDATOR_SH:-/home/${SOL_USER}/validator.sh}"

if [[ "$MODE" != "promote" && -z "$HEXIS_TAG" && -z "$HEXIS_BINARY" ]]; then
  log_error "One of --hexis-tag or --hexis-binary is required"
  exit 1
fi
if [[ -n "$HEXIS_TAG" && -n "$HEXIS_BINARY" ]]; then
  log_error "Pass either --hexis-tag or --hexis-binary, not both"
  exit 1
fi
if [[ -n "$HEXIS_TAG" ]]; then
  command -v gh &>/dev/null || { log_error "--hexis-tag needs the gh CLI locally"; exit 1; }
  # The download is a GitHub API call from THIS machine using gh's token
  gh auth status &>/dev/null || { log_error "gh is not authenticated — run 'gh auth login' with an account that can see ${HEXIS_REPO}"; exit 1; }
fi
for f in "$HEXIS_BINARY" "$HEXIS_SETUP_BINARY" "$HEXIS_CONFIG" "$HEXIS_SIGNER"; do
  [[ -n "$f" && ! -f "$f" ]] && { log_error "File not found: $f"; exit 1; }
done
if [[ "$HEXIS_CONTROL_BIND" == 127.0.0.1:* || "$HEXIS_CONTROL_BIND" == localhost:* ]]; then
  log_error "--hexis-control-bind must not be loopback — Hexis dials the host"
  exit 1
fi

# SFDP requires cluster metrics. Only defaulted when --metrics-config was not
# passed at all, so "" stays an explicit "leave validator.sh alone".
if ! $METRICS_CONFIG_SET && [[ -z "$METRICS_CONFIG" ]]; then
  METRICS_CONFIG="$SFDP_METRICS_MAINNET"
fi

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o IdentitiesOnly=yes -i $SSH_KEY"

# Copy-pasteable form of the connection these scripts make themselves.
# IdentitiesOnly stops ssh offering every agent key and tripping MaxAuthTries.
SSH_CMD="ssh -o IdentitiesOnly=yes -i ${SSH_KEY}"

# 'exit' waits for the restart window and then stops the validator. sol.service is
# Restart=always, so systemd brings it straight back on whatever the symlink points at.
EXIT_ARGS="exit --min-idle-time ${MIN_IDLE_TIME} --max-delinquent-stake ${MAX_DELINQUENT_STAKE}"
$SKIP_SNAPSHOT_CHECK && EXIT_ARGS+=" --skip-new-snapshot-check"

# perch_before_exit <binary> — on a host that runs perch, wait for the restart
# window and then declare the restart, so the watchtower does not page for it.
# The window comes first because perch's hold has a deadline and the wait for a
# window can outlast it; the exit that follows finds the window already open.
perch_before_exit() {
  remote "if [ -x /home/${SOL_USER}/perch/maint ]; then $1 --ledger ${LEDGER_PATH} wait-for-restart-window ${EXIT_ARGS#exit } && $(perch_maint_cmd "$SOL_USER" "$PERCH_DEADLINE_AGAVE"); fi"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
remote() {
  if $DRY_RUN; then
    echo "[DRY RUN] ssh $SOL_HOST: $*"
  else
    ssh $SSH_OPTS "$SOL_HOST" "$@"
  fi
}

# Always runs, even under --dry-run. For reads that must not be faked.
probe() { ssh $SSH_OPTS "$SOL_HOST" "$@" 2>/dev/null || true; }

sol_script() {
  if $DRY_RUN; then
    echo "[DRY RUN] sol_script on $SOL_HOST: <script>"
    cat
    return
  fi
  local tmpscript
  tmpscript=$(mktemp)
  cat > "$tmpscript"
  scp -q $SSH_OPTS "$tmpscript" "$SOL_HOST:/tmp/_ascend.sh"
  rm -f "$tmpscript"
  ssh $SSH_OPTS "$SOL_HOST" 'bash /tmp/_ascend.sh; rc=$?; rm -f /tmp/_ascend.sh; exit $rc'
}

root_script() {
  if $DRY_RUN; then
    echo "[DRY RUN] root_script on $SOL_HOST: <script>"
    cat
    return
  fi
  local tmpscript
  tmpscript=$(mktemp)
  cat > "$tmpscript"
  scp -q $SSH_OPTS "$tmpscript" "$SOL_HOST:/tmp/_ascend_root.sh"
  rm -f "$tmpscript"
  ssh $SSH_OPTS "$SOL_HOST" "echo '${SUDO_PASS:-}' | sudo -S bash /tmp/_ascend_root.sh; rc=\$?; rm -f /tmp/_ascend_root.sh; exit \$rc"
}

confirm() {
  $ASSUME_YES && return 0
  $DRY_RUN && return 1
  local reply
  read -rp "$1 [type 'yes' to continue]: " reply
  [[ "$reply" == "yes" ]]
}

# Flash-loan state as arb-config.toml on the host actually has it, not as our flags
# would have written it — upgrade and promote never regenerate that file.
hexis_flash_loan_account() {
  probe "grep -m1 '^marginfi_account' ${HEXIS_DIR}/arb-config.toml 2>/dev/null | sed -e 's/.*= *\"//' -e 's/\".*//'"
}

keygen_path() {
  probe "for p in \
    /home/${SOL_USER}/.local/share/solana/install/releases/active_release/bin/solana-keygen \
    /home/${SOL_USER}/.local/share/solana/install/active_release/bin/solana-keygen; do
      [ -x \"\$p\" ] && echo \"\$p\" && exit 0
    done
    command -v solana-keygen || true"
}

# Agave 4.4 dropped the --experimental-* XDP/PoH flag names. When <binary> — the
# one validator.sh will exec after the next restart — takes the current names,
# rename them in validator.sh. Sets XDP_FLAGS_BROKEN when the file is left with
# names that binary rejects, so --restart does not bring up a validator that
# exits on its first argument.
XDP_FLAGS_BROKEN=false
fix_xdp_flags() {
  local bin="$1" diff_out
  [[ "$(probe "grep -cE -- '${XDP_OLD_FLAGS_RE}' ${VALIDATOR_SH}")" =~ ^0?$ ]] && return 0

  if $DRY_RUN; then
    echo "[DRY RUN] would rename the --experimental-* XDP/PoH flags in ${VALIDATOR_SH} if ${bin} takes the current names"
    return 0
  fi
  if [[ "$(probe "$(xdp_flag_probe "$bin" "--xdp-cpu-cores 1")")" != "yes" ]]; then
    return 0   # predates Agave 4.3 — the old names are the right ones for it
  fi

  log_info "${bin} uses the current XDP/PoH flag names — renaming them in ${VALIDATOR_SH}"
  diff_out=$(sol_script <<SCRIPT
set -e
VALIDATOR_SH="${VALIDATOR_SH}"
sed '$(xdp_rename_sed)' "\$VALIDATOR_SH" > "\$VALIDATOR_SH.ascend-new"
if [ "\$(wc -l < "\$VALIDATOR_SH.ascend-new")" -ne "\$(wc -l < "\$VALIDATOR_SH")" ] \
   || grep -qE -- '${XDP_OLD_FLAGS_RE}' "\$VALIDATOR_SH.ascend-new" \
   || ! grep -q -- '--ledger' "\$VALIDATOR_SH.ascend-new" \
   || ! bash -n "\$VALIDATOR_SH.ascend-new"; then
  echo "ASCEND_ERR_XDP_SANITY" >&2
  rm -f "\$VALIDATOR_SH.ascend-new"
  exit 5
fi
diff -u "\$VALIDATOR_SH" "\$VALIDATOR_SH.ascend-new" || true
SCRIPT
) || diff_out=""

  if [[ -n "$diff_out" ]]; then
    echo ""
    echo "$diff_out"
    echo ""
    if confirm "Apply this change to ${VALIDATOR_SH}?"; then
      sol_script <<SCRIPT
set -e
cp -a ${VALIDATOR_SH} ${VALIDATOR_SH}.pre-xdp-rename.\$(date +%Y%m%d%H%M%S)
mv ${VALIDATOR_SH}.ascend-new ${VALIDATOR_SH}
chmod +x ${VALIDATOR_SH}
echo "XDP/PoH flags renamed — previous version kept as ${VALIDATOR_SH}.pre-xdp-rename.*"
SCRIPT
      return 0
    fi
    remote "rm -f ${VALIDATOR_SH}.ascend-new"
  else
    log_error "Could not rewrite the XDP/PoH flags in ${VALIDATOR_SH} automatically"
  fi

  # Left as-is: fine while the binary still takes the old names, fatal once it does not
  if [[ "$(probe "$(xdp_flag_probe "$bin" "--experimental-retransmit-xdp-cpu-cores 1")")" == "yes" ]]; then
    log_warn "Left the --experimental-* XDP/PoH flags in ${VALIDATOR_SH} — ${bin} still accepts them, Agave 4.4+ will not"
  else
    log_error "${VALIDATOR_SH} still uses --experimental-* XDP/PoH flags, which ${bin} rejects —"
    log_error "  the validator will not start until they are renamed:"
    local p
    for p in "${XDP_FLAG_RENAMES[@]}"; do log_error "    ${p%%:*}  ->  ${p#*:}"; done
    XDP_FLAGS_BROKEN=true
  fi
}

# arb-enable.sh is generated, so a stale copy is regenerated rather than patched.
# Stale = written before the --program-size guard: arb set lost that flag in
# v4.3.2+concorde.1, and the unguarded call aborts the script there.
refresh_arb_enable() {
  local f="${HEXIS_DIR}/arb-enable.sh" state
  state=$(probe "if [ ! -x $f ]; then echo missing; elif grep -q 'arb set --program-size' $f && ! grep -q 'arb set --help' $f; then echo stale; else echo current; fi")
  [[ "$state" == "current" && "$MODE" != "migrate" ]] && return 0
  [[ "$state" == "stale" ]] && log_info "Regenerating $f — its unconditional --program-size fails on v4.3.2+concorde.1 and later"

  local arb_enable
  arb_enable="$(hexis_render_arb_enable "$HEXIS_DIR" "$LEDGER_PATH")"
  sol_script <<SCRIPT
cat > $f <<'ARBENEOF'
${arb_enable}
ARBENEOF

chmod +x $f
echo "arb-enable.sh ready"
SCRIPT
}

# ---------------------------------------------------------------------------
# Preflight: is this host what the mode expects?
# ---------------------------------------------------------------------------
log_info "Mode: ${MODE}  Host: ${SOL_HOST}  Hexis dir: ${HEXIS_DIR}"

if ! probe "echo ok" | grep -q ok; then
  log_error "Cannot SSH to ${SOL_HOST}"
  exit 1
fi

VALIDATOR_SH_EXISTS=$(probe "test -f ${VALIDATOR_SH} && echo yes || echo no")
if [[ "$VALIDATOR_SH_EXISTS" != "yes" ]]; then
  log_error "No validator startup script at ${VALIDATOR_SH} — pass --validator-script"
  exit 1
fi

HEXIS_INSTALLED=$(probe "test -x ${HEXIS_DIR}/agave-validator && echo yes || echo no")
ALREADY_PATCHED=$(probe "grep -q -- '--arb-config' ${VALIDATOR_SH} && echo yes || echo no")

# Admin-RPC commands (exit, wait-for-restart-window) should be issued by the binary
# the running process is actually executing — for a migration that is still the Jito
# build, not the Hexis one we are about to install.
ORIG_EXEC=$(probe "grep -m1 -E '^[[:space:]]*exec[[:space:]]' ${VALIDATOR_SH} | awk '{print \$2}'")
if [[ -n "$ORIG_EXEC" && "$ORIG_EXEC" != /* ]]; then
  # A bare name resolves against the PATH that validator.sh itself sets
  ORIG_EXEC=$(probe "p=\$(grep -m1 '^PATH=' ${VALIDATOR_SH} | sed 's/^PATH=//'); PATH=\"\${p:-\$PATH}\" command -v ${ORIG_EXEC} || true")
fi
[[ -n "$ORIG_EXEC" ]] && log_info "Currently executing: ${ORIG_EXEC}"
PATCH_APPLIED=false

if [[ "$MODE" != "migrate" && "$HEXIS_INSTALLED" != "yes" ]]; then
  log_error "No Hexis binary at ${HEXIS_DIR}/agave-validator — this host has not been migrated yet"
  log_error "Run: $0 migrate --host ${SSH_HOST} --ssh-key ${SSH_KEY} --hexis-tag <tag>"
  exit 1
fi
if [[ "$MODE" == "migrate" && "$ALREADY_PATCHED" == "yes" ]]; then
  log_info "${VALIDATOR_SH} already carries --arb-config — this host is migrated already"
  log_info "Use '$0 upgrade' for a version bump. Continuing will only refresh the binary and config."
  confirm "Continue anyway?" || exit 0
fi

# Ledger path: whatever the running validator actually uses
if [[ -z "$LEDGER_PATH" ]]; then
  LEDGER_PATH=$(probe "grep -oE -- '--ledger[[:space:]]+[^[:space:]\\\\]+' ${VALIDATOR_SH} | head -1 | awk '{print \$2}'")
  if [[ -z "$LEDGER_PATH" ]]; then
    log_error "Could not find --ledger in ${VALIDATOR_SH} — pass --ledger"
    exit 1
  fi
  log_info "Ledger (from ${VALIDATOR_SH}): ${LEDGER_PATH}"
fi

# ---------------------------------------------------------------------------
# promote: flip the symlink between already-staged releases
# ---------------------------------------------------------------------------
if [[ "$MODE" == "promote" ]]; then
  ACTIVE=$(probe "readlink ${HEXIS_DIR}/agave-validator 2>/dev/null | sed -e 's|^releases/||' -e 's|/agave-validator\$||'")
  STAGED=$(probe "ls -1 ${HEXIS_DIR}/releases 2>/dev/null")

  if [[ -z "$STAGED" ]]; then
    log_error "No staged releases in ${HEXIS_DIR}/releases"
    exit 1
  fi

  if $LIST_RELEASES || [[ -z "$PROMOTE_RELEASE" ]]; then
    echo ""
    echo "Staged releases in ${HEXIS_DIR}/releases:"
    while IFS= read -r r; do
      [[ -z "$r" ]] && continue
      if [[ "$r" == "$ACTIVE" ]]; then echo "  * ${r}   (active)"; else echo "    ${r}"; fi
    done <<< "$STAGED"
    echo ""
    $LIST_RELEASES && exit 0
    log_error "Pass --release <name> to activate one"
    exit 1
  fi

  if ! grep -qx "$PROMOTE_RELEASE" <<< "$STAGED"; then
    log_error "No such staged release: ${PROMOTE_RELEASE}"
    log_error "Run '$0 promote --host ${SSH_HOST} --ssh-key ${SSH_KEY} --list' to see what is available"
    exit 1
  fi
  if [[ "$PROMOTE_RELEASE" == "$ACTIVE" ]]; then
    log_info "${PROMOTE_RELEASE} is already active — nothing to do"
    exit 0
  fi

  log_info "Promoting ${PROMOTE_RELEASE} (was ${ACTIVE:-unknown})"
  # After the flip the symlink points at the new build, so admin-RPC commands go
  # through the release the running process is still executing.
  PROMOTE_RESTART_BIN="${HEXIS_DIR}/agave-validator"
  [[ -n "$ACTIVE" ]] && PROMOTE_RESTART_BIN="${HEXIS_DIR}/releases/${ACTIVE}/agave-validator"
  sol_script <<SCRIPT
set -e
cd ${HEXIS_DIR}
test -x "releases/${PROMOTE_RELEASE}/agave-validator"
ln -s "releases/${PROMOTE_RELEASE}/agave-validator" .agave-validator.next
mv -T .agave-validator.next agave-validator
echo "active: \$(readlink agave-validator)"
SCRIPT

  fix_xdp_flags "${HEXIS_DIR}/agave-validator"
  refresh_arb_enable
  if $RESTART && $XDP_FLAGS_BROKEN; then
    log_warn "Skipping --restart: ${PROMOTE_RELEASE} would not start with this ${VALIDATOR_SH}"
    RESTART=false
  fi

  if $RESTART; then
    log_info "Exiting the validator gracefully — systemd restarts it on ${PROMOTE_RELEASE}"
    perch_before_exit "$PROMOTE_RESTART_BIN"
    remote "${PROMOTE_RESTART_BIN} --ledger ${LEDGER_PATH} ${EXIT_ARGS}"
  else
    log_info "Takes effect on the next restart:"
    log_info "  ${SSH_CMD} ${SOL_HOST} '${PROMOTE_RESTART_BIN} --ledger ${LEDGER_PATH} ${EXIT_ARGS}'"
    log_info "  ${SSH_CMD} ${SOL_HOST} '${HEXIS_DIR}/arb-enable.sh'   # after it is caught up"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Download and verify
# ---------------------------------------------------------------------------
DL_DIR=""
SETUP_DL=""
if [[ -n "$HEXIS_TAG" ]]; then
  log_info "Downloading Hexis release ${HEXIS_TAG} from ${HEXIS_REPO}"
  DL_DIR=$(mktemp -d)
  HEXIS_BINARY=$(hexis_download_validator "$HEXIS_TAG" "$DL_DIR") || exit 1

  if [[ "$MODE" == "migrate" && -z "$HEXIS_SETUP_BINARY" && -n "$HEXIS_SETUP_TAG" ]]; then
    SETUP_DL=$(mktemp -d)
    HEXIS_SETUP_BINARY=$(hexis_download_setup "$HEXIS_SETUP_TAG" "$SETUP_DL") || exit 1
  fi
fi
cleanup() { [[ -n "$DL_DIR" ]] && rm -rf "$DL_DIR"; [[ -n "$SETUP_DL" ]] && rm -rf "$SETUP_DL"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Install the binary.
#
# Layout:  ${HEXIS_DIR}/releases/<release>/agave-validator   the versioned builds
#          ${HEXIS_DIR}/agave-validator -> releases/<release>/agave-validator
#
# validator.sh always execs the stable symlink path, so it never needs editing for
# a version bump. Staging writes only into releases/<release>/ and leaves the
# symlink alone, so an unplanned restart before you promote still comes up on the
# version you were running. Promoting is an atomic rename of the symlink, which
# the running process does not notice — it keeps its open inode until it exits.
# ---------------------------------------------------------------------------
RELEASE_NAME="${HEXIS_TAG}"
ACTIVE_RELEASE=$(probe "readlink ${HEXIS_DIR}/agave-validator 2>/dev/null | sed -e 's|^releases/||' -e 's|/agave-validator\$||'")
OLD_VERSION=""
if [[ "$HEXIS_INSTALLED" == "yes" ]]; then
  OLD_VERSION=$(probe "${HEXIS_DIR}/agave-validator --version 2>/dev/null | awk '{print \$2}'")
  log_info "Running: ${ACTIVE_RELEASE:-${OLD_VERSION:-unknown}}${ACTIVE_RELEASE:+ (${OLD_VERSION:-unknown})}"
fi

if $DRY_RUN; then
  echo "[DRY RUN] scp $HEXIS_BINARY -> $SOL_HOST:${HEXIS_DIR}/releases/${RELEASE_NAME:-<version>}/agave-validator"
  $STAGE_ONLY && echo "[DRY RUN] --stage-only: leaving the agave-validator symlink pointing at ${ACTIVE_RELEASE:-the current release}" \
              || echo "[DRY RUN] repoint ${HEXIS_DIR}/agave-validator -> releases/${RELEASE_NAME:-<version>}/agave-validator"
else
  remote "mkdir -p ${HEXIS_DIR}/releases ${HEXIS_DIR}/arb-reverts && chmod 700 ${HEXIS_DIR}"

  # Upload to a scratch path first — the release name may depend on --version
  scp -q $SSH_OPTS "$HEXIS_BINARY" "$SOL_HOST:${HEXIS_DIR}/agave-validator.incoming"
  remote "chmod +x ${HEXIS_DIR}/agave-validator.incoming"

  NEW_VERSION=$(probe "${HEXIS_DIR}/agave-validator.incoming --version 2>/dev/null | awk '{print \$2}'")
  if [[ -z "$NEW_VERSION" ]]; then
    log_error "The uploaded binary does not run on this host — nothing has been changed"
    log_error "  local file: ${HEXIS_BINARY}"
    log_error "  $(file -b "$HEXIS_BINARY" 2>/dev/null | cut -c1-120)"
    # Re-run with its output kept: an Illegal instruction, a missing glibc
    # symbol, or a binary that is not agave-validator at all all end up here.
    # probe swallows SSH failures, so a dropped connection also lands here.
    WHY=$(probe "${HEXIS_DIR}/agave-validator.incoming --version 2>&1 | head -5; echo \"exit code \${PIPESTATUS[0]}\"")
    if [[ -z "$WHY" ]]; then
      log_error "  no response from ${SOL_HOST} — the SSH connection probably dropped. Re-run once it is back;"
      log_error "  a leftover ${HEXIS_DIR}/agave-validator.incoming is overwritten and nothing else was touched"
      exit 1
    fi
    while IFS= read -r line; do
      log_error "  host says: ${line}"
    done <<< "$WHY"
    remote "rm -f ${HEXIS_DIR}/agave-validator.incoming"
    exit 1
  fi
  # Named by tag when we have one, otherwise by what the binary reports
  RELEASE_NAME="${RELEASE_NAME:-$NEW_VERSION}"
  log_info "Staging: ${RELEASE_NAME} (${NEW_VERSION})"

  if [[ "$RELEASE_NAME" == "$ACTIVE_RELEASE" && "$MODE" == "upgrade" ]] && ! $STAGE_ONLY; then
    log_warn "${RELEASE_NAME} is already the active release — re-staging it anyway"
  fi

  sol_script <<SCRIPT
set -e
cd ${HEXIS_DIR}

# An install that predates this layout is a regular file — move it into releases/
if [ -f agave-validator ] && [ ! -L agave-validator ]; then
  legacy="\$(./agave-validator --version 2>/dev/null | awk '{print \$2}')"
  legacy="releases/\${legacy:-legacy}"
  mkdir -p "\$legacy"
  mv agave-validator "\$legacy/agave-validator"
  ln -s "\$legacy/agave-validator" agave-validator
  echo "converted the existing install to \$legacy"
fi

mkdir -p "releases/${RELEASE_NAME}"
mv agave-validator.incoming "releases/${RELEASE_NAME}/agave-validator"
chmod +x "releases/${RELEASE_NAME}/agave-validator"
echo "staged releases/${RELEASE_NAME}/agave-validator"
SCRIPT

  if $STAGE_ONLY; then
    log_info "Staged only — ${HEXIS_DIR}/agave-validator still points at ${ACTIVE_RELEASE:-the previous release}"
  else
    # ln -sfn is unlink+symlink; rename is what makes the swap atomic
    sol_script <<SCRIPT
set -e
cd ${HEXIS_DIR}
ln -s "releases/${RELEASE_NAME}/agave-validator" .agave-validator.next
mv -T .agave-validator.next agave-validator
echo "active: \$(readlink agave-validator)"
SCRIPT
    log_info "Promoted ${RELEASE_NAME} — it takes effect on the next restart"
  fi
fi

if [[ -n "$HEXIS_SETUP_BINARY" ]]; then
  if $DRY_RUN; then
    echo "[DRY RUN] scp $HEXIS_SETUP_BINARY -> $SOL_HOST:${HEXIS_DIR}/hexis-setup"
  else
    scp -q $SSH_OPTS "$HEXIS_SETUP_BINARY" "$SOL_HOST:${HEXIS_DIR}/hexis-setup"
    remote "chmod +x ${HEXIS_DIR}/hexis-setup"
    log_info "hexis-setup installed at ${HEXIS_DIR}/hexis-setup"
  fi
fi

# ---------------------------------------------------------------------------
# Keys and config (migrate; upgrade only when --hexis-config was given)
# ---------------------------------------------------------------------------
SIGNER_PATH="${HEXIS_DIR}/${HEXIS_SIGNER_KEYPAIR}"
SIGNER_PUBKEY=""

if [[ -n "$HEXIS_CONFIG" ]]; then
  log_info "Uploading arb-config.toml from ${HEXIS_CONFIG}"
  if $DRY_RUN; then
    echo "[DRY RUN] scp $HEXIS_CONFIG -> $SOL_HOST:${HEXIS_DIR}/arb-config.toml"
  else
    remote "test -f ${HEXIS_DIR}/arb-config.toml && cp -a ${HEXIS_DIR}/arb-config.toml ${HEXIS_DIR}/arb-config.toml.bak || true"
    scp -q $SSH_OPTS "$HEXIS_CONFIG" "$SOL_HOST:${HEXIS_DIR}/arb-config.toml"
    remote "chmod 600 ${HEXIS_DIR}/arb-config.toml"
  fi
elif [[ "$MODE" == "migrate" ]]; then
  if [[ -n "$HEXIS_SIGNER" ]]; then
    if $DRY_RUN; then
      echo "[DRY RUN] scp $HEXIS_SIGNER -> $SOL_HOST:${SIGNER_PATH}"
    else
      scp -q $SSH_OPTS "$HEXIS_SIGNER" "$SOL_HOST:${SIGNER_PATH}"
      remote "chmod 600 ${SIGNER_PATH}"
    fi
  fi

  if $DRY_RUN; then
    [[ -z "$HEXIS_SIGNER" ]] && echo "[DRY RUN] generate arb signer at ${SIGNER_PATH}"
  else
    KEYGEN=$(keygen_path)
    if [[ -z "$KEYGEN" && -z "$HEXIS_SIGNER" ]]; then
      log_error "No solana-keygen on ${SOL_HOST} — pass --hexis-signer"
      exit 1
    fi

    if [[ -z "$HEXIS_SIGNER" ]]; then
      sol_script <<SCRIPT
if [ -f ${SIGNER_PATH} ]; then
  echo "arb signer already exists — keeping ${SIGNER_PATH}"
else
  ${KEYGEN} new --outfile ${SIGNER_PATH} --no-passphrase --silent
  echo "generated arb signer ${SIGNER_PATH}"
fi
chmod 600 ${SIGNER_PATH}
SCRIPT
    fi

    SIGNER_PUBKEY=$(probe "${KEYGEN} pubkey ${SIGNER_PATH}")
    [[ -n "$SIGNER_PUBKEY" ]] || { log_error "Could not read the arb signer pubkey"; exit 1; }

    log_info "Arb signer:    ${SIGNER_PUBKEY} — fund it, it pays arb transaction fees"
    log_info "Profit wallet: ${HEXIS_PROFIT_WALLET}  (Hexis rewards pool)"
  fi

  hexis_warn_flash_loans "$HEXIS_SIGNER"

  ARB_TOML="$(hexis_render_arb_config ascend.sh "$HEXIS_DIR" "$SIGNER_PATH" "$HEXIS_CONTROL")
"

  sol_script <<SCRIPT
if [ -f ${HEXIS_DIR}/arb-config.toml ]; then
  cp -a ${HEXIS_DIR}/arb-config.toml ${HEXIS_DIR}/arb-config.toml.bak
  echo "backed up existing arb-config.toml"
fi
cat > ${HEXIS_DIR}/arb-config.toml <<'ARBEOF'
${ARB_TOML}
ARBEOF
chmod 600 ${HEXIS_DIR}/arb-config.toml
echo "arb-config.toml written"
SCRIPT
fi

# ---------------------------------------------------------------------------
# Patch validator.sh (migrate only)
# ---------------------------------------------------------------------------
PATCHER=$(cat <<'AWKEOF'
has_path=$(grep -c '^PATH=' "$VALIDATOR_SH" || true)
# Matches SOLANA_METRICS_CONFIG= but not SOLANA_METRICS_CONFIG_ARB=
has_metrics=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?SOLANA_METRICS_CONFIG=' "$VALIDATOR_SH" || true)

awk -v hexis_dir="$HEXIS_DIR" \
    -v metrics="$METRICS" \
    -v sfdp="$SFDP_METRICS" \
    -v sigverify="$SIGVERIFY" \
    -v has_path="$has_path" \
    -v has_metrics="$has_metrics" '
function emit_env() {
  if (sfdp != "" && has_metrics == 0) print "export SOLANA_METRICS_CONFIG=\"" sfdp "\""
  if (metrics != "") print "export SOLANA_METRICS_CONFIG_ARB=\"" metrics "\""
  env_done = 1
}
BEGIN { env_done = 0; exec_done = 0 }
{
  if (NR == 1 && $0 ~ /^#!/) { print; if (has_path == 0) { print "export PATH=\"" hexis_dir ":$PATH\""; emit_env() } next }

  if (!env_done && $0 ~ /^PATH=/) {
    if (index($0, hexis_dir) == 0) sub(/^PATH=/, "PATH=" hexis_dir ":")
    print
    emit_env()
    next
  }

  if (!exec_done && $0 ~ /^[[:space:]]*exec[[:space:]]/) {
    if ($0 !~ /\\[[:space:]]*$/) { print "ASCEND_ERR_EXEC_ONE_LINE" > "/dev/stderr"; exit 2 }
    sub(/exec[[:space:]]+[^[:space:]]+/, "exec " hexis_dir "/agave-validator")
    print
    print "    --tvu-shred-sigverify-threads " sigverify " \\"
    print "    --arb-config " hexis_dir "/arb-config.toml \\"
    exec_done = 1
    next
  }
  print
}
END { if (!exec_done) { print "ASCEND_ERR_NO_EXEC" > "/dev/stderr"; exit 3 } }
' "$VALIDATOR_SH" > "${VALIDATOR_SH}.ascend-new" || {
  rm -f "${VALIDATOR_SH}.ascend-new"
  exit 4
}

# A rewrite that lost content, lost a flag, or does not parse is not applied.
orig_lines=$(wc -l < "$VALIDATOR_SH")
new_lines=$(wc -l < "${VALIDATOR_SH}.ascend-new")
if [ "$new_lines" -lt "$orig_lines" ] \
   || ! grep -q -- '--arb-config' "${VALIDATOR_SH}.ascend-new" \
   || ! grep -q -- '--ledger' "${VALIDATOR_SH}.ascend-new" \
   || ! bash -n "${VALIDATOR_SH}.ascend-new"; then
  echo "ASCEND_ERR_SANITY orig=${orig_lines} new=${new_lines}" >&2
  rm -f "${VALIDATOR_SH}.ascend-new"
  exit 5
fi

diff -u "$VALIDATOR_SH" "${VALIDATOR_SH}.ascend-new" || true
AWKEOF
)

if [[ "$MODE" == "migrate" ]]; then
  log_info "Patching ${VALIDATOR_SH}"

  if [[ "$ALREADY_PATCHED" == "yes" ]]; then
    log_info "${VALIDATOR_SH} already has --arb-config — leaving it alone"
    PATCH_APPLIED=true
  elif $DRY_RUN; then
    echo "[DRY RUN] would rewrite ${VALIDATOR_SH}: hexis dir first on PATH, metrics exports,"
    echo "[DRY RUN]   exec -> ${HEXIS_DIR}/agave-validator, plus --tvu-shred-sigverify-threads and --arb-config"
    PATCH_APPLIED=true
  else
    DIFF_OUT=$(sol_script <<SCRIPT
set -e
VALIDATOR_SH="${VALIDATOR_SH}"
HEXIS_DIR="${HEXIS_DIR}"
METRICS='${HEXIS_METRICS_CONFIG}'
SFDP_METRICS='${METRICS_CONFIG}'
SIGVERIFY='${HEXIS_SIGVERIFY_THREADS}'
${PATCHER}
SCRIPT
) || {
      log_error "Could not patch ${VALIDATOR_SH} automatically."
      log_error "Its exec line is either a one-liner or missing. Add these by hand instead:"
      log_error "  exec ${HEXIS_DIR}/agave-validator \\"
      log_error "      --tvu-shred-sigverify-threads ${HEXIS_SIGVERIFY_THREADS} \\"
      log_error "      --arb-config ${HEXIS_DIR}/arb-config.toml \\"
      exit 1
    }

    echo ""
    echo "$DIFF_OUT"
    echo ""

    if confirm "Apply this change to ${VALIDATOR_SH}?"; then
      sol_script <<SCRIPT
set -e
cp -a ${VALIDATOR_SH} ${VALIDATOR_SH}.pre-hexis.\$(date +%Y%m%d%H%M%S)
mv ${VALIDATOR_SH}.ascend-new ${VALIDATOR_SH}
chmod +x ${VALIDATOR_SH}
echo "patched — previous version kept as ${VALIDATOR_SH}.pre-hexis.*"
SCRIPT
      PATCH_APPLIED=true
    else
      remote "rm -f ${VALIDATOR_SH}.ascend-new"
      log_warn "Left ${VALIDATOR_SH} untouched — the arb will not start"
    fi
  fi

  # Control port, restricted to the Hexis fleet
  if $HEXIS_CONTROL; then
    CONTROL_PORT="${HEXIS_CONTROL_BIND##*:}"
    if $DRY_RUN; then
      echo "[DRY RUN] ufw allow from ${HEXIS_CONTROL_ALLOW} to any port ${CONTROL_PORT} proto tcp"
    else
      read -rsp "Sudo password for ${SOL_HOST} (to open the Control port): " SUDO_PASS
      echo ""
      root_script <<SCRIPT
ufw allow from ${HEXIS_CONTROL_ALLOW} to any port ${CONTROL_PORT} proto tcp
echo "Allowed ${CONTROL_PORT}/tcp from ${HEXIS_CONTROL_ALLOW} (Hexis Control)"
SCRIPT
    fi
  fi
fi

# ---------------------------------------------------------------------------
# --fix-metrics: add SOLANA_METRICS_CONFIG to a validator.sh that has none.
# Separate from the migrate patcher because a host already running Hexis is
# skipped there, which is exactly the host that turns out to be missing this.
# ---------------------------------------------------------------------------
HAS_METRICS=$(probe "grep -cE '^[[:space:]]*(export[[:space:]]+)?SOLANA_METRICS_CONFIG=' ${VALIDATOR_SH}")

if $FIX_METRICS && [[ "$HAS_METRICS" != "0" ]]; then
  log_info "${VALIDATOR_SH} already exports SOLANA_METRICS_CONFIG — nothing to fix"
elif $FIX_METRICS && [[ -z "$METRICS_CONFIG" ]]; then
  log_error "--fix-metrics needs a value — --metrics-config was set to empty"
  exit 1
elif $FIX_METRICS && $DRY_RUN; then
  echo "[DRY RUN] would add 'export SOLANA_METRICS_CONFIG=...' to ${VALIDATOR_SH}"
elif $FIX_METRICS; then
  log_info "Adding SOLANA_METRICS_CONFIG to ${VALIDATOR_SH}"
  DIFF_OUT=$(sol_script <<SCRIPT
set -e
VALIDATOR_SH="${VALIDATOR_SH}"
LINE='export SOLANA_METRICS_CONFIG="${METRICS_CONFIG}"'

# After the PATH line if there is one, otherwise straight after the shebang
if grep -q '^PATH=' "\$VALIDATOR_SH"; then
  awk -v line="\$LINE" '{ print } /^PATH=/ && !done { print line; done=1 }' \
    "\$VALIDATOR_SH" > "\$VALIDATOR_SH.ascend-new"
else
  awk -v line="\$LINE" 'NR==1 { print; print line; next } { print }' \
    "\$VALIDATOR_SH" > "\$VALIDATOR_SH.ascend-new"
fi

orig=\$(wc -l < "\$VALIDATOR_SH")
new=\$(wc -l < "\$VALIDATOR_SH.ascend-new")
if [ "\$new" -ne \$((orig + 1)) ] \
   || ! grep -q -- '--ledger' "\$VALIDATOR_SH.ascend-new" \
   || ! bash -n "\$VALIDATOR_SH.ascend-new"; then
  echo "ASCEND_ERR_METRICS_SANITY orig=\$orig new=\$new" >&2
  rm -f "\$VALIDATOR_SH.ascend-new"
  exit 5
fi

diff -u "\$VALIDATOR_SH" "\$VALIDATOR_SH.ascend-new" || true
SCRIPT
) || { log_error "Could not add the metrics export to ${VALIDATOR_SH} — left untouched"; exit 1; }

  echo ""
  echo "$DIFF_OUT"
  echo ""

  if confirm "Apply this change to ${VALIDATOR_SH}?"; then
    sol_script <<SCRIPT
set -e
cp -a ${VALIDATOR_SH} ${VALIDATOR_SH}.pre-metrics.\$(date +%Y%m%d%H%M%S)
mv ${VALIDATOR_SH}.ascend-new ${VALIDATOR_SH}
chmod +x ${VALIDATOR_SH}
echo "metrics export added — previous version kept as ${VALIDATOR_SH}.pre-metrics.*"
SCRIPT
    HAS_METRICS=1
  else
    remote "rm -f ${VALIDATOR_SH}.ascend-new"
    log_warn "Left ${VALIDATOR_SH} untouched"
  fi
fi

# ---------------------------------------------------------------------------
# arb-enable.sh — the post-start master switch
# ---------------------------------------------------------------------------
refresh_arb_enable

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
# The currently running binary: the pre-migration exec target, or the release that
# was active before we promoted over it. Falls back to the stable symlink.
RESTART_BIN="${HEXIS_DIR}/agave-validator"
if [[ "$MODE" == "migrate" && "$ORIG_EXEC" == /* ]]; then
  RESTART_BIN="$ORIG_EXEC"
elif [[ -n "${ACTIVE_RELEASE:-}" ]]; then
  RESTART_BIN="${HEXIS_DIR}/releases/${ACTIVE_RELEASE}/agave-validator"
fi

# --stage-only leaves the running release active; promote does this check then.
if ! $STAGE_ONLY; then
  fix_xdp_flags "${HEXIS_DIR}/agave-validator"
fi
if $RESTART && $XDP_FLAGS_BROKEN; then
  log_warn "Skipping --restart: the new binary would not start with this ${VALIDATOR_SH}"
  RESTART=false
fi

if $RESTART && [[ "$MODE" == "migrate" ]] && ! $PATCH_APPLIED; then
  log_warn "Skipping --restart: ${VALIDATOR_SH} was not patched, so a restart would just bring back the old setup"
  RESTART=false
fi

if $RESTART; then
  log_info "Exiting the validator gracefully — systemd restarts it on the new binary"
  log_info "This blocks until a safe restart window (min-idle-time ${MIN_IDLE_TIME}m, max-delinquent-stake ${MAX_DELINQUENT_STAKE}%)"
  log_info "Issuing exit via ${RESTART_BIN}"
  perch_before_exit "$RESTART_BIN"
  remote "${RESTART_BIN} --ledger ${LEDGER_PATH} ${EXIT_ARGS}"
  log_info "Validator exited — systemd should be bringing it back up"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
log_info "============================================"
log_info "${MODE} complete"
log_info "============================================"
[[ -n "$SIGNER_PUBKEY" ]] && log_info "Arb signer:    ${SIGNER_PUBKEY} (${SIGNER_PATH})"
[[ -n "$HEXIS_PROFIT_WALLET" ]] && log_info "Profit pool:   ${HEXIS_PROFIT_WALLET}"

if [[ "$HAS_METRICS" == "0" ]]; then
  log_warn "${VALIDATOR_SH} exports no SOLANA_METRICS_CONFIG — this validator publishes no cluster"
  log_warn "  metrics, which the SFDP requires. Re-run with --fix-metrics to add it."
fi

FL_ACCOUNT="$HEXIS_MARGINFI_ACCOUNT"
$DRY_RUN || FL_ACCOUNT=$(hexis_flash_loan_account 2>/dev/null || true)
if [[ -n "$FL_ACCOUNT" ]]; then
  log_info "Flash loans:   ON via marginfi account ${FL_ACCOUNT}"
else
  log_info "Flash loans:   OFF — ${HEXIS_DIR}/arb-config.toml has no [flash_loan] table"
  if [[ "$(probe "test -x ${HEXIS_DIR}/hexis-setup && echo yes || echo no")" == "yes" ]]; then
    log_info "  Fund the arb signer, then: ${SSH_CMD} ${SOL_HOST} '${HEXIS_DIR}/hexis-setup marginfi create'"
  else
    log_info "  Install hexis-setup (--hexis-setup-binary), then run 'hexis-setup marginfi create'"
  fi
  log_info "  Then re-run migrate with --hexis-marginfi-account <PUBKEY> and restart"
fi
log_info ""
if ! $RESTART; then
  log_info "Nothing has been restarted. The new binary and config take effect on restart:"
  log_info "  ${SSH_CMD} ${SOL_HOST} '${RESTART_BIN} --ledger ${LEDGER_PATH} ${EXIT_ARGS}'"
  log_info ""
fi
log_info "Once it is back and caught up, the arb is still DISABLED. Enable it with:"
log_info "  ${SSH_CMD} ${SOL_HOST} '${HEXIS_DIR}/arb-enable.sh'"
log_info ""
log_info "Verify:"
log_info "  ${SSH_CMD} ${SOL_HOST} 'solana catchup --our-localhost'"
log_info "  ${SSH_CMD} ${SOL_HOST} '${HEXIS_DIR}/agave-validator --ledger ${LEDGER_PATH} arb get'"
if [[ -n "$ACTIVE_RELEASE" ]]; then
  log_info ""
  log_info "Rollback: $0 promote --host ${SSH_HOST} --ssh-key ${SSH_KEY} --release ${ACTIVE_RELEASE}"
fi
