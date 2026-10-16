# Design of package `ir`: a Sea of Nodes IR for Odin

Status: revision 2, after the adversarial review `docs/research/10-ir-design-review.md` (responses at the end). Scope: package `ir` (graph, builder, verifier, printer, interpreter) and the interfaces to `sched`, `amd64` and `regalloc`. Linux x64 only. Behaviour reference is the fork `/home/su3h7am/Projects/Odin/src`; where this document says "the fork" it means those files.

## 1. Prior art and what is reused

Prior-art check (`AGENTS.md`):

| Question | Finding | Consequence |
|---|---|---|
| Existing Odin package? | `core/rexcode/ir` is a structured `Module→Function→Block→Operation` contract for wasm/spirv/llvm codecs (`core/rexcode/docs/ir_design.md` §2-3). No effect or control edges. | Reuse vocabulary only (table below). Not a Sea of Nodes. |
| Sea of Nodes in `refs`? | None (`docs/research/04-reuse-survey.md:28,558`). | Graph, verifier, scheduler are ours. |
| Reference designs | Click's Simple (chapters 5-13, 18-20), V8 post-mortem, Cranelift (`docs/research/02`), Tilde `tb.h`, `ASimpleReply.md`. | Simple's node/edge model; V8 lessons as constraints (section 13). |
| PR #7850 | `docs/research/06`, `07`: deterministic index-order merge, scalars in vregs, caller-saved-first allocation, remat are worth keeping; the fat overloaded record, parallel hand-kept `switch`es, shared module state plus replay log and `setjmp` are not. | Section 13. |
| Official behaviour | The fork's lowering is the specification for ABI, numerics, slicing, defer, unions, reflection (sections 6 and 8). | Every such rule below cites the fork function. |
| Vision | `docs/research/01`: "Sea of Nodes based", simplest efficient solution, no language change. | Owner rulings, section 17. |

Vocabulary taken from `core/rexcode/ir`:

| rexcode | Here | Change |
|---|---|---|
| `Id`, `ID_NONE=0xFFFFFFFF` | `Node_Id`, `NODE_NONE = 0` | Zero value is inert (node 0 is reserved). |
| `Ref_Space`, `Ref` | `Symbol_Space`, `Symbol_Ref` | Function/global/extern/local-blob only. |
| `Type_Kind`, `Type_Ref` | `Value_Type` | Scalar classes only; aggregates are memory (section 6). |
| `Error {location, code}` | `Error :: union #shared_nil` (as `src/elf/writer.odin:28`) | Typed error values. |
| `Print_Options` | `Print_Options` | Same field names (`value_prefix`, `indent`). |
| `Module`, `Function`, `Global` | same names | `Function` owns an arena and SoA arrays. |
| `Operand`, `Block`, `Operation` | not reused | Nodes replace operations; blocks are derived. |

## 2. Decisions

1. **Sea of Nodes with pinned effects.** Every value is a node; edges are inputs. Only pure nodes float. Every node that touches memory, can trap, or is ordered (loads, stores, calls, division, atomics, volatile accesses, syscalls) has a control input and stays in its block. This is Cranelift's split with Click's graph model. Floating loads are deferred (section 11).
2. **One memory chain per function** (section 7). Alias classes deferred.
3. **Scalar-only values.** Aggregates live in memory (stack slots) and move with `Load`/`Store`/`Mem_Copy`. Same rule as PR #7850 ("scalars in vregs, the rest by address") and as Tilde's Odin backend (`param_nodes`: "parameters, pointers to return values, and context ptr").
4. **ABI-explicit calls.** The IR contains the result of the Odin/SysV argument planning (section 6); `amd64` only assigns registers.
5. **No control flow is created after `lower`** except by `amd64` after scheduling, and the allocator sees that final CFG (section 12).
6. **Structured control flow.** Odin has no `goto`; labeled `break`/`continue`, `fallthrough` and `defer` expansion do not enter a loop's interior. Every loop has one `Loop` header with exactly two inputs (section 5).
7. **One table for declarative node properties** (`kind_info`: name, arity, slot types, purity, pinning, tuple shape). Typing rules that depend on context, tuple projections, interpretation and selection are explicit procedures, not table entries.
8. **`ir` does not depend on `types`.** It is type-erased to scalars. `lower` depends on both.
9. **Selection after scheduling**, inside `amd64`, on linear blocks (the reverse of Simple chapter 19). `sched` stays machine independent.
10. **Total, Odin-exact scalar semantics in the IR.** Shifts, signed remainder and conversions are defined for all inputs the way the fork defines them (sections 4, 8); `lower` does not rely on poison or undefined results.

Rejected, briefly:

| Alternative | Reason |
|---|---|
| CFG SSA with block params | Owner chose Sea of Nodes. Its good parts are kept: pinned effects, a CFG skeleton, per-block linear order from `sched`. |
| Alias classes in v0 (Simple ch. 11) | Odin's `rawptr`, `transmute`, unions and `#raw_union` defeat type-based classes; needs `MemMerge`/`MemPhi`/`BulkMemPhi` and non-local worklists. |
| Tagged `union` payload per node | Duplicates the tag in `kinds[]`; 16 B per node. An 8-byte `#raw_union` read through per-kind accessors instead. |
| Incrementally maintained def-use lists | Cost on every edit. A CSR `Use_Table` is built on demand. |
| Click's lazy loop phis, edge-locked GVN | Needs unlock/relock on edits. Loop phis come from a pre-scan; interned nodes are immutable. |
| General text parser in v0 | Not needed by any runnable milestone; the printer is kept (section 10). |
| Graph viewer | Click: "ASCII dumps rule" (`ASimpleReply.md`). |

## 3. Data structures

Package layout (`src/ir`): `ids.odin`, `kinds.odin`, `graph.odin`, `module.odin`, `builder.odin`, `cfg.odin`, `verify_graph.odin`, `verify_control.odin`, `verify_memory.odin`, `print.odin`, `interp_*.odin`, later `fold.odin`, `gvn.odin`. Imports: `support`, `base:runtime`, `core:mem`, `core:mem/virtual`.

```odin
Node_Id :: distinct u32
NODE_NONE :: Node_Id(0)            // node 0 is reserved: kind .Invalid

Value_Type :: enum u8 { None, Control, Memory, Tuple, Bool, I8, I16, I32, I64, F16, F32, F64, Ptr, V128 }
Node_Flags :: bit_set[Node_Flag; u8]
Node_Flag  :: enum u8 { Cold, Rematerialize }

Memory_Order :: enum u8 { Plain, Volatile, Relaxed, Acquire, Release, Acq_Rel, Seq_Cst }  // Odin consume = Acquire (llvm_atomic_ordering_from_odin)
Access_Info :: struct { align_log2: u8, order, failure_order: Memory_Order, rmw: Rmw_Op, weak, signal: bool }
Node_Data :: struct #raw_union {      // meaning given by kind; accessors assert the kind
	int_value:  i64,                  // Const_Int (sign-extended from its width), Ptr_Offset
	float_bits: u64,                  // Const_Float (F16 in the low 16 bits)
	index:      u32,                  // Proj index, signature/table/slot id, Target_Op, stride
	symbol:     Symbol_Ref,           // Symbol_Addr, Tls_Addr
	access:     Access_Info,          // Load*/Store/Atomic_*/Fence
	slot:       Slot_Info,            // Stack_Slot: size, align
}
Node :: struct {                       // stored as #soa[dynamic]Node
	kind: Node_Kind, type: Value_Type, flags: Node_Flags,
	input_count: u16, first_input: u32, data: Node_Data,
}
Function :: struct {
	id: Function_Id, name: string, signature: Signature_Id,
	nodes:      #soa[dynamic]Node,    // index = Node_Id; creation order; never reused
	edges:      [dynamic]Node_Id,     // all inputs of all nodes, one arena
	signatures: [dynamic]Signature,   // function-local
	tables:     [dynamic][]i64,       // switch case values
	blobs:      [dynamic]Data_Blob,   // function-local read-only data
	gvn:        Gvn_Table,            // best-effort cache (section 11)
	start, stop: Node_Id,
	arena:      virtual.Arena,        // owns every allocation above
	error:      runtime.Allocator_Error, // sticky; first failure wins
}
Use :: struct { user: Node_Id, slot: u16 }
Use_Table :: struct { first: []u32, uses: []Use }   // CSR from uses_build; order = (user id, slot)
```

Rules:
- Inputs of a node are `edges[first_input : first_input+input_count]`; the slice is valid until the next node is added. **Arity is fixed at creation.** A `Loop` is created with `[entry, NODE_NONE]` and sealed once. Pending-exit collection (section 5) gives `Region`/`Phi` their arity before creation. Shrinking (`region_remove_input`, `loop_collapse`) is in place and keeps phis in lockstep.
- Nodes are never freed: `remove_node` sets kind `.Removed` and clears inputs; ids are stable and dumps diffable. Memory per node is 17 B plus 4 B per edge, about 27 B on average.
- One `virtual.Arena` per function. Sticky-error builder: an allocation failure is recorded and later calls return `NODE_NONE`; `function_finish` returns it. Wrong arity or type from `lower` is a programmer error: `assert` in the builder and a `Verify_Error` from the verifier.

```odin
Error :: union #shared_nil { Verify_Error, runtime.Allocator_Error }   // Parse_Error returns with the parser (section 10)
Module :: struct { functions: [dynamic]Function, globals: [dynamic]Global, externs: [dynamic]Extern, arena: virtual.Arena }
Symbol_Space :: enum u8 { Function, Global, Extern, Local_Blob }
Symbol_Ref   :: struct { space: Symbol_Space, index: u32 }
Global :: struct {
	name: string, size, align: u32, mutable, tls: bool,
	bytes: []byte,                    // nil = zero-initialized (.bss / .tbss)
	relocs: []Data_Reloc,
}
Data_Reloc :: struct { offset: u32, target: Symbol_Ref, addend: i64 }   // absolute 64-bit only

Calling_Convention :: enum u8 { Odin, Contextless, C }                  // C = SysV
Extension  :: enum u8 { None, Sign, Zero }
Param_Attr :: enum u8 { Direct, Indirect, By_Value, Struct_Return, Context }
Param  :: struct { type: Value_Type, attr: Param_Attr, ext: Extension, size: u32, align: u16 }   // size: bytes of a By_Value object, or significant bytes of an odd-size Direct piece; align: By_Value alignment, or stack alignment of a Direct piece (16 for the low half of an i128)
Result :: struct { type: Value_Type, ext: Extension, size: u32 }   // size: significant bytes of an odd-size piece
Signature :: struct { cc: Calling_Convention, variadic: bool, params: []Param, results: []Result }  // 0..2 results
```

**V128** (decision 1) is a `Value_Type` for ABI pieces and memory: `Load`, `Store`, `Call`, `Return` and `Start` pieces may carry it. The interpreter returns `Unsupported` at the first node that produces or consumes a V128 value (`node` = that node). No node holds a two-word value. `lower` scalarizes `#simd` values, so V128 appears only at ABI boundaries.

`Indirect` is a plain pointer to a caller-owned copy (Odin MEMORY-class arguments); `By_Value` is the C `byval` object copied by `amd64` into the outgoing stack area. They are different ABIs (section 6).

Module symbols (functions, globals, externs) are declared by `lower` in `check` order before any body is built; workers read them. `Local_Blob` ids stay function-local through the whole pipeline: nothing rewrites `Symbol_Addr` nodes. The emitter keeps `blob_symbol[function][blob]`, filled by a deterministic merge in function-index order that deduplicates blobs only when bytes, alignment, and every relocation (offset, final target, addend) are equal (section 14).

## 4. Node kinds (v0)

Every node has one output of type `Value_Type`. Multi-output nodes have type `Tuple`; members are read with `Proj(tuple)` (index in `data.index`). Integer types carry no signedness: the operation does. Integers wrap (two's complement); `Const_Int` is stored sign-extended from its width.

"Pinned" = control input in slot 0 (a block head, section 5); `sched` never moves the node out of its block. "Pure" = no control input, immutable, free to float. Loads and stores exist for `I8..I64`, `F16`, `F32`, `F64`, `Ptr` only; `Bool` is never stored (`lower` uses `I8` plus `Trunc`/`Zext`).

| Kind | Inputs | Output | Class | Notes |
|---|---|---|---|---|
| `Start` | none | Tuple(ctrl, mem, params…) | control | `Proj 0` is the entry head; `Proj 1` the initial state; `Proj 2..` the parameters in signature order (sret, regular pieces, split-result pointers, context). |
| `Stop` | terminators… | none | control | Dump/verifier summary; not a traversal root. |
| `Region` | heads (≥2) | Control | head | Merge. |
| `Loop` | entry, back edge | Control | head | Exactly 2 inputs. |
| `If` | ctrl, cond:Bool | Tuple(ctrl, ctrl) | control | `Proj 0` true, `Proj 1` false; each projection heads its own block. `Cold` on a `Proj` marks panic paths. |
| `Switch` | ctrl, value | Tuple(ctrl × (n+1)) | control | `data.index` = case table; `Proj k<n` case k, `Proj n` default. |
| `Proj` | tuple | member type | head if control, else pure | |
| `Return` | ctrl, mem, results… | none | terminator | Operands match the signature (section 6). |
| `Unreachable` `Trap` | ctrl, mem | none | terminator | `Trap` executes `ud2`; `Unreachable` is `ud2` for `amd64`, assumption for optimizers. |
| `Const_Int` `Const_Float` | none | Bool/I8..I64/Ptr; F16/F32/F64 | pure, remat | |
| `Undef` | none | any scalar | pure | One stable arbitrary value per node (`---` only). Interpreter: 0. Never used to fill a missing phi arm. |
| `Symbol_Addr` | none | Ptr | pure, remat | Function, global, extern or local blob. |
| `Tls_Addr` | none | Ptr | pure, remat | Local-exec address of a `tls` global: `fs:0 + tpoff`. |
| `Stack_Slot` | entry head | Ptr | pinned (entry) | `data.slot`. Unique; never interned. |
| `Stack_Alloc` | ctrl, size:I64 | Ptr | pinned | `intrinsics.alloca`; `data.index` = alignment. Lives until return; forces a frame pointer. |
| `Phi` | region, values… | any, incl. Memory | bound to region | One value per region input, same order. |
| `Add Sub Mul And Or Xor` | a, b | I8..I64 (`Bool` for And/Or/Xor) | pure | Commutative ones sort inputs by id. |
| `Shl Shr Sar` | a, count | type of a | pure | `count` is any int type, read **unsigned in its own width**. Total: `count ≥ width(a)` gives 0 (`Shl`, `Shr`) or sign fill (`Sar`), as `llvm_backend_expr.cpp:2093-2125`. `amd64` expands the clamp unless the count is a constant `< width`. |
| `SDiv UDiv SRem URem` | ctrl, a, b | I8..I64 | pinned | Hardware semantics: trap on divisor 0 and on `MIN/-1`. `lower` adds the official guards (section 8). Not on the memory chain. Unused result: removable. |
| `Eq Ne SLt SLe ULt ULe` | a, b | Bool | pure | `>`/`>=` canonicalized by swapping. `Eq/Ne` also on `Ptr`, `Bool`. |
| `FEq FLt FLe FNe` | a, b | Bool | pure | Ordered, except `FNe` (true on NaN). Not defined on `F16`. |
| `FAdd FSub FMul FDiv FNeg FSqrt` | a[, b] | F32/F64 | pure | IEEE; `FSqrt` is `sqrtsd`/`sqrtss`. `F16` arithmetic is `Float_Ext`, op, `Float_Trunc` per operation (the LLVM promotion the fork gets). |
| `Select` | cond, a, b | type of a | pure | Operands already evaluated; never for effectful `x if c else y`. |
| `Trunc Zext Sext` | a | I8..I64/Bool | pure | `Trunc` to `Bool` keeps bit 0. |
| `Bitcast` | a | same size | pure | int↔float, int↔`Ptr`, `I16`↔`F16`. Not for `Bool`. |
| `Sint_To_Float Uint_To_Float Float_To_Sint Float_To_Uint Float_Ext Float_Trunc` | a | F16/F32/F64/int | pure | `F16` ends use the runtime software routines (`f16_to_f32`, `f32_to_f16`, same rounding as the libcalls the fork emits); `amd64` expands `u64↔float` after scheduling. |
| `Popcnt Clz Ctz Bswap` | a | I8..I64 | pure | `Clz`/`Ctz` of 0 give the width (`llvm.ctlz/cttz` with `is_zero_poison = false`, `llvm_backend_proc.cpp:3851-3870`). `amd64` expands at baseline x86-64 (`bsr/bsf` guards, SWAR popcount; no `popcnt`/`lzcnt` assumed). |
| `Mul_Hi_S Mul_Hi_U` | a, b | I64 | pure | High half of the 128-bit product; narrower overflow tests widen to 64 first. |
| `Ptr_Offset` | base | Ptr | pure | `base + data.int_value`. |
| `Ptr_Index` | base, index:I64 | Ptr | pure | `base + index * data.index`. Not an `#soa` element address (section 8). |
| `Load` | ctrl, mem, ptr | scalar | pinned | Plain, non-atomic; state-consuming only. `data.access.align_log2`. |
| `Load_Ordered` | ctrl, mem, ptr | Tuple(mem, value) | pinned | Volatile and atomic loads (`order` ≠ `Plain`). Produces a state, so order against other ordered operations is a graph edge. |
| `Store` | ctrl, mem, ptr, value | Memory | pinned | `order`: `Plain`, `Volatile`, or atomic (`Relaxed`, `Release`, `Seq_Cst`). |
| `Atomic_Rmw` | ctrl, mem, ptr, value | Tuple(mem, old) | pinned | `rmw` ∈ add, sub, and, nand, or, xor, xchg; order per `data`. Widths 1, 2, 4, 8. |
| `Atomic_Cas` | ctrl, mem, ptr, expected, desired | Tuple(mem, old, Bool) | pinned | Success and failure orders, `weak`. Floats compare by bits (`bitcast` in `lower`). |
| `Fence` | ctrl, mem | Memory | pinned | Scope is the `signal` flag (thread otherwise); `order` in `data.access`. |
| `Mem_Copy` `Mem_Set` | ctrl, mem, dst, src/byte, size:I64 | Memory | pinned | `Mem_Copy` has `memmove` semantics. Expanded inline; no libc. |
| `Call` | ctrl, mem, callee:Ptr, args… | Tuple(mem, r0[, r1]) | pinned | `data.index` = function-local signature. Direct call: callee is a `Symbol_Addr`. |
| `Syscall` | ctrl, mem, number, args (≤6) | Tuple(mem, I64) | pinned | `intrinsics.syscall`: registers `rax rdi rsi rdx r10 r8 r9`, clobbers `rcx r11` and memory (`llvm_backend_proc.cpp:4446-4542`). Not a fence substitute. |
| `Target_Op` | ctrl, mem, args… | Tuple(mem, results…) | pinned | Closed enum in `data.index`: `Cpuid` (leaf, subleaf → eax, ebx, ecx, edx), `Xgetbv`, `Pause` (`cpu_relax`), `Rdtsc`. One table `target_op_info` gives arity and types. |

Total: 77 kinds plus `Invalid` and `Removed`. Atomic stores are `Store` with an order; `Odin` `atomic_*_explicit` orders map as `relaxed→Relaxed`, `consume/acquire→Acquire`.

x64 mapping of the atomic family (stronger than required is allowed; non-atomic is not): loads of any order are `mov`; `Seq_Cst` stores are `xchg`; other stores are `mov`; `Atomic_Rmw` add/sub/xchg with the old value use `lock xadd`/`xchg`; and/or/xor/nand use `lock cmpxchg` loops when the old value is used; `Atomic_Cas` is `lock cmpxchg` (16-byte is `Unsupported`); a `Seq_Cst` thread `Fence` is `mfence`, other fences and all signal fences are compiler barriers. `Load_Ordered`, `Store` with order ≠ `Plain`, and the atomic nodes are never removed, commoned, forwarded or fused.

Still deferred (each reported by `lower` as `Unsupported(feature, position)`, never approximated):

| Area | Kinds | Why |
|---|---|---|
| SIMD, matrix | vector value types | Open question 1: the copied runtime's baseline paths use `#simd[16]u8`/`#simd[4]u32`. |
| Native 128-bit | `I128` | `lower` expands to `I64` pairs; the ABI keeps the 16-byte grouping (section 6). |
| Rare numerics | `Fma`, `Floor`, `Ceil`, saturating ops, `Bit_Reverse`, rotates | Not used by the default runtime or `core:fmt`; `lower` can expand from shifts/masks when needed. |
| Overflow arithmetic | none | `lower` expands `overflow_add/sub/mul` to compares and `Mul_Hi_*`; no node. |
| Inline asm | `Asm` | Roadmap item. |
| Control folding | `Dead` constant | Section 11. |
| Floating loads | `Load` without control + guard cast | Section 11. |
| Debug info | variable scopes | DWARF is a later milestone. |

## 5. Control, blocks and phis

A **block head** is `Proj 0` of `Start` (the entry head), a `Region`, a `Loop`, or a `Proj` of an `If`/`Switch` (Simple chapter 13, "Identification of Basic Blocks"). A block is its head, every pinned node whose slot-0 control input is that head, and one **exit**: an `If`/`Switch`/`Return`/`Unreachable`/`Trap` whose control input is the head, or an edge into a `Region`/`Loop` that lists the head as an input. A jump needs no node. `Stack_Slot` takes the entry head. Every transfer goes through a projection block, so critical edges do not exist in the source graph.

Rules `lower` follows (all through one **pending-exit** mechanism):
- **Current control** is a head or `CTRL_NONE` (unreachable; nothing is emitted). A merge with one live predecessor is not created.
- **Pending exits.** `break`, labeled `break`/`continue`, `continue`, `fallthrough` and loop-bottom fall-through append `(head, environment)` to the target's list. The target is *sealed* once: a `Region` with exactly that many inputs is created, and its phis come from comparing the environments (a phi only where node ids differ; the memory phi only where states differ). Loop exits and `continue` targets are sealed when the loop body ends, so arity is never grown. Each target records its scope depth; exits run exactly the pending `defer`s of the scopes they cross (section 8).
- **Counted `for`.** `continue` and the end of the body jump to a continue target that runs the post statement and then takes the back edge.
- **Loops.** `loop_begin(entry)` creates the `Loop` and, from a pre-scan of the checked body (variables assigned in the body, the post statement, nested bodies and defer expansions; plus always the memory variable), one phi per such variable and a memory phi. `loop_end(loop, back_head)` sets input 1 and each phi's back input. If no path reaches the back edge (`for { break }`, `for { return }`), `loop_end(loop, NODE_NONE)` runs `loop_collapse`: the header is replaced by its entry, each phi by its entry value, the markers removed; since this rewrites inputs of already interned nodes it runs `uses_build` and `gvn_rebuild` (section 11). No synthetic back edge is invented.
- **Switch.** One `Switch` per integer switch. A case body reached from its projection and by `fallthrough` is a `Region` with matching phis; its direct projection stays a separate edge block.
- **Loop depth** and membership are those of the natural loop of each `Loop` back edge (body = blocks that reach the back-edge source without passing the header), not the count of dominating `Loop` nodes.
- Reducibility follows from the above and is asserted (`C5`).

Builder surface for control (sticky error): `start`, `if_(ctrl, cond) → (true_head, false_head)`, `switch_`, `region(preds)`, `loop_begin`, `loop_end`, `phi(region, values)`, `ret`, `trap`, `unreachable`, `function_finish → Error` (creates `Stop`, runs `verify`).

## 6. Calls, ABI and aggregates

**Aggregates are memory.** Structs, arrays, slices, strings, `any`, unions, dynamic arrays, maps, complex numbers and `context` are stack slots or globals addressed by `Ptr`. `lower` loads and stores scalar fields; whole-value copies are `Mem_Copy`; zero initialization is `Mem_Set`; `---` emits nothing. A local becomes an SSA variable (Simple's `ScopeNode` idea) only if its type is scalar and **no address of it is ever taken, explicitly or implicitly** (`&x`, slicing an array local, `any(x)` boxing, `by_ptr` calls, method receivers by pointer). Small-aggregate slot promotion is a later pass.

**The signature is the output of `types.abi`, which reproduces `llvm_abi.cpp` exactly.** It is not derived from Clang's behaviour; Clang is the oracle for the `C` convention only. The planner keeps the fork's counters and decisions:

| Case in the fork | Representation |
|---|---|
| Counters start at 6 integer and 8 SSE registers; every argument classified `Int`/`SSE*` subtracts its eightbytes before the decision (`llvm_abi.cpp:791-812, 930-938`). | Planner state; reproduced verbatim, including that return pointers, `sret` and `context` are not counted. |
| Aggregate whose pieces do not fit the remaining registers (`ran_out_of_regs`). | `By_Value` argument for any convention (`:961-964`); returns use `Struct_Return`. |
| MEMORY-class aggregate, convention `Odin`. | `Indirect`: plain pointer, no copy by `amd64` (`:975-979`). The caller passes the address of a temporary copy, or of the original when the fork proves the parameter read-only (`lb_address_from_load_if_readonly_parameter`). |
| MEMORY-class aggregate, convention `C`. | `By_Value` with size and alignment; `amd64` copies it to the outgoing area (`:976-981`). |
| Aggregate classified into registers. | 1-2 `Direct` pieces, consecutive in the parameter list, assigned by `amd64` sequentially, register by register, as LLVM's calling-convention lowering of the final parameter list does. The planner's counters decide `Direct` versus `By_Value`; hidden pointers are not in the counters, so a straddle between the last register and the stack is reproduced, not corrected (open question 5). Odd-size aggregates follow `llreg`/`classify_source`. |
| `i128` (computation uses `I64` pairs). | Two `Direct` `I64` pieces; the low piece has `align = 16` for stack placement; classified `Int,Int`. A struct containing it follows the aggregate rules, not "two scalars". |
| Small integer (<4 bytes), `bool`. | `ext` = `Sign` (signed integers, enums), `Zero` (unsigned, `bool`, `b8`..): `lb_integer_extension_attribute` (`:437-456`). The caller extends arguments to 32 bits, the callee extends results to 32 bits. The same on `Result`. |
| Results ≤16 bytes, classified. | 1-2 `Result` pieces (`rax:rdx`, `xmm0:xmm1`, mixed); an odd-size piece sets `size`. |
| Larger results. | First parameter `Struct_Return`. |
| `Odin` convention, tuple results. | Results 0..n-2 are `Ptr` parameters (`Direct`, appended after the regular parameters, before `context`); result n-1 is the return value (`:394-418, 2754-2775`). |
| `Odin` convention. | Last parameter `Context`. `Contextless` and `C` have none. A procedure of those conventions that needs a context builds a default one in a local (`lb_find_or_generate_context_ptr`, `lb_emit_init_context`). |
| C variadic. | `variadic = true`; `amd64` sets `al` to the number of vector register arguments. |
| `f16`. | `Direct` `F16` piece (class `SSEHs`). |

Parameter order of an `Odin` function: `[Struct_Return] regular… split-result-pointers… Context`. `Start`, `Call` and `Return` carry exactly these pieces; `verify` checks types, `attr` and `ext` against the signature. Assigning registers, stack offsets, `rsp` alignment, callee-saved registers and the red zone belong to `amd64`.

Calls to module functions are `Call` with a `Symbol_Addr` callee. Calls that never return (`-> !`) are followed by `Unreachable(ctrl, mem)` consuming the call's memory.

A `Return` with two results (decision 2) is not interpreted: the interpreter returns `Unsupported` at the Return node, and no two-result outcome exists.

**Validation** of the planner is bidirectional: a matrix of signatures compiled by the fork's Odin and by Clang, compared piece by piece with the plan (register exhaustion, MEMORY aggregates, mixed Int/SSE, odd sizes, signed/unsigned small returns, `i128`, split returns, `context`).

**Known ABI differences.** `mise run abi-matrix` compares 215 `C` signatures: 196 agree among the plan, Clang and the fork; the other 19 match the fork and differ from Clang. The decision is language ABI parity: the plan matches the fork. Evidence is the IR from both compilers (`mise run abi-matrix --keep`).

| Case | Signatures | Clang | Fork and plan | Effect |
|---|---|---|---|---|
| Last eightbyte only partly filled | 14 | `i8`/`i32` piece | full `i64` piece | Same register. |
| `struct{3×f16}` (6 bytes) | 3 | `<4 x half>` | `<3 x half>` | Same register. |
| `struct{f32}` after the 8 SSE registers are used | 1 | `byval align 8` | plain `float` | Both use an 8-byte stack slot. |
| `struct{u128}` | 1 | `i128` | `{i64, i64}` | Same registers; the stack case is `By_Value` in both. |

Clang also puts `zeroext`/`signext` on small results; the fork never attaches the result extension (only `sret`). The plan records the intended `ext` on single results, so `amd64` extends results itself (decision in `docs/04-amd64-design.md`).

## 7. Memory model

**v0: one memory chain per function** (Simple chapter 10).

- `Memory` is a value type. `Start` supplies the initial state. Producers: `Store`, `Mem_Copy`, `Mem_Set`, `Fence`, `Call`/`Syscall`/`Target_Op`/`Load_Ordered`/`Atomic_*` (tuple member 0), memory `Phi`. Consumers: all producers, `Load`, `Return`, `Unreachable`, `Trap`. A call or syscall always takes the whole state and produces a new one, even with no result: unknown callees get no readonly or no-alias reading.
- `lower` keeps the current state in a hidden variable `$mem` in the same scope structure as other variables.
- A plain `Load` consumes a state and produces none. Volatile and atomic loads produce one (B1 of the review): the order between two of them is a graph edge, not the node-id tie-break.
- **Order inside a block** comes from four rules and nothing else: (1) data inputs, (2) producer before consumer of a state, (3) anti-dependence: a plain `Load` of state `s` runs before the producer that takes `s` over, (4) ties by node id (source order for builder output). Rule 4 is only a determinism tie-break, never a semantic order.
- **Path consistency** is verified (section 9, `M1-M5`): the current state at every point of every path, with phi inputs checked on their edges. Unchanged states need no phi; mutually exclusive consumers of one state are fine.
- Loads, stores and division are pinned, so they cannot move above a bounds check or a null test.
- All stack slots, globals and heap objects share the chain; conservative and correct for `rawptr`. Later refinement: non-escaping slots are sound alias classes; `MemSplit/MemMerge` can be added without changing existing layouts.
- Non-atomic shared accesses obey Odin's race rules; the state token does not promise exclusivity. Only atomic and ordered nodes synchronize.

## 8. How Odin features lower

All of this is `lower` (AST + types → `ir`). The behavioural reference is the named fork function.

**Integer division and remainder** (`lb_integer_division` `llvm_backend_expr.cpp:1494-1586`, `lb_integer_modulo` `:1729-1830`, mode from `lb_check_for_integer_division_by_zero_behaviour` `:309-326`: file feature flag, else `-integer-division-by-zero:{trap,zero,self,all-bits}`, default `trap`). A constant non-zero divisor emits the bare operation (unsigned divide by a power of two may become a shift). Otherwise: `If(rhs ≠ 0)`; fast path the operation; edge path by mode. Division: `trap` → `Trap`; `zero` → 0; `self` → `lhs`; `all-bits` → all ones. Remainder (`%` and `%%`): `trap` → `Trap`; `zero` and `all-bits` → `lhs`; `self` → 0. A constant zero divisor follows the same table. `Trap` is `ud2`, not the divide fault, so the observable signal matches. Signed `%` divides by the safe divisor `Select(Eq(y,-1), 1, y)` (`lb_srem_safe_divisor` `:331-342`), giving `MIN % -1 = 0`; `%%` is `lb_emit_signed_floor_mod` (`:346-392`): safe-divisor `SRem`, then `+ rhs` when the signs differ and the remainder is non-zero; constant `-1` gives 0. Signed `/` has no `MIN/-1` guard in the fork, so it keeps the hardware fault.

**Shifts.** One `Shl`/`Shr`/`Sar` node with the count in its own type (total semantics, section 4); `lower` converts nothing. This matches the fork, which compares the count in its original width before converting it (`:2093-2125`): an `x: u8 << (256: u64)` is 0.

**Bounds checks.** The fork calls the runtime handler unconditionally and relies on inlining; we emit the handler's own condition inline and call the handler on the failure edge (`Cold`), then `Unreachable`. Index: `ULt(i, len)` (`bounds_check_error`: `uint(index) < uint(count)`). Slices, strings, dynamic arrays and fixed arrays: bound is the **length**, never the capacity (`llvm_backend_expr.cpp:5700-5760`): without `lo`, `ULe(hi, len)` (`slice_expr_error_hi`); with `lo`, `ULe(lo, hi) ∧ ULe(hi, len)` (equivalent to the runtime's `0 <= lo <= hi <= len`, `error_checks.odin:156`). Multipointer slices use `multi_pointer_slice_expr_error`. Handler variant: `_with_context` when the enclosing procedure has a context stack, else `_contextless` (`llvm_backend_general.cpp:1271-1275, 1356-1360`); arguments are the location `file` (blob), `line`, `column`, then the values. `#no_bounds_check` and `-no-bounds-check` emit nothing; checker-proven accesses emit nothing.

**Multiple results.** Callee: results 0..n-2 are `Store`d through the extra pointer parameters, result n-1 is passed to `Return`. Named results are slots or SSA variables. Caller: one `Stack_Slot` per extra result, `Load`s after the call.

**`defer`.** No node. `lower` keeps, per scope, the list of deferred statements, each with the **context binding that was current when it was registered** (`lbDefer.context_stack_count`, restored while lowering the body: `llvm_backend_stmt.cpp:3610-3613, 3701-3704`). At every exit (`return`, `or_return`, `or_break`, `or_continue`, labeled `break`/`continue`, block end) the pending bodies of exactly the scopes crossed are emitted inline in reverse order. `return` first evaluates all operands, converts them, stores named results and split-result pointers, and only then runs the defers; the `Return` operands are the values computed before the defers (`:2621-2683, 2731-2853`). Procedures attached through `lb_add_defer_proc` follow the same exit mechanism.

**`or_return` / `or_else`.** `has_value` is the boolean itself when the last value is `bool`, else `err == nil` (`lb_emit_try_has_value` `llvm_backend_utility.cpp:474-484`); `If`; the false edge converts the error to the last result type, stores named results or sets the single result, runs defers, `Return` (`:634-680`). `or_else` is `If` plus `Phi`.

**`context`.** The incoming pointer is used directly as the address of `context`. `context.x = v` allocates a slot, `Mem_Copy`s the old context, stores the field and rebinds the current-context variable; calls pass the current one; the previous binding returns at scope exit.

**Slices, strings, dynamic arrays, maps.** `{data, len}` (16 B), `{data, len, cap, allocator}` (40 B) in slots (`Raw_Slice`, `Raw_Dynamic_Array`). `append`, `make`, `delete`, `map` are calls into `base:runtime`; map operations follow the fork's runtime-call route (`llvm_backend.cpp:1341-1407`): key and value are passed by address of an lvalue or a temporary, hash and compare procedures and `Map_Info` come from constant global data with relocations. `#soa` element access gathers and scatters per field and uses the SoA pointer representation (`llvm_backend_general.cpp:936-1039, 1751-1810`); it is not `Ptr_Index`.

**`any`.** `any(x)` takes the **address of an addressable operand** and a fresh slot only for rvalues and constants (`lb_address_from_load_or_generate_local` `llvm_backend_utility.cpp:1059-1071`; conversion `llvm_backend_expr.cpp:3384-3404`, constants `:2381-2396`); outside multi-assignment this exposes the address, so the variable is a slot. `typeid` is the canonical type hash (`lb_typeid` → `type_hash_canonical_type`, `llvm_backend_type.cpp:78-90`), not an index. `type_info_of(T)` with a static type uses the table index; `type_info_of(id)` calls `runtime.__type_info_of`, a hash lookup in `type_table` (`llvm_backend_proc.cpp:3170-3182`, `core.odin:814-826`). The type table and string tables are generated global data (`llvm_backend_type.cpp`).

**Unions.** Layout is supplied by `types` as a descriptor with kinds `Tagged` (tag integer after the variant area), `Maybe_Pointer` (no tag: nil pointer is "no variant", `is_type_union_maybe_pointer`), `Zero_Size`, plus `shared_nil` and custom alignment. `lower` follows `lb_emit_union_tag_ptr/value`, `lb_emit_union_cast`, the `shared_nil` branches (`llvm_backend_general.cpp:2425-2519`, `llvm_backend_utility.cpp:839-956`). A tag is never loaded from a `Maybe_Pointer`; constructing a nil `shared_nil` variant leaves the union nil.

**Proc groups, polymorphism.** Resolved and monomorphized by the checker, in a deterministic order; each instance is a separate `Function`.

**Globals and constant data.** Constant-initialized globals, string literals, constant arrays, `Source_Code_Location` values, type info, map info become `Global` or `Local_Blob` bytes plus `Data_Reloc`s. Non-constant initializers run in a generated startup procedure in checker dependency order. `@(thread_local)` globals are `tls` globals with `Tls_Addr`.

**Intrinsics.** `mem_copy*`/`mem_zero*` → `Mem_Copy`/`Mem_Set` (a `Mem_Set` is never removed in v0, so the volatile variant needs no extra flag); `unaligned_load/store` of scalars → `Load`/`Store` with `align_log2 = 0`, otherwise `Mem_Copy`; `trap`, `debug_trap` → `Trap`; `unreachable`; `expect` dropped; `syscall`; `atomic_*`, `volatile_*`, fences → section 4; `count_*`, `byte_swap`, `sqrt`, `alloca`, `cpu_relax`, `x86_cpuid/xgetbv`, `read_cycle_counter` → section 4 kinds; `count_ones/zeros/leading_ones/trailing_ones` compose from `Popcnt/Clz/Ctz` and `Xor -1`; `overflow_*` expand (add/sub by compare formulas, mul by `Mul_Hi_*`); `ptr_offset/ptr_sub` → `Ptr_Index`. **`#simd`**: open question 1.

**f16.** Source `f16` values are `F16` in registers and 2 bytes in memory; arithmetic and comparisons promote per operation through `F32` (`Float_Ext`, op, `Float_Trunc`); `core:fmt` reaches this through `f64(f16)`. The runtime's `f16_to_f32`/`f32_to_f16` (`base/runtime/internal.odin:1071-1128`) are the software conversions used.

## 9. Verifier invariants

`ir.verify(fn, allocator) -> []Verify_Error` runs after the builder finishes and after every pass in debug builds (`-define:IR_VERIFY=true`); tests and `-dump-ir` always run it. Each error is `{node, other, code}`. Three files: `verify_graph` (S, G), `verify_control` (C, D), `verify_memory` (M).

Structure
- `S1` node 0 is `Invalid`; exactly one `Start` and one `Stop`; `Stop` inputs are exactly the terminators.
- `S2` every input id `< node count` and not `Removed`; `NODE_NONE` only in an unsealed loop back edge, and nowhere after `function_finish`.
- `S3` arity within `kind_info`; `Region ≥ 2`, `Loop = 2`, `Phi = region arity + 1`, `Switch` projections = cases + 1.
- `S4` slot types and result types match the kind rule and the context rule (`Add` operands equal; `Eq` result `Bool`; `Load*`/`Store` only on non-`Bool` scalars; shift count any int; `Const_Int` canonical for its width).
- `S5` `Proj` input is `Tuple`, index in range, type equals the member type derived by the kind (`Start` and `Call` from the signature); every `If` has both projections once, every `Switch` all of its.
- `S6` `Call` operands and result members equal its signature (`type`, `attr`, `ext`); `Return` and `Start` equal the function signature; `Stack_Slot` size > 0, power-of-two align, control input the entry head; symbol, table and signature indices in range; case values unique.
- `S7` removed nodes have no inputs and no users.

Control (`cfg.odin`)
- `C1` a slot-0 control input is a block head; every pinned node and terminator has one.
- `C2` every head has exactly one exit.
- `C3` every head is reachable from `Proj 0` of `Start` by control edges (forward enumeration; `Stop` is not used for reachability).
- `C4` a `Loop`'s entry input is not dominated by it and its back-edge source is.
- `C5` reducible: every retreating edge of a DFS of the control graph is a `Loop` back edge.
- `C6` `Phi` input 0 is a `Region`/`Loop`; value inputs have one type; no `Control` phis; a `Loop` has a memory phi.

Memory (path consistency, linear time, reverse post-order over blocks; review M1)
- `M1` memory-typed values come only from the producers of section 7.
- `M2` each memory-using node has exactly one memory operand; no other node has one.
- `M3` **entry state** of each block: the entry head has `Start`'s state; a branch projection has the exit state of the block of its `If`/`Switch`; a `Region` has its memory phi, and each phi input equals the exit state of the matching predecessor block; a `Region` without a memory phi requires all predecessors to have the same exit state (this rejects "forgot the phi after one arm stored"); a `Loop` has its memory phi, entry input equal to the entry predecessor's exit state, back input equal to the back-edge block's exit state.
- `M4` **chain in a block**: the block's producers form one linear chain starting at the entry state (each consumes the entry state or the previous output; no output is taken over twice); the exit consumes the chain end; the block's exit state is the chain end (the entry state if none).
- `M5` a plain `Load` consumes the entry state or a chain output *of its own block*; consuming an older state of a dominating block, after that block's chain moved on, is stale and rejected. Anti-dependence is then satisfiable by construction.

Dataflow
- `D1` schedulability: for every pinned node and every phi edge, each input's earliest block (pinned: its own; pure: the deepest of its inputs' earliest blocks, which must form a dominator chain; constants, symbol and TLS addresses: the entry) dominates the use block (for a phi, the matching predecessor block; back-edge phi inputs are checked at the back-edge block, not recursed through the phi).
- `D2` pinned classes have a control input; pure classes do not.

Interning (debug): `G1` every table entry refers to a live pure node whose semantic key equals the entry's key (duplicates of a key are allowed); `G2` no interned node was mutated.

`sched.verify_schedule`: every non-rematerialized node appears exactly once, in a block that dominates its uses; definitions precede uses inside a block; phis lead their block; each plain `Load` precedes the producer taking over its state; the layout has the entry first and `Cold` blocks last.

Negative tests are one table-driven procedure with one broken graph per code. Two cases are mandatory because shortcuts pass them: **sequential diamonds** (`if c {store}` then `if d {store}` where the second diamond's stores reuse the first diamond's original state: `M3`), and a **volatile/atomic pair with unused results** (the order must survive).

## 10. Printer and interpreter

The printer is the debugging surface (V8 problem 1). It prints the graph in id order, one node per line, with explicit ids; removed ids are skipped. The general parser is deferred (section 15); early tests build graphs with the builder and compare printed text. The syntax is fixed now so it can be parsed later without change:

```
module      = { global | extern | function } ;
global      = "global" GID STRING "size" INT "align" INT [ "mut" ] [ "tls" ] [ "bytes" HEX ] { reloc } ;
reloc       = "reloc" INT "->" symref [ ("+"|"-") INT ] ;
function    = "func" FID STRING "sig" "=" SID "{" { sigdecl | tabledecl | blobdecl | nodeline } "}" ;
sigdecl     = "sig" SID "cc" ("odin"|"contextless"|"c") [ "variadic" ] "(" [ param { "," param } ] ")" "->" "(" [ result { "," result } ] ")" ;
param       = vtype { ":" ("indirect" | "byval" "(" INT "," INT ")" | "sret" | "sext" | "zext" | "context" | "align" "(" INT ")") } ;
result      = vtype [ ":" ("sext" | "zext") ] ;
nodeline    = NID "=" KIND "." vtype [ ref { "," ref } ] { attr } ;
ref         = NID | "_" ;                          (* "_" = NODE_NONE, unsealed loop only *)
attr        = ("value"|"bits"|"index"|"offset"|"stride"|"size"|"align"|"order"|"failure"|"op") "=" (INT|HEX|IDENT)
            | "sym" "=" symref | "sig" "=" SID | "table" "=" TID | "weak" | "cold" ;
vtype       = "none"|"ctrl"|"mem"|"tuple"|"bool"|"i8"|"i16"|"i32"|"i64"|"f16"|"f32"|"f64"|"ptr"|"v128" ;
```

`sched` also prints blocks (`block b2 head=n12 depth=1 preds=[b1,b4]: …`); print-only, used for golden tests. Example (`add_or_zero(a, b: i64, c: bool) -> i64`):

```
func f0 "main.add_or_zero" sig=s0 {
  sig s0 cc c (i64, i64, bool:zext) -> (i64)
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
  n14 = phi.mem n11, n3, n3
  n15 = return.none n11, n14, n13
  n16 = stop.none n15
}
```

**Interpreter** (the differential oracle; Simple chapters 8 and 18). Built in three layers so each is testable: (1) scalar and control evaluation of one function; (2) flat memory, globals with relocations, stack slots, loads/stores/copies, atomics as sequential operations; (3) calls and recursion with the ABI plan applied (pieces, `Indirect`, `By_Value`, extension), then a host table for externs and a small syscall whitelist.
- Memory is one flat byte array from base `0x10000`; null faults. Pointers are `u64`.
- Pure nodes are evaluated on demand and memoized by a generation counter bumped whenever a pinned node produces a value or a phi updates; pinned nodes run in the order of the four rules of section 7; all phis of a region read before any is written.
- Results and failures are typed: value, `Trap`, `Unreachable`, `Arith_Trap` (hardware divide fault), `Out_of_Fuel`, `Fault` (address), `Unsupported` (node), `Exit` (exit code), `Stack_Overflow`. Signal and exit-code distinctions are preserved so `Trap` (`ud2`) and a divide fault are different outcomes, as in the official binary.
- It runs the unscheduled graph with the local rules only, and a second mode runs a `sched` schedule. The two share the effect rules, so agreement does not prove the rules; the official compiler's native output is the oracle for source-visible effects (writes, defer order, context, errors, ABI), compared on the same program.

## 11. Peepholes and GVN

v0 starts with **no GVN and no folding beyond integer constants**; each addition has its own semantic tests and is added after the interpreter exists (section 15). Order of introduction, all at node creation in the builder (definitions before uses, no worklist, V8 problem 6):

1. **Integer constant folding** with exact width wrap; shifts and conversions folded with the total semantics of section 4; division folded only for a non-zero divisor and not `MIN/-1`. Float folding only for `FAdd FSub FMul FDiv FNeg FSqrt` on constants of the same width, never for `F16` or comparisons with NaN, never across `Float_Ext/Trunc`.
2. **Canonical form and identities** (small fixed list): commutative operand order by id, `a > b` → `b < a`; `x+0, x|0, x^0, x<<0, x*1, x&-1` → `x`; `x*0, x&0` → 0; `x-x, x^x` → 0; `Eq(x,x)` → true (integers and `Ptr` only; float `FEq` is not folded); `Select(c,a,a)`; extension/truncation round trips; `Ptr_Offset` chains.
3. **Hash-consing of pure nodes.** Open-addressing table of `Node_Id`, lookups only, never iterated. The key is a **semantic key function per kind**: kind, type, inputs, and exactly the data fields that kind defines (not the raw union bytes), plus flags that change meaning (none in v0; `Cold` and `Rematerialize` are not in the key). `Proj` is interned only for non-control members of pure tuples. The table is a cache: rewriting passes may leave duplicates, and `G1` allows them.
4. **Store-to-load forwarding**: `Load(ctrl, m, p)` with `m` a plain `Store` to the identical pointer node with identical value type and width, both `Plain` order, `m` the exact current state → the stored value. No partial overlap, no width change, no `Bool`, never across `Call`, `Syscall`, `Fence`, atomics, volatile or an unknown producer.

**Immutability.** An interned node is never edited. Edits touch non-interned kinds only (`Loop`, `Phi`, `Region`, `Stop`). A pass that rewrites inputs of interned nodes (`loop_collapse`, later SCCP) runs `uses_build`, rewrites, and `gvn_rebuild` (clear and re-insert in id order); duplicates that appear are legal.

**Roots and DCE.** Roots are terminators, every producer of a state (stores, calls, copies, fences, ordered and atomic operations, `Syscall`, `Target_Op`) and `Stack_Alloc`; a reachable infinite loop keeps its stores. Everything else is removed if unreached from roots through inputs, including unused plain `Load`, division (its zero guard is explicit; the `MIN/-1` fault of an unused signed division is allowed to vanish as it does under LLVM), phi-only cycles and dead address computations.

**Deferred**, roughly by value: iterate-to-fixpoint worklist with distant-neighbour dependencies (Simple chapter 9); phi/load factoring (chapters 10-11); SCCP and dead-branch removal with a `Dead` constant and `region_remove_input` (chapter 24); dead-store elimination; alias classes; floating loads guarded by `Cast` nodes; range-check elimination; inlining; slot promotion; Cranelift-style e-graph (rejected for v0).

## 12. Pass pipeline

```
check → lower (per function, parallel) → ir.verify → ir.dce → ir.verify
  → sched.order        conservative: fixed control skeleton, pure nodes at the LCA of their uses
  → sched.verify_schedule
  → amd64.select         linear blocks of ideal nodes → machine CFG on virtual registers (all control expansion done here)
  → amd64.verify_machine pred/succ symmetry, definitions, edge moves, fixed registers, no critical edges
  → regalloc.allocate  liveness → assignment → move resolution → regalloc.verify
  → amd64.emit           prologue/epilogue, spills, layout (Cold last), branch fix-up, encoding via core:rexcode/isa/x86
  → elf builder (src/elf)
```

Later optimizing variants plug in at the same points: GVN/forwarding in `ir`, GCM in `sched`. `-dump-ir=<pass>` prints the graph or schedule at a point; output is deterministic.

**`sched`.** Input: a verified `ir.Function`. Output `Schedule { blocks: []Block }`, each `{head, nodes (final order), preds, succs, depth, cold}`. Stage A (`order`): enumerate blocks by forward control traversal; place each pure node in the LCA block of its uses (phi uses at the matching predecessor) — valid by `D1`; local order by the four rules of section 7. Stage B (GCM, Click 1995 and Simple chapter 13) adds *early* placement and the choice among blocks between early and late by shallowest loop depth. Fixed placements: `Phi` and control `Proj` at their head, `Stack_Slot` at the entry, pinned nodes in their block; loop back-edge phi inputs are excluded from ordinary recursive placement. `Const_*`, `Undef`, `Symbol_Addr`, `Tls_Addr` are `Rematerialize`: not scheduled, materialized at each use by `amd64`. Hoisting to a common dominator of uses on exclusive paths may compute a value where one path does not need it (V8 problem 5); accepted for the cheap pure nodes of v0. `Cold`-only blocks are laid out last.

**`amd64.select`.** Greedy per-block tree matching on the schedule with use counts. Single-use `Load` folds into the ALU/compare operand **only when it sits immediately before its consumer in the final order with no intervening pinned node** (any call, syscall, atomic, volatile, store or trapping operation blocks it; volatile and atomic loads never fold). `Ptr_Offset`/`Ptr_Index` chains fold into `[base + index*scale + disp]`; a compare feeding only the block's `If` fuses with `jcc`; phi nodes become parallel copies at the end of the predecessor (each source edge has its own block). ABI lowering from `Signature`; scratch contract as a `bit_set`. Expansions that create control flow (`u64↔float`, shift clamp where not constant, float `Select`, `Switch` jump tables, popcount/clz guards, `cmpxchg` loops) run here and **complete before liveness**; new blocks and edges carry parallel copies for values live across their joins; new critical edges are split. Encoding is `core:rexcode/isa/x86`.

**Register allocation (package `regalloc`, imports neither `ir` nor `amd64`).** First model, deliberately small (review M10): **no interval splitting**; one location per vreg for its whole life, register or spill slot; a spilled vreg is reloaded into a short-lived temporary vreg at each use and stored after each def (spill everywhere); fixed-register requirements (division, shifts by `cl`, call arguments and results, `syscall`) are met by `amd64` copying through fresh short-lived vregs carrying a `Fixed` constraint; call clobbers force intervals that cross a call into callee-saved registers or spill slots. The interface is data:

```odin
Vreg :: distinct u32
Register_Class :: enum u8 { Int, Float }
Constraint :: enum u8 { Any, Fixed, Reuse_Input }
Position   :: enum u8 { Early, Late }
Operand :: struct { vreg: Vreg, role: enum u8 { Use, Def, Use_Def }, position: Position, constraint: Constraint, fixed: u8, reuse: u8 }
Instruction :: struct { operands: []Operand, clobbers: Register_Set, is_call, is_move: bool }
Block :: struct { instructions: []Instruction, successors: []u32, edge_copies: []Parallel_Copy, depth: u8 }
Program :: struct { blocks: []Block, classes: []Register_Class, allocatable: [Register_Class]Register_Set, callee_saved: Register_Set, spill_width: [Register_Class]u8 }
Location :: union { Register, Spill_Slot }
Result :: struct { location: []Location, spill_slots: u32 }
allocate :: proc(program: ^Program, allocator: mem.Allocator) -> (Result, Error)
```

Steps: liveness by backward dataflow on the final machine CFG (loop depth weights); linear scan over whole-life intervals (Poletto/Sarkar, with SSA-aware phi handling after Wimmer/Mössenböck); parallel-copy resolution with cycle breaking inside this package. Spill cost = uses × weight ÷ length; named constants. Spill slots are fixed width (8 bytes for `Int` and `Float` scalars). Rematerialization (`Vreg_Info.remat`: immediate, symbol, slot address) is added to `Program` when it is implemented, not before. `regalloc.verify` checks the **rewritten** machine program: no two simultaneously live vregs share a register, fixed and reuse constraints hold at each operand position, clobbers are respected, every edge copy is a valid parallel move. A graph-colouring middle (Simple chapter 20) can replace linear scan later without changing `Program`.

## 13. Risk register

V8 failure modes are numbered as in `docs/research/02-backend-ir-landscape.md` §1.4.

| # | Failure mode | Mitigation | Check |
|---|---|---|---|
| 1 | Unreadable graph | Deterministic dump with stable ids, per-pass `-dump-ir`, block dump after `sched` (section 10). | Golden text |
| 2, 3 | Everything lands on the effect/control chain; memory ops do not float | Accepted openly: v0 pins memory ops and divisions; only pure nodes float. No claim of load hoisting. | `D2` |
| 4 | Hand-managed chains, conflated chains (crbug 41470351) | One linear chain carried as `$mem`; path-consistency verifier `M1-M5` including sequential diamonds; ordered operations are graph edges. | `M3` negative tests |
| 5 | Scheduler complexity, CSE then re-duplication | Conservative `sched.order` first; GCM only for pure nodes, later; constants/addresses rematerialized. | `verify_schedule` |
| 6 | Bad visitation order | Fold at creation, in definition order; later fixpoint via worklist plus `Use_Table`. | – |
| 7 | State tracking cost | No global load elimination; O(1) forwarding of the exact current state only. | – |
| 8 | Cache-unfriendly | SoA `#soa`, `u32` handles, one edge arena, creation-order ids, per-function arena, ~27 B per node. | Measured in step I1 |
| 9 | Control-dependent typing | Checks are explicit `If` + panic path; no node derives facts from a check. | – |
| 10 | Propagating deadness | v0 never creates dead control; `loop_collapse` is the only structural rewrite and rebuilds the GVN cache. | `C3` |
| 11 | Hard to add control flow in lowering | IR passes never create blocks; `amd64` creates them before liveness and re-verifies the machine CFG. | `amd64.verify_machine` |
| 12 | Loop bodies | Explicit `Loop` nodes; membership from natural loops. | `C4`, `C5` |
| 13 | Slow compile | Per-pass timing; parallel across functions; budget gate (I1). | Benchmark |
| 14 | Destroys prior scheduling | Source order recovered by id tie-break; GCM is optional. | Golden schedule |

| Source | Failure mode | Mitigation |
|---|---|---|
| PR #7850 | Fat record, parallel hand-kept `switch`es | SoA node, per-kind accessors, one `kind_info` table with `#assert` completeness. |
| PR #7850 | Shared module state forced a replay log | Symbols pre-declared; one `Function` and arena per worker; function-local blobs and signatures; index-order merge; no `Symbol_Addr` rewrite. |
| PR #7850 | `setjmp`, string reasons, magic constants | Sticky-error builder, typed `Error`, `Unsupported` results from `lower`, named constants. |
| PR #7850 | Allocator fused to one IR/target | `regalloc` imports neither `ir` nor `amd64`. |
| Tilde | Lone-maintainer SoN backend stalled | Narrow scope, steps ≤ ~600 lines with tests, interpreter useful before machine code, milestones that run natively early. |
| Click | Thesis scheduler lacked anti-dependences | Included from the start (section 7 rule 3). |
| Odin semantics | Shift, remainder, division modes, slicing, `defer`, `any`, unions, `typeid`, ABI differ from C | Each is specified with its fork function (sections 6, 8) and has a representation test (section 15). |
| Determinism | Map iteration, pointer order, thread order | Lookup-only GVN table, ids by creation order, index-order merge, no `map` iteration in `ir`. |

## 14. Parallelism and determinism

- Parallel unit: one `Function`, on `core/thread/thread_pool.odin`. No replay log.
- Before the fork `lower` declares, in `check` order, functions, globals (with `tls`), externs. Workers read these only and write only their own `Function`.
- Join: one thread walks functions by index, appends blobs to read-only data deduplicating by content, alignment and complete relocation list, and fills `blob_symbol[function][blob]`. Every later table follows function-index order.
- A test builds a fixed module with 1 and 8 threads and compares dumps and object bytes.

## 15. Staged implementation plan

The ~600-line figure is a review-size preference; estimates below include tests and error paths. Steps that previously hid several algorithms are split. "Interface" notes say where a step is bootstrapped with a limited interface. Validation per package: `mise run check <pkg>` and `mise run test <pkg>` for `ir`, `sched`, `types`, `regalloc`, `amd64` separately.

**Milestones** (the order of the review): **M0** a native executable of one procedure with a loop, memory and a call that writes with `Syscall` and exits; **M1** the same with ABI-checked calls between our procedures and a raw-syscall `core:sys/linux` program; **M2** a default-runtime executable (TLS, startup, allocator) with no `fmt`; **M3** `fmt.println`/`fmt.printf` without replacing the allocator or disabling TLS; **M4** optimizations (GVN, forwarding, GCM) with an unoptimized mode kept as the comparison path.

| Step | Deliverable | Lines | Needs | Test |
|---|---|---|---|---|
| A1 | `ids`, `kinds`: ids, `Value_Type`, `Node_Kind` (77), `kind_info`, `target_op_info`, `Error` | ~450 | – | `#assert` completeness |
| A2 | `graph`: SoA function, edges arena, accessors, `remove_node`, `uses_build` | ~450 | A1 | accessors, CSR order |
| A3 | `module`: module, signature, global, blob merge table | ~350 | A1 | merge determinism |
| A4 | `builder` core + **minimal verifier** (`S1-S7`, `C1-C3`) together; no `function_finish` promise beyond them | ~600 | A2, A3 | build and verify the sample |
| A5 | builder control: pending exits, regions, loops, `loop_collapse` | ~550 | A4 | nested-loop sample with post statement, labeled continue, fallthrough, no-back-edge loop |
| A6 | `print` (graph form) | ~350 | A2, A3 | golden text |
| A7 | `cfg`: heads, exits, RPO, idom, natural loops | ~450 | A2 | dominators, no-exit loop |
| A8 | `verify_control`: `C4-C6`, `D1-D2` | ~550 | A7 | negative table |
| A9 | `verify_memory`: `M1-M5` (entry/exit states, chains, phi edges) | ~500 | A7, A8 | sequential-diamonds and stale-load negatives |
| B1 | `types`: layout and union descriptors | ~600 | – | layout tables |
| B2 | `types.abi`: classification (`unify`, `fixup`, odd sizes, `#raw_union`, SoA/packed fall-backs) | ~600 | B1 | table test |
| B3 | `types.abi`: plan (counters, `Indirect`/`By_Value`, extension, split returns, context, `i128`) | ~600 | B2 | table test |
| B4 | ABI matrix: signatures through the fork and Clang vs the plan | ~500 | B3 | matrix |
| C1 | interpreter: scalar and control | ~500 | A4 | by builder |
| C2 | interpreter: memory, globals, relocations, slots | ~500 | C1, A3 | load/store/reloc |
| C3 | interpreter: calls with the ABI plan, externs, syscalls | ~600 | C2, B3 | recursion, byval, split results |
| C4 | interpreter: ordered/atomic/TLS/target ops | ~400 | C2 | order cases |
| D1 | `sched.order` (stage A) + schedule printer | ~450 | A7 | golden schedules |
| D2 | `sched.verify_schedule`, interpreter schedule mode | ~400 | D1, C1 | agreement of modes |
| E1 | `regalloc`: `Program`, liveness | ~500 | – | hand-built programs |
| E2 | `regalloc`: whole-life linear scan, spill-everywhere, `verify` | ~600 | E1 | constraints, clobbers |
| E3 | `regalloc`: parallel copies | ~400 | E1 | cycle cases |
| F1-F6 | `amd64`: call/ABI lowering; integer selection; float selection; memory/atomics; control expansion; frame/emit/layout | ~600 each | D2, E2, B3 | run natively (separate doc) |
| G0 | `lower`: module pass, symbol table, procedure job pool, parameter binding, implicit return, error type, `lower_program` | – | A5, B3 | a procedure returning a constant, built and verified |
| G1-G6 | `lower`: expressions; control and `defer`; calls/ABI use; aggregates, slices, bounds; unions/`any`/`typeid`/type tables; maps/`#soa` | ~600 each | A5, B3 | against the fork (separate doc) |
| H1 | TLS end to end: `tls` globals, `.tdata/.tbss`, `PT_TLS`, `R_X86_64_TPOFF32`, `Tls_Addr`, startup (`arch_prctl(ARCH_SET_FS)`) | ~600 | A3, F4 | thread-local test |
| H2 | atomics, fences, ordered accesses in `amd64` | ~500 | F4, C4 | per-op tests |
| H3 | bit ops, `Mul_Hi`, overflow expansions, `FSqrt`, `Bswap` | ~500 | F2 | per-op |
| H4 | `i128` pair expansion in `lower` (+ `udivmod128` path) | ~500 | G1 | boundary values |
| H5 | `f16` conversions and promotion | ~300 | F3 | rounding cases |
| H6 | `#simd` scalarization (or runtime adaptation; open question 1) | ~600 | G4 | memory_equal/compare |
| H7 | `Target_Op` (`cpuid`, `xgetbv`, `pause`, `rdtsc`), `Stack_Alloc` | ~300 | F1 | per-op |
| H8 | startup without the `.asm` stubs (open question 2) | ~500 | H1 | M2 |
| I1 | folding, GVN, forwarding (each separately, semantic tests first); compile-time/peak-memory measurement | ~500 each | C3 | agree with interpreter |
| I2 | GCM stage B | ~500 | D2, I1 | golden schedules |
| I3 | deferred kinds, parser, slot promotion | – | – | – |

Critical path: A1 → A2/A3 → A4 → A5 → C1-C3 → D1 → F1-F6 with B3 and E2 → M0; H1-H8 → M2/M3.

Parallel start, disjoint files: after A1, agents **A** (A2, A4, A5), **B** (A3, then C2), **C** (A6, A7); **D** (`types`: B1-B3) and **E** (`regalloc`: E1-E3) are independent of `ir` and start immediately (`regalloc` needs only the section 12 interface). After A7: **F** (A8, A9) and **G** (D1, D2). `amd64` and `lower` steps start when A5, B3, D2 and E2 exist. Interfaces bootstrapped limitedly: A4's verifier covers only structure and entry control; `function_finish` verifies exactly what exists; GVN tests wait for I1.

## 16. Open questions for the owner

1. **`#simd`.** The copied runtime's baseline paths use `#simd[16]u8` (`memory_equal`, `memory_compare`, `internal.odin:276-340`) and `#simd[4]u32` (chacha8, `random_generator_chacha8_simd128.odin`) because `HAS_HARDWARE_SIMD` is true with SSE2. Recommendation: `lower` scalarizes a `#simd[N]T` as an aggregate with unrolled per-lane code for the intrinsics the runtime uses (H6), keeping `ir` scalar; a native `V128` is a later optimization. Alternative: adapt our `base/runtime` copy to set `HAS_HARDWARE_SIMD` false for this backend, which does not make user `#simd` code work.
2. **Assembly stubs in the runtime.** `entry_unix_no_crt_linux_amd64.asm`, `tls_linux_no_crt_amd64.asm` and the stack-protector stub are `foreign import`ed assembly. A pure-Odin toolchain has no assembler. Options: emit the entry from `amd64` directly (the code is short and documented), or port the stubs to naked Odin procedures. Needed by H1/H8.
3. **`__ODIN_LLVM_F16_SUPPORTED`.** With it false the runtime's `__float16` is `u16`; the compiler would report false for this backend. This changes no user-visible type but is an ABI choice for the runtime's own `truncsfhf2`/`extendhfsf2`. Confirm.
4. **`typeid` values.** Only consistency between ids and the generated `type_table` is observable (`__type_info_of` hashes `id % len`). Confirm that the canonical hash need not equal the official compiler's numbers.
5. **Straddling pieces.** Hidden pointers (`sret`, split-result pointers, `context`) are not in the fork's register counters, so a register-fitting aggregate can straddle the last register and the stack in the physical assignment. This design reproduces the fork; the B4 matrix will show whether LLVM actually does so. Confirm that reproducing it is the intent.

## 17. Owner decisions

These replace the earlier list; later rulings override earlier text.

1. A `lower` package sits between `check` and `ir`. `ir` depends only on `support`.
2. `i128`/`u128` are expanded by `lower` into `I64` pairs; `ir` and `amd64` stay scalar-only. The ABI representation keeps the 16-byte grouping and alignment of the original type (section 6).
3. Thread-local storage is **v0**, local-exec: `tls` globals in `.tdata`/`.tbss`, `PT_TLS`, `Tls_Addr` as `fs:0 + tpoff` with `R_X86_64_TPOFF32` (System V x86-64 psABI), thread pointer installed by startup with `arch_prctl(ARCH_SET_FS)` as the fork's no-CRT entry does, per-thread blocks initialized as `linux_no_crt_tls_init` does. Local-exec is a static-executable restriction, not the answer for shared objects.
4. Atomics, fences, volatile/ordered accesses, bit intrinsics (`Popcnt Clz Ctz Bswap`, overflow via `Mul_Hi_*`), `f16` conversions and the target operations the default runtime and `core:fmt` reach are **v0** (section 4: 77 kinds).
5. Division, remainder, shifts, slicing, `defer`, `any` and unions match the official compiler exactly, including the zero-divisor trap, `MIN % -1 = 0`, signed `%%`, and the four `-integer-division-by-zero` modes with per-file feature flags (section 8).
6. The Odin calling convention follows `llvm_abi.cpp` exactly: MEMORY-class aggregates are `Indirect` for `Odin` and `By_Value` for `C`; aggregate grouping under register exhaustion, `ran_out_of_regs`, split results, context-last, and result extension metadata (section 6). No alternative convention.
7. The direction stays Sea of Nodes with pinned loads and stores and a single memory chain; effect ordering, path-exclusive memory verification, the entry-head contract, loop sealing and GVN/forwarding rules follow the review (sections 5, 7, 9, 11).
8. The plan is re-estimated; the general text parser and early optimizations are deferred; the printer stays (sections 10, 15).

## 18. Review responses

Each finding was checked against the fork (`/home/su3h7am/Projects/Odin/src`) and `base/runtime` before acceptance.

| Finding | Verdict | Evidence and change |
|---|---|---|
| B1 volatile/atomic order | Accepted | Fork sets volatile on every atomic (`llvm_backend_proc.cpp:4065-4288`); orders `consume→Acquire`. New `Load_Ordered`, `Atomic_Rmw`, `Atomic_Cas`, `Fence`; `Store` with order; x64 mapping table; plain `Load` stays state-consuming. |
| B2 ABI representation | Accepted, with one refinement | MEMORY under `Odin` is `lb_arg_type_indirect` without `byval`; `ran_out_of_regs` makes an aggregate `byval` for any convention; extension on results (`llvm_abi.cpp:437-456, 961-981`). `Param_Attr` gains `Indirect`, `Param`/`Result` gain `ext`. Refinement: the fork decides grouping in the planner by counters, then LLVM places pieces sequentially, so IR keeps pieces plus the planner's decisions rather than aggregate groups; the uncounted hidden pointers can make a straddle, kept and tested (open question 5). |
| B3 deferred set | Accepted | Verified TLS (`core_builtin.odin:63`, `heap_allocator_implementation.odin:2173`), atomics (`lifecycle_linux_amd64.odin:168-176`), `overflow_add` (`default_temp_allocator_arena.odin:28`), `cpuid/xgetbv` (`mem_linux_amd64.odin:52-65`), `u128`/`f16` in `fmt` (`fmt.odin:1149, 3525`), `#simd` in `memory_equal` (`internal.odin:276-340`). Node set grows 63→77; I did not re-verify every cited line of the review's table. New finding: runtime `.asm` stubs (open question 2). SIMD is not in the owner's list: open question 1. |
| B4 entry/loop contract | Accepted | `Proj 0` of `Start` is the entry head; `Stack_Slot` uses it; `loop_collapse` for no-back-edge loops (section 5). |
| M1 non-dominance ≠ exclusive | Accepted | Replaced by block entry/exit state and chain verification with phi edges (`M3-M5`); sequential-diamonds negative. |
| M2 merge/exit rules | Accepted | Pending-exit sealing, post-statement continue, switch fallthrough regions, scope depths, natural-loop depth (section 5). No irreducible machinery. |
| M3 numerics | Accepted | Fork compares the count before conversion (`:2093-2125`); `MIN % -1` safe divisor and `%%` (`:331-392`); trap mode emits `llvm.trap` (`:1549-1560`); default is `trap` (`build_settings.cpp:492`). IR shifts made total; division recipe by mode; `Trap` not the fault. Signed `/` has no `MIN/-1` guard in the fork; kept. |
| M4 slice bound | Accepted | Bound is length for slices, strings, dynamic arrays (`:5700-5760`); condition from `error_checks.odin:156`. Also found: the fork calls the handler unconditionally; we inline the same condition. Handler variant by context presence. |
| M5 defer/returns | Accepted | `context_stack_count` per defer (`llvm_backend_stmt.cpp:3610, 3704`); results computed and stored before defers (`:2621-2853`); boolean `or_return` (`llvm_backend_utility.cpp:474-484`). |
| M6 `any`/unions/reflection | Accepted | `lb_address_from_load_or_generate_local`; maybe-pointer, zero-size and `shared_nil` unions; `typeid` is the canonical hash and `__type_info_of` a hash lookup. Added: contextless procedures generate a default context (`lb_find_or_generate_context_ptr`). Maps and `#soa` expansions noted. |
| M7 forwarding | Accepted | `Bool` never stored; forwarding only for plain, identical type and width, current state; load folding only when adjacent to its consumer. |
| M8 GVN | Accepted, simpler route | Duplicates allowed (`G1` weakened), semantic key function, `gvn_rebuild` after rewrites; blob symbols remapped at emit instead of rewriting nodes; `Undef` defined. |
| M9 machine CFG | Accepted | `amd64.select` completes all control expansion before liveness; `amd64.verify_machine`; fixed placements and back-edge phi handling in `sched`. |
| M10 allocator interface | Accepted | First model has no splitting, spill-everywhere, fixed-register copies, fixed-width slots, rewritten-program verification; remat added when implemented. |
| N1 DCE roots | Accepted | Roots defined in section 11. |
| N2 stale items | Accepted | Local-exec stated; stages named by deliverable. |
| N3 node count | Accepted | No kind cut; mechanisms cut instead (parser, GVN, GCM deferred). |
| Plan and order | Accepted | Section 15 rewritten with the review's order and milestones. |

## 19. Sources

- Repository: `docs/01-architecture.md`, `docs/research/01`, `02`, `04`, `06`, `07`, `10`; `core/rexcode/ir/*`, `core/rexcode/docs/ir_design.md`; `src/elf/writer.odin`; `base/runtime/*.odin` (`core.odin`, `error_checks.odin`, `internal.odin`, `mem_linux_amd64.odin`, `tls_linux_no_crt*.odin`, `entry_unix_no_crt_linux_amd64.asm`).
- Fork `/home/su3h7am/Projects/Odin/src`: `llvm_abi.cpp`, `llvm_backend_expr.cpp`, `llvm_backend_general.cpp`, `llvm_backend_proc.cpp`, `llvm_backend_stmt.cpp`, `llvm_backend_type.cpp`, `llvm_backend_utility.cpp`, `build_settings.cpp`, `main.cpp`.
- Click, *Simple* (https://github.com/SeaOfNodes/Simple): chapters 8-11, 13, 18-20, `ASimpleReply.md`; Click, *Global Code Motion / Global Value Numbering*, PLDI 1995; Click and Paleczny, *A Simple Graph-Based Intermediate Representation*, 1995.
- V8, *Land ahoy: leaving the Sea of Nodes* (2025); Cranelift mid-end (Fallin, 2026); Tilde `tb.h`.
- System V Application Binary Interface, AMD64 Architecture Processor Supplement (calling convention, eightbyte classification, thread-local storage); Poletto and Sarkar, *Linear Scan Register Allocation*; Wimmer and Mössenböck, linear scan on SSA form; Cooper, Harvey and Kennedy, *A Simple, Fast Dominance Algorithm*.

## Open-question rulings

Evidence: `docs/research/12-runtime-asm-and-f16.md`.

1. `#simd`: `lower` scalarizes it. Our `base/runtime` stays unmodified.
2. Runtime assembly stubs: the compiler emits the process-entry, TLS setup and stack-protector sequences directly (Ginger Bill's own position on issue #4444 is that assembly is optional tooling, not a language need). No assembler is embedded. User `foreign import` of `.asm` files is a later feature.
3. `__ODIN_LLVM_F16_SUPPORTED`: this backend reports `false`, so the runtime's f16 helpers use the integer-register ABI. The `f16` language type is unchanged. Revisit only if hardware f16 is added.
4. `typeid` values: only consistency with our generated type table is required.
5. Register straddle: reproduce the official compiler.
