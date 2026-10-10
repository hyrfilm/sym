# sym CLI

The Go CLI uses only the standard library. It parses arguments, sends one
request to `symd`, formats the reply, and exits. It does not speak LSP, know
languages, resolve symbol ambiguity, or keep state. The
[Nix package](../README.md#install) puts its companion `symd` alongside it.

From anywhere inside a workspace (a directory with `sym.toml`, or a git
repository covered by the global config):

```sh
sym refs NAME
sym refs --at FILE:LINE:COL
sym def NAME
sym def --at FILE:LINE:COL
sym symbols FILE
```

Every semantic request carries the working directory it was run from; the
daemon resolves the workspace from it. When no daemon answers, the query
starts one — `sym start` exists but is never required. When a running daemon
identifies itself as symd on a different protocol (one left over from before
an upgrade), the query stops it, starts a fresh one, and retries once.

`--at` locations are 1-based and parsed from the right, so paths containing
colons work. File arguments become absolute paths before they are sent; the
daemon replies with absolute paths and the CLI prints them relative to the
working directory when they fall inside it. `--json` prints the raw result
object instead of location lines.

`start` launches the companion with separate arguments, no shell, and waits
for a compatible status reply (protocol 3). Output, including language-server
stderr, goes to `<socket>.log`. `stop` sends a socket request and waits for
cleanup; it never kills a process based on a PID file. Both commands are safe
to repeat, and the daemon also stops itself after 30 idle minutes.

The default socket is `~/.sym/symd.sock` — one daemon per user, reachable
from every directory. The `SYM_SOCKET` environment variable overrides it,
and the `--socket` flag overrides both; `--socket`, `--service`, and
`--json` are global flags and go before the command.
`--service /path/to/symd` overrides the companion executable.

Exit status: 0 answered, 1 service/connection failure, 2 bad usage, 3 a name
query too ambiguous to answer (the candidate definitions were printed; narrow
with a qualified name or `--at`).

Run `go test ./...` here for the CLI tests; they include auto-start and
stale-daemon replacement, using the test binary itself as a fake symd.
`just test-package` at the root also runs the real packaged CLI/service
lifecycle test, without Erlang on the caller's PATH.
