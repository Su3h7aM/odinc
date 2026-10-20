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

- `#soa` array, slice, and dynamic-array types remain unsupported at type checking (2026-10-20; `src/driver/testdata/demo_section_soa_struct_layout`, `Unsupported_Type_Expression`). The demo's 20 `Undeclared_Name v_soa` diagnostics cascade from rejected `#soa[N]Vector3` declarations, not range-variable scoping. The official fixture checks, builds, and exits 19.
- `m[k] = v` and `m[k] += 1` compile but misbehave at runtime; the `map_assign` fixture is parked while the call path is investigated.
- Map iteration with `for k, v in m` fails checking with `Unsupported Range_Type`.
- `cap(map)` is unsupported.
- Union and `any` fields from constants in composite literals fail with `Unsupported Constant`.
- Quaternion multiplication and division are unsupported.
- SIMD operations on `f16` are unsupported.
- Untyped complex `:=` fails with `Mismatched_Types`.

## CS14 follow-up (2026-10-20)

The full-demo histogram fell from 280 to 251 diagnostics. Its 23 `Composite_Implicit_Type` diagnostics were 23 distinct imported-core source sites, not duplicate reports or demo-source literals: `core/math/big/internal.odin:1946`; `core/os/file_util.odin:253,274`; `core/os/file_linux.odin:325`; `core/os/pipe_linux.odin:52,55`; `core/os/process_linux.odin:176,213,253,863`; `core/os/temp_file.odin:29`; `core/io/conv.odin:32,37,42,47,52,57,63,68,73,78`; `core/sys/linux/sys.odin:2261`; `core/sys/posix/sys_mman_linux.odin:210`. All were bit-set literals in binary expressions. The histogram checks every declaration in every loaded package; a normal build checks reachable declarations and previously reported only the big-integer site.

Binary implicit literals now receive the other operand's contextual type, including parenthesized literals and literals on the left. Scalar and 128-bit bit-set operations use union, difference, intersection, symmetric difference, and subset/superset semantics; runtime literal elements lower to bit masks. Constant bit-set `+` and `-` fold as union and difference. `Composite_Implicit_Type` fell from 23 to 0 and `Composite_Bit_Set_Runtime` from 5 to 0. The new differential fixture `src/driver/testdata/bit_set_binary_literals` passes with official-confirmed exit code 73. It was added after the 142-fixture sweep above. No checker-only feature was added.

The references were the fork and reference compiler's `check_expr.cpp` (`check_binary_expr`, `check_compound_literal`) and `llvm_backend_expr.cpp` (`Type_BitSet` literal emission), existing aggregate and wide-bit-set lowering, and upstream issues [#2859](https://github.com/odin-lang/Odin/issues/2859) and [#5082](https://github.com/odin-lang/Odin/issues/5082). Official check/build probes are authoritative for this change: `+`, `-`, `&`, `&~`, `|`, binary `~`, equality and all four ordered comparisons accept contextual bit-set literals. Membership still requires a typed right-hand set: `E.A in {.A, .B}` is rejected with `Missing type in compound literal`.

## Previous full-gate snapshot

The prior full validation snapshot recorded `mise run fmt --check` passing 466 Odin sources, `mise run check` passing 12 packages, and `mise run test` passing 309 tests. CS13 reran the fixture sweep, not those gates; CS14 passed formatting, checking, and tests for `check`, `lower`, and `driver` (186, 57, and 56 tests).

