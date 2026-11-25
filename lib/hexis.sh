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

# hexis_require_credentials <jup-key: yes|no> — stop when a credential the run
# is about to write to the host was never given. The Jupiter key is only needed
# when arb-config.toml is generated, not when one is uploaded.
hexis_require_credentials() {
  local missing=()
  [[ "$1" == "yes" ]] && ! $HEXIS_JUP_KEY_SET && missing+=("the Jupiter API key: --hexis-jup-key <key> or HEXIS_JUP_KEY")
  $HEXIS_METRICS_CONFIG_SET || missing+=("the arb metrics string: --hexis-metrics-config <str> or SOLANA_METRICS_CONFIG_ARB")
  [[ ${#missing[@]} -eq 0 ]] && return 0
  log_error "Hexis credentials are not kept in this repository. Missing:"
  local m
  for m in "${missing[@]}"; do log_error "  - $m"; done
  log_error "Put them in ${HEXIS_ENV_FILE} (see hexis.env.example) to give them once."
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

# perch_maint_cmd <user> <deadline> [root] — shell text that declares the
# restart to perch when the host has it, and says nothing when it does not.
# Never fails the caller: a restart goes ahead even if perch cannot be told.
# With "root" the text is for a root shell and drops to the user, who owns
# perch's config.
perch_maint_cmd() {
  local maint="/home/$1/perch/maint" run=""
  [[ "${3:-}" == "root" ]] && run="runuser -u $1 -- "
  printf 'if [ -x %s ]; then %s%s restart %s || echo "perch: could not declare the restart — it may page"; fi' \
    "$maint" "$run" "$maint" "$2"
}

# perch_local_rpc_off_cmd <user> — root shell text for a host that has just
# moved to Firedancer. perch usually watches the validator's own RPC port as one
# of its endpoints; Firedancer runs without RPC, so that endpoint is dead from
# then on and keeps perch from seeing the validator recover. Every [[endpoints]]
# block that points at this machine and has nothing listening on its port is
# removed, the old config is kept beside it as config.toml.bak-pre-firedancer,
# and perch is restarted. Left alone when no other endpoint would remain.
perch_local_rpc_off_cmd() {
  cat <<EOF
perch_cfg="/home/$1/perch/config.toml"
EOF
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
  cat <<EOF
perch_cfg="/home/$1/perch/config.toml"
if [ -f "\$perch_cfg.bak-pre-firedancer" ]; then
  mv -f "\$perch_cfg.bak-pre-firedancer" "\$perch_cfg"
  systemctl try-restart perch 2>/dev/null || true
  echo "perch: config from before Firedancer put back"
fi
EOF
}

# The Hexis builds, Agave and Firedancer alike, exist for mainnet only.
MAINNET_GENESIS_HASH="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"

# perch_local_rpc_dead_cmd <user> — shell text that prints yes when perch has an
# RPC endpoint on this machine that nothing listens on, no otherwise. Only the
# [[endpoints]] blocks count: perch also reads node_exporter and its peers on
# local addresses, and those are not the validator's RPC.
perch_local_rpc_dead_cmd() {
  cat <<EOF
perch_cfg="/home/$1/perch/config.toml"
EOF
  cat <<'EOF'
if [ -f "$perch_cfg" ] && awk 'BEGIN { RS = "" }
    /\[\[endpoints\]\]/ && match($0, /:\/\/(127\.0\.0\.1|localhost):[0-9]+/) {
      port = substr($0, RSTART, RLENGTH); sub(/.*:/, "", port)
      if (system("ss -lnt 2>/dev/null | grep -q \":" port " \"") != 0) dead = 1
    }
    END { exit dead ? 0 : 1 }' "$perch_cfg"; then echo yes; else echo no; fi
EOF
}
