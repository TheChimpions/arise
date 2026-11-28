# Hexis arb client

The Hexis arb client is a build of the Jito-Solana validator that also runs an arbitrage
pipeline. It is released privately by Hexis ([hexis-validator-docs](https://github.com/hexishq/hexis-validator-docs)),
so everything on this page needs a GitHub account Hexis has given access to, plus the two
credentials and the signer keypair Hexis hands to its operators. It runs on mainnet only.

- A new server: `arise.sh --hexis`, below.
- A server already running Jito or Agave: [`ascend.sh migrate`](#upgrading-and-migrating-ascendsh).
- A newer Hexis release on a host that runs it: [`ascend.sh upgrade`](#upgrading-and-migrating-ascendsh).

Everything else about `arise.sh` — disks, users, firewall, the security model — is in the
[README](../README.md).

## Installing with `arise.sh --hexis`

Off by default and **mainnet only**. When enabled, the Hexis `agave-validator` build is
installed to `/home/sol/hexis` and put **first on `PATH`** in `validator.sh`, so the
`exec agave-validator` line runs it. The arb pipeline always boots **disabled** —
nothing arbitrages until you run `arb-enable.sh` against a running validator.

Because the Hexis release _is_ the validator binary, `--hexis` **skips the jito-solana
source build and the Rust toolchain** — a compile whose output would never be executed.
Instead it installs the prebuilt Solana CLI for `solana-keygen` (identity and arb
keypairs) and `solana` (catchup, monitoring), which takes seconds rather than the better
part of an hour. Pass `--build-client` to compile from source anyway.

| Flag                           | Description                                                                                                                                                         |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--hexis`                      | Enable Hexis arb client setup                                                                                                                                       |
| `--hexis-tag`                  | Release tag fetched with your **local** `gh` CLI from `hexishq/hexis-validator-docs`, checksum-verified, then uploaded                                              |
| `--hexis-binary`               | Pre-downloaded `agave-validator-linux-amd64` to upload (use instead of `--hexis-tag`)                                                                               |
| `--hexis-setup-binary`         | Pre-downloaded `hexis-setup` binary (LUT / marginfi / token-ledger tooling)                                                                                         |
| `--hexis-setup-tag`            | Release tag for `hexis-setup`, which ships separately from the validator (default: `v1.0-hexis-setup`). Empty string skips it.                                      |
| `--hexis-config`               | Upload this `arb-config.toml` verbatim instead of generating one                                                                                                    |
| `--hexis-signer`               | Arb signer keypair — the `signing_key.json` Hexis gave you — copied to `/home/sol/hexis/arb_signer_keypair.json`. Generated on the server when omitted.             |
| `--hexis-dir`                  | Install dir (default: `/home/sol/hexis`)                                                                                                                            |
| `--hexis-program-id`           | On-chain arb program                                                                                                                                                |
| `--hexis-profit-wallet`        | Address the program pays profit into. Defaults to the Hexis shared rewards pool. Only set it if Hexis hands you a different pool address.                           |
| `--hexis-jup-key`              | Jupiter API key from Hexis. Required unless `--hexis-config` is used; also read from `$HEXIS_JUP_KEY` or `hexis.env`.                                                                                  |
| `--hexis-metrics-config`       | Value exported as `SOLANA_METRICS_CONFIG_ARB` in `validator.sh`. From Hexis; required. Also read from `$SOLANA_METRICS_CONFIG_ARB` or `hexis.env`.                   |
| `--hexis-lookup-tables`        | Comma-separated extra address lookup tables (see `lut.md`)                                                                                                          |
| `--hexis-jupiter-token-ledger` | Jupiter TokenLedger (create with `hexis-setup`)                                                                                                                     |
| `--hexis-okx-token-ledger`     | OKX TokenLedger PDA (create with `hexis-setup okx-token-ledger`)                                                                                                    |
| `--hexis-base-mints`           | Comma-separated base mints. Order matters — `--hexis-marginfi-banks` must line up with it.                                                                          |
| `--hexis-marginfi-account`     | marginfi v2 account used for flash loans. Defaults to the one from the Hexis config, whose authority is the arb signer they issue. See [Flash loans](#flash-loans). |
| `--no-hexis-flash-loans`       | Drop `[flash_loan]` entirely — flash loans off                                                                                                                      |
| `--hexis-marginfi-banks`       | Comma-separated banks, one per base mint, same order                                                                                                                |
| `--hexis-marginfi-program-id`  | marginfi v2 program                                                                                                                                                 |
| `--hexis-control-bind`         | Control listen address (default: `0.0.0.0:18082`). Must not be loopback — Hexis dials the host.                                                                     |
| `--hexis-control-allow`        | The only source allowed through `ufw` to the Control port (default: `188.40.61.182`)                                                                                |
| `--no-hexis-control`           | Leave the `[control]` table out and don't open the port                                                                                                             |

The release lives in a **private** repo, and the download is a GitHub API call from
_your_ machine using `gh`'s own token — nothing GitHub-related is put on the server. Make sure `gh auth status` shows an account with
access; the script checks this before it touches the server. Assets are verified against
the release's `checksums.txt` and a mismatch aborts the run.

**The two keys play different roles and only one of them is yours.**

- **`signer_path`** — the keypair that signs arb transactions and pays their fees. Hexis
  gives you this as `signing_key.json`; pass it with
  `--hexis-signer ~/keys/signing_key.json` and it is copied to
  `/home/sol/hexis/arb_signer_keypair.json` (0600). **Fund it** — an empty signer means
  no arb lands. Omit the flag and one is generated on the server instead, which then
  needs funding before it is any use.
- **`profit_wallet`** — Hexis's shared rewards pool. You hold no key for it; the program
  simply pays into it. It defaults to the pool address from the Hexis config and is
  never generated. Only pass `--hexis-profit-wallet` if Hexis hands you a different pool.

With `--hexis-config`, nothing is generated — that file owns `signer_path` and
`profit_wallet`.

**Defaults come from the Hexis mainnet sample config**, and all of them are public
on-chain addresses. **Check them against what Hexis gave you** — especially the token
ledgers and the lookup tables, which are per-operator — before going live.

**The two Hexis credentials are not in this repository**: the Jupiter API key and the
`SOLANA_METRICS_CONFIG_ARB` metrics string. Hexis gives both to its operators. Supply
them one of three ways, first match wins:

1. `--hexis-jup-key <key>` and `--hexis-metrics-config <str>`
2. the environment: `HEXIS_JUP_KEY` and `SOLANA_METRICS_CONFIG_ARB`
3. `hexis.env` beside the scripts — copy `hexis.env.example`, fill it in once; git
   ignores it, and the scripts read it without running it

Give none of them and `arise.sh --hexis` and `ascend.sh migrate` **ask for what is
missing** when run at a terminal. What you type is not shown, and each answer can be
saved to `hexis.env` (mode 600) so you are asked once. The metrics string is the same
for every Hexis host, so one `hexis.env` on your laptop serves all your servers.

Without a terminal, or with `--yes`, nothing is asked: the run stops before touching the
host when one was never given. Passing `""` — or pressing Enter alone at the prompt — is
a decision to set up without it. With `--hexis-config` the Jupiter key is not asked for,
since your file carries it.

Example:

```bash
./arise.sh \
  --host <ip> --ssh-key ~/.ssh/id_ed25519 \
  --identity ~/keys/staked_identity.json \
  --vote-account <VOTE_ACCOUNT> \
  --network mainnet --commission-bps 0 \
  --hexis \
  --hexis-tag <release-tag> \
  --hexis-signer ~/keys/signing_key.json

# The marginfi account, banks, profit pool and token ledgers all default to the
# values from the Hexis config, so the signer is the only thing you supply.
# Fund it before enabling the arb — it pays the transaction fees.
```

What it adds to `validator.sh`:

```bash
PATH=/home/sol/hexis:/home/sol/.local/share/solana/install/releases/active_release/bin:...
export SOLANA_METRICS_CONFIG_ARB="..."
exec agave-validator \
    --tvu-shred-sigverify-threads 2 \
    --arb-config /home/sol/hexis/arb-config.toml \
    ...
```

## Turning the arb on

`arb-config.toml` is read **once** at boot and a typo'd key aborts the boot. The
pipeline itself always comes up **disabled**, including after a crash-restart — a
restarted validator is a plain validator until you enable it again.

```bash
# Validator running and caught up, then:
/home/sol/hexis/arb-enable.sh          # arb set --enabled true, --program-size (releases that still have it), okx-token-ledger, arb get

# Day-to-day
cd /home/sol/hexis
./agave-validator --ledger /mnt/ledger arb get       # live config
./agave-validator --ledger /mnt/ledger arb disable   # stops arb, validator keeps producing blocks

# Control port (skip if --no-hexis-control)
ss -lntp | grep 18082
./agave-validator --ledger /mnt/ledger arb control-http2 get
```

## Flash loans

Flash loans are **on by default**, using the marginfi v2 account from the Hexis config
along with its banks and program id. That account pairs with the arb signer Hexis
issues — a marginfi account can only be borrowed against by its own authority — so the
two travel together. If you pass no `--hexis-signer` while that account is configured,
both scripts warn that flash loans will fail, because a locally generated signer is not
the account's authority.

`--no-hexis-flash-loans` drops the whole `[flash_loan]` table and runs the arb without
them.

To use your own marginfi account instead, create it on the host after the first run —
`hexis-setup` only lands there during a run:

1. Fund the arb signer, then `/home/sol/hexis/hexis-setup marginfi create` (see
   `marginfi.md`).
2. Re-run with `--hexis-marginfi-account <PUBKEY>` and restart the validator —
   `arb-config.toml` is read **once at boot**, so editing it without a restart changes
   nothing.

`--hexis-marginfi-banks` must list one bank per `--hexis-base-mints` entry, in the same
order.

Identity (signer, program, profit wallet, marginfi account) can be changed without a
restart via `arb identity set` — see the Hexis docs. Don't pass extra `arb set` flags
beyond the ones in `arb-enable.sh` unless whoever owns the stack asks you to.

Revert dumps spool to `/home/sol/hexis/arb-reverts/{slot}/{arb_sig}/` and are deleted
once Hexis `dumpd` acks them over Control.

## Upgrading and migrating (`ascend.sh`)

`arise.sh` builds a host from scratch. For a host that already exists, use `ascend.sh`
(or let [`system.sh`](../README.md#servers-that-already-run-a-validator) pick the command):

```bash
./ascend.sh upgrade --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <new-tag>
./ascend.sh migrate --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <tag>
./ascend.sh promote --host <ip> --ssh-key ~/.ssh/<key> --release <tag>
```

Releases live in `/home/sol/hexis/releases/<tag>/` and `/home/sol/hexis/agave-validator`
is a symlink to the active one. `validator.sh` execs that symlink, so a version bump
never edits it.

`upgrade` stages a checksum-verified release and repoints the symlink; `--stage-only`
uploads without activating, so even an unplanned restart stays on the current version.
`promote --release <tag>` activates a staged release or rolls back to an older one, and
`promote --list` shows what is staged. `migrate` puts Hexis onto a validator already
running Jito or plain Agave —
installs the binary and `hexis-setup`, generates the keypairs, writes `arb-config.toml`,
opens the Control port, and patches the existing `validator.sh` after showing you the
diff. It refuses rather than guesses if the startup script isn't a shape it recognises.

On a host that runs [perch](https://github.com/TheChimpions/perch-watchtower), every
restart these scripts make is declared to it first. perch is found in either place it
can live: system-wide as `arise.sh` installs it (`perch` on the PATH, config in
`/etc/perch`), or in the validator user's home on an older host (`/home/sol/perch/maint`).
A system-wide perch can only be told through root, so `ascend.sh --restart` asks for
sudo on such a host. The declaration is made
with `maint restart`, so the watchtower does not page: `ascend.sh --restart` with a 1h
deadline, once the restart window is open; `reawaken.sh cutover`, `upgrade` and `rollback`
with 2h, which covers a reboot for huge pages and a full snapshot download. If perch cannot
be told, the restart goes ahead and the script says it may page.

Neither enables the arb, and neither restarts the validator unless you pass `--restart`
— which runs `exit` (wait for the restart window, then stop; systemd brings it back), and
accepts `--min-idle-time` (default `20`), `--max-delinquent-stake` (default `5`) and
`--skip-new-snapshot-check` (on by default; `--wait-for-new-snapshot` turns it off). The
`exit` is issued by the binary the running process is actually executing, so it never
crosses a version boundary.
Full detail and the by-hand equivalent: [HEXIS-UPGRADE.md](../HEXIS-UPGRADE.md).

## Cluster metrics on a Hexis host

`validator.sh` exports `SOLANA_METRICS_CONFIG` for the cluster metrics the Solana Foundation
Delegation Program requires, and `SOLANA_METRICS_CONFIG_ARB` for the arb. The two are
independent and both are set.

`ascend.sh` reports whether the host publishes cluster metrics and can repair one that
doesn't:

```bash
# check — every ascend run warns if the export is missing
./ascend.sh upgrade --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <tag>

# repair, on any host, in any mode (shows a diff, keeps a .pre-metrics backup)
./ascend.sh upgrade --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <tag> --fix-metrics
```

`migrate` adds the export while patching `validator.sh`, but only when the file has none
— an existing config is the operator's and is never overwritten. A host already running
Hexis is skipped by that patcher entirely, which is why `--fix-metrics` exists.

## Troubleshooting

**`--hexis-tag` fails** — the release download runs `gh` on **your** machine, not the server. Make sure `gh auth status` works and your account can see `hexishq/hexis-validator-docs`, or download the asset yourself and pass `--hexis-binary`.

**Arb never trades** — it boots disabled. Check `arb get`, then `/home/sol/hexis/arb-enable.sh`. If the validator refuses to boot at all, the config had a bad key: `agave-validator run` aborts on a typo in `arb-config.toml`.
