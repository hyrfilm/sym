# sym

`sym` is a small Go CLI; `symd` is its Elixir service. The working commands install
and list LSP packages. Semantic queries and running language servers come next.

## Run

From the repository root:

```sh
nix develop
(cd symd && mix deps.get)
just build
./bin/symd --config sym.toml --socket /tmp/symd.sock
```

Keep that terminal open. In another terminal, from the repository root:

```sh
./bin/sym --socket /tmp/symd.sock add --lsp typescript-language-server
./bin/sym --socket /tmp/symd.sock add --lsp dexter
./bin/sym --socket /tmp/symd.sock list
```

If direnv has already loaded `.envrc`, skip `nix develop`; the tools are already
on your PATH. The current `symd` executable needs Erlang's `escript` at runtime.

Starting `symd` creates the profile directory configured in `sym.toml` if needed.
The supplied configuration uses `.sym/profiles/symd-nix`; Nix owns the installed
package state. Installation does not start the language servers.

For one-shot use, run `./bin/sym --oneshot list` inside the development shell.
This starts `symd` for one request over stdin/stdout and exits. `just test` runs
both projects' tests.

## CLI / service protocol

[cli/](cli/README.md) parses arguments, sends one request, prints the JSON reply,
and exits. [symd/](symd/README.md) reads configuration and owns package commands.
The transport uses one JSON request line and one JSON reply line per Unix socket
connection. One-shot mode uses the same messages. The default socket is
`.sym/symd.sock`; the examples select `/tmp/symd.sock` explicitly.

```json
{"op":"add","lsp":"dexter"}
{"ok":true,"result":{"lsp":"dexter"}}
```

```json
{"op":"list"}
{"ok":true,"result":{"lsps":["dexter","typescript-language-server"]}}
```

Failures use `{"ok":false,"error":{"code":"...","message":"..."}}` and make
the CLI exit with status 1. Diagnostics go to stderr. Global CLI options, such as
`--socket`, go before the command.

The service handles requests sequentially. Startup refuses an existing socket;
if an interrupted service leaves one behind, remove the socket file only after
confirming that service has stopped.

Future semantic operations include symbols, references, and definitions. Their
external locations use only `path:line:column`, with 1-based line and column,
parsed from the right. Locations are authoritative; names are search terms.
