# Review of the Sea of Nodes IR design

Reviewed `docs/02-ir-design.md`, including its owner decisions. This is a source-based design review, not an implementation or a claim that the example programs below were executed. Compiler references use `/home/su3h7am/Projects/Odin/src`, as requested. Runtime references use this repository's copied `base/runtime` and `core/fmt`.

## Verdict

Keep Sea of Nodes, scalar values, one conservative memory state, pinned memory operations, and the official Odin calling convention. Those choices can produce a correct compiler. The document is not ready to be an implementation contract. Its effect ordering, ABI representation, control invariants, and hello-world dependency assumptions contain correctness gaps. Several lowering descriptions also disagree with the requested fork.

The owner decisions do not remove these gaps. In particular, local-exec TLS is appropriate for the proposed static executable, but it is needed before normal runtime startup. Expanding `i128` into pairs does not make its ABI two unrelated scalar arguments. The premise that all relevant integer division and remainder cases behave like an unchecked hardware divide is false in the fork.

| Question | Answer |
|---|---|
| 1. Is one memory chain sound? | Yes for conservative alias handling, including `rawptr`, if every observable effect participates and scheduling preserves state on every control path. The specified volatile-load representation and memory verifier do not establish that contract. Atomics require machine atomicity and ordering, not just graph edges. |
| 2. Are derived blocks and two-input loops workable? | Yes. Odin's structured branches do not require irreducible loops. The entry-head inconsistency, loops with no live backedge, continuing through a loop's post statement, and merge construction need explicit rules. |
| 3. Are 63 kinds sufficient for runtime plus `fmt`? | No under the stated deferred-feature policy. TLS, atomic operations, bit/overflow operations, half conversions, and existing runtime vector/target operations need implementations before that milestone. Many can expand to existing scalar nodes or helper calls rather than become new kinds. |
| 4. Are GVN and forwarding safe? | Only with a defined value representation, complete keys, rewrite-time deduplication, and special treatment of volatile/atomic accesses. A same-byte-size bitcast is insufficient for `bool`. |
| 5. Is the plan realistic? | The decomposition is useful; the dependency order and several line budgets are not. ABI, flow verification, interpretation, constrained allocation, and the deferred-runtime step are underestimated. |
| 6. Is this simple enough for v1? | The representation can be. The initial implementation plan combines too many independent algorithms. Start with a conservative schedule and a small executable lowering sample; add GCM and GVN after that sample has an independent oracle. |
| 7. Is compatibility preserved? | The intended convention is right, but the specified MEMORY-class argument lowering, result metadata, shifts, slicing, remainder, `any`, union, and reflection rules need correction. Rejecting a temporarily unsupported feature is honest, but does not fulfill the final full-language requirement. |

## Prior art checked and what to reuse

- `core/rexcode/ir` and `core/rexcode/docs/ir_design.md` provide structured IR vocabulary, not a reusable Sea of Nodes scheduler. `core/rexcode/isa/x86` remains the encoder. No new encoder is justified.
- The fork's `base`, `core`, and `vendor` were checked as the first source of existing facilities. Runtime atomics, TLS declarations, memory implementations, and formatting dispatch are existing requirements, not speculative backend features.
- Official repository searches included code-oriented searches and GitHub issue/PR queries. PR [#7850](https://github.com/odin-lang/Odin/pull/7850) is closed and unmerged. Merged backend work includes [#7825](https://github.com/odin-lang/Odin/pull/7825), [#7729](https://github.com/odin-lang/Odin/pull/7729), and [#7720](https://github.com/odin-lang/Odin/pull/7720). Searches of `odin-lang/examples` and `odin-lang/pkg.odin-lang.org` did not reveal a reusable implementation of this graph/effect model. This is a bounded search result, not a claim that no relevant code can exist.
- Click's Simple chapters [8](https://github.com/SeaOfNodes/Simple/blob/main/chapter08/README.md), [10](https://github.com/SeaOfNodes/Simple/blob/main/chapter10/README.md), [11](https://github.com/SeaOfNodes/Simple/blob/main/chapter11/README.md), and [13](https://github.com/SeaOfNodes/Simple/blob/main/chapter13/README.md) were read directly. Reuse memory-as-SSA, predecessor-indexed phis, parallel phi updates, and load anti-dependencies. Do not import Simple's field-disjoint alias assumptions into Odin.
- [V8's post-mortem](https://v8.dev/blog/leaving-the-sea-of-nodes), `docs/research/02-backend-ir-landscape.md`, `06-pr7850-ir-regalloc-parallelism.md`, and `07-pr7850-lowering-abi-elf-dwarf.md` were checked. They support a fixed control skeleton and conservative effects, but do not establish correctness merely because operations are pinned.
- The local reference checkout was searched. `/home/su3h7am/Projects/refs/rfcs/linux/kernel-docs/Documentation/arch/x86/x86_64/fsgs.rst` explains per-thread FS bases and `ARCH_SET_FS`. `/home/su3h7am/Projects/refs/go/src/internal/runtime/atomic/doc.go` is a useful contrast between runtime atomic guarantees and ordinary memory access. The requested Odin fork supplies the decisive lowering reference. The local LLVM checkout did not contain `LangRef.rst`; no claim below depends on having read a missing local specification.

The fixes below preserve the owner choices and follow `docs/research/01-gingerbill-vision.md`: fewer independently moving parts, explicit costs and state, existing Odin facilities first, and no language changes.

## Blocker findings

### B1. Observable reads need effect order, not just a pinned block

Design locations: sections 4 and 7, especially lines 178-185 and 246-253.

A single memory state is a sound conservative choice for Odin aliasing. A call must consume and replace that state even when it returns no ordinary result. The same applies to a syscall, including reads and writes through pointer arguments and globals. Unknown callees cannot receive a readonly or no-alias interpretation merely because their signature contains only scalars. A memory state cannot be reused for forwarding across either operation.

However, `Volatile Load` currently consumes memory and returns only its scalar value. Two such loads have no effect edge between them. Their required observation order is left to the node-id tie-break. That can preserve order in unchanged builder output, but the document does not make it a checked semantic invariant across rewrites and selection. `verify_schedule` does not check that tie-break or source-order preservation. Either IDs must become a mandatory ordering contract for observable reads, including every transformation, or the graph must carry the order. Pinning alone is insufficient. The ordinary load-fusion rule also permits moving a read past a call because it checks only intervening stores; see M7.

The deferred atomic design needs more than the phrase "full-barrier meaning". A chain edge prevents compiler motion; it does not make a read-modify-write indivisible or make an ordinary store sequentially consistent on x64. Compare-exchange also needs its observed value, success flag, success/failure orders, and weak/strong choice. Signal fences and thread fences have different scopes. The fork explicitly preserves these distinctions in `llvm_backend_proc.cpp:4065-4144, 4176-4288`.

**Fix:** make volatile reads state-producing operations, for example `Tuple(mem, value)`, or add an explicit ordered-effect input/output to them. Put every atomic operation and fence on that ordered state as well. Specify atomic width/alignment, RMW operation, compare-exchange results, and the required x64 instruction/fence behavior. Initially using stronger machine orders is conservative, but it does not excuse non-atomic instructions or a non-atomic CAS expansion. Never remove, common, forward, or fuse these operations as ordinary loads.

Ordinary nonvolatile loads may remain state-consuming only. Their read-before-clobber anti-dependencies are sufficient when the memory SSA is valid. Non-atomic shared-memory accesses still follow Odin's race rules; a memory token is not a promise that another thread cannot modify memory. Atomic synchronization must prevent reuse of an older state across the synchronization point. Volatile alone is not inter-thread synchronization.

The syscall model is otherwise suitable for ordinary returning Linux syscalls. Preserve its whole-memory clobber and actual register constraints. `llvm_backend_proc.cpp:4500-4542` supplies the x64 syscall register order and memory clobber. A syscall is not a universal replacement for a language atomic fence.

### B2. The call signature cannot yet express the claimed ABI

Design locations: section 3's `Param`/`Signature`, section 6's table, and owner decisions 2 and 4.

There are three concrete problems.

1. The table maps every MEMORY-class argument to a `By_Value` pointer that `x64` copies to the outgoing stack area. That is not the fork's Odin convention. In `llvm_abi.cpp:973-980`, a MEMORY-class argument under an Odin calling convention becomes an indirect argument without the C `byval` attribute. A physical pointer parameter and a stack-resident by-value object are different ABIs. The stated large-aggregate rule would break calls into LLVM-built Odin procedures even if every field's layout were correct.
2. Flattening a small aggregate into unrelated scalar `Param`s loses the grouping needed when argument registers run out. For a C function with five integer arguments followed by `struct {a, b: i64}`, the aggregate cannot become one half in the last integer register and one half on the stack. Its classification/placement must preserve the aggregate rule. The fork tracks register demand and the aggregate distinction in `llvm_abi.cpp:902-980`. Bare `i128`, a struct containing it, and two scalar `i64`s also do not have interchangeable stack alignment/placement rules.
3. `Signature.results` contains only `Value_Type`. It cannot distinguish signed and unsigned small integer returns or attach their extension obligations. The fork's `lb_integer_extension_attribute`, `llvm_abi.cpp:437-456`, applies to returns as well as arguments. A callee returning `i8(-1)` and a callee returning `u8(255)` cannot share an unspecified upper-register-bit contract.

**Fix:** define a whole-signature ABI plan before removing aggregate information. Either retain argument groups with byte ranges, alignment, passing mode, and piece classes, or make `lower` produce final physical argument/result locations and exact stack-object descriptors. State where register-exhaustion decisions happen. Separate Odin indirect passing from C by-value stack passing. Give results attributes or explicitly widened ABI types too. Preserve `i128` grouping/alignment even though computation uses `I64` pairs.

The official split-result-pointers rule and context-last rule are supported by `llvm_abi.cpp:394-418, 2754-2775` and need not change. Do not adopt the open question's alternative register-return convention. Validate the final plan bidirectionally against the fork, not only against Clang. Clang is the C ABI oracle, not an Odin-CC oracle.

### B3. The deferred set prevents the advertised hello world

Design locations: section 4's deferred table, stage 18, owner decision 3.

Normal runtime startup and a dynamic `any` formatter are much broader than a literal write syscall. The compiler must compile their reachable bodies even when a particular test run does not execute every branch. The design has no branch-specialization mechanism that could remove unsupported formatting cases.

| Existing source | Requirement that is deferred or missing |
|---|---|
| `base/runtime/core_builtin.odin:59-64`, `heap_allocator_implementation.odin:2173` | Default temporary allocator and heap state use TLS. |
| `base/runtime/entry_unix.odin:57-85`, `lifecycle_linux_amd64.odin:168-176` | Startup/cleanup include owned runtime setup and atomic atexit locking. |
| `base/runtime/heap_allocator_tagged.odin:37-85` | Atomic load, CAS, OR, and AND; the x64 path is not the single-thread fallback. |
| `base/runtime/heap_allocator_implementation.odin:422-433, 1884-1985` | Leading/trailing-zero operations and several atomic orders. |
| `base/runtime/default_temp_allocator_arena.odin:28-30` | Overflow addition. |
| `base/runtime/internal_i128.odin:20, 61`, `core/fmt/fmt.odin:1149, 1354, 3579-3586` | `u128` operations and conversions. The owner's pair expansion must exist before this milestone. |
| `core/fmt/fmt.odin:3479-3586` | Runtime-dispatched formatting includes half floats and 128-bit values, even when the caller prints a string. |
| `base/runtime/internal.odin:276-315` | Memory equality contains 16-byte SIMD loads/comparisons/reduction on the baseline path, not only an optional AVX2 loop. |
| `base/runtime/mem_linux_amd64.odin:7-33, 45-84` | Required no-CRT memory wrappers lead to native memory routines with vector types, `x86_cpuid`, `x86_xgetbv`, atomic load and CAS. |
| `base/runtime/heap_allocator_implementation.odin:1455` | `cpu_relax` in allocator synchronization. |

This table proves the 63-kind contract plus `Unsupported` fallback is insufficient; it is not an exhaustive transitive dependency inventory.

**Fix:** distinguish a minimal raw-syscall executable from a default-runtime `core:fmt` executable. Before calling the latter v0, implement TLS end to end, the runtime atomic subset, bit/overflow expansions, `i128` pair lowering, half conversions, and the actually selected runtime vector/target operations. A scalar expansion or existing Odin helper is acceptable when it preserves semantics and ABI. Do not claim that adding one new node enum member completes TLS, half support, or 128-bit division.

Local-exec is a reasonable TLS decision for the static executable. Add TLS classification to globals, `.tdata`/`.tbss`, `PT_TLS`, relocation handling, image alignment and initialization, the initial thread pointer, and each new thread's TLS. Reuse the fork's layout/startup logic rather than invent a second incompatible arrangement. `base/runtime/entry_unix_no_crt_linux_amd64.asm:87-130` shows that setup already precedes `_start_odin`. It cannot move to "soon after hello world" while hello world uses that runtime.

### B4. The entry and loop invariants reject ordinary source programs

Design locations: sections 4-5, `S2`, `S6`, `C1-C5`, and the section 10 example.

The document has two competing entry blocks. `Start` produces a tuple; its projection 0 produces `Control`. The block-head definition includes `Start` but only allows projections of `If`/`Switch`, not the Start projection. The example uses `n2 = proj.ctrl n1` as the predecessor of `If`. Meanwhile `Stack_Slot` demands a slot-0 input equal to `Start`, despite the generic pinned-node rule demanding a control-typed block head. A literal implementation cannot satisfy all of these rules.

The exactly-two-input `Loop` rule also has no completed representation for `for { break }`, `for { return }`, or a loop body whose paths all terminate. There is no live backedge source to install, and `S2` forbids leaving `NODE_NONE`. A synthetic backedge from a terminating block would invent control flow.

**Fix:** choose the Start control projection as the entry head, and define Start's value/memory/parameter projections separately. Give `Stack_Slot` either the entry-head control input or an explicit entry-anchored exception, consistently in the builder and verifier.

On sealing a loop with no live backedge, replace its header by its entry, replace header phis by their entry values, and remove the loop marker. An equivalent explicit representation is possible, but it must not leave a false cycle. Specify the rewrite before implementing GCM. Keep real infinite loops reachable through forward CFG enumeration and pinned roots; the proposed avoidance of Simple's `Never` node is reasonable if every traversal follows that policy.

## Major findings

### M1. Non-dominance does not prove exclusive execution

Design locations: section 7 line 250 and verifier `M3-M4`.

Two blocks can execute on the same path even when neither dominates the other. Consider two sequential optional branches, `if c { store_a }` followed by `if d { store_b }`. Neither store block dominates the other, but both execute when `c && d`. A faulty lowerer can feed both stores the original state, omit the first merge's memory phi, and still pass the stated non-dominance test. A stale load after a conditional write is likewise not covered by `M4` when the writing block does not dominate the load.

This is precisely a defect in the proposed defense against the V8 effect-chain bug. Making the state a hidden local reduces mistakes but does not prove they cannot occur.

**Fix:** verify the current memory state along control edges, including each phi input at its matching predecessor edge. The verifier must reject a state use reachable after a consuming clobber without the appropriate merged/new state, not just a use dominated by that clobber. A forward block-state consistency check with loop fixed points is one conservative option. Treat phi inputs as edge uses throughout this check. Add one negative sequential-diamonds graph; it catches a bug a simple diamond test does not.

Do not require a new memory phi at every empty diamond. An unchanged state on all incoming edges is valid. Likewise, two mutually exclusive consumers of the same state are valid. The property is path consistency, not a globally single-use token.

### M2. Reducibility is plausible, but the lowerer needs precise merge and exit rules

Design locations: section 5, section 8's defer lowering, section 12's scheduler.

There is no demonstrated requirement for irreducible source control flow here. Switch fallthrough advances to a later case; labeled `break` exits a structured construct; labeled `continue` targets an enclosing loop's continuation; duplicating a defer body on an exit does not create an entry into a loop's interior. These constructs can retain a dominating header. The fix is not to add general irreducible-loop machinery speculatively.

The missing details are more immediate:

- A counted `for`'s `continue` must execute the post statement. It must not jump directly to the condition/header. All appropriate defers run before reaching the post statement.
- A switch case reached both from the switch projection and by fallthrough needs a merge and matching scalar/memory phis. Its direct projection can be a separate edge block, but cannot also pretend that the case body has a single entry.
- A labeled exit needs the target scope depth, not just a single current-loop break or continue region. Deferred statements execute for exactly the scopes crossed.
- Fixed arity conflicts with "created on demand" regions if a later `continue` adds a predecessor. Collect pending `(control, environment)` exits until the target is sealed, or use binary merge chains as Simple chapter 8 does. Do not patch growth into an immutable-arena contract implicitly.
- Loop assignment discovery must operate on checked variable identities and include updates in nested bodies, post statements, and defer expansions. Otherwise eager phis silently miss a backedge definition. Hidden state belongs in the same mechanism.

**Fix:** specify one exit-collection/sealing procedure and use it for loop exits, labeled exits, and fallthrough. Validate it with one nested-loop program containing a post statement, a labeled continue, switch fallthrough, and deferred observable writes. Keep `C4-C5` as assertions on that lowering, rather than treating the absence of a `goto` keyword as the proof.

Loop depth also cannot be the number of dominating Loop nodes. A loop header dominates its exit and much code after it, which is outside the loop. Compute membership from the normalized backedge/header structure or preserve the builder's loop nesting with verified exits. Simple chapter 13 explicitly handles exits in its loop-depth computation.

### M3. The numeric lowering changes defined behavior

Design locations: the raw shift/divide kinds, section 8's shifts/bounds rules, and owner decision 6.

The shift operand type is not necessarily the left operand type. The fork compares the count against the width before converting the count to the left operand type, `llvm_backend_expr.cpp:2089-2128`. For `x: u8` and `count: u64` equal to 256, truncating the count before the comparison changes `x << count` from zero to `x`. The document requires the raw count to have the type of `x` but does not preserve this distinction in its lowering recipe.

The recipe also eagerly forms an out-of-range raw shift in the unchosen operand of `Select`, while declaring such shifts undefined. LLVM's poison/select rules can support that pattern, but this IR has not specified equivalent rules and calls its interpreter an oracle. "Undefined operation" and "arbitrary unused result" are not interchangeable specifications.

Remainder is a separate concrete mismatch. The fork's `lb_srem_safe_divisor`, `llvm_backend_expr.cpp:331-342`, and `lb_integer_modulo`, `:1729-1755`, ensure that `MIN % -1` returns zero instead of taking an x64 divide exception. Signed `%%` also has a nonzero-remainder/sign correction, `:346-392`; a naive wrapped `(a % b + b) % b` is not sufficient. A raw SRem that may trap needs a protecting expansion.

Division by zero has source/file and build modes in `llvm_backend_expr.cpp:309-327, 1494-1594`. In trap mode, the runtime-divisor zero path explicitly calls `llvm.trap`, rather than relying on the divide instruction. That distinction can change the observable signal. Do not treat zero division as undefined and exclude it from all differential tests when the reference has a defined selected behavior.

**Fix:** compare a shift count in its original width, then convert a safe count. A simple non-poison recipe clamps the raw shift operand before evaluating the shift and selects the Odin result afterward. Specify signed `%`/`%%` safe-divisor expansion and implement the supported division-by-zero modes in `lower`. Keep owner decision 6 as a default trap policy only after correcting its reference-compatibility premise; a policy choice cannot make incompatible behavior identical.

### M4. The slice check uses capacity where Odin uses length

Design location: section 8 line 267's bounds-check description.

The document says slice expressions check `lo <= hi <= cap`. Odin slices do not carry capacity, and the fork checks dynamic-array slicing against its current length too, not its capacity. `llvm_backend_expr.cpp:5723-5746` passes slice length or dynamic-array length to the check. A dynamic array with `len == 1` and `cap == 8` must not be allowed to slice to index 4 merely because backing memory exists. Negative low bounds must also fail; a signed `lo <= hi <= limit` test alone does not establish that.

**Fix:** state the rules by source container. For an ordinary slice, string, array, or dynamic array use the reference's appropriate length bound, plus nonnegativity and ordering. Multipointer slicing has its separate rule. Preserve the chosen context-aware failure handler and source location. The existing scalar/control nodes can express these checks; no bounds-check node is needed. Test a negative low bound and a dynamic-array high bound between length and capacity.

### M5. Defers need their registration context; named returns must be snapshotted

Design locations: sections 8's `defer`, `context`, and multiple-return descriptions.

Duplicating deferred bodies is a workable choice and matches the reference's approach. A stack containing only deferred syntax is not enough. `lb_add_defer_node` records `context_stack_count`, and `lb_build_defer_stmt` restores that context stack before lowering the deferred statement, `llvm_backend_stmt.cpp:3596-3628, 3694-3708`. A defer registered before a later context rebinding must not automatically use the binding active at the exit. The document describes current context and a defer stack separately without their connection.

Return values also need a defined snapshot point. The fork collects return values before running defers, including bare named returns, and writes split results before the defer sequence, `llvm_backend_stmt.cpp:2621-2683, 2778-2853`. Reading a named result after a defer has modified it would differ from this behavior. Do not infer Go's named-return rules from the similar syntax.

The boolean form of `or_return` is absent from the recipe. `lb_emit_try_has_value`, `llvm_backend_utility.cpp:474-484`, takes a boolean success flag directly; it only compares nil-capable errors to nil. The propagation path then delegates to the same return/defer machinery, `:634-672`.

**Fix:** save each defer's registration context binding and scope information. Snapshot all return results at the reference's point, then emit the deferred statements with their recorded context. Route `return`, `or_return`, `or_break`, `or_continue`, fallthrough, and labeled branches through the same scope-exit mechanism. Include compiler-generated deferred-procedure attributes in the eventual lowering inventory; the backend has a separate `lb_add_defer_proc` path. None of this needs a new IR kind.

### M6. `any`, unions, and reflection cannot be lowered by the stated shortcuts

Design locations: section 8's aggregate and union paragraphs.

Three descriptions need correction before `core:fmt` is a meaningful oracle.

- `any(x)` does not always mean a pointer to a fresh stack copy. In `llvm_backend_expr.cpp:3384-3404`, conversion obtains an address through `lb_address_from_load_or_generate_local`. That helper reuses the loaded lvalue's address when permitted, `llvm_backend_utility.cpp:1059-1071`. Always copying can change what a later read through `any.data` observes. Implicit address exposure also means a local cannot remain SSA merely because source syntax contains no explicit `&x`.
- Not every union is a variant area followed by an integer tag. The reference has tagless pointer-like unions, zero-sized unions, `#shared_nil` construction that canonicalizes nil, custom alignment, and unchecked/optional-ok assertion paths. See `llvm_backend_general.cpp:2425-2519` and `llvm_backend_utility.cpp:854-956`. Loading a tag from a tagless `Maybe(^T)` reads nonexistent data. Writing a nonzero variant tag for a nil shared-nil variant changes nil equality and error propagation.
- In this fork, a `typeid` is a canonical type hash, not a type-table array index. `lb_typeid`, `llvm_backend_type.cpp:78-90`, calls `type_hash_canonical_type`. Dynamic `type_info_of(id)` calls `__type_info_of`, `llvm_backend_proc.cpp:3170-3182`; `base/runtime/core.odin:814-826` performs the table lookup. A simple table-base-plus-id calculation is wrong. Compile-time `type_info_of(T)` can use the checker's separate table index.

**Fix:** make these explicit `lower`/layout responsibilities with the named fork helpers as behavioral references. Treat implicit boxing as address exposure, preserve permitted lvalue reuse and lifetime, carry union representation information from `types`, and generate the exact reflection tables and type IDs that the copied runtime expects. Test the distinction between an addressable boxed variable and an rvalue, nil shared-nil construction, a tagless pointer union, and dynamic reflection lookup. These are missing lowerings, not reasons to add high-level `Any` or `Union` node kinds.

Maps and `#soa` likewise need no dedicated ideal nodes, but are not covered merely by calling them aggregates. Map lookup/set needs key hashing, the correct metadata or generated helper, optional-ok zero values, and context/allocator behavior. The fork's `llvm_backend.cpp:1341-1407` supplies a runtime-call route suitable for v0. `#soa` element loads and stores gather/scatter separate fields and have a distinct pointer representation, `llvm_backend_general.cpp:936-1039, 1751-1810, 2261-2313`. A flat `base + index * element_size` is not an SoA element address. Document these expansions before claiming general aggregate coverage.

### M7. Store-to-load forwarding needs a representation contract, especially for booleans

Design locations: section 7's load rule and section 11 line 394.

Forwarding the immediately preceding ordinary store is sound if the state really is current, both accesses are ordinary, the address and exact byte range match, and the stored representation is converted to the loaded representation correctly. Raw pointers do not invalidate that local proof. A different pointer that might alias is simply a reason not to forward. Calls, atomics, syscalls, and volatile accesses must prevent extending this shortcut across them.

The current "same width, bit-cast if types differ" is incomplete. `Bool` is a one-bit logical value with byte memory storage. A byte load as `Bool`, a logical-bool store, and an `I8` load need explicit truncate/extend behavior. Bitcasting `Bool` to `I8` violates the same-size rule. Nor may integer identities silently apply to the separate float operators: NaN equality and signed zero forbid several superficially similar folds.

**Fix:** define each load/store's memory width and value conversion. Either forbid Bool-typed memory operations and use `I8` plus conversions in `lower`, or make forwarding use the same encode/decode rules as actual memory. Check both the load and store's volatile/atomic properties. Do not forward partial overlaps, mixed widths, or an earlier store found by skipping an unknown clobber. Keep the preserved Store itself unless a separate dead-store proof permits removal.

Loads folded into x64 memory operands need the same restrictions. One use and "no intervening store" are insufficient: an intervening call, syscall, atomic operation, volatile event, or observable trap boundary can also matter. Until the selector proves the permitted interval, fuse only at the load's scheduled position or require adjacency. Never fold volatile/atomic loads through the ordinary tree matcher.

### M8. Rebuilding the GVN table does not restore unique canonical nodes

Design locations: verifier `G1-G2`, section 11's immutability rule, and section 14's blob merge.

Suppose `p = Phi(region, x, x)`, and both `Add(p, one)` and `Add(x, one)` exist before phi simplification. Replacing `p` by `x` makes the two Add nodes equal. Rehashing them does not rewrite their users or remove the duplicate. `G1` explicitly forbids the resulting graph. This is not fixed by never iterating the hash table.

The document also says GVN keys include raw `data`, whose eight-byte union can contain padding or inactive bytes. Those bytes need initialization or a semantic key function. A future semantic flag must not be omitted merely because the proposed key lists kind/type/inputs/data but not flags. `Proj` classification depends on the projected tuple member; it cannot be handled as universally pure just because most value projections are pure.

Finally, the deterministic blob merge rewrites `Symbol_Addr` payloads after they have been interned. That is another graph rewrite, and must invalidate/rebuild the affected GVN state. Deduplication must compare relocation targets/addends and alignment requirements as well as bytes. Two zero-filled pointer blobs with relocations to different functions are different data.

**Fix:** either permit duplicate live pure nodes and weaken `G1`, or make rebuild perform deterministic canonicalization plus use replacement until the promised invariant holds. The former is simpler for v0. Hash kind-specific semantic fields, not uninitialized union storage; explicitly define which flags enter the key. Freeze and normalize blob symbol references before final GVN validation, or route their rewrite through the same rebuild protocol. Only merge blobs whose complete relocation-bearing content and permitted address identity match.

Also define `Undef` precisely. LLVM-style per-use undef, a stable arbitrary value, and the interpreter's fixed zero are different models. Do not use undef to hide a reachable missing phi value that the checker/lowerer should reject. Differential tests must avoid interpreting unspecified values as a correctness oracle.

### M9. Derived blocks can support GCM, but machine CFG changes need a contract

Design locations: section 12, scheduler and selector descriptions.

The source graph's split If/Switch projections can avoid critical edges if all transfers really route through those projection blocks. That is a useful invariant, not an automatic property of naming a node `Proj`. The claimed edge-copy rule depends on keeping these blocks, including for switch fallthrough joins.

After scheduling, `x64.select` creates new control flow for conversions and switches. The machine CFG can now have new predecessors, successors, edge-copy positions, and internal joins. Register allocation must see that final graph. Computing liveness on the old scheduled IR blocks and inserting a hidden branch later would be incorrect. A branch expansion's two definitions of one result also need a defined non-SSA join or explicit parallel-copy representation.

The verifier needs explicit treatment of fixed phis and tuple projections during early/late scheduling. Recursing through loop-phi backedges as ordinary pure inputs creates cycles. Phi uses belong to predecessor edges, and all phi values update in parallel. Forward CFG enumeration is also necessary for no-exit loops because Stop is not a complete root.

**Fix:** finish machine CFG expansion before liveness; then verify predecessor/successor symmetry, definitions, edge moves, fixed-register requirements, and any newly critical edges. Split new critical edges or place moves with a proven edge-specific mechanism. Have the scheduler use fixed placements for phis/projections and exclude loop backedges from ordinary recursive placement. Add one schedule test for a no-exit loop and one machine-CFG test for a branch expansion with a value live across its join.

### M10. The allocator interface cannot express the advertised allocation model

Design location: section 12's `Operand`, `Result`, and Wimmer/Mössenböck description.

`Result.location` gives one location per vreg. An interval-splitting allocator needs locations by live-range segment or operand position. Even without splitting, a value can be required in different physical registers at different instructions, such as a call argument and a return. The listed `inserted_moves` do not by themselves define how an operand uses a location different from `location[vreg]`, or how the verifier checks that transition.

Rematerialization is promised in the prose but absent from `Operand`/`Program`. Spill slots have no stated width/alignment contract. The `Use_Table` notion of early/late positions also needs to agree with fixed-register clobbers, two-address instructions, and parallel moves; these are not independent details that can be left to emission.

**Fix:** pick a smaller first allocator model. One option is no interval splitting, explicit short-lived vregs for fixed-register copies, fixed-width spill slots for the initial scalar classes, and operand rewriting before final verification. Alternatively return a per-position allocation and specify move insertion/splitting fully. Add a concrete rematerialization descriptor only when it is implemented. Final verification should check the rewritten machine program, not merely compare one static vreg location against every constraint.

## Minor findings

### N1. Rooting all pinned nodes is safe but broader than the stated DCE goal

Design location: section 11 line 400.

Rooting all pinned nodes and every phi preserves unused divisions, unused loads' address calculations, and phi-only cycles. That is conservative, not an optimizing DCE. There is also tension between rooting every Load and deleting unused ordinary loads in the same pass.

**Fix:** define observable roots separately from pinned placement, and specify whether ordinary unused loads and divisions may be removed under the chosen trapping contract. Keeping all reachable pinned nodes initially is acceptable if documented. The important infinite-loop requirement is preserving reachable control and effects, not keeping every unused phi forever.

### N2. The TLS open question and numeric stage references are stale

The owner selected local-exec, while open question 3 still conflates `R_X86_64_TPOFF32` with initial-exec. The latter normally uses a GOT-relative TLS relocation path, not the same local-exec address contract. Earlier sections refer to deferred kinds as stage 14 and aggregate promotion as stage 15; the actual plan puts these in stages 18 and 19.

**Fix:** incorporate the owner decisions into the normative sections and delete obsolete alternatives. Name stages by deliverable or keep references synchronized. Local-exec remains a static-executable restriction, not the final answer for shared-library output on every supported platform.

### N3. The node count is not a useful simplification target

The counted 63 kinds are a plausible scalar instruction vocabulary. There is no large set of obviously unnecessary kinds to delete. `Ptr_Index`, `Select`, and the separate signed/unsigned operations have concrete lowering uses. Removing them just to meet a numerical target moves complexity into `lower` or instruction selection.

**Fix:** cut optimization mechanisms first. If all traversals use forward reachability plus pinned roots, Stop is a redundant graph summary that could be omitted, but retaining it for dumps is cheap. A single well-specified target-operation descriptor may cover the few required CPU operations; do not replace typed nodes with an unverified universal opcode bag. SIMD, half, and 128-bit source semantics may use scalar/helper expansions, while their ABI descriptions still retain the information foreign calls need.

## Plan corrections and implementation order

The line cap should be a review-size preference, not a correctness estimate. Once tests, error handling, malformed-input checks, and all called helpers are counted, several proposed steps contain multiple algorithms.

| Proposed step | Underestimated work | Concrete split or order correction |
|---|---|---|
| 4, builder | Control sealing, loop repair, constructor typing, sticky allocation failure, plus a finishing verifier that does not exist yet. | Implement basic construction with a minimal verifier together; then branch merges, then loops/exits. Do not let the finishing API promise verification several stages before it is available. |
| 6, parser | Tokenization, two-pass forward references, sparse IDs, nested declarations, relocations, typed errors, and complete malformed-input checking. | Keep deterministic print immediately; defer a general round-trip parser until the semantic graph format is stable. Use constructors for early tests. |
| 8b, flow verifier | Reachability/dominance plus memory path consistency, phi-edge legality, cycles, and precise backedge handling. | Separate control/SSA verification from memory-state verification. The current 500-line scope relies on the insufficient dominance shortcut in M1. |
| 9, folds/GVN | Exact-width integer behavior, floating constants, semantic keys, OOM handling, rewriting, deduplication, and forwarding representations. | Start with integer constants and a few identities. Add GVN and forwarding independently after semantic tests exist. Its planned interpreter-based test currently precedes the interpreter. |
| 10a-10b, interpreter | Calls/recursion, ABI by-value semantics, activation memory/lifetime, relocations, phi parallel assignment, scheduling dependencies, conversion edge cases, and host effects. | Build a scalar/control evaluator, then memory, then calls. Add native/host facilities separately. Do not call a small host whitelist a runtime-complete interpreter. |
| 11, scheduler | Cyclic graph placement, fixed projections/phis, loop membership, local anti-dependencies, and schedule verification. | Start with builder/source-order scheduling of the fixed control skeleton; add GCM for pure nodes after the loop/effect verifier is established. |
| 12, ABI | Layout, odd-byte pieces, MEMORY versus indirect passing, exhaustion/grouping, return attributes, and foreign interoperability. | Make the whole-signature ABI plan an early dependency of call construction, interpreter calls, and selection. Research doc 07 describes a 1401-line reference ABI implementation; 500 lines including tests is not a credible completeness guarantee. |
| 13-15, allocation | The interface decisions in M10, live-range holes/splitting, constrained registers, spills, move resolution, and verification. | Freeze a minimal supported allocation model first. Add fixed-register rewriting, then calls/spills, then cycle-resolving moves. Do not advertise the full SSA linear-scan algorithm in one 550-line ticket. |
| 16 and 17, backend/lower | Nearly all language semantics, machine expansion, runtime ABI, startup, reflection, and integration are unbudgeted behind "separate doc". | Specify a small complete AST-to-native example before completing every standalone package. Subsequent tickets should name one lowering and its independent reference behavior. |
| 18, deferred support | TLS is compiler+ELF+startup+thread-runtime work; 128-bit division is not merely a new scalar operator; atomics affect verification, scheduling, selection, and tests. | Move the required runtime subset before the `fmt` milestone and split by end-to-end capability, not enum member. |

The printed critical path omits the verifier and several ABI/allocation prerequisites. The parallel list also starts verification of `G1-G2` before GVN exists and starts finishing constructors before their verifier. These can be bootstrapped with explicitly limited interfaces, but the plan should say so rather than assert all steps already have independent tests. `mise run check ir` and `mise run test ir` are not sufficient validation commands for packages implemented under `sched`, `types`, or `regalloc`; each needs its own package check/test task invocation.

A lower-risk order that preserves the chosen IR is:

1. Freeze value representations, effect order, entry/merge/loop sealing, and the whole-signature ABI data model. Write the minimum verifier with the constructors, plus deterministic graph and block dumps.
2. Lower one small typed procedure with a loop, memory, and a call. Use a conservative fixed schedule and compare a scalar interpreter result with the fork. This exposes the package interfaces before a general parser or GVN is built.
3. Emit the same procedure natively with a deliberately simple allocator. Verify the final machine CFG and ABI. Add native tests for source-visible side effects, not just equal final return values.
4. Implement the default-runtime dependency inventory above, including local-exec TLS and startup. First run a raw-syscall executable, then a default-runtime executable, then `fmt.println` and `fmt.printf`.
5. Add pure-node GCM, GVN, and forwarding separately. Keep an unoptimized mode as the comparison path. Measure total compile time and peak memory, including GVN/use tables and verifier scratch, before adding alias slicing or slot promotion.

## What I would cut for a solo or agent-built v1

Keep the owner choices and the typed scalar/effect contract. Cut the general text parser from the first runnable milestone. Keep graph and block dumps. Keep a small interpreter but do not require full OS emulation or complete runtime execution in its first version. Defer global hash-consing and GCM until conservative scheduling works. Defer alias slices, floating loads, aggregate slot promotion, inlining, SCCP, and elaborate rematerialization, as the document mostly already proposes. Do not cut runtime atomics, TLS, required scalar expansions, or correct ABI metadata to make the node list shorter.

Use `kind_info` for names, arity patterns, and other declarative properties. Use a few explicit procedures for dependent typing and per-kind semantics. A table cannot replace the algorithms for interpretation, instruction selection, or projection classification. Trying to encode all of those in one universal descriptor risks recreating the overloaded instruction design criticized in research doc 06.

The V8 warning most applicable here is that reconstructing a schedule and manually maintaining effects create a second source of correctness work. Indexed SoA storage addresses memory locality, not that semantic burden. The simplest version should therefore retain an explicit, verifiable control/effect construction order even though pure values are graph nodes. This remains Sea of Nodes and respects the owner's decision.

## Validation recommendations

Use a few tests that distinguish failure modes rather than one test per kind:

- A sequential-diamonds negative graph for stale memory, plus an ordered volatile/atomic case with unused results.
- A nested-loop exit program with a post statement, labeled continue, fallthrough, a defer registered before context rebinding, and a no-backedge loop.
- A scalar-boundary program covering a wide shift count, `MIN % -1`, signed `%%`, negative slice lows, and dynamic-array length versus capacity.
- A representation program covering addressable `any`, shared-nil and tagless unions, and dynamic `type_info_of`.
- A bidirectional ABI matrix against LLVM-built Odin procedures and Clang-built C procedures. Include register exhaustion, a large aggregate, mixed integer/SSE pieces, odd-size aggregates, small signed/unsigned returns, `i128`, split returns, and context. Whole-language tests and machine ABI tests catch different bugs.
- One default-runtime `fmt` executable without replacing its allocator or disabling TLS to conceal missing support. Treat a raw-syscall executable as a separate, earlier milestone.

The interpreter and scheduler intentionally share the effect rules. Agreement between them cannot prove the rules themselves are right. The official compiler/native comparison must observe writes, defer order, context, error paths, and ABI, not only the final integer or a generic trap result. Preserve signal/termination distinctions where the language/runtime contract specifies them.

No source implementation was changed for this review.

Repository validation was attempted without formatting other agents' files. `mise run check` failed in `src/syntax/parser_test.odin:65` because `os.walker_create` receives both the string and `Allocator_Error` returned by `filepath.join`, and at line 68 because `File_Info` has no `is_dir` field. `mise run fmt --check` reported ten unformatted files: `src/elf/elf_exec.odin`, `src/elf/exec_test.odin`, `src/syntax/ast.odin`, `src/syntax/ast_test.odin`, `src/syntax/parse_decl.odin`, `src/syntax/parse_expr.odin`, `src/syntax/parser.odin`, `src/syntax/parser_test.odin`, `src/syntax/parse_stmt.odin`, and `src/syntax/parse_type.odin`. These files are outside this report's scope and were left unchanged.
