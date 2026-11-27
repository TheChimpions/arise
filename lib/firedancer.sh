#!/usr/bin/env bash
#
# Firedancer (Hexis Concorde build) definitions for reawaken.sh.
#
# Sourced, never executed, and only after lib/hexis.sh — it reuses that file's
# logging, checksum verification and Hexis defaults. Everything here is pure:
# parsing an Agave validator.sh, picking the build for a CPU, and rendering the
# Firedancer config and unit. SSH transport stays in reawaken.sh.
#
# Reference: https://github.com/hexishq/hexis-validator-docs/tree/concorde-firedancer

# Defaults below are read by the sourcing script, not by this file.
# shellcheck disable=SC2034

FD_DOCS_BRANCH="concorde-firedancer"

# Two builds are handled. The Hexis Concorde is a private release with the arb
# built in. Vanilla Firedancer (github.com/firedancer-io/firedancer) is source
# only: the operator builds it and hands the binary over with --fd-binary. The
# scripts set FD_FLAVOR_LABEL to the second when --vanilla is given, or when
# the config already on the host has no [arb] table.
FD_CONCORDE_LABEL="Firedancer with the Hexis Concorde"
FD_VANILLA_LABEL="vanilla Firedancer"
FD_FLAVOR_LABEL="$FD_CONCORDE_LABEL"
FD_MIN_GLIBC="2.38"

# Control (gRPC) is dialled by both Hexis addresses; only the first reads metrics.
FD_CONTROL_PORT="18082"
FD_CONTROL_ALLOW="188.40.61.182 146.71.98.50"
FD_METRICS_PORT="7999"
FD_METRICS_ALLOW="188.40.61.182"

# Firedancer's default listen ports: gossip, shred, votor, repair client/serve,
# QUIC transactions (regular + quic). Opened when ufw is active.
FD_P2P_UDP_PORTS="8001 8003 8004 8701 8702 9001 9007"

# Jito mainnet values from the Hexis Firedancer docs, used when the source
# validator did not run Jito. A value the source does set is carried over as it
# is; reawaken.sh warns when its authority is not this one.
FD_TIP_PAYMENT_PROGRAM="T1pyyaTNZsKv2WcRAB8oVnk93mLJw2XzjtVYqCsaHqt"
FD_TIP_DISTRIBUTION_PROGRAM="4R3gSG8BpU4t19KYj8CfnbtRpnT8gtk4dvTHxVRwc2r7"
FD_TIP_DISTRIBUTION_AUTHORITY="8F4jGUmxF36vQ6yabnsxX6AQVXdKBhs8kGSUuRKSg8Xt"

# Open-file limit the unit asks for. systemd cannot grant more than fs.nr_open,
# and arise.sh sets that to 1000000, so the sysctl is raised to match first.
FD_NOFILE="1024000"
FD_SYSCTL_FILE="/etc/sysctl.d/90-firedancer.conf"

# Firedancer's 'snapshots' configure stage refuses any other mode on the
# snapshot directory, and cannot repair one that already exists.
FD_SNAPSHOTS_MODE="0700"

FD_LOGROTATE_FILE="/etc/logrotate.d/firedancer"

# HTTP mirror the full snapshot is pre-downloaded from before a restart, and how
# many byte ranges it is fetched in at once. <mirror>/snapshot.tar.bz2 has to
# redirect to the real file name, the way an Agave RPC port does.
FD_SNAPSHOT_MIRROR="https://snapshots.avorio.network/mainnet-beta"
FD_SNAPSHOT_STREAMS="8"
# The file is fetched in pieces of this size, each retried on its own, so one
# dropped connection costs a piece and not the whole download.
FD_SNAPSHOT_CHUNK_MB="1024"
# The download gives up after this many seconds and Firedancer starts anyway.
FD_SNAPSHOT_DEADLINE="900"
# Run by firedancer.service before each start. Root's file, outside the
# validator user's reach, because the unit runs it as root.
FD_PREFETCH_SCRIPT="/usr/local/sbin/firedancer-snapshot-prefetch"
# Asked for the trusted validators' RPC addresses when neither Firedancer's log
# nor a local Agave knows them: a host that has never run a validator.
FD_CLUSTER_RPC="https://api.mainnet-beta.solana.com"

# DoubleZero edge multicast group. Publishing to it needs simple RSS queues
# because the tunnel is GRE.
FD_DOUBLEZERO_GROUP="233.84.178.1"

# ---------------------------------------------------------------------------
# Reading an Agave validator.sh
# ---------------------------------------------------------------------------

# fd_plain_values <what> — passes on, line by line, only values made of the
# characters a path, an address, a URL or a pubkey is made of. What these
# scripts read out of validator.sh and the TOML files on the host is written by
# the validator user and later put into commands that run as root, so a value
# carrying shell syntax is dropped here, with a warning, and never gets there.
# One pair of quotes around a value is taken off first.
fd_plain_values() {
  local line
  while IFS= read -r line; do
    case "$line" in
      \"*\") line="${line#\"}"; line="${line%\"}" ;;
      \'*\') line="${line#\'}"; line="${line%\'}" ;;
    esac
    [[ -z "$line" ]] && continue
    # arise.sh's <FILL_IN_...> placeholders go through without their brackets,
    # so the caller can still say which value was never filled in.
    while [[ "$line" =~ \<(FILL_IN_[A-Z_]+)\> ]]; do
      line="${line/"<${BASH_REMATCH[1]}>"/${BASH_REMATCH[1]}}"
    done
    if [[ "$line" =~ ^[A-Za-z0-9._/:,@+=%-]+$ ]]; then
      printf '%s\n' "$line"
    else
      printf '[WARN]  Ignoring %s: it is not a plain value\n' "$1" >&2
    fi
  done
}

# Every value given for <flag> in <validator.sh text>, one per line. Comment
# lines are skipped; a trailing line-continuation backslash is not part of the
# value, with or without a space before it.
fd_vsh_flag_all() {
  local text="$1" flag="$2"
  grep -v '^[[:space:]]*#' <<<"$text" \
    | grep -oE -- "(^|[[:space:]])${flag}([[:space:]]+|=)[^[:space:]\\\\]+" \
    | sed -E "s/^[[:space:]]*${flag}[[:space:]=]+//" \
    | fd_plain_values "${flag} in validator.sh" || true
}

fd_vsh_flag() { fd_vsh_flag_all "$1" "$2" | head -1; }

fd_vsh_has() {
  grep -v '^[[:space:]]*#' <<<"$1" | grep -qE -- "(^|[[:space:]])$2([[:space:]=\\\\]|\$)"
}

# fd_key_info_cmd <keypair path>... — a command for the host that prints, per
# file, "<path>|<what it resolves to>|<pubkey>". The pubkey is the last 32 bytes
# of the keypair in base58, worked out on the host so no key leaves it. An
# identity that is a symlink is how a host is switched between its staked and
# unstaked key, so the target matters as much as the name.
fd_key_info_cmd() {
  local py='import json,sys
b=bytes(json.load(open(sys.argv[1])))[32:]
a="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n=int.from_bytes(b,"big");s=""
while n:
    n,r=divmod(n,58);s=a[r]+s
print("1"*(len(b)-len(b.lstrip(bytes(1))))+s)'
  printf ': key-info; for f in %s; do echo "$f|$(readlink -f "$f")|$(python3 -c '"'%s'"' "$f" 2>/dev/null)"; done' "$*" "$py"
}

# fd_key_label <key info text> <path> -> "<path> -> <target>  <pubkey>", with
# whatever of the two the host could tell us.
fd_key_label() {
  local line target pubkey out="$2"
  line=$(grep -m1 -F "$2|" <<<"$1" || true)
  target=$(cut -d'|' -f2 <<<"$line")
  pubkey=$(cut -d'|' -f3 <<<"$line")
  [[ -n "$target" && "$target" != "$2" ]] && out+=" -> ${target}"
  [[ -n "$pubkey" ]] && out+="  ${pubkey}"
  echo "$out"
}

# hexis | jito | agave — what the startup script is running today
fd_detect_source() {
  local text="$1"
  if fd_vsh_has "$text" "--arb-config"; then
    echo hexis
  elif fd_vsh_has "$text" "--block-engine-url" || fd_vsh_has "$text" "--tip-payment-program-pubkey"; then
    echo jito
  else
    echo agave
  fi
}

# Value of a string key in arb-config.toml text
fd_toml_get() {
  grep -m1 -E "^[[:space:]]*$2[[:space:]]*=" <<<"$1" | sed -e 's/^[^=]*=[[:space:]]*"//' -e 's/".*//' \
    | fd_plain_values "'$2' in the config on the host" || true
}

# ---------------------------------------------------------------------------
# Build selection
# ---------------------------------------------------------------------------

# fd_pick_asset <vendor_id> <cpu family> <cpu flags>
# The zen builds die with SIGILL on anything older than their target, so this
# only picks one when the CPU is positively that generation.
fd_pick_asset() {
  local vendor="$1" family="$2" flags=" $3 "
  if [[ "$flags" != *" avx2 "* ]]; then
    return 1
  fi
  if [[ "$vendor" == "AuthenticAMD" && "$family" == "26" ]]; then
    echo "firedancer-linux-amd64-zen5"
  elif [[ "$vendor" == "AuthenticAMD" && "$family" == "25" && "$flags" == *" avx512f "* ]]; then
    echo "firedancer-linux-amd64-zen4"
  else
    echo "firedancer-linux-amd64"
  fi
}

# 0 when dotted version $1 >= $2
fd_version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# fd_download <tag> <asset> <dir> — echoes the local path. Logging goes to
# stderr so the caller's command substitution gets only the path.
fd_download() {
  local tag="$1" asset="$2" dir="$3"
  gh release download "$tag" --repo "$HEXIS_REPO" \
    --pattern "$asset" --pattern '*checksums.txt' \
    --dir "$dir" --clobber >&2
  [[ -f "${dir}/${asset}" ]] || {
    log_error "Release ${tag} has no ${asset} asset" >&2
    return 1
  }
  hexis_verify_checksum "$dir" "$asset" >&2 || return 1
  echo "${dir}/${asset}"
}

# The Concorde's own config tables, every key at this build's default. Kept in
# the Hexis docs, not here: Firedancer refuses to boot on a key it does not
# know, so a vendored copy would rot with the first release that renames one.
fd_fetch_concorde_tables() {
  gh api "repos/${HEXIS_REPO}/contents/config.toml.example?ref=${FD_DOCS_BRANCH}" \
    -H "Accept: application/vnd.github.raw"
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

# "a,b" -> TOML array body on separate lines, indented for a table
fd_toml_array() {
  local IFS=, item first=true
  for item in $1; do
    item="${item//[[:space:]]/}"
    [[ -z "$item" ]] && continue
    $first || printf ',\n'
    printf '        "%s"' "$item"
    first=false
  done
  $first || printf ',\n'
}

# Renders the Firedancer side of the config from FDC_* variables:
#   FDC_USER FDC_BASE FDC_IDENTITY FDC_VOTE_ACCOUNT FDC_AUTH_VOTERS
#   FDC_SNAPSHOTS FDC_ACCOUNTS FDC_LOG FDC_ENTRYPOINTS FDC_GENESIS_HASH
#   FDC_SHRED_VERSION FDC_INTERFACE FDC_RSS_SIMPLE FDC_SNAPSHOT_ALLOW_LIST
#   FDC_BUNDLE_URL FDC_TIP_PAY FDC_TIP_DIST FDC_TIP_AUTH FDC_COMMISSION_BPS
#   FDC_SHRED_DESTS FDC_METRICS_ADDR FDC_RPC FDC_VANILLA
# Top-level keys come first: Firedancer rejects one that sits below a table.
fd_render_base_config() {
  local generator="$1"
  cat <<EOF
# Generated by ${generator} — ${FD_FLAVOR_LABEL}.
# Checked on the host with 'firedancer mem' before it is put in place.

name = "fd1"
user = "${FDC_USER}"
# The Solana Foundation Delegation Program requires telemetry.
telemetry = true

[paths]
    base = "${FDC_BASE}"
    identity_key = "${FDC_IDENTITY}"
    vote_account = "${FDC_VOTE_ACCOUNT}"
EOF
  if [[ -n "${FDC_AUTH_VOTERS:-}" ]]; then
    printf '    authorized_voter_paths = [\n%s    ]\n' "$(fd_toml_array "$FDC_AUTH_VOTERS")
"
  fi
  cat <<EOF
    snapshots = "${FDC_SNAPSHOTS}"
    accounts = "${FDC_ACCOUNTS}"

[log]
    path = "${FDC_LOG}"

[gossip]
    entrypoints = [
$(fd_toml_array "$FDC_ENTRYPOINTS")
    ]

[consensus]
    expected_genesis_hash = "${FDC_GENESIS_HASH}"
EOF
  [[ -n "${FDC_SHRED_VERSION:-}" ]] && echo "    expected_shred_version = ${FDC_SHRED_VERSION}"
  cat <<EOF
    # Needed up to 26.10.x, where it is off by default and the validator stops once
    # the snapshot loads. From 26.11 Alpenglow is always on and this is ignored.
    alpenglow = true
EOF

  if [[ -n "${FDC_SNAPSHOT_ALLOW_LIST:-}" ]]; then
    cat <<EOF

# Snapshots only from the validators the Agave setup already trusted. If boot
# stops on "timed out waiting for incremental snapshot peers", they all refused
# (HTTP 429): list more, or re-run with --snapshot-allow-any.
[snapshots.sources.gossip]
    allow_any = false
    allow_list = [
$(fd_toml_array "$FDC_SNAPSHOT_ALLOW_LIST")
    ]
EOF
  fi

  if [[ -n "${FDC_INTERFACE:-}" ]]; then
    printf '\n[net]\n    interface = "%s"\n' "$FDC_INTERFACE"
  fi
  if [[ "${FDC_RSS_SIMPLE:-false}" == "true" ]]; then
    cat <<EOF

# DoubleZero runs over GRE, where dedicated queues do not work.
[net.xdp]
    rss_queue_mode = "simple"
EOF
  fi

  if [[ -n "${FDC_BUNDLE_URL:-}" ]]; then
    cat <<EOF

[tiles.bundle]
    enabled = true
    url = "${FDC_BUNDLE_URL}"
    tip_distribution_program_addr = "${FDC_TIP_DIST}"
    tip_payment_program_addr = "${FDC_TIP_PAY}"
    tip_distribution_authority = "${FDC_TIP_AUTH}"
    commission_bps = ${FDC_COMMISSION_BPS}
EOF
  fi

  if [[ -n "${FDC_SHRED_DESTS:-}" ]]; then
    cat <<EOF

# Leader list only: these get the shreds of our own blocks. The retransmit list
# would send every relayed shred, and DoubleZero removes a publisher that does.
[tiles.shred]
    additional_shred_destinations_leader = [
$(fd_toml_array "$FDC_SHRED_DESTS")
    ]
EOF
  fi

  if [[ "${FDC_VANILLA:-false}" == "true" ]]; then
    cat <<EOF

# Prometheus metrics. Nothing outside this host needs them unless you say so.
[tiles.metric]
    prometheus_listen_address = "${FDC_METRICS_ADDR}"
    prometheus_listen_port = ${FD_METRICS_PORT}
EOF
  else
    cat <<EOF

# Hexis reads these from ${FD_METRICS_ALLOW} only — firewall the port.
[tiles.metric]
    prometheus_listen_address = "${FDC_METRICS_ADDR}"
    prometheus_listen_port = ${FD_METRICS_PORT}
EOF
  fi

  if [[ "${FDC_VANILLA:-false}" == "true" && "${FDC_RPC:-false}" != "true" ]]; then
    cat <<EOF

# Vanilla Firedancer runs the RPC server unless told not to. Off here, as on the Concorde
# build; --enable-rpc turns it on.
[tiles.rpc]
    enabled = false
EOF
  elif [[ "${FDC_VANILLA:-false}" == "true" ]]; then
    cat <<EOF

[tiles.rpc]
    enabled = true
EOF
  elif [[ "${FDC_RPC:-false}" == "true" ]]; then
    cat <<EOF

# The Concorde build turns RPC off and gives its core to the arb tiles.
[tiles.rpc]
    enabled = true
EOF
  fi
}

# fd_render_concorde_tables <example text> <signer path> <jupiter ledger> <okx ledger>
# Sets only the keys this install owns; every other key keeps the build default.
fd_render_concorde_tables() {
  local text="$1" signer="$2" jup="$3" okx="$4"
  sed -E \
    -e "s|^([[:space:]]*signer_key_path[[:space:]]*=[[:space:]]*).*|\\1\"${signer}\"|" \
    -e "s|^([[:space:]]*jupiter_token_ledger[[:space:]]*=[[:space:]]*).*|\\1\"${jup}\"|" \
    -e "s|^([[:space:]]*okx_token_ledger[[:space:]]*=[[:space:]]*).*|\\1\"${okx}\"|" \
    <<<"$text"
}

# Root shell lines that make fs.nr_open large enough for the unit's LimitNOFILE,
# now and after a reboot. Without it the unit dies at step LIMITS before
# Firedancer runs. Only ever raises the value.
fd_render_nofile_sysctl() {
  cat <<EOF
if [ "\$(sysctl -n fs.nr_open)" -lt ${FD_NOFILE} ]; then
  echo "fs.nr_open = ${FD_NOFILE}" > ${FD_SYSCTL_FILE}
  sysctl -q -w fs.nr_open=${FD_NOFILE}
  echo "fs.nr_open raised to ${FD_NOFILE} (${FD_SYSCTL_FILE})"
fi
EOF
}

# fd_render_logrotate_install <log path> — root shell text that installs daily
# rotation for the Firedancer log. copytruncate because Firedancer keeps the
# file open and has no signal to reopen it. Same schedule arise.sh gives Agave.
fd_render_logrotate_install() {
  cat <<EOF
cat > ${FD_LOGROTATE_FILE} <<'LOGEOF'
$1 {
    daily
    rotate 7
    dateext
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGEOF
echo "log rotation: $1 (${FD_LOGROTATE_FILE})"
EOF
}

# fd_render_snapshot_seed <agave snapshot dir> <firedancer snapshot dir> <user>
# Root shell text that puts Agave's newest full snapshot, and the newest
# incremental built on it, into Firedancer's snapshot directory. The two clients
# read the same files, and Firedancer starts from a local full snapshot when a
# trusted peer still serves incrementals on that same slot, which saves the
# full download. It prunes its own directory, so it gets links (or copies when
# a link is not possible) rather than Agave's directory itself.
fd_render_snapshot_seed() {
  local from="$1" to="$2" user="$3"
  cat <<EOF
seed_full=\$(cd "${from}" 2>/dev/null && ls snapshot-*.tar.zst 2>/dev/null | sort -t- -k2,2n | tail -1)
if [ -z "\$seed_full" ]; then
  echo "no Agave snapshot in ${from} — Firedancer downloads one"
else
  seed_slot=\${seed_full#snapshot-}; seed_slot=\${seed_slot%%-*}
  have_slot=\$(cd "${to}" 2>/dev/null && ls snapshot-*.tar.zst 2>/dev/null | sort -t- -k2,2n | tail -1 | cut -d- -f2)
  if [ "\${have_slot:-0}" -ge "\$seed_slot" ]; then
    echo "Firedancer already holds a full snapshot at slot \$have_slot — Agave's (\$seed_slot) is not newer"
  else
    seed_inc=\$(cd "${from}" && ls incremental-snapshot-\${seed_slot}-*.tar.zst 2>/dev/null | sort -t- -k4,4n | tail -1)
    for f in "\$seed_full" \$seed_inc; do
      [ -e "${to}/\$f" ] && continue
      if [ "\$(ls -ld "${from}/\$f" | awk '{print \$3}')" = "${user}" ] && ln "${from}/\$f" "${to}/\$f" 2>/dev/null; then
        echo "seeded \$f (linked from ${from})"
      else
        cp "${from}/\$f" "${to}/\$f"
        $(fd_chown_cmd "$user") "${to}/\$f"
        echo "seeded \$f (copied from ${from})"
      fi
    done
  fi
fi
EOF
}

# fd_render_snapshot_prefetch <mirror url> <firedancer snapshot dir> <user>
#                             <config> <log> <agave snapshot dir or ""> <agave rpc port or "none">
# Shell text for root that downloads the current full snapshot from an HTTP
# mirror into Firedancer's snapshot directory. The start that follows then loads
# it from disk and fetches only the incremental. It is used two ways: run by
# cutover and upgrade while the validator is still up, and installed as the
# unit's pre-start step (fd_render_prefetch_install), where it is what a crash
# or a reboot goes through.
#
# It downloads only when it has to: Firedancer makes no snapshots of its own, so
# the one on disk is usable exactly when it is the full snapshot the cluster is
# on now. The mirror is a third party, so its file is taken only when a
# validator on the config's snapshot allow list serves a full snapshot with the
# same slot and hash; that also means those peers have incrementals built on it,
# which is what makes Firedancer use the local file. The check is on the name:
# the bytes are not verified here.
#
# The file comes in pieces, several at a time, each written straight to its
# place and retried by itself. Any failure, or running past the deadline, leaves
# things as they were and Firedancer downloads from its peers as before; the
# step never fails the run.
fd_render_snapshot_prefetch() {
  cat <<EOF
PF_MIRROR="$1"
PF_TO="$2"
PF_USER="$3"
PF_CONFIG="$4"
PF_LOG="$5"
PF_AGAVE="$6"
PF_RPC_PORT="${7:-8899}"
PF_CLUSTER_RPC="${FD_CLUSTER_RPC}"
PF_STREAMS="\${PF_STREAMS:-${FD_SNAPSHOT_STREAMS}}"
PF_CHUNK_MB="\${PF_CHUNK_MB:-${FD_SNAPSHOT_CHUNK_MB}}"
PF_DEADLINE="\${PF_DEADLINE:-${FD_SNAPSHOT_DEADLINE}}"
EOF
  cat <<'EOF'
# pf_resolve <name or ""> — the mirror's download URL, which is signed and
# short-lived. With a name, only when the mirror still serves that file.
pf_resolve() {
  local u n
  u=$(curl -sS --connect-timeout 5 -m 20 -A curl -o /dev/null -w '%{redirect_url}' "${PF_MIRROR}/snapshot.tar.bz2" 2>/dev/null || true)
  n=${u%%\?*}; n=${n##*/}
  [ -n "$u" ] || return 1
  [ -z "$1" ] || [ "$n" = "$1" ] || return 1
  printf '%s' "$u"
}

# pf_worker <n> — fetches pieces n, n+streams, n+2*streams, ... one after the
# other, each into its place in the file. A piece that comes up short is asked
# for again, with a fresh URL, three times before the worker gives up.
pf_worker() {
  local i="$1" url="" born=0 start len got try now
  while [ "$i" -lt "$PF_NCHUNKS" ]; do
    start=$((i * PF_CHUNK)); len=$PF_CHUNK
    [ $((start + len)) -gt "$PF_SIZE" ] && len=$((PF_SIZE - start))
    try=0; got=""
    while [ "$try" -lt 3 ]; do
      now=$(date +%s)
      [ "$now" -ge "$PF_DEADLINE_AT" ] && return 1
      if [ -z "$url" ] || [ $((now - born)) -ge 240 ]; then
        if ! url=$(pf_resolve "$PF_NAME"); then
          url=""; try=$((try + 1)); sleep "${PF_RETRY_SECONDS:-2}"; continue
        fi
        born=$now
      fi
      got=$(curl -fsS -A curl -m $((PF_DEADLINE_AT - now)) --speed-limit 1048576 --speed-time 30 \
              -r "${start}-$((start + len - 1))" -o - "$url" 2>/dev/null \
            | LC_ALL=C dd of="$PF_FILE" bs=1048576 seek=$((i * PF_CHUNK_MB)) conv=notrunc 2>&1 | awk '/bytes/ { print $1; exit }')
      [ "$got" = "$len" ] && break
      url=""; try=$((try + 1)); sleep "${PF_RETRY_SECONDS:-2}"
    done
    [ "$got" = "$len" ] || return 1
    i=$((i + PF_STREAMS))
  done
}

pf_main() {
  local url name slot have allow peers k a rpc got asked=0 agree=0 avail stage w pid pids="" ok=true keep f b s
  if ! url=$(pf_resolve ""); then
    echo "snapshot pre-download: ${PF_MIRROR} did not answer — skipped"
    return 0
  fi
  name=${url%%\?*}; name=${name##*/}
  if ! printf '%s' "$name" | grep -Eq '^snapshot-[0-9]+-[1-9A-HJ-NP-Za-km-z]{32,44}\.tar\.zst$'; then
    echo "snapshot pre-download: ${PF_MIRROR} named no snapshot — skipped"
    return 0
  fi
  slot=$(printf '%s' "$name" | cut -d- -f2)
  have=$(cd "$PF_TO" 2>/dev/null && ls snapshot-*.tar.zst 2>/dev/null | sort -t- -k2,2n | tail -1 | cut -d- -f2)
  if [ "${have:-0}" -ge "$slot" ]; then
    echo "snapshot pre-download: the full snapshot at slot ${have} is already on disk — nothing to fetch"
    return 0
  fi
  if [ -n "$PF_AGAVE" ] && ls "$PF_AGAVE"/snapshot-"$slot"-*.tar.zst >/dev/null 2>&1; then
    echo "snapshot pre-download: Agave already holds the full snapshot at slot ${slot} — it is handed over instead"
    return 0
  fi

  # Where the trusted validators serve snapshots: Firedancer logs each one's RPC
  # address. Before its first run, Agave's own RPC knows them; on a host that
  # has run neither, a public RPC endpoint does.
  allow=$(sed -n '/allow_list = \[/,/\]/p' "$PF_CONFIG" 2>/dev/null | grep -oE '[1-9A-HJ-NP-Za-km-z]{32,44}' || true)
  peers=""
  for k in $allow; do
    a=$(grep -a "allowed gossip peer added with public key \`$k\`" "$PF_LOG" 2>/dev/null | tail -1 | sed -nE 's/.*RPC address `([0-9.]+:[0-9]+)`.*/\1/p')
    [ -n "$a" ] && peers="$peers $a"
  done
  for rpc in "http://127.0.0.1:${PF_RPC_PORT}" "$PF_CLUSTER_RPC"; do
    [ -z "$peers" ] && [ -n "$allow" ] || break
    case "$rpc" in ""|*:none) continue ;; esac
    peers=$(curl -s --connect-timeout 5 -m 20 -X POST -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"getClusterNodes"}' "$rpc" 2>/dev/null \
      | PF_ALLOW="$allow" python3 -c '
import json, os, re, sys
allow = set(os.environ["PF_ALLOW"].split())
try:
    nodes = json.load(sys.stdin)["result"]
except Exception:
    nodes = []
print(" ".join(n["rpc"] for n in nodes if n.get("pubkey") in allow and re.fullmatch(r"[0-9.]+:[0-9]+", n.get("rpc") or "")))' 2>/dev/null || true)
  done
  for a in $peers; do
    got=$(curl -sS --connect-timeout 5 -m 6 -o /dev/null -r 0-0 -w '%{redirect_url}' "http://${a}/snapshot.tar.bz2" 2>/dev/null || true)
    got=${got##*/}
    [ -n "$got" ] && asked=$((asked + 1))
    [ "$got" = "$name" ] && agree=$((agree + 1))
  done
  if [ "$agree" -lt 1 ]; then
    echo "snapshot pre-download: no trusted validator serves ${name} (${asked} answered) — not taking it from the mirror"
    return 0
  fi
  echo "snapshot pre-download: ${agree} of ${asked} trusted validators serve ${name}"

  PF_NAME="$name"
  PF_SIZE=$(curl -sS --connect-timeout 5 -m 20 -A curl -r 0-0 -o /dev/null -D - "$url" 2>/dev/null | tr -d '\r' | sed -nE 's/^[Cc]ontent-[Rr]ange: bytes 0-0\/([0-9]+)$/\1/p')
  if [ -z "$PF_SIZE" ]; then
    echo "snapshot pre-download: the mirror does not serve byte ranges — skipped"
    return 0
  fi
  avail=$(df -Pk "$PF_TO" | awk 'NR==2 {print $4}')
  if [ "$avail" -lt $((PF_SIZE / 1024 * 11 / 10)) ]; then
    echo "snapshot pre-download: not enough room in ${PF_TO} for $((PF_SIZE / 1073741824)) GiB — skipped"
    return 0
  fi

  stage="${PF_TO}.fetch"
  rm -rf "$stage"; mkdir -p "$stage"
  PF_FILE="${stage}/${name}"
  PF_CHUNK=$((PF_CHUNK_MB * 1048576))
  PF_NCHUNKS=$(( (PF_SIZE + PF_CHUNK - 1) / PF_CHUNK ))
  PF_DEADLINE_AT=$(( $(date +%s) + PF_DEADLINE ))
  : > "$PF_FILE"
  trap 'kill $pids 2>/dev/null; rm -rf "$stage"; exit 0' TERM INT
  w=0
  while [ "$w" -lt "$PF_STREAMS" ] && [ "$w" -lt "$PF_NCHUNKS" ]; do
    pf_worker "$w" &
    pids="$pids $!"
    w=$((w + 1))
  done
  echo "snapshot pre-download: fetching $((PF_SIZE / 1048576)) MB in ${PF_NCHUNKS} pieces, ${w} at a time"
  while [ -n "$(jobs -rp)" ]; do
    sleep "${PF_PROGRESS_SECONDS:-15}"
    [ -n "$(jobs -rp)" ] && echo "  $(du -sm "$stage" | cut -f1) of $((PF_SIZE / 1048576)) MB"
  done
  for pid in $pids; do wait "$pid" || ok=false; done
  trap - TERM INT
  if $ok; then
    [ "$(wc -c < "$PF_FILE" | tr -d ' ')" = "$PF_SIZE" ] || ok=false
    [ "$(head -c 4 "$PF_FILE" | od -An -tx1 | tr -d ' \n')" = "28b52ffd" ] || ok=false
  fi
  if ! $ok; then
    rm -rf "$stage"
    echo "snapshot pre-download: the download did not complete — discarded, Firedancer downloads from its peers"
    return 0
  fi
  chmod 600 "$PF_FILE"
  chown "${PF_USER}:$(id -gn "${PF_USER}")" "$PF_FILE"
  mv "$PF_FILE" "${PF_TO}/${name}"
  rm -rf "$stage"
  echo "snapshot pre-download: ${name} is in ${PF_TO}"

  # Each full snapshot is over 100 GB and nothing else clears them out. Keep
  # this one and the one before it; older ones go, with their incrementals.
  keep=" $(cd "$PF_TO" && ls snapshot-*.tar.zst 2>/dev/null | sort -t- -k2,2n | tail -2 | cut -d- -f2 | tr '\n' ' ')"
  for f in "$PF_TO"/snapshot-*.tar.zst "$PF_TO"/incremental-snapshot-*.tar.zst; do
    [ -e "$f" ] || continue
    b=$(basename "$f"); s=$(printf '%s' "${b#incremental-}" | cut -d- -f2)
    case "$keep" in
      *" $s "*) ;;
      *) rm -f "$f" && echo "snapshot pre-download: removed ${b}, older than the last two full snapshots" ;;
    esac
  done
}
pf_main || echo "snapshot pre-download: failed — Firedancer downloads from its peers"
EOF
}

# fd_render_prefetch_install <on|off> <mirror url> <firedancer snapshot dir>
#                            <user> <config> <log>
# Root shell text that installs the pre-download as the script the unit runs
# before each start, or takes it away. The script is root's: the unit runs it
# as root, so the validator user must not be able to change it.
fd_render_prefetch_install() {
  if [[ "$1" != "on" ]]; then
    echo "rm -f ${FD_PREFETCH_SCRIPT}"
    return 0
  fi
  cat <<EOF
cat > ${FD_PREFETCH_SCRIPT}.new <<'FDPREFETCHEOF'
#!/bin/bash
# Written by reawaken.sh. firedancer.service runs this before each start: when
# the full snapshot on disk is no longer the one the cluster is on, it is
# fetched from a mirror first, which takes minutes where Firedancer's own
# download from its peers takes about an hour. It never stops a start.
$(fd_render_snapshot_prefetch "$2" "$3" "$4" "$5" "$6" "" none)
exit 0
FDPREFETCHEOF
chown root:root ${FD_PREFETCH_SCRIPT}.new
chmod 755 ${FD_PREFETCH_SCRIPT}.new
mv ${FD_PREFETCH_SCRIPT}.new ${FD_PREFETCH_SCRIPT}
echo "pre-start snapshot download installed: ${FD_PREFETCH_SCRIPT} (mirror $2)"
EOF
}

# fd_chown_cmd <user> — root shell text that hands files to a user and that
# user's own group. The group is named outright: uutils chown (Ubuntu 25.10 and
# later) leaves it as it was for "user:", and Firedancer refuses to start on a
# directory with the wrong gid.
fd_chown_cmd() { printf 'chown %s:$(id -gn %s)' "$1" "$1"; }

# fd_render_unit <binary> <config> <agave service> [pre-start snapshot download: on|off]
# Conflicts= makes systemd stop the Agave unit when this one starts and the
# other way round, so the two can never run the same identity at once.
fd_render_unit() {
  local bin="$1" config="$2" agave_service="$3" prefetch=""
  if [[ "${4:-off}" == "on" ]]; then
    # After configure: the huge pages are taken before the download fills the
    # page cache. "-" lets the start go ahead whatever the script does, and the
    # start timeout has to outlast the download's own deadline.
    prefetch="# Fetch the full snapshot from the mirror when the one on disk is too old.
ExecStartPre=-${FD_PREFETCH_SCRIPT}
TimeoutStartSec=$((FD_SNAPSHOT_DEADLINE * 2))
"
  fi
  cat <<EOF
[Unit]
Description=${FD_FLAVOR_LABEL}
After=network-online.target
Wants=network-online.target
Conflicts=${agave_service}.service
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
Type=simple
User=root
# Huge page mounts do not survive a reboot, so configure runs before each start.
ExecStartPre=${bin} configure init all --config ${config}
${prefetch}ExecStart=${bin} run --config ${config}
LimitNOFILE=${FD_NOFILE}
LimitMEMLOCK=infinity
TimeoutStopSec=120
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}
