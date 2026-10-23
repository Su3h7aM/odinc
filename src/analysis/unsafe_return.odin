package analysis

import "base:runtime"
import "core:fmt"
import "oc:check"
import "oc:syntax"
import "oc:types"

@(private = "package")
check_unsafe_returns :: proc(run: ^Run) -> runtime.Allocator_Error {
	for event in run.events[1:] {
		if event.kind != .Return { continue }
		procedure := run.program.procedure_list[run.procedures[event.procedure].checked_index]
		file := &run.program.files[procedure.body.file]
		if .Escape in file.ast.analysis { continue }
		plan := check.plan(run.program, event.plan)
		if plan == nil { continue }
		exit, ok := plan^.(check.Exit_Plan)
		if !ok { continue }
		for value in exit.values {
			expression: check.Expression_Ref
			switch operand in value {
			case check.Expression_Ref:
				expression = operand
			case check.Projection:
				expression = operand.expression
			case check.Const_Id, check.Entity_Id:
				continue
			}
			info := check.expression_info(run.program, expression.view, expression.node)
			node := unsafe_return_expression(run.program, expression)
			unsafe_return(run, expression, info, info.type, node) or_return
		}
	}
	return nil
}

@(private = "file")
unparen :: proc(ast: ^syntax.Ast, node: syntax.Node_Index) -> syntax.Node_Index {
	node := node
	for node != 0 && ast.nodes[node].kind == .Paren_Expr {
		node = syntax.node_payload(ast, node, syntax.Paren_Expr).expr
	}
	return node
}

@(private = "file")
unsafe_return_expression :: proc(program: ^check.Checked_Program, expression: check.Expression_Ref) -> syntax.Node_Index {
	ast := program.files[program.typed_views[expression.view].file].ast
	node := unparen(ast, expression.node)
	for ast.nodes[node].kind == .Call_Expr {
		call := syntax.node_payload(ast, node, syntax.Call_Expr)
		callee := check.expression_info(program, expression.view, call.expr)
		arguments := syntax.node_list(ast, call.args)
		if callee.mode != .Type || len(arguments) != 1 || ast.nodes[arguments[0]].kind == .Field_Value { break }
		argument := check.expression_info(program, expression.view, arguments[0])
		converted := check.expression_info(program, expression.view, node)
		if !types.are_identical(program.type_data, argument.type, converted.type) { break }
		node = unparen(ast, arguments[0])
	}
	return node
}

@(private = "file")
expression_entity :: proc(program: ^check.Checked_Program, view: check.View_Id, node: syntax.Node_Index) -> check.Entity_Id {
	ast := program.files[program.typed_views[view].file].ast
	node := node
	node = unparen(ast, node)
	#partial switch ast.nodes[node].kind {
	case .Ident, .Selector_Expr, .Call_Expr:
		return check.expression_info(program, view, node).entity
	case .Ternary_When_Expr:
		ternary := syntax.node_payload(ast, node, syntax.Ternary_Expr)
		if ternary.op1.kind == .When {
			condition := check.expression_info(program, view, ternary.cond)
			if constant := check.constant(program, condition.constant); constant != nil {
				if value, ok := constant.value.(bool); ok { return expression_entity(program, view, ternary.x if value else ternary.y) }
			}
		}
	}
	return 0
}

@(private = "file")
is_local_variable :: proc(run: ^Run, entity: check.Entity_Id) -> bool {
	if entity == 0 || run.excluded_locals[entity] { return false }
	value := run.program.entities[entity]
	if value.kind != .Variable { return false }
	variable, ok := value.data.(check.Variable_Data)
	return ok && variable.storage == .Local
}

@(private = "file")
unsafe_return :: proc(
	run: ^Run,
	original: check.Expression_Ref,
	info: check.Expression_Info,
	expected: types.Type_Id,
	node: syntax.Node_Index,
) -> runtime.Allocator_Error {
	if expected == types.TYPE_NONE || node == 0 { return nil }
	file := &run.program.files[run.program.typed_views[original.view].file]
	ast := file.ast
	descriptor := types.get(run.program.type_data, types.resolve_named(run.program.type_data, expected))
	if ast.nodes[node].kind == .Comp_Lit && descriptor.kind == .Slice {
		literal := syntax.node_payload(ast, node, syntax.Comp_Lit)
		if literal.elems.count != 0 { report_unsafe_return(run, original, "a compound literal of a slice") or_return }
	} else if ast.nodes[node].kind == .Unary_Expr && syntax.node_payload(ast, node, syntax.Unary_Expr).op.kind == .And {
		operand := unparen(ast, syntax.node_payload(ast, node, syntax.Unary_Expr).expr)
		entity := expression_entity(run.program, original.view, operand)
		if is_local_variable(run, entity) {
			report_unsafe_return(run, original, "the address of a local variable") or_return
		} else if ast.nodes[operand].kind == .Comp_Lit {
			report_unsafe_return(run, original, "the address of a compound literal") or_return
		} else if ast.nodes[operand].kind == .Index_Expr || ast.nodes[operand].kind == .Matrix_Index_Expr {
			base: syntax.Node_Index
			if ast.nodes[operand].kind == .Index_Expr {
				base = syntax.node_payload(ast, operand, syntax.Index_Expr).expr
			} else {
				base = syntax.node_payload(ast, operand, syntax.Matrix_Index_Expr).expr
			}
			indexed := expression_entity(run.program, original.view, base)
			if indexed != 0 {
				type := run.program.entities[indexed].type
				kind := types.get(run.program.type_data, types.resolve_named(run.program.type_data, type)).kind
				array_like := kind == .Array || kind == .Enumerated_Array
				if ast.nodes[operand].kind == .Matrix_Index_Expr { array_like = false }
				if is_local_variable(run, indexed) && (array_like || kind == .Matrix) {
					report_unsafe_return(run, original, "the address of an indexed variable", type) or_return
				}
			}
		}
	} else if ast.nodes[node].kind == .Slice_Expr {
		base := unparen(ast, syntax.node_payload(ast, node, syntax.Slice_Expr).expr)
		entity := expression_entity(run.program, original.view, base)
		if is_local_variable(run, entity) &&
		   types.get(run.program.type_data, types.resolve_named(run.program.type_data, run.program.entities[entity].type)).kind == .Array {
			report_unsafe_return(run, original, "a slice of a local variable") or_return
		} else if ast.nodes[base].kind == .Comp_Lit {
			report_unsafe_return(run, original, "a slice of a compound literal") or_return
		}
	} else if descriptor.kind == .Slice && upstream_constant(run.program, original, info) {
		original_node := unparen(ast, original.node)
		if ast.nodes[original_node].kind == .Call_Expr {
			callee := syntax.node_payload(ast, original_node, syntax.Call_Expr).expr
			if ast.nodes[callee].kind == .Basic_Directive {
				span := ast.nodes[callee]
				if string(file.source[span.start:span.end]) == "#load" { return nil }
			}
		}
		report_unsafe_return(run, original, "a compound literal of a slice", note = true) or_return
	} else if ast.nodes[node].kind == .Comp_Lit {
		literal := syntax.node_payload(ast, node, syntax.Comp_Lit)
		for element in syntax.node_list(ast, literal.elems) {
			if ast.nodes[element].kind != .Field_Value { continue }
			field := syntax.node_payload(ast, element, syntax.Field_Value)
			field_type := compound_field_type(run.program, original.view, node, expected, field)
			if field_type != types.TYPE_NONE { unsafe_return(run, original, info, field_type, field.value) or_return }
		}
	}
	return nil
}

@(private = "package")
upstream_constant :: proc(program: ^check.Checked_Program, expression: check.Expression_Ref, info: check.Expression_Info) -> bool {
	if constant := check.constant(program, info.constant); constant != nil {
		if _, nil_value := constant.value.(check.Nil_Value); nil_value { return false }
	}
	return check.addressing_constant(program, expression.view, expression.node)
}

@(private = "file")
compound_field_type :: proc(
	program: ^check.Checked_Program,
	view: check.View_Id,
	node: syntax.Node_Index,
	expected: types.Type_Id,
	field: syntax.Field_Value,
) -> types.Type_Id {
	if entity := expression_entity(program, view, field.field); entity != 0 { return program.entities[entity].type }
	info := check.expression_info(program, view, node)
	if plan := check.plan(program, info.plan); plan != nil {
		if aggregate, is_aggregate := plan^.(check.Aggregate_Plan); is_aggregate {
			for value, index in aggregate.values {
				if expression, is_expression := value.(check.Expression_Ref); is_expression && expression.node == field.value && expression.view == view {
					if index < len(aggregate.field_paths) && len(aggregate.field_paths[index]) != 0 {
						path := aggregate.field_paths[index]
						last := path[len(path) - 1]
						return types.get(program.type_data, last.type).fields[last.field_index].type
					}
				}
			}
		}
	}
	descriptor := types.get(program.type_data, types.resolve_named(program.type_data, expected))
	if descriptor.kind != .Struct { return types.TYPE_NONE }
	file := &program.files[program.typed_views[view].file]
	span := file.ast.nodes[field.field]
	name := string(file.source[span.start:span.end])
	for member in descriptor.fields {
		if member.name == name { return member.type }
	}
	return types.TYPE_NONE
}

@(private = "file")
report_unsafe_return :: proc(
	run: ^Run,
	original: check.Expression_Ref,
	category: string,
	extra_type: types.Type_Id = 0,
	note: bool = false,
) -> runtime.Allocator_Error {
	file_id := run.program.typed_views[original.view].file
	file := &run.program.files[file_id]
	text := check.render_expression(file.ast, file.source, original.node, run.allocator)
	reason: string
	if extra_type != 0 {
		type_text := types.type_text(run.program.type_data, extra_type, run.allocator)
		reason = fmt.aprintf(
			"It is unsafe to return %s ('%s') of type ('%s') from a procedure, as it uses the current stack frame's memory",
			category,
			text,
			type_text,
			allocator = run.allocator,
		)
	} else {
		reason = fmt.aprintf(
			"It is unsafe to return %s ('%s') from a procedure, as it uses the current stack frame's memory",
			category,
			text,
			allocator = run.allocator,
		)
	}
	if note { reason = fmt.aprintf("%s\n\tNote: A constant slice value will use the memory of the current stack frame", reason, allocator = run.allocator) }
	span := file.ast.nodes[original.node]
	append(&run.diagnostics, Diagnostic{severity = .Error, source = {file_id, span.start, span.end}, reason = reason}) or_return
	return nil
}
