---
name: odin-probe-upstream
description: Check a checker or lowering rule against the official Odin compiler and upstream source before changing our compiler. Use when a self-check, probe or test disagrees with the reference, or when deciding what official Odin accepts or rejects.
---

# Probe a rule against the official compiler

Goal: know what the official compiler does before touching `src/check` or `src/lower`. The official compiler and upstream source are the only behavioural references. Record observed behaviour as fact.

The LLVM-based fork at `/home/su3h7am/Projects/Odin` is not a reference. It is only the bootstrap builder of our compiler (see `odin-private-validation`). Never copy fork behaviour or internals.

## Steps

1. Write a minimal probe in `/tmp/fx/<name>.odin`. Use `paper_write`; the directory must exist first (`mkdir -p`).
2. Official result (first): `ODIN_ROOT=/home/su3h7am/.local/share/mise/installs/odin/dev-2026-10 /home/su3h7am/.local/share/mise/installs/odin/dev-2026-10/bin/odin check /tmp/fx/<name>.odin -file -no-entry-point`. Read the exit code (0 accepted, 1 rejected), the position and the diagnostic text, including `Note:` lines.
3. Our result: `env ODIN_ROOT=/home/su3h7am/Projects/odin-compiler /tmp/fx/odinc-self check /tmp/fx/<name>.odin` (the self-hosted binary from `odin-private-validation`; `odinc-alias` only when no self-hosted build exists, and say so).
4. Compare exit codes first, then positions, then text. Text parity is a separate step.
5. For the upstream source of a rule, grep `/home/su3h7am/Projects/refs/compilers_linkers/Odin-upstream/src` (for example `check_expr.cpp`). Read the procedure, not the whole file.
6. Any program the official compiler accepts must be accepted by ours. A mismatch there is a finding.

## Runtime probes

- `check` does not run code. To run, `build` a directory, not a file: put `main.odin` in `/tmp/fx/pr/<name>/` and build it with the official compiler first, then ours.
- If the official `build` fails at link time (for example `Runtime procedure not found: native_memmove`), compare only `check`, and record the error.

## Pitfalls

- Fish shell: no heredocs (`cat > f <<EOF` fails) and no `VAR=value cmd` prefixes. Write files with `paper_write`; for an env var, use `env X=... cmd` or a bash script.
- Fish has no `for ... do`. Use `for x ... end`.
- `odin check` on a single file needs `-file`. Without `-no-entry-point`, a file with no `main` fails.
- A probe that passes `check` can still crash lowering. Always also `build` the directory.
- Do not add a rule before the official exit code matches on at least two variants (accept and reject).
- Probes made with the fork before this rule are stale: re-check them with the official binary before reporting them as matched.
