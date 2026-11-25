.```
 █████╗ ██████╗ ██╗███████╗███████╗
██╔══██╗██╔══██╗██║██╔════╝██╔════╝
███████║██████╔╝██║███████╗█████╗
██╔══██║██╔══██╗██║╚════██║██╔══╝
██║  ██║██║  ██║██║███████║███████╗
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚══════╝╚══════╝
```

A one-shot, idempotent setup script that takes a fresh Ubuntu server and turns it into a Solana validator (testnet or mainnet). Handles disk setup, kernel tuning, Jito build, region detection, systemd services, firewall, jag-snap, and the optional Hexis arb client.

> **"Arise."** — one command, and the validator rises from the shadows.

---

## ⚠️ Disclaimers

**This is experimental software. Read before running.**

- **Review the script before you run it.** Open `arise.sh` and read what it does. It installs packages, formats disks, reconfigures the kernel, hardens SSH, opens firewall ports, and creates system users. These are destructive and hard to reverse.
- **This will format drives.** Auto-disk detection picks unformatted NVMe drives and runs `mkfs` on them. If you have important data on any NVMe drive that isn't the boot disk, **pass `--no-auto-disks`** or pass `--ledger-disk` / `--accounts-disk` explicitly.
- **Mainnet validators handle real stake and real money.** A misconfigured validator can miss votes, get delinquent, or lose stake. Do not run this on mainnet without understanding every step it performs.
- **Region auto-detection is best-effort.** It geolocates the server IP to pick the closest Jito and BloXroute regions. If detection fails, the script will warn you and leave placeholders in `validator.sh` that you **must fill in manually** before starting the validator.
- **No warranty.** If this script eats your stake, bricks your server, or summons a shadow army, that's on you.

**Verify after setup**, before starting the validator:

- `cat ~/validator.sh` on the server — confirm every flag is correct
- Check `--shred-receiver-address`, `--block-engine-url`, `--public-rpc-address`, `--commission-bps`
- Confirm `/mnt/ledger` and `/mnt/accounts` are mounted and owned by `sol`
- Confirm `solana-keygen verify` against your staked identity
- Run a testnet deploy first before touching mainnet

---

## What it does

1. **Bootstrap** — creates the `sol` user and copies your SSH key (if run with `--root-user`)
2. **System packages** — curl, build deps, docker.io, monitoring tools
3. **Kernel tuning** — Anza-recommended sysctl settings, CPU governor, network buffers
4. **Disk setup** — auto-detects unused NVMe drives, formats and mounts them as `/mnt/ledger` and `/mnt/accounts`
5. **Swap** — creates a swap file (default 128G)
6. **NTP** — configures chrony with the Jito region's NTP server
7. **Rust + Solana CLI** — installs via rustup, clones and builds Jito-Solana from source (requires `--github-ssh-key`). With `--hexis`, both are skipped in favour of the prebuilt Solana CLI, since the Hexis release already ships the validator binary.
8. **Identity keypairs** — copies your staked identity, generates an unstaked identity, symlinks `identity.json`
9. **Validator script** — generates `validator.sh` with region-specific Jito block engine, shred receiver, and BloXroute shred receivers based on server geolocation
10. **systemd** — creates `sol.service` and `sol-fix-mounts.service` (enabled but not started)
11. **Log rotation, firewall, SSH hardening, fail2ban**
12. **jag-snap** — clones and runs the jag-snap snapshot container
13. **Hexis arb client** (off by default, `--hexis` to enable, mainnet only) — installs the Hexis `agave-validator` build into `/home/sol/hexis`, writes `arb-config.toml`, creates the revert-dump spool, opens the Control port to the Hexis fleet only, and drops an `arb-enable.sh` helper
14. **XDP** (on by default, `--no-xdp` to disable) — accelerated retransmit per the [Anza XDP setup guide](https://www.anza.xyz/blog/agave-xdp-setup-guide): detects the NIC/driver/kernel, tunes ring sizes to powers of 2 (persisted across reboots), grants the validator the required capabilities, and adds the experimental retransmit/PoH flags

---

## Prerequisites

On your **local machine**:

- SSH private key with access to the target server
- A `staked_identity.json` file (validator keypair with a vote account already created)
- (Optional) A GitHub SSH key authorized to clone `jito-solana` and `jag-snap`

On the **target server**:

- Ubuntu 24.04 (or compatible)
- NVMe drives available for ledger/accounts (or you can fall back to `$HOME` directories)
- Initial SSH access via a user with sudo/root (typically `root` on a fresh VPS)

---

## Usage

```bash
./arise.sh \
  --host 192.168.1.100 \
  --ssh-key ~/.ssh/id_ed25519 \
  --identity ~/keys/staked_identity.json \
  --vote-account <VOTE_ACCOUNT_PUBKEY> \
  --network testnet \
  --root-user root \
  --github-ssh-key ~/.ssh/github_key
```

### Flags

**Required:**

| Flag               | Description                                                                                                                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--host`           | Server IP or hostname                                                                                                                                                                                                    |
| `--ssh-key`        | Path to SSH private key                                                                                                                                                                                                  |
| `--identity`       | Path to `staked_identity.json`                                                                                                                                                                                           |
| `--vote-account`   | Vote account pubkey                                                                                                                                                                                                      |
| `--commission-bps` | **Jito** commission in basis points — the cut of Jito MEV tips taken via the tip distribution program (mainnet only, e.g. `0` = 0%, `500` = 5%). This is the Jito tip commission, **not** the validator vote commission. |

**Bootstrap (fresh servers):**

| Flag          | Description                                                                                                                                                                                                                                                                                                                                              |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--root-user` | Initial sudo user (default: `root`). Creates the `sol` user and reconnects as `sol`. The root login does not need your SSH key — if the key is refused, ssh asks for the root password once and reuses that connection for the whole bootstrap. Everything after the bootstrap runs as `sol` with sudo, and SSH hardening then turns password login off. |

**Optional:**

| Flag               | Description                                                                                                                                                                     |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--github-ssh-key` | SSH key for GitHub (required to build Jito + run jag-snap)                                                                                                                      |
| `--jito-repo`      | Jito-Solana git repo URL (default: `git@github.com:jito-foundation/jito-solana.git`)                                                                                            |
| `--build-jito`     | Build jito-solana from source even with `--hexis` (off by default — see below)                                                                                                  |
| `--network`        | `testnet` or `mainnet` (default: `testnet`)                                                                                                                                     |
| `--jito-region`    | Override auto-detection (e.g. `frankfurt`, `new-york`, `singapore`)                                                                                                             |
| `--metrics-config` | `SOLANA_METRICS_CONFIG` exported by `validator.sh`. Defaults to the cluster metrics endpoint the SFDP requires (`mainnet-beta` or `tds` by network). Pass `""` to publish none. |
| `--ledger-disk`    | Explicit ledger disk (e.g. `/dev/nvme0n1`). Disables auto-detection.                                                                                                            |
| `--accounts-disk`  | Explicit accounts disk. Disables auto-detection.                                                                                                                                |
| `--no-auto-disks`  | Disable NVMe auto-discovery entirely                                                                                                                                            |
| `--swap-size`      | Swap file size (default: `128G`)                                                                                                                                                |
| `--dry-run`        | Print commands without executing them                                                                                                                                           |

**XDP (accelerated retransmit — [Anza XDP setup guide](https://www.anza.xyz/blog/agave-xdp-setup-guide)):**

XDP is **on by default**: it grants capabilities, tunes NIC ring sizes, and adds the experimental retransmit/PoH flags. Requires Agave **v3.0.9+** and kernel **6.8+** (**6.14+** for the `igb` driver).

| Flag                | Description                                                                                                                     |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `--no-xdp`          | Disable XDP setup entirely                                                                                                      |
| `--xdp-cpu-cores`   | Value for the validator's `--xdp-cpu-cores` (default: `1`)                                                                      |
| `--poh-pinned-core` | Value for the validator's `--poh-pinned-cpu-core` (default: `10`). Must be a **different physical core** than the XDP cores.    |
| `--xdp-interface`   | NIC to attach XDP to (default: auto-detect from the default route; bond members are resolved automatically)                     |
| `--xdp-zero-copy`   | `auto` \| `on` \| `off` (default: `auto`). Auto disables zero-copy for the `bnxt_en` and `ice` drivers, which don't support it. |

Agave 4.3 renamed the validator's XDP flags (`--experimental-retransmit-xdp-cpu-cores` → `--xdp-cpu-cores`, `--experimental-poh-pinned-cpu-core` → `--poh-pinned-cpu-core`, and the same for `-interface` and `-zero-copy`), and 4.4 removed the old names. `arise.sh` writes the new names when the installed validator accepts them and the old ones otherwise. `ascend.sh` renames them in an existing `validator.sh` when the release it activates takes the new names, and refuses `--restart` if it would leave names the new binary rejects.

**Hexis arb client ([hexis-validator-docs](https://github.com/hexishq/hexis-validator-docs)):**

Off by default and **mainnet only**. When enabled, the Hexis `agave-validator` build is
installed to `/home/sol/hexis` and put **first on `PATH`** in `validator.sh`, so the
`exec agave-validator` line runs it. The arb pipeline always boots **disabled** —
nothing arbitrages until you run `arb-enable.sh` against a running validator.

Because the Hexis release _is_ the validator binary, `--hexis` **skips the jito-solana
source build and the Rust toolchain** — a compile whose output would never be executed.
Instead it installs the prebuilt Solana CLI for `solana-keygen` (identity and arb
keypairs) and `solana` (catchup, monitoring), which takes seconds rather than the better
part of an hour. `--github-ssh-key` is then only needed for jag-snap. Pass `--build-jito`
to compile from source anyway.

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
| `--hexis-jup-key`              | Jupiter API key. Defaults to the Hexis fleet key; also read from `$HEXIS_JUP_KEY`.                                                                                  |
| `--hexis-metrics-config`       | Value exported as `SOLANA_METRICS_CONFIG_ARB` in `validator.sh`. Defaults to the Hexis metrics host; also read from `$SOLANA_METRICS_CONFIG_ARB`.                   |
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
_your_ machine using `gh`'s own token — `--github-ssh-key` is for git-over-SSH on the
server and has nothing to do with it. Make sure `gh auth status` shows an account with
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

**Defaults come from the Hexis mainnet sample config**, including the two fleet-wide
credentials — the Jupiter API key and the `SOLANA_METRICS_CONFIG_ARB` metrics string.
Both are the values Hexis hands to every operator, both are committed in this (public)
repo, and both are overridable with `--hexis-jup-key` / `--hexis-metrics-config` or by
exporting `HEXIS_JUP_KEY` / `SOLANA_METRICS_CONFIG_ARB`. **Check the rest against what
Hexis gave you** — especially the token ledgers and the lookup tables, which are
per-operator — before going live.

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

### Disk selection priority

1. **Explicit** — `--ledger-disk` / `--accounts-disk` if passed (disables auto-detection)
2. **Auto-detection** (default) — scans for unused, unformatted NVMe drives
3. **Fallback** — `/home/sol/ledger` and `/home/sol/accounts` if no drives found

---

## After the script finishes

The validator service is **enabled but not started**. Do not start it until you've verified everything:

```bash
# SSH in as sol
ssh -i ~/.ssh/id_ed25519 sol@<host>

# Review the generated validator script
cat ~/validator.sh

# Look for any FILL_IN_ placeholders (means region detection failed)
grep FILL_IN ~/validator.sh

# Start the validator when ready
sudo systemctl start sol

# Watch logs
tail -f ~/logs/solana-validator.log    # testnet
tail -f ~/logs/agave-validator.log     # mainnet

# Monitor catchup
solana catchup --our-localhost
```

### Verifying XDP (unless `--no-xdp` was used)

```bash
# Confirm the capabilities and ring tuning landed
systemctl cat sol | grep -i capab
systemctl status xdp-nic-tuning.service

# Inspect the NIC the script picked up
sudo ethtool -i <nic_name>     # driver
sudo ethtool -g <nic_name>     # current vs max ring sizes (current should be a power of 2)

# Confirm the flags are in validator.sh, then watch retransmit-stage metrics after start
grep -E 'xdp|poh-pinned' ~/validator.sh
```

XDP and PoH must run on **separate physical cores** — verify `--xdp-cpu-cores` and
`--poh-pinned-core` don't collide on your CPU topology before going live.

### Turning the arb on (only with `--hexis`)

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

### Cluster metrics (SFDP)

The Solana Foundation Delegation Program requires validators to publish cluster metrics,
so `validator.sh` exports `SOLANA_METRICS_CONFIG` pointing at `metrics.solana.com` —
`db=mainnet-beta` or `db=tds` depending on `--network`. With `--hexis` it also exports
`SOLANA_METRICS_CONFIG_ARB` for the arb; the two are independent and both are set.

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

### Upgrading and migrating

`arise.sh` builds a host from scratch. For a host that already exists, use `ascend.sh`:

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

On a host that runs [perch](https://github.com/TheChimpions/perch-watchtower)
(`/home/sol/perch/maint` exists), every restart these scripts make is declared to it first
with `maint restart`, so the watchtower does not page: `ascend.sh --restart` with a 1h
deadline, once the restart window is open; `reawaken.sh cutover`, `upgrade` and `rollback`
with 2h, which covers a reboot for huge pages and a full snapshot download. If perch cannot
be told, the restart goes ahead and the script says it may page.

A cutover to Firedancer also takes this host's own RPC out of perch's `[[endpoints]]`
(Firedancer runs without RPC, so perch would never see the validator recover), keeps the
old file as `config.toml.bak-pre-firedancer`, and restarts perch. `rollback` puts it back.

Neither enables the arb, and neither restarts the validator unless you pass `--restart`
— which runs `exit` (wait for the restart window, then stop; systemd brings it back), and
accepts `--min-idle-time` (default `20`), `--max-delinquent-stake` (default `5`) and
`--skip-new-snapshot-check` (on by default; `--wait-for-new-snapshot` turns it off). The
`exit` is issued by the binary the running process is actually executing, so it never
crosses a version boundary.
Full detail and the by-hand equivalent: [HEXIS-UPGRADE.md](HEXIS-UPGRADE.md).

### Which script for which host (`system.sh`)

`system.sh` looks at a host and says which of the other scripts applies to it. Without a
goal it only reports, and changes nothing:

```bash
./system.sh --host <ip> --ssh-key ~/.ssh/<key>
```

It shows the client and release the host runs, whether Firedancer is installed, staged
or running, the newest Hexis Agave and Firedancer releases, and the command for each
move that is possible from there. With a goal it runs that command through the script
that owns it, which still asks before it stops or starts a validator:

| Goal | On a Jito / plain Agave host | On a Hexis Agave host | On a Firedancer host |
|---|---|---|---|
| `upgrade` | not available | `ascend.sh upgrade --restart` | `reawaken.sh upgrade` |
| `hexis` | `ascend.sh migrate --restart` | already there | use `agave` |
| `firedancer` | `reawaken.sh stage`, then `cutover` on the next call | same | already there |
| `agave` | already there | already there | `reawaken.sh rollback` |

```bash
./system.sh upgrade    --host <ip> --ssh-key ~/.ssh/<key>
./system.sh firedancer --host <ip> --ssh-key ~/.ssh/<key> --print        # show, do not run
./system.sh upgrade    --host <ip> --ssh-key ~/.ssh/<key> -- --dry-run   # passed through
```

`--tag` picks a release other than the newest. A server with no validator is pointed at
`arise.sh`, which needs your keys and is never run from here.

### Moving to Firedancer (`reawaken.sh`)

`reawaken.sh` moves a validator that is already running — Hexis Agave, Jito or plain
Agave — onto Firedancer with the Hexis Concorde. It reads the existing `validator.sh`
(and `arb-config.toml` on a Hexis host) for the identity, vote account, entrypoints,
known validators, Block Engine settings, shred receivers, arb signer and token ledgers,
so on a Hexis or Jito host there is normally nothing to pass but the release.

```bash
# 1. Stage. Touches nothing that is running; repeat it to change the config or upgrade.
./reawaken.sh stage --host <ip> --ssh-key ~/.ssh/<key> --fd-tag 'v26.10.8+concorde.4'

# 2. Cut over at a safe window: stops Agave, starts Firedancer. Asks first.
./reawaken.sh cutover --host <ip> --ssh-key ~/.ssh/<key>

# Back to Agave, and a read-only report
./reawaken.sh rollback --host <ip> --ssh-key ~/.ssh/<key>
./reawaken.sh status   --host <ip> --ssh-key ~/.ssh/<key>

# Later, on a host already running Firedancer: a newer release, or the one before
./reawaken.sh upgrade --host <ip> --ssh-key ~/.ssh/<key> --fd-tag '<newer tag>'
./reawaken.sh upgrade --host <ip> --ssh-key ~/.ssh/<key> --previous
```

`upgrade` stages the release exactly as `stage` does (binary, config refreshed against
that release's Concorde tables, shown as a diff), checks the config with the new binary,
waits for a window with no leader slot and restarts Firedancer. Every restart downloads
a snapshot, so the validator is not voting until that has loaded. `--previous` points
back at the release that was active before and restarts; it refuses when that older
binary does not accept the current config.

`--dry-run` on any mode prints the plan, the full `config.toml` and the unit without
changing the host or asking for sudo.

What `stage` does:

- picks the build for the host's CPU (`-zen5`, `-zen4`, or the generic AVX2 one),
  downloads it with `gh`, verifies the checksum, and installs it under
  `/home/sol/firedancer/releases/<tag>/` behind a `firedancer` symlink;
- installs the arb signer root-owned (Firedancer reads it as root at boot);
- writes `config.toml`: the migrated settings plus the Concorde's own tables, fetched
  from the Hexis docs so they match the release, and **checks it with `firedancer mem`
  against the real binary before putting it in place** — Firedancer refuses to boot on
  a key it does not know;
- raises `fs.nr_open` to the unit's open-file limit and installs log rotation for the
  Firedancer log;
- installs `firedancer.service`, not enabled, with `Conflicts=sol.service` so the two
  clients can never run the same identity at once;
- opens Control (18082) to the two Hexis addresses, metrics (7999) to one, and
  Firedancer's p2p UDP ports.

A plain Agave host has no Block Engine or arb signer to carry over: pass
`--block-engine-url` and `--commission-bps` (or `--no-block-engine`), and
`--hexis-signer`. A Jito host needs only `--hexis-signer`.

Things that change on Firedancer:

- **The arb starts enabled.** There is no `arb-enable.sh` step; Hexis controls it over
  the Control port.
- **No snapshots, no jag-snap.** Firedancer loads a snapshot on every start, makes
  none (`[layout] enable_snapshot_production` is off and marked unsupported in this
  release), and does not advertise an RPC address in gossip, so the host cannot be a
  snapshot source. Left alone, every start downloads the full snapshot from
  the trusted peers (about an hour for 117 GB at 33 MB/s), so `cutover` and `upgrade` put
  a current one on disk first, while the validator still runs:
  - `cutover` links Agave's newest full snapshot and incremental into Firedancer's
    snapshot directory.
  - `cutover` and `upgrade` fetch the current full snapshot from an HTTP mirror
    (`--snapshot-mirror`, default `https://snapshots.avorio.network/mainnet-beta`) in
    eight parallel ranges, when it is newer than what is on disk. The mirror is a third
    party: its file is taken only when a validator on the snapshot allow list serves a
    full snapshot with the same slot and hash. That check is on the name, not the bytes.
    `--no-snapshot-prefetch` turns it off.

  Firedancer starts from the local file when a trusted peer still serves incrementals
  built on that full slot; if anything above fails, it downloads as before. `cutover` stops the jag-snap container and closes 18899/tcp; `rollback` starts
  it and reopens the port. Stake that depends on serving snapshots (JagPool) does not
  carry over to a Firedancer host.
- **RPC is off** in the Concorde build (its core goes to the arb tiles), so
  `solana catchup --our-localhost` stops working on that host. `--enable-rpc` turns it
  back on.
- **Memory.** About 190 GiB is locked as huge pages while Firedancer runs. `rollback`
  releases it before starting Agave.
- **Cluster metrics.** `SOLANA_METRICS_CONFIG` is replaced by Firedancer's telemetry,
  which the generated config keeps on.

### Flash loans

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

### Swapping to staked identity

The script starts the validator with an **unstaked identity** via a symlink:

```bash
ls -la ~/identity.json
# identity.json -> unstaked_identity.json
```

To go live with your staked identity, follow the Jito hot-swap procedure. Do not just `ln -sf` the staked identity without understanding tower file handling.

---

## Troubleshooting

**"Could not auto-detect Jito region"** — the script will warn and continue. Open `~/validator.sh` on the server and replace the `<FILL_IN_...>` placeholders with values from https://jito.network/docs or pass `--jito-region` on the next run.

**Docker build fails with "permission denied"** — the script runs docker as root. If you're running commands manually as `sol`, either use `sudo docker` or log out and back in after being added to the docker group.

**Disks not detected** — check `lsblk` on the server. Auto-detection skips any drive that has mounted partitions or an existing filesystem. Use `--ledger-disk` / `--accounts-disk` to override.

**`--hexis-tag` fails** — the release download runs `gh` on **your** machine, not the server. Make sure `gh auth status` works and your account can see `hexishq/hexis-validator-docs`, or download the asset yourself and pass `--hexis-binary`.

**Arb never trades** — it boots disabled. Check `arb get`, then `/home/sol/hexis/arb-enable.sh`. If the validator refuses to boot at all, the config had a bad key: `agave-validator run` aborts on a typo in `arb-config.toml`.

**Build fails** — the Jito build needs `--github-ssh-key` and the key must be authorized on the `TheChimpions/jito-solana` fork.

---

## What's NOT handled

- Vote account creation (do this yourself with `solana create-vote-account`)
- Stake delegation
- Identity hot-swap procedure
- Monitoring / alerting (Prometheus, Grafana)
- Backup of tower files and identity keys
- Disaster recovery

---

## Development

```
arise.sh          provision a fresh server into a validator
ascend.sh         upgrade / migrate / promote on a server that already exists
lib/hexis.sh      shared Hexis defaults, logging, config rendering, checksum verification
test/run.sh       test suite — no dependencies
```

Both scripts source `lib/hexis.sh`, so they must be run from a checkout rather than
copied somewhere on their own. Hexis config values (program id, profit pool, marginfi
account and banks, token ledgers, lookup tables) live in that one file.

```bash
./test/run.sh              # everything
./test/run.sh patcher      # only cases matching a name
```

`ssh`, `scp` and `gh` are stubbed (`test/stubs/`) and host responses come from glob→output
fixtures (`test/fixtures/`), so the suite runs offline and touches no server. It covers the
`validator.sh` rewriter (including the shapes it must refuse rather than mangle), config
rendering, checksum verification, the flash-loan matrix, release staging and promotion, and
CLI validation. CI runs it alongside `shellcheck`.

## License

[MIT](LICENSE) — experimental, use at your own risk.
