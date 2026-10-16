# Design of package `ir`: a Sea of Nodes IR for Odin

Status: design for review. Scope: package `ir` (graph, builder, verifier, printer, parser, interpreter), plus the interfaces to `sched`, `x64` and `regalloc`. Linux x64 only.

## 1. Prior art and what is reused

Prior-art check (`AGENTS.md`), done before writing:

| Question | Finding | Consequence |
|---|---|---|
| Existing Odin package? | `core/rexcode/ir` (`refs`, `types`, `status`, `print`, `module`) is a structured `Module→Function→Block→Operation` contract for wasm/spirv/llvm codecs (`core/rexcode/docs/ir_design.md` §2-3). It has no effect or control edges. | Reuse vocabulary only (table below). Not a Sea of Nodes. |
| Sea of Nodes in `refs`? | None (`docs/research/04-reuse-survey.md:28,558`). | Graph, verifier, scheduler are ours. |
| Reference designs | Click's Simple tutorial (chapters 5-13, 18-20), V8 post-mortem and Cranelift (`docs/research/02`), Tilde Backend `tb.h` node list, `ASimpleReply.md`. | Adopt the node/edge model of Simple; adopt V8 lessons as constraints (section 13). |
| PR #7850 | `docs/research/06`, `07`: good ideas (deterministic index-order merge, scalars in vregs and aggregates in memory, caller-saved-first allocation, remat); bad shape (fat overloaded `xbInstr`, three hand-kept opcode switches, shared module state plus replay log, `setjmp`). | Adopt the ideas listed in section 13; reject the shape. |
| Vision check | `docs/research/01`: "Sea of Nodes based" is the stated direction; simplest efficient solution; no language change. | See section 2 for how "simplest" is applied. |

Vocabulary taken from `core/rexcode/ir`:

| rexcode | Here | Change |
|---|---|---|
| `Id`, `ID_NONE=0xFFFFFFFF` | `Node_Id`, `NODE_NONE = 0` | Zero value is inert (node 0 is reserved). |
| `Ref_Space`, `Ref` | `Symbol_Space`, `Symbol_Ref` | Only function/global/extern/local-data spaces. |
| `Type_Kind`, `Type_Ref` | `Value_Type` | Scalar classes only; aggregates are memory (section 6). |
| `Error {location, code}` | `Error :: union #shared_nil` (as in `src/elf/writer.odin:28`) | Errors as typed values. |
| `Print_Options`, `Token_Kind` | `Print_Options` | `value_prefix`, `indent`, same names; token spans deferred. |
| `Module`, `Function`, `Global` | same names | `Function` owns an arena and SoA arrays instead of `[]Block`. |
| `Operand`, `Block`, `Operation` | not reused | Nodes replace operations; blocks are derived by `sched`. |

Other facts the design relies on, all checked in the Odin sources under `refs/Odin-upstream/src`:
- `ProcCC_Odin` passes the context pointer as the last parameter (`llvm_backend_proc.cpp:520-526`, `llvm_abi.cpp:2769-2775`); the callee uses it directly as the address of `context` (`llvm_backend.cpp:225-247`).
- Odin multiple returns: all results except the last are returned through pointer parameters appended after the regular parameters; the last is returned directly (`llvm_abi.cpp:394-418`).
- Shifts: a count `>=` width gives 0, and signed `>>` clamps the count to `width-1` (`llvm_backend_expr.cpp:2089-2128`).
- `or_return` is an `if has_value` with a return block (`llvm_backend_utility.cpp:634-680`).

## 2. Decisions

1. **True Sea of Nodes, honest about what floats.** Every value is a node; edges are use-def inputs. In v0 only pure nodes float (arithmetic, compares, casts, address computation, constants, `Phi` stays bound to its region). Every node that touches memory or can trap carries a control input and is pinned to a block. This is Cranelift's "CFG skeleton, floating pure operators" with Click's graph model. Floating loads are deferred (section 11).
2. **One memory chain per function** (section 7). Alias classes deferred.
3. **Scalar-only values.** Aggregates live in memory (stack slots), moved with `Load`/`Store`/`Mem_Copy`. This is the PR #7850 rule "scalars in vregs, everything else by address" and the Tilde rule (TB's Odin backend had `param_nodes` = "parameters, pointers to return values, and context ptr").
4. **ABI-explicit calls.** The IR already contains the SysV/Odin-CC lowering of aggregates (pieces, byval, sret, split returns, context). `x64` only assigns registers.
5. **No control flow is created after `lower`** except by `x64` after scheduling. IR passes never create blocks (V8 problem 11).
6. **Structured, reducible control flow by construction.** Odin has no `goto`. Every loop is a `Loop` node with exactly two inputs.
7. **One table for node properties** (`kind_info`), used by builder, verifier, printer, parser, peepholes and `sched`. No hand-kept parallel `switch`es (PR #7850 failure, doc 06 section 1.3).
8. **`ir` does not depend on `types`.** `docs/01-architecture.md` lists `ir → support, types`. The IR is type-erased to scalars, so the dependency is unnecessary and `ir` tests need no checker. `lower` depends on both. Open question 1.
9. **Instruction selection happens after scheduling, inside `x64`**, on linear blocks (the order is the reverse of Simple chapter 19, which selects before GCM). It keeps `sched` machine-independent and lets folding of single-use loads check "same block, no intervening store".

Rejected, briefly:

| Alternative | Reason |
|---|---|
| CFG SSA with block params (`docs/research/00`) | Owner decision is Sea of Nodes (`docs/01-architecture.md`). We keep its good parts: pinned effects, a CFG skeleton, per-block linear order from `sched`. |
| Alias classes in v0 (Simple ch. 11: `MemMerge`, `MemPhi`, `BulkMemPhi`) | Click's "free from the type system" argument does not hold in Odin: `rawptr`, `transmute`, `cast`, unions and `#raw_union` defeat type-based classes. Needs three extra node kinds and non-local worklist dependencies. |
| Tagged `union` per node payload | Duplicates the tag already in `kinds[]`; 16 bytes per node. We use an 8-byte `#raw_union` indexed by kind. |
| Def-use lists maintained incrementally | Cost on every edit and V8-style stale state. v0 builds a CSR `Use_Table` on demand. |
| Click's lazy loop phis and edge-locked GVN | Needs unlock/relock on every edit. We pre-scan assigned variables per loop and make interned nodes immutable (section 11). |
| `Never`/`forceExit` for infinite loops | Not needed: roots are all pinned nodes, not "reachable from `Stop`". |
| Graph viewer | Click himself says ASCII dumps win (`ASimpleReply.md`). Text dump only. |

## 3. Data structures

Package layout (`src/ir`): `ids.odin`, `kinds.odin`, `graph.odin`, `module.odin`, `builder.odin`, `fold.odin`, `cfg.odin`, `verify.odin`, `print.odin`, `parse.odin`, `interp.odin`. Imports: `support`, `base:runtime`, `core:mem`, `core:mem/virtual`.

```odin
Node_Id :: distinct u32
NODE_NONE :: Node_Id(0)            // node 0 is reserved: kind .Invalid

Value_Type :: enum u8 { None, Control, Memory, Tuple, Bool, I8, I16, I32, I64, F32, F64, Ptr }

Node_Flags :: bit_set[Node_Flag; u8]
Node_Flag :: enum u8 { Volatile, Cold, Rematerialize }

Node_Data :: struct #raw_union {      // meaning given by kind; accessors assert the kind
	int_value:  i64,                  // Const_Int (sign-extended from its width), Ptr_Offset
	float_bits: u64,                  // Const_Float
	index:      u32,                  // Proj index, signature/table/slot id
	symbol:     Symbol_Ref,           // Symbol_Addr
	memory:     Memory_Info,          // Load/Store/Mem_*: align (log2), flags
	slot:       Slot_Info,            // Stack_Slot: size, align
}

Node :: struct {                       // stored as #soa[dynamic]Node: one array per field
	kind:        Node_Kind,
	type:        Value_Type,
	flags:       Node_Flags,
	input_count: u16,
	first_input: u32,                 // index into Function.edges
	data:        Node_Data,
}

Function :: struct {
	id:         Function_Id,
	name:       string,
	signature:  Signature_Id,         // into signatures (function-local table)
	nodes:      #soa[dynamic]Node,    // index = Node_Id; ids are creation order, never reused
	edges:      [dynamic]Node_Id,     // all inputs of all nodes, one arena
	signatures: [dynamic]Signature,
	tables:     [dynamic][]i64,       // switch case values
	blobs:      [dynamic]Data_Blob,   // function-local read-only data (string literals, constant arrays)
	gvn:        Gvn_Table,
	start, stop: Node_Id,
	arena:      virtual.Arena,        // owns every allocation above
	error:      runtime.Allocator_Error, // sticky; first failure wins
}

Use :: struct { user: Node_Id, slot: u16 }
Use_Table :: struct { first: []u32, uses: []Use }   // CSR, built by uses_build; order = (user id, slot)
```

Rules:
- Inputs of a node are `edges[first_input : first_input+input_count]`. **Arity is fixed at creation.** The slice is valid until the next node is added. Region and Phi arity is known when the lowerer has collected its predecessors; a `Loop` is created with `[entry, NODE_NONE]` and its back edge set once (`loop_set_back_edge`). Shrinking a node (`region_remove_input`) is in place and keeps the Phis in lockstep. There is no growth, so no dead edge ranges.
- Nodes are never freed: `remove_node` sets kind `.Removed`, clears inputs. Ids are stable, so dumps are diffable.
- Estimated cost: kind, type, flags (3 B) + count (2 B) + first_input (4 B) + data (8 B) = 17 B per node plus 4 B per edge; about 27 B per node on average.
- One `virtual.Arena` per function (`core/mem/virtual`, as already chosen in `docs/research/04-reuse-survey.md:491`). Functions are built on different threads without sharing anything mutable (section 14).
- Errors: the builder is sticky-error: allocation failure sets `Function.error`; later calls return `NODE_NONE`; `function_finish` returns it. Programmer misuse (wrong arity or type) is caught by `assert` in the builder and by `verify` in all builds; user-input problems (unsupported feature) never reach `ir`, `lower` reports them with a source position.

```odin
Error :: union #shared_nil { Parse_Error, Verify_Error, runtime.Allocator_Error }

Module :: struct {
	functions: [dynamic]Function,     // index = Function_Id = declaration order from `check`
	globals:   [dynamic]Global,       // index = Global_Id
	externs:   [dynamic]Extern,       // index = Extern_Id (name only; resolved by the linker)
	arena:     virtual.Arena,
}

Symbol_Space :: enum u8 { Function, Global, Extern, Local_Blob }
Symbol_Ref :: struct { space: Symbol_Space, index: u32 }

Global :: struct {
	name: string, size, align: u32, mutable: bool,
	bytes:  []byte,                   // nil means zero-initialized (.bss)
	relocs: []Data_Reloc,
}
Data_Reloc :: struct { offset: u32, target: Symbol_Ref, addend: i64 }   // absolute 64-bit only

Calling_Convention :: enum u8 { Odin, Contextless, C }       // C = SysV
Param_Attr :: enum u8 { None, By_Value, Struct_Return, Sign_Extend, Zero_Extend, Context }
Param :: struct { type: Value_Type, attr: Param_Attr, size: u32, align: u16 }  // size/align for By_Value
Signature :: struct { cc: Calling_Convention, variadic: bool, params: []Param, results: []Value_Type } // 0..2 results
```

Only `Module.globals`, `externs` and function names are declared (by `lower`, single-threaded, in `check` order) before any function body is built. During the parallel build, workers only read them. Function-local `Local_Blob` entries are merged into the module in function-index order at the end, deduplicating by content (section 14).

## 4. Node kinds (v0)

Every node has one output value of type `Value_Type`. Multi-output nodes have type `Tuple`; members are read with `Proj(tuple)` (index in `data.index`), as in Simple and TB. Integer types carry no signedness: the operation does. Integers wrap (two's complement); `Const_Int` is stored sign-extended from its width, so equal constants are equal nodes.

"Pinned" means the node has a control input (slot 0 = the head of its block, section 5) and `sched` never moves it out of that block. Everything else is "pure": no control input, immutable, hash-consed (section 11), free to float.

| Kind | Inputs | Output | Class | Notes |
|---|---|---|---|---|
| `Start` | none | Tuple(ctrl, mem, params…) | control | Params are `Proj` 2..n, in signature order, incl. sret pointers, split-return pointers and the context pointer. |
| `Stop` | terminators… | none | control | Root for traversals; one per function. |
| `Region` | ctrl heads (≥2) | Control | control | Merge point; block head. |
| `Loop` | entry, back edge | Control | control | Exactly 2 inputs; block head; marks loop nesting. |
| `If` | ctrl, cond:Bool | Tuple(ctrl, ctrl) | control | `Proj 0` = true, `Proj 1` = false; each projection heads its own block (no critical edges). `Cold` flag on a `Proj` marks panic paths. |
| `Switch` | ctrl, value | Tuple(ctrl × (cases+1)) | control | `data.index` = case table; `Proj k` for `k < n` is case k, `Proj n` is default. |
| `Proj` | tuple | member type | control or pure | Projection of a control tuple is a block head. |
| `Return` | ctrl, mem, results… | none | terminator | 0-2 scalar results matching the signature. |
| `Unreachable` | ctrl, mem | none | terminator | Optimizer may assume it is never executed; `x64` emits `ud2`. |
| `Trap` | ctrl, mem | none | terminator | `intrinsics.trap()`; executes `ud2`. |
| `Const_Int` | none | Bool/I8..I64/Ptr | pure, remat | `data.int_value`. `Ptr` constant is the null pointer or an absolute address. |
| `Const_Float` | none | F32/F64 | pure, remat | Raw bits. |
| `Undef` | none | any scalar | pure | `---` and phi arms with no value. Interpreter yields 0. |
| `Symbol_Addr` | none | Ptr | pure, remat | `data.symbol`: function, global, extern or local blob. |
| `Stack_Slot` | ctrl (=`Start`) | Ptr | pinned to entry | `data.slot` size/align. Unique, never interned. Frame layout is `x64`'s. |
| `Phi` | region, values… | any incl. Memory | bound to region | One value per region input, same order. |
| `Add Sub Mul And Or Xor` | a, b | I8..I64 | pure | `Bool` allowed for `And Or Xor`. Commutative ones sort inputs by id. |
| `Shl Shr Sar` | a, count | same as a | pure | Count `< width` only; larger is undefined. `lower` emits the Odin rule (section 8). `count` has the type of `a`. |
| `SDiv UDiv SRem URem` | ctrl, a, b | I8..I64 | **pinned** | Can trap (÷0, `MIN/-1`); must not float above a guard. Not on the memory chain. |
| `Eq Ne SLt SLe ULt ULe` | a, b | Bool | pure | `>` and `>=` are canonicalized by swapping. `Eq/Ne` also on `Ptr`, `Bool`. |
| `FEq FLt FLe FNe` | a, b | Bool | pure | Ordered, except `FNe` which is true on NaN (Odin and C semantics). |
| `FAdd FSub FMul FDiv FNeg` | a[, b] | F32/F64 | pure | IEEE; no fast-math. |
| `Select` | cond, a, b | type of a | pure | Only for operands that are already evaluated (shift clamp, `min`, `max`). Never for `x if c else y` with effects. |
| `Trunc Zext Sext` | a | I8..I64/Bool | pure | `Trunc` to `Bool` keeps bit 0 (`i8 → i1`, as LLVM does for Odin `bool`). |
| `Bitcast` | a | same size | pure | int↔float, int↔`Ptr`. |
| `Sint_To_Float Uint_To_Float Float_To_Sint Float_To_Uint Float_Ext Float_Trunc` | a | F32/F64/int | pure | `x64` expands `u64↔float` after scheduling (it needs a branch). |
| `Ptr_Offset` | base | Ptr | pure | `base + data.int_value`. Field access. |
| `Ptr_Index` | base, index:I64 | Ptr | pure | `base + index * data.index` (stride). Array and slice element access. |
| `Load` | ctrl, mem, ptr | scalar | pinned | `Volatile` flag; align in data. Result unused and non-volatile: removable. |
| `Store` | ctrl, mem, ptr, value | Memory | pinned | |
| `Mem_Copy` | ctrl, mem, dst, src, size:I64 | Memory | pinned | Overlap allowed (memmove semantics). `x64` expands inline; no libc. |
| `Mem_Set` | ctrl, mem, dst, byte:I8, size:I64 | Memory | pinned | |
| `Call` | ctrl, mem, callee:Ptr, args… | Tuple(mem, r0[, r1]) | pinned | `data.index` = function-local signature id. Direct call = `callee` is a `Symbol_Addr`. |
| `Syscall` | ctrl, mem, number, args (≤6) | Tuple(mem, I64) | pinned | `intrinsics.syscall`; needed by `core:sys/linux`. Clobbers `rcx`, `r11`. |

Total: 63 kinds plus `Invalid` and `Removed`.

Deferred (the checker or `lower` must report `Unsupported(feature, position)`, never emit something approximate):

| Area | Deferred kinds | Why deferred |
|---|---|---|
| Bit tricks | `Popcnt Clz Ctz Bswap Rotl Rotr Mul_Hi` | Pure, trivial to add (stage 14); `core:math/bits` needs them soon after hello world. |
| Overflow arithmetic | `Add_Overflow` etc. (`intrinsics.overflow_*`) | Pure tuples; add with the bit tricks. |
| Float math | `FSqrt FAbs FMin FMax Fma Floor Ceil` | `intrinsics.sqrt` is `sqrtsd`; add with the bit tricks. |
| 128-bit and 16-bit | `I128`, `F16` value types | `base:runtime` uses `u128` division. Open question 2. |
| SIMD, matrix | vector value types, `#simd`, `matrix` | Out of v0; arrays and complex/quaternion arithmetic are expanded to scalars by `lower`. |
| Atomics | `Atomic_Load/Store/Rmw/Cas`, `Fence` | Memory-chain nodes with a full-barrier meaning; additive. |
| Inline asm, target intrinsics | `Asm`, `cpuid`, `rdtsc`, `xgetbv` | Odin roadmap item; one opaque effectful node later. |
| Thread-local data | `Tls_Addr` | `base:runtime` uses `@(thread_local)` (`core_builtin.odin:63`, `heap_allocator_implementation.odin:2173`). Needed soon after hello world. Open question 3. |
| Dynamic stack | `Stack_Alloc` (`intrinsics.alloca`) | Pinned, changes frame layout. |
| Control folding | `Dead` control constant | No branch folding in v0 (section 11). |
| Floating loads | `Load` without control, guard cast | Needs Click's `Cast` guard (section 11). |
| Debug info | `Stack_Slot.debug_name`, variable scopes | DWARF is a later milestone. |

## 5. Control, blocks and phis

Blocks are derived, not stored. A **block head** is `Start`, `Region`, `Loop`, or a `Proj` of an `If`/`Switch` (Simple chapter 13, "Identification of Basic Blocks"). A block is the head plus every pinned node whose slot-0 control input is that head, plus exactly one **exit**: an `If`/`Switch`/`Return`/`Unreachable`/`Trap` whose control input is the head, or an edge into a `Region`/`Loop` whose input is the head. A jump needs no node: a `Region` input is the head of the predecessor block.

Rules the builder and `lower` follow:
- **Current control** in `lower` is a block head or `CTRL_NONE` (unreachable). While it is `CTRL_NONE` no node is emitted. Merges drop dead predecessors; a merge with one live predecessor is not created (the lowerer continues in that block). A `Region` has ≥2 inputs.
- **Loops**: `loop_begin(entry) → Loop`, body built with the header as current control, every `continue` jumps to one `continue Region` (created on demand; if only the bottom of the body reaches the back edge there is none), `loop_end(loop, back_source)` sets input 1. Every `break` jumps to one exit `Region`. Phis for variables assigned in the body are created at `loop_begin` from a pre-scan of the loop body (variables assigned, plus always the memory phi), with the back-edge input set by `loop_end`. After `loop_end`, a phi whose back input is itself or equals its entry input is replaced by the entry value by the one-off pass `phis_simplify`, which then calls `gvn_rebuild` (section 11).
- **Branch merges**: `lower` compares the per-variable node ids of the arms; a `Phi` is created only where they differ.
- **Switch** on integers: one `Switch` with a case table and one default. Strings and type switches are `If` chains or a switch on the tag.
- Reducibility: back edges exist only as `Loop` input 1. Verified (`C5`).

Builder surface for control (all return `Node_Id`, sticky error): `start(fn)`, `if_(fn, ctrl, cond) → (true_head, false_head)`, `switch_(fn, ctrl, value, cases) → (case_heads, default_head)`, `region(fn, preds)`, `loop_begin`, `loop_end`, `phi(fn, region, values)`, `ret(fn, ctrl, mem, results)`, `trap`, `unreachable`, `function_finish(fn) → Error` (creates `Stop`, runs `phis_simplify`, `verify`).

## 6. Calls, ABI and aggregates

**Aggregates are memory.** Structs, arrays, slices, strings, `any`, unions, dynamic arrays, maps, complex numbers and `context` itself are stack slots or globals, addressed by `Ptr`. `lower` loads and stores their scalar fields; whole-value copies use `Mem_Copy`; zero-initialization and `---` use `Mem_Set` or nothing. A local whose address is never taken and whose type is scalar is not a slot at all: it is an SSA variable in the lowerer's scope (Simple's `ScopeNode` idea), joined with phis (section 5). Slot promotion for small aggregates (slice, string) is a later pass (stage 15).

**Calls carry scalars only.** `lower` asks `types` for the parameter classification (SysV eightbyte classes; the Odin-CC variant is extracted from `llvm_abi.cpp`; the classifier is `types` work, `docs/research/07` §2) and builds the call:

| Source value | Lowered to |
|---|---|
| Scalar | One argument of that `Value_Type`; small ints get `Sign_Extend`/`Zero_Extend`. |
| Aggregate ≤16 B classified INT/SSE | 1-2 scalar arguments loaded from the aggregate. |
| Aggregate in MEMORY class | `Ptr` argument with attr `By_Value` and size/align; `x64` copies it to the outgoing area. |
| Aggregate result ≤16 B | 1-2 scalar results (`Tuple(mem, r0, r1)`), stored to a slot by the caller. |
| Aggregate result >16 B | Hidden first argument, attr `Struct_Return`. |
| Multiple results, `Odin` cc | Results 0..n-2 are `Ptr` parameters appended after the regular parameters (caller passes `Stack_Slot` addresses and loads afterwards), result n-1 is the return value. Same layout as the official compiler. |
| `context` | Last parameter (attr `Context`) of every `Odin`-cc function; the caller passes its current context pointer. `Contextless` and `C` have none. |
| C variadic | `variadic = true`; `x64` sets `al` to the number of vector register arguments. |

Order of parameters of an `Odin`-cc function: `[Struct_Return] regular… split-result-pointers… context`.

Calls to functions in the module are `Call` with a `Symbol_Addr` callee; indirect calls pass any `Ptr`. Calls that never return (`-> !`, panics) are followed by `Unreachable(ctrl, mem)` consuming the call's memory, which keeps the call alive.

Register assignment, stack-argument placement, `rsp` alignment, callee-saved handling and the red zone belong to `x64`; `Call` and `Start`/`Return` tell it everything through the signature.

## 7. Memory model

**Recommendation for v0: one memory chain per function.** This is Simple chapter 10 ("One memory value"), which Click himself builds first; chapter 11 splits it later.

- `Memory` is a value type. `Start` produces the initial state (`Proj 1`). `Store`, `Mem_Copy`, `Mem_Set`, `Call` (member 0), `Syscall` (member 0) and memory `Phi` produce a new state. `Load`, `Return`, `Unreachable`, `Trap` and the producers consume one. Every function exit consumes the current state, which keeps stores alive (Simple: "Every Return consumes the current whole-memory value").
- `lower` keeps the current state in a hidden variable `$mem` in the same scope structure as other variables, so branches and loops merge it with ordinary phis.
- A `Load` does not produce a state, so many loads may read one state and `Load(Store(m,p,v), p)` with the identical pointer node and size can be forwarded (section 11).
- **Order inside a block** is recovered by `sched` from four rules, nothing else: (1) data inputs, (2) producer before consumer of a state, (3) **anti-dependence**: a `Load` reading state `m` runs before every other consumer of `m` that takes the state over (a `Store`, `Call`, a `Phi` input on that edge, a `Return`), (4) ties broken by node id (source order for builder output). Rule 3 is Simple chapter 13 "Inserting Anti Dependencies" without alias filtering.
- **Linearity** (verifier `M3`): two consumers of one state that take it over must be on mutually exclusive paths (neither block dominates the other, and not the same block). A violation is a forked or stale chain: the V8 bug class "three effect chains were conflated". A `Load` whose state was already taken over by a store in a block that dominates it is unsatisfiable (`M4`).
- Loads and stores are pinned (section 2), so they cannot move above a bounds check or a null test. Division is pinned for the same reason and is not on the chain.
- `Stack_Slot` addresses are plain pointers. All slots, globals and heap objects share the chain; this is conservative and always correct. Later refinement: non-escaping slots (address only used by `Load`/`Store`/`Ptr_*` chains) are sound alias classes by construction, and a `MemSplit/MemMerge` pair can be added without changing existing node layouts.
- `Volatile` loads and stores are kept and never forwarded. Atomics (deferred) are chain nodes with full-barrier meaning.

## 8. How Odin features lower

Everything in this section happens in `lower` (AST + types → `ir`), which the architecture table does not list yet (open question 1). The IR sees only the result.

**Multiple return values.** Callee: results 0..n-2 are `Store`d through the extra pointer parameters, result n-1 is passed to `Return` (1 or 2 scalar pieces, or stored through `sret`). Named results are slots (or SSA variables) read by a bare `return`. Caller: one `Stack_Slot` per extra result, in the entry block; after the `Call`, `Load`s feed the destructuring assignment.

**`defer`.** No `defer` node exists. `lower` keeps a stack of deferred statements per scope and, at every scope exit (`return`, `break`, `continue`, `or_return`, `or_break`, `or_continue`, fallthrough of the block), emits the pending bodies inline in reverse order, duplicating the code (same as `lb_emit_defer_stmts`). A `return` evaluates its operands, stores named results, runs the defers, then `Return`.

**`or_return` / `or_else`.** `v, err := f() or_return` becomes: lowered call; `has_value` test (`err == nil`, or a tag compare for union errors); `If`; the false branch converts `err` to the last result type, stores it to the named result or sets the single result, runs defers, `Return`; the true branch continues. `or_else` is the same with a `Select`-free branch and a `Phi`. No special IR support.

**Slices, strings, dynamic arrays, `any`.** 16, 16, 40 and 16 byte aggregates in slots: `{data: Ptr, len: I64}`, `{data, len, cap, allocator{procedure, data}}`, `{data: Ptr, id: I64}` (`base:runtime` `Raw_Slice`, `Raw_Dynamic_Array`, `Raw_Any`). `len(s)` is `Load(Ptr_Offset(slot, 8))`. Passing a slice or string by value is two `I64`/`Ptr` arguments. `append`, `make`, `delete`, `map` are calls into `base:runtime`; map metadata is constant global data with relocations to function addresses.

**Unions, `any`, `typeid`.** A union is `{variant area, tag}` laid out by `types`; the tag is an integer load; `switch v in u` is a `Switch` on the tag. `u.(T)` is a tag compare plus the panic path. `typeid` is an `I64` constant from `types`; `any(x)` stores a pointer to a stack copy and the `typeid` constant. `type_info_of(T)` is `Symbol_Addr(type_table) + Ptr_Index`. The type table and string tables are generated global data with relocations (`llvm_backend_type.cpp` is the behavioural reference).

**Bounds checks and the panic path.** `a[i]` becomes `ok = ULt(i, len)`, `If(ok)`; the false projection carries `Cold` and calls the runtime error procedure with the source location (`file` string blob, `line`, `column` constants, `index`, `len`, plus the context pointer when the chosen variant is not contextless, see `base/runtime/error_checks.odin:27,45`), then `Unreachable`. Slice expressions check `lo <= hi <= cap` the same way. `#no_bounds_check` and `-no-bounds-check` make `lower` emit nothing. `sched` places `Cold` blocks last. No inliner is needed because the check is explicit.

**Shifts.** `lower` emits `Select(ULt(count, W), Shl(x, count), 0)`; for signed `>>`, `Sar(x, Select(ULt(count, W), count, W-1))`. Folding removes the select when the count is constant (matches `llvm_backend_expr.cpp:2089-2128`).

**`context`.** The incoming context pointer is `Proj` of `Start`, used directly as the address of `context`. `context.allocator = a` allocates a `Stack_Slot`, `Mem_Copy`s the old context into it, `Store`s the field and rebinds the lowerer's current-context variable; calls pass the current one. At scope exit the previous binding returns, as in `lb_push_context_onto_stack`.

**Proc groups, polymorphism.** The checker resolves groups and monomorphizes; `lower` receives one concrete procedure per instance, each a separate `Function` with a mangled name. A group call is a direct call to the chosen member. `$T` values are constants. The order of instances must be deterministic (checker requirement).

**Globals and constant data.** Constant-initialized globals, string literals, constant arrays/slices, `Source_Code_Location` values, type info and vtable-like tables become `Global` or `Local_Blob` bytes plus `Data_Reloc`s (absolute 64-bit address of a function, global or blob plus addend). Globals with non-constant initializers are set by a generated startup procedure in the checker's dependency order. `Symbol_Addr` yields the address; `x64` emits `lea rip+disp32` and the ELF relocation.

**Integers.** `i8..i64`, `uint`, `uintptr`, enums, `bit_set`, `bool` (`I8` in memory, `Bool` as a value) map directly. `bit_field` access is load, shift, mask. `i128/u128`: open question 2.

**Foreign and runtime calls.** `foreign` procedures become `Extern` symbols with the `C` convention. `intrinsics.mem_copy/mem_zero` → `Mem_Copy/Mem_Set`; `intrinsics.trap` → `Trap`; `intrinsics.unreachable` → `Unreachable`; `intrinsics.syscall` → `Syscall`; `volatile_load/store` → flagged `Load/Store`; `expect` is dropped. Any other intrinsic not in the v0 set is reported `Unsupported`.

## 9. Verifier invariants

`ir.verify(fn, allocator) -> []Verify_Error` runs after the builder finishes and after every pass in debug builds (`-define:IR_VERIFY=true`); the unit tests and `-dump-ir` always run it. Each error has `{node, other, code}`. The properties come from `kind_info` (arity, slot types, result rule, purity, pinned), so there is one table to keep correct.

Structure
- `S1` node 0 is `Invalid`; node `start` is `Start`; exactly one `Start` and one `Stop`.
- `S2` every input id `< node count`, none is `Removed`; `NODE_NONE` appears only in unfinished loop back edges, and not at all after `function_finish`.
- `S3` arity of each node is within `kind_info`; `Region ≥ 2`, `Loop = 2`, `Phi = region arity + 1`, `Switch` projections = cases + 1.
- `S4` each input's `Value_Type` matches the slot rule; result type matches the rule (`Add` operands and result equal; `Eq` operands equal, result `Bool`; `Load` result is scalar; `Const_Int` value fits its width in sign-extended canonical form).
- `S5` `Proj` input is `Tuple`, index in range, type equals the tuple member; every `If` has both projections exactly once, every `Switch` all of its projections.
- `S6` `Call` argument and result types match its signature; `Return` operand types match the function signature; `Start` params match it; `Stack_Slot` has `size > 0`, power-of-two `align`, control input `Start`; symbol, table and signature indices are in range; case values are unique.
- `S7` removed nodes have no inputs and no users; `Stop` inputs are exactly the terminators.

Control (needs `cfg.odin`)
- `C1` a slot-0 control input is a block head; every pinned node and terminator has one.
- `C2` every block head has exactly one exit (section 5).
- `C3` every head is reachable from `Start` by control edges.
- `C4` `Loop` input 0 is not dominated by the loop; input 1's source is dominated by it.
- `C5` reducible: every retreating edge in a DFS of the control graph is a `Loop` back edge.
- `C6` `Phi` input 0 is a `Region`/`Loop`; all value inputs have one type (or `Memory`); no `Control` phis.

Memory
- `M1` memory-typed values are produced only by `Start`, `Store`, `Mem_Copy`, `Mem_Set`, `Call`/`Syscall` member 0, memory `Phi`.
- `M2` every `Load/Store/Mem_*/Call/Syscall/Return/Unreachable/Trap` has exactly one memory input; no other node has one.
- `M3` linearity as in section 7 (no fork, no stale state at an exit).
- `M4` no `Load` is pinned in a block strictly dominated by a block that takes over its state.

Dataflow
- `D1` schedulability: for every pinned node and every phi edge, each input's earliest block (pinned: its own block; pure: the deepest of its inputs' earliest blocks, which must form a dominator chain; constants and `Symbol_Addr`: entry) dominates the use block (for a phi, the matching predecessor block). This is the "value used on a path that does not define it" check.
- `D2` division, `Load`, `Store`, `Call` etc. have a control input (pinned classes from `kind_info`).

Interning (debug only)
- `G1` every live pure node is in the GVN table under its own key and no two live nodes share a key.
- `G2` no node mutated after interning (checked by re-hashing).

`sched` has its own `verify_schedule`: every non-rematerialized node appears exactly once, in a block that dominates its uses; definitions precede uses inside a block; phis lead their block; each `Load` precedes every state-taking consumer of its state; the block order is a valid layout (entry first, `Cold` last).

## 10. Text format, parser and interpreter

The dump is the primary debugging surface (V8 problem 1; Click: "ASCII dumps rule"). It prints the graph in id order, one node per line, with explicit ids, so `parse(print(f))` reproduces the same ids and `print(parse(print(f))) == print(f)` byte for byte. Ids may be sparse (removed nodes are skipped).

```
module      = { global | extern | function } ;
global      = "global" GID STRING "size" INT "align" INT [ "mut" ]
              [ "bytes" HEX ] { "reloc" INT "->" symref [ ("+"|"-") INT ] } ;
extern      = "extern" XID STRING ;
function    = "func" FID STRING "sig" "=" SID "{" { sigdecl | tabledecl | blobdecl | nodeline } "}" ;
sigdecl     = "sig" SID "cc" ("odin"|"contextless"|"c") [ "variadic" ]
              "(" [ param { "," param } ] ")" "->" "(" [ vtype { "," vtype } ] ")" ;
param       = vtype { ":" ("byval" "(" INT "," INT ")" | "sret" | "sext" | "zext" | "context") } ;
tabledecl   = "table" TID "=" "[" INT { "," INT } "]" ;
blobdecl    = "blob" BID STRING HEX { "reloc" INT "->" symref [ ("+"|"-") INT ] } ;
nodeline    = NID "=" KIND "." vtype [ operands ] { attr } ;
operands    = ref { "," ref } ;
ref         = NID | "_" ;                      (* "_" is NODE_NONE, loop back edge only *)
attr        = "value" "=" INT | "bits" "=" HEX | "index" "=" INT | "offset" "=" INT
            | "stride" "=" INT | "size" "=" INT | "align" "=" INT | "sym" "=" symref
            | "sig" "=" SID | "table" "=" TID | "volatile" | "cold" ;
symref      = FID | GID | XID | BID ;
vtype       = "none" | "ctrl" | "mem" | "tuple" | "bool" | "i8" | "i16" | "i32" | "i64" | "f32" | "f64" | "ptr" ;
NID = "n" DIGITS ; FID = "f" DIGITS ; GID = "g" DIGITS ; XID = "x" DIGITS ;
SID = "s" DIGITS ; TID = "t" DIGITS ; BID = "b" DIGITS ; HEX = 'x"' hexdigits '"' ;
comments run from ";" to end of line
```

The header names the function's own signature (`sig=s0`). Attribute order and the set per kind come from `kind_info`; the printer emits them in a fixed order and the parser accepts only that order, so the format has one spelling. Example (`func add_or_zero(a, b: i64, c: bool) -> i64`):

```
func f0 "main.add_or_zero" sig=s0 {
  sig s0 cc c (i64, i64, bool) -> (i64)
  n1  = start.tuple
  n2  = proj.ctrl n1 index=0
  n3  = proj.mem n1 index=1
  n4  = proj.i64 n1 index=2
  n5  = proj.i64 n1 index=3
  n6  = proj.bool n1 index=4
  n7  = if.tuple n2, n6
  n8  = proj.ctrl n7 index=0
  n9  = proj.ctrl n7 index=1
  n10 = add.i64 n4, n5
  n11 = region.ctrl n8, n9
  n12 = const.i64 value=0
  n13 = phi.i64 n11, n10, n12
  n14 = return.none n11, n3, n13
  n15 = stop.none n14
}
```

`sched` also prints blocks (`block b2 head=n12 depth=1 preds=[b1,b4]: …`) for golden tests; that form is print-only.

**Parser** (`parse.odin`): two passes over the tokens of a function: pass 1 allocates every node id mentioned (so loop back edges and phis can refer forward) and records kind/type; pass 2 fills inputs and attrs. Errors are `Parse_Error{line, column, code}` values. Hash-consing is not applied while parsing; the GVN table is rebuilt at the end (`gvn_rebuild`).

**Round-trip tests** (few, meaningful): (1) a corpus of hand-written graphs, one per construct (if, loop, switch, call with split results, memory phi, global with relocation); (2) graphs produced by the builder in the interpreter tests. Both check `print∘parse∘print` identity and `verify == ok`. A table-driven negative test feeds one broken text per verifier code.

**Interpreter** (`interp.odin`, ~600 lines, the differential-testing oracle, after Simple chapter 8 and `Eval2` of chapter 18):
- Memory is one flat byte array (64 MiB default) at base `0x10000`; null and low addresses fault. Globals are laid out in id order with relocations applied; each activation allocates its `Stack_Slot`s. Pointers are plain `u64`.
- Execution starts at `Start` and walks blocks. At a block: pure nodes are evaluated on demand and memoized by a generation counter that increments whenever a pinned node produces a value or a phi is updated; pinned nodes are executed in the order of the four rules of section 7 (data, state, anti-dependence, node id); then the exit is taken. Phi inputs are all read before any phi of the region is written (parallel assignment; Simple chapter 8's warning).
- Calls to module functions create a new activation; calls to `Extern` symbols go through a host table (`write`, `exit`, test hooks). `Syscall` supports a small whitelist. `Trap` and `Unreachable` end the run with a result code, so panics and bounds-check failures are comparable with the LLVM-built program's exit code.
- Fuel limit on executed blocks; every run ends with a result value or a typed `Run_Error`.
- It runs the **unscheduled graph with the local ordering rules only**, independent of GCM. A second mode runs a `sched` schedule, so a disagreement between the modes localizes bugs to `sched`.

Differential testing: Odin program → (a) official `odin` binary output, (b) our IR in the interpreter, (c) our native binary. Results and exit codes must agree. Where Odin leaves behaviour undefined (÷0, out-of-range float→int) tests avoid it.

## 11. Peepholes and GVN (v0, kept minimal)

All v0 simplification happens **at node creation** in the builder (`fold.odin`), so definitions are visited before uses and no worklist or global walk exists (V8 problem 6). In order, for pure kinds:

1. **Constant folding**: both inputs `Const_*` → one constant, with exact width wrap, shift rules (count `≥` width is left unfolded), `Trunc/Zext/Sext`, compares, float ops (host SSE semantics equal target semantics on x64). Division is pinned and is folded only when both operands are constant and the divisor is non-zero and not the `MIN/-1` case.
2. **Canonical form**: commutative operands ordered by node id; constants second; `a > b` becomes `b < a`.
3. **Identities** (small fixed list): `x+0, x-0, x|0, x^0, x<<0, x*1, x&-1` → `x`; `x*0, x&0` → `0`; `x-x, x^x` → `0`; `Eq(x,x)` → `true`; `Select(c,a,a)` → `a`; `Select(true/false,…)`; `Zext(Zext x)`, `Trunc(Zext x)` back to the original width; `Ptr_Offset(Ptr_Offset(p,a),b)` → one offset; `Ptr_Offset(p,0)` → `p`.
4. **Hash-consing** of pure nodes: open-addressing table of `Node_Id`, key = kind, type, inputs, data; lookups only, **never iterated**, so no ordering dependence. Constants are deduplicated by this. Pinned, `Region`, `Loop`, `Phi`, `Stack_Slot` and effect nodes are never interned.
5. **Store-to-load forwarding**: `Load(ctrl, m, p)` where `m` is a `Store` whose pointer node is `p` (same id), same width, non-volatile → the stored value (bit-cast if types differ). Sound with one chain because `m` is the exact current state.

**Immutability rule.** An interned node is never edited. The only edits to existing nodes are to non-interned kinds (`Loop` back edge, `Phi` inputs, `Region` shrinking, `Stop` inputs). This removes Click's edge-lock/unlock protocol. Any whole-graph pass that must rewrite inputs of interned nodes (`phis_simplify`, later SCCP) runs `uses_build`, rewrites, then `gvn_rebuild`.

**Deferred**, in rough order of value: iterate-to-fixpoint worklist with distant-neighbor dependencies (Simple chapter 9, needs `Use_Table` kept incrementally); phi/load factoring (Simple chapters 10-11); SCCP and dead-branch removal with a `Dead` control constant and `region_remove_input` (Simple chapter 24); dead-store elimination; alias classes; floating loads guarded by `Cast` nodes (Click's null/range guard casts); range-check elimination; inlining; loop-invariant motion beyond what GCM does for pure nodes; Cranelift-style e-graph for pure nodes (doc 02 §4, rejected for v0).

Dead code elimination in v0 is one pass: mark from all pinned nodes and phis, tombstone unmarked pure nodes and unused non-volatile `Load`s.

## 12. Pass pipeline

```
check (typed AST)
  → lower        per function, parallel; AST + types → ir.Function (builder + fold + loop phis)
  → ir.verify
  → ir.dce, ir.phis_simplify                      (v0 cleanup)
  → ir.verify
  → sched.schedule   cfg (blocks, RPO, dominators, loop depth) → schedule early → schedule late → local order
  → sched.verify_schedule
  → x64.select       linear blocks of ideal nodes → machine instructions on virtual registers
  → regalloc.allocate  liveness → intervals → assignment → parallel-move resolution → regalloc.verify
  → x64.emit         prologue/epilogue, spill code, block layout (Cold last), branch fix-up, encode with core:rexcode/isa/x86
  → elf builder (src/elf)
```

`-dump-ir=<pass>` prints the graph (or the schedule after `sched`) at the named point; deterministic, so dumps are golden-testable.

**`sched` (separate package; GCM, Click 1995 and Simple chapter 13).**
- Inputs: a verified `ir.Function`. Output: `Schedule { blocks: []Block }`, each block `{head, nodes: []Node_Id (final order), preds, succs, depth, cold}`.
- Steps: `cfg` from `ir/cfg.odin` (heads, RPO, immediate dominators by Cooper-Harvey-Kennedy, loop depth from `Loop` nodes: no loop discovery); **early**: each pure node goes to the deepest of its inputs' blocks; **late**: walk uses (a `Phi` use counts at the matching predecessor block), take the least common dominator of uses, then walk up toward the early block choosing the shallowest loop depth, then the deepest block; **local order** inside a block: list scheduling by the rules of section 7, ties by node id. Pinned nodes keep their block, `Stack_Slot` stays in the entry block.
- `Const_*`, `Undef`, `Symbol_Addr` have `Rematerialize`: they are not scheduled; `x64` materializes them at each use (Simple chapter 18: "shared constant expressions get a local copy in each function that uses them"; PR #7850 `remat`).
- Hoisting a pure node to the common dominator of uses on exclusive paths can compute it where one path does not need it (V8 problem 5). v0 accepts this for cheap nodes; it has no pure expensive node (`Div` is pinned, there is no `FSqrt` yet).
- The PR #7850 cold-block layout belongs here: blocks reachable only through `Cold` projections are placed last.

**`x64.select`.** Greedy per-block tree matching on the schedule, using use counts: single-use `Load` folds into the ALU operand or compare; `Ptr_Offset`/`Ptr_Index` chains fold into `[base + index*scale + disp]`; `Cmp` feeding only the block's `If` fuses with `jcc`; phi nodes become parallel copies on the incoming edges (each edge has its own block, so no critical edges). ABI lowering from `Signature`: argument/result registers, `byval` copy, `sret`, `al` for variadics, `rsp` alignment, scratch contract stated once as a `bit_set`. Expansions that need new control flow (`u64↔float`, `Select` of floats, `Switch` jump tables) happen here, after scheduling. Instruction encoding is `core:rexcode/isa/x86`, never reimplemented.

**Register allocation (package `regalloc`, standalone; imports nothing from `ir` or `x64`).** The interface is data:

```odin
Vreg :: distinct u32
Register_Class :: enum u8 { Int, Float }
Constraint :: enum u8 { Any, Fixed, Reuse_Input }          // Fixed: reg in operand; Reuse_Input: two-address ops
Position :: enum u8 { Early, Late }                        // when a use/def happens within an instruction

Operand :: struct { vreg: Vreg, role: enum u8 { Use, Def, Use_Def }, position: Position, constraint: Constraint, fixed: u8, reuse: u8 }
Instruction :: struct { operands: []Operand, clobbers: Register_Set, is_call: bool, is_move: bool }
Block :: struct { instructions: []Instruction, successors: []u32, edge_moves: [][]Move, depth: u8 }
Program :: struct {
	blocks: []Block, classes: []Register_Class,            // class per vreg
	allocatable: [Register_Class]Register_Set, callee_saved: Register_Set,
}
Location :: union { Register, Spill_Slot }
Result :: struct { location: []Location, inserted_moves: []Move_At, spill_slot_count: u32 }   // errors as values
allocate :: proc(program: ^Program, allocator: mem.Allocator) -> (Result, Error)
```

Model: liveness by backward dataflow on the block graph (loop depth weights from `Block.depth`); linear scan over live intervals in the Wimmer/Mössenböck SSA style (doc 02 §7.2), early/late positions, fixed and reuse-input constraints, call clobbers, caller-saved-first unless the interval crosses a call, rematerialization for constants (`remat` operands), spill by cost = uses × weight ÷ length, **parallel-move resolution with cycle breaking inside this package**. `verify` checks no two live vregs share a location, constraints hold, and clobbers are respected. A graph-colouring allocator (Simple chapter 20) can replace the middle later without changing `Program`.

## 13. Risk register

Each V8 failure mode from `docs/research/02-backend-ir-landscape.md` §1.4 (numbering as there), then the PR #7850 and Tilde lessons.

| # | Failure mode | Mitigation in this design | Check |
|---|---|---|---|
| 1 | Graph is a hard-to-read "soup" | Deterministic text dump with stable ids, per-pass `-dump-ir`, block-form dump after `sched` (sections 10, 12). ASCII only. | Round-trip tests |
| 2 | Nearly everything ends up on the effect/control chain | Accepted openly: v0 pins all memory ops and divisions to blocks; only pure nodes float (Cranelift's split). No claim of hoisting loads. | Verifier `D2` |
| 3 | Memory ops do not float | Same; floating loads deferred behind guard casts (section 11). | – |
| 4 | Effect/control chains managed by hand, conflated chains bug (crbug 41470351) | One linear chain; `lower` carries it as the hidden variable `$mem` through the same scope/phi machinery as locals; verifier `M1-M4`; interpreter runs the unscheduled graph and the schedule. | `M3` negative tests, differential tests |
| 5 | Scheduler complexity, CSE then re-duplication | GCM is its own package and moves only pure nodes; constants/addresses are rematerialized instead of scheduled; no pure expensive node exists in v0. | `verify_schedule` |
| 6 | Bad visitation order; peepholes change a node once per ~20 visits | v0 folds at creation, in definition order; no global walk. Later fixpoint uses a worklist plus `Use_Table` (Simple chapter 9), never "walk up from returns". | – |
| 7 | State tracking expensive; load elimination bails out on big graphs | No global load elimination in v0. Only O(1) store→load forwarding on the exact current state. | – |
| 8 | Cache-unfriendly (3-7× L1 misses) | SoA via `#soa[dynamic]`, `distinct u32` handles, all edges in one arena, creation-order ids (defs next to uses), per-function arena freed at once; ~27 B per node. | Stage 17 measures nodes/s and bytes/node |
| 9 | Control-dependent typing limited (`CheckedAdd`) | Checks are explicit `If` plus panic path; no node derives facts from a check. Overflow intrinsics (deferred) are pure tuples. | – |
| 10 | Propagating deadness hard | v0 never creates dead control (`lower` skips unreachable code, merges drop dead predecessors). Later: one `Dead` constant and `region_remove_input`, verifier `C3`. | `C3` |
| 11 | Hard to introduce control flow during lowering | IR passes never create blocks. All control comes from `lower` or from `x64` after `sched` (`u64↔float`, float `Select`, jump tables). Pure `min`/`max` stay `Select`. | – |
| 12 | Hard to identify loop bodies | `Loop` nodes explicit, two inputs, reducible by construction; depth from the dominator tree. | `C4`, `C5` |
| 13 | Slow compile | Per-pass timing in `-dump-ir`; parallel across functions with index-order merge; budget tracked in stage 17. | Benchmark gate |
| 14 | Sea of Nodes destroys prior scheduling | Source order is recovered per block by node-id tie-break; debug builds keep program order. | Golden schedule dumps |

Other risks:

| Source | Failure mode | Mitigation |
|---|---|---|
| PR #7850 | Fat overloaded instruction record, several hand-kept `switch`es that must agree | SoA node, 8-byte payload read through per-kind accessors, one `kind_info` table for arity, types, purity, pinning, text name. `#assert` that every `Node_Kind` has an entry. |
| PR #7850 | Shared mutable module state during parallel build forced a log-and-replay engine | Module symbols are declared before bodies are built; workers own one `Function` and one arena; blobs and signatures are function-local; merge in function-index order (section 14). Test: byte-identical output at 1 and N threads. |
| PR #7850 | `setjmp`/`longjmp` bail-out, string reasons | Sticky-error builder, typed `Error` unions, `Unsupported` result from `lower`. |
| PR #7850 | Allocator fused to one IR and one target | `regalloc` imports neither `ir` nor `x64` (section 12). |
| PR #7850 | Magic constants (weights, thresholds) | Named constants in `regalloc`, documented where defined. |
| Tilde / TB | Lone-maintainer SoN backend stalled and was removed | Scope limited to Odin core semantics; steps ≤ ~600 lines, each tested; interpreter makes the IR useful before any machine code exists. |
| Click (`ASimpleReply.md`) | Anti-dependences missing from Click's thesis scheduler | Included from the start (section 7 rule 3, `verify_schedule`). |
| Odin semantics | Shift, bounds, ÷0, `or_return`, `context` subtly differ from C | Each is specified in section 8 with its source line in the official backend. |
| Determinism | Map iteration, pointer-order, thread order | GVN table is lookup-only; ids from creation order; merge by index; no `map` iteration in `ir`. |

## 14. Parallelism and determinism

- Parallel unit: one `Function`. `driver` uses `core:thread` `Pool` (`core/thread/thread_pool.odin`); there is no replay log.
- Before the fork `lower` declares, in `check` order: functions (name, signature), globals (name, size, align), externs. Workers read these tables only.
- Workers write only their own `Function` (nodes, edges, signatures, tables, blobs). `Local_Blob` and function-local `Signature` ids are local.
- Join: a single thread walks functions by index, appends each function's blobs to the module's read-only data, deduplicating by content in that order, and rewrites `Local_Blob` symbol refs to final `Global` ids. The order of every later table (data layout, symbol table, text) is the function-index order.
- A test builds a fixed module with 1 and 8 threads and compares the dump and the object bytes.

## 15. Staged implementation plan

Each step is ≤ ~600 lines of Odin including its test, has one purpose and can be checked with `mise run check ir` and `mise run test ir`. Tests are few: round trip, one table-driven negative verifier test, one differential run per feature, a golden schedule per sched feature. "Needs" lists the earlier steps whose files must exist.

| Step | Deliverable | Lines | Needs | Test |
|---|---|---|---|---|
| 1 | `ids.odin`, `kinds.odin`: `Node_Id`, `Value_Type`, `Node_Kind`, `Node_Flags`, `Node_Data`, `kind_info` table, `Error` types | ~300 | – | `#assert` completeness; name table round trip |
| 2 | `graph.odin`: `Function`, `#soa` nodes, edges arena, `add_node`, `set_input`, `remove_node`, `uses_build`, sticky error | ~350 | 1 | add/inspect, `Use_Table` order |
| 3 | `module.odin`: `Module`, `Global`, `Data_Reloc`, `Signature`, `Symbol_Ref`, blob merge | ~250 | 1 | merge dedup determinism |
| 4 | `builder.odin`: typed constructors per kind group, control/phi helpers, `function_finish` | ~550 | 2, 3 | builds the example of section 10 |
| 5 | `print.odin`: printer for graph form | ~300 | 2, 3 | golden text |
| 6 | `parse.odin`: tokenizer + two-pass parser | ~550 | 5 (grammar fixed here) | round-trip corpus |
| 7 | `cfg.odin`: heads, exits, RPO, idom, loop depth, DFS retreating edges | ~300 | 2 | dominators on hand graphs |
| 8a | `verify.odin`: structure `S1-S7`, `G1-G2` | ~400 | 1, 2, 3 | negative table (part 1) |
| 8b | `verify_flow.odin`: control `C1-C6`, memory `M1-M4`, dataflow `D1-D2` | ~500 | 7, 8a | negative table (part 2) |
| 9 | `fold.odin`: constant folding, identities, GVN table, store→load forwarding; hooks into builder | ~500 | 4 | folds equal interpreter results |
| 10a | `interp_memory.odin`: flat memory, globals with relocations, stack slots, extern host table | ~300 | 3 | load/store/reloc test |
| 10b | `interp.odin`: block walk, local ordering, phi parallel update, calls, traps | ~550 | 7, 10a | programs by text and by builder |
| 11a | `sched/early_late.odin`: early, late, loop-depth placement | ~450 | 7 | golden schedules |
| 11b | `sched/local_order.odin`: list scheduling by section 7 rules, cold-last layout | ~300 | 11a | anti-dependence case |
| 11c | `sched/verify.odin` + schedule printer + interpreter schedule mode | ~400 | 11b, 10b | interpreter agrees in both modes |
| 12 | `types`: SysV and Odin-CC classification (`unify`, `fixup`, `[8]Class`) | ~500 | `types` base | table test against clang's decisions |
| 13 | `regalloc/liveness.odin` + `program.odin` (interface of section 12) | ~450 | – | hand-built programs |
| 14 | `regalloc/linear_scan.odin` | ~550 | 13 | constraint cases, call clobbers |
| 15 | `regalloc/moves.odin` (parallel moves) + `verify.odin` | ~400 | 13 | cycle cases |
| 16 | `x64`: ABI lowering, selection, emit (separate doc, several steps) | – | 11c, 14, 15, 12 | assembled output run by test harness |
| 17 | `lower`: AST → IR in small steps (separate doc), then benchmark gate | – | 4, 9, 12 | differential against official `odin` |
| 18 | Deferred kinds (bit tricks, overflow, float math), `i128`, `Tls_Addr` | ~400 each | 9, 10b | per-kind |
| 19 | Slot promotion for small aggregates (slice/string) | ~400 | 11c | before/after node counts |

Critical path to a runnable v0: 1 → 2/3 → 4 → 9 → 10 → (17 in parallel) → 11 → 16.

Which steps can run in parallel (different agents, disjoint files):
- After step 1 lands: **A** (2 then 4 then 9), **B** (3), **C** (5, then 6) and **D** (12, in `types`) start together. Step 5 needs only the node accessors, so C may use the raw `add_node` from step 2 as soon as it exists.
- After step 2: **E** (7, then 8b) and **F** (8a).
- After 4 and 7: **G** (10a, 10b), **H** (11a-11c). 11c needs 10b only for its schedule-mode test.
- **I** (13, 14, 15: `regalloc`) is independent of everything above; it needs only section 12's interface and can start on day one.
- 16 and 17 start after the IR core is stable (4 and 9) and the ABI classifier (12) exists.

## 16. Open questions for the owner

1. **Package for AST → IR.** `docs/01-architecture.md` has no package between `check` and `ir`. This document assumes `lower` (depends on `syntax`, `types`, `check`, `ir`), and that `ir` depends only on `support`, not `types`. Confirm the name and the dependency change.
2. **`i128`/`u128`.** `base:runtime` and `core:fmt` use them. Options: `I128` value type with `x64` splitting into two `I64`; or `lower` expands to `I64` pairs (no IR change). Recommendation: `lower` expands, so `ir` and `x64` stay scalar-only. Needed before a hello world that formats integers.
3. **Thread-local storage.** `base:runtime` uses `@(thread_local)`. Needs `Tls_Addr` and TLS ELF relocations (`R_X86_64_TPOFF32` / initial-exec), specified in the System V x86-64 psABI and the ELF TLS specification. Which mode is wanted for static executables with no libc (initial-exec, set up by our `_start`)?
4. **Odin calling convention.** The design copies the official layout (split returns by pointer, context last) so objects stay mixable with LLVM-built Odin code. If that is never needed, a register-return multi-value convention would be faster and simpler for `x64`; this is a one-line change in `lower` and `x64`, not in `ir`. Confirm.
5. **Pinned loads in v0.** Floating loads (Click's guard casts) are deferred. Confirm that debug-build speed, not optimized code quality, is the target of v0.
6. **Division by zero and `MIN/-1`.** Treated as trapping hardware behaviour, not diagnosed, as in the LLVM build. Confirm that no Odin-visible check is wanted.

## 17. Sources

- Repository: `docs/01-architecture.md`, `docs/research/01-gingerbill-vision.md`, `02-backend-ir-landscape.md`, `04-reuse-survey.md`, `06-pr7850-ir-regalloc-parallelism.md`, `07-pr7850-lowering-abi-elf-dwarf.md`; `core/rexcode/ir/*`, `core/rexcode/docs/ir_design.md`; `src/elf/writer.odin`; `base/runtime/core.odin`, `error_checks.odin`.
- Odin official compiler (`refs/Odin-upstream/src`): `llvm_abi.cpp`, `llvm_backend.cpp`, `llvm_backend_proc.cpp`, `llvm_backend_expr.cpp`, `llvm_backend_utility.cpp`, `parser.hpp`.
- Cliff Click, *Simple* tutorial, https://github.com/SeaOfNodes/Simple: chapters 8 (lazy phis, evaluator), 9 (GVN, worklists, `addDep`), 10-11 (memory), 13 (GCM), 18 (calls), 19-20 (selection, register masks), `ASimpleReply.md`.
- Click, *Global Code Motion / Global Value Numbering*, PLDI 1995; Click and Paleczny, *A Simple Graph-Based Intermediate Representation*, 1995.
- V8, *Land ahoy: leaving the Sea of Nodes*, 2025; Cranelift mid-end (Fallin, 2026); Tilde Backend `tb.h` (node list, `SPLITMEM/MERGEMEM`, anti-dependence edges after the inputs).
- System V Application Binary Interface, AMD64 Architecture Processor Supplement (calling convention, eightbyte classification); Wimmer and Mössenböck, linear scan on SSA form; Cooper, Harvey and Kennedy, *A Simple, Fast Dominance Algorithm*.

## Owner decisions

1. A `lower` package sits between `check` and `ir`. `ir` depends only on `support`, not on `types`.
2. `lower` expands `i128`/`u128` into `I64` pairs. `ir` and `x64` stay scalar-only.
3. Thread-local storage uses the local-exec model: the startup code allocates the TLS block and installs it with `arch_prctl(ARCH_SET_FS)`, as the fork's no-CRT entry does. A `Tls_Addr` node and TLS relocations come soon after hello world.
4. The Odin calling convention keeps the official layout. The ABI must stay compatible with the official compiler and with foreign code.
5. Pinned loads are accepted for v0. Debug-build speed and correctness come first.
6. Division by zero and `MIN/-1` keep hardware-trap behavior, as in the LLVM build.
