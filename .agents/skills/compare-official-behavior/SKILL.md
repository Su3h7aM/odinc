---
name: compare-official-behavior
description: Check that a compiled program behaves the same under our odinc and the official compiler, for a language feature, intrinsic, lowering change or library initializer. Also measure size and speed against official -o:none. Use when a claim of "matches official" needs evidence, or when a change touches lowering that a library package's behavior depends on.
---

# Compare behavior with the official compiler

## References

- Official compiler: the mise binary `/home/su3h7am/.local/share/mise/installs/odin/dev-2026-10/bin/odin`, with `ODIN_ROOT=/home/su3h7am/.local/share/mise/installs/odin/dev-2026-10`.
- Upstream source (for reading, not for building): `/home/su3h7am/Projects/refs/compilers_linkers/Odin-upstream`.
- The fork `/home/su3h7am/Projects/Odin` is not a reference and not an official side. It is only the bootstrap builder of our compiler (see `odin-private-validation`). Never use it as a fallback for behaviour: if the official binary cannot parse an input, record that and report it.
- Probe programs first with the official binary (`odin-probe-upstream`), then run them under ours.

## Rules

- Any program the official compiler accepts must compile with ours. If ours rejects it, that is a finding: record the exact error line.
- Size and speed baselines use official `-o:none`, built from the mise binary, on trees it can compile (for example `src-notest`, the source without `_test.odin` files).
- Record every result as a fact (both outputs), not as a verdict. Diffs must be empty or explained.

## Steps

1. Write `/tmp/<name>/probe/main.odin` as a `package probe` with a `main` that prints what you compare. Print only in the probe, never in tests.
2. Build with both compilers:
   - ours: `cd /tmp/<name> && ODIN_ROOT=<repo> ./odinc build probe -o /tmp/<name>/probe_ours` (the private odinc from `odin-private-validation`)
   - official: `cd /tmp/<name> && ODIN_ROOT=/home/su3h7am/.local/share/mise/installs/odin/dev-2026-10 /home/su3h7am/.local/share/mise/installs/odin/dev-2026-10/bin/odin build probe -o:none -out:/tmp/<name>/probe_official`
3. Run each binary under each environment you care about, for example `env TERM=xterm-256color` and `env TERM=xterm-256color NO_COLOR=1`, and diff the stdout. Include the exit code.
4. For size and speed, measure with the LLVM tools only (`llvm-size`, `llvm-readelf -S`, `llvm-nm --print-size`, `perf`), and name each binary's build line.
5. Done when every (environment, binary) pair is recorded and the diff is empty or explained.

## Pitfalls

- Library packages (under `base/`, `core/`, `vendor/` of ODIN_ROOT) only get lowered when reached, so the probe must import the package whose behavior you check. A probe that does not import it proves nothing.
- Pick an observable effect: an `@(init)` that sets a package variable the probe prints (`core:terminal` `color_enabled` and `color_depth` work), not a side effect that needs a debugger.
- The official build uses `-out:`, ours uses `-o`. Mixing them fails with "Unable to find any short flag".
- A probe that fails to build on the official side is a finding; record its exact error line.
- Compare symbol counts by normalized name. Official names look like `pkg::[file.odin]::name` and `name:proc(...)`; ours look like `pkg.name`.

## Cleanup

`rm -rf /tmp/<name>` after reporting.
