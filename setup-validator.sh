#!/usr/bin/env bash
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
#   ./setup-validator.sh \
#     --host <user@host> \
#     --ssh-key <path-to-ssh-key> \
#     --identity <path-to-staked_identity.json> \
#     --vote-account <vote-account-pubkey> \
#     --network <testnet|mainnet> \
#     [--ledger-disk /dev/nvme0n1] \
#     [--accounts-disk /dev/nvme1n1] \
#     [--auto-disks] \
#     [--swap-size 128G] \
#     [--dry-run]

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NETWORK="testnet"
LEDGER_DISK=""
ACCOUNTS_DISK=""
SWAP_SIZE="128G"
AUTO_DISKS=false
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
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

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
  --commission-bps <bps>        Commission in basis points (mainnet, e.g., 0)

Bootstrap (for fresh servers):
  --root-user <user>            Initial SSH user with root/sudo access (default: root)
                                Used to create sol user and add SSH key, then
                                reconnects as sol for the rest of the setup

Optional:
  --github-ssh-key <path>       SSH key for GitHub (to clone jito-solana repo)
  --network <testnet|mainnet>   Network to join (default: testnet)
  --jito-region <region>        Jito region (auto-detected from server IP if omitted)
                                Mainnet: amsterdam, dublin, frankfurt, london,
                                         new-york, salt-lake-city, singapore, tokyo
                                Testnet: dallas, new-york
  --ledger-disk <device>        Block device for ledger (e.g., /dev/nvme0n1)
  --accounts-disk <device>      Block device for accounts (e.g., /dev/nvme1n1)
  --auto-disks                  Auto-discover unformatted NVMe drives on server
  --swap-size <size>            Swap file size (default: 128G)
  --dry-run                     Print commands without executing
  -h, --help                    Show this help

Disk selection priority:
  1. Explicit --ledger-disk / --accounts-disk flags
  2. --auto-disks: scans server for unused/unformatted NVMe drives
  3. Falls back to /home/sol/ directories if neither is specified
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
    --jito-region)   JITO_REGION="$2";     shift 2 ;;
    --network)       NETWORK="$2";         shift 2 ;;
    --ledger-disk)   LEDGER_DISK="$2";     shift 2 ;;
    --accounts-disk) ACCOUNTS_DISK="$2";   shift 2 ;;
    --auto-disks)    AUTO_DISKS=true;      shift   ;;
    --swap-size)     SWAP_SIZE="$2";       shift 2 ;;
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

# Strip user@ prefix from --host if accidentally included
SSH_HOST="${SSH_HOST##*@}"

# Build SSH destinations
SOL_HOST="${SOL_USER}@${SSH_HOST}"
if [[ -n "$ROOT_HOST" ]]; then
  ROOT_DEST="${ROOT_HOST}@${SSH_HOST}"
fi

# PROBE_HOST is used for pre-bootstrap operations (region detection, IP lookup)
# before the sol user may exist
PROBE_HOST="${ROOT_DEST:-$SOL_HOST}"

# ---------------------------------------------------------------------------
# Network-specific config
# ---------------------------------------------------------------------------
if [[ "$NETWORK" == "testnet" ]]; then
  RPC_URL="https://api.testnet.solana.com"
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
  RPC_URL="https://api.mainnet-beta.solana.com"
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

# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o IdentitiesOnly=yes -i $SSH_KEY"

# Determine root connection — use --root-user if provided, otherwise
# fall back to sol with sudo for system-level operations
if [[ -n "$ROOT_HOST" ]]; then
  ROOT_DEST="${ROOT_HOST}@${SSH_HOST}"
else
  ROOT_DEST=""
fi

# Run a script as root on the server
# Uses ROOT_DEST if available (pre-bootstrap), otherwise sol with sudo (post-bootstrap)
# Adds sudo when ROOT_HOST is not "root"
root_script() {
  if $DRY_RUN; then
    echo "[DRY RUN] root_script on ${ROOT_DEST:-$SOL_HOST}: <script>"
    cat
    return
  fi
  local tmpscript
  tmpscript=$(mktemp)
  cat > "$tmpscript"
  if [[ -n "$ROOT_DEST" ]]; then
    scp -q $SSH_OPTS "$tmpscript" "$ROOT_DEST:/tmp/_setup_script.sh"
    rm -f "$tmpscript"
    if [[ "$ROOT_HOST" == "root" ]]; then
      ssh $SSH_OPTS "$ROOT_DEST" "bash /tmp/_setup_script.sh; rm -f /tmp/_setup_script.sh"
    else
      ssh $SSH_OPTS "$ROOT_DEST" "sudo bash /tmp/_setup_script.sh; rm -f /tmp/_setup_script.sh"
    fi
  else
    scp -q $SSH_OPTS "$tmpscript" "$SOL_HOST:/tmp/_setup_script.sh"
    rm -f "$tmpscript"
    ssh $SSH_OPTS "$SOL_HOST" "echo '${SUDO_PASS}' | sudo -S bash /tmp/_setup_script.sh; rm -f /tmp/_setup_script.sh"
  fi
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
  # Check if sol user is already set up and accessible
  if ssh $SSH_OPTS -o ConnectTimeout=5 "$SOL_HOST" "echo ok" 2>/dev/null; then
    log_info "Step 0: Sol user already accessible via SSH — skipping bootstrap"
    read -rsp "Enter sudo password for ${SOL_USER}@${SSH_HOST}: " SUDO_PASS
    echo ""
  else
    log_info "Step 0: Bootstrapping sol user via ${ROOT_DEST}"

  # Get the public key corresponding to the provided SSH private key
  SSH_PUBKEY=$(ssh-keygen -y -f "$SSH_KEY")
  if [[ -z "$SSH_PUBKEY" ]]; then
    log_error "Could not derive public key from $SSH_KEY"
    exit 1
  fi

  # Build the bootstrap script
  BOOTSTRAP_SCRIPT=$(cat <<BOOTEOF
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

echo "Sol user bootstrap complete"
BOOTEOF
  )

  # Verify SSH connectivity to root user first (also accepts host key)
  log_info "Testing SSH connection to ${ROOT_DEST}..."
  if ! ssh $SSH_OPTS "$ROOT_DEST" "echo 'SSH connection OK'" 2>/dev/null; then
    log_error "Cannot SSH to ${ROOT_DEST} — check SSH key and host"
    exit 1
  fi

  # Execute bootstrap as root
  BOOT_TMP=$(mktemp)
  echo "$BOOTSTRAP_SCRIPT" > "$BOOT_TMP"
  scp -q $SSH_OPTS "$BOOT_TMP" "$ROOT_DEST:/tmp/_bootstrap.sh"
  rm -f "$BOOT_TMP"
  ssh $SSH_OPTS "$ROOT_DEST" "sudo bash /tmp/_bootstrap.sh; rm -f /tmp/_bootstrap.sh"

  # Set sol user's password (for sudo)
  echo ""
  read -rsp "Set password for ${SOL_USER} user (used for sudo): " SOL_PASS
  echo ""
  read -rsp "Confirm password: " SOL_PASS_CONFIRM
  echo ""

  if [[ "$SOL_PASS" != "$SOL_PASS_CONFIRM" ]]; then
    log_error "Passwords do not match"
    exit 1
  fi

  # Write password change to a temp script to avoid quoting issues
  PASS_TMP=$(mktemp)
  echo "echo '${SOL_USER}:${SOL_PASS}' | chpasswd" > "$PASS_TMP"
  scp -q $SSH_OPTS "$PASS_TMP" "$ROOT_DEST:/tmp/_setpass.sh"
  rm -f "$PASS_TMP"
  ssh $SSH_OPTS "$ROOT_DEST" "sudo bash /tmp/_setpass.sh; rm -f /tmp/_setpass.sh"
  log_info "Sol user password set"
  SUDO_PASS="$SOL_PASS"

  # Verify we can connect as sol
  if ssh $SSH_OPTS "$SOL_HOST" "echo 'SSH connection as ${SOL_USER} successful'" 2>/dev/null; then
    log_info "Verified SSH access as ${SOL_USER}"
  else
    log_error "Cannot SSH as ${SOL_USER}@${SSH_HOST} — check authorized_keys"
    exit 1
  fi
  fi  # end of bootstrap else (sol not yet accessible)
else
  # No bootstrap — prompt for sol's sudo password (needed for sol_script sudo fallback)
  if ! $DRY_RUN; then
    read -rsp "Enter sudo password for ${SOL_USER}@${SSH_HOST}: " SUDO_PASS
    echo ""
    if ! ssh $SSH_OPTS "$SOL_HOST" "echo '${SUDO_PASS}' | sudo -S -v 2>/dev/null"; then
      log_error "Sudo password validation failed"
      exit 1
    fi
    log_info "Sudo access confirmed for ${SOL_USER}"
  fi
fi

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

detect_jito_region() {
  log_info "Detecting server region from IP geolocation..."

  # Get server public IP and geolocate it
  SERVER_GEO=$(ssh $SSH_OPTS "$PROBE_HOST" "curl -s https://ipinfo.io 2>/dev/null || curl -s https://ifconfig.co/json 2>/dev/null || true")

  if [[ -z "$SERVER_GEO" ]]; then
    log_warn "Could not determine server location"
    return 1
  fi

  # Extract city, region, country, coordinates
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

prompt_jito_region() {
  echo ""
  echo "=========================================="
  echo "  Jito Region Selection ($NETWORK)"
  echo "=========================================="

  # Build numbered list
  local i=1
  declare -a region_names=()
  while IFS='|' read -r name block_engine shred_receiver ntp; do
    region_names+=("$name")
    local marker=""
    if [[ -n "$1" && "$name" == "$1" ]]; then
      marker=" <-- detected (closest to server)"
    fi
    printf "  %d) %-20s %s%s\n" "$i" "$name" "$block_engine" "$marker"
    ((i++))
  done < <(get_regions_for_network)

  echo ""

  # If we have a suggestion, default to it
  local default_num=""
  if [[ -n "$1" ]]; then
    for idx in "${!region_names[@]}"; do
      if [[ "${region_names[$idx]}" == "$1" ]]; then
        default_num=$((idx + 1))
        break
      fi
    done
  fi

  while true; do
    if [[ -n "$default_num" ]]; then
      read -rp "Select region [${default_num}]: " choice
      choice="${choice:-$default_num}"
    else
      read -rp "Select region: " choice
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
      JITO_REGION="${region_names[$((choice - 1))]}"
      break
    else
      echo "Invalid selection. Enter a number between 1 and $((i - 1))."
    fi
  done

  log_info "Selected Jito region: $JITO_REGION"
}

# --- Resolve Jito region ---
if [[ -z "$JITO_REGION" ]] && ! $DRY_RUN; then
  SUGGESTED_REGION=""
  SUGGESTED_REGION=$(detect_jito_region 2>/dev/null) || true
  prompt_jito_region "$SUGGESTED_REGION"
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

# --- Resolve public RPC address from server IP ---
PUBLIC_RPC_ADDRESS=""
if [[ "$NETWORK" == "mainnet" ]]; then
  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP=$(ssh $SSH_OPTS "$PROBE_HOST" "curl -s https://ipinfo.io/ip 2>/dev/null || curl -s https://ifconfig.me 2>/dev/null || true")
  fi
  PUBLIC_RPC_ADDRESS="${SERVER_IP}:8899"
  log_info "Public RPC address: $PUBLIC_RPC_ADDRESS"
fi

# --- Prompt for commission if not provided (mainnet) ---
if [[ "$NETWORK" == "mainnet" && -z "$COMMISSION_BPS" ]] && ! $DRY_RUN; then
  echo ""
  read -rp "Commission in basis points (e.g., 0 = 0%, 500 = 5%, 1000 = 10%) [0]: " COMMISSION_BPS
  COMMISSION_BPS="${COMMISSION_BPS:-0}"
  log_info "Commission: ${COMMISSION_BPS} bps"
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
  htop \
  iotop \
  sysstat \
  fail2ban \
  ufw \
  logrotate \
  nvme-cli \
  mdadm \
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
  MOUNTS_EXIST=$(ssh $SSH_OPTS "$PROBE_HOST" "mountpoint -q /mnt/ledger 2>/dev/null && mountpoint -q /mnt/accounts 2>/dev/null && echo YES || echo NO")
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

  # Get size in GB for display
  size_bytes=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
  size_gb=$((size_bytes / 1073741824))

  # Report: device, size
  echo "${dev}|none|${size_gb}GB"
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
    # Parse discovered disks
    declare -a DISK_LIST=()
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      dev=$(echo "$line" | cut -d'|' -f1)
      fs=$(echo "$line" | cut -d'|' -f2)
      size=$(echo "$line" | cut -d'|' -f3)
      log_info "  $dev  filesystem=$fs  size=$size"
      DISK_LIST+=("$dev")
    done <<< "$DISCOVERED_DISKS"

    DISK_COUNT=${#DISK_LIST[@]}

    if [[ $DISK_COUNT -ge 2 ]]; then
      # Two or more drives: sort by size descending on the server
      SORT_TMP=$(mktemp)
      cat > "$SORT_TMP" <<'SORTEOF'
for dev in "$@"; do
  sz=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
  echo "$sz $dev"
done | sort -rn | awk '{print $2}'
SORTEOF
      scp -q $SSH_OPTS "$SORT_TMP" "$PROBE_HOST:/tmp/_sort_disks.sh"
      rm -f "$SORT_TMP"
      if [[ -n "$ROOT_DEST" && "$ROOT_HOST" == "root" ]]; then
        SORTED_DISKS=$(ssh $SSH_OPTS "$PROBE_HOST" "bash /tmp/_sort_disks.sh ${DISK_LIST[*]}; rm -f /tmp/_sort_disks.sh")
      else
        SORTED_DISKS=$(ssh $SSH_OPTS "$PROBE_HOST" "sudo bash /tmp/_sort_disks.sh ${DISK_LIST[*]}; rm -f /tmp/_sort_disks.sh")
      fi
      LEDGER_DISK=$(echo "$SORTED_DISKS" | head -1)
      ACCOUNTS_DISK=$(echo "$SORTED_DISKS" | sed -n '2p')
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

# ---------------------------------------------------------------------------
# Step 6b: Build and install Jito validator
# ---------------------------------------------------------------------------
if [[ -n "$GITHUB_SSH_KEY" ]]; then
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
    # Fetch branches and prompt for selection
    log_info "Fetching branches from jito-solana..."
    BRANCHES=$(remote "ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/github_key git@github.com 2>/dev/null; git ls-remote --heads git@github.com:TheChimpions/jito-solana.git 2>/dev/null | awk '{print \$2}' | sed 's|refs/heads/||' | grep -E '(jito|tuxr)$' | sort -V" 2>/dev/null || true)

    if [[ -z "$BRANCHES" ]]; then
      log_error "Could not fetch branches — check GitHub SSH key"
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
  git clone git@github.com:TheChimpions/jito-solana.git ~/jito-solana
  echo "Cloned jito-solana"
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

  # Ensure PATH is in .bashrc
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

else
  log_warn "Step 6b: No --github-ssh-key provided — skipping Jito build"
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
log_info "Step 7b: Creating mostly_confirmed_threshold"

sol_script <<SCRIPT
cat > ~/mostly_confirmed_threshold <<'EOF'
0.35 4 1 8
EOF
echo "mostly_confirmed_threshold created"
SCRIPT

# ---------------------------------------------------------------------------
# Step 7: Create validator startup script
# ---------------------------------------------------------------------------
log_info "Step 8: Creating validator.sh"

# Build entrypoint flags
ENTRYPOINT_FLAGS=""
for ep in "${ENTRYPOINTS[@]}"; do
  ENTRYPOINT_FLAGS+="    --entrypoint $ep \\"$'\n'
done

# Build known-validator flags
KNOWN_FLAGS=""
for kv in "${KNOWN_VALIDATORS[@]}"; do
  KNOWN_FLAGS+="    --known-validator $kv \\"$'\n'
done

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
VALIDATOR_SCRIPT="#!/bin/bash
PATH=/home/${SOL_USER}/.local/share/solana/install/releases/active_release/bin:/home/${SOL_USER}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
"

if [[ "$NETWORK" == "mainnet" ]]; then
  VALIDATOR_SCRIPT+="exec agave-validator \\
    --identity /home/${SOL_USER}/identity.json \\
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
    --shred-receiver-address ${JITO_SHRED_RECEIVER:-<FILL_IN_SHRED_RECEIVER_ADDRESS>} \\
    --only-known-rpc \\
    --log /home/${SOL_USER}/logs/agave-validator.log \\
    --accounts ${ACCOUNTS_PATH} \\
    --snapshots ${SNAPSHOTS_PATH} \\
    --ledger ${LEDGER_PATH} \\
    --rpc-port 8899 \\
    --rpc-bind-address 127.0.0.1 \\
    --no-port-check \\
    --public-rpc-address ${PUBLIC_RPC_ADDRESS:-<FILL_IN_PUBLIC_RPC_ADDRESS>} \\
    --dynamic-port-range 8000-8025 \\
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
  VALIDATOR_SCRIPT+="exec solana-validator \\
    --identity /home/${SOL_USER}/staked_identity.json \\
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
    --full-rpc-api
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
