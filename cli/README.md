# sym CLI

The Go CLI uses only the standard library. It parses arguments, sends one
request to `symd`, formats the reply, and exits. It does not speak LSP, know
languages, resolve symbol ambiguity, or keep state. The
[Nix package](../README.md#run) puts its companion `symd` alongside it.

From a directory containing `sym.toml`:

```sh
sym start
sym refs NAME
sym refs --at FILE:LINE:COL
sym def NAME
sym def --at FILE:LINE:COL
sym symbols FILE
sym stop
```

`--at` locations are 1-based and parsed from the right, so paths containing
colons work. File arguments become absolute paths before they are sent; the
daemon replies with absolute paths and the CLI prints them relative to the
working directory when they fall inside it. `--json` prints the raw result
object instead of location lines.

`start` launches the companion with separate arguments, no shell, and waits
for a compatible status reply (protocol 2). Output, including language-server
stderr, goes to `<socket>.log`. `stop` sends a socket request and waits for
cleanup; it never kills a process based on a PID file. Both commands are safe
to repeat.

The default socket is `.sym/symd.sock`. `--socket`, `--config`, `--service`,
and `--json` are global flags and go before the command. Use an absolute
socket path when calling the same daemon from different directories.
`--service /path/to/symd` overrides the companion executable.

Exit status: 0 answered, 1 service/connection failure, 2 bad usage, 3 a name
query too ambiguous to answer (the candidate definitions were printed; narrow
with a qualified name or `--at`).

Run `go test ./...` here for the CLI tests. `just test-package` at the root
also runs the real packaged CLI/service lifecycle test, without Erlang on the
caller's PATH.
