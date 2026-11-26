#!/usr/bin/env bash
#
# Shared Hexis arb client definitions for arise.sh and ascend.sh.
#
# Sourced, never executed. Defines logging, the Hexis config defaults, and the
# pure rendering/verification helpers both scripts need. SSH transport stays in
# the individual scripts — arise.sh has a bootstrap/root path that ascend.sh
# does not, and unifying those would change behaviour rather than de-duplicate it.
#
# Reference: https://github.com/hexishq/hexis-validator-docs

# Defaults below are read by the sourcing script, not by this file.
# shellcheck disable=SC2034

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Hexis defaults
#
# These are the values from the Hexis mainnet config: public on-chain addresses,
# each overridden by flag. The two credentials Hexis hands to its operators are
# not kept here — see "Hexis credentials" below.
# ---------------------------------------------------------------------------
HEXIS_REPO="hexishq/hexis-validator-docs"
HEXIS_SETUP_TAG="v1.0-hexis-setup"      # hexis-setup ships as its own release
HEXIS_SIGNER_KEYPAIR="arb_signer_keypair.json"
HEXIS_CONTROL_BIND="0.0.0.0:18082"
HEXIS_CONTROL_ALLOW="188.40.61.182"     # only source allowed to reach Control
HEXIS_SIGVERIFY_THREADS="2"
HEXIS_PROGRAM_SIZE="45101"

# Cluster metrics the Solana Foundation Delegation Program requires validators to
# publish. Public write credentials, same values the Agave docs ship.
SFDP_METRICS_MAINNET="host=https://metrics.solana.com:8086,db=mainnet-beta,u=mainnet-beta_write,p=password"
SFDP_METRICS_TESTNET="host=https://metrics.solana.com:8086,db=tds,u=testnet_write,p=c4fa841aa918bf8274e3e2a44d77568d9861b3ea"

# Hexis credentials — the Jupiter API key and the arb metrics string. Hexis gives
# both to each operator; neither is kept in this repository. Each is taken from
# the first of: the flag (--hexis-jup-key, --hexis-metrics-config), the
# environment (HEXIS_JUP_KEY, SOLANA_METRICS_CONFIG_ARB), or hexis.env beside the
# scripts, which git ignores (hexis.env.example shows the format). A value given
# as "" is a decision to go without it; one never given at all is an error where
# it is needed, so a host is not set up without it by accident.
HEXIS_ENV_FILE="${HEXIS_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hexis.env}"

# hexis_env_value <NAME> — the value of NAME=... in hexis.env, quotes stripped.
# The file is read, never sourced. Fails when the file or the name is absent.
hexis_env_value() {
  local line value
  [[ -f "$HEXIS_ENV_FILE" ]] || return 1
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$HEXIS_ENV_FILE" | tail -1) || return 1
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

HEXIS_JUP_KEY_SET=false
if [[ -n "${HEXIS_JUP_KEY+x}" ]]; then
  HEXIS_JUP_KEY_SET=true
elif HEXIS_JUP_KEY=$(hexis_env_value HEXIS_JUP_KEY); then
  HEXIS_JUP_KEY_SET=true
else
  HEXIS_JUP_KEY=""
fi

HEXIS_METRICS_CONFIG_SET=false
if [[ -n "${SOLANA_METRICS_CONFIG_ARB+x}" ]]; then
  HEXIS_METRICS_CONFIG="$SOLANA_METRICS_CONFIG_ARB"; HEXIS_METRICS_CONFIG_SET=true
elif HEXIS_METRICS_CONFIG=$(hexis_env_value SOLANA_METRICS_CONFIG_ARB); then
  HEXIS_METRICS_CONFIG_SET=true
else
  HEXIS_METRICS_CONFIG=""
fi

# hexis_can_prompt — true when a person is there to answer: a terminal on both
# ends and no --yes. HEXIS_ASSUME_TTY=1 stands in for the terminal in tests.
hexis_can_prompt() {
  [[ "${ASSUME_YES:-false}" == true ]] && return 1
  [[ "${HEXIS_ASSUME_TTY:-}" == 1 ]] && return 0
  [[ -t 0 && -t 2 ]]
}

# hexis_save_credential <NAME> <value> — put NAME="value" in hexis.env, replacing
# an earlier line for the same name. The file is only ever readable by its owner.
hexis_save_credential() {
  local name="$1" value="$2" tmp
  tmp=$(mktemp "${HEXIS_ENV_FILE}.XXXXXX") || return 1
  if [[ -f "$HEXIS_ENV_FILE" ]]; then
    grep -v -E "^[[:space:]]*(export[[:space:]]+)?${name}=" "$HEXIS_ENV_FILE" > "$tmp" || true
  fi
  printf '%s="%s"\n' "$name" "$value" >> "$tmp"
  chmod 600 "$tmp" && mv "$tmp" "$HEXIS_ENV_FILE"
}

# hexis_ask_credential <NAME> <what> [pattern] — ask for one credential without
# echoing it, offer to keep it in hexis.env, and leave it in HEXIS_ASKED. Enter
# alone is the decision to go without. A value that does not match the pattern
# is asked for again.
HEXIS_ASKED=""
hexis_ask_credential() {
  local name="$1" what="$2" pattern="${3:-}" value save
  while :; do
    printf 'Enter %s (input is hidden; Enter alone to set up without it): ' "$what" >&2
    IFS= read -rs value || { echo "" >&2; return 1; }
    echo "" >&2
    value="${value%$'\r'}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    [[ -z "$value" || -z "$pattern" || "$value" =~ $pattern ]] && break
    log_warn "That does not look like ${what} — expected the form ${4:-$pattern}"
  done
  [[ -z "$value" ]] && log_warn "Going without ${what}"
  printf 'Save it to %s for next time? [Y/n] ' "$HEXIS_ENV_FILE" >&2
  IFS= read -r save || save="n"
  case "$save" in
    n|N|no|No|NO) ;;
    *) if hexis_save_credential "$name" "$value"; then
         log_info "Saved to ${HEXIS_ENV_FILE} (readable only by you; git ignores it)"
       else
         log_warn "Could not write ${HEXIS_ENV_FILE} — using it for this run only"
       fi ;;
  esac
  HEXIS_ASKED="$value"
}

# hexis_require_credentials <jup-key: yes|no> — make sure every credential the
# run is about to write to the host was given. At a terminal a missing one is
# asked for; anywhere else the run stops. The Jupiter key is only needed when
# arb-config.toml is generated, not when one is uploaded. The metrics string is
# the same one for every Hexis host, so it is asked for once per laptop.
hexis_require_credentials() {
  if hexis_can_prompt; then
    if [[ "$1" == "yes" ]] && ! $HEXIS_JUP_KEY_SET; then
      log_info "Hexis credentials are not kept in this repository; Hexis hands them to its operators."
      hexis_ask_credential HEXIS_JUP_KEY "the Jupiter API key" || return 1
      HEXIS_JUP_KEY="$HEXIS_ASKED"; HEXIS_JUP_KEY_SET=true
    fi
    if ! $HEXIS_METRICS_CONFIG_SET; then
      hexis_ask_credential SOLANA_METRICS_CONFIG_ARB "the arb metrics string" \
        '^host=[^,]+,db=[^,]+,u=[^,]+,p=.+$' 'host=...,db=...,u=...,p=...' || return 1
      HEXIS_METRICS_CONFIG="$HEXIS_ASKED"; HEXIS_METRICS_CONFIG_SET=true
    fi
    return 0
  fi
  local missing=()
  [[ "$1" == "yes" ]] && ! $HEXIS_JUP_KEY_SET && missing+=("the Jupiter API key: --hexis-jup-key <key> or HEXIS_JUP_KEY")
  $HEXIS_METRICS_CONFIG_SET || missing+=("the arb metrics string: --hexis-metrics-config <str> or SOLANA_METRICS_CONFIG_ARB")
  [[ ${#missing[@]} -eq 0 ]] && return 0
  log_error "Hexis credentials are not kept in this repository. Missing:"
  local m
  for m in "${missing[@]}"; do log_error "  - $m"; done
  log_error "Put them in ${HEXIS_ENV_FILE} (see hexis.env.example) to give them once,"
  log_error "or run this at a terminal without --yes and it asks for them and saves them."
  log_error "Hexis hands both to its operators. Pass \"\" to set up without one."
  return 1
}

# [engine]
HEXIS_PROGRAM_ID="FQXqWuMPdQ7PzPu5y7eJSFBrNQ6WQL5KWzNQ6pLNBfdq"
# Hexis's shared rewards pool. We hold no key for it — the program pays into it.
HEXIS_PROFIT_WALLET="FevX9jr7HQ43anpFpUA88M8eA1Xk22fLVqPG6YEERr4h"
HEXIS_PRICE_VALID_MS="500"
HEXIS_LOOKUP_TABLES="2HKHV5M2EKRjhUgp3DVT1RWUFmDP6UQuAVA9j8vVy7vr"
HEXIS_JUPITER_TOKEN_LEDGER="GPxeELGQFPUD8QMYJEx8Pe4sbujGRsUcBFBuaeeu5LEm"
HEXIS_OKX_TOKEN_LEDGER="FZ2tnmpsGG2JxruyAPRrSBFARGAQtcVvTmt8z83kM5yC"

# [index] — marginfi_banks below must line up with this order
HEXIS_BASE_MINTS="So11111111111111111111111111111111111111112,EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v,Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"

# [flash_loan] — the marginfi v2 account from the Hexis config. Its authority is
# the arb signer Hexis issued, so the two go together.
HEXIS_MARGINFI_ACCOUNT="93rXRLxa3nJ6WkEbsxHCPS6doffoVf4yXb8hxWaphPsw"
HEXIS_MARGINFI_BANKS="CCKtUs6Cgwo4aaQUmBPmyoApH2gUDErxNZCAntD6LYGh,2s37akK2eyBbp8DZgCm7RtsaEz8eJP3Nxd4urLHQv7yB,HmpMfL8942u22htC4EMiWgLX931g3sacXFR6KjuLgKLV"
HEXIS_MARGINFI_PROGRAM_ID="MFv2hWf31Z9kbCa1snEPYctwafyhdvnV7FZnsebVacA"

# ---------------------------------------------------------------------------
# XDP / PoH flag names
#
# Agave 4.3 renamed these and kept the old --experimental-* names as hidden
# aliases; 4.4 dropped the aliases, so a validator.sh written for an older build
# refuses to start on 4.4+. old:new, none is a prefix of another.
# ---------------------------------------------------------------------------
XDP_FLAG_RENAMES=(
  "--experimental-retransmit-xdp-cpu-cores:--xdp-cpu-cores"
  "--experimental-retransmit-xdp-interface:--xdp-interface"
  "--experimental-retransmit-xdp-zero-copy:--xdp-zero-copy"
  "--experimental-poh-pinned-cpu-core:--poh-pinned-cpu-core"
)
XDP_OLD_FLAGS_RE='--experimental-(retransmit-xdp-|poh-pinned-cpu-core)'

# sed program rewriting the old names to the new ones
xdp_rename_sed() {
  local p
  for p in "${XDP_FLAG_RENAMES[@]}"; do
    printf 's/%s/%s/g;' "${p%%:*}" "${p#*:}"
  done
}

# Remote shell snippet: prints yes if <binary> parses <flag args>, no if it
# rejects them. --version stops it before anything starts.
xdp_flag_probe() {
  echo "$1 $2 --version >/dev/null 2>&1 && echo yes || echo no"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# "a,b, c" -> "\"a\", \"b\", \"c\"" for TOML arrays
hexis_toml_list() {
  local IFS=,
  local out="" item
  for item in $1; do
    item="${item//[[:space:]]/}"
    [[ -z "$item" ]] && continue
    out+="\"${item}\", "
  done
  echo "${out%, }"
}

# Verify a downloaded asset against the release's checksums.txt, when there is one.
# Exits non-zero on mismatch — the caller is expected to be running under set -e.
hexis_verify_checksum() {
  local dir="$1" file="$2" sums expected actual
  sums=$(find "$dir" -name '*checksums.txt' -type f | head -1)
  if [[ -z "$sums" ]]; then
    log_warn "No checksums.txt in the release — cannot verify ${file}"
    return 0
  fi
  expected=$(awk -v f="$file" '$2 == f { print $1 }' "$sums")
  if [[ -z "$expected" ]]; then
    log_warn "checksums.txt has no entry for ${file} — skipping verification"
    return 0
  fi
  actual=$(shasum -a 256 "${dir}/${file}" | awk '{print $1}')
  if [[ "$expected" != "$actual" ]]; then
    log_error "Checksum mismatch for ${file}"
    log_error "  expected ${expected}"
    log_error "  got      ${actual}"
    return 1
  fi
  log_info "Checksum OK: ${file}"
}

# hexis_download_validator <tag> <dir> — echoes the verified binary path
hexis_download_validator() {
  local tag="$1" dir="$2"
  gh release download "$tag" --repo "$HEXIS_REPO" \
    --pattern 'agave-validator-linux-amd64' --pattern '*checksums.txt' \
    --dir "$dir" --clobber
  [[ -f "${dir}/agave-validator-linux-amd64" ]] || {
    log_error "Release ${tag} has no agave-validator-linux-amd64 asset" >&2
    return 1
  }
  hexis_verify_checksum "$dir" agave-validator-linux-amd64 >&2 || return 1
  echo "${dir}/agave-validator-linux-amd64"
}

# hexis_download_setup <tag> <dir> — echoes the verified path, or nothing.
# hexis-setup is optional: a missing asset is a warning, not a failure.
hexis_download_setup() {
  local tag="$1" dir="$2"
  if gh release download "$tag" --repo "$HEXIS_REPO" \
       --pattern 'hexis-setup-linux-amd64' --pattern '*checksums.txt' \
       --dir "$dir" --clobber 2>/dev/null \
     && [[ -f "${dir}/hexis-setup-linux-amd64" ]]; then
    hexis_verify_checksum "$dir" hexis-setup-linux-amd64 >&2 || return 1
    echo "${dir}/hexis-setup-linux-amd64"
    return 0
  fi
  log_warn "Could not download hexis-setup from release ${tag} — pass --hexis-setup-tag or --hexis-setup-binary" >&2
  return 0
}

# hexis_render_arb_config <generator> <hexis_dir> <signer_path> <control_on>
# Echoes arb-config.toml from the HEXIS_* globals. A generated config is only as
# good as the flags — the caller warns about the combinations that cannot work.
hexis_render_arb_config() {
  local generator="$1" hexis_dir="$2" signer_path="$3" control_on="$4"

  echo "# Arb boot configuration — generated by ${generator}"
  echo "# Read ONCE at startup. The master switch always boots DISABLED:"
  echo "# run ${hexis_dir}/arb-enable.sh after every (re)start."
  echo ""
  echo "[engine]"
  echo "program_id     = \"${HEXIS_PROGRAM_ID}\""
  echo "profit_wallet  = \"${HEXIS_PROFIT_WALLET}\""
  [[ -n "$signer_path" ]] && echo "signer_path    = \"${signer_path}\""
  [[ -n "$HEXIS_JUP_KEY" ]] && echo "jup_key        = \"${HEXIS_JUP_KEY}\""
  echo "price_valid_ms = ${HEXIS_PRICE_VALID_MS}"
  echo "lookup_tables  = [$(hexis_toml_list "$HEXIS_LOOKUP_TABLES")]"
  echo "jupiter_token_ledger = \"${HEXIS_JUPITER_TOKEN_LEDGER}\""
  echo "okx_token_ledger = \"${HEXIS_OKX_TOKEN_LEDGER}\""
  echo ""
  echo "[index]"
  echo "# Positional: marginfi_banks must line up with this order."
  echo "base_mints = [$(hexis_toml_list "$HEXIS_BASE_MINTS")]"
  echo "max_candidate_pools         = 32"
  echo "detection_mode              = \"account-touch\""
  echo "snapshot_max_age_days       = 15"
  echo "runtime_cleanup_max_age_days = 15"
  echo "rank_rebuild_interval_ms    = 500"
  echo "volume_decay_half_life_secs = 900"
  echo ""
  echo "[budget]"
  echo "compute_unit_dynamic      = true"
  echo "compute_unit_margin_bps   = 500"
  echo "account_data_size_dynamic = true"
  if [[ -n "$HEXIS_MARGINFI_ACCOUNT" ]]; then
    echo ""
    echo "[flash_loan]"
    echo "marginfi_account = \"${HEXIS_MARGINFI_ACCOUNT}\""
    echo "marginfi_banks = [$(hexis_toml_list "$HEXIS_MARGINFI_BANKS")]"
    echo "marginfi_program_id = \"${HEXIS_MARGINFI_PROGRAM_ID}\""
  fi
  echo ""
  echo "[revert_dump]"
  echo "dir = \"${hexis_dir}/arb-reverts\""
  if [[ "$control_on" == "true" ]]; then
    echo ""
    echo "[control]"
    echo "bind = \"${HEXIS_CONTROL_BIND}\""
  fi
}

# hexis_render_arb_enable <hexis_dir> <ledger_path> — echoes arb-enable.sh
hexis_render_arb_enable() {
  local hexis_dir="$1" ledger="$2"
  cat <<ENABLEEOF
#!/bin/bash
# Enable the Hexis arb pipeline on a RUNNING validator.
# The pipeline boots disabled on every start, so run this after each (re)start.
set -euo pipefail

BIN=${hexis_dir}/agave-validator
LEDGER=${ledger}

"\$BIN" --ledger "\$LEDGER" arb set --enabled true
# arb set lost --program-size in v4.3.2+concorde.1; earlier releases still need it.
# Checked against whatever BIN points at, so this survives a promote or rollback.
if "\$BIN" arb set --help 2>/dev/null | grep -q -- '--program-size'; then
  "\$BIN" --ledger "\$LEDGER" arb set --program-size ${HEXIS_PROGRAM_SIZE}
fi
"\$BIN" --ledger "\$LEDGER" arb okx-token-ledger set ${HEXIS_OKX_TOKEN_LEDGER}
"\$BIN" --ledger "\$LEDGER" arb get
ENABLEEOF
}

# A marginfi account can only be borrowed against by its own authority, which is
# the signer Hexis issues. Warn on the combination that cannot work.
# hexis_warn_flash_loans <signer_supplied> [off_hint]
hexis_warn_flash_loans() {
  local signer_supplied="$1" off_hint="${2:-}"
  if [[ -z "$HEXIS_MARGINFI_ACCOUNT" ]]; then
    log_warn "Flash loans off — [flash_loan] omitted from arb-config.toml${off_hint}"
  elif [[ -z "$signer_supplied" ]]; then
    log_warn "marginfi_account ${HEXIS_MARGINFI_ACCOUNT} is configured but the arb signer was generated here."
    log_warn "  Flash loans will fail unless that account's authority is this signer. Pass --hexis-signer"
    log_warn "  with the keypair Hexis issued, or --no-hexis-flash-loans to run without them."
  fi
}

# ---------------------------------------------------------------------------
# Releases
# ---------------------------------------------------------------------------

# One line per published release, newest first: "<tag>|<asset>,<asset>,..."
hexis_release_lines() {
  gh api "repos/${HEXIS_REPO}/releases?per_page=40" \
    --jq '.[] | select(.draft | not) | .tag_name + "|" + ([.assets[].name] | join(","))'
}

# hexis_latest_tag <release lines> <asset name> — newest release that ships it.
# The Agave client and Firedancer are released from the same repository, so the
# asset is what tells them apart.
hexis_latest_tag() {
  local line
  while IFS= read -r line; do
    if [[ ",${line#*|}," == *",$2,"* ]]; then
      echo "${line%%|*}"
      return 0
    fi
  done <<<"$1"
  return 1
}

# perch (github.com/TheChimpions/perch-watchtower) pages when a validator stops
# voting. Its maint command declares planned work so a restart does not page:
# "restart <deadline>" holds until the validator is back or the deadline passes.
# A Firedancer start can need a reboot for its huge pages and, at worst, an
# hour of snapshot download, so it gets the longer deadline.
PERCH_DEADLINE_AGAVE="1h"
PERCH_DEADLINE_FIREDANCER="2h"

# perch lives in one of two places. An older host has it in the validator user's
# home: /home/<user>/perch, with a maint wrapper that user runs. A host set up by
# the current arise.sh has it installed system-wide: the perch binary on PATH,
# its config in /etc/perch (root:perch), so declaring work there takes root.
PERCH_SYSTEM_CFG="/etc/perch/config.toml"

# perch_kind_cmd <user> — shell text that prints home, system or nothing. Safe
# to run as the validator user, who cannot read /etc/perch but can see it.
perch_kind_cmd() {
  printf 'if [ -x /home/%s/perch/maint ]; then echo home; elif command -v perch >/dev/null 2>&1 && [ -d /etc/perch ]; then echo system; fi' "$1"
}

# perch_cfg_line <user> — the first line of the config helpers below: the home
# config when there is one, else the system-wide one.
perch_cfg_line() {
  printf 'perch_cfg="/home/%s/perch/config.toml"; [ -f "$perch_cfg" ] || perch_cfg="%s"\n' "$1" "$PERCH_SYSTEM_CFG"
}

# perch_maint_cmd <user> <deadline> [root] — shell text that declares the
# restart to perch when the host has it, and says nothing when it does not.
# Never fails the caller: a restart goes ahead even if perch cannot be told.
# With "root" the text is for a root shell: it drops to the user for a perch in
# their home, and runs the system-wide one as root. Without it the text is for
# the validator user and covers only the perch in their home; a system-wide
# perch has to be declared through root.
perch_maint_cmd() {
  local maint="/home/$1/perch/maint" warn='echo "perch: could not declare the restart — it may page"'
  if [[ "${3:-}" == "root" ]]; then
    printf 'if [ -x %s ]; then runuser -u %s -- %s restart %s || %s; elif command -v perch >/dev/null 2>&1 && [ -f %s ]; then perch --config %s maint restart %s || %s; fi' \
      "$maint" "$1" "$maint" "$2" "$warn" "$PERCH_SYSTEM_CFG" "$PERCH_SYSTEM_CFG" "$2" "$warn"
  else
    printf 'if [ -x %s ]; then %s restart %s || %s; fi' "$maint" "$maint" "$2" "$warn"
  fi
}

# perch_local_rpc_off_cmd <user> — root shell text for a host that has just
# moved to Firedancer. perch usually watches the validator's own RPC port as one
# of its endpoints; Firedancer runs without RPC, so that endpoint is dead from
# then on and keeps perch from seeing the validator recover. Every [[endpoints]]
# block that points at this machine and has nothing listening on its port is
# removed, the old config is kept beside it as config.toml.bak-pre-firedancer,
# and perch is restarted. Left alone when no other endpoint would remain.
perch_local_rpc_off_cmd() {
  perch_cfg_line "$1"
  cat <<'EOF'
if [ -f "$perch_cfg" ]; then
  awk 'BEGIN { RS = ""; ORS = "\n\n" }
    /\[\[endpoints\]\]/ && match($0, /:\/\/(127\.0\.0\.1|localhost):[0-9]+/) {
      port = substr($0, RSTART, RLENGTH); sub(/.*:/, "", port)
      if (system("ss -lnt 2>/dev/null | grep -q \":" port " \"") != 0) { dropped++; next }
    }
    { print }
    END { exit dropped ? 0 : 3 }' "$perch_cfg" > "$perch_cfg.new" && perch_drop=yes || perch_drop=no
  if [ "$perch_drop" = yes ] && grep -q '\[\[endpoints\]\]' "$perch_cfg.new"; then
    cp -a "$perch_cfg" "$perch_cfg.bak-pre-firedancer"
    cat "$perch_cfg.new" > "$perch_cfg"
    systemctl try-restart perch 2>/dev/null || true
    echo "perch: removed the endpoint for this host's own RPC, which Firedancer does not serve (old config: $perch_cfg.bak-pre-firedancer)"
  elif [ "$perch_drop" = yes ]; then
    echo "perch: its only endpoint is this host's own RPC, which Firedancer does not serve — give it another in $perch_cfg"
  fi
  rm -f "$perch_cfg.new"
fi
EOF
}

# perch_local_rpc_on_cmd <user> — the way back, for a host returning to Agave.
perch_local_rpc_on_cmd() {
  perch_cfg_line "$1"
  cat <<'EOF'
if [ -f "$perch_cfg.bak-pre-firedancer" ]; then
  # cat keeps the live file's owner and mode (root:perch 0640 when system-wide)
  cat "$perch_cfg.bak-pre-firedancer" > "$perch_cfg"
  rm -f "$perch_cfg.bak-pre-firedancer"
  systemctl try-restart perch 2>/dev/null || true
  echo "perch: config from before Firedancer put back"
fi
EOF
}

# The Hexis builds, Agave and Firedancer alike, exist for mainnet only.
MAINNET_GENESIS_HASH="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"

# perch reads what Firedancer says about itself — voting, replay, turbine, tile
# heartbeats, how full the accounts index is — from Firedancer's metrics port,
# when the [[hosts]] entry for the machine carries firedancer_url. That key
# arrived in this perch release; an older perch refuses a config that has it.
PERCH_FIREDANCER_MIN="1.6.0"

# perch_firedancer_on_cmd <user> <firedancer config> — root shell text that
# points the perch on this host at its Firedancer's metrics. Says nothing on a
# host without perch. Leaves the config alone, and says why, when perch is too
# old, when no [[hosts]] entry is clearly this machine, or when perch itself
# turns the new config down.
perch_firedancer_on_cmd() {
  perch_cfg_line "$1"
  printf 'perch_bin="/home/%s/bin/perch"; [ -x "$perch_bin" ] || perch_bin=$(command -v perch 2>/dev/null || true)\n' "$1"
  printf 'perch_fd_config="%s"; perch_fd_min="%s"\n' "$2" "$PERCH_FIREDANCER_MIN"
  cat <<'PERCH'
if [ -f "$perch_cfg" ] && [ -n "$perch_bin" ]; then
  # A perch in the validator user's home is that user's file: run it as them,
  # never as root. Its config names secrets held in the unit's environment
  # file, which is read line by line here and never run.
  perch_owner=$(stat -c %U "$perch_bin" 2>/dev/null || true)
  perch_env=$(systemctl show -p EnvironmentFiles --value perch 2>/dev/null | awk '{ print $1; exit }')
  perch_run() {
    (
      if [ -n "$perch_env" ] && [ -f "$perch_env" ]; then
        while IFS='=' read -r perch_k perch_v; do
          case "$perch_k" in ""|\#*) continue ;; esac
          perch_v="${perch_v#\"}"; perch_v="${perch_v%\"}"
          export "$perch_k=$perch_v" 2>/dev/null || true
        done < "$perch_env"
      fi
      if [ "$(id -u)" = 0 ] && [ -n "$perch_owner" ] && [ "$perch_owner" != root ]; then
        runuser -u "$perch_owner" -- "$perch_bin" "$@"
      else
        "$perch_bin" "$@"
      fi
    )
  }
  perch_ver=$(perch_run --version 2>/dev/null | awk '{ print $2; exit }')
  perch_fd_addr=$(awk '/^[[:space:]]*\[/ { s = ($1 == "[tiles.metric]") } s && $1 == "prometheus_listen_address" { gsub(/"/, "", $3); print $3; exit }' "$perch_fd_config" 2>/dev/null)
  perch_fd_port=$(awk '/^[[:space:]]*\[/ { s = ($1 == "[tiles.metric]") } s && $1 == "prometheus_listen_port" { print $3; exit }' "$perch_fd_config" 2>/dev/null)
  case "$perch_fd_addr" in ""|0.0.0.0) perch_fd_addr="127.0.0.1" ;; esac
  perch_fd_url="http://${perch_fd_addr}:${perch_fd_port:-7999}/metrics"
  if grep -q "^[[:space:]]*firedancer_url[[:space:]]*=[[:space:]]*\"${perch_fd_url}\"" "$perch_cfg"; then
    echo "perch: already reads Firedancer's metrics at ${perch_fd_url}"
  elif [ "$(printf '%s\n' "$perch_fd_min" "${perch_ver:-0}" | sort -V | head -1)" != "$perch_fd_min" ]; then
    echo "perch: ${perch_ver:-this version} cannot read Firedancer's metrics — that needs perch ${perch_fd_min} or newer. Upgrade perch, then run cutover again."
  else
    # The entry for this machine: the only one there is, or the only one whose
    # node_exporter is on loopback. The new line goes right under its url.
    cp -p "$perch_cfg" "$perch_cfg.new"
    awk -v fd="$perch_fd_url" '
      NR == FNR {
        if ($0 ~ /^[[:space:]]*\[/) { cur = 0; if ($0 ~ /^[[:space:]]*\[\[hosts\]\]/) cur = ++n }
        else if (cur && $0 ~ /^[[:space:]]*url[[:space:]]*=.*(127\.0\.0\.1|localhost|\[::1\])/) { if (!islocal[cur]++) { nlocal++; pick_local = cur } }
        next
      }
      FNR == 1 { pick = (n == 1) ? 1 : (nlocal == 1 ? pick_local : 0); cur = 0; n = 0 }
      $0 ~ /^[[:space:]]*\[/ { cur = 0; if ($0 ~ /^[[:space:]]*\[\[hosts\]\]/) cur = ++n }
      cur && cur == pick && $0 ~ /^[[:space:]]*firedancer_url[[:space:]]*=/ { next }
      { print }
      cur && cur == pick && !done && $0 ~ /^[[:space:]]*url[[:space:]]*=/ { print "firedancer_url = \"" fd "\""; done = 1 }
      END { exit done ? 0 : (n ? 3 : 4) }' "$perch_cfg" "$perch_cfg" > "$perch_cfg.new" && perch_fd_set=yes || perch_fd_set=$?
    if [ "$perch_fd_set" = 4 ]; then
      echo "perch: $perch_cfg has no [[hosts]] entry for this machine, which is where Firedancer's metrics go. Add one (name, node_exporter url) with: firedancer_url = \"${perch_fd_url}\""
    elif [ "$perch_fd_set" != yes ]; then
      echo "perch: no [[hosts]] entry in $perch_cfg is clearly this machine — add this line to the right one yourself: firedancer_url = \"${perch_fd_url}\""
    elif perch_run --config "$perch_cfg" --check-config >/dev/null 2>&1 && ! perch_run --config "$perch_cfg.new" --check-config >/dev/null 2>&1; then
      echo "perch: it turned down the config with firedancer_url in it — left as it was"
    else
      cat "$perch_cfg.new" > "$perch_cfg"
      systemctl try-restart perch 2>/dev/null || true
      echo "perch: now reads Firedancer's metrics at ${perch_fd_url}"
    fi
    rm -f "$perch_cfg.new"
  fi
fi
PERCH
}

# perch_firedancer_off_cmd <user> — the way back, for a host returning to Agave,
# where nothing answers on that port and perch would page for it.
perch_firedancer_off_cmd() {
  perch_cfg_line "$1"
  cat <<'PERCH'
if [ -f "$perch_cfg" ] && grep -q '^[[:space:]]*firedancer_url[[:space:]]*=' "$perch_cfg"; then
  grep -v '^[[:space:]]*firedancer_url[[:space:]]*=' "$perch_cfg" > "$perch_cfg.new"
  cat "$perch_cfg.new" > "$perch_cfg"
  rm -f "$perch_cfg.new"
  systemctl try-restart perch 2>/dev/null || true
  echo "perch: no longer reads Firedancer's metrics"
fi
PERCH
}

# perch_local_rpc_dead_cmd <user> — shell text that prints yes when perch has an
# RPC endpoint on this machine that nothing listens on, no otherwise. Only the
# [[endpoints]] blocks count: perch also reads node_exporter and its peers on
# local addresses, and those are not the validator's RPC. Run as the validator
# user it sees a perch in their home; a system-wide config is not readable to
# them and reads as no.
perch_local_rpc_dead_cmd() {
  perch_cfg_line "$1"
  cat <<'EOF'
if [ -f "$perch_cfg" ] && awk 'BEGIN { RS = "" }
    /\[\[endpoints\]\]/ && match($0, /:\/\/(127\.0\.0\.1|localhost):[0-9]+/) {
      port = substr($0, RSTART, RLENGTH); sub(/.*:/, "", port)
      if (system("ss -lnt 2>/dev/null | grep -q \":" port " \"") != 0) dead = 1
    }
    END { exit dead ? 0 : 1 }' "$perch_cfg"; then echo yes; else echo no; fi
EOF
}
