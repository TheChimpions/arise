# Security

These scripts log in to a server as root-equivalent, handle validator keypairs, and
decide what a firewall lets through. This file says what they trust, what they check,
and how to report a problem.

## Reporting a vulnerability

Please do not open a public issue for something that could put a validator or its keys at
risk. Use GitHub's private reporting instead: the repository's **Security** tab, then
**Report a vulnerability**. Include the script and flags involved, what you expected, what
happened, and whether a live host is affected.

You should hear back within a few days. Fixes land on `main`; there are no maintained
older branches, so the fix for any version is the current one.

Ordinary bugs — a step that fails, a wrong default, a confusing message — are welcome as
normal issues.

## What the scripts guarantee

The README's "Security model" section is the full list. In short:

- The validator user has no sudo and is not in the `docker` group. Root work goes through
  a separate admin user.
- On a Jito or Agave host, root never changes the owner of, or runs, anything inside a
  directory the validator user owns. A Firedancer host is the exception: see below.
- SSH is key-only, root login is off unless you keep it, and the sshd change is checked
  before it is applied.
- The firewall opens SSH and the validator's port range. RPC stays on localhost.
- Scripts and the sudo password reach the server over SSH stdin, never as a file or an
  argument. No password appears in a process list on the server, and keypairs are mode
  600 from the first byte.
- Values that end up in a command or a file on the server are checked against a strict
  pattern first: flags, release tags, and what is read back from `validator.sh` and the
  config files on the host.
- No credential is stored in this repository. The two Hexis credentials are supplied at
  run time and can be kept in `hexis.env`, which git ignores.
- `arise.sh` runs every script on the server under `set -euo pipefail` and stops at the
  first failure. `ascend.sh` and `reawaken.sh` set error handling step by step and stop
  on a failure in anything that changes what the validator runs. A few best-effort steps
  (NIC ring tuning, `node_exporter`, telling perch about a restart) warn instead.

## What is downloaded, and how it is checked

Nothing fetched from the network is piped into a shell. Each item below is the trust you
are extending when you run these scripts.

| What | From | Checked how |
|---|---|---|
| Jito or Agave source | the client's GitHub repository over HTTPS, at the tag you name | The tag is checked out and built on the server. Nothing verifies who signed the tag |
| Rust toolchain installer | `static.rust-lang.org`, a pinned rustup release | SHA-256 recorded in `arise.sh`; the installer is not run on a mismatch. rustup then fetches the toolchain itself, over HTTPS, with its own checks |
| Prebuilt Solana CLI (only when nothing is built from source) | `release.anza.xyz/stable/install` | Downloaded to a file and run as the validator user. **Not pinned and not checksummed** |
| Hexis and Firedancer releases | a private GitHub repository, downloaded on your machine with `gh` | SHA-256 against the checksum file published with the release, before upload. A release with no checksum file, or none for that asset, is refused. A binary you pass yourself (`--hexis-binary`, `--fd-binary`) is not checked: that is yours to verify |
| Vanilla Firedancer | built by you from `firedancer-io/firedancer` and passed with `--fd-binary` | Not checked, and it runs as root. The source tag, and what the project's `deps.sh` fetches while building, are yours to verify |
| perch watchtower (installed unless `--no-perch`) | its GitHub release, the latest unless `--perch-version` names one | `install.sh` is checked against the release's `SHA256SUMS` before it runs as root, and it checks the binary the same way. The checksums come from the same release, so this catches a damaged file, not a compromised publisher |
| `node_exporter`, base packages | Ubuntu's archive, with `apt` | apt's signed package lists |
| Full snapshot for Firedancer | an HTTP mirror (`--snapshot-mirror`) | Taken only when a validator on your snapshot allow list serves a full snapshot with the same slot and hash. That check is on the name, not the bytes; Firedancer verifies the contents when it loads them |

Addresses are copied into the scripts, and you inherit them unless you pass your own.
Jito's tip programs, merkle upload authority, Block Engine and shred receiver endpoints
carry the date and the page they were taken from, next to the value. The cluster
entrypoints and known validators (who you take snapshots from), the DoubleZero shred
receiver, and the Hexis program, profit pool and marginfi addresses are copied in
without one. They are other people's addresses and can change. Check them against the
source before a mainnet install.

With `--hexis`, and on a Firedancer host, a Control port (18082) listens on every
interface, and the firewall lets in only addresses Hexis operates: `188.40.61.182`, and
`146.71.98.50` as well on Firedancer, which also answers that first address on its
metrics port (7999). The firewall rule is the only thing restricting them, so `ufw` has
to be on; `ascend.sh` says so when it is not.

## Running a release you can trust

Run from a tagged release rather than whatever `main` happens to be, and check the tag
before you use it:

```bash
git fetch --tags
git tag -v <tag>          # the tag must verify against a key you trust
git checkout <tag>
```

A tag that does not verify should not be run against a host that holds keys.

For maintainers, releases are cut with a signed, annotated tag:

```bash
git tag -s v<version> -m "v<version>"
git push origin v<version>
```

Signing needs a key git knows about (`git config user.signingkey`, with either GPG or
`gpg.format ssh`) and the public half published where users can find it: on the
maintainer's GitHub profile, which also makes GitHub show the tag as Verified.

## What these scripts do not protect against

- A compromised machine running the scripts. It holds your SSH key and, for a moment, the
  validator keypairs and the sudo password.
- Someone in the path of the first connection, when you do not pass
  `--host-key-fingerprint`. The first run then accepts the host key it is shown, and
  sends the new admin password and the validator keypairs. Pass the fingerprint from
  your provider's console and the key is compared before anything connects; a host that
  does not have it is not connected to. A key that changes on a later run is refused.
- Your own shell history and process list, for a Hexis credential given as a flag. Use
  `hexis.env`. `--dry-run` prints the files it would write, credentials included.
- A compromised upstream: the client source, a private release, or a publisher whose
  checksums ship beside the file they describe.
- Anyone who already has the validator user's login. That account can read the keypairs
  it runs with. On a Jito or Agave host it cannot gain root or silence the watchtower
  through anything installed here. With XDP on (the default) the validator process does
  hold `CAP_NET_ADMIN`, which is enough to change the firewall.
- The validator user's login on a Firedancer host, which is as good as root. Firedancer
  starts as root, and `firedancer.service` runs the binary and config in
  `/home/sol/firedancer`, which that user owns; `reawaken.sh` also does root work inside
  that user's directories. This holds from the first `reawaken.sh stage` on.
- Leftovers from older setups. `system.sh` reports the ones it knows about, such as the
  validator user still being in the `docker` group.
