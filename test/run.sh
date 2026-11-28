#!/usr/bin/env bash
#
# Test suite for arise.sh / ascend.sh / lib/hexis.sh. No external dependencies.
#
#   ./test/run.sh            run everything
#   ./test/run.sh patcher    run only cases whose name matches
#
# ssh/scp/gh are stubbed (test/stubs); host responses come from test/fixtures.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="${1:-}"
PASS=0; FAIL=0; CURRENT=""
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="${ROOT}/test/stubs:$PATH"
export STUB_LOG=/dev/null
# The Hexis credentials are not in the repository. Tests get made-up ones from
# the environment, and never read a real hexis.env that may sit beside the scripts.
export HEXIS_ENV_FILE="$WORK/no-hexis.env"
export HEXIS_JUP_KEY="test-jup-key"
export SOLANA_METRICS_CONFIG_ARB="host=https://metrics.test,db=d,u=u,p=test-pw"

# Fixed inputs so output is stable
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key" <<<y >/dev/null 2>&1
echo '[1,2,3]' > "$WORK/id.json"
echo '[9,9,9]' > "$WORK/signer.json"
printf 'FAKE' > "$WORK/binary"

# --- assertions -------------------------------------------------------------
it()  { CURRENT="$1"; }
_ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$CURRENT"; }
_fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$CURRENT" "$1"; }

assert_contains() {
  if grep -qF -- "$2" <<<"$1"; then _ok; else _fail "expected to find: $2"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" <<<"$1"; then _fail "expected NOT to find: $2"; else _ok; fi
}
assert_eq() {
  if [[ "$1" == "$2" ]]; then _ok; else _fail "expected [$2], got [$1]"; fi
}
# file_mode <path> — permission bits in octal. GNU stat first: on Linux
# 'stat -f' is a different command that succeeds and prints something else.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# assert_order <text> <first> <second> — both are there, and the first line
# holding <first> comes before the first line holding <second>
assert_order() {
  local a b
  a=$(grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1)
  b=$(grep -nF -- "$3" <<<"$1" | head -1 | cut -d: -f1)
  if [[ -z "$a" ]]; then _fail "expected to find: $2"
  elif [[ -z "$b" ]]; then _fail "expected to find: $3"
  elif (( a < b )); then _ok
  else _fail "expected [$2] (line $a) before [$3] (line $b)"; fi
}
assert_file_missing() {
  if [[ -e "$1" ]]; then _fail "expected $1 not to exist"; else _ok; fi
}

should_run() { [[ -z "$FILTER" || "$1" == *"$FILTER"* ]]; }

arise() { ( cd "$ROOT" && ./arise.sh "$@" ) 2>&1; }
ascend() { ( cd "$ROOT" && ./ascend.sh "$@" ) 2>&1; }
system() { ( cd "$ROOT" && ./system.sh "$@" ) 2>&1; }

# fd_host <file> <facts overrides, \n separated> <validator.sh body lines, \n separated>
# Builds the stub responses for a host: its facts, validator.sh, arb-config.toml.
fd_host() {
  local file="$1" facts="$2" body="$3"
  local base='vendor=AuthenticAMD\nfamily=25\nmodel=AMD EPYC 9254 24-Core Processor\nflags=avx2 avx512f \nglibc=2.39\nmem_gib=377\nip=9.9.9.9\ndoublezero=no\nufw=active\nagave_active=active\nagave_enabled=enabled\nfd_active=inactive\nfd_enabled=disabled\nfd_unit=no\nfd_release=\nfd_version=\nfd_config=no\nfd_signer=no\nvsh=yes'
  {
    printf '%s\n' '*echo ok*|ok'
    printf '%s\n' "*host-facts*|${facts}${facts:+\\n}${base}"
    printf '%s\n' "*cat /home/sol/validator.sh*|#!/bin/bash\\nexec agave-validator \\\\\\\\\\n    --identity /home/sol/identity.json \\\\\\\\\\n    --authorized-voter /home/sol/staked_identity.json \\\\\\\\\\n    --vote-account VoTe111 \\\\\\\\\\n    --ledger /mnt/ledger \\\\\\\\\\n    --accounts /mnt/accounts \\\\\\\\\\n    --entrypoint entrypoint.mainnet-beta.solana.com:8001 \\\\\\\\\\n    --expected-genesis-hash 5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d \\\\\\\\\\n${body}    --limit-ledger-size"
    printf '%s\n' '*cat /home/sol/hexis/arb-config.toml*|[engine]\nsigner_path    = "/home/sol/hexis/arb_signer_keypair.json"\njupiter_token_ledger = "JUPfromAgave"\nokx_token_ledger = "OKXfromAgave"'
    printf '%s\n' '*key-info*|/home/sol/identity.json|/home/sol/unstaked_identity.json|UNSTAKEDpk\n/home/sol/staked_identity.json|/home/sol/staked_identity.json|STAKEDpk'
    printf '%s\n' '*cat /home/sol/firedancer/config.toml*|name = "fd1"\nuser = "sol"\n[paths]\n    base = "/mnt/ledger/firedancer"\n    snapshots = "/mnt/ledger/firedancer/snapshots"'
  } > "$file"
}
L='\\\\\\\\\\n'   # one validator.sh line break, as the stub file needs it
KV="    --known-validator K1 ${L}    --known-validator K2 ${L}    --known-validator K3 ${L}"
JITO="    --block-engine-url https://ny.mainnet.block-engine.jito.wtf ${L}    --commission-bps 1000 ${L}    --merkle-root-upload-authority AUTH111 ${L}    --shred-receiver-address 233.84.178.1:7733,1.2.3.4:1002${L}"
HEXIS="    --arb-config /home/sol/hexis/arb-config.toml ${L}"

# Common argument sets
arise_base=(--host 1.2.3.4 --vote-account 7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2 --network mainnet --commission-bps 0
            --jito-region frankfurt --no-auto-disks --no-xdp --dry-run)

# ---------------------------------------------------------------------------
group() { printf '\n%s\n' "$1"; }

# === lib: config rendering =================================================
if should_run "render"; then
group "lib/hexis.sh rendering"
  # shellcheck source=../lib/hexis.sh
  source "${ROOT}/lib/hexis.sh"

  out="$(hexis_render_arb_config arise.sh /home/sol/hexis /home/sol/hexis/s.json true)"

  it "renders the Hexis program id"
  assert_contains "$out" 'program_id     = "FQXqWuMPdQ7PzPu5y7eJSFBrNQ6WQL5KWzNQ6pLNBfdq"'

  it "renders the shared profit pool, which we hold no key for"
  assert_contains "$out" 'profit_wallet  = "FevX9jr7HQ43anpFpUA88M8eA1Xk22fLVqPG6YEERr4h"'

  it "renders the supplied signer path"
  assert_contains "$out" 'signer_path    = "/home/sol/hexis/s.json"'

  it "includes [flash_loan] by default"
  assert_contains "$out" 'marginfi_account = "93rXRLxa3nJ6WkEbsxHCPS6doffoVf4yXb8hxWaphPsw"'

  it "includes [control] when control is on"
  assert_contains "$out" 'bind = "0.0.0.0:18082"'

  it "omits [control] when control is off"
  assert_not_contains "$(hexis_render_arb_config x /h /s.json false)" '[control]'

  it "omits [flash_loan] when the marginfi account is empty"
  assert_not_contains "$(HEXIS_MARGINFI_ACCOUNT='' hexis_render_arb_config x /h /s.json true)" 'marginfi_account'

  it "omits signer_path when no signer is known"
  assert_not_contains "$(hexis_render_arb_config x /h '' true)" 'signer_path'

  # base_mints and marginfi_banks are positional: entry N of one maps to entry N
  # of the other. A mismatch in count is a silent misconfiguration on chain.
  it "has one marginfi bank per base mint"
  assert_eq "$(tr -cd ',' <<<"$HEXIS_BASE_MINTS" | wc -c | tr -d ' ')" \
            "$(tr -cd ',' <<<"$HEXIS_MARGINFI_BANKS" | wc -c | tr -d ' ')"

  it "quotes and splits comma lists"
  assert_eq "$(hexis_toml_list 'a, b,c')" '"a", "b", "c"'

  it "renders arb-enable.sh with the ledger path"
  assert_contains "$(hexis_render_arb_enable /home/sol/hexis /mnt/ledger)" 'LEDGER=/mnt/ledger'

  it "renders arb-enable.sh with the OKX token ledger"
  assert_contains "$(hexis_render_arb_enable /home/sol/hexis /mnt/ledger)" \
    'arb okx-token-ledger set FZ2tnmpsGG2JxruyAPRrSBFARGAQtcVvTmt8z83kM5yC'

  # Run the rendered script against fake binaries: one whose `arb set` still
  # has --program-size (<= v4.3.0) and one where it is gone (v4.3.2+concorde.1+).
  # Each records the calls it gets and rejects --program-size like clap would.
  fake_validator() {
    local dir="$1" has_flag="$2"
    mkdir -p "$dir"
    cat > "$dir/agave-validator" <<FAKE
#!/usr/bin/env bash
if [[ "\$*" == "arb set --help" ]]; then
  echo "        --enabled <BOOL>"
  $has_flag && echo "        --program-size <BYTES>"
  exit 0
fi
echo "\$*" >> "$dir/calls"
if [[ "\$*" == *--program-size* ]] && ! $has_flag; then
  echo "error: Found argument '--program-size' which wasn't expected" >&2
  exit 1
fi
FAKE
    chmod +x "$dir/agave-validator"
    hexis_render_arb_enable "$dir" /mnt/ledger > "$dir/arb-enable.sh"
  }

  fake_validator "$WORK/arb-new" false
  out="$(bash "$WORK/arb-new/arb-enable.sh" 2>&1)"; rc=$?
  it "arb-enable.sh succeeds on a release without --program-size"
  assert_eq "$rc" "0"

  it "arb-enable.sh skips --program-size when the release lacks it"
  assert_not_contains "$(cat "$WORK/arb-new/calls")" "--program-size"

  it "arb-enable.sh still reaches arb get on a release without --program-size"
  assert_contains "$(cat "$WORK/arb-new/calls")" "--ledger /mnt/ledger arb get"

  fake_validator "$WORK/arb-old" true
  out="$(bash "$WORK/arb-old/arb-enable.sh" 2>&1)"; rc=$?
  it "arb-enable.sh succeeds on a release that has --program-size"
  assert_eq "$rc" "0"

  it "arb-enable.sh sets --program-size when the release has it"
  assert_contains "$(cat "$WORK/arb-old/calls")" "arb set --program-size $HEXIS_PROGRAM_SIZE"
fi

# === lib: checksum verification ============================================
if should_run "checksum"; then
group "lib/hexis.sh checksum verification"
  source "${ROOT}/lib/hexis.sh"
  d="$WORK/ck"; mkdir -p "$d"; printf 'payload' > "$d/asset"

  printf '%s  asset\n' "$(shasum -a 256 "$d/asset" | awk '{print $1}')" > "$d/checksums.txt"
  it "accepts a matching checksum"
  out="$(hexis_verify_checksum "$d" asset 2>&1)"; rc=$?
  assert_eq "$rc" "0"

  printf '%s  asset\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$d/checksums.txt"
  it "rejects a mismatched checksum"
  out="$(hexis_verify_checksum "$d" asset 2>&1)"; rc=$?
  assert_eq "$rc" "1"

  it "reports what it expected and got"
  assert_contains "$out" "Checksum mismatch for asset"

  printf '%s *asset\n' "$(shasum -a 256 "$d/asset" | awk '{print $1}')" > "$d/checksums.txt"
  it "reads a binary-mode line (hash *name)"
  out="$(hexis_verify_checksum "$d" asset 2>&1)"; rc=$?
  assert_eq "$rc" "0"

  printf '%s  something-else\n' "$(shasum -a 256 "$d/asset" | awk '{print $1}')" > "$d/checksums.txt"
  it "refuses an asset the checksum file does not list"
  out="$(hexis_verify_checksum "$d" asset 2>&1)"; rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "has no entry for asset"

  rm -f "$d/checksums.txt"
  it "refuses an asset from a release with no checksum file"
  out="$(hexis_verify_checksum "$d" asset 2>&1)"; rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "No checksums.txt in the release"

  printf '%s  asset\n' "$(shasum -a 256 "$d/asset" | awk '{print $1}')" > "$d/checksums.txt"
  printf '%s  asset\n' "1111111111111111111111111111111111111111111111111111111111111111" > "$d/other-checksums.txt"
  it "refuses when two checksum files disagree"
  out="$(hexis_verify_checksum "$d" asset 2>&1)"; rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "disagree about asset"
  rm -f "$d/other-checksums.txt"

  # Regression: these echo a path for command substitution, so their logging
  # must go to stderr or the caller ends up with a corrupted path.
  it "hexis_download_validator emits only a path on stdout"
  path="$(hexis_download_validator v1.0 "$WORK/dl" 2>/dev/null)"
  assert_eq "$path" "$WORK/dl/agave-validator-linux-amd64"
fi

# === ascend: validator.sh patcher ==========================================
if should_run "patcher"; then
group "ascend.sh validator.sh patcher"
  patcher="$WORK/patcher.sh"
  sed -n "/^PATCHER=\$(cat <<'AWKEOF'\$/,/^AWKEOF\$/p" "$ROOT/ascend.sh" | sed '1d;$d' > "$patcher"
  if [[ ! -s "$patcher" ]]; then
    it "extracts the patcher from ascend.sh"; _fail "could not extract PATCHER block"
  else
    export HEXIS_DIR=/home/sol/hexis METRICS='host=https://m,p=pw' SIGVERIFY=2

    run_patcher() { ( cd "$WORK" && VALIDATOR_SH="$1" bash "$patcher" >/dev/null 2>"$WORK/err" ); }

    # A Jito validator.sh as arise.sh generates it: bare binary name, PATH line
    cat > "$WORK/bare.sh" <<'EOF'
#!/bin/bash
PATH=/home/sol/.local/share/solana/install/releases/active_release/bin:/usr/bin
exec agave-validator \
    --identity /home/sol/identity.json \
    --ledger /mnt/ledger \
    --limit-ledger-size
EOF
    run_patcher bare.sh; rc=$?
    result="$(cat "$WORK/bare.sh.ascend-new" 2>/dev/null)"

    it "patches a bare exec target to the hexis symlink"
    assert_contains "$result" 'exec /home/sol/hexis/agave-validator \'

    it "puts the hexis dir first on PATH"
    assert_contains "$result" 'PATH=/home/sol/hexis:/home/sol/.local'

    it "exports the arb metrics config"
    assert_contains "$result" 'export SOLANA_METRICS_CONFIG_ARB="host=https://m,p=pw"'

    it "adds --arb-config"
    assert_contains "$result" '--arb-config /home/sol/hexis/arb-config.toml \'

    it "adds --tvu-shred-sigverify-threads"
    assert_contains "$result" '--tvu-shred-sigverify-threads 2 \'

    it "preserves the original flags"
    assert_contains "$result" '--identity /home/sol/identity.json'

    it "produces a script that parses"
    bash -n "$WORK/bare.sh.ascend-new" 2>/dev/null && _ok || _fail "output is not valid bash"

    # Absolute exec target, no PATH line
    cat > "$WORK/abs.sh" <<'EOF'
#!/bin/bash
exec /home/sol/.local/share/solana/install/active_release/bin/agave-validator \
    --identity /home/sol/identity.json \
    --ledger /mnt/ledger
EOF
    run_patcher abs.sh
    result="$(cat "$WORK/abs.sh.ascend-new" 2>/dev/null)"

    it "rewrites an absolute exec target"
    assert_contains "$result" 'exec /home/sol/hexis/agave-validator \'

    it "inserts a PATH export when there is no PATH line"
    assert_contains "$result" 'export PATH="/home/sol/hexis:$PATH"'

    # A one-line exec cannot have flags appended safely
    printf '#!/bin/bash\nexec agave-validator --identity /i.json --ledger /mnt/ledger\n' > "$WORK/oneline.sh"
    run_patcher oneline.sh; rc=$?

    it "refuses a single-line exec rather than mangling it"
    assert_eq "$rc" "4"

    it "leaves no partial rewrite behind after refusing a single-line exec"
    assert_file_missing "$WORK/oneline.sh.ascend-new"

    # No exec line at all
    printf '#!/bin/bash\nagave-validator --ledger /mnt/ledger\n' > "$WORK/noexec.sh"
    run_patcher noexec.sh; rc=$?

    it "refuses a script with no exec line"
    assert_eq "$rc" "4"

    it "leaves no partial rewrite behind after refusing a script with no exec"
    assert_file_missing "$WORK/noexec.sh.ascend-new"
  fi
fi

# === clients and the security model ========================================
if should_run "client"; then
group "clients and security model"
  F="$ROOT/test/fixtures"
  PK=7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2
  cl_base=(--host 1.2.3.4 --vote-account "$PK" --network mainnet --commission-bps 0
           --jito-region frankfurt --no-auto-disks --dry-run
           --ssh-key "$WORK/key" --identity "$WORK/id.json")

  out="$(arise "${cl_base[@]}" --no-xdp)"

  it "jito is the default client and builds from the public repo over https"
  assert_contains "$out" "CLIENT_REPO=https://github.com/jito-foundation/jito-solana.git"

  it "jito gets the Block Engine flags"
  assert_contains "$out" "--block-engine-url https://frankfurt.mainnet.block-engine.jito.wtf"

  it "the shred receivers are the Jito region and DoubleZero, nothing else"
  assert_contains "$out" "--shred-receiver-address 64.130.50.14:1002,233.84.178.1:7733 \\"

  it "jito on mainnet gets the tip programs and merkle authority Jito publishes"
  assert_contains "$out" "--tip-payment-program-pubkey T1pyyaTNZsKv2WcRAB8oVnk93mLJw2XzjtVYqCsaHqt \\"
  assert_contains "$out" "--tip-distribution-program-pubkey 4R3gSG8BpU4t19KYj8CfnbtRpnT8gtk4dvTHxVRwc2r7 \\"
  assert_contains "$out" "--merkle-root-upload-authority 8F4jGUmxF36vQ6yabnsxX6AQVXdKBhs8kGSUuRKSg8Xt \\"

  it "the Agave and Firedancer paths name the same merkle authority"
  assert_eq "$(grep -c "JITO_MERKLE_AUTHORITY_MAINNET=\"$(sed -n 's/^FD_TIP_DISTRIBUTION_AUTHORITY="\(.*\)"$/\1/p' "$ROOT/lib/firedancer.sh")\"" "$ROOT/arise.sh")" "1"

  tn_out="$(STUB_RESPONSES=$F/host-fresh.responses arise --host 1.2.3.4 --vote-account "$PK" --network testnet \
        --jito-region dallas --no-auto-disks --no-xdp --dry-run --ssh-key "$WORK/key" --identity "$WORK/id.json")"
  it "jito on testnet gets the testnet Block Engine and shred receiver"
  assert_contains "$tn_out" "--block-engine-url https://dallas.testnet.block-engine.jito.wtf \\"
  assert_contains "$tn_out" "--shred-receiver-address 141.98.218.12:1002 \\"

  it "and the testnet tip programs and merkle authority, not the mainnet ones"
  assert_contains "$tn_out" "--tip-payment-program-pubkey GJHtFqM9agxPmkeKjHny6qiRKrXZALvvFGiKf11QE7hy \\"
  assert_contains "$tn_out" "--tip-distribution-program-pubkey DzvGET57TAgEDxvm3ERUM4GNcsAJdqjDLCne9sdfY4wf \\"
  assert_contains "$tn_out" "--merkle-root-upload-authority 7T4inmPmtNBX3MhLwJ9hFsSMnGJYYkKioVABSNTWVRuS \\"
  assert_not_contains "$tn_out" "T1pyyaTNZsKv2WcRAB8oVnk93mLJw2XzjtVYqCsaHqt"

  it "testnet takes no DoubleZero receiver and a commission of 0 unless one is given"
  assert_not_contains "$tn_out" "233.84.178.1"
  assert_contains "$tn_out" "--commission-bps 0 \\"

  it "a testnet validator.sh still parses, with the Jito flags inside the one command"
  tn_vsh="$(printf '%s\n' "$tn_out" | sed -n '/^#!\/bin\/bash$/,/--full-rpc-api$/p')"
  assert_contains "$tn_vsh" "--full-rpc-api"
  assert_eq "$(printf '%s\n' "$tn_vsh" | bash -n 2>&1 && echo parses)" "parses"
  assert_eq "$(printf '%s\n' "$tn_vsh" | grep -c '^exec ')" "1"

  it "agave on testnet gets no Jito flags"
  assert_not_contains "$(STUB_RESPONSES=$F/host-fresh.responses arise --host 1.2.3.4 --vote-account "$PK" --network testnet --client agave \
        --no-auto-disks --no-xdp --dry-run --ssh-key "$WORK/key" --identity "$WORK/id.json")" "--block-engine-url"

  it "rustup is a pinned release checked against a recorded checksum, never piped into a shell"
  assert_eq "$(grep -cE 'curl[^|]*\|[[:space:]]*(sh|bash)([[:space:]]|$)' "$ROOT/arise.sh" "$ROOT/ascend.sh" "$ROOT/reawaken.sh" "$ROOT/system.sh" "$ROOT"/lib/*.sh | awk -F: '{n+=$2} END {print n}')" "0"
  assert_contains "$out" "static.rust-lang.org/rustup/archive/\${RUSTUP_VERSION}/"
  assert_contains "$out" "sha256sum -c -"
  assert_order "$out" "sha256sum -c -" '"$RUSTUP_TMP/rustup-init" -y'

  it "RPC stays on localhost and out of gossip"
  assert_contains "$out" "--private-rpc"

  it "no public RPC address is advertised"
  assert_not_contains "$out" "--public-rpc-address"

  it "the port range is the 26 ports Agave 4 needs"
  assert_contains "$out" "--dynamic-port-range 8000-8026"

  it "the firewall opens that range and not 8000-10000"
  assert_contains "$out" "FIREWALL_PORT_RANGE=8000:8026"

  it "the old wide firewall rule is removed"
  assert_contains "$out" "ufw delete allow 8000:10000/tcp"

  it "no GitHub key is copied to the server"
  assert_not_contains "$out" "IdentityFile ~/.ssh/github_key"

  it "a GitHub key left by an older run is reported"
  assert_contains "$out" "delete it and revoke it on GitHub"

  it "jag-snap is not set up"
  assert_not_contains "$out" "docker run"

  it "sol's old sudo access is revoked"
  assert_contains "$out" 'rm -f "/etc/sudoers.d/$SOL_USER"'

  it "sshd is hardened through a drop-in that is checked before reload"
  assert_contains "$out" 'DROPIN="$DROPIN_DIR/00-arise.conf"'

  it "root login is turned off by default"
  assert_contains "$out" "PERMIT_ROOT_LOGIN=no"

  it "--keep-root-login keeps key-only root login"
  assert_contains "$(arise "${cl_base[@]}" --no-xdp --keep-root-login)" "PERMIT_ROOT_LOGIN=prohibit-password"

  it "CPU mitigations stay on unless asked"
  assert_contains "$out" "DISABLE_CPU_MITIGATIONS=false"

  it "no script is written to /tmp on the server"
  assert_not_contains "$out" "/tmp/_setup_script"

  it "perch is installed by default"
  assert_contains "$out" "Installing perch watchtower"

  # The part of the perch step that gives it this machine's [[hosts]] entry,
  # lifted from the script a dry run prints and run against scratch files.
  ne_dir="$(mktemp -d)"; mkdir "$ne_dir/bin"
  ne_block="$(printf '%s\n' "$out" | sed -n '/^  HOSTS_NOTE="no \[\[hosts\]\]/,/^    HOSTS_NOTE="\[\[hosts\]\] entry in the starter/p' \
    | sed "s|/etc/default/prometheus-node-exporter|$ne_dir/defaults|")"
  # The lifted script is written for GNU sed. BSD sed wants an argument after -i.
  printf '#!/bin/sh\nif [ "$1" = "-i" ] && ! /usr/bin/sed --version >/dev/null 2>&1; then shift; exec /usr/bin/sed -i "" "$@"; fi\nexec /usr/bin/sed "$@"\n' > "$ne_dir/bin/sed"
  printf '#!/bin/sh\necho "$@" >> "%s/systemctl.calls"\n' "$ne_dir" > "$ne_dir/bin/systemctl"
  printf '#!/bin/sh\necho "$@" >> "%s/apt.calls"\n[ -n "$APT_FAILS" ] && exit 100\nprintf "#!/bin/sh\\n" > "%s/bin/prometheus-node-exporter"; chmod +x "%s/bin/prometheus-node-exporter"\n' \
    "$ne_dir" "$ne_dir" "$ne_dir" > "$ne_dir/bin/apt-get"
  chmod +x "$ne_dir/bin/sed" "$ne_dir/bin/systemctl" "$ne_dir/bin/apt-get"
  ne_starter() { printf '%s\n' '[[validators]]' 'label = "val-1"' '' '[digest]' 'enabled = false' > "$ne_dir/new.toml"; }
  # shellcheck disable=SC2034  # NEW and PERCH_LABEL are read by the lifted script
  ne_run() { ( PATH="$ne_dir/bin:$PATH"; NEW="$ne_dir/new.toml"; PERCH_LABEL="val-1"; eval "$ne_block
  fi"; echo "$HOSTS_NOTE" ); }

  it "the dry run shows the step that gives perch this machine's [[hosts]] entry"
  assert_contains "$ne_block" "prometheus-node-exporter"

  ne_starter; printf '%s\n' '# defaults' 'ARGS=""' > "$ne_dir/defaults"
  ne_out="$(ne_run)"
  it "a fresh install gets node_exporter, answering on loopback only"
  assert_contains "$(cat "$ne_dir/apt.calls")" "install -y --no-install-recommends prometheus-node-exporter"
  assert_eq "$(grep '^ARGS=' "$ne_dir/defaults")" 'ARGS="--web.listen-address=127.0.0.1:9100"'
  assert_contains "$(cat "$ne_dir/systemctl.calls")" "restart prometheus-node-exporter"

  it "and perch gets a [[hosts]] entry for this machine, tied to its validator"
  assert_eq "$(sed -n '/^\[\[hosts\]\]/,$p' "$ne_dir/new.toml")" "$(printf '%s\n' '[[hosts]]' 'name = "val-1-hw"' 'url = "http://127.0.0.1:9100/metrics"' 'validator = "val-1"')"
  assert_contains "$ne_out" "disks read from node_exporter on 127.0.0.1:9100"

  it "that entry is the one a later cutover adds Firedancer's metrics to"
  printf '%s\n' '[tiles.metric]' '    prometheus_listen_address = "10.1.2.3"' > "$ne_dir/fd.toml"
  printf '#!/bin/sh\ncase "$*" in *--version*) echo "perch 1.6.0 (abc)" ;; esac\n' > "$ne_dir/bin/perch"; chmod +x "$ne_dir/bin/perch"
  ( PATH="$ne_dir/bin:$PATH"; eval "$(perch_firedancer_on_cmd nobody-here "$ne_dir/fd.toml" | sed "1s|.*|perch_cfg=\"$ne_dir/new.toml\"|")" ) >/dev/null
  assert_eq "$(grep -A1 '^url = "http://127.0.0.1:9100/metrics"' "$ne_dir/new.toml" | tail -1)" 'firedancer_url = "http://10.1.2.3:7999/metrics"'

  ne_starter; rm -f "$ne_dir/apt.calls" "$ne_dir/systemctl.calls"
  ne_run >/dev/null
  it "node_exporter already there and already on loopback is not reinstalled or restarted"
  assert_file_missing "$ne_dir/apt.calls"
  assert_not_contains "$(cat "$ne_dir/systemctl.calls")" "restart"

  ne_starter; rm -f "$ne_dir/bin/prometheus-node-exporter"
  ne_out="$(APT_FAILS=1 ne_run)"
  it "node_exporter that cannot be installed costs the entry, not the install"
  assert_contains "$ne_out" "node_exporter could not be installed"
  assert_not_contains "$(cat "$ne_dir/new.toml")" "[[hosts]]"

  printf '%s\n' '[[hosts]]' 'name = "theirs"' 'url = "http://10.0.0.5:9100/metrics"' > "$ne_dir/new.toml"; rm -f "$ne_dir/apt.calls"
  ne_out="$(ne_run)"
  it "a starter config that already has a [[hosts]] entry is not given a second"
  assert_eq "$(grep -c '^\[\[hosts\]\]' "$ne_dir/new.toml")" "1"
  assert_file_missing "$ne_dir/apt.calls"
  rm -rf "$ne_dir"

  # perch's installer runs as root: the lines that check it first, lifted from
  # the dry run and run against scratch files
  pi_dir="$(mktemp -d)"; mkdir "$pi_dir/bin"
  command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$pi_dir/bin/sha256sum"; chmod +x "$pi_dir/bin/sha256sum"; }
  pi_check="$(printf '%s\n' "$out" | sed -n '/^if ! (cd "\$WORK" && grep -E .*install/,/^fi$/p')"
  pi_run() { ( PATH="$pi_dir/bin:$PATH"; WORK="$pi_dir"; eval "$pi_check"; echo "ran the installer" ) 2>&1; }
  printf '#!/bin/sh\necho perch installer\n' > "$pi_dir/install.sh"
  pi_sum="$(PATH="$pi_dir/bin:$PATH" sha256sum "$pi_dir/install.sh" | cut -d' ' -f1)"

  it "the dry run checks perch's installer against the release checksums before running it"
  assert_order "$out" 'SHA256SUMS | sha256sum -c -' 'bash "$WORK/install.sh" --version'

  printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "perch-x86_64-unknown-linux-musl.tar.gz" "$pi_sum" "install.sh" > "$pi_dir/SHA256SUMS"
  it "an installer that matches its published checksum is run"
  assert_eq "$(pi_run)" "ran the installer"

  echo "echo tampered" >> "$pi_dir/install.sh"
  it "an installer that does not match is not run"
  assert_contains "$(pi_run)" "does not match the checksum published with the release"
  assert_not_contains "$(pi_run)" "ran the installer"

  printf '%s  %s\n' "$pi_sum" "perch-x86_64-unknown-linux-musl.tar.gz" > "$pi_dir/SHA256SUMS"
  it "nor is one the checksum list does not mention at all"
  assert_not_contains "$(pi_run)" "ran the installer"
  rm -rf "$pi_dir"

  it "--no-perch skips it"
  assert_contains "$(arise "${cl_base[@]}" --no-xdp --no-perch)" "Skipping perch watchtower"

  out="$(arise "${cl_base[@]}" --no-xdp --client agave --client-version v4.4.1)"

  it "agave builds from the Anza repo"
  assert_contains "$out" "CLIENT_REPO=https://github.com/anza-xyz/agave.git"

  it "agave gets no Jito flags"
  assert_not_contains "$out" "--block-engine-url"

  it "agave gets no tip programs"
  assert_not_contains "$out" "--tip-payment-program-pubkey"

  out="$(arise "${cl_base[@]}" --client firedancer --fd-tag v1.2.3)"

  it "firedancer builds nothing from source"
  assert_contains "$out" "Firedancer ships as a binary"

  it "firedancer writes validator.sh with the Block Engine settings for reawaken to read"
  assert_contains "$out" "--block-engine-url https://frankfurt.mainnet.block-engine.jito.wtf"

  it "firedancer leaves sol.service disabled"
  assert_contains "$out" "IS_FIREDANCER=true"

  it "firedancer hands over to reawaken stage with the release and the admin user"
  assert_contains "$out" "reawaken.sh stage --host 1.2.3.4 --ssh-key $WORK/key --admin-user monarch --fd-tag v1.2.3 --generate-signer"

  it "firedancer passes a supplied arb signer on"
  assert_contains "$(arise "${cl_base[@]}" --client firedancer --fd-tag v1.2.3 --hexis-signer "$WORK/signer.json")" \
    "--hexis-signer $WORK/signer.json"

  it "firedancer points at cutover to start it"
  assert_contains "$out" "reawaken.sh cutover --host 1.2.3.4"

  it "--fd-vanilla hands a binary you built to reawaken stage, with no signer"
  out_up="$(arise "${cl_base[@]}" --client firedancer --fd-vanilla --fd-binary "$WORK/binary")"
  assert_contains "$out_up" "reawaken.sh stage --host 1.2.3.4 --ssh-key $WORK/key --admin-user monarch --fd-binary $WORK/binary --vanilla"
  assert_not_contains "$out_up" "--generate-signer"

  it "--fd-vanilla is not held to mainnet"
  out_up="$(arise --host 1.2.3.4 --vote-account "$PK" --network testnet --dry-run --no-auto-disks \
    --ssh-key "$WORK/key" --identity "$WORK/id.json" --client firedancer --fd-vanilla --fd-binary "$WORK/binary")"
  assert_not_contains "$out_up" "requires --network mainnet"
  assert_contains "$out_up" "--fd-binary $WORK/binary --vanilla"

  it "--fd-vanilla needs the binary, and takes no Hexis release or signer"
  assert_contains "$(arise "${cl_base[@]}" --client firedancer --fd-vanilla)" "--fd-vanilla needs --fd-binary"
  assert_contains "$(arise "${cl_base[@]}" --client firedancer --fd-vanilla --fd-tag v1.2.3)" "Vanilla Firedancer has no prebuilt releases"
  assert_contains "$(arise "${cl_base[@]}" --client firedancer --fd-vanilla --fd-binary "$WORK/binary" --hexis-signer "$WORK/signer.json")" "belong to the Hexis Concorde"
  assert_contains "$(arise "${cl_base[@]}" --fd-vanilla)" "only go with --client firedancer"

  it "firedancer is mainnet only"
  assert_contains "$(arise --host 1.2.3.4 --vote-account "$PK" --network testnet --dry-run \
    --ssh-key "$WORK/key" --identity "$WORK/id.json" --client firedancer)" "requires --network mainnet"

  it "--hexis needs the jito client"
  assert_contains "$(arise "${cl_base[@]}" --client agave --hexis --hexis-binary "$WORK/binary")" "--hexis needs --client jito"

  it "an unknown client is refused"
  assert_contains "$(arise "${cl_base[@]}" --client frankendancer)" "--client must be"

  it "--fd-tag without the firedancer client is refused"
  assert_contains "$(arise "${cl_base[@]}" --fd-tag v1)" "only go with --client firedancer"

  it "a vote account that is not a pubkey is refused"
  assert_contains "$(arise --host 1.2.3.4 --vote-account 'x;reboot' --network mainnet --dry-run \
    --ssh-key "$WORK/key" --identity "$WORK/id.json")" "not a valid base58 pubkey"

  it "a disk that is not a /dev path is refused"
  assert_contains "$(arise "${cl_base[@]}" --ledger-disk 'nvme0n1; rm -rf /')" "must be a /dev path"

  # --- lib/remote.sh ---
  source "${ROOT}/lib/remote.sh"

  it "a wrapped script is parsed whole and reads no stdin"
  assert_eq "$(printf 'echo one\ncat\necho two\n' | wrap_script | bash)" "$(printf 'one\ntwo')"

  it "a wrapped script stops at the first failing command"
  assert_eq "$(printf 'echo one\nfalse\necho two\n' | wrap_script | bash; echo "rc=$?")" "$(printf 'one\nrc=1')"

  it "a wrapped script's exit status is the script's"
  printf 'exit 7\n' | wrap_script | bash; assert_eq "$?" "7"

  it "emit_vars quotes values so they cannot run as code"
  # shellcheck disable=SC2034  # read by name through emit_vars
  HOSTILE='x"; touch '"$WORK"'/pwned; echo "'
  ( emit_vars HOSTILE; echo 'printf "%s" "$HOSTILE" > /dev/null' ) | wrap_script | bash
  assert_file_missing "$WORK/pwned"

  it "the sudo password is sent on stdin, never on the command line"
  sudo_run() {   # <log name> <root_script | other shell text>; env comes from the caller
    bash -c "
      source '${ROOT}/lib/hexis.sh'; source '${ROOT}/lib/remote.sh'
      SSH_KEY='$WORK/key'; SSH_HOST=1.2.3.4; SOL_USER=sol; ADMIN_USER=monarch; DRY_RUN=false; remote_init
      $2" > "$WORK/$1.out" 2>&1
  }
  STUB_LOG="$WORK/ssh.log" SUDO_PASS='s3cret-pass' sudo_run pass "ask_sudo_pass && echo 'echo hi' | root_script"
  assert_not_contains "$(cat "$WORK/ssh.log")" "s3cret-pass"

  it "root scripts run through the admin user with sudo reading stdin"
  assert_contains "$(cat "$WORK/ssh.log")" "monarch@1.2.3.4 sudo -k -S -p '' bash -s"

  it "with passwordless sudo no password line is put in front of the script"
  STUB_SUDO_NOPASS=1 STUB_LOG="$WORK/nopass.ssh" STUB_SCRIPT_LOG="$WORK/nopass.scripts" SUDO_PASS='s3cret-pass' \
    sudo_run nopass "ask_sudo_pass && echo 'echo hi' | root_script"
  assert_contains "$(cat "$WORK/nopass.ssh")" "monarch@1.2.3.4 sudo -n bash -s"
  assert_not_contains "$(cat "$WORK/nopass.ssh")" "sudo -k -S"
  assert_not_contains "$(cat "$WORK/nopass.scripts")" "s3cret-pass"
  assert_contains "$(cat "$WORK/nopass.out")" "passwordless sudo"

  it "with passwordless sudo nobody is asked for a password"
  STUB_SUDO_NOPASS=1 STUB_LOG="$WORK/noprompt.ssh" sudo_run noprompt "ask_sudo_pass < /dev/null && echo SETTLED"
  assert_contains "$(cat "$WORK/noprompt.out")" "SETTLED"
  assert_not_contains "$(cat "$WORK/noprompt.out")" "Enter sudo password"

  it "a root script refuses to run before sudo has been checked"
  STUB_LOG="$WORK/unasked.ssh" SUDO_PASS='s3cret-pass' sudo_run unasked "echo 'echo hi' | root_script; echo status=\$?"
  assert_contains "$(cat "$WORK/unasked.out")" "status=1"
  assert_file_missing "$WORK/unasked.ssh"
fi

# === Hexis credentials ======================================================
if should_run "credentials"; then
group "Hexis credentials (never in the repository)"
  F="$ROOT/test/fixtures"
  hexis_args=("${arise_base[@]}" --ssh-key "$WORK/key" --identity "$WORK/id.json"
              --hexis --hexis-binary "$WORK/binary" --hexis-signer "$WORK/signer.json")
  touch "$WORK/key" "$WORK/id.json" "$WORK/binary" "$WORK/signer.json"
  no_creds() { ( unset HEXIS_JUP_KEY SOLANA_METRICS_CONFIG_ARB; "$@" ); }

  it "no script carries a Jupiter key or a metrics token as a default"
  leaked="$(cd "$ROOT" && grep -lE 'HEXIS_JUP_KEY:-[^}]|SOLANA_METRICS_CONFIG_ARB:-[^}]|p=apiv[0-9]_[A-Za-z0-9]' ./*.sh lib/*.sh README.md || true)"
  assert_eq "$leaked" ""

  it "lib/hexis.sh has no default for either credential"
  assert_eq "$(no_creds bash -c "source '${ROOT}/lib/hexis.sh'; echo \"[\$HEXIS_JUP_KEY][\$HEXIS_METRICS_CONFIG]\"")" "[][]"

  out="$(STUB_RESPONSES=$F/host-fresh.responses no_creds arise "${hexis_args[@]}")"; rc=$?
  it "arise --hexis stops when the credentials were never given"
  assert_eq "$rc" "1"
  assert_contains "$out" "--hexis-jup-key"
  assert_contains "$out" "--hexis-metrics-config"

  it "it stops before anything is written for the host"
  assert_not_contains "$out" "arb-config.toml"

  out="$(STUB_RESPONSES=$F/host-fresh.responses no_creds arise "${hexis_args[@]}" \
        --hexis-jup-key flag-key --hexis-metrics-config 'host=https://flag,p=flag-pw')"
  it "the flags supply them"
  assert_contains "$out" 'jup_key        = "flag-key"'
  assert_contains "$out" 'export SOLANA_METRICS_CONFIG_ARB="host=https://flag,p=flag-pw"'

  printf '%s\n' '# from Hexis' 'HEXIS_JUP_KEY="file-key"' "SOLANA_METRICS_CONFIG_ARB='host=https://file,p=file-pw'" > "$WORK/hexis.env"
  out="$(STUB_RESPONSES=$F/host-fresh.responses HEXIS_ENV_FILE="$WORK/hexis.env" no_creds arise "${hexis_args[@]}")"
  it "hexis.env supplies them"
  assert_contains "$out" 'jup_key        = "file-key"'
  assert_contains "$out" 'export SOLANA_METRICS_CONFIG_ARB="host=https://file,p=file-pw"'

  printf '%s\n' 'HEXIS_JUP_KEY=x; touch '"$WORK"'/env-ran' > "$WORK/hostile.env"
  HEXIS_ENV_FILE="$WORK/hostile.env" no_creds bash -c "source '${ROOT}/lib/hexis.sh'" >/dev/null 2>&1
  it "hexis.env is read, not run"
  assert_file_missing "$WORK/env-ran"

  out="$(STUB_RESPONSES=$F/host-fresh.responses HEXIS_ENV_FILE="$WORK/hexis.env" arise "${hexis_args[@]}")"
  it "the environment wins over hexis.env"
  assert_contains "$out" 'jup_key        = "test-jup-key"'

  out="$(STUB_RESPONSES=$F/host-fresh.responses no_creds arise "${hexis_args[@]}" \
        --hexis-jup-key "" --hexis-metrics-config "")"; rc=$?
  it "an empty value is a decision to go without, and is said out loud"
  assert_eq "$rc" "0"
  assert_contains "$out" "No Jupiter API key"
  assert_contains "$out" "No arb metrics config"
  assert_not_contains "$out" "jup_key        ="

  out="$(no_creds ascend migrate --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" --dry-run)"; rc=$?
  it "ascend migrate stops when the credentials were never given"
  assert_eq "$rc" "1"
  assert_contains "$out" "Hexis credentials are not kept in this repository"

  out="$(no_creds ascend upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" --dry-run)"
  it "ascend upgrade, which writes neither, does not ask for them"
  assert_not_contains "$out" "Hexis credentials are not kept"

  # At a terminal the missing ones are asked for. HEXIS_ASSUME_TTY stands in for
  # the terminal; the answers are: key, save?, metrics string, save?
  ask_env="$WORK/asked/hexis.env"; mkdir -p "$WORK/asked"
  asking() { ( unset HEXIS_JUP_KEY SOLANA_METRICS_CONFIG_ARB; HEXIS_ASSUME_TTY=1 HEXIS_ENV_FILE="$ask_env" "$@" ); }
  ask_metrics='host=https://asked,db=d,u=u,p=asked-pw'

  out="$(printf '%s\n' 'asked-key' 'y' "$ask_metrics" '' | STUB_RESPONSES=$F/host-fresh.responses asking arise "${hexis_args[@]}" 2>&1)"; rc=$?
  it "at a terminal arise asks for the missing credentials and uses the answers"
  assert_eq "$rc" "0"
  assert_contains "$out" 'jup_key        = "asked-key"'
  assert_contains "$out" "export SOLANA_METRICS_CONFIG_ARB=\"${ask_metrics}\""

  it "the answers are saved to hexis.env, readable only by the owner"
  assert_eq "$(cat "$ask_env")" "$(printf '%s\n' 'HEXIS_JUP_KEY="asked-key"' "SOLANA_METRICS_CONFIG_ARB=\"${ask_metrics}\"")"
  assert_eq "$(find "$ask_env" -perm 600 | wc -l | tr -d ' ')" "1"

  out="$(STUB_RESPONSES=$F/host-fresh.responses asking arise "${hexis_args[@]}" </dev/null 2>&1)"; rc=$?
  it "the next run reads the saved file and asks nothing"
  assert_eq "$rc" "0"
  assert_not_contains "$out" "Enter the"
  assert_contains "$out" 'jup_key        = "asked-key"'

  rm -f "$ask_env"
  out="$(printf '%s\n' 'once-key' 'n' "$ask_metrics" 'n' | STUB_RESPONSES=$F/host-fresh.responses asking arise "${hexis_args[@]}" 2>&1)"
  it "answering no to saving uses the value for this run only"
  assert_contains "$out" 'jup_key        = "once-key"'
  assert_file_missing "$ask_env"

  printf '%s\n' '# from Hexis' 'HEXIS_JUP_KEY="old-key"' > "$ask_env"; chmod 644 "$ask_env"
  out="$(printf '%s\n' "$ask_metrics" 'y' | STUB_RESPONSES=$F/host-fresh.responses asking arise "${hexis_args[@]}" 2>&1)"
  it "only the missing one is asked for, and the rest of hexis.env is kept"
  assert_not_contains "$out" "Enter the Jupiter API key"
  assert_eq "$(cat "$ask_env")" "$(printf '%s\n' '# from Hexis' 'HEXIS_JUP_KEY="old-key"' "SOLANA_METRICS_CONFIG_ARB=\"${ask_metrics}\"")"
  assert_eq "$(find "$ask_env" -perm 600 | wc -l | tr -d ' ')" "1"

  rm -f "$ask_env"
  out="$(printf '%s\n' '' 'y' 'not-a-metrics-string' "$ask_metrics" 'y' | STUB_RESPONSES=$F/host-fresh.responses asking arise "${hexis_args[@]}" 2>&1)"; rc=$?
  it "Enter alone goes without the key and that choice is saved"
  assert_eq "$rc" "0"
  assert_contains "$out" "No Jupiter API key"
  assert_contains "$(cat "$ask_env")" 'HEXIS_JUP_KEY=""'

  it "a metrics string in the wrong form is asked for again"
  assert_contains "$out" "does not look like the arb metrics string"
  assert_contains "$out" "export SOLANA_METRICS_CONFIG_ARB=\"${ask_metrics}\""

  it "what is typed is never printed back"
  out="$(printf '%s\n' 'secret-key-value' 'n' "$ask_metrics" 'n' | STUB_RESPONSES=$F/host-fresh.responses asking arise "${hexis_args[@]}" --dry-run 2>&1 | grep -v 'jup_key  \|SOLANA_METRICS_CONFIG_ARB' | grep -c 'secret-key-value\|asked-pw')"
  assert_eq "$out" "0"

  rm -f "$ask_env"
  out="$(printf '%s\n' 'k' 'y' | asking ascend migrate --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" --dry-run --yes 2>&1)"; rc=$?
  it "--yes never asks: a missing credential still stops the run"
  assert_eq "$rc" "1"
  assert_contains "$out" "Hexis credentials are not kept in this repository"
  assert_file_missing "$ask_env"
fi

# === flash loans ============================================================
if should_run "flash"; then
group "flash loans"
  F="$ROOT/test/fixtures"

  out="$(STUB_RESPONSES=$F/host-fresh.responses arise "${arise_base[@]}" \
        --ssh-key "$WORK/key" --identity "$WORK/id.json" \
        --hexis --hexis-binary "$WORK/binary" --hexis-signer "$WORK/signer.json")"

  it "arise writes [flash_loan] by default"
  assert_contains "$out" 'marginfi_account = "93rXRLxa3nJ6WkEbsxHCPS6doffoVf4yXb8hxWaphPsw"'

  it "arise does not warn about authority when a signer is supplied"
  assert_not_contains "$out" "Flash loans will fail"

  out="$(STUB_RESPONSES=$F/host-fresh.responses arise "${arise_base[@]}" \
        --ssh-key "$WORK/key" --identity "$WORK/id.json" \
        --hexis --hexis-binary "$WORK/binary")"

  it "arise warns when the marginfi account is set but the signer was generated"
  assert_contains "$out" "Flash loans will fail unless that account's authority is this signer"

  out="$(STUB_RESPONSES=$F/host-fresh.responses arise "${arise_base[@]}" \
        --ssh-key "$WORK/key" --identity "$WORK/id.json" \
        --hexis --hexis-binary "$WORK/binary" --hexis-signer "$WORK/signer.json" --no-hexis-flash-loans)"

  it "--no-hexis-flash-loans drops the table"
  assert_not_contains "$out" 'marginfi_account ='

  it "--no-hexis-flash-loans says so"
  assert_contains "$out" "Flash loans off"

  out="$(STUB_RESPONSES=$F/host-hexis.responses ascend upgrade --host 1.2.3.4 \
        --ssh-key "$WORK/key" --hexis-binary "$WORK/binary")"

  it "ascend reports flash-loan state read from the host's config"
  assert_contains "$out" "Flash loans:   ON via marginfi account 93rXRLxa3nJ6WkEbsxHCPS6doffoVf4yXb8hxWaphPsw"
fi

# === releases: staging and promotion =======================================
if should_run "release"; then
group "release staging and promotion"
  F="$ROOT/test/fixtures"

  out="$(STUB_RESPONSES=$F/host-hexis.responses ascend upgrade --host 1.2.3.4 \
        --ssh-key "$WORK/key" --hexis-tag 'v4.2.2+concorde.1')"

  it "upgrade stages into a versioned release directory"
  assert_contains "$out" "Staging: v4.2.2+concorde.1"

  it "upgrade promotes by default"
  assert_contains "$out" "Promoted v4.2.2+concorde.1"

  it "upgrade issues exit via the release that is still running"
  assert_contains "$out" "/home/sol/hexis/releases/4.2.1/agave-validator --ledger /mnt/ledger exit"

  out="$(STUB_RESPONSES=$F/host-hexis.responses ascend upgrade --host 1.2.3.4 \
        --ssh-key "$WORK/key" --hexis-tag 'v4.2.2+concorde.1' --stage-only)"

  it "--stage-only does not promote"
  assert_not_contains "$out" "Promoted"

  it "--stage-only says what stays active"
  assert_contains "$out" "still points at 4.2.1"

  out="$(STUB_RESPONSES=$F/host-hexis.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" --list)"

  it "promote --list marks the active release"
  assert_contains "$out" "* 4.2.1   (active)"

  it "promote --list shows staged releases"
  assert_contains "$out" "v4.2.2+concorde.1"

  out="$(STUB_RESPONSES=$F/host-hexis.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" --release nope)"

  it "promote rejects a release that is not staged"
  assert_contains "$out" "No such staged release: nope"

  out="$(STUB_RESPONSES=$F/host-hexis.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" \
        --release 'v4.2.2+concorde.1' --min-idle-time 20 --skip-new-snapshot-check)"

  it "--skip-new-snapshot-check reaches the exit command"
  assert_contains "$out" "exit --min-idle-time 20 --max-delinquent-stake 5 --skip-new-snapshot-check"

  # After the flip the symlink points at the new build, so an admin-RPC call
  # through it would cross a version boundary against the running process.
  it "promote issues exit via the release that is still running"
  assert_contains "$out" "/home/sol/hexis/releases/4.2.1/agave-validator --ledger /mnt/ledger exit"

  out="$(STUB_RESPONSES=$F/host-hexis.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" \
        --release 'v4.2.2+concorde.1')"

  it "restart defaults to min-idle-time 20, max-delinquent-stake 5, skipping the snapshot wait"
  assert_contains "$out" "exit --min-idle-time 20 --max-delinquent-stake 5 --skip-new-snapshot-check"

  out="$(STUB_RESPONSES=$F/host-hexis.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" \
        --release 'v4.2.2+concorde.1' --wait-for-new-snapshot)"

  it "--wait-for-new-snapshot drops --skip-new-snapshot-check"
  assert_not_contains "$out" "--skip-new-snapshot-check"

  it "promote leaves a current arb-enable.sh alone"
  assert_not_contains "$out" "Regenerating"

  # An arb-enable.sh from before the --program-size guard aborts on 4.3.2+concorde.1+
  printf '%s\n' "*then echo missing*|stale" > "$WORK/stale-arb-enable.responses"
  cat "$F/host-hexis.responses" >> "$WORK/stale-arb-enable.responses"
  out="$(STUB_RESPONSES=$WORK/stale-arb-enable.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" \
        --release 'v4.2.2+concorde.1')"

  it "promote regenerates an arb-enable.sh with an unguarded --program-size"
  assert_contains "$out" "Regenerating /home/sol/hexis/arb-enable.sh"

  out="$(STUB_RESPONSES=$WORK/stale-arb-enable.responses ascend upgrade --host 1.2.3.4 --ssh-key "$WORK/key" \
        --hexis-binary "$WORK/binary" --dry-run)"

  it "upgrade regenerates an arb-enable.sh with an unguarded --program-size"
  assert_contains "$out" "Regenerating /home/sol/hexis/arb-enable.sh"
fi

# === XDP / PoH flag rename (Agave 4.3+) ====================================
if should_run "xdp"; then
group "XDP / PoH flag rename"
  F="$ROOT/test/fixtures"
  source "${ROOT}/lib/hexis.sh"

  old_flags='    --experimental-retransmit-xdp-cpu-cores 1 \
    --experimental-poh-pinned-cpu-core 10 \
    --experimental-retransmit-xdp-interface enp1s0f0 \
    --experimental-retransmit-xdp-zero-copy \'
  renamed="$(sed "$(xdp_rename_sed)" <<< "$old_flags")"

  it "renames every --experimental-* XDP/PoH flag"
  assert_eq "$renamed" '    --xdp-cpu-cores 1 \
    --poh-pinned-cpu-core 10 \
    --xdp-interface enp1s0f0 \
    --xdp-zero-copy \'

  it "the old-flag pattern finds nothing after the rename"
  assert_eq "$(grep -cE -- "$XDP_OLD_FLAGS_RE" <<< "$renamed")" "0"

  # Host responses: validator.sh carries the old names; the binary's answers vary
  old_xdp="*grep -cE -- '--experimental*|4"
  new_ok="*agave-validator --xdp-cpu-cores 1 --version*|yes"
  new_rejected="*agave-validator --xdp-cpu-cores 1 --version*|no"
  old_rejected="*agave-validator --experimental-retransmit-xdp-cpu-cores 1 --version*|no"
  # sol_script streams its script over stdin, so the call is "sol@host bash -s"
  diff_back="*sol@1.2.3.4 bash -s|--- /home/sol/validator.sh"

  printf '%s\n' "$old_xdp" "$new_ok" "$diff_back" > "$WORK/xdp-new.responses"
  cat "$F/host-hexis.responses" >> "$WORK/xdp-new.responses"
  out="$(STUB_RESPONSES=$WORK/xdp-new.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" \
        --release 'v4.2.2+concorde.1' --yes --restart)"

  it "promote renames the flags when the new release takes the current names"
  assert_contains "$out" "uses the current XDP/PoH flag names — renaming them in /home/sol/validator.sh"

  it "promote still restarts after a successful rename"
  assert_contains "$out" "Exiting the validator gracefully"

  out="$(STUB_RESPONSES=$WORK/xdp-new.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" \
        --release 'v4.2.2+concorde.1' --yes --restart --dry-run)"

  it "a restart tells perch first, once the restart window is open, on a host that runs it"
  assert_contains "$out" "if [ -x /home/sol/perch/maint ]; then /home/sol/hexis/releases/"
  assert_contains "$out" "wait-for-restart-window --min-idle-time 20 --max-delinquent-stake 5 --skip-new-snapshot-check && if [ -x /home/sol/perch/maint ]; then /home/sol/perch/maint restart 1h"

  # Run the generated perch lines against a scratch config; ss is a stub that
  # reports the ports named in SS_PORTS as listening
  pc_dir="$(mktemp -d)"; mkdir "$pc_dir/bin"
  printf '#!/bin/sh\nfor p in $SS_PORTS; do echo "LISTEN 0 128 127.0.0.1:$p 0.0.0.0:*"; done\n' > "$pc_dir/bin/ss"
  printf '#!/bin/sh\nexit 0\n' > "$pc_dir/bin/systemctl"
  chmod +x "$pc_dir/bin/ss" "$pc_dir/bin/systemctl"
  pc_write() {
    printf '%s\n' '[watchtower]' 'name = "x"' '' '# Its own RPC' '[[endpoints]]' 'name = "localhost"' \
      'url = "http://127.0.0.1:8899"' 'monitor = true' '' '[[endpoints]]' 'name = "public"' \
      'url = "https://rpc.example"' '' '[quorum]' 'min_definite = 2' > "$pc_dir/config.toml"
  }
  pc_run() { ( PATH="$pc_dir/bin:$PATH"; eval "$("$1" sol | sed "1s|.*|perch_cfg=\"$pc_dir/config.toml\"|")" ); }

  pc_write
  SS_PORTS="" pc_run perch_local_rpc_off_cmd >/dev/null
  it "after a move to Firedancer, perch stops watching the RPC port that is gone"
  assert_not_contains "$(cat "$pc_dir/config.toml")" "127.0.0.1:8899"

  it "and keeps its other endpoints and settings"
  assert_contains "$(cat "$pc_dir/config.toml")" 'url = "https://rpc.example"'
  assert_contains "$(cat "$pc_dir/config.toml")" 'min_definite = 2'

  it "and keeps the config it had, for the way back"
  assert_contains "$(cat "$pc_dir/config.toml.bak-pre-firedancer")" "127.0.0.1:8899"

  pc_run perch_local_rpc_on_cmd >/dev/null
  it "a rollback puts perch's config back"
  assert_contains "$(cat "$pc_dir/config.toml")" "127.0.0.1:8899"

  pc_write
  SS_PORTS="8899" pc_run perch_local_rpc_off_cmd >/dev/null
  it "perch keeps the local endpoint when Firedancer does serve RPC there"
  assert_contains "$(cat "$pc_dir/config.toml")" "127.0.0.1:8899"

  pc_write
  it "a dead local RPC endpoint in perch is noticed"
  assert_eq "$(SS_PORTS="" pc_run perch_local_rpc_dead_cmd)" "yes"

  it "but not while something listens there"
  assert_eq "$(SS_PORTS="8899" pc_run perch_local_rpc_dead_cmd)" "no"

  printf '%s\n' '[[endpoints]]' 'name = "public"' 'url = "https://rpc.example"' '' '[[hosts]]' 'url = "http://127.0.0.1:9100/metrics"' > "$pc_dir/config.toml"
  it "and node_exporter on a local address is not taken for the validator's RPC"
  assert_eq "$(SS_PORTS="" pc_run perch_local_rpc_dead_cmd)" "no"

  printf '%s\n' '[[endpoints]]' 'name = "localhost"' 'url = "http://127.0.0.1:8899"' > "$pc_dir/config.toml"
  it "perch's only endpoint is not taken away, and the script says so"
  assert_contains "$(SS_PORTS="" pc_run perch_local_rpc_off_cmd)" "its only endpoint is this host's own RPC"
  assert_contains "$(cat "$pc_dir/config.toml")" "127.0.0.1:8899"

  # --- perch installed system-wide, as the current arise.sh does it ---
  it "from root, the restart is declared to a perch in the user's home or a system-wide one"
  assert_contains "$(perch_maint_cmd sol 2h root)" 'elif command -v perch >/dev/null 2>&1 && [ -f /etc/perch/config.toml ]; then perch --config /etc/perch/config.toml maint restart 2h'

  printf '#!/bin/sh\necho "$@" >> "%s/perch.calls"\n' "$pc_dir" > "$pc_dir/bin/perch"; chmod +x "$pc_dir/bin/perch"
  ( PERCH_SYSTEM_CFG="$pc_dir/system.toml"; touch "$PERCH_SYSTEM_CFG"; PATH="$pc_dir/bin:$PATH"; eval "$(perch_maint_cmd nobody-here 2h root)" )
  it "a system-wide perch is told through its own command"
  assert_eq "$(cat "$pc_dir/perch.calls" 2>/dev/null)" "--config $pc_dir/system.toml maint restart 2h"

  rm -f "$pc_dir/perch.calls"
  ( PERCH_SYSTEM_CFG="$pc_dir/none.toml"; PATH="$pc_dir/bin:$PATH"; eval "$(perch_maint_cmd nobody-here 2h root)" )
  it "a host with no perch config is left alone"
  assert_file_missing "$pc_dir/perch.calls"

  it "the validator user's own text never reaches for the system-wide perch"
  assert_not_contains "$(perch_maint_cmd sol 1h)" "/etc/perch"

  it "the config helpers fall back to the system-wide config when the home has none"
  # shellcheck disable=SC2154  # perch_cfg is set by the line being evaluated
  assert_eq "$(PERCH_SYSTEM_CFG="$pc_dir/system.toml"; eval "$(perch_cfg_line nobody-here)"; echo "$perch_cfg")" "$pc_dir/system.toml"

  # the whole way there and back on a system-wide config: sc_run leaves line 1 alone
  sc_run() { ( PERCH_SYSTEM_CFG="$pc_dir/config.toml"; PATH="$pc_dir/bin:$PATH"; eval "$("$1" nobody-here)" ); }
  pc_write; chmod 640 "$pc_dir/config.toml"; rm -f "$pc_dir/config.toml.bak-pre-firedancer"
  SS_PORTS="" sc_run perch_local_rpc_off_cmd >/dev/null
  it "a system-wide perch loses the dead local endpoint too"
  assert_not_contains "$(cat "$pc_dir/config.toml")" "127.0.0.1:8899"
  assert_contains "$(cat "$pc_dir/config.toml.bak-pre-firedancer")" "127.0.0.1:8899"

  sc_run perch_local_rpc_on_cmd >/dev/null
  it "and gets it back on a rollback, with the file's mode unchanged"
  assert_contains "$(cat "$pc_dir/config.toml")" "127.0.0.1:8899"
  assert_eq "$(file_mode "$pc_dir/config.toml")" "640"
  assert_file_missing "$pc_dir/config.toml.bak-pre-firedancer"

  { printf '%s\n' '*command -v perch*|system'; cat "$WORK/xdp-new.responses"; } > "$WORK/perch-system.responses"
  out="$(STUB_RESPONSES=$WORK/perch-system.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" \
        --release 'v4.2.2+concorde.1' --yes --restart --dry-run)"
  it "ascend declares a restart to a system-wide perch through root, after the window"
  assert_order "$out" "wait-for-restart-window --min-idle-time 20" "perch --config /etc/perch/config.toml maint restart 1h"
  assert_contains "$out" "[DRY RUN] root script via monarch@1.2.3.4"

  # --- perch reading Firedancer's metrics -----------------------------------
  # A perch that answers --version with $PERCH_VER and turns down any config
  # holding the word in $PERCH_REJECT.
  cat > "$pc_dir/bin/perch" <<'FAKE'
#!/bin/sh
case "$*" in
  *--version*) echo "perch ${PERCH_VER} (abc1234)" ;;
  *--check-config*) [ -z "${PERCH_REJECT:-}" ] || ! grep -q "$PERCH_REJECT" "$2" ;;
esac
FAKE
  chmod +x "$pc_dir/bin/perch"
  printf '%s\n' '[layout]' '    net_tile_count = 1' '' '[tiles.metric]' '    prometheus_listen_address = "10.1.2.3"' \
    '    prometheus_listen_port = 7999' '' '[tiles.gui]' '    prometheus_listen_port = 1' > "$pc_dir/fd.toml"
  fd_url='firedancer_url = "http://10.1.2.3:7999/metrics"'
  pf_write() {
    printf '%s\n' '[[endpoints]]' 'name = "public"' 'url = "https://rpc.example"' '' \
      '[[hosts]]' 'name = "this-hw"' 'url = "http://127.0.0.1:9100/metrics"' 'mountpoints = ["/"]' '' \
      '[checks.cluster_stake]' 'enabled = false' > "$pc_dir/config.toml"
  }
  pf_on()  { ( PATH="$pc_dir/bin:$PATH"; eval "$(perch_firedancer_on_cmd nobody-here "${1:-$pc_dir/fd.toml}" | sed "1s|.*|perch_cfg=\"$pc_dir/config.toml\"|")" ); }
  pf_off() { ( PATH="$pc_dir/bin:$PATH"; eval "$(perch_firedancer_off_cmd nobody-here | sed "1s|.*|perch_cfg=\"$pc_dir/config.toml\"|")" ); }

  pf_write; chmod 640 "$pc_dir/config.toml"
  out="$(PERCH_VER=1.6.0 pf_on)"
  it "a perch new enough is pointed at the address Firedancer serves its metrics on"
  assert_contains "$out" "now reads Firedancer's metrics at http://10.1.2.3:7999/metrics"
  assert_eq "$(grep -c 'firedancer_url' "$pc_dir/config.toml")" "1"

  it "the line goes under the url of this machine's [[hosts]] entry"
  assert_eq "$(grep -A1 '^url = "http://127.0.0.1:9100/metrics"' "$pc_dir/config.toml" | tail -1)" "$fd_url"

  it "nothing else in the config changes, and it keeps its mode"
  assert_eq "$(grep -v 'firedancer_url' "$pc_dir/config.toml")" "$(pf_write; cat "$pc_dir/config.toml")"
  PERCH_VER=1.6.0 pf_on >/dev/null
  assert_eq "$(file_mode "$pc_dir/config.toml")" "640"
  assert_file_missing "$pc_dir/config.toml.new"

  out="$(PERCH_VER=1.6.0 pf_on)"
  it "running it again adds no second line"
  assert_contains "$out" "already reads Firedancer's metrics"
  assert_eq "$(grep -c 'firedancer_url' "$pc_dir/config.toml")" "1"

  out="$(pf_off)"
  it "going back to Agave takes the line out again"
  assert_contains "$out" "no longer reads Firedancer's metrics"
  assert_eq "$(cat "$pc_dir/config.toml")" "$(pf_write; cat "$pc_dir/config.toml")"

  it "and says nothing when there was no such line"
  assert_eq "$(pf_off)" ""

  pf_write
  out="$(PERCH_VER=1.5.4 pf_on)"
  it "an older perch, which would refuse the key, is left alone and the reason given"
  assert_contains "$out" "1.5.4 cannot read Firedancer's metrics"
  assert_contains "$out" "needs perch 1.6.0 or newer"
  assert_not_contains "$(cat "$pc_dir/config.toml")" "firedancer_url"

  out="$(PERCH_VER=1.10.2 pf_on)"
  it "versions are compared as versions: 1.10 is newer than 1.6"
  assert_contains "$(cat "$pc_dir/config.toml")" "$fd_url"

  pf_write
  out="$(PERCH_VER=1.6.0 PERCH_REJECT=firedancer_url pf_on)"
  it "a config perch itself turns down is not put in place"
  assert_contains "$out" "turned down the config"
  assert_not_contains "$(cat "$pc_dir/config.toml")" "firedancer_url"
  assert_file_missing "$pc_dir/config.toml.new"

  printf '%s\n' '[[hosts]]' 'name = "other"' 'url = "http://10.0.0.9:9100/metrics"' '' \
    '[[hosts]]' 'name = "this-hw"' 'url = "http://127.0.0.1:9100/metrics"' '' '[quorum]' 'url = "x"' > "$pc_dir/config.toml"
  PERCH_VER=1.6.0 pf_on >/dev/null
  it "with several hosts, the one on loopback is this machine"
  assert_eq "$(grep -B1 'firedancer_url' "$pc_dir/config.toml" | head -1)" 'url = "http://127.0.0.1:9100/metrics"'
  assert_eq "$(grep -c 'firedancer_url' "$pc_dir/config.toml")" "1"

  printf '%s\n' '[[hosts]]' 'url = "http://10.0.0.8:9100/metrics"' '' '[[hosts]]' 'url = "http://10.0.0.9:9100/metrics"' > "$pc_dir/config.toml"
  out="$(PERCH_VER=1.6.0 pf_on)"
  it "with several hosts and none on loopback, it does not guess"
  assert_contains "$out" "no [[hosts]] entry"
  assert_contains "$out" "$fd_url"
  assert_not_contains "$(cat "$pc_dir/config.toml")" "firedancer_url"

  printf '%s\n' '[[endpoints]]' 'url = "https://rpc.example"' > "$pc_dir/config.toml"
  out="$(PERCH_VER=1.6.0 pf_on)"
  it "a perch that watches no host is left alone, and told what is missing"
  assert_contains "$out" "has no [[hosts]] entry for this machine"
  assert_contains "$out" "$fd_url"
  assert_not_contains "$(cat "$pc_dir/config.toml")" "firedancer_url"
  assert_file_missing "$pc_dir/config.toml.new"

  pf_write
  printf '%s\n' '[tiles.metric]' '    prometheus_listen_address = "0.0.0.0"' > "$pc_dir/fd-any.toml"
  PERCH_VER=1.6.0 pf_on "$pc_dir/fd-any.toml" >/dev/null
  it "metrics served on every address are read over loopback, on the default port"
  assert_contains "$(cat "$pc_dir/config.toml")" 'firedancer_url = "http://127.0.0.1:7999/metrics"'

  PERCH_VER=1.6.0 pf_on >/dev/null
  it "a metrics address that changed replaces the old line"
  assert_eq "$(grep 'firedancer_url' "$pc_dir/config.toml")" "$fd_url"

  rm -f "$pc_dir/bin/perch"
  pf_write
  it "a host without perch hears nothing about it"
  assert_eq "$(PATH="$pc_dir/bin:/usr/bin:/bin"; eval "$(perch_firedancer_on_cmd nobody-here "$pc_dir/fd.toml" | sed "1s|.*|perch_cfg=\"$pc_dir/config.toml\"|")")" ""

  rm -rf "$pc_dir"

  it "perch not hearing about it never stops a restart"
  assert_contains "$(perch_maint_cmd sol 2h root)" 'runuser -u sol -- /home/sol/perch/maint restart 2h || echo "perch: could not declare the restart'

  printf '%s\n' "$old_xdp" "$new_rejected" > "$WORK/xdp-old.responses"
  cat "$F/host-hexis.responses" >> "$WORK/xdp-old.responses"
  out="$(STUB_RESPONSES=$WORK/xdp-old.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" \
        --release 'v4.2.2+concorde.1' --yes)"

  it "leaves the old names alone for a binary that predates the rename"
  assert_not_contains "$out" "renaming them"

  # The rewrite produces no diff (it failed remotely) and the binary rejects the old names
  printf '%s\n' "$old_xdp" "$new_ok" "$old_rejected" > "$WORK/xdp-broken.responses"
  cat "$F/host-hexis.responses" >> "$WORK/xdp-broken.responses"
  out="$(STUB_RESPONSES=$WORK/xdp-broken.responses ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" \
        --release 'v4.2.2+concorde.1' --yes --restart)"

  it "says the validator will not start when the old names are left for a 4.4+ binary"
  assert_contains "$out" "the validator will not start until they are renamed"

  it "refuses --restart rather than bring up a validator that cannot parse its flags"
  assert_contains "$out" "Skipping --restart"

  it "does not issue exit when the flags are broken"
  assert_not_contains "$out" "Exiting the validator gracefully"

  out="$(STUB_RESPONSES=$WORK/xdp-new.responses ascend upgrade --host 1.2.3.4 --ssh-key "$WORK/key" \
        --hexis-binary "$WORK/binary" --dry-run)"

  it "upgrade --dry-run reports the pending rename"
  assert_contains "$out" "[DRY RUN] would rename the --experimental-* XDP/PoH flags"

  out="$(STUB_RESPONSES=$WORK/xdp-new.responses ascend upgrade --host 1.2.3.4 --ssh-key "$WORK/key" \
        --hexis-binary "$WORK/binary" --stage-only --dry-run)"

  it "upgrade --stage-only leaves validator.sh for promote to fix"
  assert_not_contains "$out" "would rename"
fi

# === cluster metrics (SFDP) =================================================
if should_run "metrics"; then
group "cluster metrics (SFDP)"
  F="$ROOT/test/fixtures"
  source "${ROOT}/lib/hexis.sh"

  out="$(STUB_RESPONSES=$F/host-fresh.responses arise "${arise_base[@]}" \
        --ssh-key "$WORK/key" --identity "$WORK/id.json")"

  it "arise exports SOLANA_METRICS_CONFIG on mainnet"
  assert_contains "$out" "export SOLANA_METRICS_CONFIG=\"$SFDP_METRICS_MAINNET\""

  out="$(STUB_RESPONSES=$F/host-fresh.responses arise --host 1.2.3.4 --vote-account 7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2 \
        --network testnet --no-auto-disks --no-xdp --dry-run \
        --ssh-key "$WORK/key" --identity "$WORK/id.json")"

  it "arise exports the testnet metrics endpoint on testnet"
  assert_contains "$out" "export SOLANA_METRICS_CONFIG=\"$SFDP_METRICS_TESTNET\""

  out="$(STUB_RESPONSES=$F/host-fresh.responses arise "${arise_base[@]}" \
        --ssh-key "$WORK/key" --identity "$WORK/id.json" \
        --hexis --hexis-binary "$WORK/binary" --hexis-signer "$WORK/signer.json")"

  it "arise exports both the cluster and the arb metrics config"
  assert_contains "$out" "export SOLANA_METRICS_CONFIG_ARB="

  it "cluster metrics come before the arb ones"
  assert_eq "$(grep -c 'export SOLANA_METRICS_CONFIG=' <<<"$out")" "1"

  out="$(STUB_RESPONSES=$F/host-fresh.responses arise "${arise_base[@]}" \
        --ssh-key "$WORK/key" --identity "$WORK/id.json" --metrics-config "")"

  it "--metrics-config '' opts out"
  assert_not_contains "$out" "export SOLANA_METRICS_CONFIG="

  it "--metrics-config '' warns that SFDP wants them"
  assert_contains "$out" "will not publish cluster metrics"

  out="$(STUB_RESPONSES=$F/host-fresh.responses arise "${arise_base[@]}" \
        --ssh-key "$WORK/key" --identity "$WORK/id.json" --metrics-config "host=https://mine:8086,db=x")"

  it "--metrics-config overrides the default"
  assert_contains "$out" 'export SOLANA_METRICS_CONFIG="host=https://mine:8086,db=x"'

  # --- the migrate patcher ---
  patcher="$WORK/patcher.sh"
  sed -n "/^PATCHER=\$(cat <<'AWKEOF'\$/,/^AWKEOF\$/p" "$ROOT/ascend.sh" | sed '1d;$d' > "$patcher"
  export HEXIS_DIR=/home/sol/hexis METRICS='arb=1' SIGVERIFY=2 SFDP_METRICS="$SFDP_METRICS_MAINNET"

  cat > "$WORK/nometrics.sh" <<'EOF'
#!/bin/bash
PATH=/home/sol/.local/share/solana/install/releases/active_release/bin:/usr/bin
exec agave-validator \
    --identity /home/sol/identity.json \
    --ledger /mnt/ledger
EOF
  ( cd "$WORK" && VALIDATOR_SH=nometrics.sh bash "$patcher" >/dev/null 2>&1 )
  result="$(cat "$WORK/nometrics.sh.ascend-new" 2>/dev/null)"

  it "migrate adds SOLANA_METRICS_CONFIG when the validator has none"
  assert_contains "$result" "export SOLANA_METRICS_CONFIG=\"$SFDP_METRICS_MAINNET\""

  # An existing config is the operator's; replacing it could point a working
  # validator at the wrong cluster database.
  cat > "$WORK/hasmetrics.sh" <<'EOF'
#!/bin/bash
PATH=/home/sol/.local/share/solana/install/releases/active_release/bin:/usr/bin
export SOLANA_METRICS_CONFIG="host=https://metrics.solana.com:8086,db=mainnet-beta,u=someone_else,p=theirs"
exec agave-validator \
    --identity /home/sol/identity.json \
    --ledger /mnt/ledger
EOF
  ( cd "$WORK" && VALIDATOR_SH=hasmetrics.sh bash "$patcher" >/dev/null 2>&1 )
  result="$(cat "$WORK/hasmetrics.sh.ascend-new" 2>/dev/null)"

  it "migrate leaves an existing SOLANA_METRICS_CONFIG alone"
  assert_contains "$result" "u=someone_else,p=theirs"

  it "migrate does not add a second SOLANA_METRICS_CONFIG"
  assert_eq "$(grep -c 'export SOLANA_METRICS_CONFIG=' <<<"$result")" "1"

  it "migrate still adds the arb metrics config alongside it"
  assert_contains "$result" "export SOLANA_METRICS_CONFIG_ARB="

  # A host already running Hexis is skipped by the migrate patcher, so the SFDP
  # gap on an existing box has to be repairable on its own.
  out="$(STUB_RESPONSES=$F/host-no-metrics.responses ascend upgrade --host 1.2.3.4 \
        --ssh-key "$WORK/key" --hexis-binary "$WORK/binary")"

  it "ascend warns when the host publishes no cluster metrics"
  assert_contains "$out" "exports no SOLANA_METRICS_CONFIG"

  it "that warning names the flag that fixes it"
  assert_contains "$out" "--fix-metrics"

  out="$(STUB_RESPONSES=$F/host-no-metrics.responses ascend upgrade --host 1.2.3.4 \
        --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" --fix-metrics --dry-run)"

  it "--fix-metrics offers to add the export"
  assert_contains "$out" "would add 'export SOLANA_METRICS_CONFIG=...'"

  out="$(STUB_RESPONSES=$F/host-hexis.responses ascend upgrade --host 1.2.3.4 \
        --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" --fix-metrics)"

  it "--fix-metrics is a no-op when the host already has one"
  assert_contains "$out" "already exports SOLANA_METRICS_CONFIG — nothing to fix"

  it "--fix-metrics with an empty --metrics-config is rejected"
  assert_contains "$(STUB_RESPONSES=$F/host-no-metrics.responses ascend upgrade --host 1.2.3.4 \
    --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" --fix-metrics --metrics-config "")" \
    "--fix-metrics needs a value"
fi

# === CLI validation =========================================================
if should_run "cli"; then
group "CLI validation"
  it "ascend requires a mode"
  assert_contains "$(ascend --host 1.2.3.4)" "must be 'upgrade', 'migrate' or 'promote'"

  it "ascend requires a binary source"
  assert_contains "$(ascend upgrade --host 1.2.3.4 --ssh-key "$WORK/key")" \
    "One of --hexis-tag or --hexis-binary is required"

  it "ascend rejects a loopback Control bind"
  assert_contains "$(ascend migrate --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" \
    --hexis-control-bind 127.0.0.1:18082)" "must not be loopback"

  it "ascend rejects a missing file"
  assert_contains "$(ascend upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary /nope)" \
    "File not found: /nope"

  it "arise rejects --hexis on testnet"
  assert_contains "$(arise --host 1.2.3.4 --ssh-key "$WORK/key" --identity "$WORK/id.json" \
    --vote-account 7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2 --network testnet --hexis)" "requires --network mainnet"

  it "arise requires --host"
  assert_contains "$(arise)" "--host is required"

  it "arise rejects an unknown flag"
  assert_contains "$(arise --nonsense)" "Unknown option"

  # A value flag given last used to die on "$2: unbound variable" under set -u
  for script in arise.sh ascend.sh reawaken.sh system.sh; do
    case "$script" in
      ascend.sh)   mode="upgrade" ;;
      reawaken.sh) mode="status" ;;
      *)           mode="" ;;
    esac
    it "$script names the flag that is missing its value"
    # shellcheck disable=SC2086
    out=$( (cd "$ROOT" && ./"$script" $mode --host) 2>&1 )
    assert_contains "$out" "--host requires a value"
    it "$script does not hit an unbound variable on a flag with no value"
    assert_not_contains "$out" "unbound variable"

    it "$script --help exits 0 and prints usage"
    out=$( (cd "$ROOT" && ./"$script" --help) 2>&1 ); rc=$?
    assert_eq "$rc" "0"
    it "$script --help shows the usage text"
    assert_contains "$out" "Usage:"
    it "$script exits 1 on an unknown flag"
    # shellcheck disable=SC2086
    (cd "$ROOT" && ./"$script" $mode --nonsense) >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "1"
  done

  # Printed commands are copy-pasted against real hosts. Without IdentitiesOnly
  # the agent offers every loaded key and can trip the server's MaxAuthTries.
  it "printed ssh commands carry the key and IdentitiesOnly"
  assert_contains "$(STUB_RESPONSES=$ROOT/test/fixtures/host-hexis.responses ascend upgrade \
    --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary")" \
    "ssh -o IdentitiesOnly=yes -i $WORK/key sol@1.2.3.4"

  # --root-user only creates the admin user. Step 12 turns root login off, so
  # root work after the bootstrap goes through the admin user + sudo, and never
  # through sol, which has no sudo at all.
  out="$(STUB_RESPONSES=$ROOT/test/fixtures/host-fresh.responses arise "${arise_base[@]}" \
    --ssh-key "$WORK/key" --identity "$WORK/id.json" --root-user root)"

  it "arise runs root scripts as the admin user even with --root-user"
  assert_contains "$out" "root script via monarch@1.2.3.4"

  it "arise never runs root scripts over the root login"
  assert_not_contains "$out" "root script via root@"

  it "arise never runs root scripts as sol"
  assert_not_contains "$out" "root script via sol@"

  it "--admin-user names the account that holds sudo"
  assert_contains "$(STUB_RESPONSES=$ROOT/test/fixtures/host-fresh.responses arise "${arise_base[@]}" \
    --ssh-key "$WORK/key" --identity "$WORK/id.json" --admin-user ops)" "root script via ops@1.2.3.4"

  it "ascend refuses to upgrade a host with no hexis install"
  assert_contains "$(STUB_RESPONSES=$ROOT/test/fixtures/host-jito.responses ascend upgrade \
    --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary")" "has not been migrated yet"

  # The uploaded binary dies on the host: the reason has to reach the operator
  printf '%s\n' "*incoming --version 2>/dev/null*|" \
    "*incoming --version 2>&1*|Illegal instruction (core dumped)\nexit code 132" > "$WORK/badbin.responses"
  cat "$ROOT/test/fixtures/host-hexis.responses" >> "$WORK/badbin.responses"
  out="$(STUB_RESPONSES=$WORK/badbin.responses ascend upgrade \
    --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary")"

  it "ascend stops when the uploaded binary does not run"
  assert_contains "$out" "does not run on this host — nothing has been changed"

  it "ascend shows what the host printed when the binary fails"
  assert_contains "$out" "host says: Illegal instruction (core dumped)"

  it "ascend shows the failing exit code"
  assert_contains "$out" "host says: exit code 132"

  it "ascend names the local file it uploaded"
  assert_contains "$out" "local file: $WORK/binary"

  # No answer at all — the connection went away mid-install
  printf '%s\n' "*incoming --version*|" > "$WORK/dropped.responses"
  cat "$ROOT/test/fixtures/host-hexis.responses" >> "$WORK/dropped.responses"
  out="$(STUB_RESPONSES=$WORK/dropped.responses ascend upgrade \
    --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary")"

  it "ascend blames a dropped connection, not the binary, when the host says nothing"
  assert_contains "$out" "the SSH connection probably dropped"
fi

# === Firedancer: lib ========================================================
if should_run "firedancer"; then
group "lib/firedancer.sh"
  source "${ROOT}/lib/hexis.sh"
  source "${ROOT}/lib/firedancer.sh"

  vsh='#!/bin/bash
exec agave-validator \
    --identity /home/sol/identity.json \
    --identity-extra /nope \
    # --ledger /commented/out \
    --ledger /mnt/ledger \
    --known-validator AAA \
    --known-validator BBB \
    --shred-receiver-address 1.1.1.1:1,2.2.2.2:2\
    --only-known-rpc \
    --limit-ledger-size'

  it "reads a flag value"
  assert_eq "$(fd_vsh_flag "$vsh" "--identity")" "/home/sol/identity.json"

  it "skips commented-out flags"
  assert_eq "$(fd_vsh_flag "$vsh" "--ledger")" "/mnt/ledger"

  it "reads every value of a repeated flag"
  assert_eq "$(fd_vsh_flag_all "$vsh" "--known-validator" | paste -sd, -)" "AAA,BBB"

  it "stops a value at a line continuation with no space before it"
  assert_eq "$(fd_vsh_flag "$vsh" "--shred-receiver-address")" "1.1.1.1:1,2.2.2.2:2"

  it "returns nothing for a flag that is absent"
  assert_eq "$(fd_vsh_flag "$vsh" "--block-engine-url")" ""

  it "detects plain Agave"
  assert_eq "$(fd_detect_source "$vsh")" "agave"

  it "detects Jito"
  assert_eq "$(fd_detect_source "$vsh
    --block-engine-url https://x \\")" "jito"

  it "detects Hexis Agave ahead of Jito"
  assert_eq "$(fd_detect_source "$vsh
    --block-engine-url https://x \\
    --arb-config /home/sol/hexis/arb-config.toml \\")" "hexis"

  it "picks the zen5 build for AMD family 26"
  assert_eq "$(fd_pick_asset AuthenticAMD 26 "avx2 avx512f")" "firedancer-linux-amd64-zen5"

  it "picks the zen4 build for AMD family 25 with AVX-512"
  assert_eq "$(fd_pick_asset AuthenticAMD 25 "avx2 avx512f")" "firedancer-linux-amd64-zen4"

  it "picks the generic build for Zen 3 (family 25, no AVX-512)"
  assert_eq "$(fd_pick_asset AuthenticAMD 25 "avx2")" "firedancer-linux-amd64"

  it "picks the generic build for Intel even with AVX-512"
  assert_eq "$(fd_pick_asset GenuineIntel 6 "avx2 avx512f")" "firedancer-linux-amd64"

  it "picks nothing for a CPU without AVX2"
  fd_pick_asset GenuineIntel 6 "sse4_2" >/dev/null; rc=$?
  assert_eq "$rc" "1"

  it "compares glibc versions numerically"
  fd_version_ge 2.39 2.38; a=$?; fd_version_ge 2.4 2.38; b=$?
  assert_eq "$a$b" "01"

  tables="$(cat "$ROOT/test/fixtures/concorde-tables.toml")"
  out="$(fd_render_concorde_tables "$tables" /home/sol/firedancer/arb-signer.json JUP OKX)"

  it "sets the signer path in the Concorde tables"
  assert_contains "$out" 'signer_key_path = "/home/sol/firedancer/arb-signer.json"'

  it "sets the token ledgers in the Concorde tables"
  assert_contains "$out" 'okx_token_ledger = "OKX"'

  it "leaves every other Concorde key at the build default"
  assert_eq "$(diff <(echo "$tables") <(echo "$out") | grep -c '^>')" "3"

  out="$(fd_render_unit /home/sol/firedancer/firedancer /home/sol/firedancer/config.toml sol)"

  it "the unit can never run alongside the Agave unit"
  assert_contains "$out" "Conflicts=sol.service"

  it "the unit re-runs configure before each start"
  assert_contains "$out" "ExecStartPre=/home/sol/firedancer/firedancer configure init all --config /home/sol/firedancer/config.toml"

  # A real keypair layout: 32 secret bytes, then the 32 public ones
  key_dir="$(mktemp -d)"
  python3 -c 'import json,sys; json.dump([7]*32+[0]+list(range(1,32)), open(sys.argv[1],"w"))' "${key_dir}/unstaked.json"
  ln -s "${key_dir}/unstaked.json" "${key_dir}/identity.json"
  key_info="$(bash -c "$(fd_key_info_cmd "${key_dir}/identity.json")")"
  real_target="$(cd "$key_dir" && pwd -P)/unstaked.json"

  it "works out a keypair's pubkey on the host, leading zero byte included"
  assert_eq "$(cut -d'|' -f3 <<<"$key_info")" "1thX6LZfHDZZKUs92febYZhYRcXddmzfzF2NvTkPNE"

  it "shows which file an identity symlink points at, with its pubkey"
  assert_eq "$(fd_key_label "$key_info" "${key_dir}/identity.json")" \
    "${key_dir}/identity.json -> ${real_target}  1thX6LZfHDZZKUs92febYZhYRcXddmzfzF2NvTkPNE"

  it "falls back to the bare path when the host told us nothing"
  assert_eq "$(fd_key_label "" "/home/sol/identity.json")" "/home/sol/identity.json"
  rm -rf "$key_dir"

  it "names the group when handing files to a user, not the bare 'user:' form"
  assert_eq "$(fd_chown_cmd sol)" 'chown sol:$(id -gn sol)'

  # Run the generated install lines against a scratch file
  rot_dir="$(mktemp -d)"
  # shellcheck disable=SC2034  # read by the eval'd lines
  ( FD_LOGROTATE_FILE="${rot_dir}/firedancer"; eval "$(fd_render_logrotate_install /mnt/ledger/firedancer/firedancer.log)" ) >/dev/null

  it "installs rotation for the Firedancer log, by copy because the file stays open"
  assert_contains "$(cat "${rot_dir}/firedancer")" "/mnt/ledger/firedancer/firedancer.log {"
  assert_contains "$(cat "${rot_dir}/firedancer")" "copytruncate"
  rm -rf "$rot_dir"

  # Run the generated seeding lines against scratch directories
  seed_dir="$(mktemp -d)"; mkdir "$seed_dir/agave" "$seed_dir/fd"
  touch "$seed_dir/agave/snapshot-100-OLDhash.tar.zst" "$seed_dir/agave/incremental-snapshot-100-190-OLDinc.tar.zst" \
        "$seed_dir/agave/snapshot-200-NEWhash.tar.zst" "$seed_dir/agave/incremental-snapshot-200-250-INCa.tar.zst" \
        "$seed_dir/agave/incremental-snapshot-200-1050-INCb.tar.zst"
  seed_out="$(eval "$(fd_render_snapshot_seed "$seed_dir/agave" "$seed_dir/fd" "$(id -un)")")"

  it "seeds Firedancer with Agave's newest full snapshot and the newest incremental on it"
  assert_eq "$(ls "$seed_dir/fd" | paste -sd, -)" "incremental-snapshot-200-1050-INCb.tar.zst,snapshot-200-NEWhash.tar.zst"

  it "links the snapshot rather than copying 100+ GB when the owner already matches"
  assert_contains "$seed_out" "seeded snapshot-200-NEWhash.tar.zst (linked from"

  it "leaves Agave's own snapshots where they were"
  assert_eq "$(ls "$seed_dir/agave" | wc -l | tr -d ' ')" "5"

  it "does not seed when Firedancer already holds a full snapshot at least as new"
  assert_contains "$(eval "$(fd_render_snapshot_seed "$seed_dir/agave" "$seed_dir/fd" "$(id -un)")")" "already holds a full snapshot at slot 200"

  it "says so when Agave has no snapshot to hand over"
  assert_contains "$(eval "$(fd_render_snapshot_seed "$seed_dir/none" "$seed_dir/fd" "$(id -un)")")" "no Agave snapshot in"
  rm -rf "$seed_dir"

  # Run the generated pre-download lines with curl replaced by a mirror and a
  # trusted validator that live in scratch files. The mirror's file is a little
  # over 3 MiB and is fetched in 1 MiB pieces, so there are four of them.
  pf_dir="$(mktemp -d)"; mkdir "$pf_dir/fd" "$pf_dir/agave"
  pf_key="7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2"
  pf_name="snapshot-300-HD9P3x1tKAqbNvn8PJzNrqmJA9nBxNHCompRkfGT8Edm.tar.zst"
  { printf '\x28\xb5\x2f\xfd'; head -c 3146727 /dev/urandom; } > "$pf_dir/mirror-file"
  pf_size=3146731
  printf '[snapshots.sources.gossip]\n    allow_list = [\n        "%s",\n    ]\n' "$pf_key" > "$pf_dir/config.toml"
  printf 'NOTICE snapct: allowed gossip peer added with public key `%s` and RPC address `10.0.0.9:8899`\n' "$pf_key" > "$pf_dir/fd.log"
  # prefetch <agave dir or ""> [rpc port] — knobs, all optional:
  #   PEER_NAME    the full snapshot the trusted validator serves
  #   SHORT_BY     every piece comes up this many bytes short, every time
  #   FLAKY=1      each piece comes up short the first time it is asked for
  #   MIRROR_NAME  what the mirror serves (default: $pf_name)
  #   MOVES_ON=1   the mirror serves another snapshot once the download has begun
  prefetch() {
    (
      rm -f "$pf_dir"/asked.* "$pf_dir/started"
      curl() {
        local out="" range="" url="" headers=false post=false s e short
        while (($#)); do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            -r) range="$2"; shift 2 ;;
            -D) headers=true; shift 2 ;;
            -X) post=true; shift 2 ;;
            -m|-A|-H|-d|-w|--connect-timeout|--speed-limit|--speed-time) shift 2 ;;
            -*) shift ;;
            *)  url="$1"; shift ;;
          esac
        done
        case "$url" in
          http://10.0.0.9:8899/snapshot.tar.bz2) printf '%s' "http://10.0.0.9:8899/${PEER_NAME}" ;;
          https://mirror.test/snapshot.tar.bz2)
            if [ -n "${MOVES_ON:-}" ] && [ -e "$pf_dir/started" ]; then
              printf '%s' "https://store.test/snapshot-999-HD9P3x1tKAqbNvn8PJzNrqmJA9nBxNHCompRkfGT8Edm.tar.zst?sig=2"
            else
              printf '%s' "https://store.test/${MIRROR_NAME:-$pf_name}?sig=1"
            fi ;;
          https://api.mainnet-beta.solana.com)
            $post && printf '{"result":[{"pubkey":"%s","rpc":"10.0.0.9:8899"},{"pubkey":"SomeoneElse","rpc":"10.9.9.9:8899"}]}' "$pf_key" ;;
          https://store.test/*)
            if $headers; then
              printf 'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/%s\r\n' "$pf_size"
            else
              : > "$pf_dir/started"
              s="${range%-*}"; e="${range#*-}"; short="${SHORT_BY:-0}"
              if [ -n "${FLAKY:-}" ] && [ ! -e "$pf_dir/asked.$s" ]; then short=7; fi
              : > "$pf_dir/asked.$s"
              tail -c "+$((s + 1))" "$pf_dir/mirror-file" 2>/dev/null | head -c "$((e - s + 1 - short))"
            fi ;;
        esac
      }
      # shellcheck disable=SC2034  # read by the eval'd lines
      PF_PROGRESS_SECONDS=0.1 PF_RETRY_SECONDS=0 PF_CHUNK_MB=1 PF_STREAMS=3
      eval "$(fd_render_snapshot_prefetch https://mirror.test "$pf_dir/fd" "$(id -un)" "$pf_dir/config.toml" "$pf_dir/fd.log" "$1" "${2:-8899}")"
    )
  }
  prefetch_down() { ( curl() { return 7; }; eval "$(fd_render_snapshot_prefetch https://mirror.test "$pf_dir/fd" "$(id -un)" "$pf_dir/config.toml" "$pf_dir/fd.log" "" none)" ); }
  pf_left="agave,config.toml,fd,fd.log,mirror-file"
  pf_tidy() { rm -f "$pf_dir"/asked.* "$pf_dir/started"; ls -A "$pf_dir" | paste -sd, -; }

  it "does not take the mirror's snapshot when no trusted validator serves the same one"
  assert_contains "$(PEER_NAME="snapshot-200-SomeOtherHashSomeOtherHashSomeOtherHash1.tar.zst" prefetch "")" "no trusted validator serves ${pf_name}"

  it "and leaves the snapshot directory empty then"
  assert_eq "$(ls -A "$pf_dir/fd" | wc -l | tr -d ' ')" "0"

  it "discards a download whose pieces keep coming up short"
  assert_contains "$(PEER_NAME="$pf_name" SHORT_BY=1 prefetch "")" "did not complete — discarded"

  it "and leaves nothing behind from it"
  assert_eq "$(pf_tidy)" "$pf_left"
  assert_eq "$(ls -A "$pf_dir/fd" | wc -l | tr -d ' ')" "0"

  it "discards the download when the mirror moves on to another snapshot part way"
  assert_contains "$(PEER_NAME="$pf_name" FLAKY=1 MOVES_ON=1 prefetch "")" "did not complete — discarded"
  assert_eq "$(pf_tidy)" "$pf_left"

  it "gives up at the deadline and lets Firedancer start"
  assert_contains "$(PEER_NAME="$pf_name" PF_DEADLINE=0 prefetch "")" "did not complete — discarded"
  assert_eq "$(pf_tidy)" "$pf_left"

  touch "$pf_dir/agave/snapshot-300-AgaveOwnCopyAgaveOwnCopyAgaveOwnCopy1.tar.zst"
  it "skips the download when Agave holds that full snapshot already"
  assert_contains "$(PEER_NAME="$pf_name" prefetch "$pf_dir/agave")" "Agave already holds the full snapshot at slot 300"

  # Two older full snapshots and their incrementals are on disk before the fetch
  for old_slot in 100 200; do
    : > "$pf_dir/fd/snapshot-${old_slot}-OldFuLLoLdFuLLoLdFuLLoLdFuLLoLdFuLL${old_slot}.tar.zst"
    : > "$pf_dir/fd/incremental-snapshot-${old_slot}-$((old_slot + 50))-oLdincoLdincoLdincoLdincoLdincoLd${old_slot}.tar.zst"
  done
  pf_out="$(PEER_NAME="$pf_name" FLAKY=1 prefetch "")"
  it "fetches the mirror's full snapshot when a trusted validator serves the same slot and hash"
  assert_contains "$pf_out" "1 of 1 trusted validators serve ${pf_name}"
  assert_contains "$pf_out" "in 4 pieces, 3 at a time"

  it "a piece that comes up short is fetched again, and the file is the mirror's byte for byte"
  assert_eq "$(cmp "$pf_dir/mirror-file" "$pf_dir/fd/$pf_name" && echo same)" "same"

  it "the file is the validator user's, closed to everyone else"
  assert_eq "$(find "$pf_dir/fd/$pf_name" -perm 600 -user "$(id -un)" | wc -l | tr -d ' ')" "1"

  it "cleans up its working directory"
  assert_eq "$(pf_tidy)" "$pf_left"

  it "keeps the full snapshot from before and removes older ones, with their incrementals"
  assert_eq "$(ls "$pf_dir/fd" | cut -d- -f1-3 | cut -d. -f1 | paste -sd, -)" "incremental-snapshot-200,snapshot-200-OldFuLLoLdFuLLoLdFuLLoLdFuLLoLdFuLL200,snapshot-300-HD9P3x1tKAqbNvn8PJzNrqmJA9nBxNHCompRkfGT8Edm"
  assert_contains "$pf_out" "removed snapshot-100-"

  it "fetches nothing when that full snapshot is on disk already"
  assert_contains "$(PEER_NAME="$pf_name" prefetch "")" "slot 300 is already on disk"

  rm -f "$pf_dir/fd"/*; : > "$pf_dir/fd.log"
  it "on a host that has run no validator, a public RPC endpoint names the trusted validators"
  assert_contains "$(PEER_NAME="$pf_name" prefetch "" none)" "1 of 1 trusted validators serve ${pf_name}"
  assert_eq "$(cmp "$pf_dir/mirror-file" "$pf_dir/fd/$pf_name" && echo same)" "same"

  it "a mirror that names something other than a snapshot is passed over"
  assert_contains "$(MIRROR_NAME="index.html" PEER_NAME="$pf_name" prefetch "")" "named no snapshot — skipped"

  it "and so is one that does not answer"
  assert_contains "$(PEER_NAME="$pf_name" prefetch_down)" "did not answer — skipped"

  # The same lines, installed as the script the unit runs before each start
  pf_script="$pf_dir/prefetch-script"
  ( FD_PREFETCH_SCRIPT="$pf_script"; chown() { :; }
    eval "$(fd_render_prefetch_install on https://mirror.test /mnt/ledger/firedancer/snapshots sol /home/sol/firedancer/config.toml /mnt/ledger/firedancer/firedancer.log)" ) >/dev/null
  it "the pre-start script is a whole bash script that parses"
  assert_eq "$(head -1 "$pf_script")" "#!/bin/bash"
  assert_eq "$(bash -n "$pf_script" && echo parses)" "parses"

  it "it carries this host's mirror, directories and user, and asks no local Agave"
  assert_contains "$(cat "$pf_script")" 'PF_MIRROR="https://mirror.test"'
  assert_contains "$(cat "$pf_script")" 'PF_TO="/mnt/ledger/firedancer/snapshots"'
  assert_contains "$(cat "$pf_script")" 'PF_RPC_PORT="none"'
  assert_contains "$(cat "$pf_script")" 'PF_AGAVE=""'

  it "it can never fail the start: it ends with exit 0 and is executable"
  assert_eq "$(tail -1 "$pf_script")" "exit 0"
  assert_eq "$(test -x "$pf_script" && echo yes)" "yes"

  ( FD_PREFETCH_SCRIPT="$pf_script"; eval "$(fd_render_prefetch_install off)" )
  it "turned off, the script is taken away"
  assert_file_missing "$pf_script"
  rm -rf "$pf_dir"

  it "the unit runs the pre-download after configure, lets it fail, and waits long enough for it"
  unit_on="$(fd_render_unit /fd/firedancer /fd/config.toml sol on)"
  assert_order "$unit_on" "ExecStartPre=/fd/firedancer configure init all" "ExecStartPre=-${FD_PREFETCH_SCRIPT}"
  assert_order "$unit_on" "ExecStartPre=-${FD_PREFETCH_SCRIPT}" "ExecStart=/fd/firedancer run"
  assert_contains "$unit_on" "TimeoutStartSec=$((FD_SNAPSHOT_DEADLINE * 2))"

  it "without it the unit has neither line"
  assert_not_contains "$(fd_render_unit /fd/firedancer /fd/config.toml sol off)" "snapshot-prefetch"
  assert_not_contains "$(fd_render_unit /fd/firedancer /fd/config.toml sol)" "TimeoutStartSec"

  it "the unit asks for the open-file limit the sysctl step provides"
  assert_contains "$out" "LimitNOFILE=${FD_NOFILE}"

  # Run the generated root lines against a fake sysctl that records what it is given
  nofile_dir="$(mktemp -d)"
  run_nofile_step() {
    ( sysctl() { if [[ "$1" == "-n" ]]; then echo "$1_current"; else echo "$*" >> "${nofile_dir}/calls"; fi; }
      # shellcheck disable=SC2034  # read by the eval'd lines
      FD_SYSCTL_FILE="${nofile_dir}/90-firedancer.conf"
      eval "$(fd_render_nofile_sysctl | sed "s/\\\$(sysctl -n fs.nr_open)/$1/")" )
  }

  it "raises fs.nr_open when the host's value is below the unit's limit"
  run_nofile_step 1000000 >/dev/null
  assert_eq "$(cat "${nofile_dir}/90-firedancer.conf")" "fs.nr_open = ${FD_NOFILE}"
  assert_contains "$(cat "${nofile_dir}/calls")" "fs.nr_open=${FD_NOFILE}"

  it "leaves fs.nr_open alone when it is already large enough"
  rm -f "${nofile_dir}/90-firedancer.conf" "${nofile_dir}/calls"
  run_nofile_step 1048576 >/dev/null
  assert_eq "$(ls "$nofile_dir" | wc -l | tr -d ' ')" "0"
  rm -rf "$nofile_dir"
fi

# === Firedancer: reawaken.sh ==================================================
if should_run "reawaken"; then
group "reawaken.sh"
  source "${ROOT}/lib/hexis.sh"
  source "${ROOT}/lib/firedancer.sh"
  reawaken() { ( cd "$ROOT" && ./reawaken.sh "$@" ) 2>&1; }
  T="$ROOT/test/fixtures/concorde-tables.toml"

  base_args=(stage --host 1.2.3.4 --ssh-key "$WORK/key" --concorde-tables "$T" --dry-run)

  # --- Hexis Agave source ---
  fd_host "$WORK/fd-hexis.responses" "" "${KV}${JITO}${HEXIS}"
  out="$(STUB_RESPONSES=$WORK/fd-hexis.responses reawaken "${base_args[@]}")"

  it "recognises a Hexis Agave host"
  assert_contains "$out" "Hexis Agave -> Firedancer with the Concorde"

  it "picks the build from the host CPU"
  assert_contains "$out" "Build: firedancer-linux-amd64-zen4"

  it "carries the identity over"
  assert_contains "$out" 'identity_key = "/home/sol/identity.json"'

  it "carries a separate authorized voter over"
  assert_contains "$out" '"/home/sol/staked_identity.json",'

  it "carries the vote account over"
  assert_contains "$out" 'vote_account = "VoTe111"'

  it "turns Alpenglow on"
  assert_contains "$out" "alpenglow = true"

  it "keeps telemetry on for the SFDP"
  assert_contains "$out" "telemetry = true"

  it "carries the Block Engine over"
  assert_contains "$out" 'url = "https://ny.mainnet.block-engine.jito.wtf"'

  it "carries the tip commission over"
  assert_contains "$out" "commission_bps = 1000"

  it "carries the merkle root upload authority over as the tip distribution authority"
  assert_contains "$out" 'tip_distribution_authority = "AUTH111"'

  it "flags a carried-over tip authority that differs from the Hexis docs"
  assert_contains "$out" "The Hexis Firedancer docs use $FD_TIP_DISTRIBUTION_AUTHORITY"

  it "defaults the tip programs the source does not name"
  assert_contains "$out" 'tip_payment_program_addr = "T1pyyaTNZsKv2WcRAB8oVnk93mLJw2XzjtVYqCsaHqt"'

  it "sends shred receivers to the leader list"
  assert_contains "$out" "additional_shred_destinations_leader = ["

  it "never uses the retransmit list"
  assert_not_contains "$out" "additional_shred_destinations_retransmit"

  it "uses simple RSS queues when DoubleZero is a receiver"
  assert_contains "$out" 'rss_queue_mode = "simple"'

  it "limits snapshots to three or more known validators"
  assert_contains "$out" "allow_any = false"

  it "reuses the Hexis Agave signer"
  assert_contains "$out" "/home/sol/hexis/arb_signer_keypair.json (the Hexis Agave signer)"

  it "points the Concorde at the root-owned copy of the signer"
  assert_contains "$out" 'signer_key_path = "/home/sol/firedancer/arb-signer.json"'

  it "carries the token ledgers from arb-config.toml"
  assert_contains "$out" 'jupiter_token_ledger = "JUPfromAgave"'

  it "binds metrics to the host address"
  assert_contains "$out" 'prometheus_listen_address = "9.9.9.9"'

  it "puts Firedancer's data beside, not inside, Agave's snapshots"
  assert_contains "$out" 'snapshots = "/mnt/ledger/firedancer/snapshots"'

  it "leaves RPC off and says what that breaks"
  assert_contains "$out" "RPC:            off"

  it "a dry run changes nothing"
  assert_contains "$out" "nothing was changed on sol@1.2.3.4"

  it "a dry run never asks for sudo"
  assert_not_contains "$out" "Sudo password"

  out="$(STUB_RESPONSES=$WORK/fd-hexis.responses reawaken "${base_args[@]}" --enable-rpc --snapshot-allow-any)"

  it "--enable-rpc turns the RPC tile on"
  assert_contains "$out" "[tiles.rpc]"

  it "--snapshot-allow-any drops the allow list"
  assert_not_contains "$out" "allow_any = false"

  # --- Jito source ---
  fd_host "$WORK/fd-jito.responses" "" "${KV}${JITO}"
  out="$(STUB_RESPONSES=$WORK/fd-jito.responses reawaken "${base_args[@]}")"

  it "recognises a Jito host"
  assert_contains "$out" "Startup script: Jito"

  it "a Jito host has no arb signer to reuse, and says so"
  assert_contains "$out" "No arb signer: Jito has none to reuse"

  out="$(STUB_RESPONSES=$WORK/fd-jito.responses reawaken "${base_args[@]}" --hexis-signer "$WORK/signer.json")"

  it "a Jito host migrates with --hexis-signer"
  assert_contains "$out" "Jito -> Firedancer with the Concorde"

  it "the Hexis-issued signer brings the Hexis token ledgers"
  assert_contains "$out" 'okx_token_ledger = "FZ2tnmpsGG2JxruyAPRrSBFARGAQtcVvTmt8z83kM5yC"'

  out="$(STUB_RESPONSES=$WORK/fd-jito.responses reawaken "${base_args[@]}" --generate-signer)"

  it "a generated signer gets no token ledgers"
  assert_contains "$out" 'okx_token_ledger = ""'

  it "a generated signer comes with the flash-loan warning"
  assert_contains "$out" "flash loans off until Hexis has its MarginFi account"

  # --- plain Agave source ---
  fd_host "$WORK/fd-agave.responses" "" "    --known-validator K1 ${L}"
  out="$(STUB_RESPONSES=$WORK/fd-agave.responses reawaken "${base_args[@]}" --hexis-signer "$WORK/signer.json")"

  it "recognises a plain Agave host"
  assert_contains "$out" "Startup script: plain Agave"

  it "plain Agave needs a Block Engine decision"
  assert_contains "$out" "has no --block-engine-url"

  out="$(STUB_RESPONSES=$WORK/fd-agave.responses reawaken "${base_args[@]}" --hexis-signer "$WORK/signer.json" \
        --block-engine-url https://frankfurt.mainnet.block-engine.jito.wtf)"

  it "plain Agave with a Block Engine still needs a commission"
  assert_contains "$out" "pass --commission-bps"

  out="$(STUB_RESPONSES=$WORK/fd-agave.responses reawaken "${base_args[@]}" --hexis-signer "$WORK/signer.json" \
        --block-engine-url https://frankfurt.mainnet.block-engine.jito.wtf --commission-bps 800)"

  it "plain Agave migrates once the Block Engine is given"
  assert_contains "$out" 'url = "https://frankfurt.mainnet.block-engine.jito.wtf"'

  it "plain Agave gets the Jito mainnet tip distribution authority"
  assert_contains "$out" "tip_distribution_authority = \"$FD_TIP_DISTRIBUTION_AUTHORITY\""

  it "fewer than three known validators falls back to any gossip peer"
  assert_contains "$out" "Snapshots from: any gossip peer"

  out="$(STUB_RESPONSES=$WORK/fd-agave.responses reawaken "${base_args[@]}" --hexis-signer "$WORK/signer.json" --no-block-engine)"

  it "--no-block-engine leaves the bundle tile out"
  assert_not_contains "$out" "[tiles.bundle]"

  it "--no-block-engine is called out in the plan"
  assert_contains "$out" "Block Engine:   OFF"

  # --- refusals ---
  fd_host "$WORK/fd-placeholder.responses" "" "${KV}    --block-engine-url <FILL_IN_BLOCK_ENGINE_URL> ${L}    --commission-bps 0 ${L}${HEXIS}"
  it "refuses a validator.sh that still has an arise.sh placeholder"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-placeholder.responses reawaken "${base_args[@]}")" "still has a placeholder for --block-engine-url"

  fd_host "$WORK/fd-noavx.responses" "flags=" "${KV}${JITO}${HEXIS}"
  it "refuses a CPU without AVX2"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-noavx.responses reawaken "${base_args[@]}")" "has no AVX2"

  fd_host "$WORK/fd-glibc.responses" "glibc=2.35" "${KV}${JITO}${HEXIS}"
  it "refuses a glibc older than the build needs"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-glibc.responses reawaken "${base_args[@]}")" "glibc 2.35 is older than the 2.38"

  sed 's/5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d/4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY/' \
    "$WORK/fd-hexis.responses" > "$WORK/fd-testnet.responses"
  it "refuses a testnet validator"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-testnet.responses reawaken "${base_args[@]}")" "mainnet only"

  it "refuses Concorde tables with no [arb] table"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-hexis.responses reawaken stage --host 1.2.3.4 --ssh-key "$WORK/key" \
    --concorde-tables "$WORK/id.json" --dry-run)" "refusing to guess"

  it "refuses a signer flag pair that contradicts itself"
  assert_contains "$(reawaken stage --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-signer "$WORK/signer.json" --generate-signer)" \
    "either --hexis-signer or --generate-signer"

  it "requires a mode"
  assert_contains "$(reawaken --host 1.2.3.4)" "First argument must be"

  # --- cutover / rollback ---
  it "cutover refuses a host with nothing staged"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-hexis.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)" \
    "is not staged"

  fd_host "$WORK/fd-staged.responses" "fd_unit=yes\nfd_config=yes\nfd_signer=yes\nfd_release=v26.10.8+concorde.4" "${KV}${JITO}${HEXIS}"
  out="$(STUB_RESPONSES=$WORK/fd-staged.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)"

  it "cutover waits for a restart window before stopping Agave"
  assert_contains "$out" "wait for a restart window (min-idle-time 90m, max-delinquent-stake 5%)"

  it "and takes a shorter one when asked"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-staged.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run --min-idle-time 30)" \
    "wait for a restart window (min-idle-time 30m, max-delinquent-stake 5%)"

  it "cutover disables the Agave unit so a reboot cannot bring it back"
  assert_contains "$out" "systemctl stop sol; systemctl disable sol"

  it "cutover fetches the full snapshot from the mirror before anything stops"
  assert_contains "$out" "pre-download the full snapshot from https://snapshots.avorio.network/mainnet-beta into /mnt/ledger/firedancer/snapshots"

  it "and not at all with --no-snapshot-prefetch"
  assert_not_contains "$(STUB_RESPONSES=$WORK/fd-staged.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run --no-snapshot-prefetch)" "pre-download"

  it "cutover declares the restart to perch, with room for a reboot and a snapshot download"
  assert_contains "$out" "perch maint restart 2h, if the host runs perch"

  it "cutover takes the dead RPC endpoint out of perch"
  assert_contains "$out" "drop this host's own RPC from perch's endpoints, if the host runs perch"

  it "and does so before Firedancer starts, so a reboot leaves nothing to come back for"
  assert_order "$out" "drop this host's own RPC from perch's endpoints" "systemctl start firedancer"

  it "cutover makes room for the 1 GiB pages before the start"
  assert_order "$out" "drop the page cache and compact memory" "systemctl start firedancer"
  assert_order "$out" "point perch at Firedancer's metrics" "systemctl start firedancer"

  it "the dry run says a reboot may be offered"
  assert_contains "$out" "offer to reboot, then wait for Firedancer to come up"

  # --- a real cutover against the stub: order of the steps, and the reboot ---
  # cut_run <name> <facts> <script responses> <stdin> args... -> $WORK/<name>.{out,scripts}, status in $cut_rc
  cut_run() {
    local name="$1" facts="$2" scripts="$3" input="$4"; shift 4
    fd_host "$WORK/$name.host" "fd_unit=yes\nfd_config=yes\nfd_signer=yes\nfd_release=v26.10.8+concorde.4\nhp1g_total=0\nuptime_days=12\nboot_id=boot-old${facts:+\\n}${facts}" "${KV}${JITO}${HEXIS}"
    {
      printf '%s\n' '*firedancer mem*|  Total Memory Locked      189 GiB + 644 MiB\n  Required Gigantic Pages  183'
      printf '%s\n' '*is-active firedancer*|active'
      cat "$WORK/$name.host"
    } > "$WORK/$name.responses"
    printf '%b' "$scripts" > "$WORK/$name.script-responses"
    : > "$WORK/$name.scripts"
    printf '%b' "$input" | STUB_RESPONSES="$WORK/$name.responses" STUB_SCRIPT_RESPONSES="$WORK/$name.script-responses" \
      STUB_SCRIPT_LOG="$WORK/$name.scripts" SUDO_PASS=pw REBOOT_POLL_SECONDS=0 \
      reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --now --no-snapshot-prefetch "$@" > "$WORK/$name.out"
    cut_rc=$?
  }

  cut_run plain "" "" "" --yes
  it "a cutover that finds its pages completes without a reboot"
  assert_eq "$cut_rc" "0"
  assert_contains "$(cat "$WORK/plain.out")" "cutover complete"
  assert_not_contains "$(cat "$WORK/plain.scripts")" "systemctl reboot"

  it "the script on the host deals with perch before it starts Firedancer"
  assert_order "$(cat "$WORK/plain.scripts")" 'perch_cfg="/home/sol/perch/config.toml"' "systemctl start firedancer"

  it "and frees and compacts memory before it starts Firedancer"
  assert_order "$(cat "$WORK/plain.scripts")" "compact_memory" "systemctl start firedancer"

  it "and points perch at Firedancer's own metrics before it starts"
  assert_order "$(cat "$WORK/plain.scripts")" 'perch_fd_config="/home/sol/firedancer/config.toml"; perch_fd_min="1.6.0"' "systemctl start firedancer"

  it "and stops Agave before any of that"
  assert_order "$(cat "$WORK/plain.scripts")" "systemctl stop sol" 'perch_cfg="/home/sol/perch/config.toml"'

  NEEDS_REBOOT='*systemctl start firedancer*|@exit 42\n'
  cut_run reboot-yes "" "$NEEDS_REBOOT" "" --yes
  printf '%s\n' '*cat /proc/sys/kernel/random/boot_id*|boot-new' > "$WORK/boot-new"
  cat "$WORK/boot-new" "$WORK/reboot-yes.responses" > "$WORK/reboot-back.responses"
  rb_out="$(STUB_RESPONSES="$WORK/reboot-back.responses" STUB_SCRIPT_RESPONSES="$WORK/reboot-yes.script-responses" \
        STUB_SCRIPT_LOG="$WORK/reboot-back.scripts" SUDO_PASS=pw REBOOT_POLL_SECONDS=0 \
        reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --now --no-snapshot-prefetch --yes)"; rc=$?
  it "when the pages cannot be reserved, cutover reboots the host and waits for Firedancer"
  assert_eq "$rc" "0"
  assert_contains "$rb_out" "could not reserve its 1 GiB pages"
  assert_contains "$(cat "$WORK/reboot-back.scripts")" "systemctl reboot"
  assert_contains "$rb_out" "firedancer.service started after the reboot"
  assert_contains "$rb_out" "cutover complete"

  it "a host that does not come back is reported, not waited on forever"
  assert_eq "$cut_rc" "1"
  assert_contains "$(cat "$WORK/reboot-yes.out")" "has not come back"
  assert_not_contains "$(cat "$WORK/reboot-yes.out")" "cutover complete"

  cut_run reboot-no "" "$NEEDS_REBOOT" "yes\nno\n"
  it "the reboot is asked for, and declining it reboots nothing"
  assert_eq "$cut_rc" "1"
  assert_contains "$(cat "$WORK/reboot-no.out")" "Not rebooted"
  assert_not_contains "$(cat "$WORK/reboot-no.scripts")" "systemctl reboot"

  it "declining says nothing needs to be run after the reboot, and how to go back"
  assert_contains "$(cat "$WORK/reboot-no.out")" "nothing needs to be run afterwards"
  assert_contains "$(cat "$WORK/reboot-no.out")" "reawaken.sh rollback --host 1.2.3.4"

  cut_run other-failure "" '*systemctl start firedancer*|@exit 1\n' "" --yes
  it "any other start failure stops there and offers no reboot"
  assert_eq "$cut_rc" "1"
  assert_not_contains "$(cat "$WORK/other-failure.out")" "Reboot"
  assert_not_contains "$(cat "$WORK/other-failure.scripts")" "systemctl reboot"

  # --- huge-page outlook in status ---
  hp_status() {   # <facts> -> status output
    fd_host "$WORK/hp.host" "fd_unit=yes\nfd_config=yes\nfd_signer=yes\n$1" "${KV}${JITO}${HEXIS}"
    { printf '%s\n' '*firedancer mem*|  Total Memory Locked      189 GiB\n  Required Gigantic Pages  183'; cat "$WORK/hp.host"; } > "$WORK/hp.responses"
    STUB_RESPONSES="$WORK/hp.responses" reawaken status --host 1.2.3.4 --ssh-key "$WORK/key"
  }
  it "status says a long-running host should expect the reboot"
  assert_contains "$(hp_status "hp1g_total=0\nuptime_days=12")" "183 one-GiB pages needed, 0 reserved. Up 12 day(s): expect cutover to need a reboot"

  it "status says no reboot is needed when the pages are already reserved"
  assert_contains "$(hp_status "hp1g_total=183\nuptime_days=12")" "183 already reserved — no reboot needed"

  it "status says a host booted today usually finds them"
  assert_contains "$(hp_status "hp1g_total=0\nuptime_days=0")" "Booted today"

  it "status on a running Firedancer says the pages are in use"
  assert_contains "$(hp_status "hp1g_total=183\nuptime_days=3\nfd_active=active")" "held by the running Firedancer"

  it "cutover hands Agave's newest snapshot to Firedancer"
  assert_contains "$out" "seed /mnt/ledger/firedancer/snapshots with the newest snapshot in /mnt/ledger"

  it "cutover carries the vote history into Firedancer's base directory"
  assert_contains "$out" "copy vote_history-UNSTAKEDpk.bin from /mnt/ledger to /mnt/ledger/firedancer; move any other identity's aside"

  it "cutover leaves jag-snap alone on a host that never ran it"
  assert_not_contains "$out" "jag-snap"

  # A host whose Agave advertises its RPC through the jag-snap proxy
  JAG="    --public-rpc-address 1.2.3.4:18899 ${L}"
  fd_host "$WORK/fd-jag.responses" "fd_unit=yes\nfd_config=yes\nfd_signer=yes" "${KV}${JITO}${HEXIS}${JAG}"

  it "the plan says jag-snap goes away at cutover"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-jag.responses reawaken "${base_args[@]}")" "jag-snap:       retired at cutover"

  it "cutover retires jag-snap, which has nothing to serve on Firedancer"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-jag.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)" \
    "stop the jag-snap container and close 18899/tcp"

  fd_host "$WORK/fd-jag-live.responses" "fd_unit=yes\nfd_config=yes\nfd_active=active\nagave_active=inactive" "${KV}${JITO}${HEXIS}${JAG}"
  it "rollback brings jag-snap back with Agave"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-jag-live.responses reawaken rollback --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)" \
    "start the jag-snap container and reopen 18899/tcp"

  out="$(STUB_RESPONSES=$WORK/fd-jag-live.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)"

  it "the plan shows which key the identity symlink resolves to"
  plan="$(STUB_RESPONSES=$WORK/fd-jag.responses reawaken "${base_args[@]}")"
  assert_contains "$plan" "Identity:       /home/sol/identity.json -> /home/sol/unstaked_identity.json  UNSTAKEDpk"

  it "and the authorized voter's pubkey next to it"
  assert_contains "$plan" "Auth voter:     /home/sol/staked_identity.json  STAKEDpk"

  it "cutover says which identity Firedancer starts with"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-jag.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)" \
    "identity /home/sol/identity.json -> /home/sol/unstaked_identity.json  UNSTAKEDpk"

  it "cutover on a host already on Firedancer still retires jag-snap"
  assert_contains "$out" "stop the jag-snap container and close 18899/tcp, if still up"

  it "and does not stop or start a validator there"
  assert_not_contains "$out" "systemctl"

  out="$(STUB_RESPONSES=$WORK/fd-staged.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run --now)"

  it "cutover --now skips the restart window"
  assert_not_contains "$out" "wait for a restart window"

  it "rollback does nothing while Agave is the one running"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-staged.responses reawaken rollback --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)" \
    "already running"

  fd_host "$WORK/fd-live.responses" "fd_unit=yes\nfd_config=yes\nfd_active=active\nagave_active=inactive" "${KV}${JITO}${HEXIS}"
  out="$(STUB_RESPONSES=$WORK/fd-live.responses reawaken rollback --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)"

  # --- unit: bring an existing host's unit and pre-start step up to date ---
  unit_out="$(STUB_RESPONSES=$WORK/fd-live.responses reawaken unit --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)"
  it "unit shows the new firedancer.service and the pre-start step, and restarts nothing"
  assert_contains "$unit_out" "[DRY RUN] install ${FD_PREFETCH_SCRIPT}: before each start, fetch the full snapshot from ${FD_SNAPSHOT_MIRROR} into /mnt/ledger/firedancer/snapshots"
  assert_contains "$unit_out" "ExecStartPre=-${FD_PREFETCH_SCRIPT}"
  assert_contains "$unit_out" "Firedancer is not restarted"

  : > "$WORK/unit.scripts"
  unit_out="$(STUB_RESPONSES=$WORK/fd-live.responses STUB_SCRIPT_LOG="$WORK/unit.scripts" SUDO_PASS=pw \
      reawaken unit --host 1.2.3.4 --ssh-key "$WORK/key")"; rc=$?
  it "unit installs the script as root's, then the unit, then reloads systemd"
  assert_eq "$rc" "0"
  assert_order "$(cat "$WORK/unit.scripts")" "chown root:root ${FD_PREFETCH_SCRIPT}.new" "cat > /etc/systemd/system/firedancer.service"
  assert_order "$(cat "$WORK/unit.scripts")" "cat > /etc/systemd/system/firedancer.service" "systemctl daemon-reload"
  assert_contains "$(cat "$WORK/unit.scripts")" 'PF_TO="/mnt/ledger/firedancer/snapshots"'

  it "and never stops, starts or restarts a validator"
  assert_eq "$(grep -cE 'systemctl (stop|start|restart|try-restart|enable|disable)' "$WORK/unit.scripts")" "0"

  : > "$WORK/unit.scripts"
  STUB_RESPONSES=$WORK/fd-live.responses STUB_SCRIPT_LOG="$WORK/unit.scripts" SUDO_PASS=pw \
      reawaken unit --host 1.2.3.4 --ssh-key "$WORK/key" --no-snapshot-prefetch >/dev/null
  it "unit --no-snapshot-prefetch takes the pre-start step out again"
  assert_contains "$(cat "$WORK/unit.scripts")" "rm -f ${FD_PREFETCH_SCRIPT}"
  assert_not_contains "$(cat "$WORK/unit.scripts")" "ExecStartPre=-"

  unit_out="$(STUB_RESPONSES=$WORK/fd-hexis.responses reawaken unit --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)"; rc=$?
  it "unit refuses a host where Firedancer was never staged"
  assert_eq "$rc" "1"
  assert_contains "$unit_out" "Firedancer is not staged"

  it "rollback releases Firedancer's huge pages before Agave starts"
  assert_contains "$out" "firedancer configure fini all"

  live_cut="$(STUB_RESPONSES=$WORK/fd-live.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)"
  it "cutover on a host already on Firedancer still points perch at its metrics"
  assert_contains "$live_cut" "nothing to cut over"
  assert_contains "$live_cut" "[DRY RUN] point perch at Firedancer's metrics, if the host runs perch 1.6.0 or newer"

  it "rollback stops perch reading Firedancer's metrics"
  assert_contains "$out" "[DRY RUN] stop perch reading Firedancer's metrics, if it was"

  it "rollback re-enables the Agave unit"
  assert_contains "$out" "systemctl enable sol; systemctl start sol"

  # --- upgrade: a host already on Firedancer -----------------------------------
  up=(upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --concorde-tables "$T" --dry-run)
  fd_host "$WORK/fd-up.responses" "fd_unit=yes\nfd_config=yes\nfd_signer=yes\nfd_active=active\nfd_enabled=enabled\nagave_active=inactive\nfd_release=v1+concorde.1\nfd_version=1.0" "${KV}${JITO}${HEXIS}"
  printf '%s\n' '*test -x /home/sol/firedancer/releases/v0+concorde.9/firedancer*|yes' '*cat /home/sol/firedancer/.previous-release*|v0+concorde.9' >> "$WORK/fd-up.responses"
  out="$(STUB_RESPONSES=$WORK/fd-up.responses reawaken "${up[@]}" --fd-tag v2+concorde.1)"

  it "staging a release writes a unit that fetches the snapshot from the mirror before a start"
  assert_contains "$out" "ExecStartPre=-${FD_PREFETCH_SCRIPT}"
  assert_contains "$out" "[DRY RUN] ${FD_PREFETCH_SCRIPT}: before each start, fetch the full snapshot from ${FD_SNAPSHOT_MIRROR}"

  it "and with --no-snapshot-prefetch it does not"
  assert_not_contains "$(STUB_RESPONSES=$WORK/fd-up.responses reawaken "${up[@]}" --fd-tag v2+concorde.1 --no-snapshot-prefetch)" "snapshot-prefetch"

  it "upgrade names the release it leaves and the one it moves to"
  assert_contains "$out" "Firedancer v1+concorde.1 -> v2+concorde.1"

  it "upgrade waits for a window with the binary that is running, not the new one"
  assert_contains "$out" "/home/sol/firedancer/releases/v1+concorde.1/firedancer wait --min-idle-seconds 1200"

  it "upgrade fetches the full snapshot from the mirror before the restart"
  assert_contains "$out" "pre-download the full snapshot from https://snapshots.avorio.network/mainnet-beta into /mnt/ledger/firedancer/snapshots"

  it "upgrade declares the restart to perch"
  assert_contains "$out" "perch maint restart 2h, if the host runs perch"

  it "upgrade restarts Firedancer onto the new release"
  assert_contains "$out" "systemctl restart firedancer (onto v2+concorde.1)"

  it "upgrade never touches the Agave unit"
  assert_not_contains "$out" "systemctl stop sol"

  it "upgrade --now skips the wait"
  assert_not_contains "$(STUB_RESPONSES=$WORK/fd-up.responses reawaken "${up[@]}" --fd-tag v2+concorde.1 --now)" "wait --min-idle-seconds"

  out="$(STUB_RESPONSES=$WORK/fd-up.responses reawaken upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run --previous)"

  it "upgrade --previous goes back to the release recorded before the last switch"
  assert_contains "$out" "point /home/sol/firedancer/firedancer at releases/v0+concorde.9/firedancer"

  it "and checks the config against that older binary first"
  assert_contains "$out" "check /home/sol/firedancer/config.toml with /home/sol/firedancer/releases/v0+concorde.9/firedancer mem"

  it "and restarts onto it"
  assert_contains "$out" "systemctl restart firedancer (onto v0+concorde.9)"

  fd_host "$WORK/fd-up-noprev.responses" "fd_unit=yes\nfd_config=yes\nfd_active=active\nfd_enabled=enabled\nagave_active=inactive\nfd_release=v1+concorde.1" "${KV}${JITO}${HEXIS}"
  it "upgrade --previous refuses when no earlier release was recorded"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-up-noprev.responses reawaken upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run --previous 2>&1 || true)" \
    "nothing to go back to"

  it "upgrade refuses on a host where Agave is still the one running"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-staged.responses reawaken "${up[@]}" --fd-tag v2+concorde.1 2>&1 || true)" \
    "upgrade is for a host already on Firedancer"

  it "upgrade refuses on a host with no Firedancer at all"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-jag.responses reawaken "${up[@]}" --fd-tag v2+concorde.1 2>&1 || true)" \
    "Firedancer is not installed"

  it "upgrade needs to be told which release"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-up.responses reawaken "${up[@]}" 2>&1 || true)" "upgrade needs the release to move to"

  it "--previous and a release cannot be given together"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-up.responses reawaken "${up[@]}" --previous --fd-tag v2+concorde.1 2>&1 || true)" "not both"

  it "--previous is refused outside upgrade"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-up.responses reawaken stage --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run --previous 2>&1 || true)" \
    "--previous only goes with 'upgrade'"

  it "cutover does nothing when Firedancer is already the one running"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-live.responses reawaken cutover --host 1.2.3.4 --ssh-key "$WORK/key" --dry-run)" \
    "already running"

  it "status reports which client is running"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-live.responses reawaken status --host 1.2.3.4 --ssh-key "$WORK/key")" \
    "Running now: Firedancer (firedancer.service)"

  # --- vanilla Firedancer: the operator's own build, no Hexis parts ---
  up_args=(stage --host 1.2.3.4 --ssh-key "$WORK/key" --vanilla --fd-binary "$WORK/binary")
  out="$(STUB_RESPONSES=$WORK/fd-jito.responses reawaken "${up_args[@]}" --dry-run)"

  it "--vanilla stages vanilla Firedancer from a binary, with nothing fetched from Hexis"
  assert_contains "$out" "Plan for sol@1.2.3.4 (Jito -> vanilla Firedancer)"
  assert_not_contains "$out" "Fetching the Concorde config tables"

  it "its config has no arb table and no signer"
  assert_contains "$out" "# Generated by reawaken.sh — vanilla Firedancer."
  assert_not_contains "$out" "[arb]"
  assert_not_contains "$out" "signer_key_path"

  it "it carries the Jito settings over like the Concorde does"
  assert_contains "$out" 'url = "https://ny.mainnet.block-engine.jito.wtf"'
  assert_contains "$out" "commission_bps = 1000"
  assert_contains "$out" "alpenglow = true"

  it "metrics stay on loopback and no port is opened to Hexis"
  assert_contains "$out" 'prometheus_listen_address = "127.0.0.1"'
  assert_contains "$out" "Arb:            none — vanilla Firedancer. No signer, no Control port"
  assert_not_contains "$out" "188.40.61.182"

  it "RPC is off unless asked for, as on the Concorde"
  assert_contains "$(grep -A1 -F '[tiles.rpc]' <<<"$out")" "enabled = false"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-jito.responses reawaken "${up_args[@]}" --dry-run --enable-rpc | grep -A1 -F '[tiles.rpc]')" "enabled = true"

  it "the unit says which Firedancer it is"
  assert_contains "$out" "Description=vanilla Firedancer"

  it "--vanilla with a Hexis release tag is refused, and says how to get a binary"
  out="$(reawaken stage --host 1.2.3.4 --ssh-key "$WORK/key" --vanilla --fd-tag 'v26.11.1+concorde.2')"
  assert_contains "$out" "Vanilla Firedancer has no prebuilt releases"
  assert_contains "$out" "--fd-binary <path>"

  it "--vanilla with an arb signer is refused"
  assert_contains "$(reawaken "${up_args[@]}" --hexis-signer "$WORK/signer.json")" "belong to the Hexis Concorde, not to --vanilla"
  assert_contains "$(reawaken "${up_args[@]}" --generate-signer)" "belong to the Hexis Concorde, not to --vanilla"

  it "vanilla is accepted on a cluster that is not mainnet, where the Concorde is not"
  sed 's/5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d/4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY/' \
    "$WORK/fd-jito.responses" > "$WORK/fd-jito-testnet.responses"
  out="$(STUB_RESPONSES=$WORK/fd-jito-testnet.responses reawaken "${up_args[@]}" --dry-run --no-block-engine)"
  assert_contains "$out" "Plan for sol@1.2.3.4 (Jito -> vanilla Firedancer)"
  assert_contains "$out" 'expected_genesis_hash = "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY"'
  assert_contains "$(STUB_RESPONSES=$WORK/fd-jito-testnet.responses reawaken stage --host 1.2.3.4 --ssh-key "$WORK/key" --concorde-tables "$T" --hexis-signer "$WORK/signer.json" --dry-run)" "mainnet only"

  it "there the mainnet snapshot mirror is not used unless one is named"
  assert_contains "$out" "no snapshot pre-download (the default mirror is mainnet's)"
  assert_not_contains "$out" "ExecStartPre=-${FD_PREFETCH_SCRIPT}"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-jito-testnet.responses reawaken "${up_args[@]}" --dry-run --no-block-engine --snapshot-mirror https://snap.example/testnet)" "ExecStartPre=-${FD_PREFETCH_SCRIPT}"

  it "and Jito's mainnet tip programs are not assumed"
  assert_contains "$(STUB_RESPONSES=$WORK/fd-jito-testnet.responses reawaken "${up_args[@]}" --dry-run)" "does not name Jito's tip programs and upload authority for this cluster"

  it "a host whose config has no [arb] table is recognised as vanilla without the flag"
  fd_host "$WORK/fd-up-live.responses" 'agave_active=inactive\nagave_enabled=disabled\nfd_active=active\nfd_enabled=enabled\nfd_unit=yes\nfd_release=v26.11.0\nfd_config=yes\nfd_arb=no' "${KV}${JITO}"
  out="$(STUB_RESPONSES=$WORK/fd-up-live.responses reawaken upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --fd-binary "$WORK/binary" --dry-run)"
  assert_contains "$out" "has no [arb] table: this host has vanilla Firedancer"
  assert_contains "$out" "# Generated by reawaken.sh — vanilla Firedancer."
  assert_not_contains "$out" "Fetching the Concorde config tables"

  it "naming a Hexis release there moves it to the Concorde instead"
  out="$(STUB_RESPONSES=$WORK/fd-up-live.responses reawaken upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --fd-tag 'v26.11.1+concorde.2' --concorde-tables "$T" --hexis-signer "$WORK/signer.json" --dry-run)"
  assert_not_contains "$out" "this host has vanilla Firedancer"
  assert_contains "$out" "# Generated by reawaken.sh — Firedancer with the Hexis Concorde."

  it "a Concorde host is not mistaken for a vanilla one"
  fd_host "$WORK/fd-cc-live.responses" 'agave_active=inactive\nfd_active=active\nfd_enabled=enabled\nfd_unit=yes\nfd_release=v26.10.8+concorde.4\nfd_config=yes\nfd_arb=yes\nfd_signer=yes' "${KV}${JITO}"
  out="$(STUB_RESPONSES=$WORK/fd-cc-live.responses reawaken upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --fd-binary "$WORK/binary" --concorde-tables "$T" --dry-run)"
  assert_not_contains "$out" "vanilla Firedancer"

  it "a real vanilla stage installs no signer and opens only Firedancer's own ports"
  { printf '%s\n' '*firedancer.incoming version*|v26.11.1 (0123abc)'
    printf '%s\n' '*firedancer mem*|  Total Memory Locked      189 GiB + 644 MiB\n  Required Gigantic Pages  183'
    cat "$WORK/fd-jito.responses"; } > "$WORK/fd-up-stage.responses"
  out="$(STUB_RESPONSES=$WORK/fd-up-stage.responses STUB_SCRIPT_LOG="$WORK/up-stage.scripts" SUDO_PASS=pw reawaken "${up_args[@]}" --yes; echo "rc=$?")"
  scripts="$(cat "$WORK/up-stage.scripts")"
  assert_contains "$out" "rc=0"
  assert_contains "$out" "Staging v26.11.1"
  assert_contains "$out" "stage complete"
  assert_contains "$scripts" 'mkdir -p "releases/v26.11.1"'
  assert_contains "$scripts" "ufw allow 8001/udp"
  assert_not_contains "$scripts" "port ${FD_CONTROL_PORT}"
  assert_not_contains "$scripts" "port ${FD_METRICS_PORT}"
  assert_not_contains "$scripts" "arb-signer.json"
  assert_not_contains "$scripts" "[arb]"
  assert_contains "$scripts" "Description=vanilla Firedancer"

  it "a binary that does not report a plain version is staged under a name made from its checksum"
  sed 's/^\*firedancer.incoming version\*|.*/*firedancer.incoming version*|weird;name here/' "$WORK/fd-up-stage.responses" > "$WORK/fd-up-odd.responses"
  out="$(STUB_RESPONSES=$WORK/fd-up-odd.responses STUB_SCRIPT_LOG="$WORK/up-odd.scripts" SUDO_PASS=pw reawaken "${up_args[@]}" --yes)"
  assert_contains "$out" "Staging build-$(shasum -a 256 "$WORK/binary" | cut -c1-12)"
  assert_not_contains "$(cat "$WORK/up-odd.scripts")" "weird;name"
fi

# === system.sh ===============================================================
if should_run "system"; then
group "system.sh"
  source "${ROOT}/lib/hexis.sh"
  source "${ROOT}/lib/firedancer.sh"
  T="$ROOT/test/fixtures/concorde-tables.toml"
  # st_host <file> <system-facts, \n separated> <validator.sh body lines>
  st_host() {
    {
      printf '%s\n' '*echo ok*|ok'
      printf '%s\n' "*system-facts*|$2"
      printf '%s\n' "*cat /home/sol/validator.sh*|#!/bin/bash\\nexec agave-validator \\\\\\\\\\n    --identity /home/sol/identity.json \\\\\\\\\\n$3    --ledger /mnt/ledger"
    } > "$1"
  }
  SL='\\\\\\\\\\n'
  S_HEXIS="    --arb-config /home/sol/hexis/arb-config.toml ${SL}"
  S_JITO="    --block-engine-url https://ny.mainnet.block-engine.jito.wtf ${SL}"
  export STUB_RELEASES='v26.2.0+concorde.1|firedancer-linux-amd64,firedancer-linux-amd64-zen4\nv5.0.0+concorde.1|agave-validator-linux-amd64,checksums.txt\nv26.1.0+concorde.1|firedancer-linux-amd64\nv4.0.0+concorde.1|agave-validator-linux-amd64'
  st=(--host 1.2.3.4 --ssh-key "$WORK/key")

  it "tells the two clients' releases apart by what they ship"
  assert_eq "$(hexis_latest_tag "$(printf '%b' "$STUB_RELEASES")" agave-validator-linux-amd64)" "v5.0.0+concorde.1"
  assert_eq "$(hexis_latest_tag "$(printf '%b' "$STUB_RELEASES")" firedancer-linux-amd64)" "v26.2.0+concorde.1"

  st_host "$WORK/st-hexis.responses" 'agave_active=active\nfd_enabled=disabled\nfd_release=\nfd_config=no\nagave_release=v4.0.0+concorde.1' "$S_HEXIS"
  out="$(STUB_RESPONSES=$WORK/st-hexis.responses system "${st[@]}")"

  it "reports the client and release a Hexis Agave host runs"
  assert_contains "$out" "Runs:            Hexis Agave v4.0.0+concorde.1, sol.service active"

  it "offers the newer Hexis Agave release, restarting at a safe window"
  assert_contains "$out" "upgrade     ./ascend.sh upgrade --host 1.2.3.4 --ssh-key $WORK/key --hexis-tag 'v5.0.0+concorde.1' --restart"

  it "offers staging Firedancer with the newest Firedancer release, not the Agave one"
  assert_contains "$out" "firedancer  ./reawaken.sh stage --host 1.2.3.4 --ssh-key $WORK/key --fd-tag 'v26.2.0+concorde.1'"

  it "does not offer going back to Agave on a host that is on Agave"
  assert_not_contains "$out" "rollback"

  it "with a goal and --print shows the command without running it"
  out="$(STUB_RESPONSES=$WORK/st-hexis.responses system upgrade "${st[@]}" --print -- --dry-run)"
  assert_contains "$out" "Would run: ./ascend.sh upgrade --host 1.2.3.4 --ssh-key $WORK/key --hexis-tag 'v5.0.0+concorde.1' --restart --dry-run"
  assert_not_contains "$out" "Mode:"

  it "--tag overrides the newest release"
  assert_contains "$(STUB_RESPONSES=$WORK/st-hexis.responses system upgrade "${st[@]}" --tag v4.9.9 --print)" "--hexis-tag 'v4.9.9'"

  it "hands the goal to the script that owns it"
  assert_contains "$(STUB_RESPONSES=$WORK/st-hexis.responses system firedancer "${st[@]}" -- --dry-run --concorde-tables "$T")" "Mode: stage  Host: sol@1.2.3.4"

  st_host "$WORK/st-staged.responses" 'agave_active=active\nfd_enabled=disabled\nfd_release=v26.2.0+concorde.1\nfd_config=yes\nagave_release=v5.0.0+concorde.1' "$S_HEXIS"
  out="$(STUB_RESPONSES=$WORK/st-staged.responses system "${st[@]}")"

  it "once Firedancer is staged, the firedancer goal becomes the cutover"
  assert_contains "$out" "firedancer  ./reawaken.sh cutover --host 1.2.3.4 --ssh-key $WORK/key"

  st_host "$WORK/st-fd-jag.responses" "agave_active=inactive\nfd_active=active\nfd_enabled=enabled\nfd_release=v26.1.0+concorde.1\nfd_config=yes\njag_snap=up" "$S_JITO$S_HEXIS"
  # --- the four clients a host can be running ---------------------------------
  S_TESTNET="    --expected-genesis-hash 4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY ${SL}"
  st_host "$WORK/st-testnet.responses" "agave_active=active\nfd_active=inactive\nfd_enabled=disabled" "$S_TESTNET"
  kinds_out="$(STUB_RESPONSES=$WORK/st-testnet.responses system "${st[@]}")"
  it "a plain Agave validator on testnet is reported, with no Hexis move offered"
  assert_contains "$kinds_out" "Runs:            plain Agave"
  assert_contains "$kinds_out" "From here:       nothing — the Hexis builds are mainnet only"
  assert_not_contains "$kinds_out" "./reawaken.sh"

  it "and asking for one there fails with the reason"
  assert_contains "$(STUB_RESPONSES=$WORK/st-testnet.responses system firedancer "${st[@]}" --print || true)" "mainnet only"

  # An vanilla Firedancer somebody else installed: no validator.sh, own config path
  {
    printf '%s\n' '*echo ok*|ok'
    printf '%s\n' '*other-firedancer-kind*|jito'
    printf '%s\n' '*other-firedancer*|/etc/firedancer/config.toml'
  } > "$WORK/st-other-fd.responses"
  kinds_out="$(STUB_RESPONSES=$WORK/st-other-fd.responses system "${st[@]}")"
  it "a Firedancer taking Jito bundles that these scripts did not install is named as that"
  assert_contains "$kinds_out" "Runs:            Firedancer taking Jito bundles, config /etc/firedancer/config.toml"

  it "and is not mistaken for a server with no validator"
  assert_not_contains "$kinds_out" "./arise.sh"

  it "and no goal is run against it"
  assert_contains "$(STUB_RESPONSES=$WORK/st-other-fd.responses system upgrade "${st[@]}" --print || true)" "was not installed by these scripts"
  assert_not_contains "$(STUB_RESPONSES=$WORK/st-other-fd.responses system upgrade "${st[@]}" --print || true)" "Would run"

  st_host "$WORK/st-fd-done.responses" "agave_active=inactive\nfd_active=active\nfd_enabled=enabled\nfd_release=v26.2.0+concorde.1\nfd_config=yes\njag_snap=down\nperch_local=no" "$S_JITO$S_HEXIS"
  it "a finished cutover is not offered again"
  assert_contains "$(STUB_RESPONSES=$WORK/st-fd-done.responses system firedancer "${st[@]}" --print)" "already runs Firedancer"

  st_host "$WORK/st-fd-perch.responses" "agave_active=inactive\nfd_active=active\nfd_enabled=enabled\nfd_release=v26.1.0+concorde.1\nfd_config=yes\njag_snap=down\nperch_local=yes" "$S_JITO$S_HEXIS"
  it "and so is one where perch still watches the RPC port Firedancer does not serve"
  assert_contains "$(STUB_RESPONSES=$WORK/st-fd-perch.responses system firedancer "${st[@]}" --print)" "Would run: ./reawaken.sh cutover --host 1.2.3.4 --ssh-key $WORK/key"

  it "a cutover that Firedancer finished by itself after a reboot is still offered, to retire jag-snap"
  assert_contains "$(STUB_RESPONSES=$WORK/st-fd-jag.responses system firedancer "${st[@]}" --print)" "Would run: ./reawaken.sh cutover --host 1.2.3.4 --ssh-key $WORK/key"

  # --- who holds sudo, and the host checks ---
  HX="agave_active=active\nfd_active=inactive\nfd_enabled=disabled\nfd_config=no\njag_snap=down\nperch_local=no\nagave_release=v5.0.0+concorde.1"
  # adm_host <file> <extra facts> <responses that go first, \n separated>
  adm_host() {
    st_host "$WORK/adm.base" "$HX${2:+\\n}$2" "$S_JITO$S_HEXIS"
    { [[ -n "$3" ]] && printf '%b\n' "$3"; cat "$WORK/adm.base"; } > "$1"
  }
  NO_MONARCH='*monarch@1.2.3.4 true|@fail'

  adm_host "$WORK/adm-ok.responses" "" ""
  out="$(STUB_RESPONSES=$WORK/adm-ok.responses system "${st[@]}")"
  it "a host whose default admin user takes the key is left as it is"
  assert_not_contains "$out" "Admin user:"
  assert_not_contains "$out" "--admin-user"

  adm_host "$WORK/adm-ubuntu.responses" "" "$NO_MONARCH\n*admin-candidates*|ubuntu\\\\nops\n*ubuntu@1.2.3.4*admin-sudo*|nopass"
  out="$(STUB_RESPONSES=$WORK/adm-ubuntu.responses system "${st[@]}")"
  it "a host without the default admin user gets the one that does hold sudo"
  assert_contains "$out" "Admin user:      ubuntu, with passwordless sudo — there is no 'monarch' login for this key"

  it "and every command printed for it carries that user"
  assert_contains "$out" "./reawaken.sh stage --host 1.2.3.4 --ssh-key $WORK/key --admin-user ubuntu"
  assert_contains "$out" "./arise.sh --host 1.2.3.4 --ssh-key $WORK/key --admin-user ubuntu"

  it "the goal that is run carries it too"
  assert_contains "$(STUB_RESPONSES=$WORK/adm-ubuntu.responses system firedancer "${st[@]}" --print)" "--admin-user ubuntu"

  adm_host "$WORK/adm-second.responses" "" "$NO_MONARCH\n*admin-candidates*|deploy\\\\nops\n*deploy@1.2.3.4*admin-sudo*|\n*ops@1.2.3.4*admin-sudo*|pass"
  out="$(STUB_RESPONSES=$WORK/adm-second.responses system "${st[@]}")"
  it "a login that holds no sudo is passed over for one that does"
  assert_contains "$out" "Admin user:      ops, with sudo by password"

  adm_host "$WORK/adm-none.responses" "" "$NO_MONARCH\n*admin-candidates*|deploy\n*deploy@1.2.3.4*admin-sudo*|"
  out="$(STUB_RESPONSES=$WORK/adm-none.responses system "${st[@]}")"
  it "a host with no admin login at all is said to have none"
  assert_contains "$out" "Admin user:      none found"
  assert_contains "$out" "--root-user"

  adm_host "$WORK/adm-given.responses" "" "$NO_MONARCH\n*admin-candidates*|ubuntu\n*ubuntu@1.2.3.4*admin-sudo*|nopass"
  out="$(STUB_RESPONSES=$WORK/adm-given.responses system "${st[@]}" --admin-user ops)"
  it "an --admin-user that was given is not second-guessed"
  assert_contains "$out" "--admin-user ops"
  assert_not_contains "$out" "ubuntu"

  adm_host "$WORK/chk-clean.responses" "chk_root_owner=root\nchk_groups=sol users\nchk_sudo=no\nchk_ufw=active\nchk_keys=" ""
  it "a clean host is said to be clean, with what was looked at"
  assert_contains "$(STUB_RESPONSES=$WORK/chk-clean.responses system "${st[@]}")" "Host checks:     nothing found (owner of /, sol's privileges, firewall, key file modes)"

  adm_host "$WORK/chk-bad.responses" "chk_root_owner=sol\nchk_groups=sol users docker\nchk_sudo=nopass\nchk_ufw=inactive\nchk_keys=/home/sol/staked_identity.json " ""
  out="$(STUB_RESPONSES=$WORK/chk-bad.responses system "${st[@]}")"
  it "a root directory that is not root's is reported with its fix"
  assert_contains "$out" "/ is owned by sol, not root"
  assert_contains "$out" "monarch@1.2.3.4 'sudo chown root:root /'"

  it "the validator user being in the docker group is reported"
  assert_contains "$out" "sol is in the docker group, which is root in all but name"

  it "the validator user holding sudo is reported"
  assert_contains "$out" "sol, the user the validator runs as, holds sudo"

  it "a firewall that is off is reported"
  assert_contains "$out" "the firewall (ufw) is not enabled"

  it "a key file others can read is reported with its fix"
  assert_contains "$out" "readable by other users: /home/sol/staked_identity.json"
  assert_contains "$out" "'chmod 600 /home/sol/staked_identity.json'"

  it "the report still lists what can be done from here"
  assert_contains "$out" "From here:"

  adm_host "$WORK/chk-unknown.responses" "" ""
  it "a host the checks could not read is not called clean"
  assert_not_contains "$(STUB_RESPONSES=$WORK/chk-unknown.responses system "${st[@]}")" "Host checks:"

  it "says there is nothing to upgrade on the newest release"
  assert_contains "$out" "upgrade     nothing to do: already on v5.0.0+concorde.1"

  it "a goal that is already met ends cleanly"
  out="$(STUB_RESPONSES=$WORK/st-staged.responses system upgrade "${st[@]}"; echo "rc=$?")"
  assert_contains "$out" "Nothing to do for 'upgrade'"
  assert_contains "$out" "rc=0"

  st_host "$WORK/st-fd.responses" 'agave_active=inactive\nfd_active=active\nfd_enabled=enabled\nfd_release=v26.1.0+concorde.1\nfd_config=yes\nagave_release=v5.0.0+concorde.1' "$S_HEXIS"
  out="$(STUB_RESPONSES=$WORK/st-fd.responses system "${st[@]}")"

  it "reports a host that runs Firedancer, and the Agave client kept behind it"
  assert_contains "$out" "Runs:            Firedancer with the Hexis Concorde"
  assert_contains "$out" "Firedancer:      v26.1.0+concorde.1, firedancer.service active"

  it "upgrade on a Firedancer host is the Firedancer upgrade"
  assert_contains "$out" "upgrade     ./reawaken.sh upgrade --host 1.2.3.4 --ssh-key $WORK/key --fd-tag 'v26.2.0+concorde.1'"

  it "and the way back to Agave is offered"
  assert_contains "$out" "agave       ./reawaken.sh rollback --host 1.2.3.4 --ssh-key $WORK/key"

  it "never offers the Agave upgrade while Firedancer is the running client"
  assert_not_contains "$out" "ascend.sh"

  st_host "$WORK/st-jito.responses" 'agave_active=active\nfd_enabled=disabled\nfd_release=\nfd_config=no\nagave_release=' "$S_JITO"
  out="$(STUB_RESPONSES=$WORK/st-jito.responses system "${st[@]}")"

  it "a Jito host is offered the move to the Hexis Agave client"
  assert_contains "$out" "hexis       ./ascend.sh migrate --host 1.2.3.4 --ssh-key $WORK/key --hexis-tag 'v5.0.0+concorde.1' --restart"

  it "and is told how to switch between Jito and Agave or change version"
  assert_contains "$out" "./arise.sh --host 1.2.3.4 --ssh-key $WORK/key --identity <staked_identity.json> --vote-account <pubkey> --network <net> --client <jito|agave> --client-version <tag> --restart"

  it "and upgrade there points at arise.sh, which is not run from here"
  out="$(STUB_RESPONSES=$WORK/st-jito.responses system upgrade "${st[@]}" --print; echo "rc=$?")"
  assert_contains "$out" "arise.sh upgrades it"
  assert_contains "$out" "rc=1"

  it "a non-default admin user is passed on to the script that is run"
  assert_contains "$(STUB_RESPONSES=$WORK/st-jito.responses system hexis "${st[@]}" --admin-user ops --print)" \
    "./ascend.sh migrate --host 1.2.3.4 --ssh-key $WORK/key --admin-user ops --hexis-tag"

  printf '%s\n' '*echo ok*|ok' > "$WORK/st-fresh.responses"
  it "a host with no validator is pointed at arise.sh, which is not run from here"
  out="$(STUB_RESPONSES=$WORK/st-fresh.responses system "${st[@]}")"
  assert_contains "$out" "no validator is set up"
  assert_contains "$out" "./arise.sh --host 1.2.3.4"

  : > "$WORK/st-down.responses"
  it "a host that cannot be reached says so, and a goal fails there"
  out="$(STUB_RESPONSES=$WORK/st-down.responses system upgrade "${st[@]}"; echo "rc=$?")"
  assert_contains "$out" "Cannot SSH to sol@1.2.3.4"
  assert_contains "$out" "rc=1"

  st_host "$WORK/st-upfd.responses" 'agave_active=inactive\nfd_active=active\nfd_enabled=enabled\nfd_release=v26.11.0\nfd_config=yes\nfd_arb=no' "$S_JITO"
  out="$(STUB_RESPONSES=$WORK/st-upfd.responses system "${st[@]}")"

  it "an vanilla Firedancer these scripts staged is reported as that"
  assert_contains "$out" "Runs:            vanilla Firedancer"
  assert_not_contains "$out" "Hexis Concorde"

  it "and is not offered a Hexis release to upgrade to"
  assert_not_contains "$out" "--fd-tag"
  assert_contains "$out" "upgrade     vanilla Firedancer has no prebuilt releases: build the new tag for this host, then ./reawaken.sh upgrade --host 1.2.3.4 --ssh-key $WORK/key --fd-binary <path>"

  it "the upgrade goal there says how, and runs nothing"
  out="$(STUB_RESPONSES=$WORK/st-upfd.responses system upgrade "${st[@]}"; echo "rc=$?")"
  assert_contains "$out" "build the new tag for this host"
  assert_contains "$out" "rc=1"
  assert_not_contains "$out" "Mode:"

  it "going back to Agave is still offered there"
  assert_contains "$(STUB_RESPONSES=$WORK/st-upfd.responses system "${st[@]}")" "agave       ./reawaken.sh rollback --host 1.2.3.4"

  it "a release whose tag carries shell syntax is not put into a command"
  out="$(STUB_RELEASES="v9';touch $WORK/pwned;'|agave-validator-linux-amd64" STUB_RESPONSES=$WORK/st-hexis.responses system upgrade "${st[@]}" -- --dry-run; echo "rc=$?")"
  assert_contains "$out" "Ignoring a release whose tag has unexpected characters"
  assert_contains "$out" "rc=1"
  assert_file_missing "$WORK/pwned"

  it "--tag is checked the same way"
  assert_contains "$(STUB_RESPONSES=$WORK/st-hexis.responses system upgrade "${st[@]}" --tag "v1';id;'" --print)" "--tag is not a valid release tag"

  it "a host name with shell syntax is refused before anything connects"
  assert_contains "$(system --host '1.2.3.4;id' --ssh-key "$WORK/key")" "--host is not a hostname or IP"

  it "a key path with a space reaches the next script as one argument"
  cp "$WORK/key" "$WORK/my key"
  assert_contains "$(STUB_RESPONSES=$WORK/st-hexis.responses system upgrade --host 1.2.3.4 --ssh-key "$WORK/my key" --print)" "--ssh-key $WORK/my\\ key"
  unset STUB_RELEASES
fi

# === values that end up in files and commands on the host ====================
if should_run "hardening"; then
group "values checked before they reach the host"
  source "${ROOT}/lib/hexis.sh"
  source "${ROOT}/lib/firedancer.sh"
  hd=("${arise_base[@]}" --ssh-key "$WORK/key" --identity "$WORK/id.json")
  HT=$(printf '\t')

  it "a metrics string that would run a command from validator.sh is refused"
  assert_contains "$(arise "${hd[@]}" --metrics-config 'host=h,db=d,u=u,p=x$(id)')" "--metrics-config contains a character that cannot go into validator.sh"

  it "so is an arb metrics string that would close its quotes"
  assert_contains "$(arise "${hd[@]}" --hexis --hexis-binary "$WORK/binary" --hexis-metrics-config 'host=h,db=d,u=u,p=a"b')" "The arb metrics string contains a character"

  it "an ordinary metrics string is accepted"
  assert_not_contains "$(arise "${hd[@]}" --metrics-config 'host=https://m.example:8086,db=d,u=u_w,p=Pa-ss_1')" "cannot go into validator.sh"

  it "a Hexis address that is not base58 is refused"
  assert_contains "$(arise "${hd[@]}" --hexis --hexis-binary "$WORK/binary" --hexis-okx-token-ledger 'x; id')" "--hexis-okx-token-ledger: not a base58 address"
  assert_contains "$(arise "${hd[@]}" --hexis --hexis-binary "$WORK/binary" --hexis-profit-wallet 'FevX9jr7HQ43anpFpUA88M8eA1Xk22fLVqPG6YEERr4O')" "--hexis-profit-wallet: not a base58 address"
  assert_contains "$(arise "${hd[@]}" --hexis --hexis-binary "$WORK/binary" --hexis-base-mints 'So11111111111111111111111111111111111111112,nope')" "--hexis-base-mints: not a base58 address: nope"

  it "the Control port cannot be opened to every address"
  assert_contains "$(arise "${hd[@]}" --hexis --hexis-binary "$WORK/binary" --hexis-control-allow 0.0.0.0/0)" "--hexis-control-allow must be one IP or a CIDR narrower than /0"

  it "a Hexis release tag with a + in it is a valid tag"
  assert_not_contains "$(arise "${hd[@]}" --hexis --hexis-tag 'v4.2.1+concorde.3')" "is not a valid tag"
  assert_not_contains "$(arise "${hd[@]}" --client firedancer --fd-tag 'v26.10.8+concorde.4' --concorde-tables "$ROOT/test/fixtures/concorde-tables.toml")" "is not a valid tag"

  it "a tag that starts with a dash is not"
  assert_contains "$(arise "${hd[@]}" --hexis --hexis-tag '--repo')" "--hexis-tag is not a valid tag"
  assert_contains "$(arise "${hd[@]}" --hexis --hexis-binary "$WORK/binary" --hexis-setup-tag '-x')" "--hexis-setup-tag is not a valid tag"

  it "ascend.sh checks its paths, names and tags"
  assert_contains "$(ascend upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" --hexis-dir '/home/sol/hexis; id')" "--hexis-dir must be an absolute path without spaces"
  assert_contains "$(ascend upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" --user 'sol;id')" "--user is not a valid user name"
  assert_contains "$(ascend promote --host 1.2.3.4 --ssh-key "$WORK/key" --release 'v1;id')" "--release is not a valid release name"
  assert_contains "$(ascend migrate --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary" --hexis-profit-wallet 'not-a-wallet')" "--hexis-profit-wallet: not a base58 address"

  it "reawaken.sh checks its paths, names and tags"
  rw() { ( cd "$ROOT" && ./reawaken.sh "$@" ) 2>&1; }
  assert_contains "$(rw status --host 1.2.3.4 --ssh-key "$WORK/key" --fd-dir '/home/sol/fd $(id)')" "--fd-dir must be an absolute path without spaces"
  assert_contains "$(rw status --host 1.2.3.4 --ssh-key "$WORK/key" --agave-service 'sol;id')" "--agave-service is not a valid unit name"
  assert_contains "$(rw stage --host 1.2.3.4 --ssh-key "$WORK/key" --fd-tag 'v1;id')" "--fd-tag is not a valid tag"
  assert_contains "$(rw cutover --host 1.2.3.4 --ssh-key "$WORK/key" --min-idle-time soon)" "--min-idle-time must be a number of minutes"

  it "a value read from validator.sh that carries shell syntax is dropped, with a warning"
  vsh="exec agave-validator \\
    --ledger /x\$(touch${HT}/tmp/pwned) \\
    --identity \"/home/sol/identity.json\" \\
    --block-engine-url https://ny.mainnet.block-engine.jito.wtf"
  out="$(fd_vsh_flag "$vsh" "--ledger" 2>&1)"
  assert_contains "$out" "Ignoring --ledger in validator.sh: it is not a plain value"
  assert_not_contains "$out" "touch"

  it "a quoted path loses its quotes and a URL comes through whole"
  assert_eq "$(fd_vsh_flag "$vsh" "--identity")" "/home/sol/identity.json"
  assert_eq "$(fd_vsh_flag "$vsh" "--block-engine-url")" "https://ny.mainnet.block-engine.jito.wtf"

  it "the same goes for a value read from a TOML file on the host"
  out="$(fd_toml_get 'base = "/mnt/ledger/fd$(id)"' base 2>&1)"
  assert_contains "$out" "it is not a plain value"
  assert_eq "$(fd_toml_get 'base = "/mnt/ledger/firedancer"' base)" "/mnt/ledger/firedancer"

  it "root does not change the owner of a path inside the validator user's own directories"
  out="$(arise "${hd[@]}")"
  assert_contains "$out" 'runuser -u "$SOL_USER" -- mkdir -p "$dir"'
  assert_contains "$out" "ExecStart=/usr/local/sbin/sol-fix-mounts"
  assert_not_contains "$out" "ExecStart=/bin/chown"

  it "the boot-time ownership fix leaves alone what the validator user could have swapped"
  # Run the generated helper against a scratch tree, with stat and chown stood
  # in for: the mount point's parent is root's, everything under it is sol's.
  fx="$WORK/fixmounts"; mkdir -p "$fx/bin" "$fx/mnt/ledger/snapshots" "$fx/home/logs"
  printf '%s\n' '#!/bin/sh' 'case "$3" in */mnt) echo root ;; *) echo sol ;; esac' > "$fx/bin/stat"
  printf '%s\n' '#!/bin/sh' 'shift; echo "$@" >> "'"$fx"'/chowned"' > "$fx/bin/chown"
  chmod +x "$fx/bin/stat" "$fx/bin/chown"
  sed -n '/^cat > \/usr\/local\/sbin\/sol-fix-mounts <<FIXEOF$/,/^FIXEOF$/p' "$ROOT/arise.sh" | sed '1d;$d' > "$fx/template"
  # shellcheck disable=SC2034  # read by the eval'd template below
  ( LEDGER_PATH="$fx/mnt/ledger" SNAPSHOTS_PATH="$fx/mnt/ledger/snapshots" ACCOUNTS_PATH="$fx/mnt/ledger" SOL_HOME="$fx/home" SOL_USER=sol
    eval "cat <<FIXEOF
$(cat "$fx/template")
FIXEOF" ) > "$fx/sol-fix-mounts"
  ( PATH="$fx/bin:$PATH" sh "$fx/sol-fix-mounts" ); rc=$?
  assert_eq "$rc" "0"
  assert_contains "$(cat "$fx/chowned")" "$fx/mnt/ledger"
  assert_not_contains "$(cat "$fx/chowned")" "snapshots"
  assert_not_contains "$(cat "$fx/chowned")" "logs"

  it "and still stops the validator from starting when a data directory is missing"
  rmdir "$fx/home/logs"
  ( PATH="$fx/bin:$PATH" sh "$fx/sol-fix-mounts" ) >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "1"
fi

# === arise.sh on a host that already runs a validator =======================
# These run arise.sh for real (not --dry-run) against the stub ssh, which
# answers the host-state probes and records every script and file sent.
if should_run "switch"; then
group "client switch (arise.sh on a live host)"
  PK=7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2
  JITO_REPO=https://github.com/jito-foundation/jito-solana.git
  AGAVE_REPO=https://github.com/anza-xyz/agave.git
  ID_SUM="$(shasum -a 256 "$WORK/id.json" | cut -d' ' -f1)"
  EXE=/home/sol/.local/share/solana/install/releases/v4.4.1-jito/bin/agave-validator
  sw_base=(--host 1.2.3.4 --vote-account "$PK" --network mainnet --commission-bps 0
           --jito-region frankfurt --no-auto-disks --no-xdp --no-perch
           --ssh-key "$WORK/key" --identity "$WORK/id.json")

  # sw_run <name> <state: agave_active fd_active fd_enabled client exe> <build line> <extra ssh responses> <args...>
  # Leaves the output in $out, scripts and written files in $WORK/<name>.scripts
  # and every ssh command line in $WORK/<name>.ssh.
  sw_run() {
    local name="$1" state="$2" build="$3" extra="$4"; shift 4
    local a b c d e
    read -r a b c d e <<<"$state"
    {
      printf '%s\n' "*fd_enabled*|STATE|agave_active|$a\\nSTATE|fd_active|$b\\nSTATE|fd_enabled|$c\\nSTATE|client|$d\\nSTATE|exe|${e:-}"
      printf '%s\n' "*.arise-build*cut*|$build"
      printf '%s\n' '*PROBE_DONE*|PROBE_DONE'
    } > "$WORK/$name.script-responses"
    {
      printf '%s\n' "*sha256sum*|$ID_SUM"
      [[ -n "$extra" ]] && printf '%b\n' "$extra"
      printf '%s\n' '*echo ok*|ok'
    } > "$WORK/$name.responses"
    : > "$WORK/$name.scripts"; : > "$WORK/$name.ssh"
    out="$(STUB_RESPONSES="$WORK/$name.responses" STUB_SCRIPT_RESPONSES="$WORK/$name.script-responses" \
           STUB_SCRIPT_LOG="$WORK/$name.scripts" STUB_LOG="$WORK/$name.ssh" SUDO_PASS=pw \
           arise "${sw_base[@]}" "$@" </dev/null; echo "rc=$?")"
  }
  # The validator.sh that was written, from the recorded files
  sw_vsh() { awk '/^### /{f=0} /^### .*validator\.sh\.arise-tmp/{f=1; next} f' "$WORK/$1.scripts"; }

  # --- a new server ---
  sw_run fresh "inactive inactive not-found none" "BUILD|NONE|" "" --client-version v4.4.1-jito

  it "a new server is installed from scratch"
  assert_contains "$out" "No validator on this host yet"

  it "the client is built there"
  assert_contains "$(cat "$WORK/fresh.scripts")" "CLIENT_REPO=$JITO_REPO"

  it "sol.service is enabled"
  assert_contains "$(cat "$WORK/fresh.scripts")" "HOLD_SOL=false"

  it "nothing is restarted on a new server, even with --restart"
  sw_run fresh-r "inactive inactive not-found none" "BUILD|NONE|" "" --client-version v4.4.1-jito --restart
  assert_contains "$out" "no validator was running on this host"
  assert_not_contains "$(cat "$WORK/fresh-r.ssh")" " exit "

  # --- Jito -> Agave, no restart ---
  sw_run j2a "active inactive not-found jito $EXE" "BUILD|v4.4.1-jito|$JITO_REPO" "" --client agave --client-version v4.4.1

  it "a live Jito host is recognised"
  assert_contains "$out" "This host runs Jito today"

  it "asking for Agave builds Agave beside the Jito build"
  assert_contains "$out" "not agave from $AGAVE_REPO"
  assert_contains "$(cat "$WORK/j2a.scripts")" "CLIENT_REPO=$AGAVE_REPO"

  it "the new validator.sh has no Jito flags"
  assert_not_contains "$(sw_vsh j2a)" "--block-engine-url"
  assert_contains "$(sw_vsh j2a)" "--vote-account $PK"

  it "the running validator is left alone without --restart"
  assert_contains "$out" "The validator that is running was not touched"
  assert_not_contains "$(cat "$WORK/j2a.ssh")" " exit "

  it "the restart command is given, through the binary that is running"
  assert_contains "$out" "$EXE --ledger /home/sol/ledger exit --min-idle-time 20 --max-delinquent-stake 5"

  it "the run succeeds"
  assert_contains "$out" "rc=0"

  # --- Jito -> Agave with --restart ---
  sw_run j2a-r "active inactive not-found jito $EXE" "BUILD|v4.4.1-jito|$JITO_REPO" \
    '*--version*|agave-validator 4.4.1\n*systemctl is-active sol*|active\n*readlink /proc*|/home/sol/new/agave-validator' \
    --client agave --client-version v4.4.1 --restart --min-idle-time 30

  it "--restart waits for a restart window before anything stops"
  assert_contains "$(cat "$WORK/j2a-r.ssh")" "$EXE --ledger /home/sol/ledger wait-for-restart-window --min-idle-time 30 --max-delinquent-stake 5"

  it "--restart exits through the binary that is running"
  assert_contains "$(cat "$WORK/j2a-r.ssh")" "$EXE --ledger /home/sol/ledger exit --min-idle-time 30 --max-delinquent-stake 5"

  it "the window comes before the exit, and both after validator.sh is written"
  order="$(grep -n -e 'validator.sh.arise-tmp' -e 'wait-for-restart-window' -e ' exit --min-idle-time' "$WORK/j2a-r.ssh" | sed -e 's/^[0-9]*://' -e 's/.*validator\.sh.*/vsh/' -e 's/.*wait-for.*/window/' -e 's/.* exit .*/exit/' | tr '\n' ' ')"
  assert_eq "$order" "vsh window exit "

  it "--restart tells perch, wherever it is installed, between the window and the exit"
  assert_contains "$(cat "$WORK/j2a-r.scripts")" "runuser -u sol -- /home/sol/perch/maint restart 1h"
  assert_contains "$(cat "$WORK/j2a-r.scripts")" "perch --config /etc/perch/config.toml maint restart 1h"

  it "--restart reports the validator back up"
  assert_contains "$out" "sol.service is active again, now running: /home/sol/new/agave-validator"
  assert_contains "$out" "rc=0"

  it "--restart is called off when the new binary does not run"
  sw_run j2a-bad "active inactive not-found jito $EXE" "BUILD|v4.4.1-jito|$JITO_REPO" '*--version*|@fail' \
    --client agave --client-version v4.4.1 --restart
  assert_contains "$out" "not restarting"
  assert_not_contains "$(cat "$WORK/j2a-bad.ssh")" " exit "
  assert_contains "$out" "rc=1"

  it "--restart is called off when no restart window is found"
  sw_run j2a-nowin "active inactive not-found jito $EXE" "BUILD|v4.4.1-jito|$JITO_REPO" \
    '*wait-for-restart-window*|@fail\n*--version*|agave-validator 4.4.1' --client agave --client-version v4.4.1 --restart
  assert_contains "$out" "No restart window was found"
  assert_not_contains "$(cat "$WORK/j2a-nowin.ssh")" " exit "

  # --- same client ---
  it "the same client and version is not rebuilt"
  sw_run same "active inactive not-found jito $EXE" "BUILD|v4.4.1-jito|$JITO_REPO" "" --client-version v4.4.1-jito
  assert_contains "$out" "already installed — skipping build"
  assert_not_contains "$(cat "$WORK/same.scripts")" "cargo-install-all.sh"

  it "a new version of the same client is built"
  sw_run up "active inactive not-found jito $EXE" "BUILD|v4.4.1-jito|$JITO_REPO" "" --client-version v4.4.2-jito
  assert_contains "$out" "Installed build is v4.4.1-jito; building v4.4.2-jito"
  assert_contains "$(cat "$WORK/up.scripts")" "CLIENT_VERSION=v4.4.2-jito"

  it "a build from an older version of this script counts as Jito"
  sw_run legacy "active inactive not-found jito $EXE" "BUILD|LEGACY|" "" --client agave --client-version v4.4.1
  assert_contains "$(cat "$WORK/legacy.scripts")" "CLIENT_REPO=$AGAVE_REPO"

  # --- leaving Hexis ---
  # A --hexis host has only the prebuilt Solana CLI in active_release
  sw_run unhexis "active inactive not-found hexis /home/sol/hexis/releases/v5/agave-validator" "BUILD|NONE|" "" --client-version v4.4.1-jito

  it "leaving Hexis builds the plain client: the prebuilt CLI is not taken for it"
  assert_contains "$(cat "$WORK/unhexis.scripts")" "cargo-install-all.sh"

  it "leaving Hexis drops the arb flags from validator.sh"
  assert_not_contains "$(sw_vsh unhexis)" "--arb-config"
  assert_contains "$(sw_vsh unhexis)" "--block-engine-url"

  it "leaving Hexis closes the Control port"
  assert_contains "$(cat "$WORK/unhexis.scripts")" 'ufw delete allow from "$HEXIS_CONTROL_ALLOW"'

  it "the Control port is not touched on a host that never ran Hexis"
  assert_not_contains "$(cat "$WORK/j2a.scripts")" 'ufw delete allow from "$HEXIS_CONTROL_ALLOW"'

  # --- a host that runs Firedancer ---
  sw_run fd2j "inactive active enabled jito" "BUILD|NONE|" "" --client-version v4.4.1-jito

  it "a Firedancer host is recognised"
  assert_contains "$out" "This host runs Firedancer today"

  it "the Agave-family client is installed beside Firedancer"
  assert_contains "$(cat "$WORK/fd2j.scripts")" "cargo-install-all.sh"
  assert_contains "$out" "jito is installed beside Firedancer"

  it "sol.service is not enabled next to a Firedancer that holds the identity"
  assert_contains "$(cat "$WORK/fd2j.scripts")" "HOLD_SOL=true"

  it "the switch itself is reawaken.sh rollback"
  assert_contains "$out" "reawaken.sh rollback --host 1.2.3.4 --ssh-key $WORK/key --admin-user monarch"
  assert_contains "$out" "rc=0"

  it "Firedancer staged but not enabled does not hold sol.service back"
  sw_run fdstaged "active inactive disabled jito $EXE" "BUILD|v4.4.1-jito|$JITO_REPO" "" --client-version v4.4.1-jito
  assert_contains "$(cat "$WORK/fdstaged.scripts")" "HOLD_SOL=false"

  # --restart there hands over to reawaken.sh, which reads the host itself and
  # asks before it stops anything. No answer is given here, so it stops at the question.
  fd_host "$WORK/fd-live-sw.facts" 'agave_active=inactive\nagave_enabled=disabled\nfd_active=active\nfd_enabled=enabled\nfd_unit=yes\nfd_release=v1.0.0\nfd_version=1.0.0\nfd_config=yes\nfd_signer=yes' "${KV}${JITO}"
  sw_run fd2j-r "inactive active enabled jito" "BUILD|NONE|" "$(sed 's/\\/\\\\/g' "$WORK/fd-live-sw.facts")" --client-version v4.4.1-jito --restart

  it "--restart on a Firedancer host hands over to reawaken.sh rollback"
  assert_contains "$out" "handing over to reawaken.sh rollback"
  assert_contains "$out" "This stops Firedancer on sol@1.2.3.4"

  it "and nothing is stopped without the operator's yes"
  assert_contains "$out" "Nothing changed"
  assert_not_contains "$(cat "$WORK/fd2j-r.scripts")" "systemctl stop firedancer"

  # --- a live host asked to become Firedancer ---
  # reawaken.sh stage runs for real here too, against a host whose validator.sh
  # is the Jito one. The binary handed over is a fake, so stage stops at its check.
  fd_host "$WORK/jito-live-sw.facts" '' "${KV}${JITO}"
  sw_run a2fd "active inactive not-found jito $EXE" "BUILD|v4.4.1-jito|$JITO_REPO" "$(sed 's/\\/\\\\/g' "$WORK/jito-live-sw.facts")" \
    --client firedancer --fd-binary "$WORK/binary" --concorde-tables "$ROOT/test/fixtures/concorde-tables.toml"

  it "validator.sh of the running validator is not rewritten on the way to Firedancer"
  assert_contains "$out" "validator.sh left as it is"
  assert_not_contains "$(cat "$WORK/a2fd.ssh")" "validator.sh.arise-tmp"

  it "nor is its unit, and it stays enabled until the cutover"
  assert_contains "$(cat "$WORK/a2fd.scripts")" "KEEP_RUNNING_SETUP=true"
  assert_contains "$out" "Staging Firedancer with reawaken.sh"

  it "reawaken.sh stages from the Jito validator.sh that was left in place"
  assert_contains "$out" "Plan for sol@1.2.3.4 (Jito -> Firedancer with the Concorde)"
  assert_contains "$out" "Block Engine:   https://ny.mainnet.block-engine.jito.wtf"

  it "a Firedancer binary that does not run stops the staging, and arise.sh says how to resume"
  assert_contains "$out" "The uploaded binary does not run on this host — nothing has been changed"
  assert_contains "$out" "Staging Firedancer did not finish"
  assert_contains "$out" "rc=1"

  it "--concorde-tables is refused without the firedancer client"
  assert_contains "$(arise "${sw_base[@]}" --dry-run --concorde-tables "$ROOT/test/fixtures/concorde-tables.toml")" "only go with --client firedancer"

  # --- flags ---
  it "--min-idle-time must be a number"
  assert_contains "$(arise "${sw_base[@]}" --dry-run --min-idle-time soon)" "--min-idle-time must be a number of minutes"

  it "--max-delinquent-stake must be a number"
  assert_contains "$(arise "${sw_base[@]}" --dry-run --max-delinquent-stake lots)" "--max-delinquent-stake must be a percentage"

  it "a dry run says what --restart would do"
  assert_contains "$(arise "${sw_base[@]}" --dry-run --restart)" "[DRY RUN] --restart: if a validator is running, would wait for a restart window"
fi

if should_run "hostkey"; then
  echo "host key pinning"
  # shellcheck source=../lib/hexis.sh
  source "${ROOT}/lib/hexis.sh"
  # shellcheck source=../lib/remote.sh
  source "${ROOT}/lib/remote.sh"

  ssh-keygen -q -t ed25519 -N '' -C '' -f "$WORK/hostkey" <<<y >/dev/null 2>&1
  ssh-keygen -q -t ed25519 -N '' -C '' -f "$WORK/otherkey" <<<y >/dev/null 2>&1
  HK_FP=$(ssh-keygen -lf "$WORK/hostkey.pub" | awk '{print $2}')
  OTHER_FP=$(ssh-keygen -lf "$WORK/otherkey.pub" | awk '{print $2}')
  printf '# 1.2.3.4:22 SSH-2.0-OpenSSH\n1.2.3.4 %s\n' "$(cut -d' ' -f1,2 "$WORK/hostkey.pub")" > "$WORK/scan"
  pin() { KNOWN_HOSTS_FILE="$1" STUB_KEYSCAN="${3-$WORK/scan}" pin_host_key 1.2.3.4 "$2" 2>&1; }

  it "a host whose scanned key has the fingerprint is added to known_hosts"
  out=$(pin "$WORK/kh1" "$HK_FP"); rc=$?
  assert_eq "$rc" "0"
  it "the key that was added is the scanned one"
  assert_contains "$(cat "$WORK/kh1")" "$(cut -d' ' -f2 "$WORK/hostkey.pub")"

  it "a key already in known_hosts with the fingerprint needs no scan"
  out=$(STUB_LOG="$WORK/pin-known.log" pin "$WORK/kh1" "$HK_FP" /nonexistent); rc=$?
  assert_eq "$rc" "0"
  it "and the host is not asked for its keys again"
  assert_file_missing "$WORK/pin-known.log"
  it "and known_hosts is not added to twice"
  assert_eq "$(wc -l < "$WORK/kh1" | tr -d ' ')" "1"

  it "a host that offers a different key is refused"
  out=$(pin "$WORK/kh2" "$OTHER_FP"); rc=$?
  assert_eq "$rc" "1"
  it "the refusal names the key the host does offer"
  assert_contains "$out" "It offers: ${HK_FP}"
  it "nothing is written to known_hosts for a refused host"
  assert_file_missing "$WORK/kh2"

  it "a known_hosts entry with another key does not satisfy the fingerprint"
  out=$(pin "$WORK/kh1" "$OTHER_FP"); rc=$?
  assert_eq "$rc" "1"

  it "a host that answers with no key is refused"
  out=$(pin "$WORK/kh3" "$HK_FP" /nonexistent); rc=$?
  assert_contains "$out" "Could not read a host key"
  it "with a failing status"
  assert_eq "$rc" "1"

  it "a fingerprint that is not a SHA256 one is refused"
  out=$(pin "$WORK/kh3" "MD5:aa:bb:cc"); rc=$?
  assert_contains "$out" "must look like SHA256:"

  it "system.sh connects to nothing when the fingerprint does not match"
  out=$(KNOWN_HOSTS_FILE="$WORK/kh4" STUB_KEYSCAN="$WORK/scan" STUB_LOG="$WORK/pin-sys.log" \
    system --host 1.2.3.4 --ssh-key "$WORK/key" --host-key-fingerprint "$OTHER_FP")
  assert_contains "$out" "not connecting"
  it "ssh is never run for it"
  assert_not_contains "$(grep -v '^ssh-keyscan' "$WORK/pin-sys.log")" "1.2.3.4"

  it "system.sh with a matching fingerprint connects with strict host key checking"
  KNOWN_HOSTS_FILE="$WORK/kh5" STUB_KEYSCAN="$WORK/scan" STUB_LOG="$WORK/pin-sys-ok.log" \
    STUB_RESPONSES="$ROOT/test/fixtures/host-hexis.responses" \
    system --host 1.2.3.4 --ssh-key "$WORK/key" --host-key-fingerprint "$HK_FP" >/dev/null
  assert_contains "$(cat "$WORK/pin-sys-ok.log")" "StrictHostKeyChecking=yes"
  it "and never with accept-new"
  assert_not_contains "$(cat "$WORK/pin-sys-ok.log")" "accept-new"

  for script in ascend reawaken; do
    mode=upgrade; extra=(--hexis-binary "$WORK/binary")
    if [[ "$script" == reawaken ]]; then mode=status; extra=(--yes); fi
    it "$script.sh connects to nothing when the fingerprint does not match"
    out=$( (cd "$ROOT" && KNOWN_HOSTS_FILE="$WORK/kh-$script" STUB_KEYSCAN="$WORK/scan" STUB_LOG="$WORK/pin-$script.log" \
      ./"$script".sh "$mode" --host 1.2.3.4 --ssh-key "$WORK/key" "${extra[@]}" \
      --host-key-fingerprint "$OTHER_FP") 2>&1 )
    assert_contains "$out" "not connecting"
    it "$script.sh runs no ssh for it"
    assert_not_contains "$(grep -v '^ssh-keyscan' "$WORK/pin-$script.log" 2>/dev/null)" "1.2.3.4"
  done

  it "arise.sh connects to nothing when the fingerprint does not match"
  out=$(KNOWN_HOSTS_FILE="$WORK/kh-arise" STUB_KEYSCAN="$WORK/scan" STUB_LOG="$WORK/pin-arise.log" \
    arise --host 1.2.3.4 --ssh-key "$WORK/key" --identity "$WORK/id.json" \
    --vote-account 7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2 --network testnet --host-key-fingerprint "$OTHER_FP")
  assert_contains "$out" "not connecting"
  it "arise.sh runs no ssh for it"
  assert_not_contains "$(grep -v '^ssh-keyscan' "$WORK/pin-arise.log" 2>/dev/null)" "1.2.3.4"

  it "arise.sh warns when the host is unknown and no fingerprint was given"
  out=$(KNOWN_HOSTS_FILE="$WORK/kh-empty" arise --host 1.2.3.4 --ssh-key "$WORK/key" --identity "$WORK/id.json" \
    --vote-account 7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2 --network testnet --dry-run)
  assert_contains "$out" "is not in known_hosts"
  it "arise.sh does not warn about a host that is already known"
  out=$(KNOWN_HOSTS_FILE="$WORK/kh1" arise --host 1.2.3.4 --ssh-key "$WORK/key" --identity "$WORK/id.json" \
    --vote-account 7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2 --network testnet --dry-run)
  assert_not_contains "$out" "is not in known_hosts"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
