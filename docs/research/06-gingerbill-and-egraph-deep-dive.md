# Ginger Bill's optimization rules and e-graph rewriting: deep dive

Research note, 2026-10-23. It deepens two weak areas of `05-compiler-research-survey.md`: Ginger Bill's stated constraints on optimization and bounds checking (Part A), and e-graph style rewriting for our Sea-of-Nodes graph (Part B). It does not repeat the backend timeline in `01-gingerbill-vision.md` or the architecture rules in `01-architecture.md`; those are cited where needed.

Evidence tags: **[V]** fetched or read in this pass (a web page, a GitHub page, or a local file); **[S]** seen only in a search snippet; **[D01]** taken from `01-gingerbill-vision.md` and not re-fetched; **[U]** unverified.

"Fork" means the Odin fork at `/home/su3h7am/Projects/Odin` (jj working copy at commit `ea225db25`). It is read as a local copy of the official compiler's sources, not as a separate reference.

## Part A: Ginger Bill

### A1. Primary sources and what they say

| Date | Source | Statement or fact | Tag |
|---|---|---|---|
| 2017-03-09 | "Working on a Custom Backend for Odin", odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin | "LLVM is slow - It takes up 85%+ of the total compilation time; even for non-optimized code." Also "LLVM's design is restrictive". | V |
| 2021-03-31 | Odin issue #891, github.com/odin-lang/Odin/issues/891 (opened by gingerBill) | Per-module parallel compilation for development builds, "due to LLVM scaling O(N^2) with the size of module". | V |
| 2021-11-06 | Fork, `src/llvm_backend_opt.cpp`, header comment "IMPORTANT NOTE(bill, 2021-11-06)" | Lists LLVM passes that "CANNOT be used by Odin" (CVP, InstCombine, IndVarSimplify, LoopUnroll, EarlyCSE-MemSSA, GVN, DSE). Reason: "Odin does not allow poison-value based optimizations." Odin defines `*`-flowing behaviour as 2's complement wrapping. | V |
| 2020-10-27 | Odin issue #764, "Replace inline and no_inline ... with #force_inline and #force_no_inline" (gingerBill) | "People do not realize that inline and no_inline are not hints but forced requirements." | V |
| 2021-07-05, 2021-09-06 | "The Value Propagation Experiment" parts 1 and 2 | Feature was removed, then kept as `or_return`. Bill: "It's a question of whether you are optimizing for reading or typing, and in Odin, it has usually been reading." | S |
| 2024-11-04 | Forum thread #221, "Is it true that Odin can't be as fast as Zig/Rust ...", post under the gingerBill account | "My philosophy for Odin was that you want to opt-in to the generally unsafe 'optimizations' (when possible) rather than them be opt-out". The same thread says Odin disables LLVM passes "because they either don't fit Odin's model, or rely on some sort of UB". I could not confirm which post carries each sentence. | V |
| 2026 (merge date per D01) | PR #6483, "Remove Tilde Backend", merged by gingerBill from `bill/remove-tilde` | The Sea-of-Nodes backend by Yasser Arguelles Snape was removed from Odin. | V (title, merge); date D01 |
| 2019 (goals) | Handmade Network, "Odin Goals for 2019" | "To replace LLVM as the default backend (but also support LLVM too)". | S |
| 2019-02 to 2021-12 | "Memory Allocation Strategies" series, gingerbill.org/series/memory-allocation-strategies/ | Parts 1-6: arena, stack, pool, free list, buddy. Part 1 gives a size/lifetime table where "Size Known + Lifetime Known" is about 95% of allocations. | S |

Not found in two searches each: gingerbill.org articles titled "Why not LLVM", "Odin and the compiler", "Value-based vs Type-based", and "Data-Oriented Design". The closest matches are the 2017 backend post and the 2019 Zig reply [D01]. Talk transcripts (Handmade, Better Software) were not read in this pass.

### A2. The optimization stance, as the sources state it

Three rules come out of the sources. They are Bill's stated intent, so they outrank our own preferences under `AGENTS.md`.

1. Odin's semantics are defined, so the compiler may not use C-style undefined behaviour as an optimization license. The fork's header comment says so directly [V], and the 2024 forum post says the same about opt-in unsafe optimizations [V].
2. Unsafe or fast-math behaviour is opt-in and written in the source. The fork implements this as the `@(fast_math=...)` attribute with seven flags: Allow_Reassoc, No_NaNs, No_Infs, No_Signed_Zeros, Allow_Reciprocal, Allow_Contract, Approx_Func (`src/checker.cpp:4849-4857`, `src/llvm_backend_opt.cpp:63-75`) [V]. The default is no flags.
3. Control flow that the programmer must see is explicit. `#force_inline` is a forced request, not a hint [V, issue #764], and `or_return` replaced a hidden-looking `try` [S]. The FAQ says Odin "has been optimized for the reader of code more than the writer of code" [V].

The fork confirms that the LLVM backend emits no `nsw`, `nuw` or poison flags. A grep of `src/llvm_backend*.cpp` finds them only in the header comment [V].

### A3. Flags and directives that affect optimization or checks

| Flag or directive | Effect | Evidence |
|---|---|---|
| `-o:none` | No optimization. Default when `-debug` is set. | fork `src/main.cpp:3424-3434` [V] |
| `-o:minimal` | Default when not debugging. | same [V] |
| `-o:size`, `-o:speed` | Size/speed modes. `-o:size` adds `optsize` to every procedure. | `src/llvm_backend_proc.cpp:254-262` [V] |
| `-o:aggressive` | Documented as "use this with caution". | `src/main.cpp:3433` [V] |
| `-no-bounds-check` | Disables bounds checks program-wide; defines `ODIN_NO_BOUNDS_CHECK`. | `src/main.cpp:3373`; docs/overview [V] |
| `#no_bounds_check`, `#bounds_check` | Scope the policy to a statement, block or procedure. | odin-lang.org/docs/directives [V] |
| `-disable-assert` | No code for `assert`; defines `ODIN_DISABLE_ASSERT`. | `src/main.cpp:3124` [V] |
| `#force_inline`, `#force_no_inline` | Forced. "If the compiler cannot inline the procedure, it will (currently) silently ignore the directive." Conflict with `#force_no_inline` is an error. Target-feature conflict is an error at file scope. | docs/directives [V]; `src/check_expr.cpp:9923, 9993`; `lb_add_callsite_force_inline` in `src/llvm_backend.cpp:451` [V] |
| `@(fast_math=...)` | Opt-in FP flags (see A2). | `src/checker.cpp:4849`; `src/llvm_backend_opt.cpp:63` [V] |

### A4. What this means for our SoN backend

Allowed, inside the stated philosophy:

- Constant folding and algebraic identities whose result is exact under 2's complement wrapping. Our interpreter's scalar code is the oracle for this (`src/ir/interp_scalar.odin`).
- Removal of pure, non-trapping nodes that have no users. `FDiv` is `.Pure` in `src/ir/kinds.odin:341` [V].
- Common subexpression elimination and interning of pure nodes. This already exists (`src/ir/intern.odin`). Loads may not be merged across stores; the single memory chain is the guard.
- Constant rematerialization, which exists (`src/ir/builder.odin:78-94`).
- Floating-point reassociation or contraction only when the user writes the matching `fast_math` attribute.
- Explicit `#force_inline`, honored. Automatic inlining is allowed only if it changes no observable behaviour and does not override `#force_no_inline` [inference from A2 and issue #764; no Bill quote on automatic inlining found].

Contradicts the stated philosophy:

- Any rule that needs an `nsw`/`nuw` or poison assumption, for example `x + 1 > x` becoming true for signed `x`.
- Default FP identities. `x + 0.0 -> x` is wrong for `x = -0.0`, and `x * 0.0 -> 0.0` is wrong for NaN and infinity. This is standard IEEE 754 [U, no source cited here]. Only the opt-in attributes can allow these.
- Dropping a trap-capable operation because its result is unused. `SDiv` and `UDiv` are `.Pinned` with a control input (`src/ir/kinds.odin:324-325`), so this is already excluded. Keep it that way.
- Copying the InstCombine/GVN/EarlyCSE rule set. The fork excludes those passes for exactly the UB reason above [V]. Our rule table must be written from Odin's semantics, not from LLVM's pattern list.
- Removing or weakening `assert`, bounds checks or any check under an `-o:` level. These are build policy (flags and directives), not optimizer decisions.
- Hidden control flow. I found no Bill quote using the words "hidden control flow". The closest statements are the forced-directive text and the `or_return` history above [V/S].

Overflow example to keep in mind: the classic `(x * 2) / 2 -> x` from the egg paper, which Fallin's blog discusses as a running example, is not valid for wrapping integers. Any rule of that kind needs a no-overflow precondition, and Odin has none [inference from A2].

### A5. Guarantees to preserve when hoisting or eliminating bounds checks

These come from the official docs, the fork, and our lowering. "Our code" references are to the current tree.

1. **Policy comes first.** A check exists only where its `check.Bounds_Plan.policy` is `Enabled` (`src/lower/lower_bounds.odin`, `lower_index_address`). `#no_bounds_check` and `-no-bounds-check` set the policy in the checker. An optimizer may drop a check only when the policy is `Disabled`, or when the check provably passes on every path that reaches it. Constant out-of-range indices are a compile-time error, not a runtime check [V, overview].
2. **Same length value.** The check compares against the length used by the access at that point. When the length is loaded from a slice, dynamic array or string header in memory, hoisting the check or the load is valid only when the memory state is the same. In our IR that means the same memory chain value (`lower_check` and `lower_header_parts` in `src/lower/lower_bounds.odin`).
3. **Same width and sign.** The index is widened to `I64` with `Sext` or `Zext` based on the index type before the compare (`lower_index_address`, around line 53). The compare is unsigned (`.ULt`). A rule must not turn `ULt` into a signed compare, drop the extension, or narrow the index, because a negative index must fail.
4. **128-bit indices.** With checks enabled, a non-zero high word is out of bounds (`lower_index_address` in `lower_bounds.odin`). The rule must keep this.
5. **Enumerated arrays.** The lower bound is subtracted before the check (`lower_index_address`, `.Sub`). The subtraction wraps, and the unsigned compare then fails. Keep this order.
6. **Trap ordering.** A check traps at its access. Moving a check above a store, a call, or any node that writes output changes what the program has done when it fails. Hoisting is therefore limited to nodes that carry no effect between the old and new position.
7. **Proof per use.** The fork marks a check as proven only when every analysed use passed (`src/check_escape.cpp`, near line 5160, flag `StateFlag_bounds_check_proven`), and the LLVM backend reads that flag to skip the check (`src/llvm_backend_expr.cpp:5333`) [V]. The proof is made in the front end, before lowering. Our equivalent should be recorded per node, so that a check is removed only with a recorded reason.
8. **Failure output.** Our `lower_check` emits `ir.emit_trap` (`src/ir/builder_control.odin:346`). I did not verify the official runtime's panic text and exit path in this pass [U]. Until that parity is checked, do not hoist checks in a way that changes which panic a program reports.

## Part B: e-graphs, ISLE and Cranelift

### B1. The aegraph design

Chris Fallin's 2026-04-09 post, "The acyclic e-graph: Cranelift's mid-end optimizer", describes the current design [V, cfallin.org/blog/2026/04/09/aegraph/]. Its key points:

- Pure operators leave the CFG skeleton and float in a sea of nodes. They are deduplicated by hash-consing as they are created. Demand-driven elaboration then removes dead pure nodes "for free" [V].
- Rewrites run at node creation. The post's recipe is `inst = rewrite(inst)`, then hash-cons on the final version. Chained rules fire recursively: rewriting `~(a & b)` makes `~a | ~b` in one pass [V].
- Multiple rewrite results per value (union nodes, e-classes) are kept for cost-based extraction. The post calls this "true aegraph" and reports that it adds little in practice (B3) [V].
- Full equality saturation was rejected. The RFC gives the reasons: parent pointers for full canonicalization are expensive, and "blowup" makes the e-graph large [V, RFC "cranelift-egraph.md"].
- Optimization fuel limits rewrite steps overall, and possibly per rule or per e-class. The RFC lists this as necessary to stop the search from running for exponential time [V].

The RFC is "Cranelift: Using E-Graphs for Verified, Cooperating Middle-End Optimizations" (github.com/bytecodealliance/rfcs, accepted, PR #27) [S for the title and PR; body read in V]. It also says the rewrite rules were meant to be written in ISLE, driving rewrites through ISLE-generated Rust, with a "Minimal ISLE Change: Multi-Extractors and Multi-Constructors" [V].

ISLE is Cranelift's instruction-lowering DSL (github.com/bytecodealliance/wasmtime/tree/main/cranelift/isle) [S]. The rewrite rules Cranelift keeps are in `cranelift/codegen/src/opts.rs` [S]. Both are Rust. Our compiler is Odin, so the rule language would be an Odin table or a new Odin DSL, not ISLE.

### B2. The argument for why rules replace hand-written peepholes

The RFC's case: hand-written transforms in LLVM's InstCombine were checked by the Alive tool, which "found 8 bugs in 334 hand-coded transforms (2.4%)" [V, RFC]. Declarative rules are easier to read and easier to check. The survey's Souper and Alive2 references (`05`, section 3) address validation; I did not re-verify their overhead numbers here [U].

### B3. Numbers the sources report (attributed; not reproduced as ours)

- Cranelift, full aegraph pipeline against the classical pipeline on the Sightglass suite: "about 7-8% more compile time". The post says the first 2023 aegraph build "was more or less at parity" [V, blog 2026].
- Moving from sea-of-nodes-with-CFG to the true aegraph with cost-based extraction: about 0.1% difference in execution time (blog) [V].
- Average e-class size after rewriting: 1.13 e-nodes. Across about 4 million value nodes in the benchmark corpus, two cases had more than one option, both in SpiderMonkey compiled to Wasm (blog) [V].
- The blog says early overhead was mostly cache misses from copying IR into an e-graph. The fix was to make the existing IR an implicit e-graph [V].
None of these numbers measure our backend. They tell us the order of cost to expect: an eager rule table is cheap; a saturating search is not.

### B4. Fit with our graph

Our graph already has the core of an aegraph's eager mode:

- `interned_node` (`src/ir/intern.odin:13`) is the single choke point for pure nodes. Its key is kind, type, inputs and data, the same shape as Cranelift's hash-consing key (`intern_key_equal` in `intern.odin`).
- A rule can therefore run immediately before `interned_node` and intern its result. This is the "hash-cons the final version" recipe [V on both sides].
- Users are recorded in a flat list ordered by user id and slot (`src/ir/graph.odin:85-89`, `uses`) [V]. A worklist can find affected users without maintaining parent pointers.

Where we differ from the aegraph:

- Our graph mutates after creation. `set_input` (`src/ir/builder_control.odin:296-298`), `loop_collapse` (`:307`), and `remove_node` (`:333-335`) change inputs of existing nodes. `intern_rebuild` (`intern.odin:76`, called from `builder_control.odin:336`) rebuilds the table. The file header says a stale slot "only costs sharing, never correctness". Rules that already fired on the old inputs will not see the new ones unless we re-run them. That is what the worklist in stage S3 is for.
- Cranelift takes SSA input. We build SSA incrementally from a checked program, and `lower` builds the graph directly.
- Our scheduler is global code motion (`src/sched/order.odin`), which plays the role of the aegraph's elaboration.

We already have a validator the survey asks for: the interpreter (`src/ir/interp*.odin`). Each rule can be checked by evaluating both sides on the same inputs. This is differential testing, not proof, and it is much cheaper than Alive2-style checking.

Our current folding is minimal. The builder comment at `src/ir/graph.odin:130` says `add_node` "Never folds, interns or checks input types; that is the builder's and the verifier's job." I found no folding or peephole code under `src/ir` or `src/lower` (grep for `fold`, `peephole`, `identity`) [V]. The rule table would be new code, not a replacement.

## Part C: Staged adoption plan

Effort: S is under a day, M is a few days, L is a week or more. Each stage ends with the verifier (`src/ir/verify.odin`) and the interpreter differential run.

| Stage | Work | Files (current tree) | Effort | Exit test |
|---|---|---|---|---|
| S0 | Baseline: node counts, interned-hit counts, compile time on the existing corpus, using `odinc --histogram` and timing | none (measurement only) | S | Numbers recorded in a doc |
| S1 | Constant folding and integer identities (`x+0`, `x*1`, `x&0`, `x^x`, `x-x`, shift by 0, constant compares) for wrapping integers only, applied before `interned_node` | new `src/ir/simplify.odin`; edits in `src/ir/builder.odin` (binary and compare constructors) | M | One differential test: rule output equals interpreter result on sample values |
| S2 | Bounds checks with constant operands: fold `ULt` against constant lengths, but only where the plan policy allows and A5 holds | `src/lower/lower_bounds.odin`; `src/ir/builder_control.odin` | S | Existing `lower_bounds_test.odin` passes; a constant-index case folds |
| S3 | Worklist: after `set_input`, `loop_collapse`, `remove_node`, re-run the rules on the affected users, with a per-function fuel counter | `src/ir/builder_control.odin`; `src/ir/graph.odin` (`uses`, `remove_node`); `src/ir/intern.odin` (`intern_rebuild`) | M | Loop-collapsed phis fold; fuel limit stops a deliberately cyclic rule set |
| S4 | Validation harness: run every rule through the interpreter on a random corpus at each stage | `src/ir/interp_test.odin` pattern; new test file alongside `simplify.odin` | S | Passes under `mise run test` with no output |
| S5 | Union nodes and cost-based extraction | `src/ir/graph.odin`; `src/sched/order.odin` | L | Defer. Start only if S3 shows missed rewrites that matter |
| S6 | Offline rule synthesis (Souper-style) or bounded proof for integer rules | out of tree | L | Reference study only |

S1 and S3 can be reviewed separately. The rule table should stay small: the integer identities above, nothing that needs an overflow precondition.

## Part D: Avoid

- Full egg-style equality saturation or an unbounded e-graph (L; RFC and blog).
- `nsw`, `nuw`, poison, or any rule that assumes overflow is undefined (fork header; A2).
- Default floating-point identities such as `x + 0.0 -> x` or `x * 0.0 -> 0.0`. Only behind `fast_math` attributes.
- Porting InstCombine, GVN, EarlyCSE or DSE patterns. The fork excluded them for UB reasons (A4).
- Removing or moving any check across an effect, or changing an enabled check by optimizer decision (A5).
- Treating `-no-bounds-check`, `#no_bounds_check`, or `-disable-assert` as optimizer inputs. They are build policy.
- Dropping `SDiv` or `UDiv` because the result is unused. They are pinned.
- A new rule DSL before S1 is measured. ISLE is Rust; an Odin table is enough to start.
- Adding a trap-to-panic change or any other observable panic-text change without checking the official runtime output (A5, item 8).
- Relying on the interpreter alone for rules that touch memory or traps. The interpreter checks values, not ordering against effects.
- Taking the Cranelift overhead numbers (B3) as predictions for our graph.

## Open questions for the owner

1. Is wrapping 2's complement the only integer semantics for constant folding, including shifts by amounts at or beyond the width? I assumed yes; the interpreter's behaviour should be the reference.
2. What is the official runtime's output and exit status for a failed bounds check? Our `lower_check` emits a trap. Parity affects A5 item 8, and it must be settled before hoisting.
3. Should S2 bounds elimination be a front-end proof, as the fork does (`check_escape.cpp`), or an IR-level proof recorded per node? The first matches upstream; the second is closer to our graph.
4. What compile-time budget do we accept for S1? Cranelift reports 7-8% for its whole mid-end. We have no baseline yet, so S0 comes first.
5. Do we want the `@(fast_math=...)` attribute implemented in this compiler, and when? Without it, no FP rewrite is allowed.
6. Are golden IR dumps and the deterministic printer expected to change when S1 adds folding? That affects how we review the stage.
7. Should the Tilde backend stay a reference only (as `docs/01-architecture.md` now says), or do we track Yasser Arguelles Snape's later work for SoN passes? Not checked in this pass.

## Sources

- Odin directives: https://odin-lang.org/docs/directives/ [V]
- Odin overview: https://odin-lang.org/docs/overview/ [V]
- Odin FAQ: https://odin-lang.org/docs/faq/ [V, partly; D01 for the design-principles quote]
- Odin issue #764: https://github.com/odin-lang/Odin/issues/764 [V]
- Odin issue #891: https://github.com/odin-lang/Odin/issues/891 [V]
- Odin PR #6483: https://github.com/odin-lang/Odin/pull/6483 [V]
- Forum thread #221: https://forum.odin-lang.org/t/is-it-true-that-odin-cant-be-as-fast-as-zig-rust-because-all-llvm-optimizations-arent-possible/221 [V]
- "Working on a Custom Backend for Odin" (2017): https://odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin [V]
- "Odin Goals for 2019": https://odin.handmade.network/blog/p/3615-odin_goals_for_2019 [S]
- "The Value Propagation Experiment" and Part 2: https://www.gingerbill.org/article/2021/07/05/value-propagation-experiment/ and https://www.gingerbill.org/article/2021/09/06/value-propagation-experiment-part-2/ [S]
- "Memory Allocation Strategies" series: https://www.gingerbill.org/series/memory-allocation-strategies/ [S]
- Fork sources: `src/llvm_backend_opt.cpp` (header and lines 63-75), `src/main.cpp` (3124, 3373, 3424-3434), `src/checker.cpp` (4849-4857), `src/check_expr.cpp` (9923, 9993), `src/check_escape.cpp` (5150-5170), `src/llvm_backend_expr.cpp` (5333), `src/llvm_backend_proc.cpp` (254-262) [V, local]
- Chris Fallin, "The acyclic e-graph: Cranelift's mid-end optimizer" (2026-04-09): https://cfallin.org/blog/2026/04/09/aegraph/ [V]
- Cranelift e-graph RFC, "Cranelift: Using E-Graphs for Verified, Cooperating Middle-End Optimizations": https://github.com/bytecodealliance/rfcs/blob/main/accepted/cranelift-egraph.md (PR #27: https://github.com/bytecodealliance/rfcs/pull/27) [V, body; S, PR]
- Fallin, "ægraphs: Acyclic E-graphs for Efficient Optimization in a Production Compiler" (EGRAPHS 2023): https://pldi23.sigplan.org/details/egraphs-2023-papers/2/-graphs-Acyclic-E-graphs-for-Efficient-Optimization-in-a-Production-Compiler and slides https://cfallin.org/pubs/egraphs2023_aegraphs_slides.pdf [S]
- `cranelift_egraph` crate docs: https://docs.rs/cranelift-egraph/latest/cranelift_egraph/ [S]
- ISLE: https://github.com/bytecodealliance/wasmtime/tree/main/cranelift/isle and https://github.com/bytecodealliance/wasmtime/blob/main/cranelift/isle/docs/language-reference.md [S]
- Cranelift rules: https://github.com/bytecodealliance/wasmtime/blob/main/cranelift/codegen/src/opts.rs [S]
- Souper: https://arxiv.org/abs/1711.04422 [S]
- Alive2: https://dl.acm.org/doi/10.1145/3453483.3454030 [S]
- Local code: `src/ir/intern.odin`, `src/ir/graph.odin`, `src/ir/builder.odin`, `src/ir/builder_control.odin`, `src/ir/kinds.odin`, `src/ir/interp*.odin`, `src/lower/lower_bounds.odin`, `src/sched/order.odin` [V, local]
