# symd service

The Elixir service owns profiles and installed LSP resources. From the repository
root, follow the [build instructions](../README.md#run), then start it inside the
development shell:

```sh
./bin/symd --config sym.toml --socket /tmp/symd.sock
```

`Symd.Transport` handles the [CLI / service protocol](../README.md#cli--service-protocol)
over a Unix socket or, with `--oneshot`, stdin/stdout. `Symd.Service` dispatches
`add` and `list` and produces result/error envelopes. Request lines are limited
to 64 KiB. Nix diagnostics go to stderr.

## Configuration / profile

`Symd.Config.parse/1` decodes TOML and extracts the required fields unchanged:

```toml
[profile]
name = "symd-nix"
type = "nix"
location = ".sym/profiles/symd-nix"
```

The parser reports syntax errors or missing fields. `Symd.Service.open/2` selects
the backend, resolves relative locations against the configuration file's directory,
and constructs the profile. Both daemon and one-shot startup call `Profile.install/1`
to create its directory idempotently. Startup installs no packages.

`Symd.Profile` holds a name, location, and injected functions:

- `install()` / `uninstall()`: idempotent lifecycle of the whole profile.
- `add(resource)` / `remove(resource)` / `list()`: installed resources.
- `command(resource)`: executable and argv for an installed resource.

The profile abstraction knows nothing about Nix, environment variables, or LSPs.
Backend code lives in `Symd.Profile.Nix`; a future backend supplies its own module
and is selected by the service, without changing the TOML parser.

## Package commands / backend

`sym add --lsp dexter` sends the name to the selected profile. The Nix backend
maps it to `nixpkgs#dexter` and invokes an executable with separate arguments:

```sh
nix profile add --profile .sym/profiles/symd-nix/profile nixpkgs#dexter
```

The backend's `add` and `remove` accept package names. `list` reads Nix's JSON
manifest each time; there is no second installed-package database. `command`
accepts a resource with `executable` and `args` and returns its invocation pair.
The command runner is injected for tests.

The owned directory contains Nix's `profile` and generation links. Uninstalling
that profile removes its directory; packages in the Nix store remain untouched.

## Installed resource / running LSP

Installation does not start language servers. A future `Symd.Lsp.Instance`,
identified by `{lsp_name, repo_root}`, will own the process and LSP JSON-RPC over
stdio. Its `Content-Length` byte framing is separate from the CLI / service protocol.

Run `mix test` from this directory.
