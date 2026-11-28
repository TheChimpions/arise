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

**What you can use.** Setting up a Jito or Agave validator from their public source needs
nothing but this repository, and that is what most of this page is about. So does vanilla
Firedancer, once you have built it: see [docs/firedancer.md](docs/firedancer.md). The Hexis
arb client and Firedancer with the Hexis Concorde come from private releases: those parts
work only if Hexis has given you access, and are described in [docs/hexis.md](docs/hexis.md)
and [docs/firedancer.md](docs/firedancer.md). Without that access, leave `--hexis`,
`--fd-tag` and `ascend.sh` alone.

| Script | What it is | What it does |
|---|---|---|
| `arise.sh` | Raising a new shadow soldier | **Start here for a new server.** Turns a fresh server into a validator: disks, kernel tuning, Jito build or Hexis binary, region detection, systemd, firewall, perch watchtower |
| `system.sh` | The System: status window and quests | **Start here for any server that already runs a validator.** Reports what the host runs and routes each move to the script that owns it |
| `ascend.sh` | Levelling up | Upgrades the Hexis Agave client, or moves a Jito / plain Agave validator onto it |
| `reawaken.sh` | A Re-Awakening | Moves a running validator onto Firedancer (vanilla, or with the Hexis Concorde), upgrades it there, and takes it back |

- New server: [Prerequisites](#prerequisites), then [Usage](#usage)
- Server that already runs a validator: [`system.sh`](#servers-that-already-run-a-validator)
- What the scripts trust and what they check: [Security model](#security-model) and [SECURITY.md](SECURITY.md)

---

## ⚠️ Disclaimers

**This is experimental software. Read before running.**

- **Review the script before you run it.** Open `arise.sh` and read what it does. It installs packages, formats disks, reconfigures the kernel, hardens SSH, opens firewall ports, and creates system users. These are destructive and hard to reverse.
- **This will format drives.** Auto-disk detection picks blank NVMe drives and runs `mkfs` on them. It skips any drive with partitions, a filesystem, a RAID/LVM signature or a mount, shows you what it found, and makes you type `format` before erasing anything. If in doubt, **pass `--no-auto-disks`** or pass `--ledger-disk` / `--accounts-disk` explicitly.
- **It disables root SSH login and SSH passwords.** After the first run you log in as the admin user or as `sol`, with your key. Pass `--keep-root-login` if your provider's rescue path needs key-based root login.
- **Mainnet validators handle real stake and real money.** A misconfigured validator can miss votes, go delinquent, and lose delegations. Do not run this on mainnet without understanding every step it performs.
- **Region auto-detection is best-effort.** It geolocates the server IP to pick the closest Jito region. If detection fails, the script will warn you and leave placeholders in `validator.sh` that you **must fill in manually** before starting the validator.
- **No warranty.** If this script bricks your server or summons a shadow army, that's on you.

**Verify after setup**, before starting the validator:

- `cat ~/validator.sh` on the server — confirm every flag is correct
- Check `--shred-receiver-address`, `--block-engine-url`, `--commission-bps`
- Check the flags against the release notes for the version you built — flags change between major versions
- Confirm `/mnt/ledger` and `/mnt/accounts` are mounted and owned by `sol`
- Confirm `solana-keygen verify` against your staked identity
- Run a testnet deploy first before touching mainnet

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
| **Firedancer** (vanilla) | `--client firedancer --fd-vanilla --fd-binary <path>` | A binary you built from `firedancer-io/firedancer`, which publishes source only. Any network |

Leave `--client-version` off and the script lists recent release tags to pick from.

Hexis and Firedancer installs have their own pages: [docs/hexis.md](docs/hexis.md) and [docs/firedancer.md](docs/firedancer.md).

**Jito on either network.** `--client jito` writes the Block Engine URL, shred receiver,
tip programs and merkle root upload authority for the network you chose: testnet has its
own set of all of them, and no DoubleZero shred receiver. The values are Jito's, copied
into `arise.sh` with the date and the page they came from; check them against
[Jito's on-chain addresses](https://jito-foundation.gitbook.io/mev/mev-payment-and-distribution/on-chain-addresses)
before a mainnet install. The merkle root upload authority is Jito's, so Jito runs the
tip airdrop and claim for your stakers.

A validator set up by an older copy of this script carries the previous mainnet
authority, `GZctHpWX…xDib`, in its `validator.sh`. Jito now publishes `8F4jGUmx…g8Xt`.
Compare yours with the page above and ask Jito if you are unsure which your stakers'
claims depend on.

### Flags

**Required:**

| Flag               | Description                                                                                                                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--host`           | Server IP or hostname                                                                                                                                                                                                    |
| `--ssh-key`        | Path to SSH private key                                                                                                                                                                                                  |
| `--identity`       | Path to `staked_identity.json`                                                                                                                                                                                           |
| `--vote-account`   | Vote account pubkey                                                                                                                                                                                                      |
| `--commission-bps` | **Jito** commission in basis points — the cut of Jito MEV tips taken via the tip distribution program (e.g. `0` = 0%, `500` = 5%; asked for on mainnet, 0 on testnet unless given). This is the Jito tip commission, **not** the validator vote commission. |

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
| `--fd-vanilla` | Vanilla Firedancer instead of the Hexis Concorde. Needs `--fd-binary`: see [docs/firedancer.md](docs/firedancer.md#vanilla-firedancer) |
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

**Hexis arb client:** the `--hexis` flags are listed in [docs/hexis.md](docs/hexis.md#installing-with-arisesh---hexis).

### Disk selection priority

1. **Explicit** — `--ledger-disk` / `--accounts-disk` if passed (disables auto-detection)
2. **Auto-detection** (default) — scans for unused, unformatted NVMe drives
3. **Fallback** — `/home/sol/ledger` and `/home/sol/accounts` if no drives found

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

- **On a Jito or Agave host, the validator account cannot become root through anything installed here.** `sol` has no sudo and is in no privileged group, `sol.service` runs with `NoNewPrivileges` and a read-only view of `/usr`, `/boot` and `/etc`, and root never changes the owner of a path inside a directory `sol` owns.
- **A Firedancer host is different: there the `sol` login is as good as root.** Firedancer starts as root, and `firedancer.service` runs the binary and the config in `/home/sol/firedancer`, which `sol` owns. Anyone who can log in as `sol` can replace either and has root at the next start. On such a host, guard `sol`'s SSH key the way you guard the admin's. This holds from the first `reawaken.sh stage` on.
- **XDP gives the validator process network capabilities.** With XDP on (the default) the process holds `CAP_NET_ADMIN`, `CAP_NET_RAW`, `CAP_BPF` and `CAP_PERFMON`, the four XDP needs and no others. `CAP_NET_ADMIN` is enough to change firewall rules, so the firewall does not contain a `sol` account that has been taken over. `--no-xdp` leaves them out.
- **SSH is key-only, and it is checked.** The settings go in `/etc/ssh/sshd_config.d/00-arise.conf` so they win over cloud-init's defaults. The script then reads sshd's effective configuration and rolls back and stops if anything overrides them. A `Match` block that only applies to some users or addresses is not seen by that check.
- **The first connection trusts the host key it is shown.** Check the fingerprint against your provider's console, or put the key in `known_hosts` before the first run. A key that changes later is refused.
- **The firewall opens only SSH and the validator's port range** (8000–8026, the minimum width Agave 4 accepts), plus the Hexis Control port to one address with `--hexis`. RPC is bound to `127.0.0.1`, kept out of gossip with `--private-rpc`, and not opened. Rules that were already in `ufw` are left as they are, apart from the old 8000–10000 one.
- **No secret is a file or an argument on the way to the server.** Scripts and the sudo password go over SSH stdin, no password appears in a process list on the server, and keypairs are created mode 600 from the first byte. This is `lib/remote.sh`, shared by `arise.sh`, `ascend.sh` and `reawaken.sh`. On your own machine, a Hexis credential given as a flag is in your shell history and process list (use `hexis.env`), and `--dry-run` prints the files it would write, credentials included.
- **Nothing GitHub-related goes on the server.** Public clients are cloned over HTTPS. Private releases (Hexis, Firedancer) are downloaded on your machine with `gh` and streamed up after their SHA-256 matches the release's checksum file. A release with no checksum for the file is refused.
- **Security updates stay on.** `unattended-upgrades` is enabled and `sol.service` is excluded from automatic restarts. CPU mitigations stay on. Both can be traded for performance with `--disable-auto-updates` and `--disable-cpu-mitigations`.
- **Nothing from the network is piped into a shell.** The Rust installer is a pinned release checked against a recorded SHA-256, and perch's installer is checked against its release checksums before it runs. [SECURITY.md](SECURITY.md) lists everything that is downloaded and how each is checked, including the one item that is not.
- **`arise.sh` stops at the first step that fails.** Every script it runs on the server runs under `set -euo pipefail`. A few best-effort steps (NIC ring tuning, `node_exporter`, telling perch about a restart) warn instead. `ascend.sh` and `reawaken.sh` set error handling step by step, and stop on a failure in anything that changes what the validator runs.

### Upgrading a server set up by an older version

Older versions gave `sol` sudo and docker access and left root login on. Run `arise.sh` once with `--root-user sol`: you will be asked for `sol`'s sudo password and for a new admin password. The script creates the admin user, then removes `sol`'s sudo and docker access, replaces the old 8000–10000 firewall rule, and disables root login. After this, use `ssh monarch@<host>` for anything that needs sudo, and `ascend.sh` / `reawaken.sh` ask for the admin user's sudo password (`--admin-user` if you named it something else).

It reports, but does not remove, leftovers such as an old GitHub key in `~sol/.ssh/github_key`, a `jag-snap` container, or `mitigations=off` in GRUB.

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

`sol` is deliberately not in the `perch` group: the validator account cannot silence the watchtower. The config uses perch's standalone layout with free public RPC endpoints. The script also installs `node_exporter` (answering on `127.0.0.1:9100` only) and gives perch a `[[hosts]]` entry for this machine, which turns on its disk and kernel-advisory checks. On a Firedancer host, `reawaken.sh cutover` adds Firedancer's own metrics to that same entry (perch 1.6.0 or newer). An existing perch config is never changed.

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

### Cluster metrics (SFDP)

The Solana Foundation Delegation Program requires validators to publish cluster metrics,
so `validator.sh` exports `SOLANA_METRICS_CONFIG` pointing at `metrics.solana.com` —
`db=mainnet-beta` or `db=tds` depending on `--network`. With `--hexis` it also exports
`SOLANA_METRICS_CONFIG_ARB` for the arb; the two are independent and both are set.

### Swapping to staked identity

The script starts the validator with an **unstaked identity** via a symlink:

```bash
ls -la ~/identity.json
# identity.json -> unstaked_identity.json
```

To go live with your staked identity, follow the Jito hot-swap procedure. Do not just `ln -sf` the staked identity without understanding tower file handling.

With Firedancer on either host the commands differ: see [docs/firedancer.md](docs/firedancer.md#swapping-the-staked-identity).

---

## Servers that already run a validator

`system.sh` looks at a host and says which of the other scripts applies to it. Without a
goal it only reports, and changes nothing:

```bash
# What does this host run, and what can be done from here? Read-only.
./system.sh --host <ip> --ssh-key ~/.ssh/<key>

# Then name the goal: upgrade | hexis | firedancer | agave
./system.sh upgrade --host <ip> --ssh-key ~/.ssh/<key>
```

It shows the client and release the host runs, whether Firedancer is installed, staged
or running, the newest Hexis Agave and Firedancer releases, and the command for each
move that is possible from there.

**Admin user.** The other scripts do their root work through an admin user, `monarch` by
default. On a host where that login does not take your key (one set up before the admin
user existed, say), `system.sh` tries the host's other login accounts with the same key
and uses the first that gets in and holds sudo. It says which one it found, and every
command it prints or runs carries `--admin-user <name>`. An `--admin-user` you pass is
used as given.

**Host checks.** The report also looks at a few things that are wrong whatever client
runs, each with the command that fixes it: a `/` not owned by root, the validator user
in the `docker` group or holding sudo, a firewall that is off, and keypair files other
users can read. It reads them as the validator user and changes nothing.

With a goal it runs that command through the script
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
| Vanilla Firedancer, installed by `reawaken.sh --vanilla` | vanilla Firedancer, plus the Agave client kept behind it | `agave`. For `upgrade` it prints the command: there is no release to fetch, so you build the new tag and pass it with `--fd-binary` |
| Any Agave client on testnet or devnet | the client | none from here: the Hexis builds are mainnet only. Vanilla Firedancer is staged with `reawaken.sh stage --vanilla` |
| A Firedancer installed some other way (not in `/home/sol/firedancer`) | what its config says it is | none: reported and left alone |

`system.sh` only ever fetches the Hexis builds. It does not upgrade a plain Agave or Jito
validator in place (that is `arise.sh`), and it does not build vanilla Firedancer.

A cutover that needed a reboot (see [docs/firedancer.md](docs/firedancer.md#moving-to-firedancer-reawakensh)) leaves its last steps undone, because
Firedancer comes up by itself after the reboot. `system.sh` sees that jag-snap is still
listening or that perch still watches the old RPC port, and sends the `firedancer` goal
back to `cutover`, which then only does those steps.

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

---

## Hexis and Firedancer

The Hexis arb client and Firedancer with the Hexis Concorde need a private release from
Hexis and run on mainnet only. Vanilla Firedancer needs neither, only a binary you built.

- [docs/hexis.md](docs/hexis.md): installing the Hexis arb client with `arise.sh --hexis`, the
  two credentials, turning the arb on, flash loans, and upgrading or migrating a running
  host with `ascend.sh`. The same upgrade done by hand is in [HEXIS-UPGRADE.md](HEXIS-UPGRADE.md).
- [docs/firedancer.md](docs/firedancer.md): vanilla Firedancer or the Hexis Concorde. A new
  Firedancer host, moving a running validator onto Firedancer and back with `reawaken.sh`,
  snapshots, perch, and the identity swap.

---

## Troubleshooting

**"Could not auto-detect Jito region"** — the script will warn and continue. Open `~/validator.sh` on the server and replace the `<FILL_IN_...>` placeholders with values from https://jito.network/docs or pass `--jito-region` on the next run.

**"Cannot SSH to monarch@..."** — the admin user does not exist yet. Pass `--root-user root` on a fresh server, or `--root-user sol` on a server set up by an older version.

**"effective sshd config is missing ..."** — another file in `/etc/ssh/sshd_config.d/` that sorts before `00-arise.conf`, or a `Match` block, overrides the hardening. The change was rolled back; remove the conflicting setting and rerun.

**"Refusing to touch /dev/..."** — the disk has partitions, a mount, or is part of RAID/LVM. If it really is safe to erase, wipe it yourself with `wipefs -a` and rerun.

**Disks not detected** — check `lsblk` on the server. Auto-detection skips any drive that has partitions, a mount, or any existing filesystem or RAID signature. Use `--ledger-disk` / `--accounts-disk` to override.

**Build fails** — check that the tag exists in the repo (`git ls-remote --tags https://github.com/jito-foundation/jito-solana.git`) and that the server has enough RAM and disk for a release build.

Hexis and Firedancer problems are in the troubleshooting sections of [docs/hexis.md](docs/hexis.md#troubleshooting) and [docs/firedancer.md](docs/firedancer.md#troubleshooting).

---

## What's NOT handled

- Vote account creation (do this yourself with `solana create-vote-account`)
- Stake delegation
- Identity hot-swap (documented under [Swapping to staked identity](#swapping-to-staked-identity), not automated)
- Prometheus / Grafana, and perch's alert secrets (perch itself and the node_exporter it reads are installed by `arise.sh`)
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
reawaken.sh        stage / cutover / rollback / upgrade / unit / status for Firedancer
lib/remote.sh      how every script reaches a server: admin user for sudo, scripts and
                   passwords over SSH stdin, strict error handling
lib/hexis.sh       shared Hexis defaults, logging, config rendering, checksum verification,
                   release discovery, perch hand-off
lib/firedancer.sh  validator.sh parsing, Firedancer config and unit rendering, snapshot
                   hand-over and pre-download
test/run.sh        test suite — no dependencies
docs/              the Hexis arb client (private release) and Firedancer
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
CLI validation, the values refused before they reach a file or a command on the host, the
Firedancer config and every `reawaken.sh` mode, `system.sh` routing, and the generated
host-side steps (snapshot hand-over and pre-download, log rotation,
perch) run against scratch directories. CI runs it alongside `shellcheck`.

Bug reports and changes: [CONTRIBUTING.md](CONTRIBUTING.md). Security problems: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) — experimental, use at your own risk.
