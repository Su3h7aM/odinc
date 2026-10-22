# Compiler optimization gaps, back half

This note compares Simple chapters 14–25 with the compiler in this repository. Simple is a useful set of optimization examples, not an architecture to copy. Our architecture remains the pipeline in `docs/01-architecture.md`, with Sea of Nodes IR and a one-memory-chain representation. The reported performance gap is 4–22x slower than the official compiler at `-o:speed`; that number is supplied as a premise for this analysis, not measured here. The other reported symptoms are bounds-check traps on slice accesses, indexed addresses with `imul`, no inlining, and no packed floating-point operations.

## Numeric types, ranges, and bounds checks

Simple chapter 14 models integer types as ranges, propagates ranges through arithmetic, and uses a type lattice for constants and nonconstant values. Chapter 15 adds arrays and range-checks array access. Together the chapters make the bounds predicate an optimization target: if analysis proves `0 <= index < length`, the check is redundant. Chapter 24 describes SCCP over a rich lattice as a later way to propagate values and discover call edges.

We lower checked indexing directly into control flow. `src/lower/lower_bounds.odin:34-46` checks the high word of a wide index and converts ordinary integer offsets; `:75-98` handles array/slice bases, compares the index against length when policy is enabled, then creates the scaled pointer. `src/lower/lower_bounds.odin:10-15` emits a trap branch. Bounds policy is retained in `check.Bounds_Plan` (`src/check/model.odin:857-865`); `src/check/expr_index.odin:1-9` describes the policy and the `#no_bounds_check` override. The IR contains scalar operations and a `Ptr_Index`, but the cited architecture has no range-analysis or SCCP pass (`docs/01-architecture.md:9-25`).

**Gap.** There is no fact domain on IR values that proves an index range from preceding comparisons, constants, induction variables, or known array lengths. A trap before each eligible access therefore survives even when the program establishes the bounds.

**Sketch.** Add a conservative integer interval domain and a worklist analysis over IR nodes and CFG edges, likely in `src/ir/range.odin` and a new optimization driver under `src/opt/`. Transfer functions cover constants, conversions, add/subtract, comparisons, and phis; overflow widens to unknown rather than asserting a false interval. Use branch predicates to refine intervals per successor. Before `sched.order`, remove only the check branch whose true edge is proven by the analysis, preserving the trap edge otherwise. Keep language policy as the gate: disabled checks remain disabled, and proof-based removal applies only to enabled checks. Validate IR after rewriting. Tests should cover constant and loop-derived indices, signed/unsigned boundaries, overflow, joins, wide indices, and a deliberately failing access. Compare optimized and unoptimized execution for results and trap behavior.

Risk is unsound range narrowing at overflow, casts, or loop joins; start with intervals and unknown-on-overflow, not aggressive modular arithmetic. Effort: L.

## Global code motion and loop optimization

Simple chapter 13 describes global code motion with early placement at the first block dominated by inputs and late placement near uses, favoring shallow loop nests while preserving memory order. It computes dominators and loop depth, then places loop-invariant work outside loops. Chapter 19 adds target selection and scheduling; later chapters revisit scheduling details.

Our `src/sched/order.odin:28-75` builds the control skeleton, places floating values, pins effects and phis, and orders nodes in blocks. `src/sched/order.odin:141-168` places floating values at a common dominator of uses. `src/sched/order.odin:236-252` adds memory ordering and exit dependencies. `Block.depth` is retained (`src/sched/order.odin:10-16`), but no late placement cost or loop-depth placement is apparent in the ordering algorithm. The architecture calls this global code motion (`docs/01-architecture.md:9-25`); the current implementation is a simpler single placement strategy.

**Gap.** Loop-invariant work may remain in loop blocks. There is no unrolling pass. Bounds checks and address calculations inside hot loops can also remain per-iteration.

**Sketch.** First extend scheduler placement with a late-use walk: compute the common dominator of uses, walk upward from that block toward the earliest legal block, and choose the shallowest loop depth that dominates uses, while respecting pinned effects and memory dependencies. Add a separate loop optimizer later, after range analysis: identify canonical induction variables and trip counts, hoist only pure invariant nodes, and unroll only small constant-trip loops under a code-growth budget. Keep transformations in `src/sched` or a distinct `src/opt/loop.odin`, with an explicit pipeline position before final scheduling. Test dependence ordering, nested loops, side effects, zero/one/multiple trip counts, and code-size limits. Benchmark loop kernels separately.

Risks include moving loads across stores or changing trap timing, and code growth from unrolling. Implement hoisting first; effort M. Bounded unrolling is L.

## Function calls and inlining

Simple chapter 18 represents function entries, parameters, returns, and calls in its graph. It reports a first inlining form for a function with one caller, allowing ordinary peepholes to simplify the merged graph. Chapter 24's interprocedural SCCP discovers call-graph edges; chapter 25 separates compilation units and preserves externally reachable functions.

Our lowering creates a `.Call` IR node after resolving signatures and argument evaluation (`src/lower/lower_call.odin:75-109`, `:247-331`). The `amd64` selector assigns ABI pieces and emits the call (`src/amd64/select_control.odin:52-76`). System V argument/result registers and stack placement are explicit in `src/amd64/abi.odin:37-55`, `:58-99`; call lowering emits the machine call and tracks clobbers in `src/amd64/abi.odin` and the instruction metadata in `src/amd64/op_info.odin:20-30`. There is no inliner in the documented pipeline (`docs/01-architecture.md:9-25`); source search found `#force_inline` checking and printing but no lowering expansion pass (`src/check/target_feature.odin:293-309`, `src/check/expr_to_string.odin:50-53`).

**Gap.** Calls retain ABI moves, call/return control transfer, and register clobber costs even for small local procedures. There is no IR inlining to expose constant arguments, eliminate wrappers, or enable range facts across a call.

**Sketch.** Add an IR-level inliner after all procedure bodies are lowered and verified, before range analysis and scheduling. Start with direct calls to small, nonrecursive, nonvariadic local procedures. Clone the callee's nodes into the caller, map parameters to call arguments, merge multiple returns through caller control/value/memory phis, and replace call projections. Preserve source-level evaluation order and effects. Do not inline foreign, indirect, exported/address-taken, or feature-incompatible procedures in the first version. Honor force-no-inline; treat force-inline as a diagnostic or required attempt according to existing semantics. Test returns, branches, memory effects, recursion rejection, argument side effects, and debug/source locations; compare executable output and traps before and after. Add a code-size threshold and report rejected candidates in compiler diagnostics or dumps.

Risks are IR remapping, memory-chain correctness, code growth, and target-feature rules. Effort L.

## Instruction selection and address arithmetic

Simple chapter 19 maps ideal nodes to machine-specific nodes before scheduling. Chapter 21 connects selected operations, allocation, encoding, calling conventions, and executable testing. Chapter 15's address arithmetic work represents scaled indexing and constant offsets explicitly, which can become x86 addressing modes.

Our selector already folds address expressions in memory operands. `src/amd64/select_memory.odin:7-40` recursively combines `Ptr_Offset` and scales 1, 2, 4, or 8 from `Ptr_Index`; `:61-99` emits `LEA` for pointer offsets and encodable scales, but materializes other scales with `IMUL`. Thus the reported `imul` is specifically the fallback for element sizes outside x86's addressing scales, not every indexed access. Integer multiplication maps to `IMUL` (`src/amd64/select_int.odin:59-72`). Comparisons currently produce `CMP`, `SETcc`, and `MOVZX` (`src/amd64/select_int.odin:46-56`); control exits independently emit `TEST` and conditional branches (`src/amd64/select_control.odin:10-22`). Machine metadata tracks flag reads/writes and branches (`src/amd64/op_info.odin:10-17`, `:48-76`).

**Gap.** Address mode folding handles common scales, but cannot encode arbitrary stride directly. There is no documented general pattern selector that fuses compare and branch or reduces multiplication by constants to shifts/adds/LEA. Separate value compare and branch lowering can leave redundant boolean materialization.

**Sketch.** Add selection patterns over scheduled IR neighborhoods, not ad hoc source rewrites. First canonicalize constant multiplication by powers of two and small signed constants to shifts/add/sub before selection, with exact width and overflow semantics. For odd strides, use a costed sequence of `LEA`/shift/add when cheaper than `IMUL`; retain `IMUL` for large constants. Extend conditional terminator selection to recognize a compare feeding only a branch and emit `CMP` plus the matching conditional jump, avoiding `SETcc`/`MOVZX`. Preserve standalone compare values and floating NaN semantics. Address selection can fold nested offsets and index expressions into base/index/scale/displacement only when x86 encoding and register constraints permit. Keep patterns target-aware in `src/amd64/select_int.odin`, `src/amd64/select_memory.odin`, and `src/amd64/select_control.odin`; update `src/amd64/op_info.odin` for flag dependencies. Test emitted instructions and execute signed/unsigned boundary cases, immediate edge cases, and memory addresses across legal scales. Benchmark code size and cycles, not instruction count alone.

Risks are flag liveness, condition inversion mistakes, and large instruction sequences regressing latency. Effort M.

## Register allocation

Simple chapter 20 builds interference and uses graph coloring with spill/split rounds and machine-specific constraints. Later chapters add allocator heuristics. Its chapter 19–21 sequence emphasizes testing selection and allocation through executable code, since errors interact.

Our allocator is already a careful linear scan, not a trivial first-fit scan. `src/regalloc/linear_scan.odin:1-16` documents hole-aware live intervals, fixed constraints, spill costs, reuse-input copies, and call-aware register preferences. `src/regalloc/liveness.odin:1-29` builds disjoint ranges and tracks clobbers/calls; `src/regalloc/linear_scan.odin:91-120` allocates fixed requirements before ordinary intervals. It does not split intervals: spills occupy a slot for the whole live range (`src/regalloc/linear_scan.odin:10-12`).

**Gap.** Long intervals can cause avoidable spills and callee-save use because the allocator does not split a live range around cold regions or calls. Graph coloring is not automatically superior; compare outcomes before replacing a sound, tuned linear scan.

**Sketch.** Add selective interval splitting at call boundaries or hot/cold block edges, with explicit transfer moves and spill-slot reuse, while preserving fixed/reuse constraints. Use the existing spill-weight and loop-depth data as the cost model. Keep allocation behind the same `Program`/`Result` contract. Extend `verify` to validate split moves and locations; add adversarial pressure tests and codegen benchmarks for spills, calls, and loops. Consider graph coloring only if measurements show a persistent quality deficit after splitting.

Risks include broken edge copies and register constraints; the existing verifier is a strong guard. Effort M for splitting, L for a new allocator.

## Packed floating point and vectorization

Simple chapters 14 and 19–21 provide scalar numeric types, target selection, allocation and encoding foundations. They do not establish a general loop vectorizer in the chapters reviewed. Vectorization is therefore a proposed extension, not a feature attributed to Simple.

Our backend handles scalar `F32` and `F64` arithmetic with scalar SSE instructions (`src/amd64/select_float.odin:8-43`, `:103-142`). It recognizes `V128` as a float-register-class value (`src/amd64/abi.odin:58-66`) and supports selected target operations (`src/amd64/select_simd_target_op.odin:8-35`), but this is not packed floating-point arithmetic. The stated absence of packed FP therefore means ordinary arithmetic does not map to vector lanes. The target baseline and feature levels are documented in `docs/01-architecture.md:27`.

**Gap.** There is no vector IR for packed arithmetic and no loop dependence/alignment analysis to prove safe vectorization. Enabling packed operations without target-feature guards could violate the x86-64-v1 baseline.

**Sketch.** First add explicit vector value types and lane-wise arithmetic/comparison nodes to IR, then implement selection for baseline-supported packed SSE operations where semantics match Odin's vector types. Keep AVX/AVX2/AVX-512 selection behind the function's enabled target-feature set and `--mcpu`. A later vectorizer should recognize simple counted loops, prove no loop-carried memory dependence and legal alignment/tail handling, then build vector operations plus a scalar remainder. Place it after inlining, range analysis, and loop canonicalization, but before scheduling and selection. Tests must check scalar equivalence, tails, alignment, NaNs, target-feature rejection, and output on the baseline CPU. Measure vector throughput and regressions on short loops.

Risks include floating-point reassociation semantics, alias analysis, tails, and feature dispatch. Explicit SIMD types: M; auto-vectorization: L.

## Calls and ABI overhead

A call is not merely a branch. It may require argument moves, stack argument setup, caller-save preservation, return-value extraction, and frame setup. Simple chapter 18 describes function/call graph structure and inlining as a way to erase that boundary. Chapters 19–21 integrate calling convention and machine constraints.

Our `lower_call_results` constructs ABI arguments, aggregate pieces, hidden result storage, and a call node (`src/lower/lower_call.odin:75-130`, `:150-331`). `src/amd64/abi.odin:34-55` defines System V locations and `:58-99` assigns argument pieces. The selector resolves direct symbols and indirect targets, calls `lower_call`, and handles syscall separately (`src/amd64/select_control.odin:52-97`).

**Gap.** The ABI implementation is substantial and necessary for compatibility, but each non-inlined call still pays its normal ABI costs. The useful reduction is often inlining or better register/stack move scheduling, not changing the ABI.

**Sketch.** Keep the System V contract fixed. After inlining exists, inspect remaining direct calls for redundant copies into ABI registers, avoid copies when the value already occupies the required register, and schedule parallel argument moves through the existing edge-copy machinery. Benchmark tiny calls and aggregate calls separately. Tests should include mixed integer/float arguments, stack overflow arguments, aggregates, variadics, and foreign calls.

Risks are ABI breakage and clobber mis-modeling. Effort S for measured move cleanup; inlining effort is tracked above.

## Prioritized roadmap

| Priority | Work | Main files | Effort | Reason |
|---|---|---|---|---|
| 1 | Interval analysis and proven bounds-check elimination | `src/ir/range.odin`, `src/opt/`, `src/lower/lower_bounds.odin` | L | Directly targets a reported trap on every slice access; retain traps unless proof is sound. |
| 2 | Compare/branch fusion and constant address arithmetic | `src/amd64/select_control.odin`, `src/amd64/select_int.odin`, `src/amd64/select_memory.odin` | M | Removes materialization and some `imul` sequences without changing IR semantics. |
| 3 | Small direct-call inlining | New IR optimization pass; `src/lower/lower_call.odin` for call shape | L | Removes call overhead and exposes constants/ranges to later passes. |
| 4 | Scheduler late placement and loop-invariant hoisting | `src/sched/order.odin` | M | Moves pure invariant work out of hot loops; must preserve effect order. |
| 5 | Split live intervals around calls/pressure points | `src/regalloc/liveness.odin`, `src/regalloc/linear_scan.odin` | M | Reduces spills without replacing the current allocator. |
| 6 | Explicit packed FP operations | `src/ir/`, `src/amd64/select_float.odin`, `src/amd64/op_info.odin` | M | Establishes vector operations before any auto-vectorizer. |
| 7 | Bounded loop unrolling and auto-vectorization | `src/opt/loop.odin`, new vector analysis | L | Requires canonical loops, dependence proof, and code-size/target controls. |

Treat the reported 4–22x slowdown as a suite-level symptom. Collect per-benchmark profiles and compare the official `-o:speed` compiler before assigning all of the gap to any one feature. For each roadmap item, record generated instruction counts, binary size, runtime, and correctness against the unoptimized compiler path.

## Open questions for the owner

- Which benchmark suite and input sizes produced the 4–22x range, and are the slow cases dominated by slice indexing, calls, integer arithmetic, or floating-point loops?
- Does the compiler already have a performance build mode or pass dump that this note should name? The architecture document only lists the pipeline and `--histogram`.
- Should proof-based bounds-check elimination run when checks are enabled, or is preserving every enabled check part of the current debugging contract?
- Which Odin vector types and floating-point semantics are expected to define packed operations? Should automatic vectorization wait for explicit SIMD support and alias analysis?
- What code-size budget and force-inline behavior should guide a first inliner?
- Should the next benchmark focus be hot loops and allocator pressure, or end-to-end applications?

## References

Simple chapters 13–25: `/home/su3h7am/Projects/refs/compilers_linkers/Simple/chapter13/README.md` through `chapter25/README.md`. Chapter 17 has two README paths, `chapter17a` and `chapter17b`; chapters 14, 15, and 18–25 were reviewed for this note. Repository evidence is cited inline above. Architecture: `docs/01-architecture.md`.
