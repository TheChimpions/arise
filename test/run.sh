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
assert_file_missing() {
  if [[ -e "$1" ]]; then _fail "expected $1 not to exist"; else _ok; fi
}

should_run() { [[ -z "$FILTER" || "$1" == *"$FILTER"* ]]; }

arise() { ( cd "$ROOT" && ./arise.sh "$@" ) 2>&1; }
ascend() { ( cd "$ROOT" && ./ascend.sh "$@" ) 2>&1; }
system() { ( cd "$ROOT" && ./system.sh "$@" ) 2>&1; }

# Common argument sets
arise_base=(--host 1.2.3.4 --vote-account V1 --network mainnet --commission-bps 0
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
  diff_back="*_ascend.sh*|--- /home/sol/validator.sh"

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

  out="$(STUB_RESPONSES=$F/host-fresh.responses arise --host 1.2.3.4 --vote-account V1 \
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
    --vote-account V --network testnet --hexis)" "requires --network mainnet"

  it "arise requires --host"
  assert_contains "$(arise)" "--host is required"

  it "arise rejects an unknown flag"
  assert_contains "$(arise --nonsense)" "Unknown option"

  # Printed commands are copy-pasted against real hosts. Without IdentitiesOnly
  # the agent offers every loaded key and can trip the server's MaxAuthTries.
  it "printed ssh commands carry the key and IdentitiesOnly"
  assert_contains "$(STUB_RESPONSES=$ROOT/test/fixtures/host-hexis.responses ascend upgrade \
    --host 1.2.3.4 --ssh-key "$WORK/key" --hexis-binary "$WORK/binary")" \
    "ssh -o IdentitiesOnly=yes -i $WORK/key sol@1.2.3.4"

  # Root may only have a password, and Step 12 turns password auth off, so root
  # work after the bootstrap has to go through sol + sudo.
  out="$(STUB_RESPONSES=$ROOT/test/fixtures/host-fresh.responses arise "${arise_base[@]}" \
    --ssh-key "$WORK/key" --identity "$WORK/id.json" --root-user root)"

  it "arise runs root scripts as sol even with --root-user"
  assert_contains "$out" "root_script on sol@1.2.3.4"

  it "arise never runs root scripts over the root login"
  assert_not_contains "$out" "root_script on root@"

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
  # trusted validator that live in scratch files
  pf_dir="$(mktemp -d)"; mkdir "$pf_dir/fd" "$pf_dir/agave"
  pf_key="7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2"
  pf_name="snapshot-300-HD9P3x1tKAqbNvn8PJzNrqmJA9nBxNHCompRkfGT8Edm.tar.zst"
  { printf '\x28\xb5\x2f\xfd'; head -c 999 /dev/urandom; } > "$pf_dir/mirror-file"
  printf '[snapshots.sources.gossip]\n    allow_list = [\n        "%s",\n    ]\n' "$pf_key" > "$pf_dir/config.toml"
  printf 'NOTICE snapct: allowed gossip peer added with public key `%s` and RPC address `10.0.0.9:8899`\n' "$pf_key" > "$pf_dir/fd.log"
  prefetch() {
    (
      curl() {
        local out="" range="" url="" headers=false s e
        while (($#)); do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            -r) range="$2"; shift 2 ;;
            -D) headers=true; shift 2 ;;
            -m|-A|-X|-H|-d|-w) shift 2 ;;
            -*) shift ;;
            *)  url="$1"; shift ;;
          esac
        done
        case "$url" in
          http://10.0.0.9:8899/snapshot.tar.bz2) printf '%s' "http://10.0.0.9:8899/${PEER_NAME}" ;;
          https://mirror.test/snapshot.tar.bz2)  printf '%s' "https://store.test/${pf_name}?sig=1" ;;
          https://store.test/*)
            if $headers; then
              printf 'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/1003\r\n'
            else
              s="${range%-*}"; e="${range#*-}"
              tail -c "+$((s + 1))" "$pf_dir/mirror-file" | head -c "$((e - s + 1 - ${SHORT_BY:-0}))" > "$out"
            fi ;;
        esac
      }
      # shellcheck disable=SC2034  # read by the eval'd lines
      PF_PROGRESS_SECONDS=0.1
      eval "$(fd_render_snapshot_prefetch https://mirror.test "$pf_dir/fd" "$(id -un)" "$pf_dir/config.toml" "$pf_dir/fd.log" "$1" 8899)"
    )
  }

  it "does not take the mirror's snapshot when no trusted validator serves the same one"
  assert_contains "$(PEER_NAME="snapshot-200-SomeOtherHashSomeOtherHashSomeOtherHash1.tar.zst" prefetch "")" "no trusted validator serves ${pf_name}"

  it "and leaves the snapshot directory empty then"
  assert_eq "$(ls -A "$pf_dir/fd" | wc -l | tr -d ' ')" "0"

  it "discards a download that comes up short"
  assert_contains "$(PEER_NAME="$pf_name" SHORT_BY=1 prefetch "")" "did not complete — discarded"

  it "and leaves nothing behind from it"
  assert_eq "$(ls -A "$pf_dir" | paste -sd, -)" "agave,config.toml,fd,fd.log,mirror-file"

  touch "$pf_dir/agave/snapshot-300-AgaveOwnCopyAgaveOwnCopyAgaveOwnCopy1.tar.zst"
  it "skips the download when Agave holds that full snapshot already"
  assert_contains "$(PEER_NAME="$pf_name" prefetch "$pf_dir/agave")" "Agave already holds the full snapshot at slot 300"

  pf_out="$(PEER_NAME="$pf_name" prefetch "")"
  it "fetches the mirror's full snapshot when a trusted validator serves the same slot and hash"
  assert_contains "$pf_out" "1 of 1 trusted validators serve ${pf_name}"

  it "joins the ranges back into the file the mirror has, byte for byte"
  assert_eq "$(cmp "$pf_dir/mirror-file" "$pf_dir/fd/$pf_name" && echo same)" "same"

  it "cleans up its working directory"
  assert_eq "$(ls -A "$pf_dir" | paste -sd, -)" "agave,config.toml,fd,fd.log,mirror-file"

  it "fetches nothing when that full snapshot is on disk already"
  assert_contains "$(PEER_NAME="$pf_name" prefetch "")" "slot 300 is already on disk"
  rm -rf "$pf_dir"

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

  it "cutover ends by taking the dead RPC endpoint out of perch"
  assert_contains "$out" "drop this host's own RPC from perch's endpoints, if the host runs perch"

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

  it "rollback releases Firedancer's huge pages before Agave starts"
  assert_contains "$out" "firedancer configure fini all"

  it "rollback re-enables the Agave unit"
  assert_contains "$out" "systemctl enable sol; systemctl start sol"

  # --- upgrade: a host already on Firedancer -----------------------------------
  up=(upgrade --host 1.2.3.4 --ssh-key "$WORK/key" --concorde-tables "$T" --dry-run)
  fd_host "$WORK/fd-up.responses" "fd_unit=yes\nfd_config=yes\nfd_signer=yes\nfd_active=active\nfd_enabled=enabled\nagave_active=inactive\nfd_release=v1+concorde.1\nfd_version=1.0" "${KV}${JITO}${HEXIS}"
  printf '%s\n' '*test -x /home/sol/firedancer/releases/v0+concorde.9/firedancer*|yes' '*cat /home/sol/firedancer/.previous-release*|v0+concorde.9' >> "$WORK/fd-up.responses"
  out="$(STUB_RESPONSES=$WORK/fd-up.responses reawaken "${up[@]}" --fd-tag v2+concorde.1)"

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
fi

# === system.sh ===============================================================
group "system.sh"
if [[ ! -f "$ROOT/system.sh" ]]; then
  it "system.sh exists"; assert_eq "missing" "present"
else
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

  # An upstream Firedancer somebody else installed: no validator.sh, own config path
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

  it "and upgrade is refused there with the reason"
  out="$(STUB_RESPONSES=$WORK/st-jito.responses system upgrade "${st[@]}" --print; echo "rc=$?")"
  assert_contains "$out" "these scripts upgrade the Hexis builds only"
  assert_contains "$out" "rc=1"

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
  unset STUB_RELEASES
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
