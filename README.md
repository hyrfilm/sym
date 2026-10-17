# sym

## CLI for quick navigation of codebases using your LSPs of choice
## for agents
## (and humans)


`sym` finds definitions, references, and the symbols declared in a file.
It uses language servers to answer questions about code from the command
line, with output that coding agents and scripts can read.

```sh
sym def parse
sym refs createMidiScheduler
sym symbols src/parser.ts
```

There are two parts: the `sym` command and `symd`, a daemon that runs in
the background. The command sends each query to the daemon, which keeps
language servers running between queries. The first query starts the
daemon automatically.

The [agent skill](skills/sym/SKILL.md) describes when and how to use sym.

## Install

Build and install the Nix package from a checkout:

```sh
nix build .
nix profile add ./result
```

Install the language servers you need separately, then add them to sym's
configuration as described below.

## Configuration

Use `~/.config/sym/sym.toml` for settings shared across Git repositories.
To configure one project, put `sym.toml` at its root. A project config
replaces the global config completely, so include all the servers it needs.
If you use `XDG_CONFIG_HOME`, the global config goes in
`$XDG_CONFIG_HOME/sym/sym.toml` instead.

Each `[lsp.<name>]` section configures a language server. For example, to
use TypeScript and Svelte:

```toml
[lsp.typescript]
command = "typescript-language-server"
args = ["--stdio"]
extensions = [".ts", ".tsx", ".js", ".jsx"]

[lsp.svelte]
command = "svelteserver"
args = ["--stdio"]
extensions = [".svelte"]
```

| Setting | Meaning |
| --- | --- |
| `command` | The executable to run, found on `PATH` or at a path relative to the config file. |
| `args` | Arguments passed to the executable. Defaults to `[]`. |
| `extensions` | File extensions handled by this server, including the leading dot. |
| `directories` | Optional source directories to open files from before queries. |

`command` and `extensions` are required. An extension such as `.ts` covers
both `parser.ts` and `parser.test.ts`. See [examples/sym.toml](examples/sym.toml)
for more server configurations.

### Source directories

If your project has more than one source directory, you can list the
directories explicitly. Add this under the relevant `[lsp.<name>]` section:

```toml
directories = ["src", "test", "e2e"]
```

Before definition and reference queries, sym opens one matching file in
each directory to help the language server load its projects. The server
can also return results from other directories. Without this option, or
with `directories = []`, name searches start from one file per server.

Paths are relative to the project root, including when set in the global
config. Use directory names without wildcards or `..`. Missing directories
cause an error; directories with no matching files are skipped.

Config changes take effect on the next query. sym restarts the affected
project's language servers automatically.

## Usage

Run sym from anywhere inside a configured project or Git repository.
Use a name to find definitions or references:

```sh
sym def parse
sym refs createMidiScheduler
```

A qualified name such as `Parser.parse` narrows the matches. If you know
where a symbol occurs, use its file, line, and column:

```sh
sym def Parser.parse
sym def --at src/parser.ts:42:8
sym refs --at src/parser.ts:42:8
```

To list the symbols declared in one file, use `sym symbols src/parser.ts`.
Lines and columns start at 1. Columns count Unicode codepoints.

Results use `path:line:column`, with a name and kind when available.
Paths are relative to the current directory when possible. For JSON output
with absolute paths, put `--json` before the command:

```sh
sym --json refs createMidiScheduler
```

To see each reference's source line after its location, separated by a
tab, put `--source` before the command:

```sh
sym --source refs createMidiScheduler
```

A reference query at a position that isn't on a symbol fails with
`no_symbol_at` instead of printing nothing.

When a reference query matches several symbols, sym groups the results by
symbol. With more than five matches, it prints the possible definitions
instead. Use a qualified name or `--at` to narrow the query. Exit codes are
0 for success, 1 for failure, 2 for incorrect usage, and 3 for too many matches.

### Managing the daemon

The daemon starts automatically, but you can also control it directly:

```sh
sym start
sym status
sym stop
```

`status` lists the projects the daemon is serving. After upgrading or
rebuilding sym, run `sym stop`; the next query starts the new daemon.

The default socket is `~/.sym/symd.sock`, and the log is
`~/.sym/symd.sock.log`. Set `SYM_SOCKET` or pass `--socket` before the command
to use a different socket. Its log has the same path with `.log` appended.
More options are described in the [CLI documentation](cli/README.md).

## Feedback

`sym --feedback "TEXT"` appends one line to `~/.sym/feedback.txt`, and
`sym --feedback` prints the notes written so far. It's meant for agents (and
people) to note a missing feature or a problem at the moment they hit it.

## How it works

The daemon starts language servers as they are needed and reuses them for
later queries. Each workspace has its own server processes. The first query
takes longer because the server has to load the code; later queries use
what it has already loaded.

A language server stops after 15 idle minutes. The daemon stops after
30 idle minutes.

### Finding the project root

Starting from the current directory, sym walks upward until it finds
`sym.toml` or `.git`. That directory is the project root, also called the
workspace. sym uses the config there, or the global config if it finds only
`.git`. It never looks beyond a Git repository's root.

This also lets you configure packages separately. For example, placing
`sym.toml` in `packages/web/` makes that directory a workspace of its own
when you run sym from there or one of its subdirectories. Projects outside
Git need a `sym.toml` to mark their root.

### Loading files

Language servers use compiler settings and imports to decide which files
belong together. Opening one file can load a whole project. The `directories`
setting gives the server a file to start from in each listed directory.
If a directory contains several independent projects, list their directories
individually.

TypeScript Language Server can limit name searches to the projects
containing the last file it accessed. If an app and its build scripts have
separate configurations and share no files, a name search may cover only
one of them. Using `--at` skips the name lookup; `symbols FILE` queries
that file directly.

### Reading changes

sym reads files from disk and sends changed contents to the language server.
Before definition and reference queries, it also refreshes files opened by
earlier queries, closes deleted files, and waits briefly while the server
reports loading work. The server handles changes to files sym has not opened.
Save editor changes before querying them with sym.

## Development

The CLI is written in Go and the daemon in Elixir. The
[CLI documentation](cli/README.md) and [daemon documentation](symd/README.md)
explain their implementation and the protocol between them.

```sh
nix develop
just build
just check
```

With direnv active, skip `nix develop`. `just build` fetches dependencies
and writes the development executables to `bin/`. The development daemon
uses the shell's Erlang runtime. `just check` runs the tests, formatting
checks, and Go vet.

`just package` builds the Nix package into `result/`. `just test-package`
checks the packaged CLI and daemon, including startup and crash recovery.
To include source files not yet tracked by Git, stop the daemon and use
`just package path:.`.
