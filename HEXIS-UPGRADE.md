# Upgrading Hexis

Upgrading is a binary swap plus a restart. `arise.sh` sets a host up; it does **not**
upgrade one — `ascend.sh` does.

```bash
# Version bump on a host that already runs Hexis
./ascend.sh upgrade --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <new-tag>

# Put Hexis onto a validator that is already running Jito or plain Agave
./ascend.sh migrate --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <tag>
```

`upgrade` downloads and checksum-verifies the release, uploads it as `.new`, keeps the
outgoing binary as `agave-validator.<old-version>`, and renames the new one into place.
`migrate` additionally installs `hexis-setup`, puts the arb signer in place, writes
`arb-config.toml`, opens the Control port, and patches `validator.sh` after showing you
the diff. Neither enables the arb — that is still `arb-enable.sh`.

Neither restarts anything unless you pass `--restart`, which runs `exit` (wait for the
restart window, then stop; `Restart=always` brings it back):

```bash
./ascend.sh migrate --host <ip> --ssh-key ~/.ssh/<key> --hexis-tag <tag> \
  --restart
```

The exit defaults to `--min-idle-time 20 --max-delinquent-stake 5 --skip-new-snapshot-check`;
override with those flags, or pass `--wait-for-new-snapshot` to wait for a fresh snapshot.

The `exit` is always issued by the binary the running process is **actually executing** —
the Jito build during a migration, the outgoing release during an upgrade or promote —
rather than the one just installed, so the admin RPC call never crosses a version
boundary. `migrate --restart` is skipped if `validator.sh` was not patched, since the
restart would only bring back the old setup.

The rest of this file is the same procedure by hand, for when you want to see every
step or the script refuses to patch a startup script it doesn't recognise.

What an upgrade touches:

- `/home/sol/hexis/agave-validator` — the validator itself, so the swap needs a restart
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

Upload beside the running binary, never over it — the kernel refuses to write a running
executable (`Text file busy`). A rename is atomic and leaves the running process on its
old inode, so this is safe while the validator is up.

```bash
HOST=sol@<server-ip>
scp agave-validator-linux-amd64 "$HOST":/home/sol/hexis/agave-validator.new
ssh "$HOST" '
  cd /home/sol/hexis
  chmod +x agave-validator.new
  ./agave-validator.new --version          # sanity check the new binary runs
  cp -a agave-validator "agave-validator.$(./agave-validator --version | awk "{print \$2}")"
  mv agave-validator.new agave-validator
  ls -la agave-validator*
'
```

The `cp -a` keeps the outgoing binary next to the new one as a named rollback.

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
ssh "$HOST" '/home/sol/hexis/agave-validator --ledger /mnt/ledger exit \
  --min-idle-time 20 --max-delinquent-stake 5 --skip-new-snapshot-check'
```

It blocks until the restart window opens, then exits and systemd restarts it. A blunt
`sudo systemctl restart sol` also works but skips the delinquency check — fine on a
testnet box, worse on staked mainnet.

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

```bash
ssh "$HOST" '
  cd /home/sol/hexis
  mv agave-validator.<old-version> agave-validator
  cp arb-config.toml.bak arb-config.toml     # only if step 4 changed it
'
ssh "$HOST" '/home/sol/hexis/agave-validator --ledger /mnt/ledger exit --min-idle-time 20 --max-delinquent-stake 5 --skip-new-snapshot-check'
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
- It re-runs the rest of the setup — firewall, sshd hardening, sysctl, swap, jag-snap.
  Idempotent, but a lot of surface for a version bump.
- It regenerates `validator.sh`, which is what you want if the new release needs a new
  validator flag.
- It does not restart the validator. Steps 5 and 6 still apply.

Worth it when the release changes validator flags or config shape. Overkill for a plain
binary bump.
