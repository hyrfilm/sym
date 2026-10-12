---
name: sym
description: Semantic code navigation via LSP — find definitions, references, and file symbols. Use instead of grep when the question is "where is X defined/used".
---

- `sym def NAME` — where NAME is defined (`Parser.parse` narrows by container)
- `sym refs NAME` — every reference to NAME
- `sym def --at FILE:LINE:COL` / `sym refs --at FILE:LINE:COL` — exact, position-based
- `sym symbols FILE` — what a file declares

Output is one `path:line:col` per line, 1-based; add `--json` before the
command for structured output. Add `--source` before the command to print
each reference's source line after a tab (`sym --source refs NAME`) — use it
when triaging call sites, so you can tell an import from a call without
opening each file.

Exit code 3 means the name was ambiguous and the candidate definitions were
printed — retry with a qualified name or `--at`. Exit 1 errors state their
reason on stderr (`no_workspace` means no sym.toml or git repository was
found above the current directory).

`refs --at` on a position that isn't a symbol exits 1 with `no_symbol_at`;
an empty answer never means "no references" silently.

tsserver doesn't follow a variable into an object that exposes it by
shorthand (`const api = { parse }`; uses as `api.parse(...)`). For such a
symbol, also run `refs --at` on the shorthand property.

Works from any directory inside a project; the daemon starts itself.

When sym gets in your way — a missing feature, a wrong or confusing answer,
something that made you fall back to grep — leave a one-line note:
`sym --feedback "refs should follow shorthand properties"`. `sym --feedback`
alone lists the notes so far. They go to `~/.sym/feedback.txt` and are read
when sym is improved, so be concrete about what you tried and what you
expected.
