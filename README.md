```
 █████╗ ██████╗ ██╗███████╗███████╗
██╔══██╗██╔══██╗██║██╔════╝██╔════╝
███████║██████╔╝██║███████╗█████╗
██╔══██║██╔══██╗██║╚════██║██╔══╝
██║  ██║██║  ██║██║███████║███████╗
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚══════╝╚══════╝
```

Scripts that take a Solana validator from a bare Ubuntu server to a running node and keep it moving afterwards: upgrades, a move onto the Hexis arb client, and a move onto Firedancer with the Hexis Concorde.

> **"Arise."** — one command, and the validator rises from the shadows.

| Script | What it is | What it does |
|---|---|---|
| `system.sh` | The System: status window and quests | **Start here for any server that already runs a validator.** Reports what the host runs and routes each move to the script that owns it |
| `arise.sh` | Raising a new shadow soldier | Turns a fresh server into a validator: disks, kernel tuning, Jito build or Hexis binary, region detection, systemd, firewall, jag-snap |
| `ascend.sh` | Levelling up | Upgrades the Hexis Agave client, or moves a Jito / plain Agave validator onto it |
| `reawaken.sh` | A Re-Awakening | Moves a running validator onto Firedancer with the Hexis Concorde, upgrades it there, and takes it back |

```bash
# What does this host run, and what can be done from here? Read-only.
./system.sh --host <ip> --ssh-key ~/.ssh/<key>

# Then name the goal: upgrade | hexis | firedancer | agave
./system.sh upgrade --host <ip> --ssh-key ~/.ssh/<key>
```

A server with no validator yet is the one case `system.sh` does not run for you: it needs your keys, so that is `arise.sh`, described first below. Everything for an existing host is under [After the script finishes](#after-the-script-finishes), starting at [`system.sh`](#which-script-for-which-host-systemsh).

---

## ⚠️ Disclaimers

**This is experimental software. Read before running.**

- **Review the script before you run it.** Open `arise.sh` and read what it does. It installs packages, formats disks, reconfigures the kernel, hardens SSH, opens firewall ports, and creates system users. These are destructive and hard to reverse.
- **This will format drives.** Auto-disk detection picks blank NVMe drives and runs `mkfs` on them. It skips any drive with partitions, a filesystem, a RAID/LVM signature or a mount, shows you what it found, and makes you type `format` before erasing anything. If in doubt, **pass `--no-auto-disks`** or pass `--ledger-disk` / `--accounts-disk` explicitly.
- **It disables root SSH login and SSH passwords.** After the first run you log in as the admin user or as `sol`, with your key. Pass `--keep-root-login` if your provider's rescue path needs key-based root login.
- **Mainnet validators handle real stake and real money.** A misconfigured validator can miss votes, get delinquent, or lose stake. Do not run this on mainnet without understanding every step it performs.
- **Region auto-detection is best-effort.** It geolocates the server IP to pick the closest Jito region. If detection fails, the script will warn you and leave placeholders in `validator.sh` that you **must fill in manually** before starting the validator.
- **No warranty.** If this script eats your stake, bricks your server, or summons a shadow army, that's on you.

**Verify after setup**, before starting the validator:

- `cat ~/validator.sh` on the server — confirm every flag is correct
- Check `--shred-receiver-address`, `--block-engine-url`, `--commission-bps`
- Check the flags against the release notes for the version you built — flags change between major versions
- Confirm `/mnt/ledger` and `/mnt/accounts` are mounted and owned by `sol`
- Confirm `solana-keygen verify` against your staked identity
- Run a testnet deploy first before touching mainnet

---

## What `arise.sh` does

1. **Bootstrap** — creates an admin user (`monarch`, sudo with password) and the `sol` service user (no sudo), and installs your SSH key for both
2. **System packages** — curl, build deps, monitoring tools
3. **Kernel tuning** — Anza-recommended sysctl settings, CPU governor, network buffers
4. **Disk setup** — auto-detects unused NVMe drives, formats and mounts them as `/mnt/ledger` and `/mnt/accounts`
5. **Swap** — creates a swap file (default 128G)
6. **NTP** — configures chrony with the Jito region's NTP server
7. **The validator client** (`--client`) — `jito` (default) and `agave` are built on the server from their public repos at the release tag you choose. With `--hexis`, or with `--client firedancer`, nothing is compiled: the binary comes from a private release and only the prebuilt Solana CLI is installed beside it
8. **Identity keypairs** — copies your staked identity, generates an unstaked identity, symlinks `identity.json`
9. **Validator script** — generates `validator.sh` with the region-specific Jito block engine and shred receiver (chosen from server geolocation) plus the DoubleZero shred receiver. RPC is bound to localhost and kept out of gossip
10. **systemd** — creates `sol.service` and `sol-fix-mounts.service` (enabled but not started)
11. **Log rotation, firewall, SSH hardening, fail2ban**
12. **perch watchtower** — installs [perch](https://github.com/TheChimpions/perch-watchtower) and points it at this validator (on by default, `--no-perch` to skip; installed but not started)
13. **Hexis arb client** (off by default, `--hexis` to enable, mainnet only) — installs the Hexis `agave-validator` build into `/home/sol/hexis`, writes `arb-config.toml`, creates the revert-dump spool, opens the Control port to the Hexis fleet only, and drops an `arb-enable.sh` helper
14. **XDP** (on by default, `--no-xdp` to disable) — accelerated retransmit per the [Anza XDP setup guide](https://www.anza.xyz/blog/agave-xdp-setup-guide): detects the NIC/driver/kernel, tunes ring sizes to powers of 2 (persisted across reboots), grants the validator the required capabilities, and adds the experimental retransmit/PoH flags

---

## Security model

| Account | Purpose | sudo | SSH |
|---|---|---|---|
| `monarch` (admin, `--admin-user`) | System changes, starting and stopping services | Yes, password required | Key only |
| `sol` | Runs the validator, holds the keypairs | **None** | Key only |
| `root` | — | — | Login disabled |

- **The validator account cannot become root.** `sol` has no sudo and is in no privileged group, and `sol.service` runs with `NoNewPrivileges` and a read-only view of `/usr`, `/boot` and `/etc`. XDP gets exactly the four capabilities it needs and no others.
- **SSH is key-only, and it is checked.** The settings go in `/etc/ssh/sshd_config.d/00-arise.conf` so they win over cloud-init's defaults. The script then reads sshd's effective configuration and rolls back and stops if anything overrides them.
- **The firewall opens only SSH and the validator's port range** (8000–8026, the minimum width Agave 4 accepts), plus the Hexis Control port to one address with `--hexis`. RPC is bound to `127.0.0.1`, kept out of gossip with `--private-rpc`, and not opened.
- **Nothing sensitive is written to disk in transit.** Scripts and the sudo password go to the server over SSH stdin. Nothing lands in `/tmp`, no password appears in a process list, and keypairs are created mode 600 from the first byte. This is `lib/remote.sh`, shared by `arise.sh`, `ascend.sh` and `reawaken.sh`.
- **Nothing GitHub-related goes on the server.** Public clients are cloned over HTTPS. Private releases (Hexis, Firedancer) are downloaded on your machine with `gh`, checksum-verified, and streamed up.
- **Security updates stay on.** `unattended-upgrades` is enabled and `sol.service` is excluded from automatic restarts. CPU mitigations stay on. Both can be traded for performance with `--disable-auto-updates` and `--disable-cpu-mitigations`.
- **Every remote step is checked.** If any command on the server fails, the script stops with a non-zero exit instead of carrying on.

### Upgrading a server set up by an older version

Older versions gave `sol` sudo and docker access and left root login on. Run `arise.sh` once with `--root-user sol`: you will be asked for `sol`'s sudo password and for a new admin password. The script creates the admin user, then removes `sol`'s sudo and docker access, replaces the old 8000–10000 firewall rule, and disables root login. After this, use `ssh monarch@<host>` for anything that needs sudo, and `ascend.sh` / `reawaken.sh` ask for the admin user's sudo password (`--admin-user` if you named it something else).

It reports, but does not remove, leftovers such as an old GitHub key in `~sol/.ssh/github_key`, a `jag-snap` container, or `mitigations=off` in GRUB.

---

## Prerequisites

On your **local machine**:

- SSH private key with access to the target server
- A `staked_identity.json` file (validator keypair with a vote account already created)
- `git` (only used to list release tags when `--client-version` is omitted)
- `gh`, logged in to an account that can see the private release repo — only for `--hexis-tag` and `--client firedancer`

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
  --client-version v4.4.1-jito
```

`--root-user` is only needed the first time. Later runs connect as the admin user and ask for its sudo password.

### Choosing a client

| | Command | Where the binary comes from |
|---|---|---|
| **Jito** (default) | `--client jito --client-version v4.4.1-jito` | Built on the server from `jito-foundation/jito-solana` |
| **Agave** | `--client agave --client-version v4.4.1` | Built on the server from `anza-xyz/agave`. No Block Engine or tip flags |
| **Jito + Hexis** | `--client jito --hexis --hexis-tag <tag>` | Private Hexis release, fetched locally with `gh` (or `--hexis-binary <path>`). Mainnet only |
| **Firedancer** (Hexis Concorde) | `--client firedancer --fd-tag <tag>` | Private release, fetched locally with `gh` (or `--fd-binary <path>`). Mainnet only |

Leave `--client-version` off and the script lists recent release tags to pick from.

**Firedancer from scratch.** `arise.sh` provisions the host and writes `validator.sh` as the record of the validator's settings (identity, vote account, entrypoints, Block Engine, shred receivers), leaves `sol.service` disabled, then runs `reawaken.sh stage` for you — the same staging a migrated host gets. Staging starts nothing. Start it with `./reawaken.sh cutover --host <host> --ssh-key <key>`: with nothing running there is nothing to stop, so it checks the config, asks once and starts `firedancer.service`. Pass `--hexis-signer <signing_key.json>` to use the arb signer Hexis issued; otherwise one is generated. There is no Agave client on such a host, so `reawaken.sh rollback` has nothing to go back to until you install one beside Firedancer — see [Changing client](#changing-client-on-a-host-that-already-runs-one).

### Flags

**Required:**

| Flag               | Description                                                                                                                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--host`           | Server IP or hostname                                                                                                                                                                                                    |
| `--ssh-key`        | Path to SSH private key                                                                                                                                                                                                  |
| `--identity`       | Path to `staked_identity.json`                                                                                                                                                                                           |
| `--vote-account`   | Vote account pubkey                                                                                                                                                                                                      |
| `--commission-bps` | **Jito** commission in basis points — the cut of Jito MEV tips taken via the tip distribution program (mainnet only, e.g. `0` = 0%, `500` = 5%). This is the Jito tip commission, **not** the validator vote commission. |

**Access:**

| Flag | Description |
|---|---|
| `--root-user` | Existing user with root or sudo access (e.g. `root`). First run only — used to create the admin user, never again. |
| `--admin-user` | Name of the admin user that holds sudo (default: `monarch`) |
| `--keep-root-login` | Keep key-based root SSH login enabled (default: disabled) |

**Client:**

| Flag | Description |
|---|---|
| `--client` | `jito` (default), `agave` or `firedancer` — see [Choosing a client](#choosing-a-client) |
| `--client-version` | Release tag to build for `jito` / `agave`. A different tag on a later run is built and `active_release` is switched to it |
| `--client-repo` | HTTPS git repo to build from (default: the client's public repo) |
| `--build-client` | Build from source even with `--hexis` (off by default — see below) |
| `--fd-tag` / `--fd-binary` | Firedancer release to stage with `--client firedancer` |
| `--concorde-tables` | Local copy of the Concorde config tables, instead of fetching them with `gh` (passed on to `reawaken.sh`) |
| `--restart` | On a host with a running validator: wait for a restart window and move it onto what was just installed. From or to Firedancer this hands over to `reawaken.sh`, which asks first |
| `--min-idle-time` | Minutes without a leader slot that `--restart` waits for (default: `20`) |
| `--max-delinquent-stake` | `--restart` does not go ahead while more than this percentage of stake is delinquent (default: `5`) |

**Monitoring and trade-offs:**

| Flag | Description |
|---|---|
| `--no-perch` | Do not install the perch watchtower (installed by default) |
| `--perch-version` | perch release to install, e.g. `v1.5.4` (default: `latest`) |
| `--perch-label` | Name used for this validator in alerts (default: the `--host` value) |
| `--confirm-format` | Skip the typed confirmation before formatting disks (for unattended runs) |
| `--disable-cpu-mitigations` | Add `mitigations=off` to the kernel command line (faster, less secure) |
| `--disable-auto-updates` | Turn off unattended security updates |

**Optional:**

| Flag               | Description                                                                                                                                                                     |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
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

`arise.sh --hexis` and `ascend.sh migrate` stop before touching the host when one was
never given. Passing `""` is a decision to set up without it. With `--hexis-config` the
Jupiter key is not asked for, since your file carries it.

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
# SSH in as sol to review the generated validator script
ssh -i ~/.ssh/id_ed25519 sol@<host>
cat ~/validator.sh

# Look for any FILL_IN_ placeholders (means region detection failed)
grep FILL_IN ~/validator.sh

# Start the validator when ready — sol has no sudo, so this is done as the admin user
ssh -t -i ~/.ssh/id_ed25519 monarch@<host> 'sudo systemctl start sol'

# Back as sol: watch logs and monitor catchup
tail -f ~/logs/agave-validator.log
solana catchup --our-localhost
```

### Turning on perch

perch pages you when the validator stops voting. The script installs it with perch's own installer (which checks the download against the published checksum), fills in this validator's identity, vote account and cluster in `/etc/perch/config.toml`, and adds the admin user to the `perch` group. It is **not started**, because it needs alert secrets only you have. As the admin user:

```bash
sudo nano /etc/perch/env                                        # Telegram / PagerDuty / heartbeat secrets
sudo nano /etc/perch/config.toml                                # delete the section of any channel you do not use
sudo bash -c 'set -a; . /etc/perch/env; perch --check-config'
sudo systemctl enable --now perch

perch maint restart                                             # before a planned restart, so it does not page
```

`sol` is deliberately not in the `perch` group: the validator account cannot silence the watchtower. The config uses perch's standalone layout with free public RPC endpoints. Disk and kernel-advisory checks need `node_exporter` and a `[[hosts]]` block, which this script does not set up.

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

### Changing client on a host that already runs one

`arise.sh` describes what a host should be, so changing client is the same command
with a different `--client`. Run it with the flags the host was set up with, the new
client, and `--restart`:

```bash
# Jito -> Agave
./arise.sh --host <ip> --ssh-key ~/.ssh/<key> --identity <staked_identity.json> \
    --vote-account <pubkey> --network mainnet \
    --client agave --client-version v4.4.1 --restart
```

It first reports what the host runs today. The new client is built beside the one that
is running (`releases/<tag>/`), `validator.sh` and the unit are rewritten for it, and
the running validator is not touched. `--restart` then checks that the new binary runs,
waits for a restart window (`--min-idle-time`, default 20 minutes;
`--max-delinquent-stake`, default 5%), declares the restart to perch if it is running,
and exits the validator through the binary it is executing; systemd brings it back on
the new setup. Without `--restart` the exact command is printed and nothing restarts.

| From | To | How |
|---|---|---|
| Jito | Agave, or back | `arise.sh --client <agave\|jito> --client-version <tag> --restart` |
| Jito or Agave | a newer version of the same | the same, with the new `--client-version` |
| Jito or Agave | Jito + Hexis | `ascend.sh migrate` (patches the `validator.sh` you have), or `arise.sh --hexis --hexis-tag <tag> --restart` |
| Jito + Hexis | plain Jito or Agave | `arise.sh` without `--hexis`, with `--client-version <tag> --restart`. The arb flags go and the Control port is closed; `/home/sol/hexis` is left on disk |
| Jito, Agave or Jito + Hexis | Firedancer | `reawaken.sh stage`, then `cutover` — or `arise.sh --client firedancer --fd-tag <tag> --restart`, which leaves the running `validator.sh` and unit alone, stages, and hands over to `cutover` |
| Firedancer | the Agave-family client it ran before | `reawaken.sh rollback` |
| Firedancer | a different Agave-family client, or one at all on a host set up as Firedancer | `arise.sh --client <jito\|agave> --client-version <tag> --restart`. The client is installed beside Firedancer, `sol.service` is written but not enabled, and `--restart` hands over to `reawaken.sh rollback` |

`reawaken.sh` asks before it stops anything, including when `arise.sh` hands over to it.

Things to know:

- A source build takes the better part of an hour and uses every core. On a host with
  a live validator, expect it to be slower for that time.
- `active_release` is repointed when the build finishes, a little before `validator.sh`
  is rewritten. An unplanned restart in that gap fails to start and is retried by
  systemd until the rewrite lands, a matter of seconds.
- If XDP is on and the NIC's ring sizes are not yet powers of two, they are resized,
  which drops the link for a moment. The script warns when a validator is running. A
  NIC that is already right is not touched.
- Jito and Agave at matching versions share the ledger format, so the ledger, accounts
  and snapshots are reused as they are.

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
| `firedancer` | `reawaken.sh stage`, then `cutover` on the next call | same | already there, unless a cutover is unfinished: then `cutover` again |
| `agave` | already there | already there | `reawaken.sh rollback` |

```bash
./system.sh upgrade    --host <ip> --ssh-key ~/.ssh/<key>
./system.sh firedancer --host <ip> --ssh-key ~/.ssh/<key> --print        # show, do not run
./system.sh upgrade    --host <ip> --ssh-key ~/.ssh/<key> -- --dry-run   # passed through
```

`--tag` picks a release other than the newest. A server with no validator is pointed at
`arise.sh`, which needs your keys and is never run from here.

What it makes of each kind of host:

| The host runs | Reported as | Moves offered |
|---|---|---|
| Plain Agave, mainnet | plain Agave | `hexis`, `firedancer` |
| Jito, mainnet | Jito | `hexis`, `firedancer` |
| Hexis Agave | Hexis Agave and its release | `upgrade`, `firedancer` |
| Firedancer with the Hexis Concorde, installed by `reawaken.sh` | that, plus the Agave client kept behind it | `upgrade`, `agave` |
| Any Agave client on testnet or devnet | the client | none: the Hexis builds are mainnet only |
| A Firedancer installed some other way (an upstream build taking Jito bundles, say) | what its config says it is | none: reported and left alone |

These scripts install and upgrade the Hexis builds only. They do not upgrade a plain
Agave or Jito validator in place, and they do not install or upgrade an upstream
Firedancer.

A cutover that needed a reboot (see below) leaves its last steps undone, because
Firedancer comes up by itself after the reboot. `system.sh` sees that jag-snap is still
listening or that perch still watches the old RPC port, and sends the `firedancer` goal
back to `cutover`, which then only does those steps.

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
fetches a current full snapshot while the validator still runs, waits for a window with
no leader slot and restarts Firedancer. The validator is not voting until the snapshot
has loaded: about two minutes from a file on disk, about an hour when it has to be
downloaded at start (see below). `--previous` points back at the release that was
active before and restarts; it refuses when that older binary does not accept the
current config.

`cutover` and `rollback` wait for a window with no leader slot for 90 minutes, `upgrade`
for 20; `--min-idle-time` changes either and `--now` skips the wait. The long default is
for what a move between clients can need at worst: a reboot and a full snapshot download.

**The reboot.** Firedancer needs 183 one-GiB pages as contiguous memory. A server that
has been up for a while often cannot provide them (memory is fragmented). `stage` and
`status` print a "Huge pages" line saying how many are needed, how many are reserved and
how long the host has been up; whether the kernel can find the rest is only known once
Agave has stopped. `cutover` therefore does everything else first — Agave stopped and
disabled, jag-snap retired, perch's dead endpoint removed — then gives the page cache
back, compacts memory and starts Firedancer. If the pages still cannot be reserved it
says so and asks to reboot the host (`--yes` answers that too). It then waits for the
host to come back and for `firedancer.service`, which is enabled and takes its pages
first thing. Nothing needs to be run after the reboot. Decline, and it prints the reboot
command and the way back (`rollback`). On a mainnet validator that needed the reboot, it
was voting again about eleven minutes after Agave stopped.

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
  built on that full slot; if anything above fails, it downloads as before. The full
  snapshot rolls over about every six hours, so a cutover that straddles a rollover
  (with a reboot in between, say) can still end in the download.

  `cutover` stops the jag-snap container and closes 18899/tcp; `rollback` starts it and
  reopens the port. Stake that depends on serving snapshots (JagPool) does not carry
  over to a Firedancer host.
- **The Block Engine connection sleeps.** Firedancer connects to the Jito Block Engine
  only around its leader slots; `bundle_conn_state` 3 (sleeping) between them is normal.
- **No BAM.** The Hexis Agave build has `--bam-url`; this Firedancer build has no
  equivalent.
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

**With Firedancer on either side** the steps are the same three (step down, carry the
vote history, step up) but the commands differ. Nothing here automates them.

```bash
# Host giving up the staked identity
#   Agave:
agave-validator -l /mnt/ledger wait-for-restart-window --min-idle-time 2 --skip-new-snapshot-check
agave-validator -l /mnt/ledger set-identity ~/unstaked_identity.json && ln -sf unstaked_identity.json ~/identity.json
#   Firedancer (wait needs root; set-identity runs as the validator user):
sudo ~/firedancer/firedancer wait --config ~/firedancer/config.toml --min-idle-seconds 120
~/firedancer/firedancer set-identity ~/unstaked_identity.json --config ~/firedancer/config.toml \
  && ln -sf unstaked_identity.json ~/identity.json

# Carry vote_history-<staked pubkey>.bin to the other host, into the directory its
# client reads: /mnt/ledger for Agave, /mnt/ledger/firedancer for Firedancer.
#   From Agave the file is     /mnt/ledger/vote_history-<pubkey>.bin
#   From Firedancer it is      /mnt/ledger/firedancer/vote_history-<pubkey>.bin.bak
#   (Firedancer renames the outgoing identity's file when it steps down; copy it to
#   the plain .bin name on the other side.)

# Host taking the staked identity, on Firedancer
~/firedancer/firedancer set-identity ~/staked_identity.json \
  --vote-history-file /mnt/ledger/firedancer/vote_history-<pubkey>.bin \
  --config ~/firedancer/config.toml \
  && ln -sf staked_identity.json ~/identity.json
```

- `--config` is required on every `firedancer` command; without it the command builds a
  default setup, finds no arb signer and refuses.
- `set-identity` changes the running validator only. The config points at
  `identity.json`, so the `ln -sf` is what makes it hold across a restart, on both hosts.
- Firedancer reads a vote history written by Agave, both at boot and through
  `set-identity`.
- Check that the two hosts' unstaked identities are different keys before you start.

---

## Troubleshooting

**"Could not auto-detect Jito region"** — the script will warn and continue. Open `~/validator.sh` on the server and replace the `<FILL_IN_...>` placeholders with values from https://jito.network/docs or pass `--jito-region` on the next run.

**"Cannot SSH to monarch@..."** — the admin user does not exist yet. Pass `--root-user root` on a fresh server, or `--root-user sol` on a server set up by an older version.

**"effective sshd config is missing ..."** — another file in `/etc/ssh/sshd_config.d/` that sorts before `00-arise.conf`, or a `Match` block, overrides the hardening. The change was rolled back; remove the conflicting setting and rerun.

**"Refusing to touch /dev/..."** — the disk has partitions, a mount, or is part of RAID/LVM. If it really is safe to erase, wipe it yourself with `wipefs -a` and rerun.

**Disks not detected** — check `lsblk` on the server. Auto-detection skips any drive that has partitions, a mount, or any existing filesystem or RAID signature. Use `--ledger-disk` / `--accounts-disk` to override.

**`--hexis-tag` fails** — the release download runs `gh` on **your** machine, not the server. Make sure `gh auth status` works and your account can see `hexishq/hexis-validator-docs`, or download the asset yourself and pass `--hexis-binary`.

**Arb never trades** — it boots disabled. Check `arb get`, then `/home/sol/hexis/arb-enable.sh`. If the validator refuses to boot at all, the config had a bad key: `agave-validator run` aborts on a typo in `arb-config.toml`.

**`cutover` says Firedancer "could not reserve its 1 GiB pages"** — expected on a server that has been up for a while. Answer yes to the reboot it offers, or reboot the host yourself; Firedancer starts on its own and nothing needs to be run afterwards. See [the reboot](#moving-to-firedancer-reawakensh).

**A `firedancer` command says `[arb.signer_key_path] is empty`** — it was run without `--config /home/sol/firedancer/config.toml`.

**`firedancer wait` says "insufficient permissions"** — it needs `sudo`.

**Firedancer downloads the full snapshot at start anyway** — no trusted peer still builds incrementals on the full snapshot that was on disk. It takes about an hour; nothing is wrong.

**Build fails** — check that the tag exists in the repo (`git ls-remote --tags https://github.com/jito-foundation/jito-solana.git`) and that the server has enough RAM and disk for a release build.

---

## What's NOT handled

- Vote account creation (do this yourself with `solana create-vote-account`)
- Stake delegation
- Identity hot-swap (documented under [Swapping to staked identity](#swapping-to-staked-identity), not automated)
- Prometheus / Grafana, and perch's alert secrets and disk checks (perch itself is installed by `arise.sh`)
- Snapshot serving — jag-snap is no longer set up; `reawaken.sh` still retires it on hosts that have it
- DoubleZero: `reawaken.sh` carries the shred receiver over and sets the queue mode a GRE tunnel needs, but installing and connecting DoubleZero is yours
- Backup of tower files and identity keys
- Disaster recovery

---

## Development

```
system.sh          report what a host runs and route a goal to the script that owns it
arise.sh           provision a fresh server into a validator
ascend.sh          upgrade / migrate / promote the Hexis Agave client on an existing server
reawaken.sh        stage / cutover / rollback / upgrade / status for Firedancer
lib/remote.sh      how every script reaches a server: admin user for sudo, scripts and
                   passwords over SSH stdin, strict error handling
lib/hexis.sh       shared Hexis defaults, logging, config rendering, checksum verification,
                   release discovery, perch hand-off
lib/firedancer.sh  validator.sh parsing, Firedancer config and unit rendering, snapshot
                   hand-over and pre-download
test/run.sh        test suite — no dependencies
```

The scripts source `lib/`, so they must be run from a checkout rather than copied
somewhere on their own. Hexis config values (program id, profit pool, marginfi account
and banks, token ledgers, lookup tables) live in `lib/hexis.sh`. Script names follow
Solo Leveling; a new script gets a name whose meaning matches what it does.

```bash
./test/run.sh              # everything
./test/run.sh patcher      # only cases matching a name
```

`ssh`, `scp` and `gh` are stubbed (`test/stubs/`) and host responses come from glob→output
fixtures (`test/fixtures/`), so the suite runs offline and touches no server. It covers the
`validator.sh` rewriter (including the shapes it must refuse rather than mangle), config
rendering, checksum verification, the flash-loan matrix, release staging and promotion,
CLI validation, the Firedancer config and every `reawaken.sh` mode, `system.sh` routing,
and the generated host-side steps (snapshot hand-over and pre-download, log rotation,
perch) run against scratch directories. CI runs it alongside `shellcheck`.

## License

[MIT](LICENSE) — experimental, use at your own risk.
