package check

import "core:fmt"
import "core:mem"
import "oc:syntax"

@(private = "package")
expression_procedure_where :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	clauses: syntax.Node_Range,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	for clause in syntax.node_list(file.ast, clauses) {
		info := check_expression(checker, view, scope, clause) or_return
		if info.state == .Invalid { return false, nil }
		value, boolean := false, false
		if info.mode == .Constant && info.constant != 0 {
			value, boolean = constant_pool_get(checker.constants, info.constant).value.(bool)
		}
		if !boolean {
			expression_failure(checker, view, scope, clause, .Expected_Boolean_Constant, "'where' clauses expect a constant boolean evaluation") or_return
			return false, nil
		}
		if !value {
			reason := fmt.aprintf(
				"'where' clause evaluated to false:\n\t%s",
				expression_text(file, clause),
				allocator = mem.dynamic_arena_allocator(&checker.arena),
			)
			expression_failure(checker, view, scope, clause, .Invalid_Operand, reason) or_return
			return false, nil
		}
	}
	return true, nil
}
