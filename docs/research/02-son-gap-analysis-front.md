# Sea-of-Nodes gap analysis, front half: Simple ch 2–13 and SCCP against our IR, lowering and scheduling

Status: read-only audit, written by the research agent at the orchestrator's request. Back-end half (instruction selection, regalloc, amd64) is owned by a separate document and is not covered here.

Reference: `/home/su3h7am/Projects/refs/compilers_linkers/Simple`, chapters 2–13, `chapter-sccp`, `chapter-interprocedural-sccp`.

Our code: `/home/su3h7am/Projects/odin-compiler/src`. Every `file:line` below was read in this session. Claims marked **[unverified]** rest on a name, a grep hit or a test title, not on the body of the code.

## Reading coverage

Chapter bodies read in full or by section: ch 2 (peephole and constant-folding sections), ch 3 ("Enabling peephole optimizations" only), ch 4 (projection nodes and dead-code elimination), ch 5 (phi push-through), ch 6 (if peepholes and dominators, in part), ch 7 (back edges), ch 8 (lazy phis), ch 9 (engineering peepholes, iterative peepholes, GVN, distant neighbours), ch 10 (one memory value, memory as SSA variable, null analysis, local memory optimizations), ch 11 (why split, equivalence-class aliasing, splitting memory phi, evaluation and ordering), ch 13 (overview, early and late schedule, loop depth), both SCCP READMEs.

Headings only: ch 12 (references). Not read: ch 2 "Nodes Pre Peephole Optimization" body, ch 3 "Symbol Tables" and "ScopeNode" bodies, ch 4 "$ctrl name binding" and the body of "More Peephole Optimizations".

## 0. Our graph in brief

A node is `Node` with a `kind`, a flat `type: Value_Type`, `flags`, an input range in a shared `edges` array, and an 8-byte `data` union (`src/ir/graph.odin:52-59`). The per-function state lives in `Function` (`graph.odin:62`), including `linkage` (`graph.odin:65`).

Pure kinds are constructed through `interned_node` (`src/ir/intern.odin:13-33`), which hash-conses. Pinned kinds go through `add_node` directly (`src/ir/builder.odin:171-178`, `:181-199`). Constructors never fold; `add_node` says so explicitly (`graph.odin:130`).

Control, variables and memory are tracked by `Builder` (`src/ir/builder_control.odin:31-39`). Variable 0 is the single memory state (`builder_control.odin:18`).

Lowering calls these constructors directly. `lower_if` and `lower_for` drive them (`src/lower/lower_control.odin:101-130`, `:199-240`).

Scheduling is one function, `order` (`src/sched/order.odin:36-119`).

## 1. Ch 2 — arithmetic, peephole at construction, constant folding, type lattice

**Simple.** Peepholes run at parse time, before a new node is installed. `Add(1,2)` becomes `3`, and the unused inputs are killed. Constant propagation needs a lattice on each node's type: ⊤ (maybe constant), constants, ⊥ (not constant). The type annotates every node.

**Ours.** `binary` only canonicalises commutative operand order and interns (`src/ir/builder.odin:104-114`). `compare` does the same for comparisons (`builder.odin:135-145`). `unary`, `convert` and `select` intern without looking at constants (`builder.odin:126-132`, `:148-154`, `:156-161`). `const_int` canonicalises the value to its width (`builder.odin:64-79`).

Odin-level constant expressions are folded earlier, in the checker. The test name `constant_operators_fold_and_intern_results` (`src/check/constants_test.odin:62`) is the only evidence I read for that **[unverified body]**.

Lowering emits runtime arithmetic with constant operands without folding. Examples: `lower_abi_memory.odin:28-29` (shift and or with a constant offset) and `lower_bounds.odin:71` (enumerated-array subtract of `lower_bound`).

There is no type lattice. `Node.type` is one `Value_Type` (`graph.odin:52-59`).

**Gap.** No construction-time or pass-time folding of pure operations whose inputs are `Const_Int` or `Const_Float`. Also no algebraic identities (`x+0`, `x*1`, `x<<0`), which Simple ch 15 lists as peepholes.

**Sketch.** Start with `builder.binary`, `compare` and `convert`. When every input is a `Const_Int` (or `Const_Float`), compute the result with the width rules that `const_int` applies (`builder.odin:64-79`) and return `const_int` instead of interning a new node. Leave `Div`, `Rem` and `Mul_Hi` alone for now, because the pinned division kinds are separate nodes (`kinds.odin`, `SDiv`–`URem`).

Ordering: this runs during lowering, before `order`, so it needs no separate pass. A later iterative driver (section 8) can reuse the same fold function.

**Risks and tests.** Wrap-around and sign rules must match the interpreter `src/ir/interp*.odin`, which is already the test oracle. Test: a differential test that builds a small arithmetic function, evaluates it with the interpreter before and after folding, and checks the same result and the same printed `ir` text. Effort: **S** for `binary` and `compare` only; **M** with unary, convert and identities.

## 2. Ch 3 — variables, scope, and killing unused nodes

**Simple.** Variables live in a `ScopeNode`. The peephole machinery kills a node when its use count drops to zero, so the parser cleans up as it goes.

**Ours.** Variables are a flat array `Builder.values` (`builder_control.odin:31-39`). `variable_declare`, `variable_get` and `variable_set` are at `builder_control.odin:90-107`. `variables_truncate` ends a scope (`builder_control.odin:110-114`).

We track no use counts during construction. `remove_node` is used only by `loop_collapse` (`builder_control.odin:333-335`) and tests (`src/ir/graph.odin:226`).

Unused pure nodes stay in the arena and are dropped only at scheduling (section 12).

**Gap.** There is no fine-grained kill. Dead values stay in memory until `order`. This costs arena space and compile time, not run time.

**Sketch.** Keep a use counter per node in `Function`, updated by `add_node` and `set_input`. Make `remove_node` recursive when a counter reaches zero for a pure node. This only matters once section 1 folds exist, because folding is what creates dead nodes.

**Risks and tests.** Pinned nodes must never be killed on zero uses, because `Store` and `Call` carry effects, and `Load` is pinned too (`kinds.odin:363`), so the same rule applies to all three. Test: count nodes in `ir/print` goldens before and after a fold. Effort: **S–M**.

## 3. Ch 4 — projections, `$ctrl`, DCE

**Simple.** Multi-result nodes are read through `Proj` nodes. The chapter adds more peepholes and a kill-based DCE: a node that loses its last user is killed immediately.

**Ours.** Tuple results are read through `Proj`. `start` builds `Proj` for control, memory and each parameter (`builder.odin:43-61`). `if_` returns a `Proj` pair (`builder.odin:202-207`). A `Call` returns a tuple whose member 0 is memory (`kinds.odin:401`, `builder.odin:181-199`).

Dead-code elimination happens only in `order`. A floating value with no reachable use gets no block and is not emitted (`src/sched/order.odin:173-183`, and the members list built from `placement` at `order.odin:78-83`).

A dead pinned node is always placed (`order.odin:59-61`), so an unused `Load` or `Call` is kept.

**Gap.** No kill-on-zero-uses. No DCE for pinned nodes whose effects are unobservable (for example a `Load` with no users, which is always removable because loads have no side effects **[unverified]** in the official semantics for `volatile`).

**Sketch.** A pure-node-only kill at construction is covered by section 2. A pinned-node DCE would need `Memory_Order` (`graph.odin:7-15`) to rule out `Volatile` and atomic orders and would rewire the memory chain: this is M and should wait for section 10.

**Risks and tests.** Removing a `Load` changes the memory chain only if we keep the state edge. Test: an interpreter run with and without the dead load on a program that reads through a volatile pointer. Effort: **M**.

## 4. Ch 5 — if, region and phi; phi peepholes and push-through

**Simple.** `Region` and `Phi` merge control and values. A `Phi` with identical inputs collapses. A peephole pushes an operation up through a phi (`phi(a+1, b+1)` becomes `phi(a,b)+1`) so that constants can fold.

**Ours.** Merge phis are built only where the exits differ (`src/ir/builder_control.odin:186-196`, the `differs` check). Equal merges reuse the value directly (`builder_control.odin:192-194`). This is the trivial-phi elimination at merges.

Loop phis are not checked. `loop_end` writes the back-edge input unconditionally (`builder_control.odin:296-299`).

There is no push-through. `Phi` construction is `builder.odin:214-232`.

**Gap.** No push-through, and no trivial loop-phi elimination except the no-back-edge case in `loop_collapse` (`builder_control.odin:307-337`).

**Sketch.** At `loop_end`, for each loop phi, if the back-edge input equals the phi itself or equals the entry input, substitute it using the same `substitute` walk as `loop_collapse` (`builder_control.odin:319-331`). Push-through is a separate peephole that belongs with section 9.

**Risks and tests.** Memory phis must not be removed unless both inputs are the same state. Substitution rewrites interned nodes, so `intern_rebuild` (`src/ir/intern.odin:76-96`) must run afterwards, as `loop_collapse` already does. Test: a loop that never changes a variable must produce no phi for it in the `ir/print` golden. Effort: **S** (trivial phis), **M** (push-through).

## 5. Ch 6 — if peepholes, dominators, constant predicates, dead arms

**Simple.** A constant predicate makes one arm dead, and the dead arm is killed. A branch whose predicate is implied by a dominating branch is folded. This needs a dominator tree.

**Ours.**

Constant predicate, literal case only. `lower_if` checks whether the condition node is a `Const_Int` and, if so, lowers only the taken arm and never builds an `If` node (`src/lower/lower_control.odin:112-119`). This is correct for literal `if true`/`if false`.

Constant predicate, derived case: not handled. Bounds checks always branch on a compare node: `lower_check` calls `branch_if` (`src/lower/lower_bounds.odin:9-14`), and `lower_index_address` builds `compare(ULt, offset, length)` (`lower_bounds.odin:95`). When the index and length are both constants, the compare is still built as a node (`builder.odin:135-145` never folds). The result is an `If` with a constant predicate **[unverified: that `lower_expr.odin:105` lowers a `Const_Id` index to `Const_Int`]**.

`for` conditions are never folded (`lower_control.odin:224-231`).

Dominators exist. `build_control_skeleton` computes `idoms` (`src/ir/cfg.odin:111`, `:166`) and `common_dominator` uses them (`src/sched/order.odin:205-216`). Nothing uses dominance to fold a branch.

Dead control: `jump_to` ignores a control of `NODE_NONE` (`builder_control.odin:135-149`). The CFG is walked only from entry, so unreachable blocks are never in it (`src/ir/cfg.odin:118-156`).

**Gap.** (a) A branch on a compare of two constants is kept. (b) A branch dominated by an identical condition is kept. (c) A dead arm of a non-literal branch is kept.

**Sketch.** (a) In `builder_control.branch_if`, if the condition is a `Const_Int`, do not add an `If`. Return a `Branch_Point` whose taken arm is the current control and whose other arm is `NODE_NONE`. `enter_arm` on `NODE_NONE` already leaves code unreachable (`builder_control.odin:244-254`). This needs constant compares to fold first (section 1). Files: `builder_control.odin`, `builder.odin`.

(b) Dominating-condition elimination is an IR pass over the CFG. Walk the dominator tree from entry, record each `If`'s outcome for its condition node, and at a dominated `If` on the same condition replace the branch. Replacing a branch removes an arm, so the merge phis below it lose an input. `set_input_count` (`graph.odin`, shrinks in place) handles that. Files: a new `src/ir/fold_branch.odin`, `cfg.odin` (idoms).

(c) Non-literal dead arms follow from (b) and from the SCCP in section 13.

**Risks and tests.** Removing an arm changes Region input order, so every phi on that Region must drop the same input, or the verifier fails (`src/ir/verify_control.odin`, not read in full **[unverified]**). Test: golden `ir/print` output for `if true`, for `x < x`, and for a repeated bounds check; differential interpreter run. Effort: **S** for (a), **M** for (b).

## 6. Ch 7 — while statements and back edges

**Simple.** A `while` becomes a `Loop` whose back edge is filled after the body. Variables get phis at the loop head, which are cleaned up later.

**Ours.** `loop_begin` creates a `Loop` with an unset back edge and one phi per assigned variable, plus memory (`src/ir/builder_control.odin:258-282`). `loop_end` sets the back edge and each phi's back value (`builder_control.odin:287-301`).

The assigned set is a syntactic pre-scan of the body and post statement (`src/lower/lower_control.odin:206-217`; scanner `:150-182`). Memory is always a phi (`builder_control.odin:270-277`).

`lower_for` lowers the condition with `branch_if`, sends the false arm to `end`, and continues in the true arm (`lower_control.odin:224-231`). `continuation` is sealed before `post` (`lower_control.odin:235-236`). `end` is sealed after `loop_end` (`lower_control.odin:238-239`).

**Gap.** Loop phis are never removed when unused (see section 4). A phi whose only users are other dead phis is still placed and scheduled. `order` places every non-floating phi (`src/sched/order.odin:59-61`), so it survives to regalloc **[unverified: that regalloc gives it a live interval and back-edge copies, not read]**.

**Sketch.** Add a dead-phi pass after `loop_end`: count users of each phi excluding self-references and other dead phis, and remove those with no users (`remove_node`, `graph.odin:226`), then `intern_rebuild`.

**Risks and tests.** Memory phis are needed if any store or call sits in the loop. Test: a loop body with no assignments emits no loop phi for an unchanged variable. Effort: **S**.

## 7. Ch 8 — lazy phis, break and continue, evaluator

**Simple.** Phis are created on first read inside the loop head scope, which avoids unnecessary phis. `break` and `continue` are jumps to scope-named targets. An evaluator runs the graph.

**Ours.** Phis are eager, not lazy, and are based on the syntactic pre-scan (section 6). `break`, labelled `break` and `continue` go through jump targets (`builder_control.odin:116-149`). A labelled block gets its own `end` target (`src/lower/lower_control.odin:90-98`). `for` gets `end` and `continuation` targets (`lower_control.odin:216-223`).

The evaluator is `src/ir/interp.odin` with `interp_call.odin`, `interp_memory.odin`, `interp_scalar.odin` and `interp_float.odin`, used by tests (`src/ir/interp_test.odin`).

**Gap.** Eager phis cost compile time and a few extra phis; lazy phis would remove the dead ones from the start. Section 6 gets most of the benefit.

**Sketch.** Lazy phis would mean hooking `variable_get` (`builder_control.odin:101-103`) to create a phi in the innermost loop head when a variable is first read there, and that needs a per-loop read set. This is **L** for little run-time benefit once dead phis are removed. Recommend against it for now.

**Risks and tests.** Lazy phi creation is easy to get wrong with nested `if`s inside loops, because a phi must go in the innermost loop head scope (Simple ch 8). Test if ever built: nested loops with a variable read only inside the inner loop. Effort: **L**.

## 8. Ch 9 — GVN and iterative peepholes

**Simple.** GVN hashes opcode and inputs into a global table, so equal pure nodes share. Peepholes are iterated with a worklist to a fixpoint. "Distant neighbours" keep dependency lists so that a changed node re-triggers the nodes that depend on it.

**Ours, GVN.** Yes, for pure kinds. `interned_node` (`src/ir/intern.odin:13-33`) hashes kind, type, inputs and the data fields that the kind defines (`intern.odin:124-144`), and compares the same fields (`intern.odin:149-174`). Commutative operands are ordered (`builder.odin:110-112`, `:141-143`). Constants and symbol addresses share through the same table (`builder.odin:64-95`).

Pinned kinds are not hashed. `load`, `store` and `call` use `add_node` (`builder.odin:171-199`).

**Ours, worklist.** None. There is no rewrite driver. After `loop_collapse` the table is rebuilt (`builder_control.odin:336`, `intern.odin:74-96`), and the comment at `intern.odin:74-75` says duplicates created by a rewrite stay separate.

**Gap.** (a) Plain loads with the same control, memory state, pointer, type and alignment are the same value and are not shared. (b) No worklist, so no fixpoint once rewrites exist.

**Sketch.** (a) Intern plain `Load` nodes. The key is (control, memory, pointer, type, align) and nothing else, which is correct because the memory state is an SSA value. Exclude `Load_Ordered`, and exclude any `Access_Info` whose order is not `Plain` (`graph.odin:7-15`). Files: `builder.odin:171-173`, `intern.odin` (the hash and key functions must learn the `Load` case). Effort **S**. Verified only by reading; the volatile policy is **[unverified]** against the official semantics.

(b) An iterative driver is **M**. It runs after `lower` and before `order`: a worklist of users of changed nodes, `set_input` and `remove_node` as the rewrite primitives, `intern_rebuild` at the end. It is useful only once sections 1, 4 and 5 exist.

**Risks and tests.** Loads sharing across a `Store` is the classic bug, and the key rules that out only because the store changes the memory state. Test: `p.x + p.x` with no store between must print one `load`; with a store between, two. Effort: (a) **S**, (b) **M**.

## 9. Ch 10 — structs and memory; memory as one SSA value; local memory optimizations

**Simple.** Memory is one SSA value. A store consumes the previous memory and produces the next. A load consumes memory without changing it. A load right after a store to the same pointer can return the stored value.

**Ours, memory.** One state, variable 0 (`builder_control.odin:18`). Merges and loops phi it like any variable (`builder_control.odin:186-205`, which iterates over every variable including 0; `:270-277`). `Load` takes `{control, memory, pointer}` (`src/ir/kinds.odin:363`, `builder.odin:171-173`). `Store` takes `{control, memory, pointer, value}` and returns memory (`kinds.odin:375`, `builder.odin:176-178`). The verifier checks memory consistency along paths (`src/ir/verify_memory.odin:3`).

**Ours, forwarding.** None found. I grepped `src/ir`, `src/lower` and `src/sched` for `forward`, and only tests matched **[unverified: body of `lower_load.odin` not read]**.

**Ours, null analysis.** None. There is no non-null pointer type in the IR (`Value_Type` is flat, `graph.odin:52-59`). Odin has no non-nullable pointer type either **[unverified]**, so the Simple ch 10 analysis has no direct equivalent to target.

**Gap.** Store-to-load forwarding for the single-step case: a `Load` whose memory input is a `Store` to the same pointer node with the same type.

**Sketch.** In `builder.load`, check `kind(memory) == .Store`, `input(memory,2) == pointer`, and `type(input(memory,3)) == type`. If all hold, return the stored value. Dominance is automatic, because the memory input is the store itself. Skip the forwarding for `Volatile` and atomic orders (`graph.odin:7-15`). Files: `src/ir/builder.odin:171-173`. Effort **S**.

**Risks and tests.** A width mismatch, for example a 1-byte store read as 8 bytes, must not forward. Test: a golden with same-type store then load (forward), and a golden with a different-width load (no forward). Also run the interpreter on both. Effort **S**.

## 10. Ch 11 — splitting memory: alias classes, MemPhi, MemMerge

**Simple.** Each struct field gets an alias class, and memory is split into one chain per class. A `MemPhi` exists per class. A `BulkMemPhi` holds all classes until a split is needed. `MemMerge` combines memories without being a clobber. Stores in different classes impose no load/store ordering.

**Ours.** There is no alias class. `Access_Info` holds alignment, order, failure order, RMW op, weak and signal flags, and a value type, but no alias (`src/ir/graph.odin:27-35`). Every memory-touching node takes the single chain (`kinds.odin:363-401`).

Consequences we can see in the code. (1) Any store orders every load after it, because `order_block` adds an edge from a `Load` to the node that takes over its memory state (`src/sched/order.odin:229-243` builds `taker`, `:273-278` adds the edge). (2) Any merge with a changed field merges memory, because memory is just another variable (`builder_control.odin:186-205`). (3) No load can move out of a loop, because loads are pinned (`kinds.odin:363`, `is_pinned` at `kinds.odin:190-202`).

**Gap.** This is probably the largest structural gap for loops over struct fields and slices: a store to an output array blocks every load of an input array.

**Sketch.** Alias classes cannot come from Odin types alone. Odin has `rawptr` and pointer casts **[unverified: Odin's aliasing rules, not read in the official spec]**, so type-based alias analysis is unsafe. The safe first step is region-based: a `Stack_Slot` (`builder.odin:97-100`) whose address never escapes (never stored, never passed to a `Call`, never converted with `Bitcast`) gets its own class. Everything else stays in the "unknown" class. Escape is a conservative syntactic walk over the uses of each `Stack_Slot`, which `uses_build` (`src/ir/graph.odin`, the function after `remove_node`) already supports.

Implementation steps: add `alias: u8` to `Access_Info`; make `MEMORY_VARIABLE` a set of variables, one per class, in `Builder` (`builder_control.odin:18`, `:270-277`); `load` and `store` take the class from the pointer's origin; `order_block` (`order.odin:273-278`) uses class-aware `taker`; `verify_memory.odin` checks per class. A `MemMerge` node is needed at calls (which clobber every class) and at `Return`.

Files: `src/ir/graph.odin`, `src/ir/builder.odin`, `src/ir/builder_control.odin`, `src/ir/verify_memory.odin`, `src/sched/order.odin`, `src/lower/lower_control.odin` (the assigned-variable pre-scan must cover classes).

**Risks and tests.** Escape analysis is easy to get too optimistic: a pointer obtained via `Bitcast` from a stack address, or stored into another stack slot, must mark the slot escaped. Test: a goldens file with a stack slot read and written in a loop beside a slice read; the slice load must hoist or at least not be ordered after the stack store. Plus interpreter equivalence on randomly generated slot-and-pointer programs. Effort: **L**.

## 11. Ch 12 — references

**Simple.** Struct fields hold references, with forward references to types that are not yet complete, and recursive struct types are resolved.

**Ours.** This is the checker's job. Cyclic declarations are handled in `src/check` (`declaration_cycle_test.odin:8` names the behaviour; `src/check/resolve.odin` implements the resolution **[unverified: body not read]**). The IR sees finished layouts only.

**Gap.** None for the IR. Chapter body not read; this section is by heading only.

**Effort.** None.

## 12. Ch 13 — global code motion: early and late schedule, loop depth

**Simple.** Control is fixed. The early schedule places each floating node in the block of its deepest input's dominator. The late schedule places each node at the lowest common dominator of its uses, and between the two it prefers the shallowest loop, then the deepest control dependence. Loads wait for memory users that can overwrite their alias. Loop depth is computed on the dominator tree.

**Ours, what `order` does.** It is one function (`src/sched/order.odin:36-119`):

1. `uses_build` and `build_control_skeleton` (`order.odin:48-49`).
2. `place_floating` (`order.odin:133-170`): Kahn order from the users, so every user is placed before its inputs.
3. `use_common_block` (`order.odin:173-183`) gives each floating node the common dominator of its uses, via `common_dominator` (`order.odin:205-216`).
4. Non-floating phis and pinned nodes keep their own block (`order.odin:56-62`).
5. Each block is ordered by `order_block` (`order.odin:248-323`): phis first, then Kahn with priority by id (`node_id_less`, `order.odin:326-328`), with data edges inside the block, a load before the node that takes over its memory state, and the exit last.

Floating means pure, or a non-control `Proj`, and not rematerialised (`order.odin:121-129`). Rematerialised constants are not placed (`kinds.odin:` `Rematerialize` flags on `Const_Int`, `Const_Float`, `Undef`, `Symbol_Addr`, `Tls_Addr`).

Loop depth is computed from loop membership (`src/ir/cfg.odin:378-389`), and used for `Block.depth` (`order.odin:112`) and for register-allocation weights (`src/regalloc/liveness.odin:103-104`, `:431`).

**Gap.** Step 3 is the late schedule only. There is no early bound and no loop-depth choice, so a pure value used inside a loop body is placed inside that body even when all its inputs are loop-invariant. That is loop-invariant code motion missing, not just a weaker placement.

Also missing: a load does not wait for memory users in other blocks (only same-block `taker` edges, `order.odin:273-278`).

**Sketch.** After step 2 places everything at its late block `L`, run a second pass in input-first order: for each floating node, compute `E` as the deepest block among the blocks of its inputs (`block_of_node` for pinned inputs, `placement` for floating inputs). `E` dominates `L`, because every use is dominated by every input's block. Choose the block on the dominator path from `E` to `L` with the smallest `cfg.depths` and, on a tie, the one closest to `L`. Files: `src/sched/order.odin` (`place_floating` and a new `early_block`), `src/ir/cfg.odin` (depths and idoms already exist).

Order: this runs after section 8's optional load CSE, before `order_block`, so the local ordering sees the final placement.

**Risks and tests.** Hoisting a pure value only moves it, so it cannot trap, because pinned division stays pinned (`kinds.odin`, `SDiv`–`URem`). Hoisting raises register pressure, which the regalloc weights (`liveness.odin:103-104`) partly offset. Test: `print_test.odin:38-62` already has a golden schedule; add a loop with a loop-invariant multiply and check that the multiply moves to the preheader block. Effort: **M**.

## 13. Chapter-sccp — sparse conditional constant propagation

**Simple.** Every node starts at ⊤. A worklist recomputes each node's lattice value from its inputs, and a changed value puts its users back on the worklist. Phis merge only live control paths, which is the "conditional" part. Loop phis of integer ranges widen after a bounded number of steps. Constants stay precise, and ranges stay narrow above the centre.

**Ours.** None. There is no lattice on nodes (`graph.odin:52-59`), no worklist, and no notion of live control (control is only reachability from entry, `ir/cfg.odin:118-156`).

**Gap.** Constant propagation through phis, and removal of arms that become dead after a constant is proved. Section 5 covers the local case. SCCP covers the case where a value is constant only because one path is dead, which is common after bounds checks are removed.

**Sketch.** A new pass `src/ir/sccp.odin`, run after lowering and before `order`, and before the peephole driver of section 8 so that folded constants feed it.

- A side table `lattice []Lattice` indexed by node id, with `Top`, `Const{bits, type}`, `Bottom`, kept outside `Node` so the node layout does not change.
- Transfer functions for the integer and boolean pure kinds in `kind_info`, reusing the fold functions from section 1; `Phi` meets only inputs whose region input is live; `If` makes one successor live when its predicate is a constant.
- Pinned nodes produce `Bottom`, except `Proj` of a live `If`.
- Results: replace constants via `const_int`, rewire dead arms via section 5(b), then `intern_rebuild`.

Algorithm cost: each node has height 3, so the worklist is linear in edges.

**Risks and tests.** Folding must not change the trap semantics of pinned division. Test: an interpreter oracle over random small integer programs with loops and branches, checking that the interpreter result is the same before and after. Plus goldens for a loop whose counter stays constant. Effort: **M** for the integer subset without ranges; **L** with range widening.

## 14. Chapter-interprocedural-sccp — calls, call graph and summaries

**Simple.** A function pointer constant names its function (a function index). Each `Call` links to the `Fun` for every index that reaches its argument. Parameters meet all incoming arguments, call ends meet all returns, and loop phis, parameters and call ends widen. Unknown callers keep the entry input.

**Ours.**

- A call takes the callee as an ordinary input: `call(control, memory, callee, signature, args)` (`builder.odin:181-199`; kinds at `kinds.odin:401`).
- Direct calls use a `Symbol_Addr` callee (`src/lower/lower_call.odin:224`, `:290`). `Symbol_Addr` is interned by its symbol (`intern.odin:137-139`), so every direct call to a symbol shares one callee node. The call target is therefore visible at the IR level without a new analysis.
- Parameters are `Proj` nodes of `Start` (`builder.odin:43-61`), and results are `Proj`s of the call tuple.
- `Function.linkage` (`graph.odin:65`) is the input for "unknown callers". Whether a procedure is exported and callable from outside is determined by its linkage **[unverified: the linkage values were not read]**.
- Lowering is lazy: only procedures reached from roots are lowered (`src/lower/reachability.odin:11-16`). A module-level call graph is therefore available only after lowering finishes; I did not read `src/ir/module.odin` **[unverified]**.
- There is no inlining (grep of `src/lower`, `src/ir`, `src/amd64` for `inlin` finds only copy limits and comments; `check/expr_to_string.odin:50-53` shows `#force_inline` is parsed). `lower` never reads `call.inlining`.

**Gap.** No interprocedural facts, and no call-graph object.

**Sketch.** After section 13 works on one function, add a module pass: map each `Symbol_Addr` callee to its `Function`; keep a parameter lattice and a return lattice per function; iterate a worklist of functions with an in-degree-aware widening step. Exported functions (by linkage) get an unknown-caller input, as in Simple. Inlining single-target calls (Simple ch 18, "Inlining") reuses the same call-graph object. Files: a new `src/ir/interproc.odin`, `src/ir/module.odin`, `src/lower/lower_call.odin` (no change needed if callees stay `Symbol_Addr`).

**Risks and tests.** Lazy lowering means a function can be called only from code that is not yet lowered; the pass must run after the reachability fixpoint. Widening must bound parameters and returns in recursive functions (the Simple chapter's `testRecursiveWidening`). Test: a two-function program in which a constant parameter reaches a callee, and a recursive one. Effort: **L**.

## 15. Roadmap

| Priority | Item | Simple reference | Files | Effort | Depends on |
|---|---|---|---|---|---|
| 1 | Dead-phi removal at loop end (section 6) | ch 7–8 | `src/ir/builder_control.odin` | S | none |
| 2 | Constant-predicate branch in `branch_if` (section 5a) | ch 6 | `src/ir/builder_control.odin`, `builder.odin` | S | 3 |
| 3 | Construction-time fold of `binary`, `compare`, `convert` (section 1) | ch 2 | `src/ir/builder.odin` | S–M | none |
| 4 | Store-to-load forwarding, single step (section 9) | ch 10 | `src/ir/builder.odin` | S | none |
| 5 | Plain-load CSE keyed on memory state (section 8a) | ch 9 | `src/ir/builder.odin`, `intern.odin` | S | none |
| 6 | Trivial loop-phi substitution (section 4) | ch 5, 7 | `builder_control.odin`, `intern.odin` | S | none |
| 7 | Early schedule and loop-depth choice (section 12) | ch 13 | `src/sched/order.odin`, `src/ir/cfg.odin` | M | 3 (for better inputs) |
| 8 | Dominating-condition branch elimination (section 5b) | ch 6 | new `src/ir/fold_branch.odin` | M | 2, 3 |
| 9 | Intra-function SCCP, integer subset (section 13) | chapter-sccp | new `src/ir/sccp.odin` | M | 3, 8 |
| 10 | Iterative peephole driver (section 8b) | ch 9 | `src/ir/peephole.odin` (new) | M | 2–6 |
| 11 | Region-based alias classes and MemMerge (section 10) | ch 11 | `graph.odin`, `builder.odin`, `builder_control.odin`, `verify_memory.odin`, `order.odin` | L | 4, 5 |
| 12 | Interprocedural SCCP and single-target inlining (section 14) | chapter-interprocedural-sccp, ch 18 | new `src/ir/interproc.odin`, `module.odin` | L | 9 |
| 13 | Lazy phis (section 7) | ch 8 | `builder_control.odin`, `lower_control.odin` | L | low value after 1 |
| 14 | Null analysis, enhanced lattice | ch 10, ch 14 | none yet | L | not recommended |

Items 1–6 are all small and independent, and together they remove most of the redundant IR that the backend currently schedules. Item 7 is the one that addresses loop-invariant code, which the back-end measurements most likely care about. Items 11 and 12 are the largest structural gaps and need an owner decision first.

## 16. Open questions for the owner

1. Folding placement: do we fold during construction (Simple ch 2 style, in `builder.odin`) or in a separate pass before `order`? The second is easier to test against the interpreter, the first gives fewer nodes to kill.
2. Volatile and atomic loads: must they stay un-CSE'd and un-forwarded? The current `Memory_Order` enum (`graph.odin:7-15`) has the cases; I have not checked the official semantics **[unverified]**.
3. Alias classes: is a region-based scheme (non-escaping stack slots only) acceptable, or do you want type-based alias classes? Type-based classes would be unsafe under Odin's pointer casts **[unverified against the spec]**.
4. Does the official compiler assume anything about callees being pure or about exported procedures not being called from within the module? That decides how much interprocedural state we may keep (item 12).
5. Compile time versus run time: items 1–6 cost little compile time. Item 11 may add a lot. Which budget governs?
6. Lowering folds literal `if` conditions only (`lower_control.odin:112`). Is that the whole contract, or does the official compiler prune constant `for` conditions too? I did not read the official lowering **[unverified]**.
7. Should dead phis remain available for debugging output, or may `ir/print` goldens change when item 1 lands? This affects how we update the tests.
