#!/usr/bin/env bash
#
#   █████╗ ██████╗ ██╗███████╗███████╗
#  ██╔══██╗██╔══██╗██║██╔════╝██╔════╝
#  ███████║██████╔╝██║███████╗█████╗
#  ██╔══██║██╔══██╗██║╚════██║██╔══╝
#  ██║  ██║██║  ██║██║███████║███████╗
#  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚══════╝╚══════╝
#
# Solana Validator Server Setup Script
#
# Idempotent script that configures a remote server (via SSH) to run a Solana validator.
#
# Prerequisites:
#   - SSH access to the target server (key-based)
#   - A staked_identity.json file (validator identity keypair with a vote account already configured)
#   - Solana CLI installed locally
#   - Server has Ubuntu 24.04 (or compatible) installed
#   - Server has NVMe drives available for ledger/accounts/snapshots
#
# Usage:
#   ./arise.sh \
#     --host <user@host> \
#     --ssh-key <path-to-ssh-key> \
#     --identity <path-to-staked_identity.json> \
#     --vote-account <vote-account-pubkey> \
#     --network <testnet|mainnet> \
#     [--ledger-disk /dev/nvme0n1] \
#     [--accounts-disk /dev/nvme1n1] \
#     [--no-auto-disks] \
#     [--swap-size 128G] \
#     [--dry-run]

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
NETWORK="testnet"
LEDGER_DISK=""
ACCOUNTS_DISK=""
SWAP_SIZE="128G"
AUTO_DISKS=true
DRY_RUN=false
SSH_HOST=""
SSH_KEY=""
ROOT_HOST=""
IDENTITY_FILE=""
VOTE_ACCOUNT=""
COMMISSION_BPS=""
SOL_USER="sol"
JITO_REGION=""
GITHUB_SSH_KEY=""
JITO_REPO_URL="git@github.com:jito-foundation/jito-solana.git"
BUILD_JITO_FORCED=false  # --build-jito: build from source even when --hexis supplies the binary

# XDP (Anza accelerated retransmit) — https://www.anza.xyz/blog/agave-xdp-setup-guide
# Cluster metrics (SFDP). Empty disables the export; default is per-network.
METRICS_CONFIG="${SOLANA_METRICS_CONFIG:-}"
METRICS_CONFIG_SET=false

ENABLE_XDP=true
XDP_CPU_CORES="1"        # value for --experimental-retransmit-xdp-cpu-cores
POH_PINNED_CORE="10"     # value for --experimental-poh-pinned-cpu-core (separate physical core)
XDP_INTERFACE=""         # override auto-detected NIC (use bond member for bonded setups)
XDP_ZERO_COPY="auto"     # auto|on|off — auto disables for bnxt_en/ice drivers

# ---------------------------------------------------------------------------
# Hexis arb client — off unless --hexis is passed. Mainnet only.
# Config defaults live in lib/hexis.sh.
# ---------------------------------------------------------------------------
ENABLE_HEXIS=false
HEXIS_DIR="/home/${SOL_USER}/hexis"
HEXIS_TAG=""                 # release tag — downloaded locally with gh, then scp'd
HEXIS_BINARY=""              # pre-downloaded agave-validator binary (instead of --hexis-tag)
HEXIS_SETUP_BINARY=""        # pre-downloaded hexis-setup binary
HEXIS_CONFIG=""              # upload this arb-config.toml verbatim instead of generating one
HEXIS_SIGNER=""              # local arb signer keypair; generated on the server when not given
HEXIS_CONTROL=true           # [control] — inbound gRPC that Hexis dumpd/ops poll

# ---------------------------------------------------------------------------
# Jito region configs: REGION|BLOCK_ENGINE_URL|SHRED_RECEIVER|NTP_SERVER
# ---------------------------------------------------------------------------
MAINNET_REGIONS=(
  "amsterdam|https://amsterdam.mainnet.block-engine.jito.wtf|74.118.140.240:1002|ntp.amsterdam.jito.wtf"
  "dublin|https://dublin.mainnet.block-engine.jito.wtf|64.130.61.8:1002|ntp.dublin.jito.wtf"
  "frankfurt|https://frankfurt.mainnet.block-engine.jito.wtf|64.130.50.14:1002|ntp.frankfurt.jito.wtf"
  "london|https://london.mainnet.block-engine.jito.wtf|64.130.46.153:1002|ntp.london.jito.wtf"
  "new-york|https://ny.mainnet.block-engine.jito.wtf|141.98.216.96:1002|ntp.dallas.jito.wtf"
  "salt-lake-city|https://slc.mainnet.block-engine.jito.wtf|64.130.53.8:1002|ntp.slc.jito.wtf"
  "singapore|https://singapore.mainnet.block-engine.jito.wtf|202.8.11.224:1002|ntp.singapore.jito.wtf"
  "tokyo|https://tokyo.mainnet.block-engine.jito.wtf|202.8.9.160:1002|ntp.tokyo.jito.wtf"
)

TESTNET_REGIONS=(
  "dallas|https://dallas.testnet.block-engine.jito.wtf|141.98.218.12:1002|ntp.dallas.jito.wtf"
  "new-york|https://ny.testnet.block-engine.jito.wtf|64.130.35.224:1002|ntp.dallas.jito.wtf"
)

# ---------------------------------------------------------------------------
# BloXroute shred receiver configs: REGION|LAT,LON|SHRED1,SHRED2
# ---------------------------------------------------------------------------
BLOXROUTE_REGIONS=(
  "frankfurt|50.1109,8.6821|fra1-shreds.blxrbdn.com:8888,fra2-shreds.blxrbdn.com:8888"
  "amsterdam|52.3676,4.9041|ams1-shreds.blxrbdn.com:8888,ams2-shreds.blxrbdn.com:8888"
  "new-york|40.7128,-74.0060|ny1-shreds.blxrbdn.com:8888,ny2-shreds.blxrbdn.com:8888"
  "singapore|1.3521,103.8198|sg1-shreds.blxrbdn.com:8888,sg2-shreds.blxrbdn.com:8888"
  "sao-paulo|-23.5505,-46.6333|sp1-shreds.blxrbdn.com:8888,sp2-shreds.blxrbdn.com:8888"
  "south-africa|-33.9249,18.4241|sa1-shreds.blxrbdn.com:8888,sa2-shreds.blxrbdn.com:8888"
)


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Required:
  --host <ip-or-hostname>       Server IP or hostname (e.g., 192.168.1.100)
  --ssh-key <path>              Path to SSH private key
  --identity <path>             Path to staked_identity.json
  --vote-account <pubkey>       Vote account public key
  --commission-bps <bps>        Jito commission in basis points — the cut taken from
                                Jito MEV tips via the tip distribution program
                                (mainnet, e.g., 0 = 0%, 500 = 5%). This is the Jito
                                tip commission, NOT the validator vote commission.

Bootstrap (for fresh servers):
  --root-user <user>            Initial SSH user with root/sudo access (default: root)
                                Used to create sol user and add SSH key, then
                                reconnects as sol for the rest of the setup.
                                Root may log in with a password instead of
                                the key — it is asked for once

Optional:
  --github-ssh-key <path>       SSH key for GitHub (to clone jito-solana repo)
  --jito-repo <url>             Jito-Solana git repo to build from
                                (default: git@github.com:jito-foundation/jito-solana.git)
  --build-jito                  Build jito-solana from source even with --hexis.
                                Off by default: the Hexis release ships the
                                validator binary, so the source build is skipped
                                and the prebuilt Solana CLI is installed instead
  --network <testnet|mainnet>   Network to join (default: testnet)
  --metrics-config <str>        SOLANA_METRICS_CONFIG exported by validator.sh.
                                Defaults to the cluster metrics endpoint the SFDP
                                requires. Pass "" to publish no cluster metrics
  --jito-region <region>        Jito region (auto-detected from server IP if omitted)
                                Mainnet: amsterdam, dublin, frankfurt, london,
                                         new-york, salt-lake-city, singapore, tokyo
                                Testnet: dallas, new-york
  --ledger-disk <device>        Block device for ledger (e.g., /dev/nvme0n1)
                                Disables auto-disk detection when specified
  --accounts-disk <device>      Block device for accounts (e.g., /dev/nvme1n1)
                                Disables auto-disk detection when specified
  --no-auto-disks               Disable auto-discovery of NVMe drives
  --swap-size <size>            Swap file size (default: 128G)
  --dry-run                     Print commands without executing
  -h, --help                    Show this help

XDP (accelerated retransmit, per Anza XDP setup guide):
  XDP is set up by default: grant the validator the required capabilities,
  tune NIC ring sizes to powers of 2, and add the experimental retransmit/PoH
  flags. Requires Agave v3.0.9+ and kernel 6.8+ (6.14+ for the igb driver).
  --no-xdp                      Disable XDP setup entirely
  --xdp-cpu-cores <n>           Value for --experimental-retransmit-xdp-cpu-cores
                                (default: 1)
  --poh-pinned-core <n>         Value for --experimental-poh-pinned-cpu-core
                                (default: 10). MUST be a different physical core
                                than the XDP cores.
  --xdp-interface <iface>       NIC to attach XDP to (default: auto-detect from the
                                default route; bond members are resolved automatically)
  --xdp-zero-copy <auto|on|off> Zero-copy mode (default: auto). Auto disables it for
                                the bnxt_en and ice drivers, which don't support it.

Hexis arb client (https://github.com/hexishq/hexis-validator-docs):
  Off by default. Mainnet only. Installs the Hexis agave-validator build into
  ${HEXIS_DIR}, writes arb-config.toml, and adds --arb-config to validator.sh.
  The pipeline always boots DISABLED — run ${HEXIS_DIR}/arb-enable.sh after start.
  --hexis                       Enable Hexis arb client setup
  --hexis-tag <tag>             Release tag to fetch with the local gh CLI from
                                ${HEXIS_REPO}
  --hexis-binary <path>         Pre-downloaded agave-validator binary to upload
                                (use instead of --hexis-tag)
  --hexis-setup-binary <path>   Pre-downloaded hexis-setup binary (LUT, marginfi,
                                token-ledger tooling)
  --hexis-setup-tag <tag>       Release tag for hexis-setup — it ships separately
                                from the validator (default: v1.0-hexis-setup).
                                Empty string skips it
  --hexis-config <path>         Upload this arb-config.toml verbatim instead of
                                generating one from the flags below
  --hexis-signer <path>         Arb signer keypair to copy to the server — the
                                signing_key.json Hexis gave you. Generated on the
                                server when omitted. Fund it: it pays the fees on
                                arb transactions
  --hexis-dir <path>            Install dir (default: /home/sol/hexis)
  --hexis-program-id <pubkey>   On-chain arb program
  --hexis-profit-wallet <pk>    Address the program pays profit into. Defaults to the
                                Hexis shared rewards pool. Only set this if Hexis
                                hands you a different pool address
  --hexis-jup-key <key>         Jupiter API key. Defaults to the Hexis fleet key
                                (or set \$HEXIS_JUP_KEY)
  --hexis-metrics-config <str>  SOLANA_METRICS_CONFIG_ARB value exported by
                                validator.sh. Defaults to the Hexis metrics host
                                (or set \$SOLANA_METRICS_CONFIG_ARB)
  --hexis-lookup-tables <list>  Comma-separated extra address lookup tables
  --hexis-jupiter-token-ledger <pubkey>
  --hexis-okx-token-ledger <pubkey>
  --hexis-base-mints <list>     Comma-separated base mints (order matters)
  --hexis-marginfi-account <pk> marginfi v2 account for flash loans. Defaults to the
                                one from the Hexis config, whose authority is the
                                arb signer they issued
  --no-hexis-flash-loans        Drop [flash_loan] entirely — flash loans off
  --hexis-marginfi-banks <list> Comma-separated banks, one per base mint, same order
  --hexis-marginfi-program-id <pubkey>
  --hexis-control-bind <addr>   Control listen address (default: 0.0.0.0:18082)
  --hexis-control-allow <cidr>  Source allowed to reach the Control port
                                (default: 188.40.61.182)
  --no-hexis-control            Do not expose the Control port at all

Disk selection priority:
  1. Explicit --ledger-disk / --accounts-disk flags (disables auto-detection)
  2. Auto-detection (default): scans server for unused/unformatted NVMe drives
  3. Falls back to /home/sol/ directories if no drives found
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)          SSH_HOST="$2";        shift 2 ;;
    --root-user)     ROOT_HOST="$2";      shift 2 ;;
    --ssh-key)       SSH_KEY="$2";         shift 2 ;;
    --identity)      IDENTITY_FILE="$2";   shift 2 ;;
    --vote-account)  VOTE_ACCOUNT="$2";    shift 2 ;;
    --commission-bps) COMMISSION_BPS="$2"; shift 2 ;;
    --github-ssh-key) GITHUB_SSH_KEY="$2"; shift 2 ;;
    --jito-repo)     JITO_REPO_URL="$2";   shift 2 ;;
    --build-jito)    BUILD_JITO_FORCED=true; shift ;;
    --jito-region)   JITO_REGION="$2";     shift 2 ;;
    --metrics-config) METRICS_CONFIG="$2"; METRICS_CONFIG_SET=true; shift 2 ;;
    --network)       NETWORK="$2";         shift 2 ;;
    --ledger-disk)   LEDGER_DISK="$2"; AUTO_DISKS=false; shift 2 ;;
    --accounts-disk) ACCOUNTS_DISK="$2"; AUTO_DISKS=false; shift 2 ;;
    --no-auto-disks) AUTO_DISKS=false;     shift   ;;
    --swap-size)     SWAP_SIZE="$2";       shift 2 ;;
    --enable-xdp)    ENABLE_XDP=true;      shift   ;;
    --no-xdp)        ENABLE_XDP=false;     shift   ;;
    --xdp-cpu-cores) XDP_CPU_CORES="$2";   shift 2 ;;
    --poh-pinned-core) POH_PINNED_CORE="$2"; shift 2 ;;
    --xdp-interface) XDP_INTERFACE="$2";   shift 2 ;;
    --xdp-zero-copy) XDP_ZERO_COPY="$2";   shift 2 ;;
    --hexis)         ENABLE_HEXIS=true;    shift   ;;
    --hexis-tag)     HEXIS_TAG="$2";       shift 2 ;;
    --hexis-binary)  HEXIS_BINARY="$2";    shift 2 ;;
    --hexis-setup-binary) HEXIS_SETUP_BINARY="$2"; shift 2 ;;
    --hexis-setup-tag) HEXIS_SETUP_TAG="$2"; shift 2 ;;
    --hexis-config)  HEXIS_CONFIG="$2";    shift 2 ;;
    --hexis-signer)  HEXIS_SIGNER="$2";    shift 2 ;;
    --hexis-dir)     HEXIS_DIR="$2";       shift 2 ;;
    --hexis-program-id)   HEXIS_PROGRAM_ID="$2";   shift 2 ;;
    --hexis-profit-wallet) HEXIS_PROFIT_WALLET="$2"; shift 2 ;;
    --hexis-jup-key) HEXIS_JUP_KEY="$2";   shift 2 ;;
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
    --dry-run)       DRY_RUN=true;         shift   ;;
    -h|--help)       usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
[[ -z "$SSH_HOST" ]]      && { log_error "--host is required";         usage; }
[[ -z "$SSH_KEY" ]]       && { log_error "--ssh-key is required";      usage; }
[[ -z "$IDENTITY_FILE" ]] && { log_error "--identity is required";     usage; }
[[ -z "$VOTE_ACCOUNT" ]]  && { log_error "--vote-account is required"; usage; }

[[ ! -f "$SSH_KEY" ]]       && { log_error "SSH key not found: $SSH_KEY";             exit 1; }
[[ ! -f "$IDENTITY_FILE" ]] && { log_error "Identity file not found: $IDENTITY_FILE"; exit 1; }

if [[ "$NETWORK" != "testnet" && "$NETWORK" != "mainnet" ]]; then
  log_error "--network must be 'testnet' or 'mainnet'"
  exit 1
fi

if $ENABLE_XDP; then
  if [[ "$XDP_ZERO_COPY" != "auto" && "$XDP_ZERO_COPY" != "on" && "$XDP_ZERO_COPY" != "off" ]]; then
    log_error "--xdp-zero-copy must be 'auto', 'on', or 'off'"
    exit 1
  fi
  if [[ "$XDP_CPU_CORES" == "$POH_PINNED_CORE" ]]; then
    log_error "--xdp-cpu-cores ($XDP_CPU_CORES) and --poh-pinned-core ($POH_PINNED_CORE) must differ — XDP and PoH require separate physical cores"
    exit 1
  fi
fi

if $ENABLE_HEXIS; then
  if [[ "$NETWORK" != "mainnet" ]]; then
    log_error "--hexis requires --network mainnet (the arb config and its pools are mainnet-only)"
    exit 1
  fi
  if [[ -n "$HEXIS_TAG" && -n "$HEXIS_BINARY" ]]; then
    log_error "Pass either --hexis-tag or --hexis-binary, not both"
    exit 1
  fi
  if [[ -n "$HEXIS_TAG" ]]; then
    if ! command -v gh &>/dev/null; then
      log_error "--hexis-tag needs the gh CLI locally. Install it, or download the release yourself and pass --hexis-binary"
      exit 1
    fi
    # The download is a GitHub API call from THIS machine using gh's token —
    # --github-ssh-key is for git-over-SSH on the server and does not apply here.
    if ! gh auth status &>/dev/null; then
      log_error "gh is not authenticated — run 'gh auth login' with an account that can see ${HEXIS_REPO}"
      exit 1
    fi
  fi
  for f in "$HEXIS_BINARY" "$HEXIS_SETUP_BINARY" "$HEXIS_CONFIG" "$HEXIS_SIGNER"; do
    [[ -n "$f" && ! -f "$f" ]] && { log_error "File not found: $f"; exit 1; }
  done
  if [[ "$HEXIS_CONTROL_BIND" == 127.0.0.1:* || "$HEXIS_CONTROL_BIND" == localhost:* ]]; then
    log_error "--hexis-control-bind must not be loopback — Hexis dials the host directly"
    exit 1
  fi
fi

# Nothing is built from source unless there is a GitHub key, and --hexis already
# ships a validator binary. Decided here because Step 6 (Rust) depends on it too.
BUILD_JITO=false
if [[ -n "$GITHUB_SSH_KEY" ]] && { ! $ENABLE_HEXIS || $BUILD_JITO_FORCED; }; then
  BUILD_JITO=true
fi

# Strip user@ prefix from --host if accidentally included
SSH_HOST="${SSH_HOST##*@}"

# Build SSH destinations
SOL_HOST="${SOL_USER}@${SSH_HOST}"
ROOT_DEST=""
if [[ -n "$ROOT_HOST" ]]; then
  ROOT_DEST="${ROOT_HOST}@${SSH_HOST}"
fi

# ---------------------------------------------------------------------------
# Network-specific config
# ---------------------------------------------------------------------------
if [[ "$NETWORK" == "testnet" ]]; then
  ENTRYPOINTS=(
    "entrypoint.testnet.solana.com:8001"
    "entrypoint2.testnet.solana.com:8001"
    "entrypoint3.testnet.solana.com:8001"
  )
  GENESIS_HASH="4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY"
  KNOWN_VALIDATORS=(
    "5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on"
    "7XSY3MrYnK8vq693Rju17bbPkCN3Z7KvvfvJx4kdrsSY"
    "Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN"
    "9QxCLckBiJc783jnMvXZubK4wH86Eqqvashtrwvcsgkv"
  )
else
  ENTRYPOINTS=(
    "entrypoint.mainnet-beta.solana.com:8001"
    "entrypoint2.mainnet-beta.solana.com:8001"
    "entrypoint3.mainnet-beta.solana.com:8001"
  )
  GENESIS_HASH="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"
  KNOWN_VALIDATORS=(
    "7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2"
    "GdnSyH3YtwcxFvQrVVJMm1JhTS4QVX7MFsX56uJLUfiZ"
    "DE1bawNcRJB9rVm3buyMVfr8mBEoyyu73NBovf2oXJsJ"
    "CakcnaRDHka2gXyfbEd2d3xsvkJkqsLw2akB3zsN1D2S"
  )
fi

# SFDP requires validators to publish cluster metrics. Only default it when the
# operator did not pass --metrics-config at all, so "" stays an explicit opt-out.
if ! $METRICS_CONFIG_SET && [[ -z "$METRICS_CONFIG" ]]; then
  if [[ "$NETWORK" == "mainnet" ]]; then
    METRICS_CONFIG="$SFDP_METRICS_MAINNET"
  else
    METRICS_CONFIG="$SFDP_METRICS_TESTNET"
  fi
fi
if [[ -z "$METRICS_CONFIG" ]]; then
  log_warn "No SOLANA_METRICS_CONFIG — this validator will not publish cluster metrics, which the SFDP requires"
fi

# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o IdentitiesOnly=yes -i $SSH_KEY"

# The root user is only used by Step 0 to create sol, and may not have our key
# yet — ssh tries the key, then falls back to the root password. The shared
# control socket means that password is typed once, not once per connection.
# The path lives under /tmp because sockets have a ~104-char limit on macOS.
ROOT_CTL_DIR=""
ROOT_SSH_OPTS="$SSH_OPTS"
if [[ -n "$ROOT_DEST" ]] && ! $DRY_RUN; then
  ROOT_CTL_DIR=$(mktemp -d /tmp/arise.XXXXXX)
  ROOT_SSH_OPTS="$SSH_OPTS -o ControlMaster=auto -o ControlPath=${ROOT_CTL_DIR}/root -o ControlPersist=300"
  trap 'ssh -o ControlPath="${ROOT_CTL_DIR}/root" -O exit "$ROOT_DEST" 2>/dev/null; rm -rf "$ROOT_CTL_DIR"' EXIT
fi

# Copy-pasteable form of the connection these scripts make themselves.
# IdentitiesOnly stops ssh offering every agent key and tripping MaxAuthTries.
SSH_CMD="ssh -o IdentitiesOnly=yes -i ${SSH_KEY}"

# Run a script as root on the server, via sol + sudo. Root itself is only used
# by Step 0 — SSH hardening turns off password auth, so a root login that came
# in on a password would stop working partway through the run.
root_script() {
  if $DRY_RUN; then
    echo "[DRY RUN] root_script on $SOL_HOST: <script>"
    cat
    return
  fi
  local tmpscript
  tmpscript=$(mktemp)
  cat > "$tmpscript"
  scp -q $SSH_OPTS "$tmpscript" "$SOL_HOST:/tmp/_setup_script.sh"
  rm -f "$tmpscript"
  ssh $SSH_OPTS "$SOL_HOST" "echo '${SUDO_PASS}' | sudo -S bash /tmp/_setup_script.sh; rm -f /tmp/_setup_script.sh"
}

# Run a script as the sol user on the server (no sudo)
sol_script() {
  if $DRY_RUN; then
    echo "[DRY RUN] sol_script on $SOL_HOST: <script>"
    cat
    return
  fi
  local tmpscript
  tmpscript=$(mktemp)
  cat > "$tmpscript"
  scp -q $SSH_OPTS "$tmpscript" "$SOL_HOST:/tmp/_setup_script.sh"
  rm -f "$tmpscript"
  ssh $SSH_OPTS "$SOL_HOST" "bash /tmp/_setup_script.sh; rm -f /tmp/_setup_script.sh"
}

# Run a command as sol
remote() {
  if $DRY_RUN; then
    echo "[DRY RUN] ssh $SOL_HOST: $*"
  else
    ssh $SSH_OPTS "$SOL_HOST" "$@"
  fi
}

# ---------------------------------------------------------------------------
# Step 0: Bootstrap sol user (only when --root-user is provided)
# ---------------------------------------------------------------------------
if [[ -n "$ROOT_DEST" ]] && ! $DRY_RUN; then
  if ssh $SSH_OPTS -o BatchMode=yes -o ConnectTimeout=5 "$SOL_HOST" "echo ok" &>/dev/null; then
    log_info "Step 0: Sol user already accessible via SSH — skipping bootstrap"
  else
    log_info "Step 0: Bootstrapping sol user via ${ROOT_DEST}"

    # Get the public key corresponding to the provided SSH private key
    SSH_PUBKEY=$(ssh-keygen -y -f "$SSH_KEY")
    if [[ -z "$SSH_PUBKEY" ]]; then
      log_error "Could not derive public key from $SSH_KEY"
      exit 1
    fi

    # Ask for sol's password up front so the root session is not left idle
    read -rsp "Set password for ${SOL_USER} user (used for sudo): " SOL_PASS
    echo ""
    read -rsp "Confirm password: " SOL_PASS_CONFIRM
    echo ""
    if [[ "$SOL_PASS" != "$SOL_PASS_CONFIRM" ]]; then
      log_error "Passwords do not match"
      exit 1
    fi

    # Build the bootstrap script. The password travels inside the uploaded file,
    # never on a command line where it would show up in ps.
    CHPASSWD_LINE=$(printf '%q' "${SOL_USER}:${SOL_PASS}")
    BOOT_TMP=$(mktemp)
    cat > "$BOOT_TMP" <<BOOTEOF
#!/bin/bash
set -e

# Create sol user if it doesn't exist
if ! id -u ${SOL_USER} &>/dev/null; then
  adduser --disabled-password --gecos "" ${SOL_USER}
  echo "Created user ${SOL_USER}"
else
  echo "User ${SOL_USER} already exists"
fi

# Grant sudo with password
echo "${SOL_USER} ALL=(ALL:ALL) ALL" > /etc/sudoers.d/${SOL_USER}
chmod 0440 /etc/sudoers.d/${SOL_USER}

# Set up SSH authorized_keys for sol
mkdir -p /home/${SOL_USER}/.ssh
chmod 700 /home/${SOL_USER}/.ssh

# Add the public key (idempotent)
if ! grep -qF "${SSH_PUBKEY}" /home/${SOL_USER}/.ssh/authorized_keys 2>/dev/null; then
  echo "${SSH_PUBKEY}" >> /home/${SOL_USER}/.ssh/authorized_keys
  echo "Added SSH public key to authorized_keys"
else
  echo "SSH public key already in authorized_keys"
fi

chmod 600 /home/${SOL_USER}/.ssh/authorized_keys
chown -R ${SOL_USER}:${SOL_USER} /home/${SOL_USER}/.ssh

printf '%s\n' ${CHPASSWD_LINE} | chpasswd
echo "Sol user bootstrap complete"
BOOTEOF

    # Opens the shared root session — this is where a root password is asked for
    log_info "Connecting to ${ROOT_DEST} (enter the root password if prompted)..."
    if ! ssh $ROOT_SSH_OPTS "$ROOT_DEST" "echo 'SSH connection OK'"; then
      rm -f "$BOOT_TMP"
      log_error "Cannot SSH to ${ROOT_DEST} — check the key/password and host"
      exit 1
    fi

    scp -q $ROOT_SSH_OPTS "$BOOT_TMP" "$ROOT_DEST:/tmp/_bootstrap.sh"
    rm -f "$BOOT_TMP"
    ssh $ROOT_SSH_OPTS "$ROOT_DEST" "chmod 600 /tmp/_bootstrap.sh; sudo bash /tmp/_bootstrap.sh; rc=\$?; rm -f /tmp/_bootstrap.sh; exit \$rc"
    ssh -o ControlPath="${ROOT_CTL_DIR}/root" -O exit "$ROOT_DEST" 2>/dev/null || true
    log_info "Sol user password set"
    SUDO_PASS="$SOL_PASS"

    # Verify we can connect as sol with the key alone
    if ssh $SSH_OPTS -o BatchMode=yes "$SOL_HOST" "echo 'SSH connection as ${SOL_USER} successful'" 2>/dev/null; then
      log_info "Verified SSH access as ${SOL_USER}"
    else
      log_error "Cannot SSH as ${SOL_USER}@${SSH_HOST} — check authorized_keys"
      exit 1
    fi
  fi
fi

# Everything from here on runs as sol, using sudo for root work
if ! $DRY_RUN; then
  if [[ -z "${SUDO_PASS:-}" ]]; then
    read -rsp "Enter sudo password for ${SOL_USER}@${SSH_HOST}: " SUDO_PASS
    echo ""
  fi
  if ! ssh $SSH_OPTS "$SOL_HOST" "echo '${SUDO_PASS}' | sudo -S -v 2>/dev/null"; then
    log_error "Sudo password validation failed"
    exit 1
  fi
  log_info "Sudo access confirmed for ${SOL_USER}"
fi

# ---------------------------------------------------------------------------
# Jito region detection
# ---------------------------------------------------------------------------
get_regions_for_network() {
  if [[ "$NETWORK" == "mainnet" ]]; then
    printf '%s\n' "${MAINNET_REGIONS[@]}"
  else
    printf '%s\n' "${TESTNET_REGIONS[@]}"
  fi
}

lookup_region() {
  local region_name="$1"
  while IFS='|' read -r name block_engine shred_receiver ntp; do
    if [[ "$name" == "$region_name" ]]; then
      echo "${name}|${block_engine}|${shred_receiver}|${ntp}"
      return 0
    fi
  done < <(get_regions_for_network)
  return 1
}

detect_server_location() {
  # Geolocate the server — sets SERVER_IP, SERVER_CITY, SERVER_COUNTRY, SERVER_LAT, SERVER_LON
  # Runs in main shell so variables persist for both Jito and BloXroute detection
  log_info "Detecting server location from IP geolocation..."

  SERVER_GEO=$(ssh $SSH_OPTS "$SOL_HOST" "curl -s https://ipinfo.io 2>/dev/null || curl -s https://ifconfig.co/json 2>/dev/null || true")

  if [[ -z "$SERVER_GEO" ]]; then
    log_warn "Could not determine server location"
    return 1
  fi

  SERVER_CITY=$(echo "$SERVER_GEO" | grep -o '"city"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  SERVER_COUNTRY=$(echo "$SERVER_GEO" | grep -o '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  SERVER_LOC=$(echo "$SERVER_GEO" | grep -o '"loc"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"loc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  SERVER_IP=$(echo "$SERVER_GEO" | grep -o '"ip"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

  log_info "Server IP: ${SERVER_IP:-unknown}"
  log_info "Server location: ${SERVER_CITY:-unknown}, ${SERVER_COUNTRY:-unknown}"

  if [[ -z "$SERVER_LOC" ]]; then
    return 1
  fi

  SERVER_LAT=$(echo "$SERVER_LOC" | cut -d',' -f1)
  SERVER_LON=$(echo "$SERVER_LOC" | cut -d',' -f2)
}

detect_jito_region() {
  # Requires SERVER_LAT and SERVER_LON to be set (via detect_server_location)
  if [[ -z "${SERVER_LAT:-}" || -z "${SERVER_LON:-}" ]]; then
    return 1
  fi

  # Known Jito region coordinates for distance calculation
  declare -A REGION_COORDS
  REGION_COORDS[amsterdam]="52.3676,4.9041"
  REGION_COORDS[dublin]="53.3498,-6.2603"
  REGION_COORDS[frankfurt]="50.1109,8.6821"
  REGION_COORDS[london]="51.5074,-0.1278"
  REGION_COORDS[new-york]="40.7128,-74.0060"
  REGION_COORDS[salt-lake-city]="40.7608,-111.8910"
  REGION_COORDS[singapore]="1.3521,103.8198"
  REGION_COORDS[tokyo]="35.6762,139.6503"
  REGION_COORDS[dallas]="32.7767,-96.7970"

  # Find closest region using simple Euclidean distance (good enough for region selection)
  local best_region=""
  local best_dist=999999

  while IFS='|' read -r name _be _sr _ntp; do
    coords="${REGION_COORDS[$name]:-}"
    [[ -z "$coords" ]] && continue
    rlat=$(echo "$coords" | cut -d',' -f1)
    rlon=$(echo "$coords" | cut -d',' -f2)

    # Approximate distance using awk (squared Euclidean on lat/lon, adjusted for longitude)
    dist=$(awk "BEGIN {
      dlat = $SERVER_LAT - $rlat;
      dlon = ($SERVER_LON - $rlon) * 0.7;
      print sqrt(dlat*dlat + dlon*dlon)
    }")

    if awk "BEGIN { exit !($dist < $best_dist) }"; then
      best_dist="$dist"
      best_region="$name"
    fi
  done < <(get_regions_for_network)

  if [[ -n "$best_region" ]]; then
    echo "$best_region"
    return 0
  fi
  return 1
}

detect_bloxroute_region() {
  local srv_lat="$1"
  local srv_lon="$2"
  local best_region=""
  local best_dist=999999

  for entry in "${BLOXROUTE_REGIONS[@]}"; do
    local name coords shreds
    name=$(echo "$entry" | cut -d'|' -f1)
    coords=$(echo "$entry" | cut -d'|' -f2)
    shreds=$(echo "$entry" | cut -d'|' -f3)
    local rlat rlon
    rlat=$(echo "$coords" | cut -d',' -f1)
    rlon=$(echo "$coords" | cut -d',' -f2)

    dist=$(awk "BEGIN {
      dlat = $srv_lat - $rlat;
      dlon = ($srv_lon - $rlon) * 0.7;
      print sqrt(dlat*dlat + dlon*dlon)
    }")

    if awk "BEGIN { exit !($dist < $best_dist) }"; then
      best_dist="$dist"
      best_region="$shreds"
    fi
  done

  if [[ -n "$best_region" ]]; then
    echo "$best_region"
    return 0
  fi
  return 1
}

# --- Geolocate server (used by both Jito and BloXroute) ---
if ! $DRY_RUN; then
  detect_server_location || true
fi

# --- Resolve Jito region ---
if [[ -z "$JITO_REGION" ]] && ! $DRY_RUN; then
  JITO_REGION=$(detect_jito_region 2>/dev/null) || true
  if [[ -n "$JITO_REGION" ]]; then
    log_info "Auto-selected Jito region: $JITO_REGION"
  else
    log_warn "Could not auto-detect Jito region — you will need to fill in shred receiver and block engine values in validator.sh before starting"
  fi
elif [[ -n "$JITO_REGION" ]]; then
  if ! lookup_region "$JITO_REGION" >/dev/null; then
    log_error "Unknown Jito region: $JITO_REGION"
    log_error "Available regions for $NETWORK:"
    get_regions_for_network | cut -d'|' -f1 | sed 's/^/  /'
    exit 1
  fi
  log_info "Using Jito region: $JITO_REGION"
fi

# Parse the selected region's config
if [[ -n "$JITO_REGION" ]]; then
  REGION_CONFIG=$(lookup_region "$JITO_REGION")
  JITO_BLOCK_ENGINE=$(echo "$REGION_CONFIG" | cut -d'|' -f2)
  JITO_SHRED_RECEIVER=$(echo "$REGION_CONFIG" | cut -d'|' -f3)
  JITO_NTP_SERVER=$(echo "$REGION_CONFIG" | cut -d'|' -f4)
  log_info "Block engine:     $JITO_BLOCK_ENGINE"
  log_info "Shred receiver:   $JITO_SHRED_RECEIVER"
  log_info "NTP server:       $JITO_NTP_SERVER"
fi

# --- Resolve BloXroute shred receivers based on server location ---
BLOXROUTE_SHREDS=""
if [[ "$NETWORK" == "mainnet" && -n "${SERVER_LAT:-}" && -n "${SERVER_LON:-}" ]]; then
  BLOXROUTE_SHREDS=$(detect_bloxroute_region "$SERVER_LAT" "$SERVER_LON" 2>/dev/null) || true
  if [[ -n "$BLOXROUTE_SHREDS" ]]; then
    log_info "BloXroute shreds: $BLOXROUTE_SHREDS"
  else
    log_warn "Could not detect closest BloXroute region"
  fi
fi

# --- Resolve public RPC address from server IP ---
# jag-snap proxies the validator's RPC on port 18899, so when it's enabled
# the validator advertises that port instead of the local 8899.
PUBLIC_RPC_ADDRESS=""
if [[ "$NETWORK" == "mainnet" || -n "$GITHUB_SSH_KEY" ]]; then
  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP=$(ssh $SSH_OPTS "$SOL_HOST" "curl -s https://ipinfo.io/ip 2>/dev/null || curl -s https://ifconfig.me 2>/dev/null || true")
  fi
  if [[ -n "$GITHUB_SSH_KEY" ]]; then
    PUBLIC_RPC_ADDRESS="${SERVER_IP}:18899"
  else
    PUBLIC_RPC_ADDRESS="${SERVER_IP}:8899"
  fi
  log_info "Public RPC address: $PUBLIC_RPC_ADDRESS"
fi

# --- Prompt for commission if not provided (mainnet) ---
if [[ "$NETWORK" == "mainnet" && -z "$COMMISSION_BPS" ]] && ! $DRY_RUN; then
  echo ""
  read -rp "Jito commission in basis points (cut of Jito MEV tips; e.g., 0 = 0%, 500 = 5%, 1000 = 10%) [0]: " COMMISSION_BPS
  COMMISSION_BPS="${COMMISSION_BPS:-0}"
  log_info "Jito commission: ${COMMISSION_BPS} bps"
fi

# ---------------------------------------------------------------------------
# Step 1: System update & base packages
# ---------------------------------------------------------------------------
log_info "Step 1: Updating system and installing base packages"

root_script <<'SCRIPT'
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  curl \
  wget \
  vim \
  jq \
  htop \
  iotop \
  sysstat \
  fail2ban \
  ufw \
  logrotate \
  nvme-cli \
  mdadm \
  ethtool \
  pciutils \
  lshw \
  libssl-dev \
  libudev-dev \
  pkg-config \
  zlib1g-dev \
  llvm \
  clang \
  cmake \
  make \
  libprotobuf-dev \
  protobuf-compiler \
  libclang-dev \
  docker.io
SCRIPT

# ---------------------------------------------------------------------------
# Step 2: System tuning (Anza recommended)
# ---------------------------------------------------------------------------
log_info "Step 2: Applying system tuning parameters"

root_script <<'SCRIPT'
# --- sysctl tuning ---
cat > /etc/sysctl.d/21-agave-validator.conf <<'SYSCTL'
# Agave Validator Recommended Settings

# UDP buffer sizes
net.core.rmem_default = 134217728
net.core.rmem_max = 134217728
net.core.wmem_default = 134217728
net.core.wmem_max = 134217728

# TCP buffer sizes (match UDP tuning)
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 87380 134217728

# Memory mapped files
vm.max_map_count = 1000000

# File descriptors
fs.nr_open = 1000000

# Network tuning
net.core.optmem_max = 134217728
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535

# Swap tuning — prefer keeping validator memory resident
vm.swappiness = 10

# Disk write tuning — optimized for heavy write workloads (ledger/accounts)
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
SYSCTL
sysctl -p /etc/sysctl.d/21-agave-validator.conf

# --- PAM session limits ---
cat > /etc/security/limits.d/90-solana-nofiles.conf <<'LIMITS'
# Solana validator limits
* - nofile 1000000
* - memlock 2000000
LIMITS

# --- systemd DefaultLimitNOFILE ---
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/20-solana-limits.conf <<'SYSD'
[Manager]
DefaultLimitNOFILE=1000000
DefaultLimitMEMLOCK=2000000000
SYSD
systemctl daemon-reload

# --- Disable transparent huge pages (THP) ---
# THP causes latency spikes from background memory compaction
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# Persist THP disable via systemd service
cat > /etc/systemd/system/disable-thp.service <<'THPSERV'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
THPSERV
systemctl daemon-reload
systemctl enable disable-thp.service

# --- NVMe I/O scheduler ---
# Ensure NVMe drives use 'none' scheduler (lowest overhead for NVMe)
for dev in /sys/block/nvme*; do
  if [ -f "$dev/queue/scheduler" ]; then
    echo none > "$dev/queue/scheduler" 2>/dev/null || true
  fi
done

# Persist via udev rule
cat > /etc/udev/rules.d/60-nvme-scheduler.rules <<'UDEV'
ACTION=="add|change", KERNEL=="nvme*", ATTR{queue/scheduler}="none"
UDEV
udevadm control --reload-rules 2>/dev/null || true

# --- CPU performance governor ---
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor || true
  # Persist via systemd service
  cat > /etc/systemd/system/cpu-performance.service <<'CPUSERV'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
ExecStart=/bin/bash -c 'echo 2850000 | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
CPUSERV
  systemctl daemon-reload
  systemctl enable cpu-performance.service
fi

# --- Disable CPU security mitigations ---
# Spectre/Meltdown mitigations cost ~5-10% CPU on dedicated validator hardware
GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ]; then
  if ! grep -q "mitigations=off" "$GRUB_FILE"; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 mitigations=off"/' "$GRUB_FILE"
    update-grub 2>/dev/null || true
    echo "CPU mitigations=off added to GRUB (takes effect on next reboot)"
  else
    echo "CPU mitigations=off already set"
  fi
fi

# --- Disable unnecessary services ---
for svc in snapd snapd.socket snapd.seeded unattended-upgrades apt-daily.timer apt-daily-upgrade.timer; do
  if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
    systemctl disable --now "$svc" 2>/dev/null || true
    echo "Disabled $svc"
  fi
done

# --- IRQ affinity for NIC ---
# Spread network interrupts across all cores instead of hammering core 0
if command -v irqbalance &>/dev/null; then
  systemctl enable --now irqbalance 2>/dev/null || true
  echo "irqbalance enabled"
else
  apt-get install -y irqbalance 2>/dev/null || true
  systemctl enable --now irqbalance 2>/dev/null || true
  echo "irqbalance installed and enabled"
fi

echo "System tuning applied"
SCRIPT

# ---------------------------------------------------------------------------
# Step 3: Configure NTP with Jito servers
# ---------------------------------------------------------------------------
log_info "Step 3: Configuring NTP (chrony) with Jito time server"

NTP_SERVER="${JITO_NTP_SERVER:-pool.ntp.org}"
root_script <<SCRIPT
# Install chrony if not present
if ! command -v chronyd &>/dev/null; then
  apt-get install -y chrony
fi

# Disable other NTP services that conflict
for svc in ntp ntpd systemd-timesyncd; do
  if systemctl is-active "\$svc" &>/dev/null 2>&1; then
    systemctl disable --now "\$svc" 2>/dev/null || true
  fi
done

# Drop Jito NTP config into conf.d (included by main chrony.conf via confdir)
# This adds the Jito server as preferred without touching the existing config
cat > /etc/chrony/conf.d/jito-ntp.conf <<'CHRONYEOF'
# Jito NTP server (same datacenter, sub-ms accuracy)
server ${NTP_SERVER} iburst prefer
CHRONYEOF

systemctl enable --now chrony
systemctl restart chrony

# Verify
chronyc tracking
echo "NTP configured with ${NTP_SERVER}"
SCRIPT

# ---------------------------------------------------------------------------
# Step 4: Disk discovery & setup with fstab persistence
# ---------------------------------------------------------------------------
log_info "Step 4: Setting up disks"

# Check if mounts already exist from a previous run
if $AUTO_DISKS && [[ -z "$LEDGER_DISK" && -z "$ACCOUNTS_DISK" ]]; then
  MOUNTS_EXIST=$(ssh $SSH_OPTS "$SOL_HOST" "mountpoint -q /mnt/ledger 2>/dev/null && mountpoint -q /mnt/accounts 2>/dev/null && echo YES || echo NO")
  if [[ "$MOUNTS_EXIST" == "YES" ]]; then
    log_info "Disks already mounted at /mnt/ledger and /mnt/accounts — skipping discovery"
    LEDGER_DISK="already_mounted"
    ACCOUNTS_DISK="already_mounted"
  fi
fi

# Auto-discover disks if --auto-disks is set and no explicit disks provided
if $AUTO_DISKS && [[ -z "$LEDGER_DISK" && -z "$ACCOUNTS_DISK" ]]; then
  log_info "Auto-discovering unused NVMe drives on server..."

  DISCOVERED_DISKS=$(root_script <<'DISKSCRIPT'
# Find NVMe block devices that are:
#   - Whole disks (not partitions)
#   - Not mounted anywhere
#   - Not the boot/root disk
#   - Have no filesystem OR have no partitions

ROOT_DISK=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null || true)

declare -a available=()

for dev in /dev/nvme*n1; do
  [ -b "$dev" ] || continue
  devname=$(basename "$dev")

  # Skip if this is the root disk
  if [[ "$devname" == "$ROOT_DISK" ]]; then
    continue
  fi

  # Skip if any partition of this disk is mounted
  is_mounted=false
  for part in ${dev}p*; do
    if [ -b "$part" ] && findmnt -n "$part" &>/dev/null; then
      is_mounted=true
      break
    fi
  done
  if findmnt -n "$dev" &>/dev/null; then
    is_mounted=true
  fi
  if $is_mounted; then
    continue
  fi

  # Skip if it already has a filesystem (formatted drive)
  fs_type=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
  if [[ -n "$fs_type" ]]; then
    continue
  fi

  # Get size in bytes (for sorting) and GB (for display)
  size_bytes=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
  size_gb=$((size_bytes / 1073741824))

  # Report: device, fs, size_display, size_bytes
  echo "${dev}|none|${size_gb}GB|${size_bytes}"
  available+=("$dev")
done

if [ ${#available[@]} -eq 0 ]; then
  echo "NO_DISKS_FOUND"
fi
DISKSCRIPT
  )

  if [[ "$DISCOVERED_DISKS" == *"NO_DISKS_FOUND"* ]]; then
    log_warn "No unused NVMe drives found on server"
    log_warn "Falling back to /home/${SOL_USER}/ directories"
  else
    log_info "Discovered unused NVMe drives:"
    # Parse discovered disks and sort by size descending (largest first)
    # Format per line: dev|fs|size_gb|size_bytes
    SORTED_LINES=$(echo "$DISCOVERED_DISKS" | grep -v '^$' | grep -v '^NO_DISKS_FOUND' | sort -t'|' -k4 -rn)

    declare -a DISK_LIST=()
    while IFS='|' read -r dev fs size_gb _size_bytes; do
      [[ -z "$dev" ]] && continue
      log_info "  $dev  filesystem=$fs  size=$size_gb"
      DISK_LIST+=("$dev")
    done <<< "$SORTED_LINES"

    DISK_COUNT=${#DISK_LIST[@]}

    if [[ $DISK_COUNT -ge 2 ]]; then
      LEDGER_DISK="${DISK_LIST[0]}"
      ACCOUNTS_DISK="${DISK_LIST[1]}"
      log_info "Auto-assigned: ledger=$LEDGER_DISK  accounts=$ACCOUNTS_DISK"
    elif [[ $DISK_COUNT -eq 1 ]]; then
      # Single drive: use it for both ledger and accounts (separate dirs)
      LEDGER_DISK="${DISK_LIST[0]}"
      ACCOUNTS_DISK=""
      log_warn "Only 1 unused drive found ($LEDGER_DISK) — will use it for both ledger and accounts"
    fi
  fi
fi

# --- Format and mount function (runs on server) ---
if [[ "$LEDGER_DISK" == "already_mounted" ]]; then
  log_info "Mounts already configured — ensuring ownership"
  root_script <<SCRIPT
chown ${SOL_USER}:${SOL_USER} /mnt/ledger
chown ${SOL_USER}:${SOL_USER} /mnt/accounts
mkdir -p /mnt/ledger/snapshots
chown ${SOL_USER}:${SOL_USER} /mnt/ledger/snapshots
echo "Ownership verified"
SCRIPT
elif [[ -n "$LEDGER_DISK" || -n "$ACCOUNTS_DISK" ]]; then
  root_script <<SCRIPT
setup_disk() {
  local device="\$1"
  local mountpoint="\$2"
  local label="\$3"

  if [[ -z "\$device" ]]; then
    echo "No device specified for \$mountpoint, creating directory only"
    mkdir -p "\$mountpoint"
    chown ${SOL_USER}:${SOL_USER} "\$mountpoint"
    return
  fi

  # Check if already mounted at the right place
  if mountpoint -q "\$mountpoint" 2>/dev/null; then
    echo "\$mountpoint is already mounted"
    chown ${SOL_USER}:${SOL_USER} "\$mountpoint"
    return
  fi

  # Format only if not already ext4
  local current_fs=\$(blkid -o value -s TYPE "\$device" 2>/dev/null || true)
  if [[ "\$current_fs" != "ext4" ]]; then
    echo "Formatting \$device as ext4 with label \$label"
    mkfs.ext4 -F -L "\$label" "\$device"
  else
    echo "\$device is already ext4, skipping format"
  fi

  mkdir -p "\$mountpoint"

  # Add to fstab if not already there (use UUID for reliability)
  local uuid=\$(blkid -o value -s UUID "\$device")
  if ! grep -q "\$uuid" /etc/fstab 2>/dev/null; then
    echo "UUID=\$uuid \$mountpoint ext4 defaults,noatime,nodiratime,discard 0 2" >> /etc/fstab
    echo "Added \$mountpoint to fstab (UUID=\$uuid)"
  else
    echo "\$mountpoint already in fstab"
  fi

  mount "\$mountpoint" 2>/dev/null || true
  chown ${SOL_USER}:${SOL_USER} "\$mountpoint"
  echo "\$mountpoint ready on \$device"
}

setup_disk "${LEDGER_DISK}" "/mnt/ledger" "solana-ledger"

# If accounts disk is separate, mount it; otherwise create subdir on ledger disk
if [[ -n "${ACCOUNTS_DISK}" ]]; then
  setup_disk "${ACCOUNTS_DISK}" "/mnt/accounts" "solana-accounts"
else
  echo "Using /mnt/ledger for accounts (single disk mode)"
  mkdir -p /mnt/accounts
fi

# Snapshots as subdir on ledger mount
mkdir -p /mnt/ledger/snapshots

# Always force ownership after all mounts — ext4 root inodes default to root:root
# and fstab mounts on reboot will reset ownership on the mountpoint
chown ${SOL_USER}:${SOL_USER} /mnt/ledger
chown ${SOL_USER}:${SOL_USER} /mnt/ledger/snapshots
chown ${SOL_USER}:${SOL_USER} /mnt/accounts

echo "Disk setup complete"
SCRIPT
else
  log_warn "No disk devices specified or discovered, creating directories under /home/${SOL_USER}"
  root_script <<SCRIPT
mkdir -p /home/${SOL_USER}/ledger
mkdir -p /home/${SOL_USER}/accounts
mkdir -p /home/${SOL_USER}/snapshots
mkdir -p /home/${SOL_USER}/logs
chown -R ${SOL_USER}:${SOL_USER} /home/${SOL_USER}/{ledger,accounts,snapshots,logs}
echo "Directories created under /home/${SOL_USER}"
SCRIPT
fi

# Create logs directory regardless
root_script <<SCRIPT
mkdir -p /home/${SOL_USER}/logs
chown ${SOL_USER}:${SOL_USER} /home/${SOL_USER}/logs
SCRIPT

# ---------------------------------------------------------------------------
# Step 5: Swap setup
# ---------------------------------------------------------------------------
log_info "Step 5: Setting up swap (${SWAP_SIZE})"

root_script <<SCRIPT
SWAPFILE="/swapfile"
if [ ! -f "\$SWAPFILE" ]; then
  fallocate -l ${SWAP_SIZE} \$SWAPFILE
  chmod 600 \$SWAPFILE
  mkswap \$SWAPFILE
  swapon \$SWAPFILE
  if ! grep -q "\$SWAPFILE" /etc/fstab; then
    echo "\$SWAPFILE none swap sw 0 0" >> /etc/fstab
  fi
  echo "Swap file created and enabled"
else
  echo "Swap file already exists"
  swapon \$SWAPFILE 2>/dev/null || true
fi
swapon --show
SCRIPT

# ---------------------------------------------------------------------------
# Step 6: Set up sol user profile
# ---------------------------------------------------------------------------
if ! $BUILD_JITO; then
  log_info "Step 6: Nothing is built from source — skipping the Rust toolchain"
else
log_info "Step 6: Setting up sol user profile"

sol_script <<'SCRIPT'
# Ensure LIBCLANG_PATH is in profile
if ! grep -q "LIBCLANG_PATH" ~/.profile 2>/dev/null; then
  echo 'export LIBCLANG_PATH=/usr/lib/llvm-18/lib' >> ~/.profile
fi

# Install Rust if not present
if command -v rustc &>/dev/null; then
  echo "Rust already installed: $(rustc --version)"
else
  curl https://sh.rustup.rs -sSf | sh -s -- -y
  echo "Rust installed"
fi

# Ensure cargo env is sourced in profile
if ! grep -q '.cargo/env' ~/.profile 2>/dev/null; then
  echo '. "$HOME/.cargo/env"' >> ~/.profile
fi

# Source cargo for this session and install/update components
. "$HOME/.cargo/env"
rustup component add rustfmt
rustup update
echo "Rust and rustfmt ready: $(rustc --version)"
SCRIPT
fi

# ---------------------------------------------------------------------------
# Step 6b: Install the validator
#   --hexis ships its own agave-validator build, so the jito-solana source build
#   is skipped and only the prebuilt Solana CLI (solana-keygen, solana, ...) goes
#   on the box. --build-jito forces the source build anyway.
# ---------------------------------------------------------------------------
if $ENABLE_HEXIS && ! $BUILD_JITO; then
  log_info "Step 6b: --hexis supplies the validator binary — skipping the jito-solana source build"
fi

# The GitHub key is still needed for jag-snap even when nothing is built from source
if [[ -n "$GITHUB_SSH_KEY" ]] && ! $BUILD_JITO; then
  if [[ ! -f "$GITHUB_SSH_KEY" ]]; then
    log_error "GitHub SSH key not found: $GITHUB_SSH_KEY"
    exit 1
  fi
  if $DRY_RUN; then
    echo "[DRY RUN] scp $GITHUB_SSH_KEY -> $SOL_HOST:/home/${SOL_USER}/.ssh/github_key"
  else
    scp $SSH_OPTS "$GITHUB_SSH_KEY" "$SOL_HOST:/home/${SOL_USER}/.ssh/github_key"
    remote "chmod 600 /home/${SOL_USER}/.ssh/github_key"
    sol_script <<'SSHCONF'
if ! grep -q "github.com" ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config <<'EOF'
Host github.com
  IdentityFile ~/.ssh/github_key
  StrictHostKeyChecking accept-new
EOF
  chmod 600 ~/.ssh/config
  echo "GitHub SSH config added"
else
  echo "GitHub SSH config already exists"
fi
SSHCONF
  fi
fi

# Prebuilt Solana CLI — solana-keygen for the identity and arb keypairs, solana
# for catchup/monitoring. Only when nothing is being built from source.
if $ENABLE_HEXIS && ! $BUILD_JITO; then
  log_info "Step 6b: Installing the prebuilt Solana CLI"

  sol_script <<'SCRIPT'
set -e
INSTALL_ROOT="$HOME/.local/share/solana/install"

if [ -x "$INSTALL_ROOT/active_release/bin/solana-keygen" ] || \
   [ -x "$INSTALL_ROOT/releases/active_release/bin/solana-keygen" ]; then
  echo "Solana CLI already installed"
else
  sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
fi

# The rest of this setup (validator.sh PATH, step 7b) refers to the source-build
# layout, releases/active_release. Point it at whatever the installer produced.
if [ ! -e "$INSTALL_ROOT/releases/active_release" ] && [ -e "$INSTALL_ROOT/active_release" ]; then
  mkdir -p "$INSTALL_ROOT/releases"
  ln -sfn "$INSTALL_ROOT/active_release" "$INSTALL_ROOT/releases/active_release"
  echo "Linked releases/active_release -> active_release"
fi

"$INSTALL_ROOT/releases/active_release/bin/solana-keygen" --version
SCRIPT
fi

if $BUILD_JITO; then
  log_info "Step 6b: Building Jito validator from source"

  if [[ ! -f "$GITHUB_SSH_KEY" ]]; then
    log_error "GitHub SSH key not found: $GITHUB_SSH_KEY"
    exit 1
  fi

  # Copy GitHub SSH key to sol user
  if $DRY_RUN; then
    echo "[DRY RUN] scp $GITHUB_SSH_KEY -> $SOL_HOST:/home/${SOL_USER}/.ssh/github_key"
  else
    scp $SSH_OPTS "$GITHUB_SSH_KEY" "$SOL_HOST:/home/${SOL_USER}/.ssh/github_key"
    remote "chmod 600 /home/${SOL_USER}/.ssh/github_key"

    # Configure SSH to use this key for github.com
    sol_script <<'SSHCONF'
if ! grep -q "github.com" ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config <<'EOF'
Host github.com
  IdentityFile ~/.ssh/github_key
  StrictHostKeyChecking accept-new
EOF
  chmod 600 ~/.ssh/config
  echo "GitHub SSH config added"
else
  echo "GitHub SSH config already exists"
fi
SSHCONF
  fi

  # Check if jito-solana is already built at the active_release path
  JITO_ALREADY_BUILT=$(remote "test -f /home/${SOL_USER}/.local/share/solana/install/releases/active_release/bin/agave-validator && echo YES || echo NO" 2>/dev/null || echo "NO")

  if [[ "$JITO_ALREADY_BUILT" == "YES" ]]; then
    log_info "Jito validator already built — skipping"
  else
    log_info "Using jito-solana repo: $JITO_REPO_URL"

    # Prompt for a branch filter — user can narrow long branch lists
    echo ""
    read -rp "Branch filter (substring/regex, leave blank for all): " BRANCH_FILTER
    echo ""

    log_info "Fetching branches from $JITO_REPO_URL..."
    if [[ -n "$BRANCH_FILTER" ]]; then
      BRANCHES=$(remote "ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/github_key git@github.com 2>/dev/null; git ls-remote --heads ${JITO_REPO_URL} 2>/dev/null | awk '{print \$2}' | sed 's|refs/heads/||' | grep -E '${BRANCH_FILTER}' | sort -V" 2>/dev/null || true)
    else
      BRANCHES=$(remote "ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/github_key git@github.com 2>/dev/null; git ls-remote --heads ${JITO_REPO_URL} 2>/dev/null | awk '{print \$2}' | sed 's|refs/heads/||' | sort -V" 2>/dev/null || true)
    fi

    if [[ -z "$BRANCHES" ]]; then
      log_error "Could not fetch branches — check GitHub SSH key, repo URL, or branch filter"
      exit 1
    fi

    echo ""
    echo "=========================================="
    echo "  Select Jito branch to build"
    echo "=========================================="
    local_i=1
    declare -a BRANCH_LIST=()
    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      printf "  %d) %s\n" "$local_i" "$branch"
      BRANCH_LIST+=("$branch")
      ((local_i++))
    done <<< "$BRANCHES"
    echo ""

    if [[ ${#BRANCH_LIST[@]} -eq 0 ]]; then
      log_error "No branches matched filter '$BRANCH_FILTER'"
      exit 1
    fi

    while true; do
      read -rp "Select branch: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < local_i )); then
        JITO_BRANCH="${BRANCH_LIST[$((choice - 1))]}"
        break
      else
        echo "Invalid selection. Enter a number between 1 and $((local_i - 1))."
      fi
    done

    log_info "Building Jito branch: $JITO_BRANCH"

    # Clone, checkout, build
    sol_script <<BUILDEOF
set -e
. "\$HOME/.cargo/env"
export LIBCLANG_PATH=/usr/lib/llvm-18/lib

# Clone if not already cloned
if [ ! -d ~/jito-solana ]; then
  git clone ${JITO_REPO_URL} ~/jito-solana
  echo "Cloned jito-solana from ${JITO_REPO_URL}"
else
  echo "jito-solana already cloned"
  cd ~/jito-solana
  git fetch --all
fi

cd ~/jito-solana
git checkout ${JITO_BRANCH}
git submodule update --init --recursive

CI_COMMIT=\$(git rev-parse HEAD)
echo "Building commit: \$CI_COMMIT on branch ${JITO_BRANCH}"

scripts/cargo-install-all.sh --validator-only ~/.local/share/solana/install/releases/active_release

echo "Jito validator built successfully"
BUILDEOF
  fi

elif ! $ENABLE_HEXIS; then
  log_warn "Step 6b: No --github-ssh-key provided — skipping Jito build"
fi

# Interactive shells need the solana bin dir, however it got there
if $BUILD_JITO || $ENABLE_HEXIS; then
  sol_script <<'PATHEOF'
SOLANA_BIN='PATH="/home/sol/.local/share/solana/install/releases/active_release/bin:$PATH"'
if ! grep -q "releases/active_release/bin" ~/.bashrc 2>/dev/null; then
  echo "$SOLANA_BIN" >> ~/.bashrc
  echo "Added solana bin to .bashrc"
else
  echo "Solana bin already in .bashrc"
fi

# Also add to .profile for login shells
if ! grep -q "releases/active_release/bin" ~/.profile 2>/dev/null; then
  echo "export $SOLANA_BIN" >> ~/.profile
  echo "Added solana bin to .profile"
else
  echo "Solana bin already in .profile"
fi
PATHEOF
fi

# ---------------------------------------------------------------------------
# Step 7: Copy identity keypair to server
# ---------------------------------------------------------------------------
log_info "Step 7: Copying identity keypair to server"

if $DRY_RUN; then
  echo "[DRY RUN] scp $IDENTITY_FILE -> $SOL_HOST:/home/${SOL_USER}/staked_identity.json"
else
  if remote "test -f /home/${SOL_USER}/staked_identity.json" 2>/dev/null; then
    log_info "staked_identity.json already exists on server — skipping copy"
  else
    scp $SSH_OPTS "$IDENTITY_FILE" "$SOL_HOST:/home/${SOL_USER}/staked_identity.json"
    remote "chmod 600 /home/${SOL_USER}/staked_identity.json"
  fi
fi

# Generate unstaked identity and symlink identity.json -> unstaked
log_info "Step 7b: Setting up unstaked identity and identity.json symlink"

sol_script <<'SCRIPT'
export PATH="$HOME/.local/share/solana/install/releases/active_release/bin:$PATH"

if [ -f ~/unstaked_identity.json ]; then
  echo "unstaked_identity.json already exists"
else
  solana-keygen new --outfile ~/unstaked_identity.json --no-passphrase
  echo "Generated unstaked_identity.json"
fi

# Symlink identity.json -> unstaked_identity.json
# Validator starts with unstaked identity; switch to staked manually
ln -sf unstaked_identity.json ~/identity.json
echo "identity.json -> unstaked_identity.json"
SCRIPT

# ---------------------------------------------------------------------------
# Step 7c: Create mostly_confirmed_threshold
# ---------------------------------------------------------------------------
log_info "Step 7c: Creating mostly_confirmed_threshold"

sol_script <<SCRIPT
cat > ~/mostly_confirmed_threshold <<'EOF'
0.35 4 1 8
EOF
echo "mostly_confirmed_threshold created"
SCRIPT

# ---------------------------------------------------------------------------
# Step 7d: XDP setup — detect NIC, tune ring sizes, build validator flags
# Reference: https://www.anza.xyz/blog/agave-xdp-setup-guide
# ---------------------------------------------------------------------------
# Holds the validator command-line flags injected into validator.sh (Step 8)
# and the systemd capability lines injected into sol.service (Step 9).
XDP_VALIDATOR_FLAGS=""
XDP_CAPS=""

# Largest power of 2 that is <= $1 (used to clamp NIC ring sizes to a power of 2)
pow2_floor() {
  local n="$1" p=1
  [[ "$n" =~ ^[0-9]+$ ]] || { echo ""; return 1; }
  (( n >= 1 )) || { echo ""; return 1; }
  while (( p * 2 <= n )); do (( p *= 2 )); done
  echo "$p"
}

if $ENABLE_XDP; then
  log_info "Step 7d: Setting up XDP (per Anza XDP setup guide)"

  if $DRY_RUN; then
    log_info "[DRY RUN] Would detect NIC/driver/kernel, tune ring sizes, and add XDP flags"
  else
    # --- Detect interface, driver, kernel and ring maxima on the server ---
    XDP_INFO=$(root_script <<XDPDETECT
IFACE="${XDP_INTERFACE}"
if [ -z "\$IFACE" ]; then
  IFACE=\$(ip route show default 2>/dev/null | awk '/default/{print \$5; exit}')
fi
# Resolve the underlying member if this is a bonded interface
if [ -n "\$IFACE" ] && [ -d "/sys/class/net/\$IFACE/bonding" ]; then
  MEMBER=\$(awk '{print \$1}' "/sys/class/net/\$IFACE/bonding/slaves" 2>/dev/null)
  if [ -n "\$MEMBER" ]; then
    echo "XDP_BOND=\$IFACE"
    IFACE="\$MEMBER"
  fi
fi
echo "XDP_IFACE=\$IFACE"
if [ -z "\$IFACE" ]; then
  echo "XDP_ERROR=no_interface"
  exit 0
fi
echo "XDP_DRIVER=\$(ethtool -i "\$IFACE" 2>/dev/null | awk -F': ' '/^driver:/{print \$2}')"
echo "XDP_KERNEL=\$(uname -r)"
echo "XDP_RX_MAX=\$(ethtool -g "\$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1} f&&/^RX:/{print \$2; exit}')"
echo "XDP_TX_MAX=\$(ethtool -g "\$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1} f&&/^TX:/{print \$2; exit}')"
XDPDETECT
)

    XDP_BOND=$(echo "$XDP_INFO"  | sed -n 's/^XDP_BOND=//p')
    XDP_IFACE=$(echo "$XDP_INFO" | sed -n 's/^XDP_IFACE=//p')
    XDP_DRIVER=$(echo "$XDP_INFO" | sed -n 's/^XDP_DRIVER=//p')
    XDP_KERNEL=$(echo "$XDP_INFO" | sed -n 's/^XDP_KERNEL=//p')
    XDP_RX_MAX=$(echo "$XDP_INFO" | sed -n 's/^XDP_RX_MAX=//p')
    XDP_TX_MAX=$(echo "$XDP_INFO" | sed -n 's/^XDP_TX_MAX=//p')

    if [[ -z "$XDP_IFACE" || "$XDP_INFO" == *"XDP_ERROR=no_interface"* ]]; then
      log_error "Could not detect a network interface for XDP — pass --xdp-interface <iface>"
      exit 1
    fi

    [[ -n "$XDP_BOND" ]] && log_info "Bonded interface $XDP_BOND -> using member $XDP_IFACE"
    log_info "XDP interface:    $XDP_IFACE"
    log_info "XDP NIC driver:   ${XDP_DRIVER:-unknown}"
    log_info "Kernel:           ${XDP_KERNEL:-unknown}"

    # --- Kernel version check (igb needs 6.14+, all others 6.8+) ---
    REQ_MINOR=8
    [[ "$XDP_DRIVER" == "igb" ]] && REQ_MINOR=14
    KMAJ=$(echo "$XDP_KERNEL" | cut -d. -f1)
    KMIN=$(echo "$XDP_KERNEL" | cut -d. -f2)
    if [[ "$KMAJ" =~ ^[0-9]+$ && "$KMIN" =~ ^[0-9]+$ ]]; then
      if (( KMAJ < 6 || ( KMAJ == 6 && KMIN < REQ_MINOR ) )); then
        log_warn "Kernel $XDP_KERNEL is below the XDP requirement (6.${REQ_MINOR}+ for the ${XDP_DRIVER:-current} driver) — XDP may not load"
      fi
    fi

    # --- Tune NIC ring sizes to a power of 2 (XDP requirement) ---
    XDP_RXP=$(pow2_floor "$XDP_RX_MAX" 2>/dev/null || true)
    XDP_TXP=$(pow2_floor "$XDP_TX_MAX" 2>/dev/null || true)
    if [[ -n "$XDP_RXP" && -n "$XDP_TXP" ]]; then
      log_info "Setting $XDP_IFACE ring sizes to rx=$XDP_RXP tx=$XDP_TXP (max rx=$XDP_RX_MAX tx=$XDP_TX_MAX)"
      root_script <<XDPRING
IFACE="${XDP_IFACE}"
# Apply now (tolerate "no change" errors when already set)
ethtool -G "\$IFACE" rx ${XDP_RXP} tx ${XDP_TXP} 2>/dev/null || true

# Persist across reboots — re-applied once the interface is up
cat > /etc/systemd/system/xdp-nic-tuning.service <<UNIT
[Unit]
Description=XDP NIC ring tuning for Agave validator
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ethtool -G ${XDP_IFACE} rx ${XDP_RXP} tx ${XDP_TXP} || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable xdp-nic-tuning.service
echo "NIC ring tuning applied and persisted for \$IFACE"
XDPRING
    else
      log_warn "Could not read ring maxima for $XDP_IFACE — skipping ring-size tuning (set manually with: ethtool -G $XDP_IFACE rx <pow2> tx <pow2>)"
    fi

    # --- Resolve zero-copy mode ---
    XDP_ZC=false
    case "$XDP_ZERO_COPY" in
      on)  XDP_ZC=true ;;
      off) XDP_ZC=false ;;
      auto)
        if [[ "$XDP_DRIVER" == "bnxt_en" || "$XDP_DRIVER" == "ice" ]]; then
          log_warn "Driver $XDP_DRIVER does not support zero-copy XDP — disabling it"
          XDP_ZC=false
        else
          XDP_ZC=true
        fi ;;
    esac

    # --- Build the validator flags (injected after the exec line in Step 8) ---
    XDP_VALIDATOR_FLAGS="    --experimental-retransmit-xdp-cpu-cores ${XDP_CPU_CORES} \\
    --experimental-poh-pinned-cpu-core ${POH_PINNED_CORE} \\
    --experimental-retransmit-xdp-interface ${XDP_IFACE} \\
"
    if $XDP_ZC; then
      XDP_VALIDATOR_FLAGS+="    --experimental-retransmit-xdp-zero-copy \\
"
    fi

    # --- Capabilities for the systemd service (Step 9) ---
    # AmbientCapabilities is required for a non-root (User=sol) service to actually
    # gain the capabilities; CapabilityBoundingSet matches the Anza guide.
    XDP_CAPS="AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON"

    log_info "XDP zero-copy:    $($XDP_ZC && echo enabled || echo disabled)"
    log_info "XDP flags:        retransmit-xdp-cpu-cores=${XDP_CPU_CORES}, poh-pinned-cpu-core=${POH_PINNED_CORE}"
  fi
fi

# ---------------------------------------------------------------------------
# Step 7e: Hexis arb client — binary, signer, arb-config.toml, revert dump spool
# Reference: https://github.com/hexishq/hexis-validator-docs
# ---------------------------------------------------------------------------
# Injected into validator.sh (Step 8): extra flags and env exports.
HEXIS_VALIDATOR_FLAGS=""
HEXIS_ENV_EXPORTS=""
HEXIS_PATH_PREFIX=""
HEXIS_SIGNER_PATH=""

# Flash-loan state as arb-config.toml on the host actually has it, not as our flags
# would have written it — upgrade and promote never regenerate that file.
hexis_flash_loan_account() {
  remote "grep -m1 '^marginfi_account' ${HEXIS_DIR}/arb-config.toml 2>/dev/null | sed -e 's/.*= *\"//' -e 's/\".*//'"
}

# solana-keygen from the validator built in Step 6b
HEXIS_KEYGEN="/home/${SOL_USER}/.local/share/solana/install/releases/active_release/bin/solana-keygen"

# Pubkey of a keypair file on the server
hexis_pubkey() {
  remote "${HEXIS_KEYGEN} pubkey $1" 2>/dev/null || true
}

if $ENABLE_HEXIS; then
  log_info "Step 7e: Setting up Hexis arb client in ${HEXIS_DIR}"

  # --- Directories: install dir plus the revert-dump spool -----------------
  sol_script <<SCRIPT
mkdir -p ${HEXIS_DIR} ${HEXIS_DIR}/arb-reverts
chmod 700 ${HEXIS_DIR}
echo "hexis dirs ready: ${HEXIS_DIR}, ${HEXIS_DIR}/arb-reverts"

# Interactive shells: the Hexis build ahead of everything else, same as validator.sh
for rc in ~/.bashrc ~/.profile; do
  if ! grep -q "${HEXIS_DIR}:" "\$rc" 2>/dev/null; then
    echo 'export PATH="${HEXIS_DIR}:\$PATH"' >> "\$rc"
    echo "Added ${HEXIS_DIR} to \$rc"
  fi
done
SCRIPT

  # --- Binaries ------------------------------------------------------------
  HEXIS_DL_DIR=""
  if [[ -n "$HEXIS_TAG" ]]; then
    log_info "Downloading Hexis release ${HEXIS_TAG} from ${HEXIS_REPO}"
    if $DRY_RUN; then
      echo "[DRY RUN] gh release download $HEXIS_TAG --repo $HEXIS_REPO"
    else
      HEXIS_DL_DIR=$(mktemp -d)
      HEXIS_BINARY=$(hexis_download_validator "$HEXIS_TAG" "$HEXIS_DL_DIR") || exit 1

      # hexis-setup is a separate release — it creates the marginfi account, the
      # LUTs and the TokenLedgers
      if [[ -z "$HEXIS_SETUP_BINARY" && -n "$HEXIS_SETUP_TAG" ]]; then
        HEXIS_SETUP_DL=$(mktemp -d)
        HEXIS_SETUP_BINARY=$(hexis_download_setup "$HEXIS_SETUP_TAG" "$HEXIS_SETUP_DL") || exit 1
      fi
    fi
  fi

  # Layout: releases/<release>/agave-validator, with agave-validator a symlink to
  # the active one. validator.sh execs the symlink, so a version bump never edits
  # it — see ascend.sh for staging and rollback between releases.
  if [[ -n "$HEXIS_BINARY" ]]; then
    if $DRY_RUN; then
      echo "[DRY RUN] scp $HEXIS_BINARY -> $SOL_HOST:${HEXIS_DIR}/releases/${HEXIS_TAG:-<version>}/agave-validator"
      echo "[DRY RUN] link ${HEXIS_DIR}/agave-validator -> releases/${HEXIS_TAG:-<version>}/agave-validator"
    else
      scp -q $SSH_OPTS "$HEXIS_BINARY" "$SOL_HOST:${HEXIS_DIR}/agave-validator.incoming"
      remote "chmod +x ${HEXIS_DIR}/agave-validator.incoming"

      HEXIS_VERSION=$(remote "${HEXIS_DIR}/agave-validator.incoming --version 2>/dev/null | awk '{print \$2}'" || true)
      if [[ -z "$HEXIS_VERSION" ]]; then
        log_error "The Hexis binary does not run on this host"
        remote "rm -f ${HEXIS_DIR}/agave-validator.incoming"
        exit 1
      fi
      HEXIS_RELEASE="${HEXIS_TAG:-$HEXIS_VERSION}"

      sol_script <<SCRIPT
set -e
cd ${HEXIS_DIR}
mkdir -p "releases/${HEXIS_RELEASE}"
mv agave-validator.incoming "releases/${HEXIS_RELEASE}/agave-validator"
chmod +x "releases/${HEXIS_RELEASE}/agave-validator"
ln -s "releases/${HEXIS_RELEASE}/agave-validator" .agave-validator.next
mv -T .agave-validator.next agave-validator
echo "installed releases/${HEXIS_RELEASE}, active: \$(readlink agave-validator)"
SCRIPT
      log_info "Hexis validator: ${HEXIS_RELEASE} (${HEXIS_VERSION})"
    fi
  elif ! $DRY_RUN; then
    if remote "test -x ${HEXIS_DIR}/agave-validator" 2>/dev/null; then
      log_info "Hexis validator already installed at ${HEXIS_DIR}/agave-validator — skipping download"
    else
      log_error "No Hexis binary on the server and neither --hexis-tag nor --hexis-binary was given"
      exit 1
    fi
  fi

  # hexis-setup is what creates the marginfi account, the LUTs and the TokenLedgers
  HEXIS_SETUP_INSTALLED=false
  if [[ -n "$HEXIS_SETUP_BINARY" ]]; then
    if $DRY_RUN; then
      echo "[DRY RUN] scp $HEXIS_SETUP_BINARY -> $SOL_HOST:${HEXIS_DIR}/hexis-setup"
    else
      scp -q $SSH_OPTS "$HEXIS_SETUP_BINARY" "$SOL_HOST:${HEXIS_DIR}/hexis-setup"
      remote "chmod +x ${HEXIS_DIR}/hexis-setup"
      log_info "hexis-setup installed at ${HEXIS_DIR}/hexis-setup"
    fi
    HEXIS_SETUP_INSTALLED=true
  elif ! $DRY_RUN && remote "test -x ${HEXIS_DIR}/hexis-setup" 2>/dev/null; then
    HEXIS_SETUP_INSTALLED=true
  fi

  [[ -n "$HEXIS_DL_DIR" ]] && rm -rf "$HEXIS_DL_DIR"
  [[ -n "${HEXIS_SETUP_DL:-}" ]] && rm -rf "$HEXIS_SETUP_DL"

  # --- Arb signer ----------------------------------------------------------
  # The signer signs arb transactions and pays their fees. profit_wallet is the
  # Hexis rewards pool — an address we do not hold a key for, so it is never
  # generated here, only written into the config.
  HEXIS_SIGNER_PATH="${HEXIS_DIR}/${HEXIS_SIGNER_KEYPAIR}"
  HEXIS_SIGNER_PUBKEY=""

  if [[ -n "$HEXIS_SIGNER" ]]; then
    if $DRY_RUN; then
      echo "[DRY RUN] scp $HEXIS_SIGNER -> $SOL_HOST:${HEXIS_SIGNER_PATH}"
    else
      scp -q $SSH_OPTS "$HEXIS_SIGNER" "$SOL_HOST:${HEXIS_SIGNER_PATH}"
      remote "chmod 600 ${HEXIS_SIGNER_PATH}"
      log_info "Arb signer copied to ${HEXIS_SIGNER_PATH}"
    fi
  fi

  if [[ -n "$HEXIS_CONFIG" ]]; then
    log_info "--hexis-config given — leaving signer_path and profit_wallet to that file"
  elif $DRY_RUN; then
    [[ -z "$HEXIS_SIGNER" ]] && echo "[DRY RUN] generate arb signer keypair at ${HEXIS_SIGNER_PATH}"
  else
    # solana-keygen ships with the locally built validator (Step 6b)
    if [[ -z "$HEXIS_SIGNER" ]] && ! remote "test -x ${HEXIS_KEYGEN}" 2>/dev/null; then
      log_error "No solana-keygen on the server (${HEXIS_KEYGEN}) — cannot generate an arb signer"
      log_error "The Solana CLI install in Step 6b must have failed. Fix that, or pass --hexis-signer"
      exit 1
    fi

    if [[ -z "$HEXIS_SIGNER" ]]; then
      sol_script <<SCRIPT
if [ -f ${HEXIS_SIGNER_PATH} ]; then
  echo "arb signer already exists — keeping ${HEXIS_SIGNER_PATH}"
else
  ${HEXIS_KEYGEN} new --outfile ${HEXIS_SIGNER_PATH} --no-passphrase --silent
  echo "generated arb signer ${HEXIS_SIGNER_PATH}"
fi
chmod 600 ${HEXIS_SIGNER_PATH}
SCRIPT
    fi

    HEXIS_SIGNER_PUBKEY=$(hexis_pubkey "$HEXIS_SIGNER_PATH")
    [[ -n "$HEXIS_SIGNER_PUBKEY" ]] || { log_error "Could not read the arb signer pubkey from ${HEXIS_SIGNER_PATH}"; exit 1; }

    log_info "Arb signer:    ${HEXIS_SIGNER_PUBKEY}  (${HEXIS_SIGNER_PATH}) — fund it, it pays arb transaction fees"
    log_info "Profit wallet: ${HEXIS_PROFIT_WALLET}  (Hexis rewards pool)"
  fi

  # --- arb-config.toml -----------------------------------------------------
  if [[ -n "$HEXIS_CONFIG" ]]; then
    log_info "Uploading arb-config.toml from $HEXIS_CONFIG"
    if $DRY_RUN; then
      echo "[DRY RUN] scp $HEXIS_CONFIG -> $SOL_HOST:${HEXIS_DIR}/arb-config.toml"
    else
      scp -q $SSH_OPTS "$HEXIS_CONFIG" "$SOL_HOST:${HEXIS_DIR}/arb-config.toml"
    fi
  else
    [[ -z "$HEXIS_JUP_KEY" ]] && log_warn "No Jupiter API key (--hexis-jup-key / \$HEXIS_JUP_KEY) — jup_key omitted from arb-config.toml"
    hexis_warn_flash_loans "$HEXIS_SIGNER" " (see the summary at the end)"

    HEXIS_TOML="$(hexis_render_arb_config arise.sh "$HEXIS_DIR" "$HEXIS_SIGNER_PATH" "$HEXIS_CONTROL")
"

    sol_script <<SCRIPT
cat > ${HEXIS_DIR}/arb-config.toml <<'ARBEOF'
${HEXIS_TOML}
ARBEOF
chmod 600 ${HEXIS_DIR}/arb-config.toml
echo "arb-config.toml written"
SCRIPT
  fi

  # --- Flags and env injected into validator.sh (Step 8) -------------------
  HEXIS_PATH_PREFIX="${HEXIS_DIR}:"
  HEXIS_VALIDATOR_FLAGS="    --tvu-shred-sigverify-threads ${HEXIS_SIGVERIFY_THREADS} \\
    --arb-config ${HEXIS_DIR}/arb-config.toml \\
"
  if [[ -n "$HEXIS_METRICS_CONFIG" ]]; then
    HEXIS_ENV_EXPORTS="export SOLANA_METRICS_CONFIG_ARB=\"${HEXIS_METRICS_CONFIG}\"
"
  else
    log_warn "No arb metrics config (--hexis-metrics-config / \$SOLANA_METRICS_CONFIG_ARB) — validator.sh will not export SOLANA_METRICS_CONFIG_ARB"
  fi
fi

# ---------------------------------------------------------------------------
# Step 8: Create validator startup script
# ---------------------------------------------------------------------------
log_info "Step 8: Creating validator.sh"

# Determine paths based on whether disks were provided/discovered
if [[ -n "$LEDGER_DISK" || -n "$ACCOUNTS_DISK" ]]; then
  LEDGER_PATH="/mnt/ledger"
  ACCOUNTS_PATH="/mnt/accounts"
  SNAPSHOTS_PATH="/mnt/ledger/snapshots"
else
  LEDGER_PATH="/home/${SOL_USER}/ledger"
  ACCOUNTS_PATH="/home/${SOL_USER}/accounts"
  SNAPSHOTS_PATH="/home/${SOL_USER}/snapshots"
fi

# Build the validator.sh content based on network
# HEXIS_PATH_PREFIX puts the Hexis build ahead of the locally built validator on
# PATH, so `exec agave-validator` below resolves to it.
VALIDATOR_ENV_EXPORTS=""
if [[ -n "$METRICS_CONFIG" ]]; then
  VALIDATOR_ENV_EXPORTS="export SOLANA_METRICS_CONFIG=\"${METRICS_CONFIG}\"
"
fi

VALIDATOR_PATH="${HEXIS_PATH_PREFIX}/home/${SOL_USER}/.local/share/solana/install/releases/active_release/bin:/home/${SOL_USER}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
VALIDATOR_EXEC="agave-validator"
[[ "$NETWORK" != "mainnet" ]] && VALIDATOR_EXEC="solana-validator"

# Step 7d writes the pre-4.3 XDP flag names, which every build since 3.0 takes.
# Switch to the current names when the binary validator.sh will exec knows them —
# 4.4+ rejects the old ones. Dry runs assume a current build.
if [[ -n "$XDP_VALIDATOR_FLAGS" ]]; then
  XDP_NEW_NAMES=yes
  if ! $DRY_RUN; then
    XDP_NEW_NAMES=$(remote "$(xdp_flag_probe "PATH=${VALIDATOR_PATH} ${VALIDATOR_EXEC}" "--xdp-cpu-cores 1")")
  fi
  if [[ "$XDP_NEW_NAMES" == "yes" ]]; then
    XDP_VALIDATOR_FLAGS=$(sed "$(xdp_rename_sed)" <<< "$XDP_VALIDATOR_FLAGS")
    XDP_VALIDATOR_FLAGS+=$'\n'
    log_info "XDP flags: using the current names (--xdp-cpu-cores, --poh-pinned-cpu-core, ...)"
  else
    log_info "XDP flags: ${VALIDATOR_EXEC} predates Agave 4.3 — using the --experimental-* names"
  fi
fi

VALIDATOR_SCRIPT="#!/bin/bash
PATH=${VALIDATOR_PATH}
${VALIDATOR_ENV_EXPORTS}${HEXIS_ENV_EXPORTS}"

if [[ "$NETWORK" == "mainnet" ]]; then
  VALIDATOR_SCRIPT+="exec ${VALIDATOR_EXEC} \\
"
  VALIDATOR_SCRIPT+="${XDP_VALIDATOR_FLAGS}"
  VALIDATOR_SCRIPT+="${HEXIS_VALIDATOR_FLAGS}"
  VALIDATOR_SCRIPT+="    --identity /home/${SOL_USER}/identity.json \\
    --authorized-voter /home/${SOL_USER}/staked_identity.json \\
    --vote-account ${VOTE_ACCOUNT} \\
"
  for kv in "${KNOWN_VALIDATORS[@]}"; do
    VALIDATOR_SCRIPT+="    --known-validator $kv \\
"
  done
  VALIDATOR_SCRIPT+="    --tip-payment-program-pubkey T1pyyaTNZsKv2WcRAB8oVnk93mLJw2XzjtVYqCsaHqt \\
    --tip-distribution-program-pubkey 4R3gSG8BpU4t19KYj8CfnbtRpnT8gtk4dvTHxVRwc2r7 \\
    --merkle-root-upload-authority GZctHpWXmsZC1YHACTGGcHhYxjdRqQvTpYkb9LMvxDib \\
    --commission-bps ${COMMISSION_BPS:-0} \\
    --block-engine-url ${JITO_BLOCK_ENGINE:-<FILL_IN_BLOCK_ENGINE_URL>} \\
    --shred-receiver-address ${JITO_SHRED_RECEIVER:-<FILL_IN_SHRED_RECEIVER_ADDRESS>},233.84.178.1:7733${BLOXROUTE_SHREDS:+,${BLOXROUTE_SHREDS}} \\
    --only-known-rpc \\
    --log /home/${SOL_USER}/logs/agave-validator.log \\
    --accounts ${ACCOUNTS_PATH} \\
    --snapshots ${SNAPSHOTS_PATH} \\
    --ledger ${LEDGER_PATH} \\
    --rpc-port 8899 \\
    --rpc-bind-address 127.0.0.1 \\
    --no-port-check \\
    --public-rpc-address ${PUBLIC_RPC_ADDRESS:-<FILL_IN_PUBLIC_RPC_ADDRESS>} \\
    --dynamic-port-range 8000-8026 \\
"
  for ep in "${ENTRYPOINTS[@]}"; do
    VALIDATOR_SCRIPT+="    --entrypoint $ep \\
"
  done
  VALIDATOR_SCRIPT+="    --expected-genesis-hash ${GENESIS_HASH} \\
    --wal-recovery-mode skip_any_corrupted_record \\
    --limit-ledger-size
"
else
  # Testnet uses solana-validator
  VALIDATOR_SCRIPT+="exec ${VALIDATOR_EXEC} \\
"
  VALIDATOR_SCRIPT+="${XDP_VALIDATOR_FLAGS}"
  VALIDATOR_SCRIPT+="    --identity /home/${SOL_USER}/staked_identity.json \\
    --vote-account ${VOTE_ACCOUNT} \\
"
  for kv in "${KNOWN_VALIDATORS[@]}"; do
    VALIDATOR_SCRIPT+="    --known-validator $kv \\
"
  done
  VALIDATOR_SCRIPT+="    --only-known-rpc \\
"
  for ep in "${ENTRYPOINTS[@]}"; do
    VALIDATOR_SCRIPT+="    --entrypoint $ep \\
"
  done
  VALIDATOR_SCRIPT+="    --expected-genesis-hash ${GENESIS_HASH} \\
    --log /home/${SOL_USER}/logs/solana-validator.log \\
    --accounts ${ACCOUNTS_PATH} \\
    --snapshots ${SNAPSHOTS_PATH} \\
    --ledger ${LEDGER_PATH} \\
    --rpc-port 8899 \\
    --dynamic-port-range 8000-8020 \\
    --wal-recovery-mode skip_any_corrupted_record \\
    --limit-ledger-size \\
    --no-port-check \\
    --use-snapshot-archives-at-startup when-newest \\
"
  if [[ -n "$PUBLIC_RPC_ADDRESS" ]]; then
    VALIDATOR_SCRIPT+="    --public-rpc-address ${PUBLIC_RPC_ADDRESS} \\
    --rpc-bind-address 127.0.0.1 \\
"
  fi
  VALIDATOR_SCRIPT+="    --full-rpc-api
"
fi

# Write validator.sh to server
sol_script <<SCRIPT
cat > ~/validator.sh <<'VALEOF'
${VALIDATOR_SCRIPT}
VALEOF

chmod +x ~/validator.sh
echo "validator.sh created"
SCRIPT

# Post-start arb commands. The pipeline always boots disabled, so this has to be
# run against a running validator after every (re)start.
if $ENABLE_HEXIS; then
  log_info "Step 8b: Creating ${HEXIS_DIR}/arb-enable.sh"

  HEXIS_ARB_ENABLE="$(hexis_render_arb_enable "$HEXIS_DIR" "$LEDGER_PATH")"
  sol_script <<SCRIPT
cat > ${HEXIS_DIR}/arb-enable.sh <<'ARBENEOF'
${HEXIS_ARB_ENABLE}
ARBENEOF

chmod +x ${HEXIS_DIR}/arb-enable.sh
echo "arb-enable.sh created"
SCRIPT
fi

# ---------------------------------------------------------------------------
# Step 9: Create systemd service
# ---------------------------------------------------------------------------
log_info "Step 9: Creating systemd service"

root_script <<SCRIPT
# Fix mount ownership service — runs before sol.service on every boot
cat > /etc/systemd/system/sol-fix-mounts.service <<'FIXEOF'
[Unit]
Description=Fix Solana mount ownership
Before=sol.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for d in /mnt/ledger /mnt/ledger/snapshots /mnt/accounts /home/${SOL_USER}/logs; do [ -d "\$d" ] && chown ${SOL_USER}:${SOL_USER} "\$d"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
FIXEOF

cat > /etc/systemd/system/sol.service <<'SVCEOF'
[Unit]
Description=Solana Validator
After=network.target sol-fix-mounts.service
Requires=sol-fix-mounts.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=${SOL_USER}
WorkingDirectory=/home/${SOL_USER}
LimitNOFILE=1000000
LimitMEMLOCK=2000000000
LogRateLimitIntervalSec=0
${XDP_CAPS}
Environment="PATH=/home/${SOL_USER}/.local/share/solana/install/active_release/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/home/${SOL_USER}/validator.sh

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable sol-fix-mounts.service
systemctl enable sol.service
echo "sol.service and sol-fix-mounts.service created and enabled"
SCRIPT

# ---------------------------------------------------------------------------
# Step 10: Log rotation
# ---------------------------------------------------------------------------
log_info "Step 10: Setting up log rotation"

root_script <<SCRIPT
cat > /etc/logrotate.d/sol <<'LOGEOF'
/home/${SOL_USER}/logs/*.log {
    daily
    rotate 7
    dateext
    compress
    delaycompress
    missingok
    copytruncate
}
LOGEOF
echo "Log rotation configured"
SCRIPT

# ---------------------------------------------------------------------------
# Step 11: Firewall
# ---------------------------------------------------------------------------
log_info "Step 11: Configuring firewall"

root_script <<'SCRIPT'
# Reset ufw to defaults if not already enabled
if ! ufw status | grep -q "Status: active"; then
  ufw default deny incoming
  ufw default allow outgoing
fi

# SSH
ufw allow 22/tcp

# Solana validator ports
ufw allow 8000:10000/tcp
ufw allow 8000:10000/udp

# DoubleZero interface rules
ufw allow in on doublezero0 to any port 44880 proto udp
ufw allow out on doublezero0 to any port 44880 proto udp

# Enable (idempotent - won't prompt if already active)
echo "y" | ufw enable

ufw status verbose
SCRIPT

# Hexis Control is plaintext gRPC — only the Hexis fleet may reach it.
if $ENABLE_HEXIS && $HEXIS_CONTROL; then
  HEXIS_CONTROL_PORT="${HEXIS_CONTROL_BIND##*:}"
  root_script <<SCRIPT
ufw allow from ${HEXIS_CONTROL_ALLOW} to any port ${HEXIS_CONTROL_PORT} proto tcp
echo "Allowed ${HEXIS_CONTROL_PORT}/tcp from ${HEXIS_CONTROL_ALLOW} (Hexis Control)"
SCRIPT
fi

# jag-snap proxies the validator RPC on 18899 — open it when jag-snap is set up.
if [[ -n "$GITHUB_SSH_KEY" ]]; then
  root_script <<'SCRIPT'
ufw allow 18899/tcp
echo "Allowed 18899/tcp for jag-snap"
SCRIPT
fi

# ---------------------------------------------------------------------------
# Step 12: SSH hardening
# ---------------------------------------------------------------------------
log_info "Step 12: Hardening SSH"

root_script <<'SCRIPT'
SSHD_CONFIG="/etc/ssh/sshd_config"

# Disable password auth (idempotent)
if grep -q "^PasswordAuthentication yes" "$SSHD_CONFIG" 2>/dev/null || \
   ! grep -q "^PasswordAuthentication no" "$SSHD_CONFIG" 2>/dev/null; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
  sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  echo "SSH hardened - password auth disabled"
else
  echo "SSH already hardened"
fi
SCRIPT

# ---------------------------------------------------------------------------
# Step 13: fail2ban
# ---------------------------------------------------------------------------
log_info "Step 13: Configuring fail2ban"

root_script <<'SCRIPT'
if ! systemctl is-active --quiet fail2ban; then
  systemctl enable --now fail2ban
  echo "fail2ban enabled"
else
  echo "fail2ban already running"
fi
SCRIPT

# ---------------------------------------------------------------------------
# Step 14: jag-snap (Docker-based snapshot tool)
# ---------------------------------------------------------------------------
if [[ -n "$GITHUB_SSH_KEY" ]]; then
  log_info "Step 14: Setting up jag-snap"

  sol_script <<'SCRIPT'
if [ -d ~/jag-snap ]; then
  echo "jag-snap already cloned"
else
  git clone git@github.com:jaguar-labs/jag-snap.git ~/jag-snap
  echo "Cloned jag-snap"
fi
SCRIPT

  root_script <<'SCRIPT'
# Ensure docker is running
systemctl enable --now docker

# Add sol user to docker group so it can run containers
usermod -aG docker sol
SCRIPT

  root_script <<SCRIPT
cd /home/${SOL_USER}/jag-snap

# Build the image
docker build -t jag-snap .
echo "jag-snap image built"

# Remove existing container if present
docker rm -f jag-snap 2>/dev/null || true

# Run jag-snap
docker run -d --restart unless-stopped --name jag-snap --network host jag-snap
echo "jag-snap container started"
SCRIPT

else
  log_warn "Step 14: No --github-ssh-key provided — skipping jag-snap setup"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_info "============================================"
log_info "Validator server setup complete!"
log_info "============================================"
log_info ""
log_info "Next steps:"
log_info "  1. Start the validator:      ssh $SSH_OPTS $SOL_HOST 'sudo systemctl start sol'"
log_info "  2. Check logs:               ssh $SSH_OPTS $SOL_HOST 'tail -f /home/${SOL_USER}/logs/solana-validator.log'"
log_info "  3. Monitor catchup:          ssh $SSH_OPTS $SOL_HOST 'solana catchup --our-localhost'"
log_info "  4. Check validator status:   ssh $SSH_OPTS $SOL_HOST 'solana-validator --ledger ${LEDGER_PATH} monitor'"
log_info ""
log_info "The validator service is enabled but NOT started automatically."
log_info "Start it manually when ready with: sudo systemctl start sol"

if $ENABLE_HEXIS; then
  log_info ""
  log_info "Hexis arb client:"
  log_info "  Config:      ${HEXIS_DIR}/arb-config.toml   (read once at boot)"
  [[ -n "${HEXIS_RELEASE:-}" ]] && log_info "  Release:     ${HEXIS_DIR}/releases/${HEXIS_RELEASE}  (agave-validator -> it)"
  if [[ -n "$HEXIS_SIGNER_PUBKEY" ]]; then
    log_info "  Signer:      ${HEXIS_SIGNER_PUBKEY}"
    log_info "               ${HEXIS_SIGNER_PATH} — fund it, it pays arb transaction fees"
  fi
  [[ -n "$HEXIS_PROFIT_WALLET" ]] && log_info "  Profit pool: ${HEXIS_PROFIT_WALLET}"
  log_info "  Reverts:     ${HEXIS_DIR}/arb-reverts"
  if $HEXIS_CONTROL; then
    log_info "  Control:     ${HEXIS_CONTROL_BIND}, open to ${HEXIS_CONTROL_ALLOW} only"
  fi
  log_info ""
  log_info "  The arb pipeline boots DISABLED on every start. Once the validator is"
  log_info "  running and caught up, enable it with:"
  log_info "    ${SSH_CMD} $SOL_HOST '${HEXIS_DIR}/arb-enable.sh'"
  log_info "  Check or stop it with:"
  log_info "    ${HEXIS_DIR}/agave-validator --ledger ${LEDGER_PATH} arb get"
  log_info "    ${HEXIS_DIR}/agave-validator --ledger ${LEDGER_PATH} arb disable"

  HEXIS_FL_ACCOUNT="$HEXIS_MARGINFI_ACCOUNT"
  $DRY_RUN || HEXIS_FL_ACCOUNT=$(hexis_flash_loan_account 2>/dev/null || true)
  if [[ -n "$HEXIS_FL_ACCOUNT" ]]; then
    log_info "  Flash loans: ON via marginfi account ${HEXIS_FL_ACCOUNT}"
  else
    log_info ""
    log_info "  Flash loans are OFF — arb-config.toml has no [flash_loan] table."
    log_info "  To turn them on, either re-run with the marginfi account Hexis issued, or"
    log_info "  create your own once this host is up:"
    log_info "    1. Fund the arb signer (${HEXIS_SIGNER_PUBKEY:-see above}) — it pays for the account"
    if $HEXIS_SETUP_INSTALLED; then
      log_info "    2. ${SSH_CMD} $SOL_HOST '${HEXIS_DIR}/hexis-setup marginfi create'   # see marginfi.md"
    else
      log_info "    2. Install hexis-setup (--hexis-setup-binary, or a release that ships it),"
      log_info "       then run: ${HEXIS_DIR}/hexis-setup marginfi create   # see marginfi.md"
    fi
    log_info "    3. Re-run arise.sh with --hexis-marginfi-account <PUBKEY> and restart the"
    log_info "       validator — arb-config.toml is only read at boot"
  fi
fi
