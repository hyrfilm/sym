# symd service

The Elixir service owns language-server processes and answers semantic
queries over a Unix socket. It is normally started by the first `sym` query
(or `sym start`); to run the packaged service in the foreground:

```sh
./result/bin/symd --socket /tmp/symd.sock
```

## Transport / service

`Symd.Transport` handles the [CLI / service protocol](../README.md#cli--service-protocol):
one JSON line each way, one request per connection, request lines limited to
64 KiB. Each accepted connection runs in its own supervised task, so a slow
query — a language server starting cold can take seconds — never blocks the
next client, and a crash spoils one connection only. A stop request closes
the listener from its handler, which ends the accept loop and lets the
executable unlink its own socket; `Symd.Idle` closes it the same way after
30 minutes without connections, waiting until nothing is in flight. Startup
recovers a refused stale socket after checking its identity, with one retry;
it preserves live listeners and other kinds of files. This assumes a
directory controlled by the user.

`Symd.Service` validates requests strictly — missing or extra fields are
errors, not guesses — dispatches `symbols`, `def`, and `refs` to the semantic
layer, and produces result/error envelopes with stable error codes. Status
and stop are tagged control results handled by the transport.

## Workspaces / configuration

No configuration is read at startup. Every semantic request carries the
caller's working directory; `Symd.Discovery` walks up from it, and the first
directory containing `sym.toml` or `.git` is the workspace root (`sym.toml`
wins in the same directory, and the search never crosses a repository
boundary). A git root reads the global config, `$XDG_CONFIG_HOME/sym/sym.toml`.

`Symd.Config.parse/1` reads the `[lsp.<name>]` tables: `command`, optional
`args`, and the `extensions` the server answers for. `Symd.Workspaces`
caches one `Symd.Workspace` per root, re-reading the config on every request
and rebuilding — stopping the root's language servers first — when its
content changes. Config-relative commands resolve against the config file's
directory. The workspace's `request`, `sync`, and `settle` functions are
injected, so the semantic layer tests against canned LSP replies.

## Semantic layer

`Symd.Semantic` answers in files, names, and 1-based codepoint columns,
hiding LSP's method shapes and UTF-16 offsets (`Symd.Position` converts, per
line of text). Name queries fan out `workspace/symbol` to every configured
LSP that has matching files in the workspace — a server with nothing to read
is never started — filter exact matches (a dotted name matches the
container, Elixir-style `Mod.fun/1` names are normalized), re-anchor on the
identifier, and group references per symbol up to a cap of five; past it
they return candidates so the caller narrows instead of waiting. Locations
are authoritative; names are search terms. Files are read from disk on every
query, and location-less or non-`file://` results are dropped rather than
guessed at.

## Language-server clients

`Symd.Lsp.Client` owns one server process per configured LSP and workspace
root, started lazily by `Symd.Servers` on the first query that needs it and
registered under `{lsp name, root}`. Clients are temporary children: a dead
server disappears with its client and the next query starts a fresh one, and
a client that nobody queries for 15 minutes stops itself — with a best-effort
LSP shutdown/exit goodbye — to release the server's memory. The client speaks
JSON-RPC over stdio using `Content-Length` framing (`Symd.Lsp.Wire`),
performs the initialize handshake during init, correlates requests by id
without blocking in callbacks, and answers server-to-client requests with
well-formed empty results. Server stderr is inherited by the VM and lands in
the daemon log.

Document state follows the disk: `sync/2` sends `didOpen` once and a full
`didChange` only when content differs from what the server last saw.
`await_quiet/2` waits, bounded, until the server reports no `$/progress` work
and a short settle period has passed — opening a file can start a whole
project load, and answers given during one are confidently incomplete.

Run `mix test` from this directory. `test/support/fake_lsp.exs` is a scripted
stdio language server the client tests run over real pipes.
