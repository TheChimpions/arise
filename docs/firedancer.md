# Firedancer with the Hexis Concorde

`reawaken.sh` moves a validator onto Firedancer with the Hexis Concorde, upgrades it there,
and takes it back to Agave. The build is released privately by Hexis, so this page needs a
GitHub account Hexis has given access to and the arb signer Hexis issues. It runs on mainnet
only.

**The validator user is as good as root on a Firedancer host.** Firedancer starts as root,
and `firedancer.service` runs the binary and the config in `/home/sol/firedancer`, which
the validator user owns. Anyone who can log in as `sol` can replace either and has root at
the next start. Guard that SSH key the way you guard the admin's. See the
[security model](../README.md#security-model).

## A new server

```bash
./arise.sh --host <ip> --ssh-key ~/.ssh/<key> --identity <staked_identity.json> \
    --vote-account <pubkey> --network mainnet --commission-bps <bps> \
    --client firedancer --fd-tag '<tag>'
```

`arise.sh` provisions the host and writes `validator.sh` as the record of the validator's settings (identity, vote account, entrypoints, Block Engine, shred receivers), leaves `sol.service` disabled, then runs `reawaken.sh stage` for you — the same staging a migrated host gets. Staging starts nothing. Start it with `./reawaken.sh cutover --host <host> --ssh-key <key>`: with nothing running there is nothing to stop, so it checks the config, asks once and starts `firedancer.service`. Pass `--hexis-signer <signing_key.json>` to use the arb signer Hexis issued; otherwise one is generated. There is no Agave client on such a host, so `reawaken.sh rollback` has nothing to go back to until you install one beside Firedancer — see [Changing client](../README.md#changing-client-on-a-host-that-already-runs-one).

## Moving to Firedancer (`reawaken.sh`)

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

# A Firedancer host set up by an older copy of these scripts: rewrite its unit so
# every start fetches the snapshot from the mirror when needed. Restarts nothing.
./reawaken.sh unit --host <ip> --ssh-key ~/.ssh/<key>

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
  Firedancer's p2p UDP ports;
- keeps snapshot downloads to the validators `validator.sh` names with `--known-validator`
  when there are three or more. `--snapshot-allow-any` takes them from any gossip peer
  instead, which is Firedancer's own default.

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
    (`--snapshot-mirror`, default `https://snapshots.avorio.network/mainnet-beta`), when
    it is newer than what is on disk. The mirror is a third party: its file is taken
    only when a validator on the snapshot allow list serves a full snapshot with the
    same slot and hash. That check is on the name, not the bytes.
  - **Every start of `firedancer.service` does the same**, as a pre-start step
    (`/usr/local/sbin/firedancer-snapshot-prefetch`, root's file). That is what covers a
    crash, a reboot, or a restart nobody planned: without it such a start is the hour's
    download. It runs after `configure`, so the huge pages are taken first; it fetches
    nothing when the snapshot on disk is still the one the cluster is on, which takes
    about a second to find out; and it can never stop a start — on any failure, or
    after 15 minutes, Firedancer starts and downloads from its peers as before. On a
    host that has never run a validator it asks a public RPC endpoint where the
    trusted validators serve their snapshots.

  The file is fetched in 1 GiB pieces, eight at a time, each written straight to its
  place and retried by itself, so a dropped connection costs one piece, not the whole
  download. After a fetch, the two newest full snapshots are kept and older ones are
  removed with their incrementals. `--no-snapshot-prefetch` turns all of it off:
  given to `stage` or `unit`, it leaves the pre-start step out of the unit.

  `stage` writes the unit with the pre-start step, so a fresh install and a host moving
  from Agave both get it. A host staged before this existed gets it from
  `reawaken.sh unit`, which rewrites the unit and the script and restarts nothing.

  Firedancer starts from the local file when a trusted peer still serves incrementals
  built on that full slot; if anything above fails, it downloads as before. Measured on
  one host: about 600 MB/s from the mirror against 33 MB/s from the trusted peer, and
  under four minutes from the restart to the tip once the file was on disk.

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

## perch on a Firedancer host

A cutover to Firedancer also takes this host's own RPC out of perch's `[[endpoints]]`
(Firedancer runs without RPC, so perch would never see the validator recover), keeps the
old file as `config.toml.bak-pre-firedancer`, and restarts perch. `rollback` puts it back.

The same cutover points perch at **Firedancer's own metrics**, when the host runs perch
1.6.0 or newer: it adds `firedancer_url` to the `[[hosts]]` entry for this machine, using
the address and port under `[tiles.metric]` in Firedancer's config. perch then reports
what Firedancer says about itself — voting, replay, turbine, a hung tile, how full the
accounts index is — which is the local view a validator without RPC otherwise lacks. No
firewall change is needed: perch is on the same machine. An older perch refuses a config
with that key, so it is left alone and you are told to upgrade it; run `cutover` again
afterwards (on a host already on Firedancer it only does the leftover steps, this one
included). The new config is checked with perch itself before it replaces the old one,
and `rollback` takes the line out again. A fresh `arise.sh --client firedancer` install
gets this too: `arise.sh` writes the `[[hosts]]` entry and the cutover that first starts
Firedancer fills it in.

## Swapping the staked identity

`arise.sh` starts a validator on an unstaked identity (`identity.json` is a symlink to
`unstaked_identity.json`); see [Swapping to staked identity](../README.md#swapping-to-staked-identity)
in the README. With Firedancer on either side the steps are the same three (step down,
carry the vote history, step up) but the commands differ. Nothing here automates them.

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

## Troubleshooting

**`cutover` says Firedancer "could not reserve its 1 GiB pages"** — expected on a server that has been up for a while. Answer yes to the reboot it offers, or reboot the host yourself; Firedancer starts on its own and nothing needs to be run afterwards. See [the reboot](#moving-to-firedancer-reawakensh).

**A `firedancer` command says `[arb.signer_key_path] is empty`** — it was run without `--config /home/sol/firedancer/config.toml`.

**`firedancer wait` says "insufficient permissions"** — it needs `sudo`.

**Firedancer downloads the full snapshot at start anyway** — the pre-start step did not put a current one on disk. `journalctl -u firedancer | grep 'snapshot pre-download'` says why: the mirror did not answer, no trusted validator served the same snapshot, or the download ran past its deadline. The download from the peers takes about an hour; nothing is wrong. A host staged by an older copy of these scripts has no pre-start step at all: `./reawaken.sh unit` adds it.
