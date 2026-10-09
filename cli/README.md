# sym CLI

The Go CLI parses arguments, sends one request to `symd`, prints its JSON reply,
and exits. It uses only the standard library and knows nothing about TOML or Nix.

After the [root build instructions](../README.md#run), run from the repository root:

```sh
./bin/sym --socket /tmp/symd.sock add --lsp typescript-language-server
./bin/sym --socket /tmp/symd.sock add --lsp dexter
./bin/sym --socket /tmp/symd.sock list
./bin/sym --socket /some/path/symd.sock list
```

The default socket is `.sym/symd.sock`. Global flags go before `add` or `list`.
Exit status is 0 for success, 1 for service/connection failures, and 2 for bad usage.

One-shot mode starts the adjacent `symd` executable and uses stdin/stdout instead
of a socket. Run it inside the development shell so Erlang is available:

```sh
./bin/sym --oneshot --config sym.toml list
```

Use `--service /path/to/symd` to override that executable. Both modes use the same
[request/reply protocol](../README.md#cli--service-protocol). `symd` selects the
profile and resolves package names into backend commands.

Run `go test ./...` from this directory.
