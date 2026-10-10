---
name: sym
description: Semantic code navigation via LSP — find definitions, references, and file symbols. Use instead of grep when the question is "where is X defined/used".
---

- `sym def NAME` — where NAME is defined (`Parser.parse` narrows by container)
- `sym refs NAME` — every reference to NAME
- `sym def --at FILE:LINE:COL` / `sym refs --at FILE:LINE:COL` — exact, position-based
- `sym symbols FILE` — what a file declares

Output is one `path:line:col` per line, 1-based; add `--json` before the
command for structured output.

Exit code 3 means the name was ambiguous and the candidate definitions were
printed — retry with a qualified name or `--at`. Exit 1 errors state their
reason on stderr (`no_workspace` means no sym.toml or git repository was
found above the current directory).

Works from any directory inside a project; the daemon starts itself.
