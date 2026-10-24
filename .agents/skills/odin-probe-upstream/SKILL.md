---
name: odin-probe-upstream
description: Check a checker or lowering rule against upstream Odin before changing our compiler. Use when a self-check, probe or test disagrees with the reference compiler, or when deciding what upstream accepts or rejects.
---

# Probe a rule against upstream

Goal: know what the reference compiler does before touching `src/check` or `src/lower`. Upstream is the behavioural target. Record observed behaviour as fact.

## Steps

1. Write a minimal probe in `/tmp/fx/<name>.odin`. Use `paper_write`; the directory must exist first (`mkdir -p`).
2. Reference result: `/home/su3h7am/Projects/Odin/odin check /tmp/fx/<name>.odin -file -no-entry-point`. Read the exit code (0 accepted, 1 rejected) and the diagnostic text.
3. Our result: `env ODIN_ROOT=$PWD /tmp/fx/odinc-alias check /tmp/fx/<name>.odin`. `odinc-alias` is the private binary built by `odin-private-validation`.
4. Compare exit codes first, then the text. Text parity is a separate task.
5. For the upstream source of a rule, grep `/home/su3h7am/Projects/refs/compilers_linkers/Odin-upstream/src/check_expr.cpp` (and the other `check_*.cpp`). Read the procedure, not the whole file.

## Runtime probes

- `check` does not run code. To run, `build` a directory, not a file: put `main.odin` in `/tmp/fx/pr/<name>/` and run `odinc-alias build <dir> --output <dir>/bin`.
- The reference `build` can fail at link time (for example `Runtime procedure not found: native_memmove`). Then only compare `check`.

## Pitfalls

- Fish shell: no heredocs (`cat > f <<EOF` fails). Write files with `paper_write`.
- Fish has no `for ... do`. Use `for x ... end`.
- `odin check` on a single file needs `-file`. Without `-no-entry-point`, a file with no `main` fails.
- A probe that passes `check` can still crash lowering. Always also `build` the directory.
- Our Odin `$status` in fish is per command. Put `set code $status` right after the command when you need it.
- Do not add a rule before the probe matches upstream exit code on at least two variants (accept and reject).
