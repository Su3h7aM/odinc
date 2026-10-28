# Compile time of `hello_fmt`

Status: measured. No `src/` change is part of this report. The phase timers were a temporary patch on a copy of the tree and were not committed.

## Method

- Fixtures: `bench/hello_fmt/main.odin` (one `fmt.println`) and `bench/empty/main.odin` (`main :: proc() {}`). Same content as the T1 fixtures.
- Clean build: `build/odinc` built from the committed tree (`74f693a`, parent `050b5bf`).
  - Wall time: `hyperfine -N --warmup 1 --runs 5` on `odinc build <fixture> --output <path>`.
  - Peak resident memory: `memory_peak_resident` from the same hyperfine export.
- Phase breakdown: a temporary build of the same tree with timers around the driver stages, the lowering steps, the backend steps and the instance and big-integer counters. Enabled with `ODINC_PHASE_TIMING=1`. The timed build also installs a tracking allocator, so its totals run about 5% above the clean build.
- Breakdown numbers are the mean of three timed runs per fixture. Wall-time numbers are from five clean runs.
- Attribution rule: the sum of named phases must cover at least 80% of total time. Result: 97.9% for `empty` and 97.7% for `hello_fmt`.

## Numbers

Clean build, `hello_fmt`: median 1089.9 ms (min 1069.0, max 1109.9), output 508872 bytes, peak resident 135.7 MB. The output is static: no `INTERP` and no `NEEDED`, and it prints `hello`.

Timed build, mean of three runs (ms):

| Phase | `empty` | `hello_fmt` | Delta | Share of delta |
| --- | ---: | ---: | ---: | ---: |
| parse | 45.2 | 202.3 | 157.1 | 18.3% |
| load and bind (excluding parse) | 18.7 | 77.1 | 58.4 | 6.8% |
| check resolve | 106.1 | 493.3 | 387.2 | 45.2% |
| check tail | 16.2 | 41.3 | 25.1 | 2.9% |
| analysis | 31.3 | 99.3 | 68.0 | 7.9% |
| lower declare | 0.5 | 16.9 | 16.5 | 1.9% |
| lower prepare | 8.6 | 40.8 | 32.2 | 3.8% |
| lower reachable | 17.4 | 50.7 | 33.3 | 3.9% |
| lower tail | 0.9 | 2.4 | 1.5 | 0.2% |
| symbols and layout | 0.3 | 0.9 | 0.6 | 0.1% |
| functions (select, regalloc, emit) | 34.2 | 87.1 | 52.9 | 6.2% |
| link | 1.7 | 5.2 | 3.4 | 0.4% |
| **Total** | **287.1** | **1143.5** | **856.4** | |

Unattributed delta: 20.2 ms (2.4%).

Overlapping measurements, not additive with the table:

- Generic instance creation, outermost calls only: 8.0 ms (`empty`), 35.9 ms (`hello_fmt`). Instances created: 40 and 182.
- Big-integer constant interning: 3.9 ms (`empty`), 51.5 ms (`hello_fmt`). Interned values: 4,849 and 50,718.

Input and allocation volume (single run, `hello_fmt` against `empty`):

- Parsed files: 193 against 52. Parsed bytes: 2.54 MB against 0.59 MB. Parse time per parsed megabyte, for the added input: about 80 ms/MB.
- Allocations: 59,896 against 12,733. Bytes allocated: 146.5 MB against 29.8 MB. Peak live bytes: 91.9 MB against 17.5 MB.

## Hypotheses

1. **Checking all of `core:fmt` costs most of the time.** Partly confirmed. Check resolve is the largest single phase, at 45% of the time added by `fmt`. The whole front end (parse, load, check, analysis) is 81%, so it is not the check alone. Not measured: the share of check time per `core:fmt` package. That needs per-package counters, which this run did not have.
2. **Generic instantiation and polymorphic call chains dominate.** Refuted. Outermost instance creation is 35.9 ms, or 3.1% of the total. Its share of the delta is 3.3%.
3. **Checker table growth and allocation dominate.** Not confirmed. Allocation volume is large: 116.7 MB and 47,163 allocations added by `fmt`, with the peak rising by 74 MB. Parse (about 41 MB added) and check resolve (about 59 MB added) carry most of the bytes. Table growth and allocator time were not isolated, so time cannot be attributed to them.
4. **Two full AST walks (check and lower) plus the analysis pass dominate.** Partly confirmed. Check resolve, analysis and lowering together are 63% of the delta. Lowering alone is 9.8%, so the second walk is not the dominant cost. The first walk, in check, is.
5. **`big.Int` constants dominate.** Refuted. Interning took 51.5 ms, or 4.5% of the total. Its share of the delta is 5.6%, and the call count is about 10 times the `empty` count. The timer's own cost, two clock reads per call, is inside these figures.

## Ranked causes for the time `fmt` adds

1. Check resolve: 387 ms (45%).
2. Parse: 157 ms (18%). Source volume grows from 0.59 MB to 2.54 MB.
3. Analysis: 68 ms (8%).
4. Load and bind, excluding parse: 58 ms (7%).
5. Lowering: 84 ms (10%).
6. Functions (select, regalloc, emit): 53 ms (6%).
7. Check tail: 25 ms (3%).

Items 1 and 2 cover 63% of the delta, and most of the check time is outside the constant and instance paths.

## Recommendation

- No optimization yet. The next measurement is per-package and per-declaration counters inside check resolve, to see whether the `core:fmt` declarations and bodies that are checked are the ones the program uses.
- Parse is the largest cost that does not depend on the checker. Measure how many of the 141 extra files for `fmt` are needed by the program before changing how packages are loaded.
- Analysis at 68 ms is worth its own measurement next. The output of analysis is not inspected here.

## Limits

- Single host. Clean runs: 5. Timed runs: 3 per fixture.
- Timers and the tracking allocator add about 5% to the timed run.
- Nested timers are excluded by construction: load includes parse, so parse is subtracted from load.
- Peak resident memory of `odinc2` (about 696 MB, reported by the T1 baseline) was not measured in this report. It belongs to the next cycle.
