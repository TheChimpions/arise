# Contributing

These scripts are run as root-equivalent against servers that hold validator keys, so a
change is judged first on what it does to a host that is already running.

## Reporting a problem

- **A bug**: open an issue with the script, the flags (leave out keys, credentials and
  anything from `hexis.env`), what you expected and what happened. `--dry-run` output
  helps, but it prints the files it would write, credentials included: remove them first.
- **A security problem**: do not open a public issue. See [SECURITY.md](SECURITY.md).

## Making a change

```bash
./test/run.sh                 # everything; no dependencies, touches no server
./test/run.sh reawaken        # only the groups whose name matches
shellcheck -S warning *.sh lib/*.sh test/run.sh
```

CI runs both on every pull request. A change should come with a test: `ssh`, `scp` and
`gh` are stubbed in `test/stubs/`, and host responses come from `test/fixtures/`, so a
test can assert on the exact script that would have run on the server.

What a change needs to keep true:

- **A value that reaches the server is checked first.** Flags, release tags and anything
  read back from a file on the host go through a strict pattern before they are put into
  a remote command or a file. Root scripts in `arise.sh` take their values through
  `emit_vars` and a quoted heredoc.
- **Root does not act on a path the validator user controls**: no `chown`, no write, no
  execute inside a directory that user owns. `reawaken.sh` and the Firedancer unit do not
  meet this today, which is why [SECURITY.md](SECURITY.md) says what it does about a
  Firedancer host. Do not add to it.
- **No secret in an argument or a temporary file.** Passwords and scripts go over SSH
  stdin; keypairs through `sol_write_file`.
- **Nothing from the network runs unchecked.** A download is pinned or compared with a
  published checksum, and a missing checksum is a failure.
- **A running validator is not restarted or stopped without being asked.**
- **The stock macOS bash (3.2) runs every script.**
- **No credential in the repository**, in a test or in a fixture.

A new script gets a Solo Leveling name whose meaning matches what it does, like the ones
here.
