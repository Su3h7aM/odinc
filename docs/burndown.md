# Burn-down

## Current fixture sweep (2026-10-20)

`mise run diff-test` ran on 142 fixture directories. 96 passed and 46 failed. The sweep excluded the empty `src/driver/testdata/user_collections` package root and included `src/driver/testdata/user_collections/app`; the latter cannot resolve its custom `nabla` collection in the diff-test configuration. The `map_assign` fixture is parked outside the repository and is not in this count. Each failing fixture was retried once. All 46 failures repeated, so no transient result appeared during the concurrent GS37 edits. Among the 28 `demo_section_*` fixtures, 22 passed and 6 failed.

## Fixture results

| fixture | status | first failure (phase and line) |
| --- | --- | --- |
| src/driver/testdata/addr_of_literal | PASS | — |
| src/driver/testdata/any_composite | PASS | — |
| src/driver/testdata/atomic_pointers | PASS | — |
| src/driver/testdata/atomics | FAIL | official-build: src/driver/testdata/atomics/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/bit_field | FAIL | official-build: src/driver/testdata/bit_field/main.odin(16:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/bit_ops | FAIL | official-build: src/driver/testdata/bit_ops/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/bit_set_wide | PASS | — |
| src/driver/testdata/caller_location_files | PASS | — |
| src/driver/testdata/comma_ok_assert | PASS | — |
| src/driver/testdata/complex_ops | PASS | — |
| src/driver/testdata/composite_literals | FAIL | official-build: src/driver/testdata/composite_literals/main.odin(20:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/constant_log2 | FAIL | official-build: src/driver/testdata/constant_log2/main.odin(7:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/core_thread_probe | PASS | — |
| src/driver/testdata/cstring_literals | FAIL | official-build: src/driver/testdata/cstring_literals/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/cstring_ops | PASS | — |
| src/driver/testdata/declared_assignment | FAIL | official-build: src/driver/testdata/declared_assignment/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/demo_section_bit_field_type | PASS | — |
| src/driver/testdata/demo_section_bit_set_type | FAIL | odinc-check: base/runtime/core_builtin.odin:1658:44: Undeclared_Type |
| src/driver/testdata/demo_section_constant_literal_expressions | FAIL | odinc-lower: src/driver/testdata/demo_section_constant_literal_expressions/main.odin:40:10: lower Unsupported Place |
| src/driver/testdata/demo_section_control_flow | PASS | — |
| src/driver/testdata/demo_section_cstring_example | PASS | — |
| src/driver/testdata/demo_section_deprecated_attribute | PASS | — |
| src/driver/testdata/demo_section_explicit_context_definition | PASS | — |
| src/driver/testdata/demo_section_explicit_procedure_overloading | PASS | — |
| src/driver/testdata/demo_section_implicit_context_system | PASS | — |
| src/driver/testdata/demo_section_implicit_selector_expression | PASS | — |
| src/driver/testdata/demo_section_matrix_type | FAIL | odinc-check: src/driver/testdata/demo_section_matrix_type/main.odin:6:5: Unsupported_Type_Expression |
| src/driver/testdata/demo_section_named_proc_return_parameters | PASS | — |
| src/driver/testdata/demo_section_or_break_and_or_continue_operators | PASS | — |
| src/driver/testdata/demo_section_or_else_operator | PASS | — |
| src/driver/testdata/demo_section_or_return_operator | PASS | — |
| src/driver/testdata/demo_section_parametric_polymorphism | PASS | — |
| src/driver/testdata/demo_section_partial_switch | PASS | — |
| src/driver/testdata/demo_section_range_statements_with_multiple_return_values | PASS | — |
| src/driver/testdata/demo_section_ranged_fields_for_array_compound_literals | PASS | — |
| src/driver/testdata/demo_section_soa_struct_layout | FAIL | odinc-check: src/driver/testdata/demo_section_soa_struct_layout/main.odin:12:5: Unsupported_Type_Expression |
| src/driver/testdata/demo_section_struct_type | PASS | — |
| src/driver/testdata/demo_section_the_basics | PASS | — |
| src/driver/testdata/demo_section_union_maybe | PASS | — |
| src/driver/testdata/demo_section_union_type | PASS | — |
| src/driver/testdata/demo_section_unroll_for_statement | PASS | — |
| src/driver/testdata/demo_section_using_statement | FAIL | odinc-check: src/driver/testdata/demo_section_using_statement/main.odin:15:2: Unsupported Statement_Kind |
| src/driver/testdata/demo_section_variadic_procedures | PASS | — |
| src/driver/testdata/demo_section_where_clauses | FAIL | odinc-check: src/driver/testdata/demo_section_where_clauses/main.odin:42:10: Conversion |
| src/driver/testdata/entry_point_noop | PASS | — |
| src/driver/testdata/enum_extrema | FAIL | official-build: src/driver/testdata/enum_extrema/main.odin(14:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/f16_ops | PASS | — |
| src/driver/testdata/global_init_order | PASS | — |
| src/driver/testdata/global_string_fields | PASS | — |
| src/driver/testdata/global_struct_literal | PASS | — |
| src/driver/testdata/hello_fmt | PASS | — |
| src/driver/testdata/histogram_program | FAIL | official-build: src/driver/testdata/histogram_program/main.odin(3:1) Syntax Error: Unknown library collection: 'missing' |
| src/driver/testdata/implicit_addr_literal | PASS | — |
| src/driver/testdata/implicit_runtime | PASS | — |
| src/driver/testdata/import_cycle | FAIL | official-build: src/driver/testdata/import_cycle/a/a.odin(3:1) Error: Cyclic importation of 'b' |
| src/driver/testdata/index_through_pointer | PASS | — |
| src/driver/testdata/init_proc | PASS | — |
| src/driver/testdata/main_implicit_context | PASS | — |
| src/driver/testdata/make_any_int | PASS | — |
| src/driver/testdata/map_cell_info | FAIL | official-build: src/driver/testdata/map_cell_info/main.odin(12:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/map_info | FAIL | official-build: src/driver/testdata/map_info/main.odin(11:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/map_lookup | PASS | — |
| src/driver/testdata/memory_args | PASS | — |
| src/driver/testdata/memory_misc | FAIL | official-build: src/driver/testdata/memory_misc/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/multi_value_args | PASS | — |
| src/driver/testdata/multiple_assignment | FAIL | official-build: src/driver/testdata/multiple_assignment/main.odin(15:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/named_arguments | PASS | — |
| src/driver/testdata/nil_assign | PASS | — |
| src/driver/testdata/nil_compare | PASS | — |
| src/driver/testdata/numeric_builtins | FAIL | official-build: src/driver/testdata/numeric_builtins/main.odin(13:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/or_break | FAIL | official-build: src/driver/testdata/or_break/main.odin(27:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/or_break_continue | PASS | — |
| src/driver/testdata/or_continue | FAIL | official-build: src/driver/testdata/or_continue/main.odin(30:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/or_else | FAIL | official-build: src/driver/testdata/or_else/main.odin(18:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/or_else_forms | PASS | — |
| src/driver/testdata/or_return | FAIL | official-build: src/driver/testdata/or_return/main.odin(52:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/or_return_assert | PASS | — |
| src/driver/testdata/or_return_convert | PASS | — |
| src/driver/testdata/or_return_multi | PASS | — |
| src/driver/testdata/or_return_value | PASS | — |
| src/driver/testdata/package_imports | PASS | — |
| src/driver/testdata/package_procedure_names | PASS | — |
| src/driver/testdata/pointer_arithmetic | PASS | — |
| src/driver/testdata/polymorphic_records | PASS | — |
| src/driver/testdata/probe_1 | PASS | — |
| src/driver/testdata/probe_2 | PASS | — |
| src/driver/testdata/probe_3 | PASS | — |
| src/driver/testdata/probe_4 | PASS | — |
| src/driver/testdata/procedure_literals | FAIL | official-build: src/driver/testdata/procedure_literals/main.odin(9:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/range_loops | PASS | — |
| src/driver/testdata/range_loops_more | PASS | — |
| src/driver/testdata/raw_data | FAIL | official-build: src/driver/testdata/raw_data/main.odin(6:39) Error: 'raw_data' expects a string, slice, dynamic array, or pointer to array |
| src/driver/testdata/return_call | PASS | — |
| src/driver/testdata/root_directory | FAIL | official-build: src/driver/testdata/root_directory/ignored_test.odin(2:1) Error: Redeclaration of 'helper' in this scope |
| src/driver/testdata/section_19 | FAIL | official-build: src/driver/testdata/section_19/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/section_20 | PASS | — |
| src/driver/testdata/section_21 | PASS | — |
| src/driver/testdata/section_22 | PASS | — |
| src/driver/testdata/section_23 | PASS | — |
| src/driver/testdata/section_24 | PASS | — |
| src/driver/testdata/section_25 | PASS | — |
| src/driver/testdata/section_26 | PASS | — |
| src/driver/testdata/section_27 | PASS | — |
| src/driver/testdata/section_28 | PASS | — |
| src/driver/testdata/section_29 | PASS | — |
| src/driver/testdata/section_30 | FAIL | official-build: src/driver/testdata/section_30/main.odin(8:3) Error: A thread local variable declaration cannot have initialization values |
| src/driver/testdata/section_31 | FAIL | official-build: src/driver/testdata/section_31/main.odin(9:1) Error: @(init) procedures must be declared as "contextless" |
| src/driver/testdata/section_32 | FAIL | official-build: src/driver/testdata/section_32/main.odin(6:14) Error: Procedures requiring a 'context' cannot be called at the global scope |
| src/driver/testdata/section_33 | PASS | — |
| src/driver/testdata/section_34 | FAIL | official-build: src/driver/testdata/section_34/main.odin(29:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/section_35 | FAIL | official-build: src/driver/testdata/section_35/main.odin(17:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/simd_intrinsics | FAIL | official-build: src/driver/testdata/simd_intrinsics/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/spread_call | PASS | — |
| src/driver/testdata/startup_args | FAIL | official-build: src/driver/testdata/startup_args/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/static_local | PASS | — |
| src/driver/testdata/string_compare | FAIL | official-build: src/driver/testdata/string_compare/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/string_literals | PASS | — |
| src/driver/testdata/string_switch | FAIL | official-build: src/driver/testdata/string_switch/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/struct_by_value_mixed | PASS | — |
| src/driver/testdata/switch_fallthrough | PASS | — |
| src/driver/testdata/ternary_forms | PASS | — |
| src/driver/testdata/type_assertions | PASS | — |
| src/driver/testdata/type_info_kinds | PASS | — |
| src/driver/testdata/type_info_of | FAIL | official-build: src/driver/testdata/type_info_of/main.odin(13:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/type_predicates | PASS | — |
| src/driver/testdata/unaligned_store | PASS | — |
| src/driver/testdata/uninitialized | FAIL | official-build: src/driver/testdata/uninitialized/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/unreachable | FAIL | official-build: src/driver/testdata/unreachable/main.odin(9:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/unsupported_import | FAIL | official-build: src/driver/testdata/unsupported_import/main.odin(3:1) Syntax Error: Path does not exist: core:no_such_package |
| src/driver/testdata/user_collections/app | FAIL | official-build: src/driver/testdata/user_collections/app/main.odin(2:1) Syntax Error: Unknown library collection: 'nabla' |
| src/driver/testdata/utf16_literals | FAIL | official-build: src/driver/testdata/utf16_literals/main.odin(5:1) Error: Procedure 'main' cannot have a custom calling convention |
| src/driver/testdata/variadic_defaults | PASS | — |
| src/driver/testdata/when_retry | PASS | — |
| src/driver/testdata/when_unresolved | FAIL | official-build: src/driver/testdata/when_unresolved/pkg/uses.odin(3:6) Error: Undeclared name: NEVER_DECLARED |
| src/driver/testdata/where_clauses_basic | FAIL | odinc-check: src/driver/testdata/where_clauses_basic/main.odin:27:13: Conversion |
| src/driver/testdata/wide_int_builtins | PASS | — |
| src/driver/testdata/wide_int_convert | PASS | — |
| src/driver/testdata/wide_int_params | PASS | — |
| src/driver/testdata/wide_intrinsics | PASS | — |
| src/driver/testdata/wide_switch | PASS | — |
| src/driver/testdata/x86_raw_operations | PASS | — |
| src/driver/testdata/zero_size_value | PASS | — |

## Changes since the last refresh

The previous refresh was at `7f2eee80`. These are the intervening commit descriptions recorded in the read-only history view.

- `561a2f6c1b43` procedures get package-qualified symbols; driver entry uses the main package symbol; package_procedure_names fixture.
- `b484a3219daf` or_return converts the status to the procedure result type; or_return_convert fixture.
- `e6b0f52e2d6e` lower: dynamic array and map parameters, raw_data and cap on dynamic arrays; memory_args fixture.
- `882d5e9ca6ee` amd64: fold spilled base and index into one address register before reloading the value.
- `bfbd114c0a9a` lower: zero-sized type assertion results; comma-ok assertion in assignment; comma_ok_assert fixture.
- `af9191212a55` lower: or_return on type assertions; struct pieces advance by eightbyte; or_return_assert and struct_by_value_mixed fixtures.
- `4dee3742637e` calls: multi-value arguments expand into plain, group and variadic callees; multi_value_args fixture.
- `2b9498d574e3` lower: complex and quaternion values and operators, f16 as integer bits; complex_ops and f16_ops fixtures.
- `4feb0a18c277` check: implicit &{...} with a pointer hint; complex and quaternion operators, untyped complex conversion and constant folding.
- `59b4081d60e7` map lookup: m[k], comma-ok, in, or_else through runtime __dynamic_map_get; map_lookup fixture.
- `7273c3029dec` check: overload where clauses can query candidate parameter types.
- `35d288d3c26c` lower: index and slice through pointers to arrays, slices, dynamic arrays; index_through_pointer fixture.
- `6656e88f489f` check: type_of in expressions; where clauses evaluated per overload candidate.
- `e61a4c0f9072` lower: address of composite literals; addr_of_literal fixture.
- `8f79ca32707b` check: untyped nil converts to aggregate targets; nil_assign fixture.
- `c943f9ee78dd` lower: zero-sized values get a one-byte slot; zero_size_value fixture.
- `ed079e4bb881` lower: or_return with several payload results; or_return_multi fixture.
- `09b518578cbf` or_break and or_continue with multi-result calls; or_break_continue fixture.
- `af2a497a37d0` or_else: type-assertion plans lower, map index pair checks; or_else_forms fixture.
- `5b7201dbb2a2` lower: 128-bit bit sets: iteration, membership, set operators; bit_set_wide fixture.
- `81449c01c405` lower: 128-bit byte_swap, reverse_bits and count intrinsics; wide_intrinsics fixture.
- `4f04e9e8ae1d` check: or_else passes its expected type to the operand.
- `26291527e721` lower: untyped constants convert to 128-bit integers; wide_int_convert fixture.
- `58f733e7f27e` lower: len of cstring scans to NUL; cstring_ops fixture.
- `13d2061de08c` lower: switch on wide integers and range cases; wide_switch fixture.
- `ffa291fd2550` lower: 128-bit abs, min, max, clamp; wide_int_builtins and caller_location_files fixture.
- `368394728076` check: constant cstring converts to string; cstring_conversion_test.
- `58a1ef9a54db` lower: 128-bit integer parameters; wide_int_params fixture.
- `5aabce78ade5` lower: ternary with aggregate result types; ternary_forms fixture.
- `d713c9a241a4` check: reject tests for mixed ints, ~0, bool arithmetic, int/string compare, unsigned negative, array length mismatch, float shift.
- `25c48a87a9c2` lower: any, map and dynamic array comparison against nil; nil_compare fixture.
- `682cfb191b39` lower: Complex and Quaternion type info entries; type_info_kinds fixture.
- `bcbf915c251d` lower: default arguments declared in another view (make with allocator); make_any_int fixture.
- `9ebbb63e1d7f` lower: string fields in constant package-level aggregates; global_string_fields fixture.
- `dedb687c6af5` lower: constant struct and array package-level initializers; global_struct_literal fixture.
- `a2262110e63c` types, lower: any{data, id} composite lowering through types.field_type; any_composite fixture.
- `4cf064a27e2b` check: generic procedure literals bound to local constants.
- `2232e40bf046` check: #any_int arguments in procedure-group scoring (make with typed lengths).
- `39e68386c132` check: defaulted parameter after a generic variadic.
- `edea3361f99e` check: spread into generic variadic parameters and generic members in group calls.
- `d8d8e0ec6f42` check: spread and named arguments in procedure-group calls for concrete members.
- `85d85e81a8ea` driver: print the unsupported reason after the diagnostic kind.
- `c70e0ee4` `@(static)` locals were ignored; this was fixed.

## hello_fmt

`src/driver/testdata/hello_fmt` links and runs, exits with code 0, prints `Hellope!`, and passes differential testing. The earlier runtime failure at `f.stream.procedure != nil` came from lowering `@(static)` locals as frame locals; `c70e0ee4` fixes that path. The related changes cover dynamic-array parameters, `raw_data` and `cap`, multi-value calls, default arguments in another view, package-qualified symbols, by-value aggregates, and AMD64 spilled-address materialization. `static_local`, `global_init_order`, and `init_proc` also pass.

## Known unsupported

- `#soa` array, slice, and dynamic-array types remain unsupported at type checking (2026-10-20; `src/driver/testdata/demo_section_soa_struct_layout`, `Unsupported_Type_Expression`). The demo's former 20 `Undeclared_Name v_soa` diagnostics cascaded from rejected `#soa[N]Vector3` declarations, not range-variable scoping. Those invalid declarations now bind poison-typed names, so their uses do not report secondary errors. The official fixture checks, builds, and exits 19.
- `m[k] = v` and `m[k] += 1` compile but misbehave at runtime; the `map_assign` fixture is parked while the call path is investigated.
- Map iteration with `for k, v in m` fails checking with `Unsupported Range_Type`.
- `cap(map)` is unsupported.
- Union and `any` fields from constants in composite literals fail with `Unsupported Constant`.
- Quaternion multiplication and division remain unsupported at lowering (2026-10-20; `src/driver/testdata/untyped_quaternion_product`, `lower Unsupported Operator` at line 8). The official fixture checks, builds, and exits 40. Quaternion literal typing and complex/quaternion `:=` defaulting now work; `src/driver/testdata/untyped_complex_defaults` passes differential testing with exit 44.
- SIMD operations on `f16` are unsupported.

## CS14 follow-up (2026-10-20)

The full-demo histogram fell from 280 to 251 diagnostics. Its 23 `Composite_Implicit_Type` diagnostics were 23 distinct imported-core source sites, not duplicate reports or demo-source literals: `core/math/big/internal.odin:1946`; `core/os/file_util.odin:253,274`; `core/os/file_linux.odin:325`; `core/os/pipe_linux.odin:52,55`; `core/os/process_linux.odin:176,213,253,863`; `core/os/temp_file.odin:29`; `core/io/conv.odin:32,37,42,47,52,57,63,68,73,78`; `core/sys/linux/sys.odin:2261`; `core/sys/posix/sys_mman_linux.odin:210`. All were bit-set literals in binary expressions. The histogram checks every declaration in every loaded package; a normal build checks reachable declarations and previously reported only the big-integer site.

Binary implicit literals now receive the other operand's contextual type, including parenthesized literals and literals on the left. Scalar and 128-bit bit-set operations use union, difference, intersection, symmetric difference, and subset/superset semantics; runtime literal elements lower to bit masks. Constant bit-set `+` and `-` fold as union and difference. `Composite_Implicit_Type` fell from 23 to 0 and `Composite_Bit_Set_Runtime` from 5 to 0. The new differential fixture `src/driver/testdata/bit_set_binary_literals` passes with official-confirmed exit code 73. It was added after the 142-fixture sweep above. No checker-only feature was added.

The references were the fork and reference compiler's `check_expr.cpp` (`check_binary_expr`, `check_compound_literal`) and `llvm_backend_expr.cpp` (`Type_BitSet` literal emission), existing aggregate and wide-bit-set lowering, and upstream issues [#2859](https://github.com/odin-lang/Odin/issues/2859) and [#5082](https://github.com/odin-lang/Odin/issues/5082). Official check/build probes are authoritative for this change: `+`, `-`, `&`, `&~`, `|`, binary `~`, equality and all four ordered comparisons accept contextual bit-set literals. Membership still requires a typed right-hand set: `E.A in {.A, .B}` is rejected with `Missing type in compound literal`.

The subsequent fixes reduced the histogram to 159 diagnostics. Failed local type declarations now bind poison-typed names, as failed package declarations already did. Official probes report one unknown-type error per declaration and no errors at the poisoned names' uses. This removed 53 secondary diagnostics without adding SoA support. Ordinary generic calls now defer untyped arguments until typed arguments bind the polymorphic parameter, reusing the rule previously limited to spread calls. This fixed eight datetime call sites. `src/driver/testdata/generic_untyped_arguments` passes with official-confirmed exit 47.

All nine `Conversion Call_Expr Unsupported` sites were constant `uintptr` to `rawptr` sentinel casts. Existing pointer-value lowering now receives interned pointer constants with their exact address bits; nonconstant inputs still use runtime conversions. Official probes accept `rawptr(~uintptr(0))`, `rawptr(uintptr(8))`, and pointer-to-`uintptr` constant round trips; they reject `rawptr(u64(1))` and the out-of-range intermediate `uintptr(1 << 64)`. Casting a constant `rawptr` to a procedure is a runtime value, not a constant. `src/driver/testdata/pointer_constants` passes with exit 83.

All nine `Mismatched_Types` diagnostics also disappeared. Eight were the two operands at each of `examples/demo/demo.odin:1545,1547,1549,1551`, caused by incorrect quaternion literal typing and missing complex/quaternion declaration defaults. The ninth, at line 675, was a returned pointer to a structure with a `using` base field. Contextual assignment now uses the existing assignment-conversion checker, including its subtype path, rather than rejecting that supported conversion before checking it. Existing subtype lowering handles the field offset. `src/driver/testdata/using_pointer_return` passes with exit 38 and checks a base field at a nonzero offset. Unsupported quaternion operators still fail explicitly at lowering.

Two `Generic_Call_Pattern` families remain. The matrix-multiplication example at `examples/demo/demo.odin:1155` uses nested array patterns whose later dimensions and element types reference earlier polymorphic bindings; the pattern matcher does not consult those bindings when evaluating the dimensions. The `card(e)` call at line 1452 uses `$S/bit_set[$E; $U]`, whose bit-set specialization pattern is not implemented. Neither family was approximated.

### Indirect-call default-argument design blocker

Seventeen distinct call sites remain explicitly unsupported by `Indirect_Call_Arguments`: `core/math/big/radix.odin:234`; `core/math/big/private.odin:2469,2478,2536,2554,2561,2581,2589,2731,2739,2789,2807,2814,2834,2845,2856`; `core/mem/allocators.odin:1745`. They omit default arguments on procedure-valued variables or fields. The allocator field's `Allocator_Proc` type does have a default `location = #caller_location` in `base/runtime/core.odin:425`. These sites do not require variadic or named arguments, although the eventual type metadata must support named arguments too.

Official probes establish that defaults come from the callee expression's static procedure type, not its runtime target. A function with `x := 1` assigned to `a: proc(x := 3) -> int` returns 3 from `a()`. A function with `x := 2` assigned to `b: proc(y := 4) -> int` returns 4 from `b()`, and named calls through such variables are accepted. The combined probe exits 34. Runtime `typeid` comparisons consider `proc(x := 1)` and `proc(x := 2)` equal, but `proc(x := 1)` and `proc(y := 1)` unequal; that combined probe exits 10. Assignment nevertheless accepts different parameter names. Inferred procedure variables retain the declaration's defaults.

The current canonical `types.Type` retains only parameter types, while `Procedure_Data` retains names and defaults for direct calls. Adding defaults to the existing type-identity key, or looking them up from the runtime target, would implement the wrong rule. Two candidate designs remain for a separate decision: include default metadata in `types.intern` keys so metadata-bearing IDs differ, then use a separate structural identity predicate that ignores defaults where required; or carry a separate static procedure signature on `Expression_Info`. Either design must preserve metadata through fields, results, assignments, and inferred variables, share it with `Procedure_Data`, distinguish parameter-name identity from assignment compatibility, and lower omitted defaults at the call site, including `#caller_location`. No indirect-call workaround was added.

## CS15 follow-up (2026-10-20)

The full-demo histogram fell from 159 to 153 after correcting deferred named-result assignments, then to 143 after stopping binary checking when the left operand is invalid. All six `Implicit_Selector_Type` failures used a poisoned contextual type; none identified a missing enum-selector rule. The latter change suppresses secondary diagnostics without accepting another program. Its negative regression remains rejected by the official compiler, which reports both the unknown name and the secondary implicit-selector error.

The next snapshot, after contextless variadic-call support and parallel range work, contains 139 diagnostics. Contextless slice variadics now reuse the existing packing and spread plans; their existing physical signature omits the context parameter. `src/driver/testdata/contextless_variadic` passes differentially with exit 45, covering packed arguments, zero arguments, a nonempty spread slice, and a nil spread slice. Procedure type checking now rejects `#c_vararg` under Odin and contextless conventions, including otherwise-unused declarations, rather than letting the new call support accept an invalid convention.

The six `Assign_Deferred_Result` sites were ordinary defer bodies, not deferred procedure attributes. The checker now matches the official `check_stmt.cpp` rule: reject a direct `=` assignment to a named result after unwrapping singular blocks, but allow assignments nested in control flow or multi-statement blocks. Direct multiple assignment remains rejected; compound assignment and assignment to a result's field or indexed element remain allowed. Existing lowering already evaluates returned values before deferred statements. Official probes cover direct, block-wrapped, conditional, loop, multiple, compound, field, indexed, and nested-procedure cases. `src/driver/testdata/defer_named_result_assignment` passes differentially with exit 38, checking caller-visible deferred writes and unchanged scalar, structure, and array return snapshots. Ginger Bill confirms the ordering in [Odin issue #489](https://github.com/odin-lang/Odin/issues/489); [#2505](https://github.com/odin-lang/Odin/issues/2505) describes the same named-result interaction.

### Synthetic intrinsics package required

Four `Undeclared_Type T` and four `Undeclared_Name N` diagnostics come from `base/intrinsics/intrinsics.odin:384-385`, not a missing polymorphic binding rule. That file is explicitly documentation-only and has `#+build ignore`; its illustrative declarations include malformed syntax. `src/driver/session.odin` currently loads it despite the build tag and ignores its parser errors, then derives builtin entities from the recovered declarations. The official compiler instead creates a synthetic intrinsics package and installs builtin entities and types directly in `checker.cpp`, including `create_builtin_package`, the builtin procedure table, and intrinsic type registration.

The driver must honour the build tag and stop ignoring parse errors. Before removing its special load path, synthetic package metadata must provide the existing builtin procedures and intrinsic types without reading the documentation file. Skipping the ignored file alone is not sufficient: it is currently the package's only file, so doing so would remove every intrinsic declaration. Reuse the existing builtin table and universe machinery rather than adding name-specific exceptions or treating documentation signatures as generic user procedures. No partial loader workaround was added.

All eight `Unsupported_Type_Expression Basic_Directive` sites are `#soa`: four in the demo, three in reflection, and one in the ignored intrinsic documentation file. They belong to the existing SoA and synthetic-package design work, not ordinary directive expression handling.

### C slice variadics and C varargs

Official probes accept slice variadics under Odin, contextless, and C calling conventions, including zero arguments, packed arguments, and spread slices; the same signatures are accepted in foreign declarations. `#c_vararg` is rejected under Odin and contextless conventions. Under C it accepts zero or packed arguments but rejects spreading a slice, including through a foreign declaration. The checker still explicitly rejects actual C-varargs calls.

The representation now separates `types.Type.variadic` from `c_vararg`, including type interning and ABI planning. Ordinary `proc "c" (args: ..int)` calls pass a slice by the normal C aggregate rules and reuse existing packing and spread plans; only `#c_vararg` marks a C-varargs physical signature. `src/driver/testdata/c_slice_variadic` passes differentially with exit 65, exercising integer and floating-point C-convention slice variadics called from Odin. The ABI-plan test also checks that the two procedure kinds intern separately and only the actual C-vararg plan is variadic. Actual C-varargs calls stay explicitly unsupported until their argument sequence and promotions are implemented and tested. The reference compiler separates `Proc.variadic` and `Proc.c_vararg`; its `check_type.cpp` also rejects `#c_vararg` for Odin and contextless conventions.

### Remaining local diagnostic families

The two demo `Undeclared_Type T` sites were inside local generic unions and disappeared with CS16's local type-resolution fix. The remaining demo `Undeclared_Name N` site is in the previously diagnosed nested-array polymorphic example. The four remaining T and four other N sites belong to synthetic intrinsics setup above.

The remaining `Invalid_Operand` sites are the ignored intrinsic documentation's recovered `soa_struct` expression and `abs(q)` on the demo's quaternion. The latter is a valid builtin operation, not an invalid Odin operand: an official check/build/run probe for `abs(3 + 4i + 0j + 0k)` exits 5. The reference LLVM backend calls the existing runtime `abs_complex*` and `abs_quaternion*` procedures. Reuse those procedures when adding runtime magnitude support, with the corresponding constant-expression rules, rather than approximating the magnitude with componentwise absolute values. No magnitude support was added in this batch.

The `swizzle` failures identify an unregistered universe builtin. The reference `check_builtin.cpp` accepts constant indices on arrays and SIMD vectors, requires at least two indices, imposes no array-output count limit, and applies SIMD power-of-two and lane limits. The existing selector `Swizzle_Plan` has four `u8` indices and cannot represent that contract. Reuse its lowering only after replacing that bounded representation with one that can represent the builtin's indices and output count; do not restrict the builtin to the demo's three-component vectors.

## CS16 follow-up (2026-10-20)

The full-demo histogram fell from 139 to 110 diagnostics. The four `Conversion Call_Expr Not_Assignable`, four `Unsupported Auto_Cast Expression_Kind`, four `Unsupported Basic_Directive Expression_Kind`, and four `Not_A_Type` diagnostics are gone. All four positive differential fixtures below have matching, nonzero official and odinc exits; their nearest negative tests are also confirmed rejected by the official compiler.

The four conversion sites were `len(p)` arguments in `core/c/libc/stdio.odin:293,308,312,327`. Tuple-expansion discovery no longer eagerly checks builtin and type-conversion calls, whose plans are not ordinary `Call_Plan` tuples. Parameter checking supplies the contextual int/uint type to the actual length builtin rather than converting a previously cached int result. A previously bound int variable still cannot become uint implicitly. `src/driver/testdata/length_call_arguments` passes with exit 66.

Local type declarations now use the same predeclaration and resolver path as package declarations. This exposes the existing generic-record registry instead of checking a local polymorphic structure as an ordinary, unbound type expression. Existing specialization, layout, union injection, and lowering are reused. `src/driver/testdata/local_generic_types` passes with exit 43, covering nested generic records, a constant array dimension, a where clause, and a generic union. A false local-record where clause remains rejected.

`auto_cast` uses the existing explicit-cast conversion plans. Without a contextual type it preserves its operand type; with one it applies ordinary cast rules, including constant representability checks. Binary context is not symmetric: the official compiler casts the right operand of equality using the left operand's type, while an auto-cast left operand is initially checked without that hint. Accepted mixed-type comparisons then use the reference backend's constant-versus-runtime and storage-size conversion rules. A retained binary conversion plan lowers these conversions without overwriting an operand's original checked row or evaluating it twice. `src/driver/testdata/auto_cast` passes with exit 138, covering truncation, parameters, returns, pointers, selectors, both operand positions, signed extension, floating-to-integer comparison, and a constant operand. The references are `check_expr.cpp`'s `AutoCast`, `check_binary_expr`, and `check_comparison`, plus `llvm_backend_expr.cpp`'s `lb_emit_comp`.

`#procedure` produces a constant untyped string, not a procedure value. Source names are recorded separately from generated symbol names; generic instances use the definition name, named local procedures retain their declaration name, and anonymous procedures use the official `(anonymous-procedure)` spelling. Existing string-constant lowering handles the result. `src/driver/testdata/procedure_directive` passes with exit 37, including a local constant initialized from the directive. Using it outside a procedure remains rejected. The source of truth is the official `check_expr.cpp` directive handler and `check_decl.cpp`'s procedure-name setup. No unknown directive was made valid.

### Remaining design families ranked by known demo sites

| Family | Demo sites | Imported sites | Recommended design |
| --- | ---: | ---: | --- |
| Matrix | 18 | 0 in this family | Preserve dimensions, element type, and row-major metadata in the existing matrix kind; implement layout, two-dimensional addressing, aggregate ABI, arithmetic, transpose, flattening, and the matrix intrinsics together. Twelve sites are type expressions, three are indexing, and three are other matrix expressions or intrinsics. |
| SoA | 7 | 4 additional type sites | Implement transformed SoA types and field-array layout, then indexing, slicing, zipping, unzipping, and append plans. Four demo sites are type expressions and three are operations. One imported type site is documentation that synthetic intrinsics setup should remove. |
| Quaternion | 3 | 0 counted here | Implement the runtime multiplication and division operations using the existing runtime formulas, plus magnitude through `abs_quaternion*`; preserve the language's constant-expression behavior. Two demo operators already pass checking but fail lowering; `abs(q)` still fails checking. |
| Indirect-call defaults | 0 | 17 calls | Preserve static procedure parameter names and defaults through variables, fields, results, and aliases; keep language type identity distinct from metadata identity where required. Apply defaults at the call site, never from the runtime target. The candidate designs and oracle evidence are recorded above. |
| Synthetic intrinsics | 0 | 11 diagnostics in documentation | Create intrinsic entities and types from compiler-owned builtin metadata. Then remove the special documentation-file load path, honour `#+build ignore`, and reject parser errors normally. Four T and four N reports plus the recovered `soa_struct` declaration account for the eleven diagnostics. |

These counts describe the five requested families, not every unsupported language feature. Swizzle remains the separate, four-report family described above; it needs an unbounded index/lvalue representation and the SIMD rules, not a four-lane registration shortcut.

CS16 passed formatting, checking, and tests for `check`, `lower`, `driver`, and `types` with 199, 57, 56, and 4 tests. Thirteen differential regressions pass, including all four new fixtures, the C and contextless slice-variadic fixtures, ordinary spread and returned calls, bit sets, generic arguments, pointer constants, using-pointer returns, and `hello_fmt`. The additional `multiple_assignment` regression cannot build with the official compiler because its main procedure has a custom calling convention; it was not changed. No diagnostic instrumentation remains.

## CS17 type-valued calls in type positions (2026-10-20)

Type-position calls now use the expression checker's existing intrinsic handlers and require a Type-mode result. Generic-record instantiation takes precedence only when the callee resolves to registered generic-record metadata. Ordinary value calls, calls returning runtime `typeid`, and boolean type predicates remain invalid types, with the official `is not a type` diagnostic represented by `Not_A_Type`. An already diagnosed expression returns poison without a duplicate type error. The design follows `refs/Odin-upstream/src/check_type.cpp:5394`, which checks a call as an expression or type and requires `Addressing_Type`; it does not maintain a spelling whitelist.

Official checks accepted all seventeen type-producing intrinsic forms: `type_base_type`, `type_core_type`, `type_elem_type`, `type_convert_variants_to_pointers`, `type_integer_to_unsigned`, `type_integer_to_signed`, `type_merge`, `type_field_type`, `type_union_tag_type`, `type_bit_set_elem_type`, `type_bit_set_underlying_type`, `type_variant_type_of`, `type_proc_parameter_type`, `type_proc_return_type`, `type_polymorphic_record_parameter_value` when its selected parameter is a type, `type_bit_set_backing_type`, and `soa_struct`. `type_key_type` and `type_value_type` are not intrinsic names in the official compiler. The reference is the official `src/check_builtin.cpp` and `checker_builtin_procs.hpp`, supplemented by [the intrinsic declarations](https://github.com/odin-lang/Odin/blob/master/base/intrinsics/intrinsics.odin), [the union-reflection PR](https://github.com/odin-lang/Odin/pull/2894), and [the package documentation](https://github.com/odin-lang/pkg.odin-lang.org/blob/master/intrinsics.odin). This change reuses the implemented base/core/element/field/bit-set-underlying handlers; it does not add the missing handlers or SoA support.

`src/driver/testdata/type_query_positions` passes differentially and computes 97 on successful validation. It covers the five reused query handlers, an intrinsic alias, globals, procedure parameters and results, record fields, arrays, slices, pointers, and a generic record containing an intrinsic result type. Existing aggregate and scalar lowering handles the resulting types without a new runtime operation. `src/driver/testdata/enumerated_array_slice`, previously parked at `/tmp/gs44/enumerated_array_slice`, also passes differentially through the unchanged `core:slice.enumerated_array` implementation. Its success result is 42 and its guarded failure result is 43, so the official exit is nonzero in either case. The existing checker test now verifies valid variable types and exactly three `Not_A_Type` diagnostics for boolean, ordinary value, and runtime-typeid call results.

Formatting, checking, and tests pass for `check`, `lower`, and `driver`, with 199, 57, and 56 tests. Six differential fixtures pass: both new fixtures and the four CS16 fixtures. The full-demo histogram remains 110 because the newly supported call appears in the separate imported-library repro rather than a previously counted demo site.

## Previous full-gate snapshot

The prior full validation snapshot recorded `mise run fmt --check` passing 466 Odin sources, `mise run check` passing 12 packages, and `mise run test` passing 309 tests. CS13 reran the fixture sweep, not those gates; CS14 passed formatting, checking, and tests for `check`, `lower`, and `driver` (191, 57, and 56 tests). Its twelve passing differential regressions include all five new supported fixtures, `hello_fmt`, `map_lookup`, `complex_ops`, and existing aggregate and wide-bit-set fixtures. The quaternion-product fixture fails explicitly at lowering as documented above; `composite_literals` still fails the official build because its main procedure has a custom calling convention.


## CS19 matrix M1 and partial M2 (2026-10-20)

Design and open-item probes are in `docs/design/matrix.md`. Implemented: the `matrix[R, C]E` type expression (`src/check/type_matrix.odin`, element count 1 to 64, element kinds integer, float and complex with any endianness, checked against official `check_matrix_type`), the `#row_major` and `#column_major` tags on matrix types (`src/syntax/parse_expr.odin`, `set_tag`, `Matrix_Type.tag`; a non-matrix operand reports `Expected_Type`), matrix types in expression position, constant-index `m[row, column]` reads and stores (`src/check/expr_matrix.odin`, `src/lower/lower_matrix.odin`), and positional matrix literals in logical row-major order, stored at their storage index (`src/check/expr_composite.odin`). Differential fixtures `matrix_layout` (sizes, alignments and offsets; official exit 42) and `matrix_literal_index` (official exit 42) pass.

Explicit unsupported or open items, each to be lowered later:

- Runtime (non-constant) matrix indices: `expression_matrix_index` reports `Matrix_Index_Runtime` (checker). Needs a two-axis bounds plan. Owner: M2 follow-up; touches `lower_bounds.odin`, which agent-158 owns.
- Keyed matrix literals (`matrix[2,2]f32{0 = 1}`): official accepts; this checker reports `Matrix_Named_Element`. Key semantics not probed.
- Single-index `m[k]` (row or column vector): unsupported. A single index parses as `Index_Expr`, which `expression_index` rejects for matrix bases as `Index_Base`. Element type is established by probe in docs/design/matrix.md section 8.
- Matrix operators (`+ - * == !=`, bitwise, scalar broadcast, matrix product, matrix with array): not implemented; the checker reports the existing binary-operator rejection. Required by M2 table in docs/design/matrix.md section 4. The typed-constant-left scalar multiply cell is excluded from fixtures (confirmed official bug, section 4.1; our broadcast verified by exit code).
- Type predicates `type_is_matrix`, `type_is_matrix_row_major`, `type_is_matrix_column_major`, `type_is_valid_matrix_elements`: builtin predicates are not implemented in this compiler (`expression_type_predicate` covers only `Type_Comparable`..`Type_Enumerated_Array`); unsupported in general, not matrix-specific.
- `conj` on complex matrices, `hadamard_product`, `outer_product`, `transpose`, `matrix_flatten`: not implemented (M6).
- Casts and `transmute` between matrices and arrays or other matrix shapes (M5).
- Matrix ABI for arguments and results (M4 gate, docs/design/matrix.md section 7).
- Matrix literals with an aggregate element other than a constant or a plain value are lowered through the same aggregate path as arrays; no fixture covers boxing or union elements inside matrices.
- Pre-existing, unrelated to matrix work: `check` test `main_of_the_main_package_cannot_have_a_custom_calling_convention` (src/check/termination_test.odin) fails in the shared tree at the time of this run; it belongs to the procedure-check work of agent-425.

## CS20 matrix keyed literals, single index, runtime indices (2026-10-20)

Implemented on top of CS19, all differentially passing with official exit 42: keyed matrix literals with logical row-major flat keys in `0..<R*C` (sparse keys zero-fill; out-of-range, duplicate and non-constant keys rejected with `Invalid_Operand`), single-index `m[k]` selecting the storage vector as an array (column of length R, or row of length C for `#row_major`), and runtime `m[i,j]` indices with a two-axis bounds check through `lower_check`, following the file bounds-check policy like array indexing. New fixtures `matrix_literal_keyed` and `matrix_index_vector` (constant and runtime indices, vector reads, stores through `m[1][0]` and `m[i, 0]`). Design probes recorded in `docs/design/matrix.md` section 8.1. The `Matrix_Index_Runtime`, `Matrix_Named_Element` and `Index_Base` explicit failures are gone; remaining matrix `lower_fail` sites are operators, casts and intrinsics. Gates at this boundary: `mise run fmt check`, `mise run check check`, `mise run build`, `test check` 203, `test lower` 57, `test driver` 56, diff-test PASS on `matrix_layout`, `matrix_literal_index`, `matrix_literal_keyed`, `matrix_index_vector`. Removed three root build artifacts (`matrix_layout`, `matrix_literal_index`, `matrix_index_vector`) produced by official `odin run -file` from the repo root; official runs now use `-out:/tmp/...`.

Still open, unchanged from CS19 except keyed literals, single index and runtime indices: matrix operators (checker dispatch approved for `expression_binary`, not yet implemented), square scalar init, type predicates, `conj`, `hadamard_product`, `outer_product`, `transpose`, `matrix_flatten`, casts and `transmute`, matrix ABI gate.

## CS20 matrix operators M3 and M4 (2026-10-20)

Implemented in the checker (`src/check/expr_matrix.odin`, dispatch from `expression_binary` in `src/check/expr_ops.odin`, unary in `expression_unary`, matrix-to-vector-array conversion in `src/check/conversion.odin`) and lowering (`src/lower/lower_matrix.odin`, dispatch from `lower_binary` in `src/lower/lower_operator.odin`, unary in `lower_expr.odin`). Rules mirror the official `check_binary_matrix`, `check_comparison` assignability, `convert_to_typed` scalar conversion and `lb_emit_arith_matrix` backend semantics, each verified by official probes in `/tmp/cs20/q` before implementation: element-wise `+ - & | ~ &~` on identical types (bitwise needs integers), `*` as product with dimension, flag and 64-element checks, comparisons by AND-reduction with scaled-identity scalar semantics (confirmed by the `{2,2,0,2} == 2` false probe and the backend `lb_emit_conv` source), untyped scalars converting to the matrix type on square matrices only, typed scalars broadcasting only for left `*` and comparing as scaled identity for `==`, matrix-vector products with type-hint adjustment, and explicit rejections (`/ % %% << >>`, ordering, `&& ||`, mismatched shapes, mixed row-major flags, rectangular scalars, matrix-array `==`). New differential fixtures `matrix_ops_int`, `matrix_ops_float` (integer, exact-float and complex64 products, vector products, scalar rules, unary minus) and `matrix_compare`, all with official exit 42; checker reject tests added to `src/check/binary_reject_test.odin`. Gates: `mise run fmt check`, `check check`, `build`, `test check` 206, `test lower` 57, `test driver` 56, full `diff-test` with only the two pre-existing environmental `official-build` failures (`user_collections` empty top directory, `when_unresolved` official rejection fixture), both unrelated to matrix work.

Reduction trees (2026-10-20 follow-up): per-element sums reproduce the official emission as scalar IR trees (pairwise with odd carry, shuffle reduction with zero-padded upper part, k-ascending otherwise), selected by the official simdable gate; verified by generated official IR (plain `fmul`/`fadd`, no `llvm.fma` with default features) and identical outputs across `-o:none`/`minimal`/`speed`/`aggressive`. Fixture `matrix_product_tree` locks each tree with distinguishing cancellation values, official exit 42. Known official bug, covered in-repo: the row-major non-square SIMD path indexes Y with the left stride (`llvm_backend_expr.cpp:1195` vs `y_stride` at `:1144`), giving lane-shifted values at `-o:none`, NaNs at default opts, and out-of-bounds lanes for integers; our lowering is layout-correct and verified by exit code on those shapes. Oracle-limited reproducers live in `src/driver/oracle_limits/` with source references and run green (exit 42) outside the differential harness, which does not scan that directory. Oracle limitation, not a behavioral difference: unary `~` on integer matrices is accepted by the official checker but official codegen crashes on it, so no differential fixture can cover it; ours lowers it as xor -1 per element and the values were verified by exit code outside the harness. Review fixes at this boundary: matrix dispatch moved after operand-value checks (type-mode operands keep the generic rejection, with a direct reject test), bitwise scalar operators require integer elements (float/complex `&` reject tests), named matrix types compare structurally per official acceptance (`M1 :: matrix[2,2]f32` against `M2` for `+`, `==` and cross-assignment all pass officially); assignment between distinct named matrix types in our checker goes through the general named-type conversion, which is a pre-existing gap shared with named arrays and out of matrix scope. Still open: square scalar initialization, matrix type predicates, `conj`, `hadamard_product`, `outer_product`, `transpose`, `matrix_flatten`, casts and `transmute` (M5), intrinsics (M6), `core:math/linalg` (M7), and the matrix ABI gate for arguments and results across procedure boundaries (M4 gate, section 7 of the design doc).

## CS20 matrix review fixes: single evaluation, lazy loads, f16 zero-minus (2026-10-20)

Final review found the unary lowering evaluated its operand twice (`lower_value` before the matrix dispatch, then `lower_array_base` inside the helper); the dispatch now precedes operand lowering. Official probes then fixed two wrong assumptions: binary element loads are lazy (both addresses resolve left to right, per-element loads follow, so a right call mutating the shared field is visible in the left sum: 110, not 11; our lowering already loads lazily and matches), and f16 matrix negation is zero-minus (`1 / (-h)[0,0]` is `+Inf`, unlike scalar f16 negation which flips the sign), so matrix negate keeps the existing widen/subtract/narrow helper rather than the sign-xor helper. Adjacent gaps fixed: f16 matrix zero crashed IR (`const_float` of `I16` in `lower_matrix_zero`, now `const_int`) and matrix globals with composite initializers stay unsupported (`lower Unsupported Global_Initializer`), so the fixture keeps matrices in locals. New differential fixture `matrix_side_effects` (pointer-root calls, no matrix ABI) locks single evaluation, left-to-right order, the lazy left read, and f16 sign behavior, official exit 42. Gates at this boundary: `mise run fmt check`, `build`, `test driver` 56, `diff-test` PASS on all nine matrix fixtures. Still open, unchanged: square scalar init, type predicates, `conj`/`hadamard_product`/`outer_product`/`transpose`/`matrix_flatten`, casts/`transmute` (M5), intrinsics (M6), `core:math/linalg` (M7), matrix ABI gate (M4).
## GS49 using statements (2026-10-20)

Using statements now check, lower, compile and run. Existing place paths preserve field aliasing, pointer rebinding and per-use selector evaluation. Official-confirmed coverage includes lexical shadowing, scope exit, collisions, imports, enum constants, embedded fields and rejected operands. `using_statement` and `demo_section_using_statement` pass differential testing; the former matches stdout `!!!!` and exit 255. Parsed feature-tag boundaries and collection policy propagation are fixed, duplicate promoted field names are rejected at struct declaration time, and nested pointer place paths dereference correctly. Committed as `5ae570e4`. The demo histogram falls from 96 to 92: two primary using-statement failures and two cascades removed. Using parameters remain a separate gap at this boundary. Gates passed: syntax 15, checker 211, lower 57, driver 56, plus fmt/check/build and hello_fmt/map_assign/map_range differential regressions. The recursive-using official-crash reproducer lives under `src/driver/oracle_limits/recursive_using` and is not counted as supported differential coverage.
Matrix open-item note (2026-10-20): `demo_section_matrix_type` (typed-scalar square init `b = f`) exits 41 officially and is still rejected at check; tracked under square scalar init, not full matrix support.

## GS50 using parameters (2026-10-20)

Using parameters now check, lower, compile and run through the existing Using_Binding, Operand and Place_Plan machinery. Bindings are introduced after all parameter and named-result declarations. Value-root aliases are read-only, including aliases promoted through pointer-valued embedded fields; reading the pointer field itself still permits mutation of its pointee. Pointer-root aliases remain writable. The original named parameter stays accessible and may be shadowed by a body local without rebinding the imported aliases. Immediate body declarations cannot redeclare imported aliases, while nested blocks may shadow them. Both statements and parameters require the parsed `using-stmt` opt-in. Blank, scalar and variadic roots, namespace collisions, value-alias assignment and taking the address of the original parameter are rejected as confirmed by official probes.

The `using_parameters` differential fixture computes 127 on successful validation and covers a register-passed value, a large indirect aggregate, a contextless pointer parameter, pointee mutation through a value-root embedded pointer, defaults, explicit arguments, shadowed roots, nested alias shadowing and ordinary parameter shadowing. No ABI or lowering changes were needed. Official references are `src/check_type.cpp` parameter flag handling and `src/check_decl.cpp` using-parameter binding, supplemented by the official demo and [issue #3401](https://github.com/odin-lang/Odin/issues/3401). Existing Odin code in `core/compress/zlib/zlib.odin` uses the same opt-in and pointer-parameter form.

The demo histogram falls from 92 to 91 by resolving `position` at `examples/demo/demo.odin:810`. Formatting and checks pass for the touched packages; checker, lower and driver tests pass with 212, 57 and 56 tests. Differential regressions pass for `using_parameters`, `using_statement`, `demo_section_using_statement`, `hello_fmt`, `map_assign` and `map_range`.
## CS20 scalar initialization and matrix globals (2026-10-20)

Square scalar initialization is implemented end to end: a scalar of the element type (typed) or one converting to it (untyped, representability-checked) assigns to a square matrix as a scaled identity, in declarations, plain, pointer-deref and field assignments, and file-scope globals. Constants fold to a diagonal aggregate at check time; runtime values lower once with diagonal stores and zero elsewhere. Rectangular and mismatched-element forms are rejected at check. Matrix globals with composite initializers work through a new `.Matrix` arm in the existing aggregate image (physical order, recursion for struct-nested matrices, zero-init path verified). New differential fixture `matrix_scalar_init` (official exit 42) covers typed/untyped constants and runtime values, negative/zero/complex/f16, pointer/field destinations and a scalar-init global; four reject neighbors live in `src/check/binary_reject_test.odin`. `demo_section_matrix_type` now passes differentially (official exit 41). Gates: `mise run fmt`, `check check`, `check lower`, `build`, `test check` 216, `test lower` 57, `test syntax` 15, `test types` 4, `test driver` 56, `diff-test` PASS on all ten matrix fixtures plus `demo_section_matrix_type`, using, hello_fmt and map regressions. Still open: type predicates, `conj`/`hadamard_product`/`outer_product`/`transpose`/`matrix_flatten`, casts/`transmute` (M5), intrinsics (M6), `core:math/linalg` (M7), matrix ABI gate. No full matrix support is claimed.
## CS20 matrix intrinsics: hadamard_product, matrix_flatten, outer_product (2026-10-21)

The demo-called matrix intrinsics are implemented end to end. `hadamard_product` takes identical matrix or array pairs (structural match, valid elements) and lowers as elementwise `*`, reusing the operator elementwise path for matrices and a flat loop for arrays. `matrix_flatten` gives the physical storage order as an independent array copy. `outer_product` takes two non-empty arrays with identical valid elements and length product at most 64, filling `result[i,j]` with `left[i]*right[j]`. Constants are not folded (official returns values). New checker `src/check/builtin_matrix.odin` with dispatch in `src/check/builtins.odin`, lowering cases in `src/lower/lower_intrinsic.odin` with helpers in `src/lower/lower_matrix.odin`. New differential fixture `src/driver/testdata/matrix_intrinsics` (official exit 42) covers int/float/named matrix and array pairs, column-major and row-major physical flatten, outer values, single evaluation, left-to-right order with lazy right-mutation visibility, and pointer-root alias operands; six reject neighbors live in `src/check/binary_reject_test.odin`. Official probes: `q_k1`-`k3` accept values, `q_k4`-`k11` reject messages, `q_k12`/`q_k14` named-type and laziness shapes. The initial array-element and two-index matrix store gap reports were incorrect. Decimal constant conversion sources caused the failure; the focused numeric assignment fix below covers those stores. Demo histogram falls from 90 to 88 (stable across reruns, identical on the repo and fork demo inputs which differ only cosmetically); the top-20 printed groups are unchanged, so the two resolved call-site entries came from the unprinted tail. Gates: `mise run fmt`, `check check`, `check lower`, `build`, `test check` 222, `test lower` 57, `test syntax` 15, `test types` 4, `test driver` 56, `diff-test` PASS on all 11 matrix fixtures plus `demo_section_matrix_type`, using, hello_fmt and map regressions. Still open: `transpose`, `conj`, casts/transmute (M5), `core:math/linalg` (M7), matrix ABI gate. No full matrix support is claimed.
Review follow-up: type-mode operands are rejected at check (`expression_value` gate, official "'X' is not an expression but a type"); the fixture additionally locks nested/bool-array flatten and result independence via single-index source mutation. The array/multi-pointer element and two-index stores noted earlier verify correctly; decimal and integer-to-float constant stores failed when lowering used the original conversion source and are fixed by repointing every successfully folded numeric Const_Id source to its target-typed constant, with f32 flattened-result mutation now locked in the fixture.

Numeric assignment review: `src/check/conversion.odin` preserves `Expression_Ref` identity, as required by `conversion_test.odin`, but uses the folded target constant for every numeric `Const_Id` source, regardless of its original pooled type. `lower_conversion` derives the source type from that operand; an already target-typed constant needs no runtime numeric conversion. The focused fixture covers f32/f64 scalar, array, matrix and multi-pointer decimal stores and integer-to-float element stores. Typed integer constants still require an explicit float cast; overflow and fractional-to-integer rejects remain unchanged. References: `refs/Odin-upstream/src/check_expr.cpp` representability conversion through `exact_value_to_float`, and upstream issue https://github.com/odin-lang/Odin/issues/4975. This reuses the existing numeric fold rather than adding a lowering exception.

Numeric assignment gates: `mise run fmt src/check`, `fmt src/driver/testdata/numeric_constant_assignment`, `check check`, `check lower`, `check driver`, `test check` (224), `test lower` (57), `test driver` (56), and `build` passed. Differential runs passed for `numeric_constant_assignment`, `matrix_intrinsics`, `hello_fmt`, `map_assign`, `map_insert`, `map_lookup`, and `map_range`. `mise run histogram` reports total 88. The histogram task was reviewed without edits; its Bash input handling and shared collection argument match the existing task conventions.

## GS51 named procedure types (2026-10-21)

Named procedure type declarations now publish the existing nominal `.Named` descriptor around the structural procedure signature. Distinct declarations retain separate identity; aliases retain their target identity; `#type proc` remains an anonymous procedure signature. Existing RTTI lowering emits `Type_Info_Named` and links its base to the procedure descriptor. `src/driver/testdata/procedure_named_identity` passes differentially with exit 0, covering the six type-identity/RTTI flags, anonymous-to-named, named-to-distinct-named, named-to-anonymous, an explicit compatible cast, nil assignment, a direct fixed-arity call, and an `any` assertion. A checker conversion test rejects a mismatched signature and confirms the compatibility does not recurse through slice element types.

Assignment compatibility follows the official `src/check_expr.cpp` procedure-type branch (`is_type_proc`, `are_proc_properties_identical`, and `check_proc_params_assignable`, around lines 1393–1411 and 1527) and `src/types.cpp:3360–3365`: procedure properties and parameter/result types must match, but nominal wrappers are not equality. The conversion is limited to top-level procedure values; it does not globally flatten named types. The official fixture confirms anonymous-to-named, named-to-named, named-to-anonymous, alias assignment, and compatible explicit casts. Official negative probes reject mismatched procedure signatures and assignment from `[]proc(int)->int` to `[]Callback`; the checker test covers both the mismatched signature and the container boundary. Parameter names and defaults are not part of the current `types.Type` signature representation; calls in the fixture pass arguments explicitly, and named procedure default-argument behavior remains unimplemented and unclaimed.

## GS51 static procedure arguments (2026-10-21)

An indirect call now binds its arguments to the parameters of the callee expression's *static* procedure type, and the omitted parameters take their defaults from that same static signature. The runtime target is never consulted for a default. The metadata travels with the type: a procedure type carries a `types.Procedure_Info_Id`, and the checker keeps the parameter defaults and flags in an arena-allocated `Procedure_Info` keyed by the signature's origin (file, node, scope, view). One evaluator serves the direct and indirect paths: `expression_default_argument` builds the default, `call_bind_arguments` assigns arguments to parameters, and the direct-call materialization of `#caller_location` and `#caller_expression` is reused unchanged.

The static signature survives reassignment because it belongs to the destination's declared type, not to the value it holds. A variable of type `proc(x := 3) -> int` keeps default 3 even when it is later assigned a procedure whose own default is 1; a field, a formal parameter, a result, and an array element behave the same way. Defaults reach a call through a variable, a field, a formal parameter, a returned procedure, and an array element.

Type identity is now three-layered, matching the official `are_types_identical` and `are_types_identical_unique_tuples` split (`refs/Odin-upstream/src/types.cpp:3350–3366` and `name_canonicalization.cpp:77–89`):

- Ordinary identity ignores parameter and result names and defaults. It is used for assignment compatibility, union membership and tag mapping, and binary comparison of two type values.
- Unique-tuple identity compares parameter and result names, and still ignores defaults. It is used for the generic instance caches, the RTTI entry deduplication, and the type switch's seen-set and exhaustiveness check.
- Nominal named procedure types stay distinct from their underlying signature under both rules.

Union membership uses ordinary identity but keeps the declared variant index, so `proc(value: int) -> int` matches the union's `proc(value: int) -> int` variant while `proc(different: int) -> int` does not. The tag the runtime writes is the declared variant's index, not the index of the matched spelling.

`#caller_location` and `#caller_expression` come from the outer indirect call site, not from the declaration of the default. Supplied arguments keep their evaluation order, and the callee expression is evaluated once.

The procedure parameter and result RTTI now writes a real `Type_Info` entry whose variant is `Type_Info_Parameters`, instead of a raw `Type_Info_Parameters` payload at a `^runtime.Type_Info` field. Reflection of parameter and result names and types is therefore valid; the synthetic runtime schema in `src/lower/lower_type_info_test.odin` gained the `Type_Info_Parameters` union member to match.

Three differential fixtures cover the feature and all pass with the official compiler's exit code 0:

- `src/driver/testdata/procedure_static_defaults`: defaults from the static signature through a variable, a field, a formal parameter, a returned procedure and an array element; the destination signature surviving reassignment; a named argument through an indirect call; supplied-argument evaluation order; single evaluation of the callee.
- `src/driver/testdata/procedure_static_identity`: ordinary identity ignoring names and defaults; unique-tuple identity separating different parameter names; the generic record instance cache; union membership and tag mapping; the type switch's seen-set; `any` assertion and switch; and the parameter and result `Type_Info_Parameters` names and types.
- `src/driver/testdata/procedure_static_callers`: `#caller_location` and `#caller_expression` at the outer indirect call site, through a variable, a field and a returned procedure.

The checker test `static_procedure_calls_reject_invalid_arguments` covers the nearest invalid neighbours: an indirect call with no default, an indirect call with an unknown named parameter, an assertion to a distinct nominal procedure type, and a type switch over a union whose procedure variant has different parameter names.

Gates at this boundary: `mise run check` for every package, `mise run test check` (228 tests; the only failure is the peer-owned `bit_field_types_pack_fields_and_report_invalid_declarations` expectation), `mise run test lower` (57), `mise run test types` (7), `mise run test driver` (56), `mise run build`, `mise run diff-test` PASS on the three new fixtures and on the hello, map, using, matrix and named-procedure regressions, and `mise run histogram` reports 69. The full demo still fails at the check phase; its remaining diagnostics are in the matrix, swizzle, SoA, quaternion, composite-literal and generic-pattern families, not in indirect-call defaults.
