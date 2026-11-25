#!/usr/bin/env bash
# shellcheck disable=SC2034
# (variables are handed to remote scripts by name through emit_vars, which the
# linter cannot follow, so its "unused variable" check is off for this file)
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
# Security model:
#   - An admin user (default: monarch) holds sudo (password required) and is used
#     for all system-level changes.
#   - The service user (sol) runs the validator and has NO sudo and NO docker access.
#   - Root SSH login and SSH password authentication are disabled.
#   - Scripts and passwords are sent to the server over SSH stdin only; nothing is
#     written to /tmp and no secret ever appears in a process list.
#
# Prerequisites:
#   - SSH access to the target server (key-based)
#   - A staked_identity.json file (validator identity keypair with a vote account already configured)
#   - git installed locally (only needed to list release tags when --client-version is omitted)
#   - gh installed and logged in locally, only for --hexis-tag (private release download)
#   - Server has Ubuntu 24.04 (or compatible) installed
#   - Server has NVMe drives available for ledger/accounts/snapshots
#
# Works with the stock macOS bash (3.2) — do not use bash 4+ features in this file.
#
# Usage:
#   ./arise.sh \
#     --host <ip-or-hostname> \
#     --ssh-key <path-to-ssh-key> \
#     --identity <path-to-staked_identity.json> \
#     --vote-account <vote-account-pubkey> \
#     --network <testnet|mainnet> \
#     [--root-user root] \
#     [--client jito|agave] [--client-version v4.4.1-jito] \
#     [--dry-run]

set -euo pipefail

# Shared libraries: Hexis defaults, logging and rendering; remote execution
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
for lib in hexis.sh remote.sh; do
  if [[ ! -f "$LIB_DIR/$lib" ]]; then
    echo "Missing $LIB_DIR/$lib — run this from a checkout, not as a lone copied file" >&2
    exit 1
  fi
done
# shellcheck source=lib/hexis.sh
source "$LIB_DIR/hexis.sh"
# shellcheck source=lib/remote.sh
source "$LIB_DIR/remote.sh"

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
ROOT_USER=""
ADMIN_USER="monarch"
IDENTITY_FILE=""
VOTE_ACCOUNT=""
COMMISSION_BPS=""
SOL_USER="sol"
JITO_REGION=""

# Which validator client to install.
#   jito       — Jito-Solana, built from the public repo (default)
#   agave      — Anza Agave, built from the public repo
#   firedancer — Firedancer with the Hexis Concorde. The host is provisioned
#                here and Firedancer is then staged by reawaken.sh; its binary
#                comes from a private release (--fd-tag / --fd-binary).
# --hexis layers the Hexis arb client on top of jito: its binary comes from a
# private release (--hexis-tag / --hexis-binary), so nothing is built from source.
CLIENT="jito"
CLIENT_REPO=""               # default depends on --client
CLIENT_VERSION=""            # release tag to build
JITO_DEFAULT_REPO="https://github.com/jito-foundation/jito-solana.git"
AGAVE_DEFAULT_REPO="https://github.com/anza-xyz/agave.git"
BUILD_FORCED=false           # --build-client: build from source even with --hexis
FD_TAG=""                    # Firedancer release tag (private repo, fetched locally with gh)
FD_BINARY=""                 # pre-downloaded Firedancer binary (instead of --fd-tag)
FD_CONCORDE_TABLES=""        # local copy of the Concorde config tables (instead of fetching them)
# Run against a host that already has a validator, a different --client is a
# client switch. --restart finishes it: wait for a restart window, then move
# the running validator onto what was just installed.
RESTART=false
MIN_IDLE_TIME="20"
MAX_DELINQUENT_STAKE="5"
WINDOW_ARGS=()               # the two above, only when given — passed on to reawaken.sh

# Cluster metrics (SFDP). Empty disables the export; default is per-network.
METRICS_CONFIG="${SOLANA_METRICS_CONFIG:-}"
METRICS_CONFIG_SET=false

# XDP (Anza accelerated retransmit) — https://www.anza.xyz/blog/agave-xdp-setup-guide
ENABLE_XDP=true
XDP_CPU_CORES="1"        # value for --experimental-retransmit-xdp-cpu-cores
POH_PINNED_CORE="10"     # value for --experimental-poh-pinned-cpu-core (separate physical core)
XDP_INTERFACE=""         # override auto-detected NIC (use bond member for bonded setups)
XDP_ZERO_COPY="auto"     # auto|on|off — auto disables for bnxt_en/ice drivers

# Hexis arb client — off unless --hexis is passed. Mainnet only.
# Config defaults live in lib/hexis.sh.
ENABLE_HEXIS=false
HEXIS_DIR="/home/${SOL_USER}/hexis"
HEXIS_TAG=""                 # release tag — downloaded locally with gh, then uploaded
HEXIS_BINARY=""              # pre-downloaded agave-validator binary (instead of --hexis-tag)
HEXIS_SETUP_BINARY=""        # pre-downloaded hexis-setup binary
HEXIS_CONFIG=""              # upload this arb-config.toml verbatim instead of generating one
HEXIS_SIGNER=""              # local arb signer keypair; generated on the server when not given
HEXIS_CONTROL=true           # [control] — inbound gRPC that Hexis dumpd/ops poll
CONFIRM_FORMAT=false
KEEP_ROOT_LOGIN=false
DISABLE_CPU_MITIGATIONS=false
DISABLE_AUTO_UPDATES=false
INSTALL_PERCH=true
PERCH_VERSION="latest"
PERCH_LABEL=""
PERCH_REPO="TheChimpions/perch-watchtower"

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

die() { log_error "$*"; exit 1; }


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

Access:
  --root-user <user>            Existing SSH user with root/sudo access (e.g. root).
                                Only needed on the first run, to create the admin
                                user. Not used again once the admin user exists.
  --admin-user <name>           Admin user that holds sudo (default: monarch).
                                The sol user runs the validator and has no sudo.
  --keep-root-login             Keep key-based root SSH login enabled
                                (default: root SSH login is disabled)

Validator client:
  --client <jito|agave|firedancer>
                                Client to set up from scratch (default: jito).
                                jito and agave are built on the server from their
                                public repos. firedancer is Firedancer with the
                                Hexis Concorde (mainnet only): the host is
                                provisioned here, then reawaken.sh stages it
  --fd-tag <tag>                Firedancer release to stage, fetched with the local
                                gh CLI from the private ${HEXIS_REPO}
  --fd-binary <path>            Pre-downloaded Firedancer binary (instead of --fd-tag)
  --concorde-tables <path>      Local copy of the Concorde config tables, instead of
                                fetching them with gh (passed on to reawaken.sh)
  --client-version <tag>        Release tag to build (e.g. v4.4.1-jito, v4.4.1).
                                If omitted, recent tags are listed to choose from.
                                A different tag on a later run is built and
                                active_release is switched to it.
  --client-repo <https-url>     Git repo to build from (default: the client's
                                public repo)
  --build-client                Build from source even with --hexis. Off by
                                default: the Hexis release ships the validator
                                binary, so the source build is skipped and the
                                prebuilt Solana CLI is installed instead

Changing client or version on a host that already runs a validator:
  Run this script again with the same flags and the new --client (and
  --client-version, --hexis, --fd-tag ...). The new client is installed next to
  the running one and validator.sh is rewritten for it. Nothing is restarted
  unless you ask:
  --restart                     Once everything is in place, wait for a restart
                                window and move the running validator onto the
                                new client. From or to Firedancer this hands over
                                to reawaken.sh (rollback / cutover), which asks
                                before it stops anything
  --min-idle-time <min>         Minutes without a leader slot the restart waits
                                for (default: ${MIN_IDLE_TIME})
  --max-delinquent-stake <pct>  Do not restart while more than this much stake
                                is delinquent (default: ${MAX_DELINQUENT_STAKE})

Optional:
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
  --confirm-format              Skip the interactive confirmation before formatting disks
  --swap-size <size>            Swap file size (default: 128G)
  --dry-run                     Print what would run. Makes no connection to the server.
  -h, --help                    Show this help

Monitoring (perch watchtower, installed by default):
  --no-perch                    Do not install perch
  --perch-version <vX.Y.Z>      perch release to install (default: latest)
  --perch-label <name>          Name used for this validator in alerts
                                (default: the --host value)

XDP (accelerated retransmit, per Anza XDP setup guide):
  XDP is set up by default: grant the validator the required capabilities,
  tune NIC ring sizes to powers of 2, and add the retransmit/PoH flags.
  Requires Agave v3.0.9+ and kernel 6.8+ (6.14+ for the igb driver).
  --no-xdp                      Disable XDP setup entirely
  --xdp-cpu-cores <n>           XDP retransmit CPU cores (default: 1)
  --poh-pinned-core <n>         Core the PoH thread is pinned to (default: 10).
                                MUST be a different physical core than the XDP cores.
  --xdp-interface <iface>       NIC to attach XDP to (default: auto-detect from the
                                default route; bond members are resolved automatically)
  --xdp-zero-copy <auto|on|off> Zero-copy mode (default: auto). Auto disables it for
                                the bnxt_en and ice drivers, which don't support it.

Hexis arb client (https://github.com/hexishq/hexis-validator-docs):
  Off by default. Mainnet only, with --client jito. Installs the Hexis
  agave-validator build into ${HEXIS_DIR}, writes arb-config.toml, and adds
  --arb-config to validator.sh. The binary comes from a private release, so one
  of --hexis-tag or --hexis-binary is needed on the first run.
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

Performance trade-offs (off by default because they reduce security):
  --disable-cpu-mitigations     Add mitigations=off to the kernel command line
  --disable-auto-updates        Disable unattended security updates

Disk selection priority:
  1. Explicit --ledger-disk / --accounts-disk flags (disables auto-detection)
  2. Existing /mnt/ledger and /mnt/accounts mounts from a previous run
  3. Auto-detection (default): scans server for blank, unused NVMe drives
  4. Falls back to /home/sol/ directories if no drives found
EOF
  exit "${1:-1}"
}

need_arg() { [[ $# -ge 2 ]] || { log_error "$1 requires a value"; usage; }; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)           need_arg "$@"; SSH_HOST="$2";       shift 2 ;;
    --root-user)      need_arg "$@"; ROOT_USER="$2";      shift 2 ;;
    --admin-user)     need_arg "$@"; ADMIN_USER="$2";     shift 2 ;;
    --ssh-key)        need_arg "$@"; SSH_KEY="$2";        shift 2 ;;
    --identity)       need_arg "$@"; IDENTITY_FILE="$2";  shift 2 ;;
    --vote-account)   need_arg "$@"; VOTE_ACCOUNT="$2";   shift 2 ;;
    --commission-bps) need_arg "$@"; COMMISSION_BPS="$2"; shift 2 ;;
    --jito-region)    need_arg "$@"; JITO_REGION="$2";    shift 2 ;;
    --client)         need_arg "$@"; CLIENT="$2";         shift 2 ;;
    --fd-tag)         need_arg "$@"; FD_TAG="$2";         shift 2 ;;
    --fd-binary)      need_arg "$@"; FD_BINARY="$2";      shift 2 ;;
    --concorde-tables) need_arg "$@"; FD_CONCORDE_TABLES="$2"; shift 2 ;;
    --client-version|--jito-version) need_arg "$@"; CLIENT_VERSION="$2"; shift 2 ;;
    --client-repo|--jito-repo)       need_arg "$@"; CLIENT_REPO="$2";    shift 2 ;;
    --build-client|--build-jito)     BUILD_FORCED=true; shift ;;
    --restart)        RESTART=true;                 shift ;;
    --min-idle-time)  need_arg "$@"; MIN_IDLE_TIME="$2"; WINDOW_ARGS+=(--min-idle-time "$2"); shift 2 ;;
    --max-delinquent-stake) need_arg "$@"; MAX_DELINQUENT_STAKE="$2"; WINDOW_ARGS+=(--max-delinquent-stake "$2"); shift 2 ;;
    --github-ssh-key) need_arg "$@"; log_warn "--github-ssh-key is no longer used and was ignored: clients are built from public repos over HTTPS"; shift 2 ;;
    --metrics-config) need_arg "$@"; METRICS_CONFIG="$2"; METRICS_CONFIG_SET=true; shift 2 ;;
    --enable-xdp)     ENABLE_XDP=true;              shift ;;
    --no-xdp)         ENABLE_XDP=false;             shift ;;
    --xdp-cpu-cores)  need_arg "$@"; XDP_CPU_CORES="$2";   shift 2 ;;
    --poh-pinned-core) need_arg "$@"; POH_PINNED_CORE="$2"; shift 2 ;;
    --xdp-interface)  need_arg "$@"; XDP_INTERFACE="$2";   shift 2 ;;
    --xdp-zero-copy)  need_arg "$@"; XDP_ZERO_COPY="$2";   shift 2 ;;
    --hexis)          ENABLE_HEXIS=true;            shift ;;
    --hexis-tag)      need_arg "$@"; HEXIS_TAG="$2";       shift 2 ;;
    --hexis-binary)   need_arg "$@"; HEXIS_BINARY="$2";    shift 2 ;;
    --hexis-setup-binary) need_arg "$@"; HEXIS_SETUP_BINARY="$2"; shift 2 ;;
    --hexis-setup-tag) need_arg "$@"; HEXIS_SETUP_TAG="$2"; shift 2 ;;
    --hexis-config)   need_arg "$@"; HEXIS_CONFIG="$2";    shift 2 ;;
    --hexis-signer)   need_arg "$@"; HEXIS_SIGNER="$2";    shift 2 ;;
    --hexis-dir)      need_arg "$@"; HEXIS_DIR="$2";       shift 2 ;;
    --hexis-program-id)    need_arg "$@"; HEXIS_PROGRAM_ID="$2";    shift 2 ;;
    --hexis-profit-wallet) need_arg "$@"; HEXIS_PROFIT_WALLET="$2"; shift 2 ;;
    --hexis-jup-key)  need_arg "$@"; HEXIS_JUP_KEY="$2";   shift 2 ;;
    --hexis-metrics-config) need_arg "$@"; HEXIS_METRICS_CONFIG="$2"; shift 2 ;;
    --hexis-lookup-tables)  need_arg "$@"; HEXIS_LOOKUP_TABLES="$2";  shift 2 ;;
    --hexis-jupiter-token-ledger) need_arg "$@"; HEXIS_JUPITER_TOKEN_LEDGER="$2"; shift 2 ;;
    --hexis-okx-token-ledger)     need_arg "$@"; HEXIS_OKX_TOKEN_LEDGER="$2";     shift 2 ;;
    --hexis-base-mints)     need_arg "$@"; HEXIS_BASE_MINTS="$2";     shift 2 ;;
    --hexis-marginfi-account) need_arg "$@"; HEXIS_MARGINFI_ACCOUNT="$2"; shift 2 ;;
    --no-hexis-flash-loans) HEXIS_MARGINFI_ACCOUNT=""; shift ;;
    --hexis-marginfi-banks) need_arg "$@"; HEXIS_MARGINFI_BANKS="$2"; shift 2 ;;
    --hexis-marginfi-program-id) need_arg "$@"; HEXIS_MARGINFI_PROGRAM_ID="$2"; shift 2 ;;
    --hexis-control-bind)  need_arg "$@"; HEXIS_CONTROL_BIND="$2";  shift 2 ;;
    --hexis-control-allow) need_arg "$@"; HEXIS_CONTROL_ALLOW="$2"; shift 2 ;;
    --no-hexis-control) HEXIS_CONTROL=false; shift ;;
    --network)        need_arg "$@"; NETWORK="$2";        shift 2 ;;
    --ledger-disk)    need_arg "$@"; LEDGER_DISK="$2";   AUTO_DISKS=false; shift 2 ;;
    --accounts-disk)  need_arg "$@"; ACCOUNTS_DISK="$2"; AUTO_DISKS=false; shift 2 ;;
    --no-auto-disks)  AUTO_DISKS=false;             shift ;;
    --confirm-format) CONFIRM_FORMAT=true;          shift ;;
    --keep-root-login) KEEP_ROOT_LOGIN=true;        shift ;;
    --disable-cpu-mitigations) DISABLE_CPU_MITIGATIONS=true; shift ;;
    --disable-auto-updates)    DISABLE_AUTO_UPDATES=true;    shift ;;
    --no-perch)       INSTALL_PERCH=false;          shift ;;
    --perch-version)  need_arg "$@"; PERCH_VERSION="$2";  shift 2 ;;
    --perch-label)    need_arg "$@"; PERCH_LABEL="$2";    shift 2 ;;
    --swap-size)      need_arg "$@"; SWAP_SIZE="$2";      shift 2 ;;
    --dry-run)        DRY_RUN=true;                 shift ;;
    -h|--help)        usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
#
# Every value below ends up inside a script that runs as root on the server,
# so each one is checked against a strict pattern before it is used.
# ---------------------------------------------------------------------------
[[ -z "$SSH_HOST" ]]      && { log_error "--host is required";         usage; }
[[ -z "$SSH_KEY" ]]       && { log_error "--ssh-key is required";      usage; }
[[ -z "$IDENTITY_FILE" ]] && { log_error "--identity is required";     usage; }
[[ -z "$VOTE_ACCOUNT" ]]  && { log_error "--vote-account is required"; usage; }

[[ -f "$SSH_KEY" ]]       || die "SSH key not found: $SSH_KEY"
[[ -f "$IDENTITY_FILE" ]] || die "Identity file not found: $IDENTITY_FILE"

if [[ "$NETWORK" != "testnet" && "$NETWORK" != "mainnet" ]]; then
  die "--network must be 'testnet' or 'mainnet'"
fi

# Strip user@ prefix from --host if accidentally included
SSH_HOST="${SSH_HOST##*@}"

RE_HOST='^[A-Za-z0-9][A-Za-z0-9.:-]*$'
RE_USER='^[a-z_][a-z0-9_-]{0,31}$'
RE_PUBKEY='^[1-9A-HJ-NP-Za-km-z]{32,44}$'
RE_DEVICE='^/dev/[A-Za-z0-9._/-]+$'
RE_SWAP='^[1-9][0-9]*[MG]$'
RE_REF='^[A-Za-z0-9][A-Za-z0-9._-]*$'
RE_REPO='^https://[A-Za-z0-9._/-]+$'
RE_REGION='^[a-z][a-z-]*$'
RE_COORD='^-?[0-9]{1,3}(\.[0-9]+)?$'
RE_SSH_PUBKEY='^[a-z0-9@.-]+ [A-Za-z0-9+/=]+$'

[[ "$SSH_HOST" =~ $RE_HOST ]]         || die "--host is not a valid hostname or IP: $SSH_HOST"
[[ "$ADMIN_USER" =~ $RE_USER ]]       || die "--admin-user is not a valid username: $ADMIN_USER"
[[ "$VOTE_ACCOUNT" =~ $RE_PUBKEY ]]   || die "--vote-account is not a valid base58 pubkey: $VOTE_ACCOUNT"
[[ "$SWAP_SIZE" =~ $RE_SWAP ]]        || die "--swap-size must look like 128G or 512M: $SWAP_SIZE"

case "$CLIENT" in
  jito)  CLIENT_REPO="${CLIENT_REPO:-$JITO_DEFAULT_REPO}" ;;
  agave) CLIENT_REPO="${CLIENT_REPO:-$AGAVE_DEFAULT_REPO}" ;;
  firedancer) CLIENT_REPO="$JITO_DEFAULT_REPO" ;;   # nothing is built; see below
  *) die "--client must be 'jito', 'agave' or 'firedancer': $CLIENT" ;;
esac
[[ "$CLIENT_REPO" =~ $RE_REPO ]]      || die "--client-repo must be an https:// URL: $CLIENT_REPO"
# Jito-specific pieces: block engine, shred receiver, tip programs, commission
USES_JITO=false
[[ "$CLIENT" == "jito" || "$CLIENT" == "firedancer" ]] && USES_JITO=true

# Firedancer from scratch: this script provisions the host and writes
# validator.sh as the record of the validator's settings (identity, vote
# account, entrypoints, Block Engine, shred receivers). reawaken.sh then stages
# Firedancer from that file, exactly as it does for a host that ran Agave.
IS_FIREDANCER=false
REAWAKEN="$(dirname "$LIB_DIR")/reawaken.sh"
if [[ "$CLIENT" == "firedancer" ]]; then
  IS_FIREDANCER=true
  [[ "$NETWORK" == "mainnet" ]] || die "--client firedancer requires --network mainnet (the Hexis Concorde build is mainnet-only)"
  [[ -x "$REAWAKEN" ]] || die "Missing $REAWAKEN — run this from a checkout"
  [[ -n "$FD_TAG" && -n "$FD_BINARY" ]] && die "Pass either --fd-tag or --fd-binary, not both"
  if [[ -n "$FD_TAG" ]]; then
    [[ "$FD_TAG" =~ $RE_REF ]] || die "--fd-tag is not a valid tag: $FD_TAG"
  fi
  [[ -n "$FD_BINARY" && ! -f "$FD_BINARY" ]] && die "File not found: $FD_BINARY"
  [[ -n "$FD_CONCORDE_TABLES" && ! -f "$FD_CONCORDE_TABLES" ]] && die "File not found: $FD_CONCORDE_TABLES"
  [[ -n "$HEXIS_SIGNER" && ! -f "$HEXIS_SIGNER" ]] && die "File not found: $HEXIS_SIGNER"
  if $ENABLE_HEXIS; then
    log_info "--client firedancer is the Hexis Concorde build, so the arb client comes with it — --hexis adds nothing here"
    ENABLE_HEXIS=false
  fi
  if $ENABLE_XDP; then
    # The Agave XDP flags and capabilities do not apply; Firedancer drives the NIC itself
    ENABLE_XDP=false
  fi
elif [[ -n "$FD_TAG" || -n "$FD_BINARY" || -n "$FD_CONCORDE_TABLES" ]]; then
  die "--fd-tag, --fd-binary and --concorde-tables only go with --client firedancer"
fi

if [[ -n "$ROOT_USER" ]]; then
  [[ "$ROOT_USER" =~ $RE_USER ]]      || die "--root-user is not a valid username: $ROOT_USER"
fi
if [[ "$ADMIN_USER" == "root" || "$ADMIN_USER" == "$SOL_USER" ]]; then
  die "--admin-user must be a dedicated account, not root or ${SOL_USER}"
fi
if [[ -n "$CLIENT_VERSION" ]]; then
  [[ "$CLIENT_VERSION" =~ $RE_REF ]]  || die "--client-version is not a valid tag: $CLIENT_VERSION"
fi
if [[ -n "$JITO_REGION" ]]; then
  [[ "$JITO_REGION" =~ $RE_REGION ]]  || die "--jito-region is not a valid region name: $JITO_REGION"
fi
[[ "$MIN_IDLE_TIME" =~ ^[0-9]{1,4}$ ]]        || die "--min-idle-time must be a number of minutes: $MIN_IDLE_TIME"
[[ "$MAX_DELINQUENT_STAKE" =~ ^[0-9]{1,3}$ ]] || die "--max-delinquent-stake must be a percentage: $MAX_DELINQUENT_STAKE"
if [[ -n "$LEDGER_DISK" ]]; then
  [[ "$LEDGER_DISK" =~ $RE_DEVICE ]]  || die "--ledger-disk must be a /dev path: $LEDGER_DISK"
fi
if [[ -n "$ACCOUNTS_DISK" ]]; then
  [[ "$ACCOUNTS_DISK" =~ $RE_DEVICE ]] || die "--accounts-disk must be a /dev path: $ACCOUNTS_DISK"
fi
if [[ -n "$LEDGER_DISK" && "$LEDGER_DISK" == "$ACCOUNTS_DISK" ]]; then
  die "--ledger-disk and --accounts-disk are the same device. Pass only --ledger-disk to share one disk."
fi

RE_PERCH_VERSION='^(latest|v[0-9]+\.[0-9]+\.[0-9]+)$'
RE_LABEL='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
[[ "$PERCH_VERSION" =~ $RE_PERCH_VERSION ]] || die "--perch-version must be 'latest' or look like v1.5.4: $PERCH_VERSION"
if [[ -z "$PERCH_LABEL" ]]; then
  PERCH_LABEL=$(printf '%s' "$SSH_HOST" | tr -c 'A-Za-z0-9._-' '-')
fi
[[ "$PERCH_LABEL" =~ $RE_LABEL ]] || die "--perch-label may only contain letters, digits, dots, dashes and underscores: $PERCH_LABEL"

if $ENABLE_XDP; then
  if [[ "$XDP_ZERO_COPY" != "auto" && "$XDP_ZERO_COPY" != "on" && "$XDP_ZERO_COPY" != "off" ]]; then
    die "--xdp-zero-copy must be 'auto', 'on', or 'off'"
  fi
  [[ "$XDP_CPU_CORES" =~ ^[0-9][0-9,-]*$ ]] || die "--xdp-cpu-cores must be a core number or list: $XDP_CPU_CORES"
  [[ "$POH_PINNED_CORE" =~ ^[0-9]+$ ]]      || die "--poh-pinned-core must be a core number: $POH_PINNED_CORE"
  if [[ -n "$XDP_INTERFACE" ]]; then
    [[ "$XDP_INTERFACE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--xdp-interface is not a valid interface name: $XDP_INTERFACE"
  fi
  if [[ "$XDP_CPU_CORES" == "$POH_PINNED_CORE" ]]; then
    die "--xdp-cpu-cores ($XDP_CPU_CORES) and --poh-pinned-core ($POH_PINNED_CORE) must differ — XDP and PoH require separate physical cores"
  fi
fi

if $ENABLE_HEXIS; then
  if [[ "$NETWORK" != "mainnet" ]]; then
    die "--hexis requires --network mainnet (the arb config and its pools are mainnet-only)"
  fi
  if [[ "$CLIENT" != "jito" ]]; then
    die "--hexis needs --client jito: the Hexis build is a Jito-Solana validator"
  fi
  if [[ -n "$HEXIS_TAG" && -n "$HEXIS_BINARY" ]]; then
    die "Pass either --hexis-tag or --hexis-binary, not both"
  fi
  if [[ -n "$HEXIS_TAG" ]]; then
    [[ "$HEXIS_TAG" =~ $RE_REF ]] || die "--hexis-tag is not a valid tag: $HEXIS_TAG"
    if ! command -v gh &>/dev/null; then
      die "--hexis-tag needs the gh CLI locally. Install it, or download the release yourself and pass --hexis-binary"
    fi
    # The release is private: the download is a GitHub API call from THIS
    # machine using gh's token. Nothing GitHub-related is put on the server.
    if ! gh auth status &>/dev/null; then
      die "gh is not authenticated — run 'gh auth login' with an account that can see ${HEXIS_REPO}"
    fi
  fi
  for f in "$HEXIS_BINARY" "$HEXIS_SETUP_BINARY" "$HEXIS_CONFIG" "$HEXIS_SIGNER"; do
    [[ -n "$f" && ! -f "$f" ]] && die "File not found: $f"
  done
  [[ "$HEXIS_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "--hexis-dir must be an absolute path without spaces: $HEXIS_DIR"
  [[ "$HEXIS_CONTROL_BIND" =~ ^[0-9A-Za-z.:-]+:[0-9]{1,5}$ ]] || die "--hexis-control-bind must look like 0.0.0.0:18082: $HEXIS_CONTROL_BIND"
  [[ "$HEXIS_CONTROL_ALLOW" =~ ^[0-9A-Fa-f.:]+(/[0-9]{1,3})?$ ]] || die "--hexis-control-allow must be an IP or CIDR: $HEXIS_CONTROL_ALLOW"
  if [[ "$HEXIS_CONTROL_BIND" == 127.0.0.1:* || "$HEXIS_CONTROL_BIND" == localhost:* ]]; then
    die "--hexis-control-bind must not be loopback — Hexis dials the host directly"
  fi
fi

# --hexis ships a validator binary, so nothing is built from source unless
# --build-client asks for it. Decided here because Step 6 (Rust) depends on it.
BUILD_FROM_SOURCE=true
if $ENABLE_HEXIS && ! $BUILD_FORCED; then
  BUILD_FROM_SOURCE=false
fi
# Firedancer ships as a binary too; only the Solana CLI is needed beside it
$IS_FIREDANCER && BUILD_FROM_SOURCE=false

validate_commission() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 <= 10000 ))
}
if [[ -n "$COMMISSION_BPS" ]]; then
  validate_commission "$COMMISSION_BPS" || die "--commission-bps must be an integer from 0 to 10000"
fi

SOL_HOME="/home/${SOL_USER}"
remote_init

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
# Agave/Jito v4.x refuses to start with a range narrower than 26 ports
# (MINIMUM_VALIDATOR_PORT_RANGE_WIDTH in net-utils; it was 25 in v3.x).
DYNAMIC_PORT_RANGE="8000-8026"
# ufw wants a colon-separated range; this is the only validator range opened.
FIREWALL_PORT_RANGE="${DYNAMIC_PORT_RANGE/-/:}"

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
# Remote access — the helpers (root_script, sol_script, remote, ...) live in
# lib/remote.sh and are shared with the other scripts.
# ---------------------------------------------------------------------------
# sol_put <remote-path> <mode> — write stdin to a file owned by sol. In a dry
# run the content is printed instead, so it can be reviewed.
sol_put() {
  if $DRY_RUN; then
    echo "[DRY RUN] write ${SOL_HOST}:$1 (mode $2):"
    cat
    echo ""
    return
  fi
  sol_write_file "$1" "$2"
}

prompt_new_password() {
  # Sets NEW_PASS
  local confirm
  while true; do
    IFS= read -rsp "Set sudo password for ${ADMIN_USER} (min 12 characters): " NEW_PASS
    echo ""
    if [[ ${#NEW_PASS} -lt 12 ]]; then
      log_warn "Password must be at least 12 characters"
      continue
    fi
    IFS= read -rsp "Confirm password: " confirm
    echo ""
    if [[ "$NEW_PASS" != "$confirm" ]]; then
      log_warn "Passwords do not match"
      continue
    fi
    break
  done
}

# ---------------------------------------------------------------------------
# Step 0: Access — admin user (sudo) and service user (no sudo)
# ---------------------------------------------------------------------------
SSH_PUBKEY=$(ssh-keygen -y -f "$SSH_KEY" | awk '{print $1" "$2}')
[[ "$SSH_PUBKEY" =~ $RE_SSH_PUBKEY ]] || die "Could not derive a public key from $SSH_KEY"

if $DRY_RUN; then
  log_info "Step 0: [DRY RUN] would connect as ${ADMIN_HOST}, bootstrapping it via --root-user if it does not exist"
elif can_ssh "$ADMIN_HOST"; then
  log_info "Step 0: Admin user ${ADMIN_USER} is accessible — skipping bootstrap"
  ask_sudo_pass || exit 1
  log_info "Sudo access confirmed for ${ADMIN_USER}"
else
  if [[ -z "$ROOT_USER" ]]; then
    log_error "Cannot SSH to ${ADMIN_HOST} with $SSH_KEY"
    log_error "On a fresh server, pass --root-user root to create the ${ADMIN_USER} admin user."
    log_error "On a server set up by an older arise.sh, pass --root-user ${SOL_USER} to migrate."
    exit 1
  fi

  BOOT_DEST="${ROOT_USER}@${SSH_HOST}"
  log_info "Step 0: Bootstrapping admin user ${ADMIN_USER} via ${BOOT_DEST}"

  can_ssh "$BOOT_DEST" || die "Cannot SSH to ${BOOT_DEST} — check SSH key and host"

  BOOT_PASS=""
  if [[ "$ROOT_USER" == "root" ]]; then
    BOOT_MODE="root"
  elif ssh "${SSH_OPTS[@]}" "$BOOT_DEST" "sudo -n true" </dev/null 2>/dev/null; then
    BOOT_MODE="sudo-nopass"
  else
    BOOT_MODE="sudo-pass"
    IFS= read -rsp "Enter sudo password for ${BOOT_DEST}: " BOOT_PASS
    echo ""
    check_sudo "$BOOT_DEST" "$BOOT_PASS" || die "Sudo password validation failed for ${BOOT_DEST}"
  fi

  prompt_new_password

  { emit_vars ADMIN_USER SSH_PUBKEY; cat <<'SCRIPT'
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$ADMIN_USER"
  echo "Created user $ADMIN_USER"
else
  echo "User $ADMIN_USER already exists"
fi

# Sudo with password. Validate the sudoers fragment before installing it —
# a broken file in sudoers.d disables sudo for everyone.
SUDOERS_TMP=$(mktemp)
echo "$ADMIN_USER ALL=(ALL:ALL) ALL" > "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP" >/dev/null
install -m 0440 -o root -g root "$SUDOERS_TMP" "/etc/sudoers.d/90-arise-$ADMIN_USER"
rm -f "$SUDOERS_TMP"

ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
touch "$ADMIN_HOME/.ssh/authorized_keys"
if ! grep -qF "$SSH_PUBKEY" "$ADMIN_HOME/.ssh/authorized_keys"; then
  echo "$SSH_PUBKEY" >> "$ADMIN_HOME/.ssh/authorized_keys"
  echo "Added SSH public key for $ADMIN_USER"
fi
chmod 600 "$ADMIN_HOME/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.ssh/authorized_keys"
echo "Admin user bootstrap complete"
SCRIPT
  } | wrap_script | root_exec "$BOOT_DEST" "$BOOT_MODE" "$BOOT_PASS" "bash -s"

  # Set the admin password. chpasswd reads user:password from stdin.
  printf '%s:%s\n' "$ADMIN_USER" "$NEW_PASS" | root_exec "$BOOT_DEST" "$BOOT_MODE" "$BOOT_PASS" "chpasswd"
  SUDO_PASS="$NEW_PASS"
  unset NEW_PASS BOOT_PASS

  can_ssh "$ADMIN_HOST" || die "Cannot SSH as ${ADMIN_HOST} after bootstrap — check authorized_keys"
  check_sudo "$ADMIN_HOST" "$SUDO_PASS" || die "Sudo check failed for ${ADMIN_HOST} after bootstrap"
  log_info "Verified SSH and sudo access as ${ADMIN_USER}"
fi

# From here on the bootstrap user is never used again. All privileged work goes
# through the admin user; everything else runs as sol.

log_info "Step 0b: Ensuring service user ${SOL_USER} exists without sudo"

{ emit_vars SOL_USER SSH_PUBKEY; cat <<'SCRIPT'
if ! id -u "$SOL_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$SOL_USER"
  echo "Created user $SOL_USER"
else
  echo "User $SOL_USER already exists"
fi

SOL_HOME=$(getent passwd "$SOL_USER" | cut -d: -f6)
install -d -m 700 -o "$SOL_USER" -g "$SOL_USER" "$SOL_HOME/.ssh"
touch "$SOL_HOME/.ssh/authorized_keys"
if ! grep -qF "$SSH_PUBKEY" "$SOL_HOME/.ssh/authorized_keys"; then
  echo "$SSH_PUBKEY" >> "$SOL_HOME/.ssh/authorized_keys"
  echo "Added SSH public key for $SOL_USER"
fi
chmod 600 "$SOL_HOME/.ssh/authorized_keys"
chown "$SOL_USER:$SOL_USER" "$SOL_HOME/.ssh/authorized_keys"

# The account that runs the validator must not be able to become root.
# Older versions of this script gave sol sudo and docker access — revoke both.
if [ -f "/etc/sudoers.d/$SOL_USER" ]; then
  rm -f "/etc/sudoers.d/$SOL_USER"
  echo "Removed legacy sudo access for $SOL_USER"
fi
for grp in sudo admin docker lxd; do
  if id -nG "$SOL_USER" | tr ' ' '\n' | grep -qx "$grp"; then
    gpasswd -d "$SOL_USER" "$grp" >/dev/null
    echo "Removed $SOL_USER from group $grp"
  fi
done
# sol logs in by SSH key only; it has no use for a password.
passwd -l "$SOL_USER" >/dev/null
echo "Service user $SOL_USER ready (no sudo, password locked)"
SCRIPT
} | root_script

if ! $DRY_RUN; then
  can_ssh "$SOL_HOST" || die "Cannot SSH as ${SOL_HOST} — check authorized_keys"
  log_info "Verified SSH access as ${SOL_USER}"
fi

# ---------------------------------------------------------------------------
# What does this host run today?
#
# On a new server the answer is "nothing" and the rest of this script is a plain
# install. On a host with a live validator this run is an upgrade or a client
# switch, and three things change: the unit of a validator that is running is
# not swapped out from under it, sol.service is not enabled next to a
# Firedancer that owns the identity, and --restart knows what it has to stop.
# ---------------------------------------------------------------------------
LIVE_AGAVE=false      # sol.service is running
LIVE_FD=false         # firedancer.service is running
FD_OWNS_HOST=false    # firedancer.service is running or enabled
HOST_CLIENT="none"    # hexis | jito | agave | none — the running process, else validator.sh
HOST_LABEL="nothing"
LIVE_EXE=""           # binary the running sol.service executes
if ! $DRY_RUN; then
  HOST_STATE=$(sol_script <<'SCRIPT'
echo "STATE|agave_active|$(systemctl is-active sol 2>/dev/null || true)"
echo "STATE|fd_active|$(systemctl is-active firedancer 2>/dev/null || true)"
echo "STATE|fd_enabled|$(systemctl is-enabled firedancer 2>/dev/null || true)"
PID=$(systemctl show -p MainPID --value sol 2>/dev/null || true)
EXE=""
FLAGS=""
if [ -n "$PID" ] && [ "$PID" != "0" ]; then
  EXE=$(readlink "/proc/$PID/exe" 2>/dev/null || true)
  FLAGS=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)
fi
# The client is read off the flags of the process that is running. validator.sh
# only says what the next start will be, and an earlier run of this script may
# already have rewritten it.
if [ -z "$FLAGS" ] && [ -f "$HOME/validator.sh" ]; then FLAGS=$(cat "$HOME/validator.sh"); fi
if [ -z "$FLAGS" ]; then echo "STATE|client|none"
elif grep -q -- '--arb-config' <<< "$FLAGS"; then echo "STATE|client|hexis"
elif grep -q -e '--block-engine-url' -e '--tip-payment-program-pubkey' <<< "$FLAGS"; then echo "STATE|client|jito"
else echo "STATE|client|agave"; fi
echo "STATE|exe|$EXE"
SCRIPT
  )
  host_state() { grep "^STATE|$1|" <<< "$HOST_STATE" | head -1 | cut -d'|' -f3; }
  [[ "$(host_state agave_active)" == "active" ]] && LIVE_AGAVE=true
  [[ "$(host_state fd_active)" == "active" ]] && LIVE_FD=true
  if $LIVE_FD || [[ "$(host_state fd_enabled)" == "enabled" ]]; then FD_OWNS_HOST=true; fi
  HOST_CLIENT=$(host_state client)
  [[ "$HOST_CLIENT" =~ ^(hexis|jito|agave|none)$ ]] || die "Could not read what ${SOL_HOST} runs today"
  LIVE_EXE=$(host_state exe)
  # A binary that was replaced on disk reads back as "<path> (deleted)"
  [[ "$LIVE_EXE" =~ ^/[A-Za-z0-9._/+-]+$ ]] || LIVE_EXE=""

  case "$HOST_CLIENT" in
    hexis) HOST_LABEL="Jito with the Hexis arb client" ;;
    jito)  HOST_LABEL="Jito" ;;
    agave) HOST_LABEL="Agave" ;;
    *)     HOST_LABEL="nothing" ;;
  esac
  if $FD_OWNS_HOST; then
    log_info "This host runs Firedancer today (firedancer.service $(host_state fd_active)/$(host_state fd_enabled))"
  elif $LIVE_AGAVE; then
    log_info "This host runs ${HOST_LABEL} today (sol.service is active) — it keeps running until it is restarted"
  elif [[ "$HOST_CLIENT" != "none" ]]; then
    log_info "This host is set up for ${HOST_LABEL}, and no validator is running"
  else
    log_info "No validator on this host yet — installing from scratch"
  fi
fi

# A host that runs a validator and asked for Firedancer: the validator.sh and
# unit there belong to the process that is running, and reawaken.sh stages
# Firedancer from them as they are. Rewriting them for a client that is not
# installed would break the next unplanned restart.
KEEP_RUNNING_SETUP=false
if $IS_FIREDANCER && $LIVE_AGAVE; then KEEP_RUNNING_SETUP=true; fi
# Firedancer holds the identity: an Agave client installed next to it must not
# be enabled, or both would start at the next boot.
HOLD_SOL=false
if $FD_OWNS_HOST && ! $IS_FIREDANCER; then HOLD_SOL=true; fi

# ---------------------------------------------------------------------------
# Jito region detection & interactive prompts
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

# Coordinates of each Jito region, as "lat lon"
region_coords() {
  case "$1" in
    amsterdam)      echo "52.3676 4.9041" ;;
    dublin)         echo "53.3498 -6.2603" ;;
    frankfurt)      echo "50.1109 8.6821" ;;
    london)         echo "51.5074 -0.1278" ;;
    new-york)       echo "40.7128 -74.0060" ;;
    salt-lake-city) echo "40.7608 -111.8910" ;;
    singapore)      echo "1.3521 103.8198" ;;
    tokyo)          echo "35.6762 139.6503" ;;
    dallas)         echo "32.7767 -96.7970" ;;
    *)              return 1 ;;
  esac
}

# nearest <lat> <lon> — reads "name lat lon" lines on stdin, prints the closest name.
# Approximate distance (squared Euclidean on lat/lon, adjusted for longitude) is
# good enough for region selection. Coordinates are passed as awk variables and
# are never part of the awk program text.
nearest() {
  awk -v slat="$1" -v slon="$2" '
    NF == 3 {
      dlat = slat - $2
      dlon = (slon - $3) * 0.7
      d = dlat * dlat + dlon * dlon
      if (best == "" || d < bestd) { bestd = d; best = $1 }
    }
    END { if (best != "") print best; else exit 1 }'
}

json_field() {
  printf '%s' "$1" | tr -d '\n' | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

detect_server_location() {
  # Geolocate the server — sets SERVER_LAT, SERVER_LON.
  # The response comes from the server, so it is treated as untrusted input:
  # coordinates must be plain numbers and display strings are stripped down.
  log_info "Detecting server location from IP geolocation..."

  local geo city country loc
  geo=$(ssh "${SSH_OPTS[@]}" "$SOL_HOST" "curl -fsS --max-time 10 https://ipinfo.io/json" </dev/null 2>/dev/null || true)
  if [[ -z "$geo" ]]; then
    log_warn "Could not determine server location"
    return 1
  fi

  city=$(json_field "$geo" city | tr -cd 'A-Za-z0-9 .,_-')
  country=$(json_field "$geo" country | tr -cd 'A-Za-z0-9 .,_-')
  loc=$(json_field "$geo" loc)
  log_info "Server location: ${city:-unknown}, ${country:-unknown}"

  local lat="${loc%%,*}" lon="${loc##*,}"
  if [[ ! "$lat" =~ $RE_COORD || ! "$lon" =~ $RE_COORD ]]; then
    log_warn "Geolocation response did not contain usable coordinates"
    return 1
  fi
  SERVER_LAT="$lat"
  SERVER_LON="$lon"
}

detect_jito_region() {
  local name coords
  get_regions_for_network | cut -d'|' -f1 | while read -r name; do
    if coords=$(region_coords "$name"); then
      echo "$name $coords"
    fi
  done | nearest "$SERVER_LAT" "$SERVER_LON"
}

# --- Geolocate server (used to pick the Jito region) ---
SERVER_LAT=""
SERVER_LON=""
if $USES_JITO && ! $DRY_RUN; then
  detect_server_location || true
fi

# --- Resolve Jito region ---
if [[ -n "$JITO_REGION" ]]; then
  if ! lookup_region "$JITO_REGION" >/dev/null; then
    log_error "Unknown Jito region: $JITO_REGION"
    log_error "Available regions for $NETWORK:"
    get_regions_for_network | cut -d'|' -f1 | sed 's/^/  /' >&2
    exit 1
  fi
  log_info "Using Jito region: $JITO_REGION"
elif [[ -n "$SERVER_LAT" ]]; then
  JITO_REGION=$(detect_jito_region) || JITO_REGION=""
  if [[ -n "$JITO_REGION" ]]; then
    log_info "Auto-selected Jito region: $JITO_REGION"
  fi
fi
if $USES_JITO && [[ -z "$JITO_REGION" ]]; then
  log_warn "No Jito region selected — pass --jito-region, or fill in the block engine and shred receiver values in validator.sh before starting"
fi

# Parse the selected region's config
JITO_BLOCK_ENGINE=""
JITO_SHRED_RECEIVER=""
JITO_NTP_SERVER=""
if [[ -n "$JITO_REGION" ]]; then
  REGION_CONFIG=$(lookup_region "$JITO_REGION")
  JITO_BLOCK_ENGINE=$(echo "$REGION_CONFIG" | cut -d'|' -f2)
  JITO_SHRED_RECEIVER=$(echo "$REGION_CONFIG" | cut -d'|' -f3)
  JITO_NTP_SERVER=$(echo "$REGION_CONFIG" | cut -d'|' -f4)
  log_info "Block engine:     $JITO_BLOCK_ENGINE"
  log_info "Shred receiver:   $JITO_SHRED_RECEIVER"
  log_info "NTP server:       $JITO_NTP_SERVER"
fi

# --- Prompt for commission if not provided (mainnet) ---
if $USES_JITO && [[ "$NETWORK" == "mainnet" && -z "$COMMISSION_BPS" ]] && ! $DRY_RUN; then
  echo ""
  read -rp "Jito commission in basis points (cut of Jito MEV tips; e.g., 0 = 0%, 500 = 5%, 1000 = 10%) [0]: " COMMISSION_BPS
  COMMISSION_BPS="${COMMISSION_BPS:-0}"
  validate_commission "$COMMISSION_BPS" || die "Commission must be an integer from 0 to 10000"
  log_info "Jito commission: ${COMMISSION_BPS} bps"
fi

# ---------------------------------------------------------------------------
# Step 1: System update & base packages
# ---------------------------------------------------------------------------
log_info "Step 1: Updating system and installing base packages"

root_script <<'SCRIPT'
export DEBIAN_FRONTEND=noninteractive

# Package upgrades must never restart a running validator. needrestart (default
# on Ubuntu 24.04) restarts services whose libraries changed; exclude sol.service.
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/90-arise-sol.conf <<'NREOF'
# Managed by arise.sh — never auto-restart the validator after a package upgrade
$nrconf{override_rc}{qr(^sol\.service$)} = 0;
NREOF

apt-get update -y
apt-get upgrade -y
apt-get install -y \
  curl \
  wget \
  git \
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
  libclang-dev
SCRIPT

# ---------------------------------------------------------------------------
# Step 2: System tuning (Anza recommended)
# ---------------------------------------------------------------------------
log_info "Step 2: Applying system tuning parameters"

{ emit_vars DISABLE_CPU_MITIGATIONS DISABLE_AUTO_UPDATES; cat <<'SCRIPT'
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
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/60-nvme-scheduler.rules <<'UDEV'
ACTION=="add|change", KERNEL=="nvme*", ATTR{queue/scheduler}="none"
UDEV
udevadm control --reload-rules 2>/dev/null || true

# --- CPU performance governor ---
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null || true
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

# --- CPU security mitigations ---
# Spectre/Meltdown mitigations cost some CPU, but turning them off weakens the
# kernel's isolation. They stay ON unless --disable-cpu-mitigations is passed.
GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ]; then
  if [ "$DISABLE_CPU_MITIGATIONS" = true ]; then
    if ! grep -q "mitigations=off" "$GRUB_FILE"; then
      sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 mitigations=off"/' "$GRUB_FILE"
      update-grub
      echo "CPU mitigations=off added to GRUB (takes effect on next reboot)"
    else
      echo "CPU mitigations=off already set"
    fi
  elif grep -q "mitigations=off" "$GRUB_FILE"; then
    echo "ARISE-WARN: mitigations=off is set in $GRUB_FILE from an earlier run. CPU security mitigations are disabled. Remove it and run update-grub to turn them back on."
  fi
fi

# --- Automatic security updates ---
# Kept ON by default. sol.service is excluded from automatic restarts in step 1,
# and unattended-upgrades does not reboot on its own.
if [ "$DISABLE_AUTO_UPDATES" = true ]; then
  for svc in unattended-upgrades apt-daily.timer apt-daily-upgrade.timer; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
      systemctl disable --now "$svc"
      echo "Disabled $svc"
    fi
  done
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
  systemctl enable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
  echo "Automatic security updates enabled"
fi

# --- Disable unnecessary services ---
for svc in snapd snapd.socket snapd.seeded; do
  if systemctl is-enabled "$svc" >/dev/null 2>&1; then
    systemctl disable --now "$svc" 2>/dev/null || true
    echo "Disabled $svc"
  fi
done

# --- IRQ affinity for NIC ---
# Spread network interrupts across all cores instead of hammering core 0
if ! command -v irqbalance >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y irqbalance
fi
systemctl enable --now irqbalance 2>/dev/null || true
echo "irqbalance enabled"

echo "System tuning applied"
SCRIPT
} | root_script

# ---------------------------------------------------------------------------
# Step 3: Configure NTP with Jito servers
# ---------------------------------------------------------------------------
log_info "Step 3: Configuring NTP (chrony)"

NTP_SERVER="${JITO_NTP_SERVER:-pool.ntp.org}"
{ emit_vars NTP_SERVER; cat <<'SCRIPT'
if ! command -v chronyd >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y chrony
fi

# Disable other NTP services that conflict
for svc in ntp ntpd systemd-timesyncd; do
  if systemctl is-active "$svc" >/dev/null 2>&1; then
    systemctl disable --now "$svc" 2>/dev/null || true
  fi
done

# Drop Jito NTP config into conf.d (included by main chrony.conf via confdir)
# This adds the Jito server as preferred without touching the existing config
mkdir -p /etc/chrony/conf.d
cat > /etc/chrony/conf.d/jito-ntp.conf <<EOF
# Jito NTP server (same datacenter, sub-ms accuracy)
server ${NTP_SERVER} iburst prefer
EOF

systemctl enable chrony
systemctl restart chrony

chronyc tracking || true
echo "NTP configured with ${NTP_SERVER}"
SCRIPT
} | root_script

# ---------------------------------------------------------------------------
# Step 4: Disk discovery & setup with fstab persistence
# ---------------------------------------------------------------------------
log_info "Step 4: Setting up disks"

HAVE_LEDGER_MOUNT=false
HAVE_ACCOUNTS_MOUNT=false
LEDGER_ACCOUNTS_DIR=false
LEGACY_ROOT_ACCOUNTS=false

# Read the current layout so reruns keep using what a previous run set up
if ! $DRY_RUN; then
  DISK_STATE=$(sol_script <<'SCRIPT'
if mountpoint -q /mnt/ledger; then echo LEDGER_MOUNTED; fi
if mountpoint -q /mnt/accounts; then echo ACCOUNTS_MOUNTED; fi
if [ -d /mnt/ledger/accounts ]; then echo LEDGER_ACCOUNTS_DIR; fi
if [ -d /mnt/accounts ] && ! mountpoint -q /mnt/accounts && [ -n "$(ls -A /mnt/accounts 2>/dev/null)" ]; then
  echo LEGACY_ROOT_ACCOUNTS
fi
echo PROBE_DONE
SCRIPT
  )
  grep -qx PROBE_DONE <<< "$DISK_STATE" || die "Could not read disk layout from server"
  if grep -qx LEDGER_MOUNTED <<< "$DISK_STATE"; then HAVE_LEDGER_MOUNT=true; fi
  if grep -qx ACCOUNTS_MOUNTED <<< "$DISK_STATE"; then HAVE_ACCOUNTS_MOUNT=true; fi
  if grep -qx LEDGER_ACCOUNTS_DIR <<< "$DISK_STATE"; then LEDGER_ACCOUNTS_DIR=true; fi
  if grep -qx LEGACY_ROOT_ACCOUNTS <<< "$DISK_STATE"; then LEGACY_ROOT_ACCOUNTS=true; fi
fi

USE_MNT=false
if [[ -n "$LEDGER_DISK" || -n "$ACCOUNTS_DISK" ]]; then
  USE_MNT=true
elif $HAVE_LEDGER_MOUNT || $HAVE_ACCOUNTS_MOUNT; then
  USE_MNT=true
  log_info "Disks already mounted from a previous run — skipping discovery"
elif $AUTO_DISKS && $DRY_RUN; then
  USE_MNT=true
  log_info "[DRY RUN] would auto-discover blank NVMe drives; assuming /mnt/ledger and /mnt/accounts"
  ACCOUNTS_DISK="<auto-discovered>"
elif $AUTO_DISKS; then
  log_info "Auto-discovering unused NVMe drives on server..."

  # A drive only counts as unused if it is blank in every way we can check:
  # not the root disk, no partitions, not part of RAID/LVM, not mounted, not
  # swap, and no filesystem, RAID or partition-table signature of any kind.
  DISCOVERED_DISKS=$(root_script <<'SCRIPT'
ROOT_SRC=$(findmnt -n -o SOURCE / || true)
ROOT_DISK=""
if [ -n "$ROOT_SRC" ]; then
  ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)
fi

for dev in /dev/nvme*n1; do
  [ -b "$dev" ] || continue
  devname=$(basename "$dev")

  if [ "$devname" = "$ROOT_DISK" ]; then continue; fi
  # Partitions or any other child device (LVM, RAID, crypt)
  if [ "$(lsblk -n -o NAME "$dev" | wc -l)" -gt 1 ]; then continue; fi
  if [ -n "$(ls -A "/sys/class/block/$devname/holders" 2>/dev/null)" ]; then continue; fi
  if findmnt -n -S "$dev" >/dev/null 2>&1; then continue; fi
  if grep -q "^$dev " /proc/swaps; then continue; fi
  # Any on-disk signature at all means the drive is not blank
  if [ -n "$(wipefs -n "$dev" 2>/dev/null)" ]; then continue; fi
  if [ -n "$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)" ]; then continue; fi

  size_bytes=$(blockdev --getsize64 "$dev")
  echo "DISK|$dev|$size_bytes"
done
echo "DISCOVERY_DONE"
SCRIPT
  )
  grep -qx DISCOVERY_DONE <<< "$DISCOVERED_DISKS" || die "Disk discovery did not complete"

  # Largest first
  SORTED_DISKS=$(grep '^DISK|' <<< "$DISCOVERED_DISKS" | sort -t'|' -k3,3nr || true)
  DISK_COUNT=0
  while IFS='|' read -r _tag dev size_bytes; do
    [[ -z "$dev" ]] && continue
    [[ "$dev" =~ $RE_DEVICE && "$size_bytes" =~ ^[0-9]+$ ]] || die "Unexpected disk discovery output: $dev"
    DISK_COUNT=$((DISK_COUNT + 1))
    log_info "  $dev  size=$((size_bytes / 1073741824))GB"
    if [[ $DISK_COUNT -eq 1 ]]; then LEDGER_DISK="$dev"; fi
    if [[ $DISK_COUNT -eq 2 ]]; then ACCOUNTS_DISK="$dev"; fi
  done <<< "$SORTED_DISKS"

  if [[ $DISK_COUNT -ge 2 ]]; then
    USE_MNT=true
    log_info "Auto-assigned: ledger=$LEDGER_DISK  accounts=$ACCOUNTS_DISK"
  elif [[ $DISK_COUNT -eq 1 ]]; then
    USE_MNT=true
    log_warn "Only 1 unused drive found ($LEDGER_DISK) — will use it for both ledger and accounts"
  else
    log_warn "No unused NVMe drives found on server"
    log_warn "Falling back to ${SOL_HOME}/ directories"
  fi
fi

# --- Resolve paths ---
if $USE_MNT; then
  LEDGER_PATH="/mnt/ledger"
  SNAPSHOTS_PATH="/mnt/ledger/snapshots"
  if [[ -n "$ACCOUNTS_DISK" ]] || $HAVE_ACCOUNTS_MOUNT; then
    ACCOUNTS_PATH="/mnt/accounts"
  elif $LEGACY_ROOT_ACCOUNTS && ! $LEDGER_ACCOUNTS_DIR; then
    # An older version of this script put accounts on the root disk in
    # single-disk mode. Keep using it rather than silently moving live data.
    ACCOUNTS_PATH="/mnt/accounts"
    log_warn "/mnt/accounts holds data but is on the ROOT disk (legacy single-disk layout)."
    log_warn "Keeping it. To move accounts onto the ledger disk: stop the validator,"
    log_warn "move /mnt/accounts to /mnt/ledger/accounts, and rerun this script."
  else
    ACCOUNTS_PATH="/mnt/ledger/accounts"
  fi
else
  LEDGER_PATH="${SOL_HOME}/ledger"
  ACCOUNTS_PATH="${SOL_HOME}/accounts"
  SNAPSHOTS_PATH="${SOL_HOME}/snapshots"
fi
if [[ "$ACCOUNTS_DISK" == "<auto-discovered>" ]]; then ACCOUNTS_DISK=""; fi

# --- Inspect, confirm, then format and mount ---
FORMAT_OK=""
if [[ -n "$LEDGER_DISK" || -n "$ACCOUNTS_DISK" ]]; then
  if ! $DRY_RUN; then
    DISK_PLAN=$({ emit_vars LEDGER_DISK ACCOUNTS_DISK; cat <<'SCRIPT'
inspect() {
  local dev="$1" mp="$2" devname fs
  if [ -z "$dev" ]; then return 0; fi
  if mountpoint -q "$mp"; then echo "OK|$dev|$mp is already mounted, nothing to do"; return 0; fi
  if [ ! -b "$dev" ]; then echo "UNSAFE|$dev|not a block device"; return 0; fi
  devname=$(basename "$dev")
  if [ "$(lsblk -n -o NAME "$dev" | wc -l)" -gt 1 ]; then echo "UNSAFE|$dev|has partitions or child devices"; return 0; fi
  if [ -n "$(ls -A "/sys/class/block/$devname/holders" 2>/dev/null)" ]; then echo "UNSAFE|$dev|in use by RAID/LVM/device-mapper"; return 0; fi
  if findmnt -n -S "$dev" >/dev/null 2>&1; then echo "UNSAFE|$dev|currently mounted somewhere else"; return 0; fi
  if grep -q "^$dev " /proc/swaps; then echo "UNSAFE|$dev|in use as swap"; return 0; fi
  fs=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
  if [ "$fs" = "ext4" ]; then
    echo "OK|$dev|existing ext4 filesystem will be mounted at $mp without formatting"
  else
    echo "FORMAT|$dev|${fs:-blank}"
  fi
}
inspect "$LEDGER_DISK" /mnt/ledger
inspect "$ACCOUNTS_DISK" /mnt/accounts
echo "LSBLK|"
for dev in "$LEDGER_DISK" "$ACCOUNTS_DISK"; do
  if [ -n "$dev" ] && [ -b "$dev" ]; then
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$dev" | sed 's/^/LSBLK|/'
  fi
done
echo "PLAN_DONE"
SCRIPT
    } | root_script)
    grep -qx PLAN_DONE <<< "$DISK_PLAN" || die "Disk inspection did not complete"

    if grep -q '^UNSAFE|' <<< "$DISK_PLAN"; then
      while IFS='|' read -r _tag dev reason; do
        log_error "Refusing to touch $dev: $reason"
      done < <(grep '^UNSAFE|' <<< "$DISK_PLAN")
      die "Wipe the device yourself (wipefs -a) if it really is safe to use, or pick another disk."
    fi

    while IFS='|' read -r _tag dev note; do
      log_info "$dev: $note"
    done < <(grep '^OK|' <<< "$DISK_PLAN" || true)

    if grep -q '^FORMAT|' <<< "$DISK_PLAN"; then
      echo ""
      echo "=========================================="
      echo "  These devices will be ERASED and formatted as ext4"
      echo "=========================================="
      while IFS='|' read -r _tag dev current; do
        [[ "$dev" =~ $RE_DEVICE ]] || die "Unexpected disk plan output: $dev"
        echo "  $dev   (current contents: $current)"
        FORMAT_OK="${FORMAT_OK}${FORMAT_OK:+ }${dev}"
      done < <(grep '^FORMAT|' <<< "$DISK_PLAN")
      echo ""
      grep '^LSBLK|' <<< "$DISK_PLAN" | cut -d'|' -f2-
      echo ""
      if $CONFIRM_FORMAT; then
        log_warn "--confirm-format given — formatting without prompting"
      else
        read -rp "Type 'format' to erase these devices on ${SSH_HOST}: " answer
        [[ "$answer" == "format" ]] || die "Aborted — no disks were changed"
      fi
    fi
  fi

  { emit_vars LEDGER_DISK ACCOUNTS_DISK FORMAT_OK; cat <<'SCRIPT'
setup_disk() {
  local device="$1" mountpoint="$2" label="$3" current_fs uuid approved=false d

  if [ -z "$device" ]; then return 0; fi

  if mountpoint -q "$mountpoint"; then
    echo "$mountpoint is already mounted"
    return 0
  fi

  # Format only if not already ext4, and only devices the operator approved
  current_fs=$(blkid -o value -s TYPE "$device" 2>/dev/null || true)
  if [ "$current_fs" != "ext4" ]; then
    for d in $FORMAT_OK; do
      if [ "$d" = "$device" ]; then approved=true; fi
    done
    if [ "$approved" != true ]; then
      echo "ERROR: $device needs formatting but was not approved" >&2
      exit 1
    fi
    echo "Formatting $device as ext4 with label $label"
    mkfs.ext4 -F -L "$label" "$device"
  else
    echo "$device is already ext4, skipping format"
  fi

  mkdir -p "$mountpoint"

  # Add to fstab if not already there (use UUID for reliability)
  uuid=$(blkid -o value -s UUID "$device")
  if [ -z "$uuid" ]; then
    echo "ERROR: could not read UUID of $device" >&2
    exit 1
  fi
  if ! grep -q "$uuid" /etc/fstab; then
    echo "UUID=$uuid $mountpoint ext4 defaults,noatime,nodiratime,discard 0 2" >> /etc/fstab
    systemctl daemon-reload
    echo "Added $mountpoint to fstab (UUID=$uuid)"
  else
    echo "$mountpoint already in fstab"
  fi

  mount "$mountpoint"
  mountpoint -q "$mountpoint"
  echo "$mountpoint ready on $device"
}

setup_disk "$LEDGER_DISK" /mnt/ledger solana-ledger
setup_disk "$ACCOUNTS_DISK" /mnt/accounts solana-accounts
echo "Disk setup complete"
SCRIPT
  } | root_script
fi

# --- Directories and ownership (all layouts) ---
# ext4 root inodes default to root:root, so ownership is always re-applied.
{ emit_vars SOL_USER SOL_HOME LEDGER_PATH ACCOUNTS_PATH SNAPSHOTS_PATH; cat <<'SCRIPT'
for dir in "$LEDGER_PATH" "$ACCOUNTS_PATH" "$SNAPSHOTS_PATH" "$SOL_HOME/logs"; do
  mkdir -p "$dir"
  chown "$SOL_USER:$SOL_USER" "$dir"
done
echo "Directories ready: ledger=$LEDGER_PATH accounts=$ACCOUNTS_PATH snapshots=$SNAPSHOTS_PATH"
SCRIPT
} | root_script

# ---------------------------------------------------------------------------
# Step 5: Swap setup
# ---------------------------------------------------------------------------
log_info "Step 5: Setting up swap (${SWAP_SIZE})"

{ emit_vars SWAP_SIZE; cat <<'SCRIPT'
SWAPFILE="/swapfile"
if [ ! -f "$SWAPFILE" ]; then
  fallocate -l "$SWAP_SIZE" "$SWAPFILE"
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
  echo "Swap file created and enabled"
else
  echo "Swap file already exists"
  if ! grep -q "^$SWAPFILE " /proc/swaps; then
    swapon "$SWAPFILE"
  fi
fi
if ! grep -q "^$SWAPFILE " /etc/fstab; then
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi
swapon --show
SCRIPT
} | root_script

# ---------------------------------------------------------------------------
# Step 6: Set up sol user profile and Rust
# ---------------------------------------------------------------------------
log_info "Step 6: Setting up sol user profile"
$BUILD_FROM_SOURCE || log_info "Nothing is built from source — skipping the Rust toolchain"

{ emit_vars BUILD_FROM_SOURCE; cat <<'SCRIPT'
touch ~/.profile ~/.bashrc

# Solana binaries on PATH for interactive and login shells
SOLANA_BIN='PATH="$HOME/.local/share/solana/install/releases/active_release/bin:$PATH"'
if ! grep -q "releases/active_release/bin" ~/.bashrc; then
  echo "$SOLANA_BIN" >> ~/.bashrc
fi
if ! grep -q "releases/active_release/bin" ~/.profile; then
  echo "export $SOLANA_BIN" >> ~/.profile
fi

if [ "$BUILD_FROM_SOURCE" != true ]; then
  echo "Profile ready"
  return 0
fi

# Ensure LIBCLANG_PATH is in profile
if ! grep -q "LIBCLANG_PATH" ~/.profile; then
  echo 'export LIBCLANG_PATH=/usr/lib/llvm-18/lib' >> ~/.profile
fi

# Install Rust if not present
if [ -x "$HOME/.cargo/bin/rustup" ]; then
  echo "Rust already installed"
else
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  echo "Rust installed"
fi

# Ensure cargo env is sourced in profile
if ! grep -q '.cargo/env' ~/.profile; then
  echo '. "$HOME/.cargo/env"' >> ~/.profile
fi

# Source cargo for this session and install/update components
set +u
. "$HOME/.cargo/env"
set -u
rustup component add rustfmt
rustup update
echo "Rust and rustfmt ready: $(rustc --version)"
SCRIPT
} | sol_script

# ---------------------------------------------------------------------------
# Step 6b: Install the validator
#   jito / agave are built on the server from their public repos, at a release
#   tag. --hexis ships its own agave-validator build, so the source build is
#   skipped and only the prebuilt Solana CLI (solana-keygen, solana, ...) goes
#   on the box; --build-client forces the source build anyway.
# ---------------------------------------------------------------------------
if [[ "$CLIENT" == "jito" ]]; then
  CLIENT_SRC="jito-solana"
  CLIENT_TAG_FILTER='-jito$'
else
  CLIENT_SRC="agave"
  CLIENT_TAG_FILTER='^v[0-9]+\.[0-9]+\.[0-9]+$'
fi
if $BUILD_FROM_SOURCE; then
  log_info "Step 6b: ${CLIENT} validator build"
elif $IS_FIREDANCER; then
  log_info "Step 6b: Firedancer ships as a binary — nothing is built from source"
else
  log_info "Step 6b: --hexis supplies the validator binary — skipping the source build"
fi

select_client_version() {
  # Lists recent release tags from the public repo and sets CLIENT_VERSION
  command -v git >/dev/null 2>&1 || die "git is not installed locally — pass --client-version <tag>"
  log_info "Fetching release tags from ${CLIENT_REPO}..."

  local tags
  tags=$(git ls-remote --tags --refs "$CLIENT_REPO" 'v*' | sed 's|.*refs/tags/||' | grep -E "$CLIENT_TAG_FILTER" | sort -V | tail -12) || true
  [[ -n "$tags" ]] || die "Could not list release tags — pass --client-version <tag>"

  echo ""
  echo "=========================================="
  echo "  Select ${CLIENT} release to build"
  echo "  (check Jito/Anza announcements for the"
  echo "   version recommended for ${NETWORK})"
  echo "=========================================="
  local i=1 tag choice
  local tag_list=()
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    printf "  %d) %s\n" "$i" "$tag"
    tag_list+=("$tag")
    i=$((i + 1))
  done <<< "$tags"
  echo ""

  while true; do
    read -rp "Select release: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
      CLIENT_VERSION="${tag_list[$((choice - 1))]}"
      break
    fi
    echo "Invalid selection. Enter a number between 1 and $((i - 1))."
  done
  [[ "$CLIENT_VERSION" =~ $RE_REF ]] || die "Unexpected tag name: $CLIENT_VERSION"
}

NEED_BUILD=$BUILD_FROM_SOURCE
if ! $BUILD_FROM_SOURCE; then
  :
elif $DRY_RUN; then
  CLIENT_VERSION="${CLIENT_VERSION:-<CLIENT_VERSION>}"
else
  # What is installed now? Prints the recorded tag and the repo it was built
  # from, LEGACY (built by an older version of this script, which only built
  # Jito; tag unknown), or NONE. The prebuilt Solana CLI that a --hexis or
  # Firedancer host carries counts as NONE: it is Anza's stock release and was
  # never the validator this host ran.
  INSTALLED_BUILD=$(sol_script <<'SCRIPT'
INSTALL_ROOT="$HOME/.local/share/solana/install"
ACTIVE="$INSTALL_ROOT/releases/active_release"
if [ -L "$ACTIVE" ] && [ "$(readlink "$ACTIVE")" = "$INSTALL_ROOT/active_release" ]; then
  echo "BUILD|NONE|"
elif [ -x "$ACTIVE/bin/agave-validator" ]; then
  if [ -f "$ACTIVE/.arise-build" ]; then
    echo "BUILD|$(cut -d' ' -f1 "$ACTIVE/.arise-build")|$(cut -d' ' -f3 "$ACTIVE/.arise-build")"
  else
    echo "BUILD|LEGACY|"
  fi
else
  echo "BUILD|NONE|"
fi
SCRIPT
  )
  INSTALLED_REPO=$(grep '^BUILD|' <<< "$INSTALLED_BUILD" | head -1 | cut -d'|' -f3)
  INSTALLED_BUILD=$(grep '^BUILD|' <<< "$INSTALLED_BUILD" | head -1 | cut -d'|' -f2)
  [[ -n "$INSTALLED_BUILD" ]] || die "Could not determine the installed validator build"

  # Is what is installed the client that was asked for?
  OTHER_CLIENT=false
  if [[ "$INSTALLED_BUILD" == "LEGACY" ]]; then
    [[ "$CLIENT" == "jito" ]] || OTHER_CLIENT=true
  elif [[ "$INSTALLED_BUILD" != "NONE" && "$INSTALLED_REPO" != "$CLIENT_REPO" ]]; then
    OTHER_CLIENT=true
  fi

  if [[ "$INSTALLED_BUILD" == "NONE" ]]; then
    if [[ -z "$CLIENT_VERSION" ]]; then select_client_version; fi
  elif $OTHER_CLIENT; then
    log_warn "Installed build is ${INSTALLED_BUILD} from ${INSTALLED_REPO:-an older version of this script}, not ${CLIENT} from ${CLIENT_REPO} — building that beside it."
    if [[ -z "$CLIENT_VERSION" ]]; then select_client_version; fi
    log_warn "A running validator keeps its current binary until it is restarted."
  elif [[ -z "$CLIENT_VERSION" ]]; then
    NEED_BUILD=false
    log_info "Validator already installed (${INSTALLED_BUILD}) — skipping build. Pass --client-version to change it."
  elif [[ "$INSTALLED_BUILD" == "$CLIENT_VERSION" ]]; then
    NEED_BUILD=false
    log_info "Validator ${CLIENT_VERSION} already installed — skipping build"
  else
    log_warn "Installed build is ${INSTALLED_BUILD}; building ${CLIENT_VERSION} and switching active_release to it."
    log_warn "A running validator keeps its current binary until it is restarted."
  fi
fi

if $NEED_BUILD; then
  log_info "Building ${CLIENT_VERSION} from ${CLIENT_REPO}"

  { emit_vars CLIENT_REPO CLIENT_VERSION CLIENT_SRC; cat <<'SCRIPT'
set +u
. "$HOME/.cargo/env"
set -u
export LIBCLANG_PATH=/usr/lib/llvm-18/lib

RELEASES="$HOME/.local/share/solana/install/releases"
TARGET="$RELEASES/$CLIENT_VERSION"
ACTIVE="$RELEASES/active_release"
SRC="$HOME/$CLIENT_SRC"

if [ ! -d "$SRC/.git" ]; then
  git clone "$CLIENT_REPO" "$SRC"
else
  git -C "$SRC" remote set-url origin "$CLIENT_REPO"
fi
cd "$SRC"
git fetch --tags --force origin

# Resolve to an exact commit: a release tag first, then a branch, then a raw commit
if REV=$(git rev-parse -q --verify "refs/tags/$CLIENT_VERSION^{commit}"); then
  echo "Using tag $CLIENT_VERSION"
elif REV=$(git rev-parse -q --verify "refs/remotes/origin/$CLIENT_VERSION^{commit}"); then
  echo "Using branch origin/$CLIENT_VERSION"
elif REV=$(git rev-parse -q --verify "$CLIENT_VERSION^{commit}"); then
  echo "Using commit $CLIENT_VERSION"
else
  echo "ERROR: $CLIENT_VERSION is not a tag, branch or commit in $CLIENT_REPO" >&2
  exit 1
fi

git checkout --detach "$REV"
git submodule update --init --recursive
echo "Building commit $REV ($CLIENT_VERSION)"

mkdir -p "$RELEASES"
scripts/cargo-install-all.sh --validator-only "$TARGET"
test -x "$TARGET/bin/agave-validator"
printf '%s %s %s\n' "$CLIENT_VERSION" "$REV" "$CLIENT_REPO" > "$TARGET/.arise-build"

# Switch active_release. Older versions of this script built straight into a
# real active_release directory; keep that build aside rather than deleting it.
if [ -e "$ACTIVE" ] && [ ! -L "$ACTIVE" ]; then
  mv "$ACTIVE" "$RELEASES/pre-arise-$(date +%Y%m%d%H%M%S)"
fi
ln -sfn "$TARGET" "$ACTIVE"

echo "ARISE-BUILT: $CLIENT_VERSION commit $REV"
SCRIPT
  } | sol_script
fi

# Prebuilt Solana CLI — solana-keygen for the identity and arb keypairs, solana
# for catchup/monitoring. Only when nothing is being built from source.
if ! $BUILD_FROM_SOURCE; then
  log_info "Step 6b: Installing the prebuilt Solana CLI"

  sol_script <<'SCRIPT'
INSTALL_ROOT="$HOME/.local/share/solana/install"

if [ -x "$INSTALL_ROOT/active_release/bin/solana-keygen" ] || \
   [ -x "$INSTALL_ROOT/releases/active_release/bin/solana-keygen" ]; then
  echo "Solana CLI already installed"
else
  INSTALLER=$(mktemp)
  curl --proto '=https' --tlsv1.2 -sSfL https://release.anza.xyz/stable/install -o "$INSTALLER"
  sh "$INSTALLER"
  rm -f "$INSTALLER"
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

# ---------------------------------------------------------------------------
# Step 7: Copy identity keypair to server
# ---------------------------------------------------------------------------
log_info "Step 7: Copying identity keypair to server"

if $DRY_RUN; then
  echo "[DRY RUN] copy $IDENTITY_FILE -> $SOL_HOST:${SOL_HOME}/staked_identity.json (mode 600, checksum verified)"
else
  LOCAL_SUM=$(sha256_local "$IDENTITY_FILE")
  if remote "test -f ${SOL_HOME}/staked_identity.json"; then
    log_info "staked_identity.json already exists on server — not overwriting"
  else
    # Streamed over SSH and created mode 600 — never readable by anyone else
    sol_write_file "${SOL_HOME}/staked_identity.json" 600 < "$IDENTITY_FILE"
  fi
  REMOTE_SUM=$(remote "chmod 600 ${SOL_HOME}/staked_identity.json && sha256sum ${SOL_HOME}/staked_identity.json | cut -d' ' -f1")
  if [[ "$LOCAL_SUM" != "$REMOTE_SUM" ]]; then
    die "staked_identity.json on the server does not match $IDENTITY_FILE. Remove the server copy if it is wrong, then rerun."
  fi
  log_info "staked_identity.json on server matches local keypair"
fi

# Generate unstaked identity and symlink identity.json -> unstaked
log_info "Step 7b: Setting up unstaked identity and identity.json symlink"

sol_script <<'SCRIPT'
export PATH="$HOME/.local/share/solana/install/releases/active_release/bin:$PATH"
umask 077

if [ -f ~/unstaked_identity.json ]; then
  echo "unstaked_identity.json already exists"
else
  solana-keygen new --outfile ~/unstaked_identity.json --no-passphrase --silent
  echo "Generated unstaked_identity.json"
fi
chmod 600 ~/unstaked_identity.json

# Validator starts with the unstaked identity; switch to staked manually.
# Never repoint an existing link — it may already point at the staked identity.
if [ -e ~/identity.json ] || [ -L ~/identity.json ]; then
  echo "identity.json already exists -> $(readlink ~/identity.json || echo 'regular file') (left unchanged)"
else
  ln -s unstaked_identity.json ~/identity.json
  echo "identity.json -> unstaked_identity.json"
fi
SCRIPT

# ---------------------------------------------------------------------------
# Step 7c: Create mostly_confirmed_threshold
# ---------------------------------------------------------------------------
log_info "Step 7c: Creating mostly_confirmed_threshold"

sol_script <<'SCRIPT'
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
    XDP_INFO=$({ emit_vars XDP_INTERFACE; cat <<'SCRIPT'
IFACE="$XDP_INTERFACE"
if [ -z "$IFACE" ]; then
  IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)
fi
# Resolve the underlying member if this is a bonded interface
if [ -n "$IFACE" ] && [ -d "/sys/class/net/$IFACE/bonding" ]; then
  MEMBER=$(awk '{print $1}' "/sys/class/net/$IFACE/bonding/slaves" 2>/dev/null || true)
  if [ -n "$MEMBER" ]; then
    echo "XDP_BOND=$IFACE"
    IFACE="$MEMBER"
  fi
fi
echo "XDP_IFACE=$IFACE"
if [ -z "$IFACE" ]; then
  echo "XDP_ERROR=no_interface"
  return 0
fi
echo "XDP_DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk -F': ' '/^driver:/{print $2}' || true)"
echo "XDP_KERNEL=$(uname -r)"
echo "XDP_RX_MAX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1} f&&/^RX:/{print $2; exit}' || true)"
echo "XDP_TX_MAX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1} f&&/^TX:/{print $2; exit}' || true)"
echo "XDP_RX_CUR=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current hardware settings:/{f=1} f&&/^RX:/{print $2; exit}' || true)"
echo "XDP_TX_CUR=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current hardware settings:/{f=1} f&&/^TX:/{print $2; exit}' || true)"
SCRIPT
    } | root_script)

    XDP_BOND=$(echo "$XDP_INFO"  | sed -n 's/^XDP_BOND=//p')
    XDP_IFACE=$(echo "$XDP_INFO" | sed -n 's/^XDP_IFACE=//p')
    XDP_DRIVER=$(echo "$XDP_INFO" | sed -n 's/^XDP_DRIVER=//p' | tr -cd 'A-Za-z0-9._-')
    XDP_KERNEL=$(echo "$XDP_INFO" | sed -n 's/^XDP_KERNEL=//p' | tr -cd 'A-Za-z0-9._+-')
    XDP_RX_MAX=$(echo "$XDP_INFO" | sed -n 's/^XDP_RX_MAX=//p')
    XDP_TX_MAX=$(echo "$XDP_INFO" | sed -n 's/^XDP_TX_MAX=//p')
    XDP_RX_CUR=$(echo "$XDP_INFO" | sed -n 's/^XDP_RX_CUR=//p')
    XDP_TX_CUR=$(echo "$XDP_INFO" | sed -n 's/^XDP_TX_CUR=//p')

    if [[ -z "$XDP_IFACE" || "$XDP_INFO" == *"XDP_ERROR=no_interface"* ]]; then
      die "Could not detect a network interface for XDP — pass --xdp-interface <iface>"
    fi
    # The name came back from the server and goes into a unit file and
    # validator.sh, so it is held to the same pattern as --xdp-interface.
    [[ "$XDP_IFACE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Unexpected interface name from the server: $XDP_IFACE"

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
      # Resizing the rings resets the link for a moment, so a NIC that already
      # has the right sizes is left alone.
      XDP_RINGS_OK=false
      if [[ "$XDP_RX_CUR" == "$XDP_RXP" && "$XDP_TX_CUR" == "$XDP_TXP" ]]; then
        XDP_RINGS_OK=true
        log_info "$XDP_IFACE ring sizes are already rx=$XDP_RXP tx=$XDP_TXP"
      else
        log_info "Setting $XDP_IFACE ring sizes to rx=$XDP_RXP tx=$XDP_TXP (max rx=$XDP_RX_MAX tx=$XDP_TX_MAX)"
        if $LIVE_AGAVE || $LIVE_FD; then
          log_warn "A validator is running on this host: resizing the rings drops the link on $XDP_IFACE for a moment"
        fi
      fi
      { emit_vars XDP_IFACE XDP_RXP XDP_TXP XDP_RINGS_OK; cat <<'SCRIPT'
if [ "$XDP_RINGS_OK" != true ]; then
  ethtool -G "$XDP_IFACE" rx "$XDP_RXP" tx "$XDP_TXP" 2>/dev/null || true
fi

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
echo "NIC ring tuning applied and persisted for $XDP_IFACE"
SCRIPT
      } | root_script
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
    # gain the capabilities; CapabilityBoundingSet limits it to exactly these.
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
HEXIS_SIGNER_PUBKEY=""
HEXIS_SETUP_INSTALLED=false

# Flash-loan state as arb-config.toml on the host actually has it, not as our flags
# would have written it — upgrade and promote never regenerate that file.
hexis_flash_loan_account() {
  remote "grep -m1 '^marginfi_account' ${HEXIS_DIR}/arb-config.toml 2>/dev/null | sed -e 's/.*= *\"//' -e 's/\".*//'"
}

# solana-keygen from the validator installed in Step 6b
HEXIS_KEYGEN="${SOL_HOME}/.local/share/solana/install/releases/active_release/bin/solana-keygen"

# Pubkey of a keypair file on the server
hexis_pubkey() {
  remote "${HEXIS_KEYGEN} pubkey $1" 2>/dev/null || true
}

if $ENABLE_HEXIS; then
  log_info "Step 7e: Setting up Hexis arb client in ${HEXIS_DIR}"

  # --- Directories: install dir plus the revert-dump spool -----------------
  { emit_vars HEXIS_DIR; cat <<'SCRIPT'
mkdir -p "$HEXIS_DIR" "$HEXIS_DIR/arb-reverts" "$HEXIS_DIR/releases"
chmod 700 "$HEXIS_DIR"
echo "hexis dirs ready: $HEXIS_DIR, $HEXIS_DIR/arb-reverts"

# Interactive shells: the Hexis build ahead of everything else, same as validator.sh
touch ~/.bashrc ~/.profile
for rc in ~/.bashrc ~/.profile; do
  if ! grep -q "$HEXIS_DIR:" "$rc"; then
    echo "export PATH=\"$HEXIS_DIR:\$PATH\"" >> "$rc"
    echo "Added $HEXIS_DIR to $rc"
  fi
done
SCRIPT
  } | sol_script

  # --- Binaries ------------------------------------------------------------
  # The release is private. It is downloaded on THIS machine with gh, its
  # checksum is verified, and the binary is streamed to the server over SSH.
  HEXIS_DL_DIR=""
  HEXIS_SETUP_DL=""
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
      echo "[DRY RUN] upload $HEXIS_BINARY -> $SOL_HOST:${HEXIS_DIR}/releases/${HEXIS_TAG:-<version>}/agave-validator"
      echo "[DRY RUN] link ${HEXIS_DIR}/agave-validator -> releases/${HEXIS_TAG:-<version>}/agave-validator"
    else
      sol_write_file "${HEXIS_DIR}/agave-validator.incoming" 755 < "$HEXIS_BINARY"

      HEXIS_VERSION=$(remote "${HEXIS_DIR}/agave-validator.incoming --version 2>/dev/null | awk '{print \$2}'" || true)
      if [[ -z "$HEXIS_VERSION" ]]; then
        remote "rm -f ${HEXIS_DIR}/agave-validator.incoming"
        die "The Hexis binary does not run on this host"
      fi
      HEXIS_RELEASE="${HEXIS_TAG:-$HEXIS_VERSION}"
      [[ "$HEXIS_RELEASE" =~ $RE_REF ]] || die "Unexpected Hexis version string: $HEXIS_RELEASE"

      { emit_vars HEXIS_DIR HEXIS_RELEASE; cat <<'SCRIPT'
cd "$HEXIS_DIR"
mkdir -p "releases/$HEXIS_RELEASE"
mv agave-validator.incoming "releases/$HEXIS_RELEASE/agave-validator"
chmod +x "releases/$HEXIS_RELEASE/agave-validator"
ln -s "releases/$HEXIS_RELEASE/agave-validator" .agave-validator.next
mv -T .agave-validator.next agave-validator
echo "installed releases/$HEXIS_RELEASE, active: $(readlink agave-validator)"
SCRIPT
      } | sol_script
      log_info "Hexis validator: ${HEXIS_RELEASE} (${HEXIS_VERSION})"
    fi
  elif ! $DRY_RUN; then
    if remote "test -x ${HEXIS_DIR}/agave-validator" 2>/dev/null; then
      log_info "Hexis validator already installed at ${HEXIS_DIR}/agave-validator — skipping download"
    else
      die "No Hexis binary on the server and neither --hexis-tag nor --hexis-binary was given"
    fi
  fi

  # hexis-setup is what creates the marginfi account, the LUTs and the TokenLedgers
  if [[ -n "$HEXIS_SETUP_BINARY" ]]; then
    if $DRY_RUN; then
      echo "[DRY RUN] upload $HEXIS_SETUP_BINARY -> $SOL_HOST:${HEXIS_DIR}/hexis-setup"
    else
      sol_write_file "${HEXIS_DIR}/hexis-setup" 755 < "$HEXIS_SETUP_BINARY"
      log_info "hexis-setup installed at ${HEXIS_DIR}/hexis-setup"
    fi
    HEXIS_SETUP_INSTALLED=true
  elif ! $DRY_RUN && remote "test -x ${HEXIS_DIR}/hexis-setup" 2>/dev/null; then
    HEXIS_SETUP_INSTALLED=true
  fi

  [[ -n "$HEXIS_DL_DIR" ]] && rm -rf "$HEXIS_DL_DIR"
  [[ -n "$HEXIS_SETUP_DL" ]] && rm -rf "$HEXIS_SETUP_DL"

  # --- Arb signer ----------------------------------------------------------
  # The signer signs arb transactions and pays their fees. profit_wallet is the
  # Hexis rewards pool — an address we do not hold a key for, so it is never
  # generated here, only written into the config.
  HEXIS_SIGNER_PATH="${HEXIS_DIR}/${HEXIS_SIGNER_KEYPAIR}"

  if [[ -n "$HEXIS_SIGNER" ]]; then
    if $DRY_RUN; then
      echo "[DRY RUN] upload $HEXIS_SIGNER -> $SOL_HOST:${HEXIS_SIGNER_PATH} (mode 600)"
    else
      # Streamed over SSH and created mode 600 — never readable by anyone else
      sol_write_file "$HEXIS_SIGNER_PATH" 600 < "$HEXIS_SIGNER"
      log_info "Arb signer copied to ${HEXIS_SIGNER_PATH}"
    fi
  fi

  if [[ -n "$HEXIS_CONFIG" ]]; then
    log_info "--hexis-config given — leaving signer_path and profit_wallet to that file"
  elif $DRY_RUN; then
    [[ -z "$HEXIS_SIGNER" ]] && echo "[DRY RUN] generate arb signer keypair at ${HEXIS_SIGNER_PATH}"
  else
    if [[ -z "$HEXIS_SIGNER" ]] && ! remote "test -x ${HEXIS_KEYGEN}" 2>/dev/null; then
      log_error "No solana-keygen on the server (${HEXIS_KEYGEN}) — cannot generate an arb signer"
      die "The Solana CLI install in Step 6b must have failed. Fix that, or pass --hexis-signer"
    fi

    if [[ -z "$HEXIS_SIGNER" ]]; then
      { emit_vars HEXIS_SIGNER_PATH HEXIS_KEYGEN; cat <<'SCRIPT'
umask 077
if [ -f "$HEXIS_SIGNER_PATH" ]; then
  echo "arb signer already exists — keeping $HEXIS_SIGNER_PATH"
else
  "$HEXIS_KEYGEN" new --outfile "$HEXIS_SIGNER_PATH" --no-passphrase --silent
  echo "generated arb signer $HEXIS_SIGNER_PATH"
fi
chmod 600 "$HEXIS_SIGNER_PATH"
SCRIPT
      } | sol_script
    fi

    HEXIS_SIGNER_PUBKEY=$(hexis_pubkey "$HEXIS_SIGNER_PATH")
    [[ "$HEXIS_SIGNER_PUBKEY" =~ $RE_PUBKEY ]] || die "Could not read the arb signer pubkey from ${HEXIS_SIGNER_PATH}"

    log_info "Arb signer:    ${HEXIS_SIGNER_PUBKEY}  (${HEXIS_SIGNER_PATH}) — fund it, it pays arb transaction fees"
    log_info "Profit wallet: ${HEXIS_PROFIT_WALLET}  (Hexis rewards pool)"
  fi

  # --- arb-config.toml -----------------------------------------------------
  if [[ -n "$HEXIS_CONFIG" ]]; then
    log_info "Uploading arb-config.toml from $HEXIS_CONFIG"
    if $DRY_RUN; then
      echo "[DRY RUN] upload $HEXIS_CONFIG -> $SOL_HOST:${HEXIS_DIR}/arb-config.toml (mode 600)"
    else
      sol_write_file "${HEXIS_DIR}/arb-config.toml" 600 < "$HEXIS_CONFIG"
    fi
  else
    [[ -z "$HEXIS_JUP_KEY" ]] && log_warn "No Jupiter API key (--hexis-jup-key / \$HEXIS_JUP_KEY) — jup_key omitted from arb-config.toml"
    hexis_warn_flash_loans "$HEXIS_SIGNER" " (see the summary at the end)"

    # It holds an API key, so it is written mode 600
    hexis_render_arb_config arise.sh "$HEXIS_DIR" "$HEXIS_SIGNER_PATH" "$HEXIS_CONTROL" \
      | sol_put "${HEXIS_DIR}/arb-config.toml" 600
    $DRY_RUN || log_info "arb-config.toml written"
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

VALIDATOR_LOG="${SOL_HOME}/logs/agave-validator.log"

VALIDATOR_ENV_EXPORTS=""
if [[ -n "$METRICS_CONFIG" ]]; then
  VALIDATOR_ENV_EXPORTS="export SOLANA_METRICS_CONFIG=\"${METRICS_CONFIG}\"
"
fi

# HEXIS_PATH_PREFIX puts the Hexis build ahead of the locally built validator on
# PATH, so `exec agave-validator` below resolves to it.
VALIDATOR_PATH="${HEXIS_PATH_PREFIX}${SOL_HOME}/.local/share/solana/install/releases/active_release/bin:${SOL_HOME}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
VALIDATOR_EXEC="agave-validator"

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

# RPC is bound to localhost, kept out of gossip (--private-rpc) and is not
# opened in the firewall.
VALIDATOR_SCRIPT="#!/bin/bash
PATH=${VALIDATOR_PATH}
${VALIDATOR_ENV_EXPORTS}${HEXIS_ENV_EXPORTS}exec ${VALIDATOR_EXEC} \\
${XDP_VALIDATOR_FLAGS}${HEXIS_VALIDATOR_FLAGS}"

if [[ "$NETWORK" == "mainnet" ]]; then
  VALIDATOR_SCRIPT+="    --identity ${SOL_HOME}/identity.json \\
    --authorized-voter ${SOL_HOME}/staked_identity.json \\
    --vote-account ${VOTE_ACCOUNT} \\
"
  for kv in "${KNOWN_VALIDATORS[@]}"; do
    VALIDATOR_SCRIPT+="    --known-validator $kv \\
"
  done
  if $USES_JITO; then
    # 233.84.178.1:7733 is the DoubleZero shred receiver
    VALIDATOR_SCRIPT+="    --tip-payment-program-pubkey T1pyyaTNZsKv2WcRAB8oVnk93mLJw2XzjtVYqCsaHqt \\
    --tip-distribution-program-pubkey 4R3gSG8BpU4t19KYj8CfnbtRpnT8gtk4dvTHxVRwc2r7 \\
    --merkle-root-upload-authority GZctHpWXmsZC1YHACTGGcHhYxjdRqQvTpYkb9LMvxDib \\
    --commission-bps ${COMMISSION_BPS:-0} \\
    --block-engine-url ${JITO_BLOCK_ENGINE:-<FILL_IN_BLOCK_ENGINE_URL>} \\
    --shred-receiver-address ${JITO_SHRED_RECEIVER:-<FILL_IN_SHRED_RECEIVER_ADDRESS>},233.84.178.1:7733 \\
"
  fi
  VALIDATOR_SCRIPT+="    --only-known-rpc \\
    --log ${VALIDATOR_LOG} \\
    --accounts ${ACCOUNTS_PATH} \\
    --snapshots ${SNAPSHOTS_PATH} \\
    --ledger ${LEDGER_PATH} \\
    --rpc-port 8899 \\
    --rpc-bind-address 127.0.0.1 \\
    --private-rpc \\
    --no-port-check \\
    --dynamic-port-range ${DYNAMIC_PORT_RANGE} \\
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
  VALIDATOR_SCRIPT+="    --identity ${SOL_HOME}/staked_identity.json \\
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
    --log ${VALIDATOR_LOG} \\
    --accounts ${ACCOUNTS_PATH} \\
    --snapshots ${SNAPSHOTS_PATH} \\
    --ledger ${LEDGER_PATH} \\
    --rpc-port 8899 \\
    --rpc-bind-address 127.0.0.1 \\
    --private-rpc \\
    --dynamic-port-range ${DYNAMIC_PORT_RANGE} \\
    --wal-recovery-mode skip_any_corrupted_record \\
    --limit-ledger-size \\
    --no-port-check \\
    --use-snapshot-archives-at-startup when-newest \\
    --full-rpc-api
"
fi

if $KEEP_RUNNING_SETUP; then
  log_info "validator.sh left as it is: it belongs to the ${HOST_LABEL} validator that is running,"
  log_info "and reawaken.sh stages Firedancer from it"
else
  printf '%s' "$VALIDATOR_SCRIPT" | sol_put "${SOL_HOME}/validator.sh" 755
  $DRY_RUN || log_info "validator.sh created"
fi

# Post-start arb commands. The pipeline always boots disabled, so this has to be
# run against a running validator after every (re)start.
if $ENABLE_HEXIS; then
  log_info "Step 8b: Creating ${HEXIS_DIR}/arb-enable.sh"
  hexis_render_arb_enable "$HEXIS_DIR" "$LEDGER_PATH" | sol_put "${HEXIS_DIR}/arb-enable.sh" 755
fi

# ---------------------------------------------------------------------------
# Step 9: Create systemd service
# ---------------------------------------------------------------------------
log_info "Step 9: Creating systemd service"

{ emit_vars SOL_USER SOL_HOME LEDGER_PATH ACCOUNTS_PATH SNAPSHOTS_PATH XDP_CAPS IS_FIREDANCER KEEP_RUNNING_SETUP HOLD_SOL; cat <<'SCRIPT'
# Fix mount ownership service — runs before sol.service on every boot.
# If a data directory is missing (e.g. a disk failed to mount) this fails and
# the validator does not start, rather than filling the root disk.
cat > /etc/systemd/system/sol-fix-mounts.service <<EOF
[Unit]
Description=Fix Solana mount ownership
Before=sol.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/chown ${SOL_USER}:${SOL_USER} ${LEDGER_PATH} ${SNAPSHOTS_PATH} ${ACCOUNTS_PATH} ${SOL_HOME}/logs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# The validator runs as an unprivileged user with no sudo. The sandboxing
# below additionally stops the process (and anything it spawns) from gaining
# privileges or modifying the OS.
# XDP gets its capabilities from AmbientCapabilities below, which works with
# NoNewPrivileges; 'setcap' on the validator binary would not.
# KEEP_RUNNING_SETUP: the unit belongs to a validator that is running and is
# on its way to Firedancer — it is left exactly as it is.
if [ "$KEEP_RUNNING_SETUP" != true ]; then
cat > /etc/systemd/system/sol.service <<EOF
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
WorkingDirectory=${SOL_HOME}
LimitNOFILE=1000000
LimitMEMLOCK=2000000000
LogRateLimitIntervalSec=0
Environment="PATH=${SOL_HOME}/.local/share/solana/install/releases/active_release/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
${XDP_CAPS}
ExecStart=${SOL_HOME}/validator.sh

NoNewPrivileges=yes
ProtectSystem=full
PrivateTmp=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
EOF
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify /etc/systemd/system/sol.service /etc/systemd/system/sol-fix-mounts.service \
    || echo "ARISE-WARN: systemd-analyze reported problems with the unit files (see above)"
fi
systemctl daemon-reload
systemctl enable sol-fix-mounts.service
if [ "$KEEP_RUNNING_SETUP" = true ]; then
  echo "sol-fix-mounts.service enabled; sol.service left as it is — it is the validator running now, and reawaken.sh cutover retires it"
elif [ "$IS_FIREDANCER" = true ]; then
  # This host is for Firedancer. sol.service is written for reference but must
  # not start: there is no Agave binary behind validator.sh.
  systemctl disable sol.service >/dev/null 2>&1 || true
  echo "sol-fix-mounts.service enabled; sol.service written but left disabled (Firedancer host)"
elif [ "$HOLD_SOL" = true ]; then
  # Firedancer is this host's validator. Enabling sol.service too would start
  # both at the next boot; reawaken.sh rollback enables it when it takes over.
  echo "sol-fix-mounts.service enabled; sol.service written but NOT enabled — Firedancer is this host's validator until 'reawaken.sh rollback'"
else
  systemctl enable sol.service
  echo "sol.service and sol-fix-mounts.service created and enabled"
fi
SCRIPT
} | root_script

# ---------------------------------------------------------------------------
# Step 10: Log rotation
# ---------------------------------------------------------------------------
log_info "Step 10: Setting up log rotation"

{ emit_vars SOL_USER SOL_HOME; cat <<'SCRIPT'
cat > /etc/logrotate.d/sol <<EOF
${SOL_HOME}/logs/*.log {
    su ${SOL_USER} ${SOL_USER}
    daily
    rotate 7
    dateext
    compress
    delaycompress
    missingok
    copytruncate
}
EOF
echo "Log rotation configured"
SCRIPT
} | root_script

# ---------------------------------------------------------------------------
# Step 11: Firewall
# ---------------------------------------------------------------------------
log_info "Step 11: Configuring firewall"

{ emit_vars FIREWALL_PORT_RANGE; cat <<'SCRIPT'
ufw default deny incoming
ufw default allow outgoing

# SSH — allow whichever port(s) sshd actually listens on, so enabling the
# firewall can never cut off the session that is configuring it
install -d -m 0755 /run/sshd
SSH_PORTS=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }')
if [ -z "$SSH_PORTS" ]; then SSH_PORTS=22; fi
for port in $SSH_PORTS; do
  ufw allow "$port/tcp"
done

# Older versions of this script opened 8000-10000, which exposed the RPC port
# and everything else in that range. Remove those rules.
ufw delete allow 8000:10000/tcp >/dev/null 2>&1 || true
ufw delete allow 8000:10000/udp >/dev/null 2>&1 || true

# Solana validator ports — exactly the validator's --dynamic-port-range.
# RPC (8899) is bound to localhost and deliberately NOT opened.
ufw allow "$FIREWALL_PORT_RANGE/tcp"
ufw allow "$FIREWALL_PORT_RANGE/udp"

# DoubleZero interface rules
ufw allow in on doublezero0 to any port 44880 proto udp
ufw allow out on doublezero0 to any port 44880 proto udp

ufw --force enable
ufw status verbose
SCRIPT
} | root_script

# Hexis Control is plaintext gRPC — only the Hexis fleet may reach it.
if $ENABLE_HEXIS && $HEXIS_CONTROL; then
  HEXIS_CONTROL_PORT="${HEXIS_CONTROL_BIND##*:}"
  { emit_vars HEXIS_CONTROL_ALLOW HEXIS_CONTROL_PORT; cat <<'SCRIPT'
ufw allow from "$HEXIS_CONTROL_ALLOW" to any port "$HEXIS_CONTROL_PORT" proto tcp
echo "Allowed $HEXIS_CONTROL_PORT/tcp from $HEXIS_CONTROL_ALLOW (Hexis Control)"
SCRIPT
  } | root_script
fi

# The Control port is only for the Hexis arb client. On a host that moved to
# plain Jito or Agave (and has no Firedancer, whose Concorde uses it too), close
# the rule an earlier --hexis run opened.
if ! $ENABLE_HEXIS && ! $IS_FIREDANCER && ! $FD_OWNS_HOST && [[ "$HOST_CLIENT" == "hexis" ]]; then
  HEXIS_CONTROL_PORT="${HEXIS_CONTROL_BIND##*:}"
  { emit_vars HEXIS_CONTROL_ALLOW HEXIS_CONTROL_PORT; cat <<'SCRIPT'
if ufw delete allow from "$HEXIS_CONTROL_ALLOW" to any port "$HEXIS_CONTROL_PORT" proto tcp 2>/dev/null | grep -q 'Rule deleted'; then
  echo "Closed $HEXIS_CONTROL_PORT/tcp (Hexis Control) — this host no longer runs the Hexis arb client"
fi
SCRIPT
  } | root_script
fi

# ---------------------------------------------------------------------------
# Step 12: SSH hardening
# ---------------------------------------------------------------------------
log_info "Step 12: Hardening SSH"

if $KEEP_ROOT_LOGIN; then
  PERMIT_ROOT_LOGIN="prohibit-password"
else
  PERMIT_ROOT_LOGIN="no"
fi

{ emit_vars PERMIT_ROOT_LOGIN; cat <<'SCRIPT'
MAIN="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN="$DROPIN_DIR/00-arise.conf"

mkdir -p "$DROPIN_DIR"
install -d -m 0755 /run/sshd

# sshd uses the FIRST value it sees for each option. The drop-in is named 00-
# so it is read before cloud-init's 50-cloud-init.conf (which commonly sets
# PasswordAuthentication yes) and before anything in sshd_config itself.
if ! grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN"; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN"
  echo "Added sshd_config.d Include to $MAIN"
fi

BACKUP=""
if [ -f "$DROPIN" ]; then
  BACKUP=$(mktemp)
  cp -p "$DROPIN" "$BACKUP"
fi
restore() {
  if [ -n "$BACKUP" ]; then mv "$BACKUP" "$DROPIN"; else rm -f "$DROPIN"; fi
}

cat > "$DROPIN" <<EOF
# Managed by arise.sh — do not edit, rerun the script instead
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin ${PERMIT_ROOT_LOGIN}
X11Forwarding no
MaxAuthTries 3
EOF
chmod 600 "$DROPIN"

# Never reload a config that does not parse, or that does not actually result
# in the settings we intend — check sshd's own view of the effective config.
if ! sshd -t; then
  restore
  echo "ERROR: sshd rejected the new configuration; it was rolled back" >&2
  exit 1
fi

EFFECTIVE=$(sshd -T)
if [ "$PERMIT_ROOT_LOGIN" = "no" ]; then WANT_ROOT="permitrootlogin no"; else WANT_ROOT="permitrootlogin without-password"; fi
for want in "pubkeyauthentication yes" "passwordauthentication no" "kbdinteractiveauthentication no" "permitemptypasswords no" "$WANT_ROOT"; do
  if ! grep -qix "$want" <<< "$EFFECTIVE"; then
    restore
    echo "ERROR: effective sshd config is missing '$want' — another config file overrides it. Rolled back." >&2
    exit 1
  fi
done
if [ -n "$BACKUP" ]; then rm -f "$BACKUP"; fi

systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh
echo "SSH hardened and verified: key-only auth, $WANT_ROOT"
SCRIPT
} | root_script

if ! $DRY_RUN; then
  wait_ssh "$ADMIN_HOST" || die "SSH as ${ADMIN_HOST} stopped working after hardening — fix this from your provider's console before closing any open session"
  log_info "Confirmed SSH access still works after hardening"
fi

# ---------------------------------------------------------------------------
# Step 13: fail2ban
# ---------------------------------------------------------------------------
log_info "Step 13: Configuring fail2ban"

root_script <<'SCRIPT'
systemctl enable --now fail2ban
systemctl is-active --quiet fail2ban
echo "fail2ban running"
SCRIPT

# ---------------------------------------------------------------------------
# Step 14: perch watchtower (default on; --no-perch to skip)
#
# perch pages when the validator stops voting. It is installed with its own
# installer, which verifies the download against the published checksum and
# sets up a sandboxed service under an unprivileged "perch" user. It holds no
# keypair. It is installed and pointed at this validator, but NOT started:
# it needs alert-channel secrets that only the operator has.
# ---------------------------------------------------------------------------
PERCH_INSTALLED=false
if $INSTALL_PERCH; then
  log_info "Step 14: Installing perch watchtower (${PERCH_VERSION})"

  if $DRY_RUN; then
    IDENTITY_PUBKEY="<STAKED_IDENTITY_PUBKEY>"
  else
    IDENTITY_PUBKEY=$(sol_script <<'SCRIPT'
export PATH="$HOME/.local/share/solana/install/releases/active_release/bin:$PATH"
echo "PUBKEY|$(solana-keygen pubkey ~/staked_identity.json)"
SCRIPT
    )
    IDENTITY_PUBKEY=$(grep '^PUBKEY|' <<< "$IDENTITY_PUBKEY" | head -1 | cut -d'|' -f2)
    [[ "$IDENTITY_PUBKEY" =~ $RE_PUBKEY ]] || die "Could not read the staked identity pubkey on the server"
  fi

  { emit_vars PERCH_REPO PERCH_VERSION PERCH_LABEL ADMIN_USER NETWORK IDENTITY_PUBKEY VOTE_ACCOUNT; cat <<'SCRIPT'
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ "$PERCH_VERSION" = "latest" ]; then
  BASE="https://github.com/$PERCH_REPO/releases/latest/download"
else
  BASE="https://github.com/$PERCH_REPO/releases/download/$PERCH_VERSION"
fi
curl --proto '=https' --tlsv1.2 -fsSL "$BASE/install.sh" -o "$WORK/install.sh"

# The admin user is added to the perch group so it can run 'perch maint'.
# sol is deliberately not: the validator account must not be able to silence
# the thing that watches it.
bash "$WORK/install.sh" --version "$PERCH_VERSION" --operator "$ADMIN_USER"

# Point the starter config at this validator. Only done while the installer's
# placeholders are still there — an edited config is never touched. The edits
# are made on a copy and only installed once the result has been checked, so a
# failure never leaves a half-edited config behind.
CFG=/etc/perch/config.toml
if grep -q 'YOUR_IDENTITY_PUBKEY' "$CFG"; then
  NEW="$WORK/config.toml"
  cp "$CFG" "$NEW"
  sed -i \
    -e "s/YOUR_IDENTITY_PUBKEY/$IDENTITY_PUBKEY/" \
    -e "s/YOUR_VOTE_PUBKEY/$VOTE_ACCOUNT/" \
    -e "s/^label = \"chimps-1\"/label = \"$PERCH_LABEL\"/" \
    -e "s/^name = \"chimps\"/name = \"$PERCH_LABEL\"/" \
    "$NEW"

  WANT_CLUSTER="mainnet-beta"
  if [ "$NETWORK" = "testnet" ]; then
    WANT_CLUSTER="testnet"
    # Pin the cluster and swap the starter's mainnet endpoints for the free
    # testnet ones listed in perch's deployment guide. The third starter
    # endpoint has no testnet equivalent, so its three-line block is dropped.
    sed -i '/^\[\[endpoints\]\]$/{N;N;/leorpc/d;}' "$NEW"
    sed -i \
      -e 's/^cluster = "mainnet-beta"/cluster = "testnet"/' \
      -e 's|https://api.mainnet-beta.solana.com|https://api.testnet.solana.com|' \
      -e 's|https://solana-rpc.publicnode.com|https://solana-testnet-rpc.publicnode.com|' \
      "$NEW"
  fi

  # The edits depend on the shape of the installer's starter config.
  # Check the result rather than trust it.
  for want in "identity = \"$IDENTITY_PUBKEY\"" "vote_account = \"$VOTE_ACCOUNT\"" "label = \"$PERCH_LABEL\"" "cluster = \"$WANT_CLUSTER\""; do
    if ! grep -qxF "$want" "$NEW"; then
      echo "ERROR: could not set '$want' in $CFG — the starter config has changed shape. It was left as installed; edit it by hand." >&2
      exit 1
    fi
  done
  if ! grep -q '^url = "https://' "$NEW"; then
    echo "ERROR: no RPC endpoint left in the perch config. $CFG was left as installed; edit it by hand." >&2
    exit 1
  fi
  if [ "$NETWORK" = "testnet" ] && grep -E '^url = ' "$NEW" | grep -Eq 'mainnet|solana-rpc\.publicnode|leorpc'; then
    echo "ERROR: could not switch the perch endpoints to testnet. $CFG was left as installed; edit it by hand." >&2
    exit 1
  fi
  # cat keeps the installed file's owner and mode (root:perch 0640)
  cat "$NEW" > "$CFG"
  echo "perch configured for $PERCH_LABEL ($WANT_CLUSTER): identity $IDENTITY_PUBKEY, vote account $VOTE_ACCOUNT"
else
  echo "Existing $CFG kept unchanged"
fi

if systemctl is-active --quiet perch; then
  echo "perch is running"
else
  echo "perch is installed but not started — it needs alert secrets in /etc/perch/env"
fi
SCRIPT
  } | root_script
  PERCH_INSTALLED=true
else
  log_info "Step 14: Skipping perch watchtower (--no-perch)"
fi

# ---------------------------------------------------------------------------
# Step 15: Leftovers from older versions of this script
# ---------------------------------------------------------------------------
log_info "Step 15: Checking for leftovers from older versions"

{ emit_vars SOL_HOME; cat <<'SCRIPT'
# Reported, not removed — these are for the operator to decide on.
if [ -f "$SOL_HOME/.ssh/github_key" ]; then
  echo "ARISE-WARN: $SOL_HOME/.ssh/github_key is a GitHub private key left on this server by an older run. It is no longer used — delete it and revoke it on GitHub."
fi
if command -v docker >/dev/null 2>&1; then
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx jag-snap; then
    echo "ARISE-WARN: a jag-snap docker container exists. This script no longer manages it — remove it with 'docker rm -f jag-snap' if unused."
  fi
fi
if [ -d "$SOL_HOME/jag-snap" ]; then
  echo "ARISE-WARN: $SOL_HOME/jag-snap is a leftover checkout and is no longer used."
fi
echo "Leftover check complete"
SCRIPT
} | root_script

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_info "============================================"
log_info "Validator server setup complete!"
log_info "============================================"
log_info ""
log_info "Two accounts, two jobs:"
log_info "  ${ADMIN_USER}  — admin, has sudo (system changes, starting/stopping the service)"
log_info "  ${SOL_USER}      — runs the validator, no sudo (logs, solana CLI, validator.sh)"
log_info ""

if $IS_FIREDANCER; then
  # Hand over to reawaken.sh. 'stage' puts the binary, config, arb signer, unit
  # and firewall rules in place and starts nothing; 'cutover' is what starts it.
  REAWAKEN_ARGS=(--host "$SSH_HOST" --ssh-key "$SSH_KEY" --admin-user "$ADMIN_USER")
  STAGE_ARGS=("${REAWAKEN_ARGS[@]}")
  [[ -n "$FD_TAG" ]]    && STAGE_ARGS+=(--fd-tag "$FD_TAG")
  [[ -n "$FD_BINARY" ]] && STAGE_ARGS+=(--fd-binary "$FD_BINARY")
  [[ -n "$FD_CONCORDE_TABLES" ]] && STAGE_ARGS+=(--concorde-tables "$FD_CONCORDE_TABLES")
  if [[ -n "$HEXIS_SIGNER" ]]; then
    STAGE_ARGS+=(--hexis-signer "$HEXIS_SIGNER")
  else
    STAGE_ARGS+=(--generate-signer)
  fi

  if $DRY_RUN; then
    log_info "[DRY RUN] would now stage Firedancer with:"
    log_info "  $REAWAKEN stage ${STAGE_ARGS[*]}"
  else
    log_info "Host is provisioned. Staging Firedancer with reawaken.sh (this starts nothing):"
    log_info "  $REAWAKEN stage ${STAGE_ARGS[*]}"
    echo ""
    # The sudo password is handed to the child through its environment so it is
    # not asked for twice. It never reaches a command line.
    if ! SUDO_PASS="$SUDO_PASS" "$REAWAKEN" stage "${STAGE_ARGS[@]}"; then
      log_error "Staging Firedancer did not finish. The host itself is set up; fix the cause and run:"
      log_error "  $REAWAKEN stage ${STAGE_ARGS[*]}"
      exit 1
    fi
  fi
  log_info ""
  if $LIVE_FD; then
    log_info "Firedancer is already running on this host. To move it onto the staged release:"
    log_info "  $REAWAKEN upgrade ${STAGE_ARGS[*]}"
  elif $KEEP_RUNNING_SETUP && $RESTART; then
    log_info "--restart: handing over to reawaken.sh cutover, which waits for a restart"
    log_info "window, stops ${HOST_LABEL} and starts Firedancer. It asks first."
    echo ""
    SUDO_PASS="$SUDO_PASS" "$REAWAKEN" cutover "${REAWAKEN_ARGS[@]}" ${WINDOW_ARGS[@]+"${WINDOW_ARGS[@]}"} || {
      log_error "The cutover did not finish. Run it again with:"
      log_error "  $REAWAKEN cutover ${REAWAKEN_ARGS[*]}"
      exit 1
    }
  elif $KEEP_RUNNING_SETUP; then
    log_info "Next steps:"
    log_info "  ${HOST_LABEL} is still what runs here. Move to Firedancer with:"
    log_info "    $REAWAKEN cutover ${REAWAKEN_ARGS[*]}"
    log_info "  and back again with:"
    log_info "    $REAWAKEN rollback ${REAWAKEN_ARGS[*]}"
  else
    log_info "Next steps:"
    log_info "  1. Review the settings:        ${SSH_CMD} $SOL_HOST 'cat ~/validator.sh'"
    log_info "  2. Start Firedancer:           $REAWAKEN cutover ${REAWAKEN_ARGS[*]}"
    log_info "     Nothing is running yet, so there is nothing to stop — cutover checks the"
    log_info "     config, asks once, and starts firedancer.service."
    log_info ""
    log_info "validator.sh on this host is the record of its settings; reawaken.sh reads it."
    log_info "There is no Agave client behind it. To have one to fall back to, run this"
    log_info "script again with --client jito or --client agave: it is installed beside"
    log_info "Firedancer and 'reawaken.sh rollback' then switches to it."
  fi
elif $HOLD_SOL; then
  # Firedancer runs here; an Agave-family client was just installed beside it.
  REAWAKEN_ARGS=(--host "$SSH_HOST" --ssh-key "$SSH_KEY" --admin-user "$ADMIN_USER")
  log_info "${CLIENT} is installed beside Firedancer, which is still this host's validator."
  if $RESTART && ! $DRY_RUN; then
    [[ -x "$REAWAKEN" ]] || die "Missing $REAWAKEN — run this from a checkout"
    log_info "--restart: handing over to reawaken.sh rollback, which waits for a restart"
    log_info "window, stops Firedancer and starts ${CLIENT} from validator.sh. It asks first."
    echo ""
    SUDO_PASS="$SUDO_PASS" "$REAWAKEN" rollback "${REAWAKEN_ARGS[@]}" ${WINDOW_ARGS[@]+"${WINDOW_ARGS[@]}"} || {
      log_error "The switch did not finish. Run it again with:"
      log_error "  $REAWAKEN rollback ${REAWAKEN_ARGS[*]}"
      exit 1
    }
  else
    log_info "Switch to it with:"
    log_info "  $REAWAKEN rollback ${REAWAKEN_ARGS[*]}"
    log_info "Until then nothing changes: sol.service is not enabled."
  fi
elif $LIVE_AGAVE; then
  # A validator is running on the binary and flags it was started with.
  # Everything for the new setup is on disk; only a restart is missing.
  log_info "The validator that is running was not touched. The new setup takes effect when it restarts."
  NEW_EXEC="PATH=${VALIDATOR_PATH} ${VALIDATOR_EXEC}"
  # exit is an admin-RPC call and goes through the binary that is running
  EXIT_BIN="${LIVE_EXE:-PATH=${VALIDATOR_PATH} ${VALIDATOR_EXEC}}"
  EXIT_ARGS="--min-idle-time ${MIN_IDLE_TIME} --max-delinquent-stake ${MAX_DELINQUENT_STAKE} --skip-new-snapshot-check"
  RESTART_CMD="${EXIT_BIN} --ledger ${LEDGER_PATH} exit ${EXIT_ARGS}"
  if $RESTART; then
    # Do not take a healthy validator down for a binary that cannot even run
    if ! remote "${NEW_EXEC} --version" >/dev/null 2>&1; then
      die "The new validator binary does not run (${VALIDATOR_EXEC} --version failed) — not restarting. The running validator is untouched."
    fi
    log_info "--restart: new binary is $(remote "${NEW_EXEC} --version" 2>/dev/null | head -1)"
    log_info "Waiting for a restart window (min-idle-time ${MIN_IDLE_TIME}m, max-delinquent-stake ${MAX_DELINQUENT_STAKE}%) — this can take a while"
    remote "${EXIT_BIN} --ledger ${LEDGER_PATH} wait-for-restart-window ${EXIT_ARGS}" \
      || die "No restart window was found — nothing was restarted. Try again, or restart by hand."
    if $PERCH_INSTALLED; then
      # Tell the watchtower the restart is planned, so it does not page for it
      root_script <<'SCRIPT'
if systemctl is-active --quiet perch 2>/dev/null; then
  perch maint restart || echo "ARISE-WARN: could not declare the restart to perch — it may alert"
fi
SCRIPT
    fi
    log_info "Exiting the validator — systemd starts it again on the new setup"
    remote "$RESTART_CMD" || die "The validator did not exit cleanly — check it: ${SSH_CMD} $SOL_HOST 'tail -50 ${VALIDATOR_LOG}'"
    RESTARTED=false
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      sleep 2
      if [[ "$(remote "systemctl is-active sol" 2>/dev/null || true)" == "active" ]]; then RESTARTED=true; break; fi
    done
    if $RESTARTED; then
      # shellcheck disable=SC2016
      log_info "sol.service is active again, now running: $(remote 'readlink /proc/$(systemctl show -p MainPID --value sol)/exe' 2>/dev/null || echo unknown)"
    else
      log_error "sol.service did not come back within 30 seconds. Check it:"
      log_error "  ${SSH_CMD} -t $ADMIN_HOST 'sudo systemctl status sol'"
      log_error "  ${SSH_CMD} $SOL_HOST 'tail -50 ${VALIDATOR_LOG}'"
      exit 1
    fi
    log_info "  Monitor catchup:  ${SSH_CMD} $SOL_HOST 'solana catchup --our-localhost'"
  else
    log_info "Restart it at a safe moment — run this script again with --restart, or by hand:"
    log_info "  ${SSH_CMD} $SOL_HOST '${RESTART_CMD}'"
    log_info "(exit waits for a window with no leader slot; systemd then starts the new setup)"
  fi
else
  log_info "Next steps:"
  log_info "  1. Review the startup script:  ${SSH_CMD} $SOL_HOST 'cat ~/validator.sh'"
  log_info "  2. Start the validator:        ${SSH_CMD} -t $ADMIN_HOST 'sudo systemctl start sol'"
  log_info "  3. Check logs:                 ${SSH_CMD} $SOL_HOST 'tail -f ${VALIDATOR_LOG}'"
  log_info "  4. Monitor catchup:            ${SSH_CMD} $SOL_HOST 'solana catchup --our-localhost'"
  log_info "  5. Check validator status:     ${SSH_CMD} $SOL_HOST 'agave-validator --ledger ${LEDGER_PATH} monitor'"
  log_info ""
  log_info "The validator service is enabled but NOT started automatically."
  if $RESTART && $DRY_RUN; then
    log_info "[DRY RUN] --restart: if a validator is running, would wait for a restart window"
    log_info "[DRY RUN]   (min-idle-time ${MIN_IDLE_TIME}m, max-delinquent-stake ${MAX_DELINQUENT_STAKE}%) and restart it onto this setup"
  elif $RESTART; then
    log_info "--restart: no validator was running on this host, so there was nothing to restart."
  fi
fi
if $PERCH_INSTALLED; then
  log_info ""
  log_info "perch (watchtower) is installed and pointed at this validator, but not started."
  log_info "As ${ADMIN_USER} on the server:"
  log_info "  1. sudo nano /etc/perch/env          — Telegram / PagerDuty / heartbeat secrets"
  log_info "     (delete the section of any channel you do not use from /etc/perch/config.toml)"
  log_info "  2. sudo bash -c 'set -a; . /etc/perch/env; perch --check-config'"
  log_info "  3. sudo systemctl enable --now perch"
  log_info "  Before planned restarts: perch maint restart"
  if [[ "$NETWORK" == "testnet" ]]; then
    log_info "  On testnet, consider severity = \"notify\" for the validator checks so it never pages."
  fi
fi

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
