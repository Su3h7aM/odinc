// Checked-program lowering. The program and its sources are borrowed for lower_program.
// References: docs/archive/05-lower-design.md sections 4, 5 and 17; the fork's lb_generate_code
// and lb_generate_procedure; PR 7850's procedure jobs. Reuses core:thread.Pool and
// ir's builder and blob merge. ABI signatures and layouts are settled serially before the
// workers start, so workers only read the type store. Each worker writes its own function and
// its extern names, which lower_program merges into the module in job order.
package lower
