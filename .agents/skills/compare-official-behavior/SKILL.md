---
name: compare-official-behavior
description: Check that a compiled program behaves the same under our odinc and the official compiler, for a language feature, intrinsic, lowering change or library initializer. Use when a claim of "matches official" needs evidence, or when a change touches lowering that a library package's behavior depends on.
---

# Compare behavior with the official compiler

Record the result as a fact (both outputs), not as a verdict. Keep the probe in `/tmp/<name>/probe/` and delete it when done.

## Steps

1. Write `/tmp/<name>/probe/main.odin` as a `package probe` with a `main` that prints what you compare. Print only in the probe, never in tests.
2. Build with both compilers (set `ODIN_ROOT` for both):
   - ours: `cd /tmp/<name> && ODIN_ROOT=<repo> ./odinc build probe -o /tmp/<name>/probe_ours` (the private odinc from `odin-private-validation`)
   - official: `cd /tmp/<name> && ODIN_ROOT=<repo> /home/su3h7am/Projects/Odin/odin build probe -out:/tmp/<name>/probe_official`
3. Run each binary under each environment you care about, for example `env TERM=xterm-256color` and `env TERM=xterm-256color NO_COLOR=1`, and diff the stdout. Include the exit code.
4. Done when every (environment, binary) pair is recorded and the diff is empty or explained.

## Pitfalls

- Library packages (under `base/`, `core/`, `vendor/` of ODIN_ROOT) only get lowered when reached, so the probe must import the package whose behavior you check. A probe that does not import it proves nothing.
- Pick an observable effect: an `@(init)` that sets a package variable the probe prints (`core:terminal` `color_enabled` and `color_depth` work), not a side effect that needs a debugger.
- The official build uses `-out:`, ours uses `-o`. Mixing them fails with "Unable to find any short flag".
- A probe that fails to build on the official side is a finding; record its exact error line.

## Cleanup

`rm -rf /tmp/<name>` after reporting.
