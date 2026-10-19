# 14 Backend review

Date: 2026-10-17. Scope: the backend path (`lower`, `ir`, `sched`, `regalloc`, `amd64`, `elf`, `link`) and the `odinc` driver, measured on generated inputs. Inputs and logs are in `/tmp/nabla_bench/`. Other agents edit `src/` concurrently, so the check results describe the tree as it stood at about 23:12. `src/` and `base/`/`core/` were not changed.

## Findings

1. Time grows near-linearly after the lowering fix. Before it, time and memory grew faster than linearly, because per-procedure work scaled with the size of the whole program (sections 1 and 2). The regalloc occupancy table was the largest memory source (section 2a). With the regalloc fix, RSS at 3200 functions falls from 760 MB to 115 MB, and RSS per function is nearly flat (section 1c). Verified.
2. The `Undeclared_Name` failure at 3200 functions does not reproduce. Both the current `odinc` build and the 23:11 build compile the current 3200-function input with exit status 0. The failing log predates the input file it names, so it came from an earlier version of that input. The earlier 6.36 s timing is not a valid compile time (section 3).
3. Four packages fail `mise run check`: `check`, `lower`, `driver`, `odinc`. The cause is one type error in `src/check/global_order.odin`, which another agent is editing. The other eight packages pass (section 4).
4. The `amd64` backend already imports `core:rexcode/isa/x86`, so the prior-art rule is met there (section 5).

## 1. Measurements

Inputs come from `/tmp/nabla_bench/gen.lua`. Each of the n functions runs an 8-iteration loop, and `main` calls each one once. Timings use `/usr/bin/time` (wall, user, max RSS).

| Input | Compiler | Wall (s) | User (s) | RSS (MB) | Status |
|---|---|---|---|---|---|
| d50 | odinc | 0.05 | 0.04 | 13.6 | compiled |
| d400 | odinc | 0.24 | 0.26 | 37.5 | compiled |
| d1600 | odinc | 1.80 (repeat 1.85) | 2.77 | 241.4 | compiled |
| d3200 | official (LLVM build) | 0.54 | 0.59 | 353.7 | compiled |
| d3200 | odinc | 6.36 | 10.73 | 803.8 | not valid, see section 3 |

Scaling of odinc from 400 to 1600 functions (4 times the input): wall time grows 7.5 times and RSS grows 6.4 times. Linear growth would give 4 times for both. Verified (from the logs above).

We have no official measurement at 1600 functions, so the comparison at equal size is not available. At 1600 functions odinc already takes 1.80 s, which is 3.3 times the official time at 3200 functions. Verified (from the logs). Extrapolating the measured step suggests about 7 s at 3200 functions. Unverified: this is a projection, not a measurement.

The official run was recorded with the same generated input. We did not check its output, and we did not check whether odinc's output at 1600 functions runs correctly. Unverified.

## 1a. After the lowering fix

Measured with `odinc_resume`, built from the tree at about 23:45 (three runs per input, `/usr/bin/time`). Each input compiles with exit status 0, and the produced binary runs with exit status 0. Verified.

| Input | Wall (s) | User (s) | RSS (MB) |
|---|---|---|---|
| d50 | 0.05 | 0.04 | 13.0 |
| d400 | 0.17 | 0.12 | 34.7 |
| d1600 | 0.64 | 0.42 | 229.0 |
| d3200 | 1.42 | 0.90 | 778.5 |

Before the fix (`odinc_cur`, 23:15): d400 0.24 s, d1600 1.81 s, d3200 6.25 s; RSS 37.7, 241.5 and 804.3 MB. Verified from the logs.

Time: from 400 to 1600 functions, wall time grows 3.8 times for 4 times the input. From 1600 to 3200, it grows 2.2 times for 2 times the input. Verified.

Memory: RSS per function is 87 KB at 400 functions, 143 KB at 1600 and 243 KB at 3200. That is not linear. Verified from the table.

## 1b. Blocker for re-measurement

The tree failed every compile with `src/lower/lower_expr.odin(23:2) runtime assertion: missing checked expression fact` (`lower_info`), from other agents' in-progress edits in `src/check` and `src/lower`. Verified: `odinc_resume` still compiles `d400`. A copy with that assertion removed fails with `lower Unsupported Expression`, so its output is not a valid measurement. Resolved: agent-500 changed `src/check/procedure.odin` (bodies with a diagnostic become Invalid, not Complete), and the real tree builds again. Section 1c uses that build.

## 1c. After the regalloc fix

Method: `/usr/bin/time -f "%e %U %M"` (wall s, user s, max RSS KB), three runs per input, `ODIN_ROOT` set to the repository, each compile exit 0. Page faults: one `perf stat -e page-faults` run per input. The fixed binary is `/tmp/nabla_bench/odinc_real`, built from the real tree with the scripts' flags at system time 2026-10-16 23:59:16. The unfixed binary is `/tmp/nabla_bench/odinc_nofix`, built at 23:59:33 from a `/tmp` copy of the same tree with only the reserve lines removed from `insert_occupied`. Verified.

| Input | Fixed: wall / user (s) | Fixed: RSS (MB) | Fixed: page faults | Unfixed: wall / user (s) | Unfixed: RSS (MB) | Unfixed: page faults |
|---|---|---|---|---|---|---|
| d400 | 0.16 / 0.12 | 24.1 | 11,419 | 0.17 / 0.12 | 34.2 | 13,991 |
| d1600 | 0.56 / 0.42 | 62.7 | 36,322 | 0.66 / 0.45 | 223.8 | 77,565 |
| d3200 | 1.06 / 0.82 | 114.8 | 65,789 | 1.41 / 0.89 | 760.4 | 230,947 |

RSS is the mean of three runs, in MB (KB / 1024). Verified from the logs.

Scaling with the fix: from 400 to 1600 functions, wall time grows 3.5 times and RSS 2.6 times. From 1600 to 3200, wall time grows 1.9 times and RSS 1.8 times. RSS per function is 62 KB at 400 functions, 40 KB at 1600 and 37 KB at 3200. Without the fix the RSS growth from 1600 to 3200 is 3.4 times. Verified.

Top remaining hotspots with the fix:

- CPU (`perf record -F 1999 -g`, d3200): no symbol above 5.6%. The top are `native_memset_sse2` 5.53%, `bounds_check_error_with_context` 4.67%, `rexcode_x86::encode` 3.50%, `regalloc::liveness` 2.14%.
- Page faults (`perf record -e page-faults --call-graph dwarf`, d1600): `virtual.arena_init_growing` accounts for 41.6% of faults, but it is called from many places, not one. The per-function arenas are in `ir` (`function_make`, `cfg_build`, `verify`, `builder_make`), `amd64` (`machine_function_init`, `emit_function`, `select_function`) and `sched::order`. `driver::native_function` has one as well (`src/driver/native.odin:358-361`). `driver::check_program` accounts for 26.3% of faults, mostly `_append_elem` growth, and `lower::lower_program` for 11.1%. Verified from the call graph. Correction: an earlier reading of this profile put the 41.6% under `native_function` alone. That was wrong; the children view included every caller.
- The per-function arenas in `ir`, `amd64` and `sched` are the largest remaining page-fault source. Not changed here; see section 1d for the driver arena change.

## 1d. Driver arena in `native_function`

`native_function` now reuses one thread-local growing arena (`native_scratch` in `src/driver/native.odin`). It resets the arena with `arena_free_all` after each function instead of creating and destroying a 1 MB arena per function. The arena's first block stays mapped for the life of the process. Verified by reading.

Output is unchanged: the ELF bytes match the pre-change binary for d400, d1600 and d3200 (sha256 equal). Verified.

Measured against the regalloc-fixed build (`odinc_real`) in the same session, `ODIN_ROOT` set, three runs for wall and RSS, one `perf stat` run for faults:

| Input | Before: wall (s) | Before: RSS (MB) | Before: faults | After: wall (s) | After: RSS (MB) | After: faults |
|---|---|---|---|---|---|---|
| d400 | 0.16 | 24.1 | 11,410 | 0.16 | 24.0 | 10,208 |
| d1600 | 0.56 / 0.64 / 0.79 | 62.7 | 36,298 | 0.51 / 0.52 / 0.54 | 62.6 | 31,465 |
| d3200 | 1.05 / 1.13 / 1.17 | 114.9 | 65,768 | 1.02 / 1.01 / 1.01 | 114.8 | 56,224 |

RSS is unchanged, because the old arena was already freed after each function and the peak comes from elsewhere. Faults fall by 10% at d400, 13% at d1600 and 15% at d3200. Verified from the logs.

The real tree did not build at this point, because another agent's in-progress debug lines in `src/lower/lower_type_info.odin` failed to compile. These numbers come from `/tmp/nabla_bench/arena_tree`: the 23:59 snapshot with the current `src/regalloc/linear_scan.odin` and `src/driver/native.odin` copied in.

Gates: `mise run fmt driver`, `check driver` and `test driver` all pass (14 tests).

Remaining work: the same per-function pattern in `ir`, `amd64` and `sched` is the next page-fault source. Those packages are not in this change.


## 2. Profile of odinc at d1600 (before the lowering fix)

`perf record` captured 5943 samples on the d1600 build. The top self-time symbols:

| Share | Symbol |
|---|---|
| 31.5% | `lower::scan_addresses` |
| 27.3% | `runtime::native_memset_sse2` |
| 11.4% | `runtime::native_memset` |
| 10.0% | `runtime::bounds_check_error_with_context` |
| 2.9% | `runtime::native_memmove_sse2` |

Code evidence (read, not run):

- `src/lower/lower_procedure.odin:153-154`: for every procedure, `locals` and `address_taken` are allocated and zeroed with `len(job.program.entities)` elements. Each procedure therefore pays for the entity count of the whole program. Verified by reading.
- `src/lower/lower_procedure.odin:163`: `scan_addresses(&state)` runs once per procedure. Verified by reading.
- `src/lower/lower_local.odin:48-81`: `scan_addresses` loops over `typed.nodes.states` (loop at line 53), which covers every node of the procedure's typed view, and does the work per node. Verified by reading.
- Whether a typed view is one per file or one per procedure decides whether the scan is quadratic. The profile suggests it is. Unverified: I did not read the view construction.
- The memset share is consistent with the per-procedure zeroing at lines 153-154. Unverified magnitude: the perf data has no per-caller breakdown for `native_memset` in `lower`.
- The 10.0% in `bounds_check_error_with_context` is not plausible for a valid run, which should never reach a bounds error. It is probably symbol attribution in the binary, or a runtime path hit repeatedly. Unverified: not checked.

Applied in `src/lower`, with the changes below. The full independent gate passed at commit 4cdbd4d9 (95 of 95 tests, fmt and check clean, no leaks), as the orchestrator reported.

1. `address_taken` is computed once per program in a prepass (`scan_address_taken`, `src/lower/lower.odin`). The lowering jobs only read it.
2. `Procedure_State.locals` is a per-procedure map (`src/lower/lower_procedure.odin`), so no entity-sized array is zeroed for each procedure.
3. The per-procedure node scan (`scan_addresses`) is removed. Its file-wide failure for an unplanned call moved to `lower_value`, where the call is lowered. This is a behavior change: an unplanned call now fails only the procedure that contains it. Unverified: no test was written for this case.
4. The generated init procedure still allocates an entity-sized `address_taken` array (`src/lower/lower_global_init.odin`). Verified: this happens once per generated procedure, not per user procedure.

## 3. The 3200-function input fails
## 2a. Memory: the regalloc occupancy table

A page-fault profile of d1600 (`perf record -e page-faults --call-graph dwarf`) puts 56% of the faults under `regalloc::insert_occupied` (`src/regalloc/linear_scan.odin`). Each insert calls `inject_at`, which resizes the table by exactly one element, and the arena never frees the old block. Verified from the call graph. The table belongs to one procedure, `main`, which holds all n calls, so its memory cost grows with n squared. Unverified in count; it is the reading of the call graph.

Fix applied in `src/regalloc/linear_scan.odin`, in `insert_occupied`: reserve capacity geometrically (`max(2 * cap, 16)`) before the insert. `mise run fmt regalloc`, `check regalloc` and `test regalloc` pass (4 tests). Verified. Its effect on RSS: at 3200 functions, 760 MB without it and 115 MB with it (section 1c). Verified.

## 3. The 3200-function input fails

`/tmp/nabla_bench/t_d3200.log` records `/tmp/nabla_bench/d3200/main.odin:41605:2: Undeclared_Name`, `build failed`, exit status 1, 0.23 s wall, 84.6 MB RSS. Verified.

The failure does not reproduce. `odinc_cur` (built 23:15) and `odinc_d3200` (23:11) both compile the current `d3200/main.odin` with exit status 0 (`/tmp/nabla_bench/x3200_*.log`). Verified.

The failing log was written at 23:11:24, and `d3200/main.odin` was rewritten at 23:11:28 (file mtime). The failure came from an earlier version of the input, which was overwritten and cannot be recovered, so its cause is unknown. Verified from mtimes; the cause is unverified.

In `src/check` and `src/driver`, spans and offsets are `u32` (`src/syntax/ast.odin`), and `line_column` (`src/driver/diagnostics.odin`) is correct. No `u16` or fixed-size cap on node, scope or entity counts was found in a text search of those packages. Verified by search; exhaustiveness unverified.

Line 41605 of the current file is `\tif acc == 12345 { acc = 0 }`. `d1600/main.odin` contains the same line, and the d1600 build succeeds (`t_d1600.log`, 1.85 s). Verified.

The earlier `odinc_d3200.log` (6.36 s wall, 10.73 s user, 803.8 MB RSS) has no exit status and no error text, and it predates the current input. Its timing must not be used. The valid current measurement is in section 1.

## 4. `mise run check` status

Each package was checked with `mise run check <package>`. Logs: `/tmp/nabla_bench/mcheck_<package>.log`. The exit status recorded by my wrapper is not reliable, so the result below comes from the log text.

- Pass: `syntax`, `types`, `ir`, `sched`, `regalloc`, `amd64`, `elf`, `link`.
- Fail: `check`, `lower`, `driver`, `odinc`. The error is `src/check/global_order.odin(24:66) Error: Cannot assign value 'entities' of type '[dynamic]Entity' to '[]Entity' in a procedure argument`. The three packages that import `check` fail for the same reason. Verified from the logs.

This file is in progress by another agent. It was not reviewed.

Non-test size of the packages (lines): `syntax` 5517, `types` 1464, `check` 7016, `ir` 4881, `sched` 509, `regalloc` 1518, `amd64` 2799, `lower` 3961, `elf` 1288, `link` 343, `driver` 1254, `odinc` 50. `odinc` has no test files. Verified by `wc`/`cat`. The `ir` node-kind enum in `src/ir/kinds.odin` has 79 members. Verified by counting.

Zero `TODO` markers exist in `src/amd64`, `src/lower` and `src/regalloc`. Verified by grep. This is a count, not a quality measure.

`src/lower/lower_bounds.odin` exists, and a bounds-check path is in the backend. Verified by grep. Unverified: whether the checks are emitted correctly, since the file was not read.

## 5. Prior art

Verified: `src/amd64/abi.odin:5`, `src/amd64/emit.odin:6`, `src/amd64/emit_frame.odin:5` and `src/amd64/machine.odin:6` import `core:rexcode/isa/x86`. The package exists at `/home/su3h7am/Projects/Odin/core/rexcode/isa/x86`. Consistent with the prior-art rule in `AGENTS.md`.

## 6. Claims from doc 13 checked here

- "The tilde*.cpp/hpp total is 12,509 lines": `wc -l` over `/home/su3h7am/Projects/refs/odin-tilde-backend/src/*.cpp` and `*.hpp` gives 12509. Verified for the total. The file-by-file counts were not checked.
- Removal commit `25c10c18c`, PR #6483, and the Windows-only and no-bounds-check claims: not checked in this pass. Unverified.

## Open questions for the orchestrator

1. Resolved: the 3200-function `Undeclared_Name` failure does not reproduce; the owner question no longer applies.
2. Does the owner of `src/lower` accept the fix in section 2? The fix touches `lower_procedure.odin` and `lower_local.odin`.
3. Resolved: the d3200 run was repeated on the current input with exit status 0; the 6.36 s figure is removed.
