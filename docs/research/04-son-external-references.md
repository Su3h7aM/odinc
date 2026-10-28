# Sea-of-Nodes gap analysis: external references

Status: bounds-check failures call the runtime handler from a `.Cold` block (commit `4f289b0`, 2026-10); passages below that describe a bare trap are stale.

This file compares how other compilers solve the six gaps we measured: the bounds-check trap before every slice access, imul addressing per access, no inlining, no packed FP, no peephole fixpoint, and no SCCP, loop-invariant hoisting or alias classes. The run-time figure of 4-22x slower than the official `-o:speed` build comes from the owner's measurements. I did not re-measure it.

Every claim has a URL or a local path. Where I could not check a claim directly, I mark it "unverified". Effort labels (S, M, L) are my estimates for this codebase. They are not measured.

## 0. Prior-art check

Local sources under `/home/su3h7am/Projects/refs`:

- `compilers_linkers/Odin-upstream/src` is the official checker and LLVM backend. `main.cpp:1014-1019` maps `-o:speed` to optimization level 2 and `-o:aggressive` to level 3. `llvm_backend_passes.cpp:549-551` is the level 2 pipeline (`default<O2>`), and `:1083-1084` is level 3 (`default<O3>`). This is the snapshot in refs; the owner's build may differ.
- `compilers_linkers/odin-tilde-backend/src` is a C++ backend (`tilde*.cpp`). `docs/01-architecture.md` calls it a Sea-of-Nodes backend. I did not read its IR, so that claim is unverified here.
- `compilers_linkers/Simple` is Cliff Click's tutorial. It has `chapter-sccp` and `chapter-interprocedural-sccp`. The other agents cover it; I cite only the directory names.
- `compilers_linkers/go` contains only `src/cmd/link` and `src/runtime`. There is no `cmd/compile`, so no `ssa/prove.go`, rewrite rules or `inl.go`. I searched all 1399 `.go` files for `prove*.go`, `rewrite*.go` and `inl*.go`; none exist. The Go sources below come from go.dev.
- `compilers_linkers/zig` has `lib/` only (std, compiler_rt, ubsan_rt). It has no compiler sources, so I did not use it.
- `alloc/llvm-project` has top-level files and `compiler-rt` only. There is no `llvm/` tree. LLVM sources below come from the llvm.org and llvm-project GitHub pages.

Not local, so taken from the web: Click's papers and talks, HotSpot C2, Graal, V8, Cranelift, libFirm and ABCD.

Our code referred to below:

- `lower/lower_bounds.odin:7` says "Traps unless `holds`": one compare and one trap per access.
- `amd64/select_memory.odin:90-96`: strides 1, 2, 4 and 8 use one LEA with a scale. Any other stride emits a MOV of the immediate, then `IMUL`, then LEA. So the imul cost falls on non-power-of-two element sizes.
- `sched/order.odin:112` reads `schedule.cfg.depths[block]`. I did not check whether pure-node placement uses that depth.
- `check_decl.cpp:1455` and `:1621` (Odin-upstream) show that the checker already handles `#force_inline` and `no_inline`.

## 1. Cliff Click: the graph IR and GCM/GVN

Design:

- Click and Paleczny (1995) use a labeled graph with ordered inputs and unordered outputs. Basic blocks become REGION nodes. PHI inputs line up with REGION inputs, and IF nodes have labeled outputs. Control inputs on primitives are optional, and the paper says dropping them "enables a number of global optimizations" at the cost of a harder serialization step (https://dl.acm.org/doi/10.1145/202530.202534 and the PDF at https://grothoff.org/christian/teaching/2007/3353/papers/click95simple.pdf).
- Global code motion (GCM) schedules a node from its dependence edges only. It hoists code out of loops and pushes it into more control-dependent blocks. It is near-linear, and the original schedule is ignored (Click, PLDI 1995: https://dl.acm.org/doi/10.1145/207110.207154, PDF https://c9x.me/compile/bib/click-gvn.pdf).
- Global value numbering (GVN) in the same paper is a hash lookup on operation and inputs, done in a single pass. It does not place nodes and does not touch memory.

Take:

- GCM as the scheduler for pure nodes. A pure node placed in the shallowest legal block is loop-invariant hoisting with no extra pass. Our `sched/order.odin` already carries block depth, so this may be a small change (M, pending the check in section 0).
- GVN as hash-consing at node creation. The builder already assigns node ids in creation order, so a table keyed by (opcode, inputs, attributes) is small (S). Loads are excluded until section 8 has an answer for aliasing.

Avoid:

- Hashing loads without a memory-clobber answer. GVN's pure-value rule does not cover them.

Effort: GVN hash-consing S; depth-driven placement M.

## 2. HotSpot C2

Design:

- C2 builds its sea of nodes during parsing and inlines at parse time. Then it runs `Iter`: repeat peephole rewrites until none fires. Each rewrite must be monotonic, so the loop is linear. The passes it lists are DCE, constant propagation, CSE, and load/store optimizations (Click, "C2: The JIT in HotSpot", 2018 slides: https://assets.ctfassets.net/oxjq45e8ilak/12JQgkvXnnXcPoAGoxB6le/5481932e755600401d607e20345d81d4/100752_1543361625_Cliff_Click_The_Sea_of_Nodes_and_the_HotSpot_JIT.pdf).
- The same slides list global code motion, loop optimizations (range-check elimination by splitting the iteration space into pre, main and post loops, then peeling and unrolling), and say inlining decisions "often too early". They also say the graph-coloring allocator is robust to over-inlining, because spill code costs less than call overhead.
- Loop predication moves an array range check out of the loop. The loop gets one check before it, and a failing check raises an uncommon trap. The check inside the loop goes away, and no loop copies are made (https://wiki.openjdk.org/spaces/HotSpot/pages/20415918/Loop+optimizations+in+Hotspot+Server+VM+Compiler+C2; the source header of `loopPredicate.cpp` at https://github.com/openjdk/jdk/blob/547a8b40b324917e66c71409b31421feacce79d7/src/hotspot/share/opto/loopPredicate.cpp).

Take:

- A monotonic peephole worklist that runs to fixpoint. Keep the rule set small and check that each rule only makes the graph smaller or more canonical (M).
- Inlining after the peepholes have run, rather than at lowering. Our inliner should see canonical nodes.
- Loop predication for bounds checks, once we have induction-variable recognition and the owner has answered question 1.

Avoid:

- Hoisting a check above a loop that writes to stdout or memory. HotSpot can fall back to the interpreter, which restores the state at the trap. We have no deopt. A check hoisted above earlier side effects would change which effects happen before the panic. That is observable, so this needs a decision first.
- Pre/main/post loop splitting. It copies the loop body and grows the code. Predication needs a single check instead.

Effort: peephole worklist M; loop predication L (needs induction variables).

## 3. Graal IR

Design:

- Graal keeps pure operations as floating nodes and effectful operations on a fixed control chain. A guard is a floating node. It takes no control position of its own, and the scheduler places it near its uses. On failure it deoptimizes using a FrameState taken from the nearest side-effecting node (Duboscq et al., 2013: https://doi.org/10.1145/2542142.2542143).
- FrameState assignment attaches frame states only to side-effecting nodes. Deoptimizing nodes reuse the nearest one, which keeps the state small (Duboscq et al., PPPJ 2014: https://ssw.jku.at/General/Staff/GD/PPPJ-2014-duboscq-29.pdf).
- `FloatingReadPhase` turns fixed reads into floating reads that depend on a memory graph. `ConditionalElimination` removes branch conditions that flow-sensitive facts prove true or false. `SchedulePhase` places floating nodes (source comments in https://github.com/oracle/graal/blob/master/compiler/src/jdk.graal.compiler/src/jdk/graal/compiler/core/phases/CEOptimization.java; the invited talk on Graal IR by Chris Seaton is unverified here).

Take:

- Floating reads with a named memory state (section 8).
- Cold-block placement for traps: a trap's failure path is never taken, so the scheduler can put it at the lowest frequency. This is S.

Avoid:

- Floating guards without a deopt state. Graal's reordering is safe because a guard can deoptimize to the right program point. We have no deopt. A bounds check has to keep its order relative to every effect that precedes it, unless analysis shows that no effect is observable in between.

Effort: cold trap placement S; floating reads with memory map M-L.

## 4. V8: TurboFan and Turboshaft

Design:

- TurboFan used Sea of Nodes for the JavaScript pipeline. Effect and control chains link memory operations, checks and branches. V8's March 2025 post says the whole JavaScript backend and all of WebAssembly now run on Turboshaft, a CFG IR with explicit blocks and composable "reducers" (https://v8.dev/blog/leaving-the-sea-of-nodes; https://chromium.googlesource.com/v8/v8/+/0cc5dcf12126a6bd5ca8fb95aa49fd5d228ed7e5/docs/compiler/turboshaft/compiler-turboshaft.md).
- The post gives these problems. Effect and control chains cause subtle bugs, and the team once got three parallel effect chains wrong. Lowering cannot easily add control flow, so lowerings get pushed to a late scheduling phase. Nodes change about once every 20 visits, so the visitation order wastes most of the work. Load elimination had to bail out on large graphs; the CFG version is up to 190x faster. Their SoN build had about 3x more L1 data-cache misses. They report compile time halved (all numbers are V8's own measurements).
- A checked operation such as CheckedAdd floats freely if it is pure. A check that can be removed only once the branch is known must be pinned to control. V8 gives it a control input (same post).

Take:

- Keep explicit blocks for traps and bounds checks at lowering. `lower/lower_bounds.odin` already emits a compare and a trap, so the CFG shape exists there. The question is whether the IR keeps that shape or folds it into floating nodes.
- Keep the effect chain small: memory and trap nodes only. Scalar code gets no effect edges.
- Count visits per change in our peephole worklist, as V8 did. If the ratio is near 1, the order is fine.
- Run load elimination as a separate pass over a block order, which gives the linear cost V8 measured.

Avoid:

- A rewrite toward CFG. V8's main reason is that almost every JavaScript operation can run arbitrary code or deoptimize. A checked, statically typed program has far fewer of those, so their main reason does not apply here. Their smaller lessons do.

Effort: lessons S to M; no rewrite.

## 5. Cranelift: aegraphs and ISLE

Design:

- Cranelift's mid-end uses an acyclic e-graph (aegraph). Rewrite rules fire once, when a node is created. Equivalences are kept with union-find, with no fixpoint over merges. Elaboration, which translates back to a CFG, performs GVN, LICM and rematerialization in the same walk (EGRAPHS 2023 abstract: https://pldi23.sigplan.org/details/egraphs-2023-papers/2/-graphs-Acyclic-E-graphs-for-Efficient-Optimization-in-a-Production-Compiler; design RFC: https://github.com/cfallin/rfcs/blob/main/accepted/cranelift-egraph.md).
- The RFC's prototype numbers, which the author reports: SpiderMonkey.wasm run time -13% and compile time +1%; bz2.wasm run time -3% and compile time -15%. The prototype replaced GVN, LICM, simple preopt and alias analysis.
- The author's April 2026 post says the aegraph pipeline beats the classical pipeline, with about 7-8% more compile time now than classical. That is because the rule set has grown. Repeating the classical pipeline does not get the same result (https://cfallin.org/blog/2026/04/09/aegraph/).
- ISLE is the rule language. Rules are typed terms. Extractors and constructors are Rust functions, and implicit converters remove boilerplate. The lowering rules are about 27k lines of DSL (https://cfallin.org/blog/2023/01/20/cranelift-isle/). That post also quotes Go's rules, for example `(ADD(L|Q) x (SHL(L|Q)const [3] y)) => (LEA(L|Q)8 x y)`.

Take:

- Peephole rules applied at node creation in our builder. This is S, and it is the cheapest route to a fixpoint-like effect.
- A small table of addressing rules for LEA with scale, as in the Go example. Write it as plain Odin first (M).
- Track compile time per rule family. The aegraph author's post shows the cost grows with the rule set.

Avoid:

- A rule DSL before we have roughly 20 rules that need it. ISLE's payoff came after a year-long migration.
- Full equality saturation with rebuilding on every merge. The aegraph work reports that as too costly.

Effort: rules at creation S; addressing table M; DSL L.

## 6. libFirm

Design:

- FIRM is a graph-based SSA IR in the sea-of-nodes family. Memory is an SSA value. Each load and store consumes a memory value and produces a new one. A Sync node joins several memory values when the operations are proven not to alias (Braun et al., 2011: https://pp.ipd.kit.edu/uploads/publikationen/braun11wir.pdf).
- When aliasing is unknown, the variable is kept out of SSA, and every access becomes an explicit load or store (same paper).
- FIRM calls its optimizations "inherent". Constant folding runs during node construction, and dead code disappears because nothing reachable from the end node uses it (same paper; edge documentation at https://libfirm.github.io/Edge_Types.html).

Take:

- Constant folding and algebraic identities inside the node constructor. This is the construction-time half of change 1 below (S).
- A memory split by alias class, using Sync-style joins only where two accesses are provably disjoint. Our first candidates are distinct stack slots, distinct globals, and a freshly allocated slice's data (M to L).

Avoid:

- Putting a scalar into SSA when its address escapes, unless the paper's rule is met. Keep the conservative fallback.

Effort: construction folding S; alias-class memory M-L.

## 7. Go SSA backend

Design:

- `prove` (ssa/prove.go) keeps a fact table of branch conditions that dominate each block. The file opens with "By far, the most common redundant pair are generated by bounds checking" (https://go.dev/src/cmd/compile/internal/ssa/prove.go?m=text). Its facts live in a partial order over values, and they include slice length, slice capacity and induction variables.
- `test/bounds.go` lists the cases that elide checks. An unsigned 8-bit index into a 1000-element array is elided. So are `ui%1000` and `i&999`, and `ui32>>22` into a 1000-element array (https://go.dev/test/bounds.go, lines 64 to 232). These are concrete, local range facts.
- Rewrite rules in `.rules` files map generic operations to machine operations and combine them. The Cranelift post quotes examples (section 5).
- `inl.go` sets the budget. The base budget is 80 nodes. A non-inlinable call costs 57, and a call through a parameter costs 17. A panic costs 1. Functions over 5000 nodes inline only bodies costing 20 or less. A closure called once gets 800. A function with SIMD parameters gets a multiplier of 3, and a closure capturing SIMD values gets 16 (https://go.dev/src/cmd/compile/internal/inline/inl.go, lines 48-61 and 182-231).

Take:

- A dominator-based fact table in the shape of `prove`. For each block, record the conditions that dominate it, and drop a check when a recorded fact implies it. Our `lower_bounds` already produces a comparison per access, so the facts are available. This is S to M.
- The mask, shift and mod range facts from `bounds.go`. These are local and cheap (S).
- The inlining budget of 80, applied to leaf procedures first. Honor `#force_inline` and `no_inline` (S to M).
- The SIMD credit idea, if packed FP arrives. Vector code is worth more inlining (see the gap table).

Avoid:

- The full partial order from `prove.go`. It is large. Start with one fact per dominator.
- Copying Go's exact cost constants. They were tuned to Go's code and runtime. Use them as starting points.

Effort: fact table S-M; ranges S; inlining budget S-M.

## 8. LLVM: IndVarSimplify (SCEV) and GVN

Design:

- `IndVarSimplify` widens induction variables to the width of their widest sign- or zero-extended use. Before it widens, it checks the target's cost of the `add` (`visitIVCast` in https://github.com/llvm/llvm-project/blob/main/llvm/lib/Transforms/Scalar/IndVarSimplify.cpp).
- Range facts come from two commits. One sharpens `!range` metadata using loop-entry predicates (r219834, 2014: https://lists.llvm.org/pipermail/llvm-commits/Week-of-Mon-20141013/239952.html). The other uses control-dependent ranges to prove that an increment is non-negative (r284629, 2016: https://lists.llvm.org/pipermail/llvm-commits/Week-of-Mon-20161017/398692.html).
- GVN "eliminates fully and partially redundant instructions. It also performs redundant load elimination" (https://www.llvm.org/docs/Passes.html). Loads are matched by a backward memory-dependence walk. Across blocks, the pointer is translated through PHIs (https://blog.llvm.org/2009/12/introduction-to-load-elimination-in-gvn.html and https://blog.llvm.org/2009/12/advanced-topics-in-redundant-load.html).
- The official `-o:speed` pipeline is `default<O2>` (section 0). I read only its entry and the `loop-unroll<O2>` lines. The other passes named here are from LLVM's documentation and are unverified against this snapshot.

Take:

- Induction-variable recognition: a PHI whose back-edge value is the PHI plus a constant, under a bound. It feeds bounds-check facts in loops and strength reduction of element addresses. This is M.
- Load forwarding inside a block and across a single-predecessor edge, using our memory chain as the clobber test. A store to the same address kills the value. A call or an unknown store kills everything. This is S to M.

Avoid:

- A general scalar-evolution engine. That is L and not needed. Recognize one pattern first.
- PHI translation for pointers. It is the hardest part of GVN, so defer it.

Effort: induction variables M; load forwarding S to M.

## 9. ABCD: Bodík, Gupta and Sarkar (PLDI 2000)

Design:

- ABCD builds an inequality graph over an extended SSA form. Nodes are values, and edges are facts such as `i < a.length` or `i + c`. Removing a check is a path query from the index to the bound (https://dl.acm.org/doi/10.1145/349299.349342; PDF https://dl.acm.org/doi/pdf/10.1145/358438.349342).
- It is demand-driven. Analysis runs only on checks worth the cost, such as hot ones. The paper reports fewer than 10 analysis steps per check and about 45% of dynamic checks removed, on Jalapeño.
- Partially redundant checks are handled by finding insertion points on the same graph. This adds a check on a new path (PDF above).

Take:

- Demand-driven analysis. Start with the checks inside loops, then the rest. This is S to M.
- An inequality graph as a second layer over the dominator table in section 7. It fits our builder.

Avoid:

- Inserting new checks on new paths. A new trap on a path that had none conflicts with the panic-order rule in question 1.

Effort: M.

## Gap mapping

| Measured gap | Best external source | First cheap step | Effort |
|---|---|---|---|
| Bounds-check trap before every slice access | Go `prove` and `bounds.go` (section 7); ABCD (section 9); HotSpot loop predication (section 2) | Dominator fact table; mask, shift and mod ranges | S, then M |
| imul addressing per access | Go and Cranelift addressing rules (sections 5, 7); LLVM induction variables (section 8) | For a stride of 12 or 24, use LEA chains (`x + 2x`, then scale) or step a pointer per iteration | S to M |
| No inlining | Go `inl.go` budget (section 7); HotSpot inlining after peepholes (section 2) | Inline leaf procedures under cost 80 before scheduling | M |
| No packed FP | Go's SIMD credit (section 7); no cheap external source | None cheap. Needs a vector type in the IR | L |
| No peephole fixpoint | C2 `Iter` (section 2); aegraph rules at creation (section 5); libFirm constructor folding (section 6) | Monotonic worklist; rules and folding at node construction | S to M |
| No SCCP | `chapter-sccp` in the Simple tutorial (local); Click's lattice approach | SCCP over the graph with reachability per control node | M |
| No LICM | Click's GCM placement by depth (section 1); aegraph elaboration (section 5) | Scheduler picks the shallowest legal block for pure nodes | M |
| No alias classes | libFirm Sync joins (section 6); Graal floating reads (section 3); LLVM memory-dependence walk (section 8) | Split the memory chain per provably disjoint root | M to L |

## Recommended order for the first six changes

These are ordered by my reading of the sources, not by measurement. The owner should check the order against a profile of trap-and-compare cost in the slowest benchmarks.

1. Peephole rules at node creation, plus a monotonic worklist to fixpoint (S, then M). Every later analysis then sees canonical nodes, and the graph gets smaller before the bounds analysis runs. Sources: C2 `Iter`; libFirm constructor folding; aegraphs. Measure visits per changed node. V8 found about one change per 20 visits in its graphs.
2. Dominator-based bounds-check elimination with a fact table (S to M). It covers the same index and length pair, constant lengths, and mask, mod and shift ranges. Sources: Go `prove`, `bounds.go`. Straight-line code loses most of its trap-and-compare pairs. Loops keep their checks until change 6 or a later loop pass.
3. SCCP over the graph (M). Start from `chapter-sccp` in the Simple tutorial. It removes dead branches, which helps change 2 as well.
4. Scheduler placement of pure nodes by loop depth (M). This gives loop-invariant hoisting for pure operations. Source: Click's GCM. Check first whether `sched/order.odin` already uses the depth at line 112 (question 4).
5. Address folding and induction variables (M). Keep strides 1, 2, 4 and 8 as one LEA with a scale, as today. For other strides, use LEA chains or step a pointer per iteration. The induction-variable recognizer also serves loop-level checks later. Sources: Go's LEA rule; LLVM `IndVarSimplify`.
6. Inline leaf procedures under the 80-node budget, before scheduling. Honor `#force_inline` and `no_inline` (M). Sources: Go `inl.go`; C2 inlining after peepholes.

After these six, the next items are loop-level bounds-check predication (blocked by question 1 and by change 5), alias-class memory (M to L), and packed FP (L).

## Open questions for the owner

1. Panic order. In the official build, a bounds failure inside a loop happens after the loop's earlier side effects, such as writes to stdout. Hoisting the check above the loop (predication) makes the panic come earlier. Is that acceptable, or must each check keep its program order relative to effects? The answer decides whether loop predication is allowed at all.
2. Is the single memory chain fixed? Alias classes need several chains (libFirm). V8's post names effect chains as the biggest source of their trouble, so this is a design decision, not a tuning detail.
3. Should inlining run before or after the peephole fixpoint? Section 2 argues after. The answer also decides whether inlining happens in `lower` or in `ir`.
4. Does `sched` place pure nodes by loop depth today? `sched/order.odin:112` reads the depth, but I did not read the placement code. If it already does, change 4 is S.
5. Which benchmarks carry the 4-22x? A breakdown into bounds checks, address multiplies, calls and FP would reorder the six changes.
6. Float rules: may our `-o:speed` build reassociate floats or contract multiply-add? Packed FP depends on the answer. I have not checked the official float flags (unverified).
7. Compile-time budget: is there a limit? V8 and Cranelift both report compile time as the constraint on each new pass. We need a number before adding passes.

## Unverified or not used

- The V8 page `why-cfg` returned 404 and is not cited.
- The Graal invited talk (Seaton, 2020) appeared in a search result only. I did not read it.
- The LLVM `default<O2>` pass list is only partly read (section 8).
- Go's rewrite rules are cited through the Cranelift post's quotes, not read from source. The Go source is not in refs.
- The Cranelift and V8 performance numbers are the authors' own. I did not reproduce them.
- The HotSpot `Iter` and GCM claims come from 2018 slides, not a paper.
