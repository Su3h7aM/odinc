---
name: odin-lower-crash-triage
description: Find which procedure and construct crash the private compiler during lowering (Bounds check failed in src/ir, SIGILL). Use when the private odinc build of src/odinc or a probe dies inside src/lower or src/ir.
---

# Triage a lowering crash

Symptom: `src/ir/...(L:C) Bounds check failed: N is out of range 0..<M`, exit 132 (SIGILL). It is an invariant violation in lowering, not an input to tolerate.

## Steps

1. Reduce first. Make a probe directory `/tmp/fx/pr/<name>/main.odin` and `build` it with the private binary. Halve the program until one construct remains.
2. Make lowering serial: add `--thread-count 1` to the build. Crash location then does not depend on the thread pool.
3. Name the procedure. Temporarily add a print at the top of `lower_procedure` in `src/lower/lower_procedure.odin` (import `core:fmt`, `fmt.eprintfln("TMPDBG lower %v", job.program.symbol_table[job.program.entity_symbols[procedure.entity]].name)`). Rebuild a debug binary with the reference compiler (`odin build ... -out:/tmp/fx/odinc-dbg`). The last `TMPDBG` line before the crash is the job. Remove the print and check `grep -rn TMPDBG src/` is empty before reporting.
4. Stack with LLDB (never GDB). `lldb -b -s script -- <bin> build ...` with script:
   ```
   breakpoint set -n runtime::default_assertion_contextless_failure_proc
   run
   memory read --format hex --size 8 --count 400 $rsp
   quit
   ```
   Plain `bt` shows only frame 0 (no unwind info). Take the `0x...` values in the text range, then `image lookup -a <addr>` on each. The `Summary:` lines name `lower::...` and `ir::...` procedures.
5. Read the caller that stores a variable (`ir.variables_truncate`, `state.locals`, `scope.variables`) and find the path that reads a variable after truncation.

## Known causes so far

- Labeled block (`lower_block` in `src/lower/lower_control.odin`) ran its `defer`s twice (explicit `run_deferred`, then `leave_local_scope`). Repro: `/tmp/fx/pr/v7`. Fixed by truncating `state.defers` after the explicit run.
- `or_else <noreturn call>`: the fallback has no value; lower the call, then `ir.emit_unreachable` and skip the store (`lower_propagation.odin`).

## Pitfalls

- Remove every `TMPDBG` print before reporting.
- Do not "fix" the bounds check. Fix the lowering that produced the bad variable id.
- Add a regression test in the lower test file that owns the construct when the fixture allows it; otherwise say so in the report.
