package analysis

import "base:runtime"
import "core:fmt"
import "core:mem"
import "oc:check"
import "oc:syntax"

@(private = "package")
check_escape_returns :: proc(run: ^Run, options: Options, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	if .Escape not_in run.enabled { return nil }
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&scratch)
	escape := Escape {
		scratch   = &scratch,
		allocator = mem.dynamic_arena_allocator(&scratch),
	}
	escape_graph_init(&escape, run) or_return
	escape.call_graph = call_graph_build(run) or_return
	escape_analyse_program(&escape, options) or_return
	return nil
}

@(private = "package")
escape_statement :: proc(escape: ^Escape, node: syntax.Node_Index) -> runtime.Allocator_Error {
	if node == 0 || !escape.reachable { return nil }
	program := escape.run.program
	ast := program.files[program.typed_views[escape.view].file].ast
	info := check.expression_info(program, escape.view, node)
	if info.state == .Inactive || info.state == .Invalid { return nil }
	#partial switch payload in ast.nodes[node].payload {
	case syntax.Block_Stmt:
		escape_block(escape, node, payload.label, syntax.node_list(ast, payload.stmts)) or_return
	case syntax.Tag_Stmt:
		escape_statement(escape, payload.stmt) or_return
	case syntax.Value_Decl:
		if !payload.is_mutable { return nil }
		escape_declaration(escape, payload, info.plan) or_return
		escape_note_declaration(escape, syntax.node_list(ast, payload.names), syntax.node_list(ast, payload.values)) or_return
	case syntax.Assign_Stmt:
		if info.plan == 0 { return nil }
		if assignment, ok := check.plan(program, info.plan)^.(check.Assignment_Plan); ok {
			for destination in assignment.destinations { if !escape_retain_known_effects(escape, destination) { return nil } }
			for operand in assignment.values { if !escape_retain_known_effects(escape, operand) { return nil } }
			values := make([dynamic]Value_Id, 0, escape.allocator) or_return
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
				if index < len(syntax.node_list(ast, payload.rhs)) {
					escape_note_store(
						escape,
						syntax.node_list(ast, payload.lhs)[index],
						syntax.node_list(ast, payload.rhs)[index],
						payload.op.kind == .Eq,
					) or_return
				}
			}
		}
	case syntax.Return_Stmt:
		if info.plan != 0 {
			if exit, ok := check.plan(program, info.plan)^.(check.Exit_Plan); ok {
				for operand in exit.values { if !escape_retain_known_effects(escape, operand) { return nil } }
				results := syntax.node_list(ast, payload.results)
				checked := program.procedure_list[escape.run.procedures[escape.procedure].checked_index]
				note_results := len(exit.values) == len(checked.results)
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
					if note_results { escape_note_result(escape, index, value) or_return }
				}
			}
		}
		bare := true
		if info.plan != 0 {
			if exit, ok := check.plan(program, info.plan)^.(check.Exit_Plan); ok { bare = len(exit.values) == 0 }
		}
		if bare { escape_named_results(escape, node) or_return }
		escape_run_defers(escape, 0) or_return
		escape_commit_stores(escape) or_return
		escape.reachable = false
	case syntax.Expr_Stmt:
		escape_note_expression(escape, {escape.view, payload.expr}) or_return
		if !escape_retain_known_effects(escape, check.Expression_Ref{escape.view, payload.expr}) { return nil }
		_ = escape_expression(escape, {escape.view, payload.expr}) or_return
	case syntax.When_Stmt:
		condition := check.expression_info(program, escape.view, payload.cond)
		if constant := check.constant(program, condition.constant); constant != nil {
			if value, ok := constant.value.(bool); ok { escape_statement(escape, payload.body if value else payload.else_stmt) or_return }
		}
	case syntax.If_Stmt:
		escape_if(escape, node, payload) or_return
	case syntax.For_Stmt:
		escape_statement(escape, payload.init) or_return
		escape_loop(escape, node, payload.cond, payload.post, payload.body, 0, nil) or_return
	case syntax.Range_Stmt:
		escape_statement(escape, payload.init) or_return
		escape_loop(escape, node, 0, 0, payload.body, payload.expr, syntax.node_list(ast, payload.vals)) or_return
	case syntax.Unroll_Range_Stmt:
		vals := make([dynamic]syntax.Node_Index, 0, escape.allocator) or_return
		if payload.val0 != 0 { append(&vals, payload.val0) or_return }
		if payload.val1 != 0 { append(&vals, payload.val1) or_return }
		escape_loop(escape, node, 0, 0, payload.body, payload.expr, vals[:]) or_return
	case syntax.Switch_Stmt:
		escape_statement(escape, payload.init) or_return
		escape_note_expression(escape, {escape.view, payload.cond}) or_return
		_ = escape_expression(escape, {escape.view, payload.cond}) or_return
		exhaustive := false
		if !payload.partial && payload.cond != 0 {
			tag := check.expression_info(program, escape.view, payload.cond)
			exhaustive = escape_type(escape, tag.type).kind == .Enum
		}
		escape_switch(escape, node, payload.body, exhaustive) or_return
	case syntax.Type_Switch_Stmt:
		escape_switch(escape, node, payload.body, !payload.partial) or_return
	case syntax.Defer_Stmt:
		if len(escape.defers) > 0 { append(&escape.defers[len(escape.defers) - 1].stmts, payload.stmt) or_return }
	case syntax.Branch_Stmt:
		if payload.token.kind == .Fallthrough {
			escape.fallen = escape_capture(escape) or_return
			escape.fallen_live = true
			escape.reachable = false
		} else { escape_branch(escape, payload.label, payload.token.kind) or_return }
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

@(private = "package")
escape_stack_origin :: proc(escape: ^Escape, value: Value_Id) -> (origin: Origin, definite, found: bool, err: runtime.Allocator_Error) {
	for fact in escape_facts(escape, value) {
		if fact.definite &&
		   (fact.origin.kind == .Local || fact.origin.kind == .Temporary || fact.origin.kind == .Variadic) { return fact.origin, true, true, nil }
	}
	work := make([dynamic]Origin, 0, escape.allocator) or_return
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

@(private = "package")
escape_report_return :: proc(escape: ^Escape, expression: check.Expression_Ref, value: Value_Id, name: string = "") -> runtime.Allocator_Error {
	if escape.muted { return nil }
	for reported in escape.reported { if reported == expression.node { return nil } }
	origin, definite, found := escape_stack_origin(escape, value) or_return
	if !found { return nil }
	append(&escape.reported, expression.node) or_return
	program := escape.run.program
	text := name
	if text == "" { text = escape_expression_text(escape, expression) }
	object := escape.graph.objects[origin.object]
	description: string
	switch origin.kind {
	case .Local:
		kind := "parameter" if escape_parameter(escape, object.entity) else "local variable"
		description = fmt.aprintf("the stack memory of the %s '%s'", kind, program.entities[object.entity].name, allocator = escape.allocator)
	case .Temporary:
		ast := program.files[program.typed_views[object.temporary.view].file].ast
		kind := "a compound literal" if ast.nodes[object.temporary.node].kind == .Comp_Lit else "a temporary value"
		description = fmt.aprintf("the stack memory of %s", kind, allocator = escape.allocator)
	case .Variadic:
		description = fmt.aprintf(
			"the variadic parameter '%s', which only lives for the duration of the call",
			program.entities[object.entity].name,
			allocator = escape.allocator,
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
		allocator = escape.allocator,
	)
	append(
		escape_report_list(escape),
		Diagnostic{severity = .Error if definite else .Warning, source = escape_expression_span(escape, expression), reason = reason},
	) or_return
	return nil
}

@(private = "package")
escape_expression_text :: proc(escape: ^Escape, expression: check.Expression_Ref) -> string {
	program := escape.run.program
	file := &program.files[program.typed_views[expression.view].file]
	text := check.render_expression(file.ast, file.source, expression.node, escape.allocator)
	if len(text) > 80 { text = check.render_expression(file.ast, file.source, expression.node, escape.allocator, shorthand = true) }
	return text
}

@(private = "package")
escape_expression_span :: proc(escape: ^Escape, expression: check.Expression_Ref) -> check.Source_Span {
	program := escape.run.program
	file_id := program.typed_views[expression.view].file
	file := &program.files[file_id]
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
	return {file_id, start, end}
}
