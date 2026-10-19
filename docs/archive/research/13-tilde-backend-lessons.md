# 13 Tilde backend lessons

Ginger Bill's Tilde backend (`-tilde`, `src/tilde*.cpp`) lowered Odin's checked AST straight to the TB library's IR, without LLVM. It was removed on 2026-03-26. This note maps the removed code, records what it does for each topic we care about, and separates what carries over from what is tied to C++ or to TB. The code is materialized under `/home/su3h7am/Projects/refs/odin-tilde-backend/src/`. The TB library's C sources are not in the tree; only its headers and a prebuilt `tb.lib` were, so TB's optimizer, codegen and ABI classification cannot be read from here.

## Provenance

- Removal commit: `25c10c18cca5150c03f3de256ea140aebf1c3667`, "Remove tilde backend", gingerBill, 2026-03-26 11:49:39 +0000.
- Merged as PR #6483 "Remove Tilde Backend", merge commit `fb69d8132deb8972eaad0cdc3be8513ff078d091`, 2026-03-26 12:07:25 +0000. The PR has no description and no review discussion.
- Last commit before removal, the state materialized here: `4697c8837cab7944fe22d0d14b45a33f406466ce` (merge of PR #6479), 2026-03-26 11:16:49 +0000. It is the parent of the removal commit.
- Last tilde-related change before removal: `e0652ee2f`, 2023-12-13, "Minor fix to call expr in tilde with variadic parameters". The code sat idle for about 27 months.
- First tilde commit: `d7af6de9b` "Add tilde", 2023-07-08. About 36 commits mention tilde.
- Where the history lives: `/home/su3h7am/Projects/Odin` has the full history. `refs/Odin-upstream` is a shallow clone at `cb755818f` and does not contain `25c10c18c`. `refs/odin-pr7850-fast-backend` has no tilde files or commits. The fork's HEAD (`ea225db25`) has no tilde files.
- The removal touched 21 files (+3 −14,714): all of `src/tilde*`, `src/tilde/` (headers and `tb.lib`), the `build.bat` `tilde_backend` block, the `ALLOW_TILDE` include, the `-tilde` flag and the linker hook in `main.cpp`, the `tilde_backend` field in `build_settings.cpp`, the `ODIN_TILDE` constant in `checker.cpp`, the `cg_module`/`cg_procedure` union in `entity.cpp`, and a wasm runtime-entity condition in `checker.cpp`.

## Why it was removed

Not stated. The commit message is two words, the PR body is empty, and I found no linked issue. Facts from the code that bear on the decision:

- Windows only. `ALLOW_TILDE` is defined only under `GB_SYSTEM_WINDOWS` in `main.cpp`, and `cg_emit_call` asserts `build_context.metrics.os == TargetOs_windows`.
- `build.bat` marked it "THIS TILDE STUFF IS FOR DEVELOPMENT ONLY!" with `tilde_backend=0`.
- No bounds checks were emitted (see topic 8).
- Calling-convention classification was delegated to TB's binary library.

Treat the reason as unknown. Ask Ginger Bill before relying on any single explanation.

## File map

| File | Lines | Role |
|---|---|---|
| `src/tilde.hpp` | 385 | `cgValue`, `cgAddr`, `cgProcedure`, `cgModule`, `cgDefer`, target and control-region structs; runtime-proc name macros |
| `src/tilde.cpp` | 842 | module create/destroy, name mangling, global variable creation, startup and cleanup procs, `cg_generate_code` (driver), object export |
| `src/tilde_proc.cpp` | 1326 | prototypes from debug types, procedure create/begin/end, calls (`cg_emit_call`, `cg_build_call_expr_internal`), default args, hasher and equal procs |
| `src/tilde_stmt.cpp` | 2889 | load/store, addresses and field access, scopes and defer, assignment, return, if/for/range, switch, type switch, declarations |
| `src/tilde_expr.cpp` | 3960 | operators, conversions, comparisons, slices, index addresses, compound literals, `any` and union casts, map ops, `or_else`/`or_return` |
| `src/tilde_const.cpp` | 1049 | constant values to TB global memory, strings, `Source_Code_Location` |
| `src/tilde_type_info.cpp` | 984 | `runtime.Type_Info` tables, typeids |
| `src/tilde_debug.cpp` | 482 | Odin types to TB debug types |
| `src/tilde_builtin.cpp` | 592 | builtin procedures (len, cap, min, max, abs, clamp, mem ops, trap, map info) |
| `src/tilde/tb.h` and `tb_*.h` | 2129 | TB 0.3 public header and internal headers (tb.h 1309, tb_coff 334, tb_elf 170, tb_formats 132, tb_x64 105, tb_arena 79) |
| `src/tilde/tb.lib` | binary, 2,347,218 B | not materialized |

The `tilde*.cpp`/`hpp` total is 12,509 lines.

## Topics

### 1. Procedure ABI and aggregates

Ginger Bill's code asks TB for each parameter and result: `tb_get_passing_rule_from_dbg` returns `TB_PASSING_DIRECT`, `INDIRECT` or `IGNORE` (`tilde_proc.cpp`: `cg_procedure_begin`, `cg_emit_call`). A direct parameter is spilled to a local (`tb_inst_local` plus a store) so it has an address. An indirect parameter is used as the incoming pointer. For non-Odin calling conventions, indirect arguments are copied into 16-byte-aligned temporaries.

- Adapt: the shape is generic. Classify each parameter and result as register, memory or ignored; spill register parameters to a slot so Odin's by-address semantics hold.
- TB or C++ specific: the classification is a black box in `tb.lib`. Only Win64 is asserted. Nothing here covers SysV, SSE/INTEGER eightbyte splitting or two-register returns.
- Our side: the SysV classification must be ours (docs/04).

### 2. sret, split returns and multi-results (Odin calling convention)

For `ProcCC_Odin`, the parameter order is:

1. the sret pointer, if the last result is indirect;
2. regular parameters (`IGNORE` skipped);
3. one pointer per result except the last ("split returns");
4. the context pointer, last.

The last result is the only value returned in registers, or through sret (`cg_procedure_begin`, `cg_emit_call`, `cg_build_return_stmt_internal`). The caller allocates zeroed locals for sret and each split slot, aligned to at least 16 bytes, and reads results back as addresses (`cg_lvalue_addr`). The callee writes split results through their pointers, then returns. A register return is zero-extended for `i1` and bitcast otherwise. A struct-like register return is stored into a local and addressed.

- Adapt: this matches the param list in docs/02 ("sret, regular pieces, split-result pointers, context"). Split results as caller-owned slots and the last result as the return value is the design to implement.
- Adapt: zeroing the slots looks unnecessary, since the callee always assigns every result. GB left `TODO(bill): Should this need to be zeroed any way?` in `cg_emit_call`.
- TB or C++ specific: `TB_PROTOTYPE_RETURNS`, raw `TB_DataType` comparisons, and the `return_count == 1` limit of TB prototypes.
- Non-Odin conventions: only single results work. `cg_build_return_stmt_internal` asserts `TODO(bill): multi-return values for the return`. Multi-result calls use a tuple local with member offsets.

### 3. Context pointer

Odin-convention procedures receive `__.context_ptr` as their last hidden parameter. `cg_procedure_begin` pushes it onto `context_stack` with `uses = +1`. Callers use `cg_find_or_generate_context_ptr` (`tilde_expr.cpp`): reuse the top of the stack, or for non-Odin conventions create a local `context`. `cgAddr_Context` entries are popped when their scope closes (`cg_scope_close`). Each `cgDefer` saves `context_stack_count`, so a deferred statement runs under the context that was active when it was registered (`cg_build_defer_stmt`).

- Adapt: one hidden trailing pointer per Odin-convention call; a context stack keyed by scope; defers capture the context. This is the semantics in docs/03 and docs/05.
- TB specific: nothing material.

### 4. Default arguments and `#caller_location`

`cg_handle_param_value` (`tilde_proc.cpp`) covers four `ParameterValue` kinds: `Constant`, `Nil`, `Location` and `Value`. `Value` is evaluated in the caller's scope at each call site. Named arguments are matched by `lookup_procedure_parameter`. `Location` builds a `Source_Code_Location` at the call site: file path string, line and column as `i32`, and the caller's procedure name (`cg_emit_source_code_location_as_global`, `tilde_const.cpp`).

- Adapt: defaults are evaluated at the call site in the caller; named arguments fill slots; `caller_location` uses the call-site position and the enclosing procedure's name.
- Do not copy: each call creates a new `scl$N` global. Identical locations could share one static object keyed by file, line, column and procedure.
- TB specific: `TB_Global` region API.

### 5. Variadics and `any`

Odin variadics (not C varargs): the caller builds a stack array of the element type, fills it, and passes a slice `{data, len}` (`cg_build_call_expr_internal`). A spread argument (`xs...`) passes the slice unchanged. An empty variadic list passes a nil slice. C varargs push raw arguments, with `any` elements promoted by `default_type`.

Conversion to `any` (`cg_emit_conv`, `tilde_expr.cpp`, the `is_type_any(dst)` branch) makes the data pointer refer to a local temporary, obtained with `cg_address_from_load_or_generate_local`, and stores the typeid. The pointer therefore refers to a temporary in the caller's frame, as the code stands.

Assertion to `any` (`cg_emit_cast_any`, `tilde_expr.cpp`) compares typeids. On success it copies the value out. On failure it calls `type_assertion_check2` with file, line, column and, unless `no_rtti`, both typeids. The `StateFlag_no_type_assert` path loads the value directly.

- Adapt: the `{data, typeid}` layout; variadics as a stack array plus slice; failure as a runtime call that receives the location; the `no_type_assert` shortcut.
- Do not copy: a stray debug trap at `tilde_expr.cpp` in `cg_emit_conv`, `GB_PANIC("HERE ...")`, which fires only for `main@main`.

### 6. Constant aggregates and string emission

Constants go straight into TB global memory, with no code. Globals are created with `tb_global_set_storage(size, align, max_regions)`. `cg_global_const_add_region` walks the `ExactValue` and writes bytes with `tb_global_add_region`. Integers are packed through big-int code (`cg_write_big_int_at_ptr`, which asserts little-endian). Pointers are written with `tb_global_add_symbol_reloc`. Arrays repeat their element. Rune arrays are decoded into `i32`. Compound literals go through `cg_global_const_comp_literal`.

Strings: each literal becomes a `csb$N` object in rdata, containing the bytes and a NUL byte. A `string` is a relocation to that object plus the length. A `cstring` points at the object directly. A constant `[N]u8` from a string is a truncated memcpy.

Non-constant initializers are emitted into `__$startup_runtime`, in the checker's `variable_init_order` (`cg_global_variables_initialize`).

- Adapt: the split between constant data (static image plus relocations) and dynamic initialization (startup procedure in initialization order). docs/02 already plans this: constants as bytes plus `Data_Reloc`, non-constant initializers in a generated startup procedure.
- Adapt, with a change: intern string literals. GB emits a separate `csb$N` for every literal.
- Gaps: matrices and `#simd` vectors panic in constant emission (`tilde_const.cpp`), as do procedure literals as constants.
- TB specific: region bookkeeping and `TB_Global` and `TB_Symbol`.

### 7. Globals and `thread_local`

File-scope variables are created by `cg_global_variables_create` (`tilde.cpp`) with a mangled name. Storage goes in the data section, or in the TLS section when `thread_local_model != ""`. Foreign and exported variables get public linkage. Block-scope `static` variables (`cg_build_mutable_value_decl`, `tilde_stmt.cpp`) get the name `proc-.name-id` and a constant initializer.

The four TLS model names (`default`, `localdynamic`, `initialexec`, `localexec`) are accepted, but each is a TODO that generates the same code. Any other name panics.

- Adapt: an explicit section kind (data, rdata, tls) chosen from the entity's flags; a mangling that includes the package and the entity id.
- Gap: TLS models are not distinct. Linux TLS (the FS-based block and its setup) has to be ours, since no libc is used. GB's code offers nothing for that. docs/04 section 9 already plans local-exec TLS (`Tls_Addr`).
- TB specific: `tb_module_get_tls`.

### 8. Bounds checks and traps

This backend emits no runtime bounds checks. Every `cg_emit_bounds_check` call is commented out: index addresses (`tilde_expr.cpp`, around lines 3622 to 3756), slice expressions (1463, 1486), and `#soa` address sites (`tilde_stmt.cpp` 278, `tilde_expr.cpp` 2855). `#no_bounds_check` is only tracked as a state flag, propagated at `tilde_expr.cpp` 2240 to 2255 and `tilde_stmt.cpp` 2600 to 2605.

- `trap` lowers to `tb_inst_trap`. `debug_trap` lowers to `tb_inst_debugbreak` (`tilde_builtin.cpp` 434 to 438).
- A non-void procedure whose body falls through ends in `tb_inst_unreachable`. A void one ends in `ret` (`cg_procedure_end`).
- Adapt: the flag propagation for `#bounds_check` and `#no_bounds_check`.
- Do not adapt: the omission. It is the largest correctness gap in the removed code. Out-of-range indexing was undefined behavior here. docs/02 already has the right design: an inline condition with the handler called on the failure edge.
- TB specific: trap and debugbreak nodes.

### 9. Switch and defer

Switch (`cg_switch_stmt_can_be_trivial_jump_table` and `cg_build_switch_stmt`, `tilde_stmt.cpp`): a jump table is used when the tag is an integer or typeid of at most 8 bytes, excluding 8-byte integers (`DISALLOW_64_SWITCH`), and every case item is a constant integer or typeid with no ranges. Then one `tb_inst_branch` takes the case entries. Otherwise each case value becomes a `tb_inst_if` to the next condition region. A range `a..b` is two comparisons. A typeid case compares against `cg_typeid`. Each body is its own region. `fallthrough` jumps to the next body, and default comes last.

- Adapt: the trivial-table predicate, which matches the `Switch` node with a case table in docs/02. Keep ranges and fallthrough targets.
- Drop: the 8-byte exclusion, which is a TB limit.

Defer (`cg_emit_defer_stmts`, `cg_build_defer_stmt`): exits have three kinds. `Default` closes a scope and runs only that scope's defers. `Return` runs all defers. `Branch` (break and continue) runs defers in scopes inside the target loop. Each deferred statement is emitted inline at every exit, in a fresh `defer` region, with the context stack restored. `cgDefer_Proc` covers deferred calls whose arguments were evaluated at registration.

- Adapt: the three exit kinds and per-scope indices, as in docs/02 section 8. Inline duplication is simple; watch code size.

### 10. Type info generation

`cg_setup_type_info_data` (`tilde_type_info.cpp`) creates `__$type_info_data`, sized for the minimum-dependency type-info set plus one. Parallel member arrays hold types, names, offsets, usings, tags and enum values. Their sizes come from summing union variants, struct fields, tuple variables and enum fields across types in that set. Entries are filled through callbacks (`type_proc`, `name_proc`, `offset_proc`, and so on). A typeid is derived from the type's index (`cg_typeid_as_u64`, `cg_type_info_index`). Nothing is emitted when `no_rtti` is set.

- Adapt: sizing from the dependency set; parallel arrays, which suit our data-oriented layout; typeid as a stable index.
- The layout must match `base/runtime`'s `Type_Info` exactly. GB's code is the reference for field order.
- TB specific: region counts in `tb_global_set_storage`.

### 11. Debug info

`cg_debug_type` (`tilde_debug.cpp`) maps Odin types to TB debug types. Structs and unions become records with field offsets. Procedure-typed fields are `rawptr`. Locals and parameters are registered with `tb_function_attrib_variable`. A register-passed parameter with an indirect debug type gets a fake pointer variable (commented as a HACK in `cg_procedure_begin`). Format is CodeView on Windows and DWARF elsewhere (`cg_generate_code`).

- Adapt: the type mapping rules, such as flattening and treating procedure fields as `rawptr`.
- Our DWARF is handled separately (docs/09).

### 12. Other patterns worth keeping

- Value kinds: `cgValue` distinguishes `Value`, `Addr`, `Symbol` and `Multi`. `cgAddr` distinguishes places: `Default`, `Map`, `Context`, `SoaVariable`, relative pointers and slices, swizzles. This is a good model for assignment lowering. Map places need set calls and swizzles need component stores.
- Runtime calls by name: `cg_emit_runtime_call` finds procedures in the runtime package for map get and set, dynamic array append and reserve, `cstring` to `string`, `memory_equal` and `type_assertion_check2`. Keep this for panic and allocation paths.
- Equal and hasher procedures are generated per type and cached (`cg_equal_proc_for_type`, `cg_hasher_proc_for_type`, `tilde_proc.cpp`).
- Entry and init: dummy `__$startup_runtime` and `__$cleanup_runtime` procedures. The `__entry_point` builtin calls the entry point.
- Threading: `cg_procedure_end` uses the thread pool when `do_threading` is set, but `cg_generate_code` sets it to false.
- Optimization: the mem2reg and peephole passes are behind `if (false)` in `cg_procedure_compile_worker_proc`.

## Incomplete state (from the code)

- Windows x64 only. `cg_emit_call` asserts it, and `ALLOW_TILDE` requires Windows. The final state has no Linux or SysV path, although the backend began with a "Hellope World" in 2023.
- No bounds checks (topic 8).
- Unimplemented paths, each a `GB_PANIC("TODO(bill)...")`, across `tilde_expr.cpp`, `tilde_stmt.cpp`, `tilde_const.cpp` and others: matrices, `#simd` vectors, complex and quaternion arithmetic and conversions, map literals, `&m[k]`, `&v.(T)`, type assertion to non-union and non-`any` targets, relative pointers, SoA variables, swizzles, multi-result non-Odin returns, range over map, string and tuple, and `unroll` range.
- TLS models are accepted but not distinct.
- Optimizations and threading are off.
- Debug leftovers: the `main@main` panic in `cg_emit_conv`, and many commented-out `lb_*` blocks copied from the LLVM backend.
- Source-location globals are not deduplicated.

## What to adapt for our compiler

- Reuse the concepts: the Odin calling convention layout (sret, split returns, trailing context), value and place kinds, switch and defer classification, dependency-sized type info, and per-entity static data for constants.
- Do not reuse: the TB calls, the Win64 assumption, the missing bounds checks, the debug panic, and the per-call-site duplicated globals.
- Our ABI classification stays ours, for SysV (docs/04).

## Sources

- Git: `25c10c18c` (removal), `fb69d8132` (PR #6483 merge), `4697c8837` (last state with tilde), `e0652ee2f` (last tilde change), in `/home/su3h7am/Projects/Odin`.
- PR page: https://github.com/odin-lang/Odin/pull/6483 (no description, merged 2026-03-26).
- Materialized files: `/home/su3h7am/Projects/refs/odin-tilde-backend/src/`.
