# Burn-down

## Baseline (2026-10-20)

Commands run from the repository root with `mise run <task>`.

### `mise run fmt --check`

- Files checked: 466 Odin sources under `src/`.
- Passed: 466. Failed: 0.
- Result: pass. No unformatted files reported.

### `mise run check`

- Packages checked: amd64, check, driver, elf, ir, link, lower, odinc, regalloc, sched, syntax, types (12).
- Passed: 12. Failed: 0.
- Result: pass. No compiler diagnostics were emitted.

### `mise run test`

| package | tests |
| --- | --- |
| amd64 | 12 |
| check | 146 |
| driver | 45 |
| elf | 4 |
| ir | 18 |
| link | 6 |
| lower | 55 |
| regalloc | 4 |
| sched | 2 |
| syntax | 13 |
| types | 4 |

- Tests run: 309. Passed: 309. Failed: 0.
- Result: pass. Every package reported "All tests were successful."

No failures to record.

## Burn-down

| feature | fixture path | failing phase | date |
| --- | --- | --- | --- |
| bit_set_type | src/driver/testdata/demo_section_bit_set_type | odinc-check: base/runtime/core_builtin.odin:1658:44: Undeclared_Type | 2026-10-20 |
| constant_literal_expressions | src/driver/testdata/demo_section_constant_literal_expressions | odinc-lower: src/driver/testdata/demo_section_constant_literal_expressions/main.odin:40:10: lower Unsupported Place | 2026-10-20 |
| cstring_example | src/driver/testdata/demo_section_cstring_example | odinc-check: src/driver/testdata/demo_section_cstring_example/main.odin:8:7: Conversion | 2026-10-20 |
| matrix_type | src/driver/testdata/demo_section_matrix_type | odinc-check: src/driver/testdata/demo_section_matrix_type/main.odin:6:5: Unsupported_Type_Expression | 2026-10-20 |
| or_break_and_or_continue_operators | src/driver/testdata/demo_section_or_break_and_or_continue_operators | odinc-check: src/driver/testdata/demo_section_or_break_and_or_continue_operators/main.odin:45:11: Unsupported | 2026-10-20 |
| or_else_operator | src/driver/testdata/demo_section_or_else_operator | odinc-check: src/driver/testdata/demo_section_or_else_operator/main.odin:12:6: Unsupported | 2026-10-20 |
| or_return_operator | src/driver/testdata/demo_section_or_return_operator | odinc-lower: src/driver/testdata/demo_section_or_return_operator/main.odin:36:2: lower Unsupported Local | 2026-10-20 |
| partial_switch | src/driver/testdata/demo_section_partial_switch | PASS | 2026-10-20 |
| ranged_fields_for_array_compound_literals | src/driver/testdata/demo_section_ranged_fields_for_array_compound_literals | PASS | 2026-10-20 |
| soa_struct_layout | src/driver/testdata/demo_section_soa_struct_layout | odinc-check: src/driver/testdata/demo_section_soa_struct_layout/main.odin:12:5: Unsupported_Type_Expression | 2026-10-20 |
| using_statement | src/driver/testdata/demo_section_using_statement | odinc-check: src/driver/testdata/demo_section_using_statement/main.odin:15:2: Unsupported | 2026-10-20 |
| where_clauses | src/driver/testdata/demo_section_where_clauses | odinc-check: src/driver/testdata/demo_section_where_clauses/main.odin:6:2: Undeclared_Name | 2026-10-20 |
| hello_fmt | src/driver/testdata/hello_fmt | odinc-check: src/driver/core/strings/builder.odin:444:2: Unsupported | 2026-10-20 |
