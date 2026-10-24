---
name: odin-private-validation
description: Build the private bootstrap compiler, run the private self-check, the acceptance build of src/odinc and the selfhost compare, and run the mise validation sequence. Use before reporting a checker or lowering change as done.
---

# Private build, self-check, acceptance, selfhost, validation

Never run `mise run build`, `selfhost`, `build-nabla` or `test-upstream`. Use the private binary below.

The fork `/home/su3h7am/Projects/Odin` is used here only as the bootstrap builder (step 1). It is not a behavioural reference. Behaviour is checked with the official compiler (`odin-probe-upstream`). Step 4 builds the self-hosted binary `/tmp/fx/build/odinc2`, which is what probes should use from then on (`/tmp/fx/odinc-self`, a copy).

## 1. Bootstrap the private compiler

```
env ODIN_ROOT=$PWD /home/su3h7am/Projects/Odin/odin build src/odinc -out:/tmp/fx/odinc-alias -o:none --collection:oc=$PWD/src
```

Check `$status` is 0. If it fails inside `src/driver` or `src/lower` while another agent is editing, wait and retry; do not edit their files.

## 2. Self-check (count errors)

```
env ODIN_ROOT=$PWD /tmp/fx/odinc-alias check src/odinc --collection oc=src --no-entry-point --max-error-count 100000 > /tmp/fx/self.txt 2>&1
grep -c "Error:" /tmp/fx/self.txt
```

Report the count. Look at `grep "Error:" | head`.

## 3. Acceptance build (the user's command, private binary and output)

```
mkdir -p /tmp/fx/build
env ODIN_ROOT=$PWD /tmp/fx/odinc-alias build src/odinc --output /tmp/fx/build/odinc2 -c oc=$PWD/src --mcpu x86_64_v3
```

A `Bounds check failed` at runtime means a lowering bug, not a tolerated input: follow `odin-lower-crash-triage`.

## 4. Selfhost compare

```
env ODIN_ROOT=$PWD /tmp/fx/build/odinc2 build src/odinc --output /tmp/fx/build/odinc3 -c oc=$PWD/src --mcpu x86_64_v3
cmp /tmp/fx/build/odinc2 /tmp/fx/build/odinc3 && echo IDENTICAL
```

## 5. Repo validation (once, at the end of a batch)

```
mise run fmt --check
mise run check
mise run test
```

For a touched package also `mise run fmt <pkg>`, `mise run check <pkg>`, `mise run test <pkg>`. Read `grep -n "ERROR\|FAIL"` on the test output; the summary line is `Finished N tests`.

## Pitfalls

- `check` of `src/odinc` prints `Unsupported ...` errors from other agents' in-progress tests (for example `lower_*_test.odin`). Count them and name the file; do not hide them.
- A private build that keeps old code is stale: rebuild after every edit before measuring.
- Use `--thread-count 1` to make lowering serial (deterministic crash location).
- Keep `/tmp/fx` until the orchestrator says to delete it.
