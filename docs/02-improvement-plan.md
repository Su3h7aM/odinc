# Improvement plan

Written 2026-10-22 by the orchestrator. It consolidates the research in `docs/research/01` to `06`, a reading of Ginger Bill's Tilde lowering, the closed PR #7850, and a direct check of our sources. Read it after `AGENTS.md` and `docs/01-architecture.md`, before starting work on the compiler. The research reports hold the detail and are linked where they matter. Where this document and a report disagree, this document wins, because every code claim here was checked against the tree on the date above.

The compiler works. It builds Nabla, it builds itself (`mise run selfhost`), and the binaries run. The next stage is to keep it correct, make it simpler to read and change, and then make its output faster without giving up compile speed or memory.

## 1. Principles

Every task is judged against these. A change that breaks one needs an owner decision first.

1. Same language, same behavior. A program compiled by `odinc` behaves exactly as under the official compiler: accepted and rejected programs, diagnostics, computed values, stdout, stderr and exit code. Upstream defines behavior, never structure (`docs/01-architecture.md`).
2. No undefined behavior as an optimization license. Odin integers wrap. Bill's note at the top of `src/llvm_backend_opt.cpp` in `Odin-upstream` lists the LLVM passes Odin refuses because "Odin does not allow poison-value based optimizations". Unsafe float behavior is opt-in through `@(fast_math=...)`, never a default.
3. Nothing hidden. `#force_inline` and `#force_no_inline` are requirements, not hints (issue #764). Build policy (`-no-bounds-check`, `#no_bounds_check`, `-disable-assert`) belongs to the program; the optimizer never adds or removes a check on its own authority.
4. Simple means easy to understand, maintain and change. It does not mean fewer lines. A procedure with several responsibilities becomes several procedures, each with one job and a name that says it, even when the total grows. The same holds for files and packages.
5. Self-describing code. Names say what a thing is or does. A reader understands a procedure from its name, its parameters and its body. Comments stay rare (`AGENTS.md`).
6. Data-oriented. Nodes and AST nodes are `distinct u32` handles into flat arrays, `#soa` where fields are read separately, arenas per lifetime, no pointer graphs. Measure memory and time before and after a change that claims to help either.
7. Sea of Nodes is the IR. Use its properties instead of working around them: hash-consing makes equal pure values the same node, the memory chain makes equal memory states the same node, and the scheduler places floating nodes. An optimization that needs a CFG walk over statement lists is a sign it is in the wrong place.
8. Maintainability is the bar. On 2026-10-09 Bill closed PR #7850, a 140-commit non-LLVM fast backend, with one line: "No. This is not maintainable." (https://github.com/odin-lang/Odin/pull/7850). This was not a rejection of a native backend. Bill's stated goal is a fast native backend of his own (`docs/research/01`, 2026-03 and 2026-10 statements). The PR would have put a second backend beside LLVM in the official compiler, with fallback between the two, and keeping both was not worth the cost to his project at this time. Our compiler has one backend and no LLVM, so that cost does not apply to us, but the lesson about code that is expensive to read and change does.
9. Threads stay as they are, and new work leaves room for more. Lowering and code generation already run on a thread pool (`src/lower/reachability.odin`, `Emit_Task` in `src/driver/native.odin`, `--thread-count`); that is kept exactly. Nothing new is made parallel yet. The goal is to parallelize as many stages as reasonably possible later, so every change today keeps per-unit work (a file, a procedure, a function) independent, passes state and allocators explicitly, returns results instead of writing shared state, and adds no package globals or hidden mutable state.
10. A difference from the official compiler is investigated, not copied. Every refactor that finds one decides by evidence (`AGENTS.md`, "Resolving inconsistencies") whether it is our bug, a missing feature, or an upstream bug, then fixes ours or implements the feature. What must match is observable behavior: accepted programs, diagnostics, results, output and exit status. How we reach it is ours to design in Sea of Nodes terms; upstream's LLVM code explains why a behavior exists, never how we build it. A suspected upstream bug goes to the owner before we diverge.

## 2. Where we are

Source: `docs/benchmarks.md`, snapshot 2026-10-20, machine Ryzen 7 5700X. Compiler B is the fork, C is `odinc`. Live numbers after that date are in that file; the table below is the 2026-10-20 snapshot.

| Measure | odinc | Official (fork) |
|---|---|---|
| Compile, small programs | about 120 ms | 120 to 135 ms default, about 360 ms `-o:speed` |
| Compile, `hello_fmt` (imports `core:fmt`) | 717 ms | 214 ms default |
| Compile peak memory | 19 to 87 MB | 250 to 400 MB |
| Run time, compute loops | 3 to 8 times slower than `-o:speed` | |
| Run time against official default build | faster on `loops`, close on `sieve`, slower on `fib` | |

Two conclusions. Memory is already an order of magnitude below the official compiler, so any change must keep it there. Compile time is fine for tiny programs and three times worse once `core:fmt` is in; the cause is not known (section 9).

Verified state of the pipeline (checked 2026-10-22):

- Node storage is data-oriented: `ir.Function.nodes` is `#soa[dynamic]Node`, inputs live in one shared `edges` array, `Node_Data` is an 8-byte raw union (`src/ir/graph.odin`).
- Pure nodes are hash-consed through one entry point, `interned_node` (`src/ir/intern.odin:13`). Nothing folds: `binary`, `compare`, `unary`, `convert` and `select` only canonicalize operand order and intern (`src/ir/builder.odin`).
- `load` and `store` go through `add_node` and are never shared (`src/ir/builder.odin`), so two reads of `s.len` with no store between are two nodes.
- The scheduler places each floating node at the common dominator of its uses and nothing else (`use_common_block` in `src/sched/order.odin`). There is no early placement, so a loop-invariant pure value used in a loop body is computed in the body.
- Cold blocks are laid out last (`order` in `src/sched/order.odin`). `lower_bounds_check` marks the failing arm `.Cold` (commit `4f289b0`).
- Bounds checks call the runtime handler from that cold arm, then `Unreachable` (`lower_bounds_check` in `src/lower/lower_bounds.odin:18`, commit `4f289b0`). See section 4.1.
- Index addresses with stride 1, 2, 4 or 8 use one `LEA`; any other stride emits `MOV`, `IMUL`, `LEA` (`select_memory.odin`, `.Ptr_Index`).
- `#force_inline` is parsed and checked but `lower` never reads it. There is no inliner.
- Register allocation is a hole-aware linear scan without interval splitting (`src/regalloc/linear_scan.odin`).
- Lowering and code generation already run on a thread pool (`src/lower/reachability.odin`, `Emit_Task` in `src/driver/native.odin`), and output is deterministic.

## 3. What Ginger Bill's own code tells us

### Tilde (2023 to 2026)

Bill wrote the Odin-to-Tilde lowering himself: all 45 commits touching `src/tilde_*.cpp` in upstream are his, from 2023-07-14 to the removal on 2026-03-26 (commit `25c10c18c`, PR #6483). The TB library under `src/tilde/` is Yasser Arguelles Snape's. A copy lives in `refs/compilers_linkers/odin-tilde-backend/src`. His reason for the removal: "Our plan is to just write out own backend instead. It means we have full control over everything." (forum, 2026-03-27).

The lowering was unfinished when removed: every `cg_emit_bounds_check` call in `tilde_expr.cpp` is commented out. Read it for structure, not for completeness. What is worth taking:

- One value type with four kinds (`cgValue`: `Value`, `Addr`, `Symbol`, `Multi`). Multiple results are a `Multi` value, so every caller handles them the same way.
- One addressable-place type (`cgAddr`) with kinds `Default`, `Map`, `Context`, `SoaVariable`, `Swizzle`, `SwizzleLarge` and the relative pointers, and exactly two operations on it, `cg_addr_load` and `cg_addr_store`. Every assignment and compound assignment goes through them (`tilde_stmt.cpp`, the op-assign path near line 1120).
- Multiple returns follow the Odin convention directly: all results but the last go through hidden pointer parameters starting at `split_returns_index`, the last is returned in registers or through the return pointer (`cg_build_return_stmt_internal`, `tilde_stmt.cpp:1138`).
- A defer stack of entries tagged with their scope index, and exits tagged `Default`, `Return` or `Branch`, so leaving a scope runs exactly the defers above its index.
- Generated procedures (equality, hashing, map get and set) are cached per type in the module.
- Each procedure is a unit of work for a thread pool (`cg_procedure_generate_worker_proc`).

### Bounds-check elimination in upstream (2026-10-12)

Ten days ago Bill added his own redundant-check elimination to the official checker: commits `3cd272c0f` "Leave out bounds checks repeating one which already passed" and `2804ac31c` in `src/check_escape.cpp` (in `Odin-upstream` and in our fork). The rule, from his comments:

- A check is left out only when the same check passed before it on every path that reaches it.
- "Same" means the same index and length expressions, reading only constants and locals whose address is never taken, with no assignment to them in between. "As integers wrap, this is only ever equality, never e.g. `i < i+1`."
- A check whose expression might not run (after `&&`, inside a disabled procedure's arguments) is not recorded as passed.
- A statement that may exit part way (`or_return`) does not publish its checks to what follows.

This is the scope Bill accepts today: redundancy only, by equality, no range reasoning, no hoisting. It answers most of the bounds questions the research reports raised.

### PR #7850, the rejected fast backend

bbodi's `-backend:fast` (closed 2026-10-09, copy in `refs/compilers_linkers/odin-pr7850-fast-backend`) was a port of the `lb_*` builders to a new IR, with per-procedure fallback to LLVM through `setjmp`/`longjmp`, shadow modules that log and replay changes for parallel determinism, and 85 IR ops. It reported debug builds 2 to 10 times faster. Bill closed it because maintaining it beside the LLVM backend would cost his project more than it gave, not because he opposes a native backend. Facts from it that are still useful to us:

- Three lowering peepholes gave 1.5 to 2.8 times fewer cycles on loop kernels: keep a result used only by the next instruction in a register, fold small constants into immediates, and fuse a compare whose only use is the next branch.
- The in-range path of a bounds check falls through; the failing path is a cold block that calls the runtime handler.
- CI compared output bytes at 1 and 10 threads to catch nondeterminism.

The lesson for us is about shape: a second code path that mirrors another backend, plus fallback and replay machinery to keep the two in step, is expensive to maintain. We have one backend; keep it that way.

## 4. Correctness first

These come before any optimization because they are behavior differences or owed validation.

### 4.1 Bounds-check failures call the runtime handler (done, `4f289b0`)

Fixed in commit `4f289b0`. `lower_bounds_check` (`src/lower/lower_bounds.odin:18`) branches to a `.Cold` arm that calls the runtime handler (`runtime.bounds_check_error_contextless` or `_with_context`) and then `Unreachable`. That matches the official compiler: on failure the runtime prints `file(line:column) Index i is out of range 0..<n` and traps (`base/runtime/error_checks.odin:27`). Slice expressions use the same path. Matrix index checks and the other `emit_trap` sites (`lower_call.odin:424`, `lower_operator.odin:880`) were not part of that commit.

### 4.2 Validation owed

`selfhost` and one `build-nabla` have not run since commits `57a4b79f`, `385e7e34`, `7a1b4343` and `f948061f`. Kill the stale `build/nabla` and `odinc` processes first. Nothing else lands until this passes.

### 4.3 Hardcoded glibc values

`INTERPRETER = "/lib64/ld-linux-x86-64.so.2"` (`src/link/dynamic.odin:6`), the library path `/usr/lib/x86_64-linux-gnu` (`src/driver/library.odin:12`) and `TCB_SIZE :: 48` (`src/driver/native.odin`) assume one distribution's layout. They only matter in the managed profile, but they break musl systems and the "no GNU" rule. Replace each with a value derived from the psABI or from the system being linked against, with the reference recorded.

## 5. Simplification

Simplification is ongoing work, done one procedure at a time, each as its own task with no behavior change. A task splits one procedure, keeps all tests green, and touches nothing else.

### 5.1 How to pick and split

Procedure lengths were measured on 2026-10-22 over `src/` without tests, `tools/` and `testdata/`: about 2600 procedures, 97 over 80 lines, 22 over 150. By package, over 80 lines (over 150 in parentheses): `check` 48 (12), `lower` 18 (3), `amd64` 5 (0), `link` 5 (1), `syntax` 5 (1), `regalloc` 4 (1), `ir` 4 (0), `elf` 3 (3), `driver` 2 (1), `sched` 1 (0), `types` 1 (0), `odinc` 1 (0).

Length alone is not the signal. A long `switch` that maps names to kinds (`intrinsic_builtin_kind`, 565 lines, `check/builtins.odin:10`) is a table and is fine. The signal is a procedure that computes several unrelated facts up front and then branches on them. Split along the phases the procedure already has: each phase becomes a procedure named for what it produces, and the original becomes a short sequence of calls.

### 5.2 First candidates

| Procedure | Lines | Phases it mixes | Split into |
|---|---|---|---|
| `expression_binary`, `check/expr_ops.odin:109` | 522 | operand checking; about 40 boolean "pair" classifications computed up front; operator validation per class; untyped conversion; result type; constant folding | a classification record built by one procedure (`binary_operand_class`), one validator per operator family, a conversion step, a result step, and the constant step |
| `check_conversion`, `check/conversion.odin:36` | 376 | read first | |
| `check_expression`, `check/expr.odin:214` | 329 | dispatch by node kind | dispatch only; move inline cases to named procedures |
| `expression_simd_call`, `check/simd.odin:107` | 329 | per-builtin checks | one procedure per builtin group |
| `build_image`, `driver/native.odin:191` | 230 | find roots; number symbols; build symbol table; startup atoms; emit; entry; link | `find_module_roots`, `assign_symbol_indices`, `build_symbol_table`, `build_startup_atoms`, then emit, entry, link; the split is the place to fix the startup and stub atom leaks in this file |
| `lower_call_results`, `lower/lower_call.odin:109` | 211 | declaration and result validation; scratch allocation; ordered argument evaluation; ABI argument assembly; the call; result unpacking; deferred registration | one procedure per step, with a small `Call_Lowering` struct for the shared state |
| `write`, `elf/writer.odin:286`, `executable_write`, `elf/elf_exec.odin:444` | 224, 188 | headers, sections, symbols, relocations | one procedure per ELF table |
| `read_object`, `link/object.odin:38` | 264 | per section type | one procedure per section type |

### 5.3 Structural simplifications

These need a design note before code, because they touch many call sites.

- One place type in `lower`. Today an address comes from `lower_address`, `lower_operand_address`, `lower_index_address`, `lower_array_address`, bit-field places and swizzle destinations, each with its own load and store handling. Tilde's `cgAddr` with `addr_load` and `addr_store` is the model: one `Place` union and two procedures. Investigate first how many call sites change (M to L).
- One multi-result representation in `lower`. Multi-result calls are handled by `Spread_Results`, `Spread_Cache`, `lower_multi_declaration` and the multiple-assignment path separately. Tilde's `Multi` value kind is the model (M).
- One ABI packing path shared by calls, returns and the entry glue (M).

## 6. Optimization

All of it runs by default. None of it removes a check, reorders an effect, or assumes no overflow. Every stage is checked by the IR verifier and by the interpreter in `src/ir/interp*.odin`, which is our oracle for integer and float semantics.

Before stage 1, measure (section 9, item 1). After each stage, record compile time, peak memory and run time on the `docs/benchmarks.md` set.

### Stage 1. Folding at construction

Add constant folding and exact integer identities in the builder, before `interned_node` is called: both operands constant; `x+0`, `x-0`, `x*1`, `x*0`, `x&0`, `x&-1`, `x|0`, `x^0`, `x^x`, `x-x`, shifts by 0, compares of a value with itself for integers. All results follow wrapping two's complement at the operand width, exactly as `const_int` canonicalizes (`src/ir/builder.odin`). No float identities: `x+0.0` is wrong for `-0.0`, `x*0.0` is wrong for NaN and infinity.

Put the rules in one new file, `src/ir/simplify.odin`, as small named procedures called from `binary`, `compare` and `convert`. A table or DSL waits until there are enough rules to need one. This follows Simple chapter 2, libFirm's construction-time folding and Cranelift's rewrite-then-intern order. Effort S to M.

Also in this stage, `branch_if` on a constant condition takes the live arm only. `lower_if` already does this for literal conditions (`src/lower/lower_control.odin`); moving it into the builder covers derived constants too. Effort S.

### Stage 2. Memory-state identity

Two loads with the same control, memory state, pointer, type and alignment are the same value, because the memory state is an SSA value. Intern plain loads on that key. Leave `Volatile` and every atomic order alone. Then forward a store to a load whose memory input is that store, when the pointer node and the type are the same. Both changes are local to `load` in `src/ir/builder.odin` and the intern key. Effort S each.

This stage is what makes stage 3 cheap. After it, two reads of `s.len` with no store between are one node, so two checks of `i < len(s)` become the same `ULt` node.

### Stage 3. Redundant bounds checks, Bill's rule in our IR

Implement Bill's 2026-10-12 rule using the graph. After stages 1 and 2, "the same check over unchanged values" is the same compare node id. Walk the dominator tree (`cfg.idoms` already exists in `src/ir/cfg.odin`); when a check's compare node already passed in a dominating block, the check is redundant and its branch is replaced by the passing arm. Keep the policy gate: only checks the program enabled are candidates, and nothing is ever moved.

This matches the upstream behavior and scope, so it needs no owner decision. Range reasoning (`i < n` implies `i < n+1`), loop predication and hoisting stay out, because Bill's rule excludes them and because moving a check above an effect changes what a failing program has done before it panics. Effort M.

Front end or IR: we do it in the IR because hash-consing and the memory chain give us "same value" for free, where the checker has to rebuild it from syntax. The observable result is the same as upstream's.

### Stage 4. Scheduler: early placement

Add an early bound to the scheduler: a floating node may go anywhere on the dominator path from the deepest block of its inputs to the common dominator of its uses, and the scheduler picks the shallowest loop depth on that path, nearest the uses on a tie. This is Click's global code motion and gives loop-invariant code motion for pure nodes with no separate pass. `cfg.depths` and `cfg.idoms` exist. Pinned nodes, including division and loads, do not move. Effort M, in `src/sched/order.odin`; split `place_floating` so early and late placement are separate procedures.

### Stage 5. Instruction selection

Three local improvements, each a small task in `src/amd64`:

- Fuse a compare whose only use is a branch into `CMP` plus `Jcc`, instead of `SETcc`, `MOVZX`, `TEST`, `Jcc`.
- Strides 3, 5 and 9 as one `LEA` (`index + index*2` and so on), 6, 10, 12, 18, 20, 24, 36, 40 and 72 as `LEA` then a scaled `LEA`; others keep `IMUL`.
- Small constants as immediates where the instruction accepts them.

Effort S to M each. bbodi measured the first and third as large wins on loop code.

### Stage 6. Inlining

First honor `#force_inline` and `#force_no_inline` exactly as upstream does, because that is language behavior, not optimization. Then consider leaf procedures under a small node budget (Go uses 80; treat that as a starting point, not a constant to copy), direct calls only, after stages 1 and 2 have run so the inliner sees folded graphs. Clone the callee graph, map parameters to arguments, and merge returns through phis. Effort L. Write a design note first.

### Later, each needs measurement and an owner decision

- Sparse conditional constant propagation (Simple `chapter-sccp`), integer subset, as a pass with its lattice in a side table indexed by node id (M).
- A worklist that re-runs the stage 1 rules on users after `set_input`, `loop_collapse` and `remove_node` mutate the graph, with a fuel limit (M). Needed once stage 1 misses rewrites in practice.
- Dead loop-phi removal at `loop_end` (S).
- Alias classes, starting with non-escaping stack slots (L).
- Interval splitting in the register allocator around calls (M).
- Packed SIMD arithmetic for Odin's `#simd` types, gated by the target features (M), and lowering for the `llvm.*` link names in `core/simd/x86` that we cannot yet emit.

## 7. Sea of Nodes and data-oriented design together

Rules for any new IR work:

- Side tables over node fields. Per-pass facts (lattice values, use counts, placement, loop depth) live in arrays indexed by node id, allocated from the pass's scratch arena, so `Node` stays 8 bytes of data plus its header and passes do not pay for each other.
- One choke point per node family. Pure nodes enter through `interned_node`, effects through their builder procedure. Rules go immediately before interning, so a rewritten node is interned in its final form.
- Mutation is explicit. `set_input`, `remove_node` and `loop_collapse` are the only graph mutators. A pass that mutates rebuilds the intern table (`intern_rebuild`) before it ends, as `loop_collapse` does.
- Count before optimizing. V8 found about one change per 20 node visits in TurboFan and moved to a CFG (`docs/research/04`, section 4). Their reasons are mostly JavaScript's (every operation may deoptimize), but the measurement is cheap: count visits and changes per pass and record them.
- Determinism is a test. Output must be byte-identical at any thread count. Add a check that builds a fixture at 1 and N threads and compares bytes, as PR #7850's CI did.

## 8. Things to avoid

- Rules that need `nsw`, `nuw`, poison, or "overflow cannot happen". Odin wraps.
- Float identities and reassociation without `@(fast_math=...)`. We do not implement that attribute yet.
- Porting InstCombine, GVN, EarlyCSE, DSE or Go's rule files. Bill excluded the LLVM ones for UB reasons; write our rules from Odin semantics.
- Moving a check, or treating build policy flags as optimizer input.
- Removing `SDiv`, `UDiv`, `SRem`, `URem` or loads because the result is unused. They can trap and are pinned.
- Equality saturation or a rule DSL before a plain Odin rule file has proved too small.
- Porting another backend's builders line by line, or adding fallback paths that hand work to a second code generator.
- Rewriting the IR to a CFG because V8 did. Our language has none of the deoptimization pressure that drove their decision.
- New abstractions before the second use. A helper is introduced when two call sites need it, not before.

## 9. Open investigations

Each is a read-only or measurement task for an agent; the result goes into this document or a `docs/research` report.

1. Phase profile. Time and peak memory per stage (parse, check, lower, ir, sched, regalloc, amd64, link) for `hello_fmt`, Nabla and `odinc` itself. Explain the 717 ms on `hello_fmt`. Use `perf`; record node counts and intern hit rates. This is the baseline for every stage in section 6.
2. Run-time profile of the three benchmark kernels: how much of the gap to `-o:speed` is bounds checks, address arithmetic, spills, calls and missing hoisting. Reorder section 6 by the answer.
3. Panic parity beyond bounds: compare stderr and exit status with the official compiler for slice expressions, type assertions, division by zero, `assert`, `panic` and `unreachable`.
4. Count and list the place and multi-result code paths in `lower` (section 5.3) before designing the merge.
5. How upstream decides `#force_inline` failures ("silently ignore" per the directives page) and target-feature conflicts, so stage 6 matches.
6. The `llvm.*` link names used by `core/simd/x86` and by Nabla: which ones reach our builds and which instructions they need.

## 10. Decisions pending from the owner

My recommendation follows each item.

1. Replace the output file instead of overwriting it, so a rebuild of a running program works instead of failing with ETXTBSY. Recommend yes: write to a temporary file in the same directory and `rename` it, which is POSIX and atomic.
2. Optimization levels. Recommend no `-o` flag until a pass measurably costs compile time. Stages 1 to 5 are cheap and run always. When a flag is needed, use upstream's names (`none`, `minimal`, `size`, `speed`, `aggressive`) in our `--` syntax.
3. Loop predication or any check hoisting. Recommend no, matching Bill's 2026-10-12 scope. Revisit only if he extends it upstream.
4. `@(fast_math=...)`. Recommend implementing the attribute's checking now (it is language), and float rules only behind it later.
5. Wording in `AGENTS.md` for editable `base/` and `core/`. Recommend: they are adapted copies of the fork, edited only in their own commits with the file list reported; never reformatted.

## 11. Other known open items

- Integer SIMD `/`, `==`, `!=` lowering.
- Foreign variables in foreign blocks (`Invalid_Foreign_Entity`).
- `DT_VERNEED` in dynamic executables.
- C-variadic procedure definitions.
- Managed-mode stdout flush at exit.
- `core:net` reports `Not_A_Type` at `core/net/common.odin:52`.
- A newline in a string literal is reported as `Import_Failed`.
- `has_target_feature` with an unknown name folds false; the official compiler errors. x86 feature names outside our 35-name table are accepted and never set. No diagnostic for explicit intrinsics that lack their feature.
- Rename `src/types/tools/abi_matrix/llvm.odin` (no LLVM-named files in our code).
- `docs/01-architecture.md` should point at this document and at `refs/compilers_linkers/odin-tilde-backend`.

## 12. Order of work

1. Section 4.2 validation, then 4.1 bounds parity.
2. Section 9 items 1 and 2 (measurement baseline).
3. Section 6 stages 1, 2 and 3, one task each.
4. Section 5.2 splits, one procedure per task, interleaved with the stages so no package is split and optimized at the same time.
5. Section 6 stages 4 and 5.
6. Section 5.3 designs, then stage 6.

## References

Ginger Bill and upstream

- `docs/research/01-gingerbill-vision.md` (timeline and quotes) and `06-gingerbill-and-egraph-deep-dive.md` (optimization stance, flags).
- Tilde lowering: `refs/compilers_linkers/odin-tilde-backend/src/tilde*.cpp`; removal commit `25c10c18c`, PR #6483 (https://github.com/odin-lang/Odin/pull/6483).
- Redundant bounds checks: `Odin-upstream` commits `3cd272c0f` and `2804ac31c`, `src/check_escape.cpp`.
- Optimization pass note: `Odin-upstream/src/llvm_backend_opt.cpp`, "IMPORTANT NOTE(bill, 2021-11-06)".
- Bounds handler: `Odin-upstream/src/llvm_backend_general.cpp:1270`; `base/runtime/error_checks.odin:27`.
- Directives: https://odin-lang.org/docs/directives/; issue #764 on forced inlining.
- PR #7850 and its closing comment: https://github.com/odin-lang/Odin/pull/7850; copy in `refs/compilers_linkers/odin-pr7850-fast-backend`.

Sea of Nodes and optimization

- Simple, Cliff Click: `refs/compilers_linkers/Simple`, chapters 2 (peepholes), 9 (GVN, worklist), 10 and 11 (memory), 13 (global code motion), `chapter-sccp`.
- Click, "Global Code Motion, Global Value Numbering", PLDI 1995: https://dl.acm.org/doi/10.1145/207110.207154.
- Cranelift aegraph: https://cfallin.org/blog/2026/04/09/aegraph/ and the RFC https://github.com/bytecodealliance/rfcs/blob/main/accepted/cranelift-egraph.md.
- libFirm, Braun et al. 2011: https://pp.ipd.kit.edu/uploads/publikationen/braun11wir.pdf.
- V8, "Land ahoy: leaving the Sea of Nodes": https://v8.dev/blog/leaving-the-sea-of-nodes.
- Go `prove.go` and `inl.go`: https://go.dev/src/cmd/compile/internal/ssa/prove.go, https://go.dev/src/cmd/compile/internal/inline/inl.go.

Research reports in this repository

- `docs/research/02-son-gap-analysis-front.md`: Simple chapters 2 to 13 against our IR, with a 14-item roadmap.
- `docs/research/03-son-gap-analysis-back.md`: selection, allocation, calls, SIMD.
- `docs/research/04-son-external-references.md`: C2, Graal, V8, Cranelift, libFirm, Go, LLVM, ABCD.
- `docs/research/05-compiler-research-survey.md`: testing, compile speed, newer techniques.

Corrections to the reports: report 06 cites the fork's `check_escape.cpp` as front-end proof without attribution; it is Bill's upstream work from 2026-10-12. Reports 03 and 04 quote a 4 to 22 times run-time gap; the recorded measurement is 3 to 8 times against `-o:speed` (`docs/benchmarks.md`). Report 04 places Tilde under `refs/compilers_linkers/odin-tilde-backend`, which is correct; `docs/01-architecture.md` gives the shorter path.
