package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Each case value is tested in turn and jumps to its clause body; the clauses fall through to the end, not to each other.
@(private)
lower_switch :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.Switch_Stmt) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, statement.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	tag: ir.Node_Id
	wide_tag := false
	union_type := types.TYPE_NONE
	tag_signed := false
	string_switch, is_string_switch := lower_string_switch_plan(state, node)
	if statement.cond != 0 {
		tag_info := lower_info(state, statement.cond)
		tag = lower_value(state, statement.cond)
		if state.failed || state.job.function.error != nil { return }
		tag_signed = signed_type(state, tag_info.type)
		if is_string_switch {
			bind_local(state, string_switch.tag, tag, true)
			if state.failed || state.job.function.error != nil { return }
		} else if is_wide_integer(state, tag_info.type) {
			wide_tag = true
		} else if lower_union_type(state, statement.cond) != types.TYPE_NONE {
			union_type = lower_union_type(state, statement.cond)
		} else if scalar_type(state, tag_info.type) == .None {
			lower_fail(state, node, .Switch)
			return
		}
	}
	clauses := syntax.node_list(state.ast, state.ast.nodes[statement.body].payload.(syntax.Block_Stmt).stmts)
	allocator := virtual.arena_allocator(&state.job.function.arena)
	bodies, bodies_error := make([]ir.Jump_Target_Id, len(clauses), allocator)
	if bodies_error != nil { state.job.function.error = bodies_error; return }
	end := ir.jump_target_make(state.builder)
	if !push_control_target(state, {node = {state.job.procedure.body.file, node}, break_target = end}) { return }
	defer pop(&state.control_targets)
	default_body := -1
	comparison := 0
	for clause, index in clauses {
		bodies[index] = ir.jump_target_make(state.builder)
		case_clause := state.ast.nodes[clause].payload.(syntax.Case_Clause)
		values := syntax.node_list(state.ast, case_clause.list)
		if len(values) == 0 { default_body = index }
		for value_node in values {
			condition: ir.Node_Id
			range_case := false
			if is_string_switch {
				if comparison >= len(string_switch.comparisons) { lower_fail(state, node, .Switch); return }
				condition = lower_string_case(state, value_node, string_switch.comparisons[comparison])
				comparison += 1
			} else if tag != 0 && is_range_case(state, value_node) {
				range_case = true
				condition = lower_switch_range(state, state.ast.nodes[value_node].payload.(syntax.Binary_Expr), tag, wide_tag, tag_signed)
			} else if union_type != types.TYPE_NONE {
				condition = lower_union_case_condition(state, node, union_type, tag, value_node)
			} else {
				condition = lower_value(state, value_node)
			}
			if state.failed || state.job.function.error != nil { return }
			if !range_case && wide_tag {
				condition = wide_equal(state.job.function, wide_load(state, tag), wide_load(state, condition))
			} else if !range_case && tag != 0 && !is_string_switch && union_type == types.TYPE_NONE {
				tag_type := state.job.function.nodes.type[tag]
				kind := ir.Node_Kind.FEq if tag_type == .F32 || tag_type == .F64 else ir.Node_Kind.Eq
				condition = ir.compare(state.job.function, kind, tag, condition)
			}
			branch := ir.branch_if(state.builder, condition)
			ir.enter_arm(state.builder, branch, 0)
			ir.jump_to(state.builder, bodies[index])
			ir.enter_arm(state.builder, branch, 1)
		}
	}
	if default_body >= 0 {
		ir.jump_to(state.builder, bodies[default_body])
	} else {
		ir.jump_to(state.builder, end)
	}
	for clause, index in clauses {
		if !ir.seal_target(state.builder, bodies[index]) { continue }
		body_scope := local_scope(state)
		case_clause := state.ast.nodes[clause].payload.(syntax.Case_Clause)
		case_statements := syntax.node_list(state.ast, case_clause.body)
		for statement_node in case_statements {
			if state.ast.nodes[statement_node].kind == .Branch_Stmt &&
			   syntax.node_payload(state.ast, statement_node, syntax.Branch_Stmt).token.kind == .Fallthrough { continue }
			lower_statement(state, statement_node)
		}
		leave_local_scope(state, body_scope)
		if state.failed || state.job.function.error != nil { return }
		next := end
		if len(case_statements) > 0 && state.ast.nodes[case_statements[len(case_statements) - 1]].kind == .Branch_Stmt {
			last_statement := case_statements[len(case_statements) - 1]
			info, info_ok := check.expression_info(state.job.program, state.view, last_statement)
			if info_ok && info.plan != 0 {
				plan := check.plan(state.job.program, info.plan)
				if exit, ok := plan^.(check.Exit_Plan); ok && exit.kind == check.Exit_Kind.Fallthrough && index + 1 < len(bodies) {
					next = bodies[index + 1]
				}
			}
		}
		ir.jump_to(state.builder, next)
	}
	ir.seal_target(state.builder, end)
}

@(private)
is_range_case :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> bool {
	binary, ok := state.ast.nodes[node].payload.(syntax.Binary_Expr)
	return ok && (binary.op.kind == .Range_Full || binary.op.kind == .Range_Half)
}

// `low..=high` and `low..<high` test the tag between the bounds; the upper bound is excluded for `..<`.
@(private)
lower_switch_range :: proc(state: ^Procedure_State, range: syntax.Binary_Expr, tag: ir.Node_Id, wide_tag, signed: bool) -> ir.Node_Id {
	function := state.job.function
	low := lower_value(state, range.left)
	if state.failed { return 0 }
	high := lower_value(state, range.right)
	if state.failed { return 0 }
	inclusive := range.op.kind == .Range_Full
	if wide_tag {
		value := wide_load(state, tag)
		low_words := wide_load(state, low)
		high_words := wide_load(state, high)
		at_least_low := bool_not(function, wide_less(function, value, low_words, signed))
		below_high := wide_less(function, value, high_words, signed)
		if inclusive { below_high = bool_not(function, wide_less(function, high_words, value, signed)) }
		return ir.binary(function, .And, at_least_low, below_high)
	}
	floating := function.nodes.type[tag] == .F32 || function.nodes.type[tag] == .F64
	less_kind := ir.Node_Kind.FLt if floating else (ir.Node_Kind.SLt if signed else ir.Node_Kind.ULt)
	less_equal_kind := ir.Node_Kind.FLe if floating else (ir.Node_Kind.SLe if signed else ir.Node_Kind.ULe)
	at_least_low := ir.compare(function, less_equal_kind, low, tag)
	below_high := ir.compare(function, less_equal_kind if inclusive else less_kind, tag, high)
	return ir.binary(function, .And, at_least_low, below_high)
}
