# Benchmarks

Live compile-time numbers for this cycle. The 2026-10-20 snapshot in `docs/02-improvement-plan.md` section 2 stays as historical context.

## Machine

- Date: 2026-10-28
- Host: AMD Ryzen 5 1600 Six-Core Processor, 8 threads, 16296580 kB RAM
- OS: Ubuntu 24.04.5 LTS, Linux 7.0.14-25-pve, x86_64
- Checkout (cycle reference, post-T0): `74f693a4d1c4f87a3d5f56964ffe1ee13f0c431d` (`050b5bf` + `74f693a`)
- Checkout (pre-T0 table only): `7365441ed50eb36a7202616f32424dff7dcdbae9`

The 2026-10-20 snapshot was measured on a Ryzen 7 5700X. This host is slower; do not treat the two tables as a like-for-like delta.

## Compiler

- Bootstrap: `/tmp/odinc-odin-fork` → `odin version dev-2026-10:ea225db25`
- `ODIN_BIN` set in `.mise.local.toml` (excluded from git via `.git/info/exclude`)
- `build/odinc` built by `scripts/build` (bootstrap `odin build` of `src/odinc`, no `-o:speed`)

## Command

```
mise run bench
```

`scripts/bench` builds `build/odinc` once, then compiles each real fixture with the real compiler (`--collection=oc=src`). Observation (linkage, INTERP, NEEDED, exit, verdict) lives in `scripts/bench_observe`; RSS in `scripts/bench_rss.odin`. Raw rows: `build/bench/results.tsv` and `build/bench/<fixture>.elf.txt`.

Base/core fixtures (`empty`, `hello_fmt`, `count_loop`, `sieve`) must be static and must run (exit 0). A dynamic image is `verdict=fail`, not a normal result. The post-T0 `verdict=ok` rows are the cycle reference.

This host has no `file(1)`. Linkage is taken from `llvm-readelf` (`/data/.local/bin/llvm-readelf`). GNU `readelf` / `nm` are not used.

## Method

- Wall time: `hyperfine` 2.0.0, median / min / max of N runs, one warmup, `--shell=bash`.
- Peak RSS: the same hyperfine runs, `memory_peak_resident` (bytes) divided by 1024 and reported as kilobytes. Fallback if hyperfine is missing: `wait4` `RUsage.maxrss_word` via `scripts/bench_rss.odin`.
- Binary size: `stat -c '%s'` of the `odinc`-produced image from one successful compile before the timed runs.
- INTERP / NEEDED / UND: `llvm-readelf --program-headers`, `--dynamic`, `--dyn-syms`.
- Verdict: `fail` if a base/core fixture is dynamic or does not run; `managed` if another fixture is dynamic; `ok` only when the image is static GNU-free.

## Table (pre-T0, managed profile)

Recorded 2026-10-28 with `mise run bench` on this host, **before T0**. Every image is dynamically linked: `PT_INTERP` yes and `DT_NEEDED libc.so.6`. `demo` and `odinc2` also need `libm.so.6`. These numbers measure the managed/libc profile, the bug T0 fixes.

Do not use this table as the T3 / T4 / T5 reference. The no-crt baseline is the table below; the before/after on this machine is the number that matters.

`odinc2` selfhost 9.4 s wall / 695 MB peak RSS was the managed-profile memory number. Remeasured after T0 in the no-crt table.

Wall times in milliseconds. INTERP from `llvm-readelf --program-headers`. NEEDED from `llvm-readelf --dynamic`.

| Fixture | Wall med (ms) | Wall min (ms) | Wall max (ms) | Peak RSS med (kB) | Size (bytes) | N | INTERP | NEEDED | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|---|---|
| `bench/empty` | 305.9 | 292.9 | 340.2 | 30118 | 125768 | 20 | yes | libc.so.6 | **fail** (base/core, dynamic) |
| `bench/hello_fmt` | 1335.9 | 1304.8 | 1406.4 | 134022 | 496168 | 20 | yes | libc.so.6 | **fail** (base/core, dynamic) |
| `examples/demo` | 1958.2 | 1876.7 | 2747.9 | 174398 | 995160 | 20 | yes | libc.so.6,libm.so.6 | managed (dynamic) |
| `src/odinc` (`odinc2`) | 9407.6 | 8807.3 | 14849.1 | 695292 | 6969256 | 20 | yes | libc.so.6,libm.so.6 | managed (dynamic) |
| `bench/count_loop` | 320.5 | 297.5 | 526.4 | 30174 | 125800 | 20 | yes | libc.so.6 | **fail** (base/core, dynamic) |
| `bench/sieve` | 302.7 | 300.5 | 314.0 | 30280 | 130744 | 5 | yes | libc.so.6 | **fail** (base/core, dynamic) |

`empty`, `hello_fmt`, `demo`, `odinc2` and `count_loop` went to 20 runs because `(max - min) / median` stayed above 5%. `sieve` stayed at 5.

## Table (no-crt, post-T0)

Recorded 2026-10-28 with `mise run bench` on this host, **after T0** (`050b5bf` + `74f693a`). Every image is statically linked: `PT_INTERP` no, `DT_NEEDED` none, `UND` none, `verdict=ok`. This is the cycle reference. Do not use the pre-T0 table for T3 / T4 / T5.

`hello_fmt` 1072.3 ms median is the number for T2.

`odinc2` selfhost 7864.4 ms wall / 696556 kB peak RSS is the memory number of this cycle. `mise run selfhost` produced `build/odinc2` and `build/odinc3`, both static (`INTERP=no`, no `NEEDED`).

Wall times in milliseconds. INTERP from `llvm-readelf --program-headers`. NEEDED from `llvm-readelf --dynamic`.

| Fixture | Wall med (ms) | Wall min (ms) | Wall max (ms) | Peak RSS med (kB) | Size (bytes) | N | INTERP | NEEDED | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|---|---|
| `bench/empty` | 263.4 | 252.6 | 317.3 | 29018 | 146472 | 20 | no | - | ok |
| `bench/hello_fmt` | 1072.3 | 1060.2 | 1088.0 | 132508 | 508872 | 5 | no | - | ok |
| `examples/demo` | 1553.4 | 1534.8 | 1569.1 | 175432 | 1022384 | 5 | no | - | ok |
| `src/odinc` (`odinc2`) | 7864.4 | 7743.9 | 7919.1 | 696556 | 7005120 | 5 | no | - | ok |
| `bench/count_loop` | 264.1 | 258.9 | 266.6 | 28896 | 146504 | 5 | no | - | ok |
| `bench/sieve` | 263.1 | 255.5 | 277.7 | 29188 | 147576 | 20 | no | - | ok |

`empty` and `sieve` went to 20 runs because `(max - min) / median` stayed above 5%. The others stayed at 5.

## hello_fmt vs 717 ms

`docs/02-improvement-plan.md` section 2 records 717 ms for `hello_fmt` on a Ryzen 7 5700X (2026-10-20). This host's pre-T0 run is 1335.9 ms median (about 1.86 times that snapshot). The empty fixture here is 305.9 ms against the snapshot's about 120 ms (about 2.55 times). Both ratios point at the slower machine, not a harness that measured a different program. The 20-run min for `hello_fmt` is still 1304.8 ms, so the gap is not a single outlier.

Those 5700X numbers are also managed-profile. Compare no-crt numbers to the post-T0 table on this machine, not to 717 ms. T2 uses this host's post-T0 `hello_fmt` 1072.3 ms.
