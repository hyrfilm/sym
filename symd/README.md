# symd service

The Elixir service owns language-server processes and answers semantic
queries over a Unix socket. It is normally started by the first `sym` query
(or `sym start`); to run the packaged service in the foreground:

```sh
./result/bin/symd --socket /tmp/symd.sock
```

## Transport / service

`Symd.Transport` handles the [CLI protocol](#cli-protocol):
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

## CLI protocol

The CLI sends one JSON request line per connection and reads one reply.
Semantic requests carry `op` (`symbols`, `def`, or `refs`), the caller's
absolute `cwd`, and either `name` or an absolute `path`. Queries at a
position also carry `line` and `column`, both starting at 1:

```json
{"op":"refs","path":"/home/user/project/src/parser.ts","line":42,"column":8,"cwd":"/home/user/project"}
```

Successful replies use `{"ok":true,"result":{...}}`. Failures use
`{"ok":false,"error":{"code":"...","message":"..."}}`; the CLI
prints the error and exits with status 1.

Management requests contain only `op`: `status` or `stop`. Status replies
include `service: "symd"`, `protocol: 4`, `state: "running"`, the process ID,
and the resolved workspaces. Stop replies acknowledge `state: "stopping"`;
the CLI then waits for socket cleanup.

## Workspaces / configuration

No configuration is read at startup. Every semantic request carries the
caller's working directory; `Symd.Discovery` walks up from it, and the first
directory containing `sym.toml` or `.git` is the workspace root (`sym.toml`
wins in the same directory, and the search never crosses a repository
boundary). A git root reads the global config, `$XDG_CONFIG_HOME/sym/sym.toml`.

`Symd.Config.parse/1` reads the `[lsp.<name>]` tables: `command`, optional
`args`, the `extensions` the server answers for, and optional workspace-relative
`directories`. `Symd.Workspaces`
caches one `Symd.Workspace` per root, re-reading the config on every request
and rebuilding — stopping the root's language servers first — when its
content changes. Config-relative commands resolve against the config file's
directory. The workspace's `request`, `sync`, and `settle` functions are
injected, so the semantic layer tests against canned LSP replies.

## Semantic layer

`Symd.Semantic` answers in files, names, and 1-based codepoint columns,
hiding LSP's method shapes and UTF-16 offsets (`Symd.Position` converts, per
line of text). Name queries consult every configured LSP with matching files;
a server with nothing to read is never started. They use `workspace/symbol`
after opening one seed file by default, or one seed per configured directory.
Seeds help load projects; the server still determines project membership and
name-search scope. TypeScript Language Server can scope names to the last
accessed file's projects, so seeding disconnected projects does not guarantee
that a name search covers all of them.

Queries filter exact matches (a dotted name matches the container, Elixir-style
`Mod.fun/1` names are normalized), re-anchor on the
identifier, and group references per symbol up to a cap of five; past it
they return candidates so the caller narrows instead of waiting. A group
whose references another group already covers (tsserver's `export { name }`
entries) is dropped. Each location carries its trimmed source line as
`text`, and `refs` at a position with no references fails with
`no_symbol_at`. Locations
are authoritative; names are search terms. Files are read from disk on every
query, and location-less or non-`file://` results are dropped rather than
guessed at.

Directory discovery runs on each definition/reference query, stopping at the
first matching regular file in each directory's alphabetical recursive
traversal. It considers untracked and ignored files, deduplicates seed paths,
and skips hidden entries, nested symlinks, and these dependency/build
directories: `node_modules`, `deps`, `_build`, `target`, `dist`, `build`,
`out`, and `vendor`. Repeated seed paths are opened only once.
Missing directories and read errors encountered during discovery fail the query;
empty directories are skipped. Positional queries also open the seeds before
asking the server for definitions or references. `symbols FILE` remains a
single-file operation.

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
`await_quiet/2` refreshes already-open documents, closes documents deleted from
disk, and waits, bounded, until the server reports no `$/progress` work
and a short settle period has passed — opening a file can start a whole
project load, and answers given during one are confidently incomplete.

Run `mix test` from this directory. `test/support/fake_lsp.exs` is a scripted
stdio language server the client tests run over real pipes.
The directory integration tests use `typescript-language-server` when it is
on PATH; otherwise ExUnit skips them.
