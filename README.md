# sym

`sym` answers the questions coding agents usually mis-solve with grep: where
is this defined, where is it referenced, what does this file declare. A small
Go CLI talks to `symd`, an Elixir daemon that owns language-server processes
and translates LSP into those answers.

`sym` points at language servers; it does not install or manage them. Where
an executable comes from — nix, npm, a checkout — is your business.

## Run

Build and install the Nix package from a checkout:

```sh
nix build .
nix profile add ./result
```

The package supplies the Erlang runtime; language servers are yours to
provide. From a directory containing `sym.toml` (this repository includes one):

```sh
sym start
sym refs createMidiScheduler
sym def parse
sym def Parser.parse
sym refs --at src/parser.ts:42:8
sym symbols src/parser.ts
sym stop
```

`start` launches `symd` in the background and waits until it is ready;
repeating it keeps the existing daemon. `stop` shuts down and removes the
socket. A later start recovers a socket left behind by a crash, while
preserving live listeners. Language servers start lazily on the first query
that needs them, so the first answer per server is the slow one.

## Configuration

Each `[lsp.<name>]` table in `sym.toml` says how to start one language server
and which files it answers for:

```toml
[lsp.typescript]
command = "typescript-language-server"
args = ["--stdio"]
extensions = [".ts", ".tsx", ".js", ".jsx"]
```

`command` is an executable name looked up on PATH, or a path resolved against
the config file's directory. The workspace root is the config file's
directory. The default socket is `.sym/symd.sock`, relative to the working
directory, and logs (including language-server stderr) go to
`.sym/symd.sock.log`. To share a daemon across directories, pass the same
absolute `--socket` path to all commands and an absolute `--config` path to
`start`. Global flags go before the command.

## Answers

The default output is one `path:line:col` per line — the shape every tool
already parses — with a tab-separated `name (kind)` description where one
exists. Lines and columns are 1-based; columns count codepoints. `--json`
prints the result object instead, with absolute paths.

```sh
$ sym refs createMidiScheduler
src/foo.ts:17:5
src/bar.ts:82:11
```

Names are search terms; locations are authoritative. A dotted name
(`Parser.parse`) narrows by container. When a name matches several symbols,
the reply groups references per symbol; past five matches it returns the
candidate definitions instead and exits with status 3, so an agent knows to
narrow with a qualified name or `--at FILE:LINE:COL` rather than parse refs.
Exit codes: 0 answered, 1 failure, 2 bad usage, 3 too ambiguous.

Files are re-read from disk and re-sent to the server on every query, so
answers reflect edits made since the last one. Definition and reference
queries also wait (bounded) while a server reports indexing progress, because
an answer computed during a project load is confidently incomplete.

## CLI / service protocol

[cli/](cli/README.md) parses arguments, sends one JSON request line over the
Unix socket, formats the JSON reply, and exits. It also launches its
companion daemon on `start`. [symd/](symd/README.md) owns configuration,
language-server processes, and the semantic operations. One request per
connection; requests carry `op` (`symbols`, `def`, `refs`, `status`, `stop`)
plus either `name` or `path`[+`line`+`column`], with absolute paths:

```json
{"op":"refs","name":"createMidiScheduler"}
{"ok":true,"result":{"matches":[{"symbol":{...},"refs":[{"path":"...","line":17,"column":5}]}]}}
```

Failures use `{"ok":false,"error":{"code":"...","message":"..."}}` and make
the CLI exit with status 1. Daemon `status` returns `service: "symd"`,
`protocol: 2`, `state: "running"`, and its process ID inside the result;
`stop` acknowledges `state: "stopping"` and the CLI waits for socket cleanup.

## Develop

```sh
nix develop
just build
just check
```

With direnv active, skip `nix develop`. `just build` fetches Mix dependencies
and builds the development executables into `bin/`; that development `symd`
still uses the shell's Erlang runtime. `just check` runs tests, formatting
checks, and Go vet. `just package` builds the local Nix package into
`result/`, and `just test-package` checks it with a bare runtime PATH,
including crash recovery.

Before new source files are tracked by Git, use `just package path:.` with the
daemon stopped; that copies the local directory instead of Git's tracked files.
