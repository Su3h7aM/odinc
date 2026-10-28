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

## T2b: per-package and per-declaration breakdown inside check

Method: exclusive time and allocation counts per package and per declaration, for each declaration resolved by the driver and each procedure body checked. Frames are nested, so a frame's time excludes its children. Big-integer interning time and calls are attributed to the innermost frame. Same instrumentation approach as T2, applied to the same checker code. The instrumented copy is outside the repository.

Coverage: the frames of `hello_fmt` account for 461 ms of the 387 ms that `check resolve` adds over `empty`, after the fixed cost of `base/runtime` (106 ms, present in both programs) is removed. The 25 ms difference is measurement scope: frames do not cover the phase work outside declaration resolution and body checks.

Package deltas (`hello_fmt` minus `empty`), exclusive:

| Package | Time (ms) | Share of fmt-added frame time | Allocations | Allocated (MB) | Big-int interning (ms, calls) |
| --- | ---: | ---: | ---: | ---: | --- |
| core/unicode | 96.9 | 26.8% | 537 | 14.1 | 31.9 ms, 28,332 calls |
| core/sys/linux | 55.6 | 15.4% | 3,545 | 1.7 | 3.2 ms, 4,404 calls |
| core/math | 50.3 | 13.9% | 1,914 | 2.2 | 1.0 ms, 1,511 calls |
| core/os | 33.8 | 9.3% | 1,522 | 21.8 | 1.0 ms, 1,111 calls |
| core/fmt | 28.8 | 8.0% | 1,071 | 2.7 | 1.2 ms, 1,786 calls |
| core/strconv | 19.7 | 5.4% | 270 | 2.5 | 4.8 ms, 3,545 calls |
| core/strings | 12.4 | 3.4% | 612 | 0.5 | |
| core/reflect | 10.1 | 2.8% | 584 | 1.2 | |
| core/sync | 7.5 | 2.1% | 498 | 0.3 | |
| core/io | 7.2 | 2.0% | 152 | 6.4 | 0.4 ms, 287 calls |

The ten largest packages account for 89% of the fmt-added frame time (sum of deltas: 362 ms). Frame-attributed allocations add 12,759 allocations and 55.3 MB; the remaining 34,404 allocations and 61.4 MB of the T2 totals come from parse, load, analysis and lowering, outside the frames.

Largest declarations (exclusive, delta over `empty`):

1. `core:strconv._POWER_OF_FIVE_128`: 11.8 ms, 2.4 MB allocated. A constant table.
2. `core:unicode.to_upper`: 11.4 ms.
3. `core:unicode.to_lower`: 8.6 ms.
4. `core:unicode.is_hangul_syllable_lvt`: 8.2 ms.
5. `core:unicode.is_emoji_extended_pictographic`: 7.5 ms.
6. `core:unicode.is_upper`: 6.7 ms.
7. `core:os.make_directory_temp`: 5.7 ms, 12.6 MB allocated.
8. `core:unicode.is_lower`: 5.5 ms.
9. `core:unicode.is_grapheme_extend`: 4.3 ms.
10. `core:unicode.is_control`: 4.3 ms.

Most of the top declarations are in `core:unicode`. They are predicates and range tables, and the table constants account for part of their cost.

Hypothesis updates:

- H1 (checking `core:fmt` costs most of the time). The measured cost is spread across packages, and `core:unicode` is the largest single one, at 27%. `core:fmt` itself is 8%. No single package accounts for the majority, so the claim is not confirmed as stated.
- H5 (`big.Int` constants dominate). Overall still refuted: interning is 46.4 ms, about 5% of the fmt delta. It is concentrated: 32 ms and 28,332 of the 45,310 calls are in `core:unicode`, so the constant tables of `core:unicode` are the place to look, but they are not the whole cost of that package.
- `base/runtime` costs 106 ms in every program, including `empty`. That is 37% of the `empty` build and is not caused by `fmt`.

Open for T2d: confirm whether the unicode predicates are checked because `core:fmt` reaches them, or because the checker resolves their whole package. Track whether the `base/runtime` fixed cost is avoidable, since it is paid by every program.

## T2b follow-up: what the fixed and unused costs are

Method: the instrumented copy with switches that skip, in the declaration loop of `check_session`, library constants, library `@(rodata)` variables, and procedure-group declarations. Three runs per mode. Measurement only; the switches are not in the repository.

Findings:

- `import "core:unicode"` with no use still costs about 140 ms over `empty`. The checker resolves every package-level constant and `@(rodata)` table of an imported library package, and evaluates their big-integer values. The unused import runs 105 ms of unicode checking, the same as the used `is_upper` case.
- Library procedure bodies are lazy (checked only when named), except those whose body text contains `#assert` or `#panic`. Ignoring that rule changes nothing in `base/runtime`, so it is not the cause of its fixed cost.
- `base/runtime` costs about 110 ms in every program. Most of that is procedure-group declarations (`make`, `append`, and similar), which are not lazy in the declaration loop, and the bodies they reach. Making groups lazy alone removes about 35 ms of the 110 ms.
- The residual 80 ms in `base/runtime` is bodies reached by reference from runtime roots (the runtime helper set and `__init_context`) and from their callees, mostly math, memory copy and set, and decoding. Not isolated per root.

Results (mean of two runs, milliseconds, timed build):

| Mode | `empty` | `hello_fmt` | `unused_unicode` | `base/runtime` in `empty` |
| --- | ---: | ---: | ---: | ---: |
| none | 278.3 | 1149.5 | 435.8 | 109.0 |
| constants, `@(rodata)` variables, procedure groups skipped | 245.9 | 878.9 | 323.6 | 79.6 |

The `hello_fmt` output is unchanged (`hello`, exit 0). Skipping these declarations would also skip their diagnostics in unreferenced library code. That is a semantic choice that needs a decision before implementation: the library-body rule already accepts that trade-off for procedure bodies.
