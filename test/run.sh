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

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
