package analysis

import "base:runtime"
import "oc:check"
import "oc:syntax"

Procedure_Id :: distinct u32
Event_Id :: distinct u32

Index_Range :: struct {
	first, count: u32,
}

Procedure :: struct {
	checked_index: u32,
	events:        Index_Range,
}

Event_Kind :: enum u8 {
	Expression,
	Block,
	Conditional,
	Loop,
	Defer,
	Declaration,
	Assignment,
	Call,
	Return,
	Branch,
}

// Events form a preorder source tree, not a lowered execution stream. Plans retain evaluation and exit semantics.
Event :: struct {
	kind:       Event_Kind,
	procedure:  Procedure_Id,
	parent:     Event_Id,
	expression: check.Expression_Ref,
	plan:       check.Plan_Id,
}

@(private = "package")
Run :: struct {
	program:         ^check.Checked_Program,
	allocator:       runtime.Allocator,
	procedures:      [dynamic]Procedure,
	events:          [dynamic]Event,
	diagnostics:     [dynamic]Diagnostic,
	excluded_locals: []bool,
	procedure:       Procedure_Id,
}

@(private = "package")
inventory :: proc(run: ^Run) -> runtime.Allocator_Error {
	append(&run.procedures, Procedure{}) or_return
	append(&run.events, Event{}) or_return
	run.excluded_locals = make([]bool, len(run.program.entities), run.allocator) or_return
	for procedure, index in run.program.procedure_list {
		if procedure.body.node == 0 { continue }
		file := &run.program.files[procedure.body.file]
		if file.ast.nodes[procedure.body.node].kind != .Block_Stmt { continue }
		run.procedure = Procedure_Id(len(run.procedures))
		first := u32(len(run.events))
		append(&run.procedures, Procedure{checked_index = u32(index)}) or_return
		inventory_node(run, procedure.body.node, 0) or_return
		run.procedures[run.procedure].events = {first, u32(len(run.events)) - first}
	}
	return nil
}

@(private = "file")
inventory_list :: proc(run: ^Run, nodes: syntax.Node_Range, parent: Event_Id) -> runtime.Allocator_Error {
	procedure := run.program.procedure_list[run.procedures[run.procedure].checked_index]
	for node in syntax.node_list(run.program.files[procedure.body.file].ast, nodes) {
		inventory_node(run, node, parent) or_return
	}
	return nil
}

@(private = "file")
exclude_range_variable :: proc(run: ^Run, node: syntax.Node_Index) {
	node := node
	if node == 0 { return }
	procedure := run.program.procedure_list[run.procedures[run.procedure].checked_index]
	ast := run.program.files[procedure.body.file].ast
	if ast.nodes[node].kind == .Unary_Expr { node = syntax.node_payload(ast, node, syntax.Unary_Expr).expr }
	info := check.expression_info(run.program, procedure.view, node)
	if info.entity != 0 { run.excluded_locals[info.entity] = true }
}

@(private = "file")
inventory_node :: proc(run: ^Run, node: syntax.Node_Index, parent: Event_Id) -> runtime.Allocator_Error {
	if node == 0 { return nil }
	procedure := run.program.procedure_list[run.procedures[run.procedure].checked_index]
	ast := run.program.files[procedure.body.file].ast
	info := check.expression_info(run.program, procedure.view, node)
	if info.state == .Inactive || info.state == .Invalid { return nil }
	kind := Event_Kind.Expression
	#partial switch ast.nodes[node].kind {
	case .Block_Stmt:
		kind = .Block
	case .If_Stmt, .When_Stmt, .Switch_Stmt, .Type_Switch_Stmt, .Case_Clause:
		kind = .Conditional
	case .For_Stmt, .Range_Stmt, .Unroll_Range_Stmt:
		kind = .Loop
	case .Defer_Stmt:
		kind = .Defer
	case .Value_Decl:
		kind = .Declaration
	case .Assign_Stmt:
		kind = .Assignment
	case .Call_Expr, .Selector_Call_Expr:
		kind = .Call
	case .Return_Stmt:
		kind = .Return
	case .Branch_Stmt, .Or_Branch_Expr, .Or_Return_Expr:
		kind = .Branch
	}
	event := Event_Id(len(run.events))
	append(&run.events, Event{kind, run.procedure, parent, {procedure.view, node}, info.plan}) or_return
	#partial switch payload in ast.nodes[node].payload {
	case syntax.Block_Stmt:
		inventory_list(run, payload.stmts, event) or_return
	case syntax.Expr_Stmt:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Tag_Stmt:
		inventory_node(run, payload.stmt, event) or_return
	case syntax.Return_Stmt:
		inventory_list(run, payload.results, event) or_return
	case syntax.Assign_Stmt:
		inventory_list(run, payload.lhs, event) or_return
		inventory_list(run, payload.rhs, event) or_return
	case syntax.Value_Decl:
		inventory_list(run, payload.values, event) or_return
	case syntax.If_Stmt:
		inventory_node(run, payload.init, event) or_return
		inventory_node(run, payload.cond, event) or_return
		inventory_node(run, payload.body, event) or_return
		inventory_node(run, payload.else_stmt, event) or_return
	case syntax.When_Stmt:
		condition := check.expression_info(run.program, procedure.view, payload.cond)
		constant := check.constant(run.program, condition.constant)
		if constant != nil {
			if value, ok := constant.value.(bool); ok {
				inventory_node(run, payload.body if value else payload.else_stmt, event) or_return
			}
		}
	case syntax.Defer_Stmt:
		inventory_node(run, payload.stmt, event) or_return
	case syntax.For_Stmt:
		inventory_node(run, payload.init, event) or_return
		inventory_node(run, payload.cond, event) or_return
		inventory_node(run, payload.post, event) or_return
		inventory_node(run, payload.body, event) or_return
	case syntax.Range_Stmt:
		for variable in syntax.node_list(ast, payload.vals) { exclude_range_variable(run, variable) }
		inventory_node(run, payload.init, event) or_return
		inventory_node(run, payload.expr, event) or_return
		inventory_node(run, payload.body, event) or_return
	case syntax.Unroll_Range_Stmt:
		exclude_range_variable(run, payload.val0)
		exclude_range_variable(run, payload.val1)
		inventory_node(run, payload.expr, event) or_return
		inventory_node(run, payload.body, event) or_return
	case syntax.Switch_Stmt:
		inventory_node(run, payload.init, event) or_return
		inventory_node(run, payload.cond, event) or_return
		inventory_node(run, payload.body, event) or_return
	case syntax.Type_Switch_Stmt:
		if plan := check.plan(run.program, info.plan); plan != nil {
			if switch_plan, ok := plan^.(check.Type_Switch_Plan); ok {
				for clause in switch_plan.clauses {
					if clause.entity != 0 { run.excluded_locals[clause.entity] = true }
				}
			}
		}
		inventory_node(run, payload.expr, event) or_return
		inventory_node(run, payload.body, event) or_return
	case syntax.Case_Clause:
		inventory_list(run, payload.list, event) or_return
		inventory_list(run, payload.body, event) or_return
	case syntax.Call_Expr:
		inventory_node(run, payload.expr, event) or_return
		inventory_list(run, payload.args, event) or_return
	case syntax.Selector_Call_Expr:
		inventory_node(run, payload.expr, event) or_return
		inventory_node(run, payload.call, event) or_return
	case syntax.Unary_Expr:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Paren_Expr:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Deref_Expr:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Auto_Cast:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Or_Return_Expr:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Or_Branch_Expr:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Tag_Expr:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Ellipsis:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Type_Cast:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Type_Assertion:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Binary_Expr:
		inventory_node(run, payload.left, event) or_return
		inventory_node(run, payload.right, event) or_return
	case syntax.Selector_Expr:
		inventory_node(run, payload.expr, event) or_return
	case syntax.Index_Expr:
		inventory_node(run, payload.expr, event) or_return
		inventory_node(run, payload.index, event) or_return
	case syntax.Matrix_Index_Expr:
		inventory_node(run, payload.expr, event) or_return
		inventory_node(run, payload.row_index, event) or_return
		inventory_node(run, payload.column_index, event) or_return
	case syntax.Slice_Expr:
		inventory_node(run, payload.expr, event) or_return
		inventory_node(run, payload.low, event) or_return
		inventory_node(run, payload.high, event) or_return
	case syntax.Comp_Lit:
		inventory_list(run, payload.elems, event) or_return
	case syntax.Field_Value:
		inventory_node(run, payload.value, event) or_return
	case syntax.Ternary_Expr:
		inventory_node(run, payload.cond, event) or_return
		if ast.nodes[node].kind == .Ternary_When_Expr {
			condition := check.expression_info(run.program, procedure.view, payload.cond)
			if constant := check.constant(run.program, condition.constant); constant != nil {
				if value, ok := constant.value.(bool); ok {
					inventory_node(run, payload.x if value else payload.y, event) or_return
				}
			}
		} else {
			inventory_node(run, payload.x, event) or_return
			inventory_node(run, payload.y, event) or_return
		}
	case syntax.Or_Else_Expr:
		inventory_node(run, payload.x, event) or_return
		inventory_node(run, payload.y, event) or_return
	}
	return nil
}
