```
 █████╗ ██████╗ ██╗███████╗███████╗
██╔══██╗██╔══██╗██║██╔════╝██╔════╝
███████║██████╔╝██║███████╗█████╗
██╔══██║██╔══██╗██║╚════██║██╔══╝
██║  ██║██║  ██║██║███████║███████╗
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚══════╝╚══════╝
```

A one-shot, idempotent setup script that takes a fresh Ubuntu server and turns it into a Solana validator (testnet or mainnet). Handles disk setup, kernel tuning, Jito build, region detection, systemd services, firewall, and jag-snap.

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
7. **Rust + Solana CLI** — installs via rustup, clones and builds Jito-Solana from source (requires `--github-ssh-key`)
8. **Identity keypairs** — copies your staked identity, generates an unstaked identity, symlinks `identity.json`
9. **Validator script** — generates `validator.sh` with region-specific Jito block engine, shred receiver, and BloXroute shred receivers based on server geolocation
10. **systemd** — creates `sol.service` and `sol-fix-mounts.service` (enabled but not started)
11. **Log rotation, firewall, SSH hardening, fail2ban**
12. **jag-snap** — clones and runs the jag-snap snapshot container

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
| Flag | Description |
|---|---|
| `--host` | Server IP or hostname |
| `--ssh-key` | Path to SSH private key |
| `--identity` | Path to `staked_identity.json` |
| `--vote-account` | Vote account pubkey |
| `--commission-bps` | Commission in basis points (mainnet only, e.g. `0`) |

**Bootstrap (fresh servers):**
| Flag | Description |
|---|---|
| `--root-user` | Initial sudo user (default: `root`). Creates the `sol` user and reconnects as `sol`. |

**Optional:**
| Flag | Description |
|---|---|
| `--github-ssh-key` | SSH key for GitHub (required to build Jito + run jag-snap) |
| `--jito-repo` | Jito-Solana git repo URL (default: `git@github.com:jito-foundation/jito-solana.git`) |
| `--network` | `testnet` or `mainnet` (default: `testnet`) |
| `--jito-region` | Override auto-detection (e.g. `frankfurt`, `new-york`, `singapore`) |
| `--ledger-disk` | Explicit ledger disk (e.g. `/dev/nvme0n1`). Disables auto-detection. |
| `--accounts-disk` | Explicit accounts disk. Disables auto-detection. |
| `--no-auto-disks` | Disable NVMe auto-discovery entirely |
| `--swap-size` | Swap file size (default: `128G`) |
| `--dry-run` | Print commands without executing them |

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

## License

[MIT](LICENSE) — experimental, use at your own risk.
