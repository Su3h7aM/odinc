package analysis

import "base:runtime"
import "core:fmt"
import "oc:check"
import "oc:syntax"

@(private = "package")
check_escape_returns :: proc(run: ^Run, options: Options) -> runtime.Allocator_Error {
	if .Escape not_in run.enabled { return nil }
	escape: Escape
	escape_graph_init(&escape, run) or_return
	for procedure, index in run.procedures {
		if index == 0 { continue }
		checked := run.program.procedure_list[procedure.checked_index]
		file := &run.program.files[checked.body.file]
		if .Escape not_in file.ast.analysis { continue }
		if !options.no_entry_point && !options.test && checked.entity == options.entry_point { continue }
		escape.procedure = Procedure_Id(index)
		escape.view = checked.view
		escape.reachable = true
		escape.variadic = 0
		descriptor := escape_type(&escape, checked.signature)
		if descriptor.variadic && !descriptor.c_vararg {
			if data, ok := run.program.entities[checked.entity].data.(check.Procedure_Data); ok {
				if data.variadic_index >= 0 && data.variadic_index < len(checked.parameters) { escape.variadic = checked.parameters[data.variadic_index] }
			}
		}
		escape_statement(&escape, checked.body.node) or_return
	}
	run.graph = escape.graph
	return nil
}

@(private = "file")
escape_statement :: proc(escape: ^Escape, node: syntax.Node_Index) -> runtime.Allocator_Error {
	if node == 0 || !escape.reachable { return nil }
	program := escape.run.program
	ast := program.files[program.typed_views[escape.view].file].ast
	info := check.expression_info(program, escape.view, node)
	if info.state == .Inactive || info.state == .Invalid { return nil }
	#partial switch payload in ast.nodes[node].payload {
	case syntax.Block_Stmt:
		for statement in syntax.node_list(ast, payload.stmts) { escape_statement(escape, statement) or_return }
	case syntax.Tag_Stmt:
		escape_statement(escape, payload.stmt) or_return
	case syntax.Value_Decl:
		if !payload.is_mutable { return nil }
		escape_declaration(escape, payload, info.plan) or_return
	case syntax.Assign_Stmt:
		if info.plan == 0 { return nil }
		if assignment, ok := check.plan(program, info.plan)^.(check.Assignment_Plan); ok {
			for destination in assignment.destinations { if !escape_retain_known_effects(escape, destination) { return nil } }
			for operand in assignment.values { if !escape_retain_known_effects(escape, operand) { return nil } }
			values := make([dynamic]Value_Id, 0, escape.run.allocator) or_return
			for operand, index in assignment.values {
				value := escape_operand(escape, operand) or_return
				expression: check.Expression_Ref
				if source, is_expression := operand.(check.Expression_Ref); is_expression { expression = source }
				if index < len(assignment.conversions) { value = escape_conversion(escape, assignment.conversions[index], value, expression) or_return }
				append(&values, value) or_return
			}
			for destination, index in assignment.destinations {
				value: Value_Id
				if index < len(values) { value = values[index] }
				escape_store_operand(escape, destination, value) or_return
			}
		}
	case syntax.Return_Stmt:
		if info.plan != 0 {
			if exit, ok := check.plan(program, info.plan)^.(check.Exit_Plan); ok {
				for operand in exit.values { if !escape_retain_known_effects(escape, operand) { return nil } }
				results := syntax.node_list(ast, payload.results)
				for operand, index in exit.values {
					expression: check.Expression_Ref
					switch source in operand {
					case check.Expression_Ref:
						expression = source
					case check.Projection:
						expression = source.expression
					case check.Entity_Id, check.Const_Id:
					}
					if len(results) == len(exit.values) { expression = {escape.view, results[index]} }
					value := escape_operand(escape, operand) or_return
					if index < len(exit.conversions) { value = escape_conversion(escape, exit.conversions[index], value, expression) or_return }
					if expression.node != 0 { escape_report_return(escape, expression, value) or_return }
				}
			}
		}
		escape.reachable = false
	case syntax.Expr_Stmt:
		if !escape_retain_known_effects(escape, check.Expression_Ref{escape.view, payload.expr}) { return nil }
		_ = escape_expression(escape, {escape.view, payload.expr}) or_return
	case syntax.When_Stmt:
		condition := check.expression_info(program, escape.view, payload.cond)
		if constant := check.constant(program, condition.constant); constant != nil {
			if value, ok := constant.value.(bool); ok { escape_statement(escape, payload.body if value else payload.else_stmt) or_return }
		}
	case syntax.If_Stmt,
	     syntax.For_Stmt,
	     syntax.Range_Stmt,
	     syntax.Unroll_Range_Stmt,
	     syntax.Switch_Stmt,
	     syntax.Type_Switch_Stmt,
	     syntax.Defer_Stmt,
	     syntax.Branch_Stmt:
		escape.reachable = false
	}
	return nil
}

@(private = "file")
escape_declaration :: proc(escape: ^Escape, declaration: syntax.Value_Decl, plan_id: check.Plan_Id) -> runtime.Allocator_Error {
	program := escape.run.program
	ast := program.files[program.typed_views[escape.view].file].ast
	names := syntax.node_list(ast, declaration.names)
	values := syntax.node_list(ast, declaration.values)
	if len(values) != 0 && len(values) != len(names) { escape.reachable = false; return nil }
	for source in values { if !escape_retain_known_effects(escape, check.Expression_Ref{escape.view, source}) { return nil } }
	assignment: check.Assignment_Plan
	if plan_id != 0 { assignment, _ = check.plan(program, plan_id)^.(check.Assignment_Plan) }
	for name, index in names {
		info := check.expression_info(program, escape.view, name)
		if !escape_local(escape, info.entity) { continue }
		value: Value_Id
		if len(values) == len(names) {
			expression := check.Expression_Ref{escape.view, values[index]}
			value = escape_expression(escape, expression) or_return
			if index < len(assignment.conversions) { value = escape_conversion(escape, assignment.conversions[index], value, expression) or_return }
		}
		escape_store_operand(escape, info.entity, value) or_return
	}
	return nil
}

@(private = "file")
escape_stack_origin :: proc(escape: ^Escape, value: Value_Id) -> (origin: Origin, definite, found: bool, err: runtime.Allocator_Error) {
	for fact in escape_facts(escape, value) {
		if fact.definite &&
		   (fact.origin.kind == .Local || fact.origin.kind == .Temporary || fact.origin.kind == .Variadic) { return fact.origin, true, true, nil }
	}
	work := make([dynamic]Origin, 0, escape.run.allocator) or_return
	for fact in escape_facts(escape, value) { append(&work, fact.origin) or_return }
	for index := 0; index < len(work); index += 1 {
		entry := work[index]
		if entry.kind == .Local || entry.kind == .Temporary || entry.kind == .Variadic { return entry, false, true, nil }
		if entry.kind != .Owned { continue }
		for fact in escape_facts(escape, escape.memory[entry.object]) {
			if !escape_path_has_prefix(escape, fact.path, entry.path) && !escape_path_has_prefix(escape, entry.path, fact.path) { continue }
			seen := false
			for previous in work { if previous == fact.origin { seen = true; break } }
			if !seen { append(&work, fact.origin) or_return }
		}
	}
	return
}

@(private = "file")
escape_report_return :: proc(escape: ^Escape, expression: check.Expression_Ref, value: Value_Id) -> runtime.Allocator_Error {
	origin, definite, found := escape_stack_origin(escape, value) or_return
	if !found { return nil }
	program := escape.run.program
	file_id := program.typed_views[expression.view].file
	file := &program.files[file_id]
	text := check.render_expression(file.ast, file.source, expression.node, escape.run.allocator)
	if len(text) > 80 { text = check.render_expression(file.ast, file.source, expression.node, escape.run.allocator, shorthand = true) }
	object := escape.graph.objects[origin.object]
	description: string
	switch origin.kind {
	case .Local:
		kind := "parameter" if escape_parameter(escape, object.entity) else "local variable"
		description = fmt.aprintf("the stack memory of the %s '%s'", kind, program.entities[object.entity].name, allocator = escape.run.allocator)
	case .Temporary:
		ast := program.files[program.typed_views[object.temporary.view].file].ast
		kind := "a compound literal" if ast.nodes[object.temporary.node].kind == .Comp_Lit else "a temporary value"
		description = fmt.aprintf("the stack memory of %s", kind, allocator = escape.run.allocator)
	case .Variadic:
		description = fmt.aprintf(
			"the variadic parameter '%s', which only lives for the duration of the call",
			program.entities[object.entity].name,
			allocator = escape.run.allocator,
		)
	case .Invalid, .Parameter, .Parameter_Load, .Parameter_Deep, .Outer, .Owned:
		return nil
	}
	verb := "refers to" if definite else "may refer to"
	reason := fmt.aprintf(
		"It is unsafe to return '%s' from a procedure, as it %s %s\n\tSuggestion: If this is intended, make it explicit with a conversion to 'rawptr' or 'uintptr', or a 'transmute'",
		text,
		verb,
		description,
		allocator = escape.run.allocator,
	)
	span := file.ast.nodes[expression.node]
	start, end := span.start, span.start
	if span.end > span.start && int(span.start) < len(file.source) {
		limit := min(int(span.end), len(file.source))
		tokenizer := syntax.init(file.source[span.start:limit])
		token := syntax.next(&tokenizer)
		if token.end > token.start {
			start = span.start + token.start
			end = span.start + token.end
		}
	}
	append(&escape.run.diagnostics, Diagnostic{severity = .Error if definite else .Warning, source = {file_id, start, end}, reason = reason}) or_return
	return nil
}
