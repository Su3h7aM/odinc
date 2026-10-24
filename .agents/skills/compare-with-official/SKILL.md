---
name: compare-with-official
description: Benchmark our odinc against the official Odin compiler with optimizations disabled on both sides (official -o:none vs our default build). Use when a claim about binary size, compile time, compile memory, or generated-code speed needs numbers, or when triaging a size/speed regression.
---

# Compare against official (-o:none vs our default)

Both sides run with no optimizer: official `-o:none`, ours default (odinc has no optimizer; never pass `--opt`, never use official `-o:speed/size` here). Record flags with every number.

## Compilers and roots

- Official: `~/.local/share/mise/installs/odin/dev-2026-10/bin/odin` with `ODIN_ROOT` set to that `bin/` dir (the mise install keeps `base/`, `core/`, `shared/`, `vendor/` beside `bin/`; `odin root` prints the `bin` dir, so export `ODIN_ROOT` explicitly). Verify with `odin version` (want the mise nightly, not the fork).
- Ours: private build at `/tmp/perf-inv/odinc` (official-built from current src) with `ODIN_ROOT=/home/su3h7am/Projects/odin-compiler`. Never `mise run build` (rewrites shared `build/odinc`). Build it with: `ODIN_ROOT=<repo> ~/Projects/Odin/odin build src/odinc --collection=oc=<repo>/src -out:/tmp/perf-inv/odinc`.
- Fish shell: no `VAR=value cmd` prefixes, no heredocs; use `set -x VAR value` lines and `printf` instead of heredocs.

## Workload layout

- Tiny programs live in `/tmp/compare/w/p_<name>/` (one dir per program, one `.odin` file each; both compilers take a directory). Keep this set: `hello` (fmt), `osprog` (os/strings/strconv, no `os.exit` at end), `thread` (4 threads x atomic add), `loops` (xorshift + accumulate), `memory` (4 MB mem.copy loop), `hashsort` (1M u32 sort + FNV), plus `bounds`/`map` when testing checks/containers. Verify both binaries print identical output before timing.
- Big input: a copy of `src/` with `*_test.odin` deleted (official mise release rejects our newer test-file syntax, so full `src/` cannot build there; both sides must compile the same tree). Compare `llvm-nm` marker probes when in doubt about file inclusion.
- When building our `src` with the official compiler, use a private copy of its installed `ODIN_ROOT` with `core/math/big` and `core/rexcode` replaced by the repo's versions: installed `int_destroy` frees temp-allocated limbs through `context.allocator`, and installed rexcode omits the operand-size prefix on 16-bit memory/immediate stores, breaking self-hosting.
- `_test.odin` files ARE compiled into `build` output by both compilers (verified: a `main` calling a proc defined in `zz_test.odin` links under both). Size comparisons on a directory therefore include test code on both sides.

## Commands

- Build official: `odin build p_<name> -o:none -out:<name>.official`; build ours: `odinc build /tmp/compare/w/p_<name> --output <name>.odinc`.
- Time with `/usr/bin/time -f "%e wall %U user %S sys %M KB"`, 3-5 runs, report median and spread. Separate `check` from `build` (ours: `odinc check <dir> -c oc=<repo>/src`); backend cost is approximately build minus check.
- Time with the shell's `time` keyword (fish builtin, not GNU time), 3-5 runs, report median and spread: `time <compiler> <args>` gives wall/user/sys; read peak RSS from `/usr/bin/time -v` only if needed — otherwise use `perf stat -e task-clock,minor-faults,max-rss`. Separate `check` from `build` (ours: `odinc check <dir> -c oc=<repo>/src`); backend cost is approximately build minus check.
- Time with the shell's `time` keyword (fish builtin, not GNU time), 3-5 runs, report median and spread. Separate `check` from `build` (ours: `odinc check <dir> -c oc=<repo>/src`); backend cost is approximately build minus check.
- Time with `/usr/bin/time -f "%e wall %U user %S sys %M KB"` (userland tool, not banned toolchain), 3-5 runs, report median and spread. Separate `check` from `build` (ours: `odinc check <dir> -c oc=<repo>/src`); backend cost is approximately build minus check.
- Size: `llvm-size -A`, `llvm-readelf -S -W`, `llvm-nm --size-sort -S --defined-only`. Compare per-section `.text/.rodata/.data/.eh_frame`, then per-procedure sizes for identically-named procedures (normalize `::` to `.`, strip `[file.odin]` tags), then ours-only/official-only symbol sets grouped by package prefix.
- Profiles: `perf record -e cycles:u -- <compiler> <args>` then `perf report --stdio --sort symbol`; call-graph sampling is blocked (paranoid=2), so attribute hot callees with `lldb --batch -s cmds.txt` breakpoint backtraces instead. Aggregate perf symbols by package prefix (`s/::.*//`) for a phase split proxy.
- Generated-code speed: run each binary 5x under `/usr/bin/time -f "%e/%U/%M"`, same machine, note variance (hashsort varies run to run).
- Generated-code speed: run each binary 5x under the shell's `time` keyword, same machine, note variance (hashsort varies run to run).
- Generated-code speed: run each binary 5x under `/usr/bin/time -f "%e/%U/%M"`, same machine, note variance (hashsort varies run to run).

## Pitfalls

- Our odinc flags: `--output` or `-o` for the path, `--collection oc=...` (`-collection:` is rejected), `--opt speed` is never used here. Official flags: `-out:`, `-collection:`, `-o:none`. Fish does not accept `time (...)`; use `/usr/bin/time` or `date +%s.%N`.
- `ODIN_ROOT` leaks between commands: set it explicitly on every block; the fork tree under `~/Projects/Odin` fails the mise binary on newer attributes and vice versa.
- Tiny builds are startup-dominated (ours ~1.2 s, official ~0.3 s); only `src`-scale builds separate check cost from backend cost.
- Official binaries are dynamically linked PIE (`.rela.dyn`, `.plt`), ours are static: file totals are not comparable, section deltas are.
- Our function symbols outnumber official's ~3:1 at similar code size; raw-name set differences are mostly naming-scheme noise (`check.foo` vs `check::[file]::foo`). Use normalized names and always cross-check against section totals.
