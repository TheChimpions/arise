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
- SSH is key-only, root login is off unless you keep it, and the sshd change is checked
  before it is applied.
- The firewall opens SSH and the validator's port range. RPC stays on localhost.
- Scripts and the sudo password reach the server over SSH stdin. Nothing is written to
  `/tmp`, no password appears in a process list, and keypairs are mode 600 from the first
  byte.
- No credential is stored in this repository. The two Hexis credentials are supplied at
  run time and can be kept in `hexis.env`, which git ignores.
- Every remote step is checked; a failure stops the run.

## What is downloaded, and how it is checked

Nothing fetched from the network is piped into a shell. Each item below is the trust you
are extending when you run these scripts.

| What | From | Checked how |
|---|---|---|
| Jito or Agave source | the client's GitHub repository over HTTPS, at the tag you name | The tag is checked out and built on the server. Nothing verifies who signed the tag |
| Rust toolchain installer | `static.rust-lang.org`, a pinned rustup release | SHA-256 recorded in `arise.sh`; the installer is not run on a mismatch. rustup then fetches the toolchain itself, over HTTPS, with its own checks |
| Prebuilt Solana CLI (only when nothing is built from source) | `release.anza.xyz/stable/install` | Downloaded to a file and run as the validator user. **Not pinned and not checksummed** |
| Hexis and Firedancer releases | a private GitHub repository, downloaded on your machine with `gh` | SHA-256 against the checksum file published with the release, before upload |
| perch watchtower | its GitHub release | `install.sh` is checked against the release's `SHA256SUMS` before it runs as root, and it checks the binary the same way. The checksums come from the same release, so this catches a damaged file, not a compromised publisher |
| `node_exporter`, base packages | Ubuntu's archive, with `apt` | apt's signed package lists |
| Full snapshot for Firedancer | an HTTP mirror (`--snapshot-mirror`) | Taken only when a validator on your snapshot allow list serves a full snapshot with the same slot and hash. That check is on the name, not the bytes; Firedancer verifies the contents when it loads them |

Addresses copied into the scripts — Jito's tip programs, merkle upload authority, Block
Engine and shred receiver endpoints, the Hexis program and wallets — carry the date and
the page they were taken from, next to the value. They are other people's addresses and
can change. Check them against the source before a mainnet install.

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
- A compromised upstream: the client source, a private release, or a publisher whose
  checksums ship beside the file they describe.
- Anyone who already has the validator user's login. That account can read the keypairs
  it runs with; it cannot gain root or silence the watchtower through anything installed
  here.
- Leftovers from older setups. `system.sh` reports the ones it knows about, such as the
  validator user still being in the `docker` group.
