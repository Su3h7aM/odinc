# Lowering: checked program to IR

Status: design. Owner: package `lower` (`src/lower`). It implements tickets G0-G6 and H1-H8 of `docs/02-ir-design.md` section 15, and adds G0 as the core those tickets build on. The checker contract is `docs/03-checker-design.md` section 12; the IR contract is `docs/02-ir-design.md` sections 3-8. The `amd64` side is `docs/04-amd64-design.md`, which this document does not change.

## 1. Prior art and what is reused

Every rule below cites the fork function it reproduces, as `docs/02-ir-design.md` section 1 requires. Lines refer to `/home/su3h7am/Projects/Odin/src`.

The fork's procedure driver is `lb_generate_code` (`llvm_backend.cpp:3803`), which generates each procedure through `lb_generate_procedure` (`llvm_backend.cpp:3745`): build the body with `lb_build_stmt`, finish, record it as done. The default context is set up by `lb_emit_init_context` (`llvm_backend.cpp:225`). The statement lowering is `lb_build_stmt` (`llvm_backend_stmt.cpp:3320`), `lb_build_stmt_list` (`:260`), `lb_build_return_stmt` (`:2685`), `lb_build_defer_stmt` (`:3599`), `lb_build_assign_stmt` (`:3241`) and `lb_build_assignment` (`:2588`). Expressions are `lb_build_expr` (`llvm_backend_expr.cpp:4601`), `lb_build_addr` (`:5134`) and `lb_emit_conv` (`:2359`). Calls are `lb_emit_call` (`llvm_backend_proc.cpp:1236`) and `lb_emit_runtime_call` (`:1181`). Module setup is `lb_init_module` (`llvm_backend_general.cpp:182`); bounds checks are `lb_emit_bounds_check` (`:1256`). Runtime type information is `lb_setup_type_info_data` (`llvm_backend_type.cpp:1162`). Unions are `lb_emit_union_cast` (`llvm_backend_utility.cpp:854`). The ABI is `llvm_abi.cpp`, which `types.plan_abi` (`src/types/abi_plan.odin:116`) reproduces.

The PR 7850 fast backend (`/home/su3h7am/Projects/refs/odin-pr7850-fast-backend/src`) is the closest prior art for a second backend that builds from the AST. Its ideas are used, not its code. `xb_build_proc` (`xb_backend.cpp:269`) builds one procedure and returns a reason string when it cannot; we do not copy that fallback, because an unsupported feature is a typed `Lower_Error` and never a second path (section 17). `xb_lower_jobs` (`xb_backend.cpp:469`) lowers procedures in parallel after the module is declared; we do the same (section 4). Its separate machine-lowering pass (`x64_lower.cpp`) matches our split between `lower` and `amd64`. Its `x64_abi.cpp` is an independent ABI implementation; we use `types.plan_abi` only.

Reused as they are: `ir` builder and `builder_control` (`builder.odin`, `builder_control.odin`), `ir.add_signature`, `ir.blob_merge`, `types` layout and `plan_abi`, the checker accessors in `src/check/model.odin`, `base/runtime` (the runtime helpers, the entry and TLS sources in `base/runtime/*_linux_no_crt*`), and `intrinsics.syscall` (`base/intrinsics`). The runtime sources are the reference for startup (section 15); the compiler emits the equivalent IR directly, as open-question ruling 2 requires.

## 2. Inputs

`lower` takes one `check.Checked_Program` by pointer. The program is borrowed: every slice, map, source buffer and the type store stays valid and unchanged for the whole lowering run. `lower` reads it only through the accessors in `model.odin` (`procedures`, `expression_info`, `plan`, `constant`, `symbols`, `entity_symbol`, `globals`, `type_store`, `runtime_requirements`, `sources`). No accessor allocates or mutates, so workers may call them in parallel.

`lower` does not resolve names, infer types, evaluate constants, choose overloads, instantiate generics or decide layouts. Those are checker and `types` work. `lower` materializes what the checker decided, and an unhandled retained plan is an error, never a guess. The boundary verifier of `docs/03-checker-design.md` section 12 runs before any worker: it rejects missing expression facts on reachable syntax, unresolved symbols, types and instances, incomplete call and exit plans, dangling ranges, and missing runtime helper declarations. After it passes, `lower` may assume these facts and assert them.

## 3. Output and package shape

The output is one `ir.Module` (`src/ir/module.odin`) and a list of `Lower_Error` values. The module holds the functions in checker order, the globals (with TLS flags and relocations), the externs, and the generated data blobs. The entry is one procedure, `lower_program(program: ^check.Checked_Program, allocator) -> (module: ir.Module, errors: []Lower_Error, err: runtime.Allocator_Error)`. The exact signature is settled in G0.

The package is `lower`. It imports `check`, `types`, `support` and `ir`; `check` does not import `ir`, so the graph is acyclic (`docs/03-checker-design.md` section 12). Each ticket owns its own files (section 18); there are no shared mutable tables between tickets. Tests live beside the source as `*_test.odin`, few and meaningful, as `AGENTS.md` requires.

## 4. Module pass

The module pass is single-threaded and runs in this order: (1) for each `check.symbols(program)` entry, in order, declare the IR symbol: a `Procedure` becomes a new `ir.Function` appended to `module.functions`, a `Global` becomes an `ir.Global`, an `Extern` becomes an `ir.Extern`. The mapping from `Symbol_Id` to `ir.Symbol_Ref` is a table indexed by `Symbol_Id`, so a call can name a procedure before its body exists. (2) Globals are filled: sizes, alignments, TLS flags, constant initializers and `Global.relocations` (all relocations are absolute 64-bit, `docs/02-ir-design.md` section 3). A dynamic initializer is not run here; it goes into the init procedure (section 15). (3) Runtime type information is materialized from `runtime_requirements` (section 11). (4) The startup procedure is generated (section 15).

After the module pass the symbol set is fixed. Procedure bodies are lowered next, in parallel. Each worker writes only its own `ir.Function`, its own signatures and its own blobs. The workers cannot add module symbols. After all workers finish, each function's blobs are merged in function order with `ir.blob_merge`, so merged blob ids do not depend on scheduling.

Staged divergence (reachability, `src/lower/reachability.odin`): the official compiler lowers every procedure and global; we lower only what the roots reach. The roots are the user-package procedures and globals, and the startup procedures of the runtime requirements (entry point, init and fini procedures, tests, init context). Each round lowers the newly reached procedures in parallel, then marks the symbols their IR and blobs reference (`Symbol_Addr`, `Tls_Addr`, blob and global relocations). A procedure never reached gets an `unreachable` body and no errors, and an initializer error of an unreached runtime global is dropped. User-package code always reports its errors. Lowering everything is the goal once every runtime feature lowers; until then reachability keeps unsupported runtime code from failing the build.

## 5. Per-procedure lowering

Each `check.Checked_Procedure` gives an entity, a symbol, a signature type, a body `Node_Ref` (or a generated-body recipe for equality, hash and map helpers), a typed-view id, parameter and result entities, a calling convention, attributes, a source span and the defer registrations of its scopes.

The lowering of one procedure is: compute the ABI plan from the signature type (section 8); store the resulting `ir.Signature` with `add_signature`; call `ir.start` to get the control, memory and parameter nodes; create a `Builder` with `builder_make`; bind each source parameter to its entity (section 8 describes the reassembly of multi-piece parameters); lower the body statement list; emit the implicit return at the fall-through of the body; call `function_finish` and `verify` on the result.

Each local variable is one of two kinds, decided before its declaration is lowered. A scalar local whose address is never taken becomes an SSA variable of the builder (`variable_declare`, `variable_get`, `variable_set`). Every other local, including every aggregate, becomes a stack slot (`stack_slot`) addressed by a `Ptr`. "Address taken" follows `docs/02-ir-design.md` section 6: `&x`, slicing an array local, `any(x)` boxing, a `#by_ptr` argument, a method receiver taken by pointer. The decision is made by a pre-pass over the procedure's typed view, not by a checker change; the pre-pass is part of G1.

The memory state is the builder's variable 0 (`MEMORY_VARIABLE`). Every effectful node takes the current memory and control and produces the next memory, so the memory chain is the evaluation order of effects (`docs/02-ir-design.md` section 7).

## 6. Expressions

For each expression node, `lower` reads `check.expression_info(program, view, node)`. A non-zero `constant` gives a constant: `const_int` or `const_float` at the final type, with strings and other data placed in blobs, and no further evaluation. Otherwise a non-zero `plan` gives the operation: `lower` switches on the variant of `check.plan` (conversion, place, call, builtin, aggregate, assignment, bounds, union, exit, propagation, context). With neither, the node is a plain operator or a name, and `lower` dispatches on its syntax kind.

Two lowerings exist for each addressable expression: `lower_value` gives a scalar node (`Node_Id`) or, for an aggregate, the address of memory holding it; `lower_address` gives the `Ptr` of a place. The `Addressing_Mode` of the expression decides which one a use needs. An aggregate value is always memory, so an aggregate expression never produces a multi-word SSA value.

Conversions follow `Conversion_Kind`. `Assignment`, `Cast` and `Subtype` are integer resizing (`Sext`, `Zext`, `Trunc`), float conversions, pointer casts, and value copies. `Transmute` is a bitcast of a scalar or a memory reinterpretation. `Box` is the `any` construction and `Union_Injection` is the union tag store (sections 10 and 11). The rules of `docs/02-ir-design.md` section 8 for divide, remainder and shifts apply to a binary operator: a constant non-zero divisor emits the bare operation; otherwise a guard on the divisor selects the fast path or the mode edge. The mode is the division-by-zero policy the checker records for the operation (`Division_By_Zero` and `Check_Policy` in `check/model.odin`, reached through `check.sources`), so `lower` reads it and does not consult the command line. `Shl`, `Shr` and `Sar` take their count in its own type and do not convert it.

Argument evaluation follows `Call_Argument.evaluation_order`: the callee is evaluated first, then the arguments in that order. Each argument's conversion is the `Plan_Id` that `Call_Argument.conversion` records.

## 7. Statements and control

Statements lower through `builder_control`. An `if` is `branch_if`, `enter_arm` for the true and false arms, and `jump_to` each arm's exit into the target that the statement names. A `for` loop is `loop_begin` with the variables it assigns, `loop_end` at the back edge, and `loop_collapse` when the loop has one exit. `switch` is `branch_switch` with the case values. `break`, `continue` and `fallthrough`, labeled or not, are `jump_to` a `Jump_Target`; the `Exit_Plan` names the target (`Node_Ref`) and lists the scopes it leaves (`exited_scopes`). Labels come from `Label_Data`.

Assignments follow the fork's order (`lb_build_assign_stmt`, `llvm_backend_stmt.cpp:3241`). The destination addresses are built first, left to right, then all right-hand values, then the stores in order (`lb_build_assignment`, `:2588`). This matters for `a, b = b, a` and for `x[i], i = v, 0`. A blank destination builds no address and stores nothing.

A `when` statement lowers only its selected arm; the checker marks the arms through `Node_State`. A `range` statement lowers to a loop through `builder_control`; its evaluation and iteration semantics follow `lb_build_range_stmt` (`llvm_backend_stmt.cpp:1329`), which G2 checks against the fork before it is accepted.

## 8. Calls and the ABI plan

The ABI is the output of `types.plan_abi(store, procedure_type, by_pointer, config, allocator)` (`src/types/abi_plan.odin:116`). It is called once per distinct procedure type of a function, for its own signature and for every call site's callee type. The plan is freed with `types.destroy_plan`. Its physical parameters are `Abi_Param` values: `source` is the index of the procedure parameter they carry, or -1 for the hidden pointers (`Struct_Return`, split-result pointers, context). A source parameter classified into registers becomes consecutive `Direct` pieces.

The conversion to IR is mechanical. `Abi_Piece` maps to `Value_Type` by name (I8 to I8 ... I64, F16, F32, F64, V128, Ptr). `Abi_Attr` maps to `Param_Attr`, and `Abi_Extension` to `Extension`. `size` and `align` are copied; `Abi_Result` gives `Result{type, ext, size}`. The resulting `ir.Signature` is stored with `add_signature`. A plan has at most two results: one or two pieces for a result of at most 16 bytes, and `Struct_Return` for a larger one. The verifier checks the limit of two results anyway (section 17).

Each piece has one meaning. A `Direct` piece is a node of its piece type; `lower` stores the pieces of a register-classified parameter into the parameter's stack slot at entry, and loads them back at a call site. An `Indirect` parameter is a `Ptr` to a caller-owned copy; the caller makes the copy, or passes the original when the fork proves the parameter read-only (`lb_address_from_load_if_readonly_parameter`, `docs/02-ir-design.md` section 6). A `By_Value` parameter is a `Ptr` to the object, which `amd64` copies into the outgoing area. `Struct_Return` is the first parameter, a `Ptr` to the destination. Extension is applied by the caller on parameters (to 32 bits) and by the callee on results, as `docs/02-ir-design.md` section 6 states.

Multiple results follow the fork. For `Odin` and `Contextless`, results 0..n-2 are `Ptr` parameters that the callee stores through; the last result is the `Return` value. The caller allocates one stack slot per extra result, passes its address and loads it after the call. `Odin` procedures take the context pointer last; `Contextless` and `C` take none. A contextless procedure that needs a context builds a default one in a local (section 9). The variadic flag of a C signature is passed through to `amd64`, which sets the vector count.

A call is `ir.call` with a `Symbol_Addr` callee for a direct call, and with a `Ptr` value for a call through a procedure value. The callee's `Signature_Id` is the one the caller added for that type.

## 9. Defer, return and context

`defer` has no IR node. `lower` keeps, per scope, the list of registered statements (`Checked_Procedure.defers`). Each registration carries the context binding that was current when it was registered (`context_plan`), and the lowering restores that binding while it emits the deferred body, as `lbDefer.context_stack_count` does (`llvm_backend_stmt.cpp:3610-3613`). At every exit (`return`, `or_return`, `or_break`, `or_continue`, labeled `break` and `continue`, the end of a block) the bodies of exactly the scopes crossed are emitted inline, in reverse registration order. Bodies are duplicated per exit; there is no shared defer block.

`return` evaluates all operands, converts them, stores named results and split-result pointers, and only then runs the defers. The `Return` node takes the values computed before the defers (`lb_build_return_stmt`, `llvm_backend_stmt.cpp:2685` and `:2621-2853`). `or_return` and `or_else` follow `lb_emit_try_has_value` (`llvm_backend_utility.cpp:474-484`): the boolean itself when the last value is `bool`, else `err == nil`. The false edge converts the error to the last result type, stores it, runs the defers and returns.

`context` is a pointer. The incoming pointer is used as the address of the current context (`lb_push_context_onto_stack_from_implicit_parameter`). `context.x = v` allocates a slot, copies the old context with `Mem_Copy`, stores the field and rebinds the current-context variable; calls pass the current binding; the previous binding returns at scope exit. The `Context_Plan` chain (`parent`, `scope`, `copy`) gives the binding for each point. A contextless procedure that needs a context builds one with the runtime's `__init_context` helper (`lb_emit_init_context`, `llvm_backend.cpp:225`), passed as an explicit runtime call.

## 10. Aggregates, slices and bounds

Structs, arrays, unions, strings, slices, dynamic arrays, `any`, complex numbers and `context` are memory. An `Aggregate_Plan` stores its fields with `Store`, one per scalar field, at the offsets `types.field_offset` gives. Zero initialization is `Mem_Set`, a whole-value copy is `Mem_Copy`, and `---` emits nothing (`docs/02-ir-design.md` section 6). Slices and strings are `{data, len}` (16 bytes) and dynamic arrays `{data, len, cap, allocator}` (40 bytes), in slots (`Raw_Slice`, `Raw_Dynamic_Array` in `base/runtime`).

A `Bounds_Plan` gives the kind (`Index`, `Slice`, `Multi_Pointer`, `Matrix`), the operands and the `Check_Policy`. `lower` emits the handler's own condition inline: `ULt(i, len)` for an index, `ULe(hi, len)` and `ULe(lo, hi)` for slices, with the length as the bound and never the capacity (`docs/02-ir-design.md` section 8). The failing edge calls the runtime handler (`bounds_check_error` or its `_with_context` form, the choice follows the context binding) on a `Cold` head and then `Unreachable`. `#no_bounds_check` and the checker's proven accesses emit nothing.

## 11. Unions, `any`, `typeid` and runtime type information

A union is a `types` descriptor with kind `Tagged`, `Maybe_Pointer`, `Zero_Size`, plus `shared_nil` and custom alignment. `lower` follows `lb_emit_union_tag_ptr` and `lb_emit_union_value` for tag reads and writes, and `lb_emit_union_cast` (`llvm_backend_utility.cpp:854`) for assertions. A tag is never loaded from a `Maybe_Pointer`. Constructing a nil `shared_nil` variant leaves the union nil. `Union_Plan` gives the operation (`Inject`, `Assert`, `Optional_Assert`, `Type_Switch`) and the variant type.

`any(x)` takes the address of an addressable operand, and a fresh slot only for rvalues and constants (`lb_address_from_load_or_generate_local`, `llvm_backend_utility.cpp:1059`). `typeid` is a constant: the checker computes the canonical runtime id, and `lower` writes it. `type_info_of(T)` with a static `T` is the table index constant; `type_info_of(id)` calls the runtime's `__type_info_of`, a hash lookup in the type table.

Runtime type information is materialized from `runtime_requirements.type_info`. Each `Type_Info_Entry` gives a type, its runtime id, its slot, its size, alignment and flags, a descriptor `Const_Id` and a symbol. `lower` emits one global per descriptor, with relocations to its name, payload, offset and tag arrays, and one `type_table` global whose slots follow the checker's slot numbers (slot zero reserved). Only the entries in `runtime_requirements` are emitted, never one per interned type (`docs/03-checker-design.md` section 11). Entries are emitted in ascending `slot` order, so the bytes do not depend on scheduling. Equality, hash and map helpers come from `Generated_Body` requests and are lowered as ordinary procedures (`Generated_Body_Kind`).

## 12. Maps and `#soa`

Map operations are runtime calls into `base:runtime` (`llvm_backend.cpp:1341-1407`). The key and the value are passed by the address of an lvalue or of a temporary. The hash and compare procedures and the `Map_Info` record are constant global data with relocations, from the checker's map and cell information. A `#soa` element access gathers and scatters each field, and uses the SoA pointer representation (`llvm_backend_general.cpp:936-1039` and `:1751-1810`), not `ptr_index`.

## 13. `i128`, `f16` and `#simd`

`i128` and `u128` are two `I64` values, low and high. Addition and subtraction carry with `ULt` on the low half. Multiplication takes the high half of the low-by-low product from `Mul_Hi_U` and adds the two cross products. Division and remainder call the runtime's 128-bit division path (H4 names it `udivmod128`). Comparisons compare the high halves (signed or unsigned, by type) and then the low halves unsigned. Shifts with counts of 64 or more are expanded. Constants are split at lowering. At ABI boundaries the value is two `Direct` `I64` pieces, the low one with `align = 16` for stack placement (`docs/02-ir-design.md` section 6).

`f16` is a storage and ABI type (`F16`). Arithmetic promotes to `F32`, operates, and rounds back to `F16`. This is exact for add, subtract, multiply, divide and square root, because 24 is at least 2 × 11 + 2 (the double-rounding result of Figueroa, 1995). LLVM promotes half arithmetic to float on x86-64 without native half support, so the fork's observable results match this route. H5 checks the rounding cases against the fork before it is accepted. Open-question ruling 3 keeps the runtime's f16 helpers on the integer-register ABI.

`#simd` is scalarized (open-question ruling 1). A vector value is held as its lane values; operations are per lane; broadcast and shuffle with constant indices are computed at lowering. In memory a vector is its lanes in order. `V128` appears only where a value crosses an ABI boundary, as a `Direct` `V128` piece (decision 1 of `docs/02-ir-design.md`); the interpreter reports `Unsupported` for it.

Lowering keeps a vector as a stack slot of lanes, and each lane is one scalar load, store or select (`src/lower/lower_simd.odin`). Native vector selection (SSE, NEON) for these operations is a later optimization, deferred; it is not implemented, and the per-lane form is the reference.

Element types follow the official `src/check_builtin.cpp`: `simd_reduce_or` takes integer or boolean elements (line 1403; the official compiler rejects `#simd[4]f32` with that message, observed with `odin check`), `simd_reduce_min` takes integer or float (line 1368), and `simd_indices` takes any numeric element (line 1277). `base/intrinsics/intrinsics.odin` declares float for `simd_reduce_or`, `simd_reduce_and` and `simd_reduce_xor` as well; the checker keeps the official rule, and the base declaration is reported for the owner to decide. Float `simd_reduce_min` lowers to `FLt` with `FNe` for NaN, the `fmin` rule of `llvm.vector.reduce.fmin` (official `src/llvm_backend_proc.cpp`, reduce_min, ~2040-2070).

## 14. TLS, atomics, bit and target operations

A `Global` with `thread_local` is an IR global with the TLS flag. A reference to it is `tls_addr` (H1), which `amd64` and the ELF writer turn into the thread-pointer-relative access (`PT_TLS`, `.tdata` and `.tbss`, `R_X86_64_TPOFF32`, per H1 and `docs/04-amd64-design.md`).

Atomic builtins lower to `Atomic_Rmw` (with `Access_Info.rmw`), `Atomic_Cas` (with the success and failure orders and `weak`), `Load_Ordered`, ordered `Store` and `Fence`. The Odin order names map one-to-one to `Memory_Order`. Floats compare by bits in CAS (`bitcast` first). The sequential semantics of these nodes are fixed by C4.

Bit operations map to kinds where the kind exists: count leading and trailing zeros to `Clz` and `Ctz`, count ones to `Popcnt`, byte swap to `Bswap`, square root to `FSqrt`, and the high halves of products to `Mul_Hi_S` and `Mul_Hi_U`. Overflow builtins expand to compares and `Mul_Hi` (`docs/02-ir-design.md` section 4 and section 8). `count_zeros` is the bit width minus `Popcnt`, as in the fork (`lb_emit_count_zeros`, `llvm_backend_utility.cpp:735-742`). Rotates and bit reversal are expanded from shifts and masks (H3). The target intrinsics `cpuid`, `xgetbv`, `pause` and `rdtsc` map to `Target_Op`, and dynamic stack allocation to `Stack_Alloc` (H7).

Raw system calls, `intrinsics.syscall` (`base/intrinsics`), map to `Syscall` with the number and the arguments in order. The result is one `uintptr`, the value of the kernel's return register.

## 15. Startup and exit

The process entry, the TLS setup and the stack-protector sequence are emitted by the compiler as IR, not from assembly (open-question ruling 2). The sources they replace are `base/runtime/entry_unix_no_crt_linux_amd64.asm`, `tls_linux_no_crt.odin` and `stack_protector_linux_no_crt.odin` (`base/runtime`); they are the reference for the order of the steps.

The generated `_start` (H8, `lower_startup.odin`) does, in order: read `argc`, `argv` and `envp` from the initial stack; set up the TLS block, copying `.tdata` and zeroing `.tbss`, then `arch_prctl(ARCH_SET_FS)` through `Syscall` (H1); set up the stack-protector canary; call the runtime's context initialization; call the init procedures in `Runtime_Requirements.init_procedures` order (sorted by priority, then by checker order), with dynamic global initializers in `global_init_order`; call `main`; call the fini procedures; then `exit` with the code `main` returns (`Syscall` 60). Each step calls a checked procedure or `Syscall`; nothing else is in `_start`.

The first slice needs only `_start` calling `main` and `exit`, with no TLS and no canary (section 19).

## 16. Determinism

The same input gives the same bytes. Symbols are declared in checker order (section 4). Functions are in that order. Blobs merge in function order. No map is iterated where order matters: relocations, type-table slots, init lists and error lists are all sorted by their checker key (slot, priority, or the (function, node) pair). Worker results are written to per-function slots and read back in order. Generated helper keys are the canonical keys from the checker, never addresses or discovery ordinals (`docs/03-checker-design.md` section 11).

## 17. Errors and verification

`lower` returns `Lower_Error` values, each with the entity of the procedure, the `Node_Ref` or source span, and a `Lower_Feature` naming the unhandled feature or the failed check. An unhandled retained plan, or a construct that G-tickets have not yet written, is one of these errors. It is never replaced by a fallback path (the PR 7850 reason string is not reused). Errors are collected per function and returned sorted by (function index, node id).

Three kinds of failure are kept apart. A feature not implemented is `Lower_Error` with `Unsupported`. An IR verifier rejection after a function is built is reported with the `ir.Verify_Code` and the function. A broken checker fact (a missing expression, a dangling range) is an `assert` in debug builds, because the boundary verifier should have caught it before lowering. Allocation failure returns `runtime.Allocator_Error`, and the builder's sticky error reports it through `function_finish`.

The IR verifier runs on each function after its builder finishes (`docs/02-ir-design.md` section 9). The signature rule (at most two results) is checked there too, for every signature of the function, so a bad signature cannot reach `amd64`.

## 18. Tickets

Each row names its files. Files do not overlap between rows, except that a ticket may add a case to a switch that G0 owns, and then G0's file is touched only by G0. Each ticket has one test that the earlier tickets could not express. "Needs" gives the steps in `docs/02-ir-design.md` section 15 and the rows here.

| Ticket | Deliverable | Files (own) | Needs | Test |
|---|---|---|---|---|
| G0 (added) | Module pass, symbol table, procedure job pool, parameter binding, implicit return, error type, `lower_program` | `lower.odin`, `lower_module.odin`, `lower_procedure.odin`, `lower_error.odin`, `lower_test.odin` | A5, B3, checker model | a procedure returning a constant, built and verified |
| G1 | Expressions: constants, operators, comparisons, conversions, divide/shift rules, address-taken pre-pass | `lower_expr.odin`, `lower_operator.odin`, `lower_conversion.odin`, `lower_constant.odin`, `lower_expr_test.odin` | G0 | the divide-by-zero table of section 8 by interpretation |
| G2 | Statements and control: `if`, `for`, `switch`, `break`/`continue`/`fallthrough`, assignment order, `when`, `defer`, `return`, `or_return` | `lower_stmt.odin`, `lower_control.odin`, `lower_defer.odin`, `lower_exit.odin`, `lower_stmt_test.odin` | G1 | assignment order and defer order by interpretation |
| G3 | Calls and ABI use: plan to signature, parameter reassembly, `Indirect`, `By_Value`, split results, extension, context and default context | `lower_abi.odin`, `lower_call.odin`, `lower_context.odin`, `lower_call_test.odin` | G1, B3 | split results and a `By_Value` argument through the interpreter |
| G4 | Aggregates, slices, strings, bounds, places, dynamic arrays | `lower_aggregate.odin`, `lower_slice.odin`, `lower_bounds.odin`, `lower_place.odin`, `lower_aggregate_test.odin` | G2 | slice bounds failure edge |
| G5 | Unions, `any`, `typeid`, runtime type information and `type_table` | `lower_union.odin`, `lower_any.odin`, `lower_typeinfo.odin`, `lower_typeinfo_test.odin` | G4 | descriptor relocations and slot order |
| G6 | Maps and `#soa` | `lower_map.odin`, `lower_soa.odin`, `lower_map_test.odin` | G4, G5 | a map insert call and an `#soa` gather |
| H1 | TLS: TLS globals, `tls_addr`, TLS image for the object writer | `lower_tls.odin`, `lower_tls_test.odin` | G0, A3, F4 | a `tls_addr` node interpreted, and the TLS image checked by the ELF writer tests |
| H2 | Atomics, fences and ordered accesses | `lower_atomic.odin`, `lower_atomic_test.odin` | G3, F4, C4 | per-op results (C4 cases) |
| H3 | Bit operations, `Mul_Hi`, overflow expansions, `FSqrt`, `Bswap`, `Popcnt` for `count_ones` and `count_zeros`, and rotates | `lower_bits.odin`, `lower_bits_test.odin` | G1, F2 | per-op values at boundaries |
| H4 | `i128` and `u128` pair expansion, `udivmod128` path | `lower_int128.odin`, `lower_int128_test.odin` | G1 | boundary values (0, 1, -1, MIN, MAX) |
| H5 | `f16` promotion and rounding | `lower_float16.odin`, `lower_float16_test.odin` | G1, F3 | rounding cases against the fork |
| H6 | `#simd` scalarization | `lower_simd.odin`, `lower_simd_test.odin` | G4 | `memory_equal` and compare on lanes |
| H7 | `Target_Op` and `Stack_Alloc` lowering | `lower_target.odin`, `lower_target_test.odin` | G0, F1 | `cpuid` leaf 0 table |
| H8 | Startup without assembly: `_start`, argument capture, TLS setup, canary, init and fini order, exit | `lower_startup.odin`, `lower_startup_test.odin` | H1, G3, G5 | the M2 default-runtime executable |

The driver step that loads and checks one file, and writes the executable through `amd64` and `elf`, is not a `lower` ticket. It is a driver ticket (owned by `driver`), and the first slice needs it (section 19).

## 19. Minimal first slice

The first slice is milestone M0 of `docs/02-ir-design.md` section 15 with no runtime types. It contains G0, the integer and bool parts of G1, the control parts of G2 (`if`, `for`, `break`, `continue`, `return`, assignment order), the direct-call part of G3 for `Contextless` and `Direct` integer parameters and results, the memory subset of G4 (local arrays and stack slots, indexing without bounds checks), and the raw-syscall intrinsic. It excludes defer, context, bounds checks, strings, slices, unions, `any`, `typeid`, maps, `#soa`, `i128`, `f16` and `#simd`.

The acceptance program is a Linux file of this shape, with `main` declared contextless so that no context is needed:

```
package main

import "base:intrinsics"

main :: proc "contextless" () {
	buffer: [6]u8
	#no_bounds_check for i in 0 ..< 5 {
		buffer[i] = u8('a' + i)
	}
	buffer[5] = '\n'
	intrinsics.syscall(1, 1, uintptr(&buffer), 6)
	intrinsics.syscall(60, 0)
}
```

Its acceptance is that the interpreter, run on the lowered module, produces the bytes `abcde\n` on fd 1 with outcome `Exit` and code 0; and that the executable written by `amd64` and `elf` prints the same bytes and exits with status 0. The `amd64` side is `docs/04-amd64-design.md`. The checker must accept this file; that is a precondition on `check`, not a `lower` ticket.

This slice has one deliberate deviation from the full ABI: `main` is contextless, so `_start` calls it without a context pointer. The default `main` of Odin takes a context; that enters with G3 and the context path, and then the `__init_context` call and the runtime startup enter with H8 and M2.

## 20. Open questions and risks

1. Address-taken analysis (section 5) is a lower pre-pass. If the checker can report it cheaply, G1 should take the checker's answer instead; this is a G1 decision with evidence from `lb_address_from_load_or_generate_local` and the checker's addressing modes.
2. Two-result returns and calls. A 9-to-16-byte aggregate result, and a mixed-class result, need two `Return` or `Call` results. The interpreter reports `Unsupported` for a `Return` with two results (decision 2 of `docs/02-ir-design.md`) and handles one value per call. These cases are then checked only by `amd64` and the ABI matrix (B4), not by the interpreter oracle. The first slice avoids them.
3. `f16` arithmetic is promoted (section 13). H5 must confirm the rounding cases against the fork before it is accepted.
4. The contextless `main` of the first slice is a deviation from Odin's `main`. It is only a slice; the full entry is H8.
5. The stack-protector canary source (the auxiliary vector's random bytes) and the argument capture in `_start` follow `base/runtime`. H8 decides the exact sequence from those sources.
6. Startup and runtime helpers are checked procedures named by the checker's runtime requirements. If the checker omits one that lowering needs, the boundary verifier rejects it; `lower` does not add a helper on its own.
7. `docs/02-ir-design.md` section 10 does not yet list the typed errors of `lower` (`Lower_Error`); that addition belongs to G0 if the orchestrator approves it.
