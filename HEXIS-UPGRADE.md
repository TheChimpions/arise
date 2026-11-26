# Upgrading Hexis

Upgrading is a new binary plus a restart. `arise.sh` sets a host up; `ascend.sh` upgrades
one or puts Hexis onto a validator that is already running.

```bash
# Version bump on a host that already runs Hexis
./ascend.sh upgrade --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <new-tag>

# Put Hexis onto a validator that is already running Jito or plain Agave
./ascend.sh migrate --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <tag>

# Switch to a release that is already on the host: a staged one, or an older one
./ascend.sh promote --host <ip> --ssh-key ~/.ssh/<key> --release <tag>
./ascend.sh promote --host <ip> --ssh-key ~/.ssh/<key> --list
```

If you are not sure which of these a host needs, `./system.sh --host <ip> --ssh-key
~/.ssh/<key>` reads the host and prints the command.

**Where releases live.** Each one is kept whole in `/home/sol/hexis/releases/<tag>/`, and
`/home/sol/hexis/agave-validator` is a symlink to the active one. `validator.sh` execs the
symlink, so it never needs editing for a version bump. `upgrade` downloads the release,
checks it against the release checksums, stages it in its own directory and repoints the
symlink. With `--stage-only` the symlink is left alone, so an unplanned restart still
comes up on the version you were running; `promote` activates it later. Going back is
`promote --release <older tag>`.

`migrate` additionally installs `hexis-setup`, puts the arb signer in place, writes
`arb-config.toml`, opens the Control port, and patches `validator.sh` after showing you
the diff. Neither mode enables the arb — that is still `arb-enable.sh`.

**Two accounts.** The validator user (`sol`) has no sudo. Its own files — the releases,
the config, `validator.sh` — are written over its SSH login. Anything that needs root,
such as the firewall rule for the Control port or telling a system-wide perch about a
restart, goes through the admin user, `monarch` by default; pass `--admin-user <name>`
when the host uses another, or let `system.sh` find it. If that account has passwordless
sudo you are not asked for a password.

**Credentials.** `migrate` writes the Jupiter API key and the arb metrics string to the
host. Neither is in this repository. Run at a terminal, `migrate` asks for whichever is
missing and offers to save it to `hexis.env` (git-ignored, mode 600); otherwise give them
with `--hexis-jup-key` / `--hexis-metrics-config`, the environment, or that file. See the
README. `upgrade` and `promote` need neither.

Nothing is restarted unless you pass `--restart`, which waits for a restart window and
then runs `exit` (`Restart=always` brings the validator back):

```bash
./ascend.sh upgrade --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <tag> --restart
```

The exit defaults to `--min-idle-time 20 --max-delinquent-stake 5 --skip-new-snapshot-check`;
override with those flags, or pass `--wait-for-new-snapshot` to wait for a fresh snapshot.
On a host that runs [perch](https://github.com/TheChimpions/perch-watchtower), the restart
is declared to it first, once the window is open, so it does not page.

The `exit` is always issued by the binary the running process is **actually executing** —
the Jito build during a migration, the outgoing release during an upgrade or promote —
rather than the one just installed, so the admin RPC call never crosses a version
boundary. `migrate --restart` is skipped if `validator.sh` was not patched, since the
restart would only bring back the old setup.

The rest of this file is the same procedure by hand, for when you want to see every
step or the script refuses to patch a startup script it doesn't recognise.

What an upgrade touches:

- `/home/sol/hexis/releases/<tag>/agave-validator` and the `agave-validator` symlink
  beside `releases/` — the validator itself, so the change needs a restart
- `/home/sol/hexis/arb-config.toml` — only if the release changed config keys
- `hexis-setup` — versioned separately, upgrade it only when you need to

What it doesn't touch: the arb signer, the profit wallet, the marginfi account, the
TokenLedgers, the lookup tables, `validator.sh`, or anything under `/mnt`.

Two facts that shape the whole procedure:

- **`arb-config.toml` is read once at boot**, and an unknown key aborts the boot. A
  release that renames a key will take the validator down on restart if the config
  wasn't updated first.
- **The arb pipeline always comes up disabled.** Every restart, including a crash
  restart, is a plain validator until you enable it again.

Substitute your ledger path below — `/mnt/ledger` when the setup found disks,
`/home/sol/ledger` when it fell back to `$HOME`.

---

## 1. Pick the tag

```bash
gh release list --repo hexishq/hexis-validator-docs
```

Validator tags look like `v4.2.1+concorde.3` — the Agave version, then the Hexis build
number. `hexis-setup` has its own tag (`v1.0-hexis-setup`) and its own cadence.

Read the release notes before going further. If they mention `arb-config.toml`, do step
4 before step 5.

---

## 2. Download and verify locally

The repo is private and `gh` authenticates with its own token, so `gh auth status` has
to show an account with access. An SSH key does not authorize this.

```bash
TAG='v4.2.1+concorde.3'
gh release download "$TAG" --repo hexishq/hexis-validator-docs \
  --pattern 'agave-validator-linux-amd64' --pattern '*checksums.txt' \
  --dir ~/hexis-"$TAG" --clobber

cd ~/hexis-"$TAG" && shasum -a 256 -c ./*checksums.txt
```

`shasum` must print `agave-validator-linux-amd64: OK`. Stop here if it doesn't.

---

## 3. Stage it on the server

Each release goes into its own directory; the running binary is never written over (the
kernel refuses to write a running executable: `Text file busy`). Staging changes nothing
the validator uses.

```bash
HOST=sol@<server-ip>
ssh "$HOST" "mkdir -p '/home/sol/hexis/releases/$TAG'"
scp agave-validator-linux-amd64 "$HOST:/home/sol/hexis/releases/$TAG/agave-validator"
ssh "$HOST" "
  cd /home/sol/hexis
  chmod +x 'releases/$TAG/agave-validator'
  'releases/$TAG/agave-validator' --version      # sanity check the new binary runs
  readlink agave-validator                       # the release that is active now
"
```

Note the release `readlink` prints: it is the one still running, the one step 5 issues the
`exit` through, and the one to go back to.

An install made before this layout has `agave-validator` as a plain file, not a symlink.
`ascend.sh upgrade` converts it; by hand, move the file to `releases/<its version>/` and
put a symlink in its place before going on.

**Activate it** by repointing the symlink. The rename is atomic and the running process
does not notice: it keeps its open file until it exits.

```bash
ssh "$HOST" "
  cd /home/sol/hexis
  ln -s 'releases/$TAG/agave-validator' .agave-validator.next
  mv -T .agave-validator.next agave-validator
  readlink agave-validator
"
```

Leave this step for later if you only want the release staged.

---

## 4. Update `arb-config.toml` — only if the release changed keys

```bash
ssh "$HOST" 'cp /home/sol/hexis/arb-config.toml /home/sol/hexis/arb-config.toml.bak'
ssh "$HOST" 'nano /home/sol/hexis/arb-config.toml'
```

Compare against `config.toml.example` in the release. There is no config linter and no
dry-run — a bad key surfaces as a validator that won't boot, so keep the `.bak` until
the new version is confirmed up.

---

## 5. Restart

`sol.service` is `Restart=always`, so a graceful exit brings the validator back on the
new binary. This waits for a safe moment rather than dropping mid-slot:

```bash
OLD='<release that step 3 printed>'
ssh "$HOST" "/home/sol/hexis/releases/$OLD/agave-validator --ledger /mnt/ledger exit \
  --min-idle-time 20 --max-delinquent-stake 5 --skip-new-snapshot-check"
```

The `exit` goes through the **old** release, the one the running process is executing, not
the symlink, which already points at the new one.

It blocks until the restart window opens, then exits and systemd restarts it. If the host
runs perch, declare the restart first so it does not page: `perch maint restart 1h` as
the admin user (`/home/sol/perch/maint restart 1h` as `sol` on an older host).

A blunt `systemctl restart sol` also works but skips the delinquency check — fine on a
testnet box, worse on staked mainnet. It needs root, so it is run as the admin user:
`ssh -t <admin>@<server-ip> 'sudo systemctl restart sol'`. `sol` has no sudo.

Watch it come back:

```bash
ssh "$HOST" 'tail -f /home/sol/logs/agave-validator.log'
ssh "$HOST" 'solana catchup --our-localhost'
```

---

## 6. Re-enable the arb

Only after the validator is caught up:

```bash
ssh "$HOST" '/home/sol/hexis/arb-enable.sh'
```

That runs `arb set --enabled true`, `arb set --program-size` (only on releases before
v4.3.2+concorde.1, which dropped the flag), the OKX TokenLedger set,
and prints `arb get`. Until it runs, the box is producing blocks with no arb.

---

## 7. Verify

```bash
ssh "$HOST" '
  /home/sol/hexis/agave-validator --version                          # matches the tag
  /home/sol/hexis/agave-validator --ledger /mnt/ledger arb get       # enabled, right identity
  ss -lntp | grep 18082                                              # Control still listening
  ls /home/sol/hexis/arb-reverts                                     # dumps spooling and clearing
'
```

---

## Rollback

The release you left is still in `releases/`. `./ascend.sh promote --release <old tag>
--restart` does all of this; by hand:

```bash
NEW='<release running now>'; OLD='<release to go back to>'
ssh "$HOST" "
  cd /home/sol/hexis
  ln -s 'releases/$OLD/agave-validator' .agave-validator.next
  mv -T .agave-validator.next agave-validator
  cp arb-config.toml.bak arb-config.toml     # only if step 4 changed it
"
ssh "$HOST" "/home/sol/hexis/releases/$NEW/agave-validator --ledger /mnt/ledger exit --min-idle-time 20 --max-delinquent-stake 5 --skip-new-snapshot-check"
ssh "$HOST" '/home/sol/hexis/arb-enable.sh'
```

---

## Upgrading `hexis-setup`

Separate release, and nothing depends on it at runtime — it only creates the marginfi
account, the LUTs and the TokenLedgers. No restart needed.

```bash
gh release download v1.0-hexis-setup --repo hexishq/hexis-validator-docs \
  --pattern 'hexis-setup-linux-amd64' --pattern '*checksums.txt' --dir /tmp/hs --clobber
cd /tmp/hs && shasum -a 256 -c ./*checksums.txt
scp hexis-setup-linux-amd64 "$HOST":/home/sol/hexis/hexis-setup
ssh "$HOST" 'chmod +x /home/sol/hexis/hexis-setup'
```

---

## Re-running `arise.sh` instead

`arise.sh --hexis --hexis-tag <new-tag>` will download, verify and install the new
binary, and it is idempotent — the existing signer and profit-wallet keypairs are kept.
It is not a lighter option than the steps above, though:

- It **regenerates `arb-config.toml` from the flags**, so any manual edit is lost, and
  omitting `--hexis-marginfi-account` silently drops `[flash_loan]` and turns flash
  loans off. Pass every flag you passed the first time.
- It re-runs the rest of the setup — firewall, sshd hardening, sysctl, swap, perch.
  Idempotent, but a lot of surface for a version bump.
- It regenerates `validator.sh`, which is what you want if the new release needs a new
  validator flag.
- It needs the two Hexis credentials again, since it writes `arb-config.toml` and
  `validator.sh`.
- It does not restart the validator unless you pass `--restart`, which waits for a
  restart window first. Step 6 still applies afterwards.

Worth it when the release changes validator flags or config shape, and it is how you
switch a host between clients (Jito, Agave, Hexis). Overkill for a plain binary bump.

## Firedancer hosts

None of this file applies to a host running Firedancer with the Hexis Concorde: there the
release is upgraded with `./reawaken.sh upgrade --fd-tag <tag>`, and the arb is part of
the build. See "Moving to Firedancer" in the README.
