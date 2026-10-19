// Checked-program lowering. The program and its sources are borrowed for lower_program.
// References: docs/archive/05-lower-design.md sections 4, 5 and 17; the fork's lb_generate_code
// and lb_generate_procedure; PR 7850's procedure jobs. Reuses core:thread.Pool and
// ir's builder and blob merge. ABI planning stays serial because types.plan_abi
// updates the type store's layout state. Workers only write their own function.
package lower
