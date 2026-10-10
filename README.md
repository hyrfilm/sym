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
provide. Configure them once, globally, in `~/.config/sym/sym.toml`
(see below) — then, from anywhere inside any git repository:

```sh
sym refs createMidiScheduler
sym def parse
sym def Parser.parse
sym refs --at src/parser.ts:42:8
sym symbols src/parser.ts
```

There is no setup step per repository and no daemon to start: the first
query starts `symd` in the background, language servers start lazily on the
first query that needs them (the first answer per server is the slow one),
and everything shuts itself down when unused — each language server after
15 idle minutes, the daemon after 30. `sym start`, `sym status`, and
`sym stop` remain for explicit control; `status` lists the workspaces the
daemon currently serves. After upgrading sym, a still-running older daemon
is replaced automatically by the next query.

## Workspaces

Every query carries the directory it was run from. Walking upward from
there, the first directory containing `sym.toml` or `.git` is the workspace
root:

- `sym.toml` wins when both are in the same directory, and marks the root
  explicitly — this is also the monorepo escape hatch: a `sym.toml` in
  `packages/web/` scopes queries under it to that package.
- A `.git` root uses the global config, `~/.config/sym/sym.toml`
  (`$XDG_CONFIG_HOME` is honored). The search never continues past a
  repository boundary.
- Neither found: the query fails with `no_workspace`.

The nearest config wins wholesale; files are not merged. Source roots inside
a project (`src/`, `tsconfig.json` directories, `go.mod` modules) are the
language server's own business — sym hands it the workspace root and the
server does its project discovery from there. Queries behave identically
from any directory inside the project.

## Configuration

Each `[lsp.<name>]` table says how to start one language server and which
files it answers for — the format is the same globally and per project:

```toml
[lsp.typescript]
command = "typescript-language-server"
args = ["--stdio"]
extensions = [".ts", ".tsx", ".js", ".jsx"]
```

`command` is an executable name looked up on PATH, or a path resolved
against the config file's directory. Config edits are picked up on the next
query — the affected root's language servers restart; no daemon restart is
needed.

One daemon serves all workspaces through one socket, `~/.sym/symd.sock` by
default; its log (including language-server stderr) is `~/.sym/symd.sock.log`.
`SYM_SOCKET` or the `--socket` flag (before the command) select a different
socket — useful for isolated test runs.

## Agents

[skills/sym/SKILL.md](skills/sym/SKILL.md) is a ready-made skill file. Copy
it to `~/.claude/skills/sym/SKILL.md` (or a project's `.claude/skills/sym/`)
so agents reach for `sym` instead of grep. It is deliberately free of setup
instructions, because the tool needs none.

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
companion daemon when none answers. [symd/](symd/README.md) owns workspace
resolution, language-server processes, and the semantic operations. One
request per connection; requests carry `op` (`symbols`, `def`, `refs`,
`status`, `stop`) plus either `name` or `path`[+`line`+`column`], with
absolute paths; semantic requests also carry the caller's absolute `cwd`:

```json
{"op":"refs","name":"createMidiScheduler","cwd":"/home/user/project"}
{"ok":true,"result":{"matches":[{"symbol":{...},"refs":[{"path":"...","line":17,"column":5}]}]}}
```

Failures use `{"ok":false,"error":{"code":"...","message":"..."}}` and make
the CLI exit with status 1. Daemon `status` returns `service: "symd"`,
`protocol: 3`, `state: "running"`, its process ID, and the `workspaces` it
has resolved; `stop` acknowledges `state: "stopping"` and the CLI waits for
socket cleanup.

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
