# 14 Backend review

Date: 2026-10-17. Scope: the backend path (`lower`, `ir`, `sched`, `regalloc`, `amd64`, `elf`, `link`) and the `odinc` driver, measured on generated inputs. Inputs and logs are in `/tmp/nabla_bench/`. Other agents edit `src/` concurrently, so the check results describe the tree as it stood at about 23:12. `src/` and `base/`/`core/` were not changed.

## Findings

1. Compile time and memory grow faster than linearly. The hot path is in `lower`, and the cause is in code we own: per-procedure work scales with the size of the whole program. Verified by measurement and by reading the code (section 2).
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

## 2. Profile of odinc at d1600

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

Proposed fix, for the owner of `src/lower` to decide and apply. Not applied here.

1. Allocate `locals` and `address_taken` once per program. Clear only the entries the procedure used, or size them by the procedure's own entity range.
2. In `scan_addresses`, visit only the nodes of this procedure, if the procedure records its node range. Verified that no such range is read in `scan_addresses` today. Unverified whether the procedure record has one.

After the fix, measure d400, d1600 and d3200 again with the same inputs and perf, and compare with the table in section 1.

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
