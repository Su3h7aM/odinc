package analysis

import "base:runtime"
import "core:fmt"
import "core:strings"
import "oc:check"
import "oc:syntax"
import "oc:types"

@(private = "package")
escape_report_list :: proc(escape: ^Escape) -> ^[dynamic]Diagnostic {
	if escape.reports != nil { return escape.reports }
	return &escape.run.diagnostics
}

@(private = "package")
escape_merge_outers :: proc(escape: ^Escape, dst: ^[dynamic]Outer_Store, src: []Outer_Store) -> (changed: bool, err: runtime.Allocator_Error) {
	for store in src {
		found := false
		for previous in dst { if previous == store { found = true; break } }
		if found { continue }
		append(dst, store) or_return
		changed = true
	}
	return
}

@(private = "package")
escape_store_at :: proc(escape: ^Escape, node: syntax.Node_Index, pointer, value: Value_Id, exact: bool) -> runtime.Allocator_Error {
	facts := escape_facts(escape, pointer)
	precise := exact && len(facts) == 1
	for fact in facts {
		#partial switch fact.origin.kind {
		case .Local, .Temporary, .Owned:
			escape_store_memory(escape, fact.origin.object, fact.origin.path, value, precise) or_return
		case .Outer, .Parameter, .Parameter_Load, .Parameter_Deep:
			escape_note_outer(escape, node, fact.origin, value) or_return
		}
	}
	return nil
}

@(private = "file")
escape_note_outer :: proc(escape: ^Escape, node: syntax.Node_Index, dest: Origin, value: Value_Id) -> runtime.Allocator_Error {
	root, path, exact := escape_outer_location(escape, node) or_return
	if exact {
		for index := len(escape.outers) - 1; index >= 0; index -= 1 {
			previous := escape.outers[index]
			if previous.root == root && previous.path == path { unordered_remove(&escape.outers, index) }
		}
	}
	for fact in escape_facts(escape, value) {
		if fact.origin.kind == .Outer { continue }
		store := Outer_Store {
			node       = node,
			root       = root,
			path       = path,
			exact      = exact,
			dest       = dest,
			origin     = fact.origin,
			value_path = fact.path,
		}
		switch fact.origin.kind {
		case .Parameter, .Parameter_Load, .Parameter_Deep:
			store.node = 0
		case .Invalid, .Local, .Temporary, .Variadic, .Outer, .Owned:
		}
		found := false
		for previous in escape.outers { if previous == store { found = true; break } }
		if !found { append(&escape.outers, store) or_return }
	}
	return nil
}

@(private = "file")
escape_outer_location :: proc(escape: ^Escape, node: syntax.Node_Index) -> (root: check.Entity_Id, path: Path_Id, exact: bool, err: runtime.Allocator_Error) {
	current := escape_unparen(escape, node)
	if current == 0 { return }
	ast := escape_ast(escape)
	#partial switch payload in ast.nodes[current].payload {
	case syntax.Ident:
		info := check.expression_info(escape.run.program, escape.view, current)
		if info.entity == 0 { return }
		return info.entity, 0, true, nil
	case syntax.Deref_Expr:
		root, path, exact = escape_outer_location(escape, payload.expr) or_return
		path = escape_path(escape, path, {kind = .Dereference}) or_return
		return
	case syntax.Index_Expr:
		root, path, _ = escape_outer_location(escape, payload.expr) or_return
		path = escape_path(escape, path, {kind = .Element}) or_return
		return root, path, false, nil
	case syntax.Selector_Expr:
		info := check.expression_info(escape.run.program, escape.view, node)
		if info.entity != 0 && .Field not_in escape.run.program.entities[info.entity].flags { return info.entity, 0, true, nil }
		root, path, exact = escape_outer_location(escape, payload.expr) or_return
		base := check.expression_info(escape.run.program, escape.view, payload.expr)
		struct_type := base.type
		descriptor := escape_type(escape, struct_type)
		if descriptor.kind == .Pointer {
			path = escape_path(escape, path, {kind = .Dereference}) or_return
			struct_type = descriptor.elem
			descriptor = escape_type(escape, struct_type)
		}
		if descriptor.kind != .Struct { return root, path, false, nil }
		name := escape_expression_text(escape, {escape.view, payload.field})
		field_index := -1
		for field, index in descriptor.fields {
			if field.name == name { field_index = index; break }
		}
		if field_index < 0 { return root, path, false, nil }
		owner := types.resolve_named(escape.run.program.type_data, struct_type)
		path = escape_path(escape, path, {kind = .Field, owner_type = owner, field_index = u32(field_index)}) or_return
		return
	}
	return
}

@(private = "package")
escape_note_result :: proc(escape: ^Escape, index: int, value: Value_Id) -> runtime.Allocator_Error {
	for fact in escape_facts(escape, value) {
		flow: Flow
		if !escape_flow_from(escape, fact.origin, &flow) { continue }
		flow.target = .Result
		flow.target_index = index
		flow.target_path = fact.path
		escape_add_flow(escape, flow) or_return
	}
	return nil
}

@(private = "package")
escape_commit_stores :: proc(escape: ^Escape) -> runtime.Allocator_Error {
	for store in escape.outers {
		held := escape_value(escape, .Copy, {}, []Value_Fact{{origin = store.origin}}) or_return
		origin, _, found := escape_stack_origin(escape, held) or_return
		if found && origin.kind != .Variadic && store.node != 0 { escape_report_store(escape, store.node, origin) or_return }
		flow: Flow
		if !escape_flow_from(escape, store.origin, &flow) { continue }
		switch store.dest.kind {
		case .Outer:
			flow.target = .Outer
		case .Parameter:
			flow.target = .Pointee
		case .Parameter_Load:
			flow.target = .Loaded
		case .Parameter_Deep:
			flow.target = .Deep
		case .Invalid, .Local, .Temporary, .Variadic, .Owned:
			continue
		}
		if flow.target != .Outer {
			flow.target_path = store.dest.path
			if flow.target == .Pointee {
				offset := escape_offset_origin(escape, store.dest, store.value_path) or_return
				flow.target_path = offset.path
			} else if !store.dest.offset_lost {
				flow.value_path = store.value_path
			}
			entity := escape.graph.objects[store.dest.object].entity
			if !escape_param_index(escape, entity, &flow.target_index) { continue }
		}
		if flow.target != .Outer && flow.target_index == flow.param {
			if flow.kind == .Load { continue }
			if flow.target == .Pointee && flow.target_path == flow.param_path { continue }
		}
		escape_add_flow(escape, flow) or_return
	}
	return nil
}

@(private = "file")
escape_flow_from :: proc(escape: ^Escape, origin: Origin, flow: ^Flow) -> bool {
	switch origin.kind {
	case .Parameter:
		flow.kind = .Value
	case .Parameter_Load:
		flow.kind = .Load
	case .Invalid, .Local, .Temporary, .Variadic, .Parameter_Deep, .Outer, .Owned:
		return false
	}
	flow.param_path = origin.path
	return escape_param_index(escape, escape.graph.objects[origin.object].entity, &flow.param)
}

@(private = "file")
escape_param_index :: proc(escape: ^Escape, entity: check.Entity_Id, index: ^int) -> bool {
	if entity == 0 { return false }
	checked := escape.run.program.procedure_list[escape.run.procedures[escape.procedure].checked_index]
	for parameter, position in checked.parameters {
		if parameter == entity {
			index^ = position
			return true
		}
	}
	return false
}

@(private = "file")
escape_add_flow :: proc(escape: ^Escape, flow: Flow) -> runtime.Allocator_Error {
	flow := flow
	flow.param_path = escape_path_widen(escape, flow.param_path) or_return
	flow.target_path = escape_path_widen(escape, flow.target_path) or_return
	flow.value_path = escape_path_widen(escape, flow.value_path) or_return
	for existing in escape.flows { if existing == flow { return nil } }
	append(&escape.flows, flow) or_return
	return nil
}

@(private = "file")
escape_path_widen :: proc(escape: ^Escape, path: Path_Id) -> (result: Path_Id, err: runtime.Allocator_Error) {
	steps := escape_path_steps(escape, path) or_return
	segment := 0
	cut := len(steps)
	for step, index in steps {
		if step.kind == .Dereference { segment = index + 1; continue }
		for earlier in segment ..< index {
			if steps[earlier].kind == step.kind && steps[earlier].field_index == step.field_index {
				cut = index
				break
			}
		}
		if cut != len(steps) { break }
	}
	return escape_path_from(escape, steps[:cut])
}

@(private = "package")
escape_path_steps :: proc(escape: ^Escape, path: Path_Id) -> (steps: [dynamic]Path_Step, err: runtime.Allocator_Error) {
	steps = make([dynamic]Path_Step, 0, escape.allocator) or_return
	for current := path; current != 0; current = escape.graph.paths[current].parent { append(&steps, escape.graph.paths[current].step) or_return }
	for index := 0; index < len(steps) / 2; index += 1 {
		end := len(steps) - 1 - index
		steps[index], steps[end] = steps[end], steps[index]
	}
	return
}

@(private = "file")
escape_path_from :: proc(escape: ^Escape, steps: []Path_Step) -> (result: Path_Id, err: runtime.Allocator_Error) {
	for step in steps { result = escape_path(escape, result, step) or_return }
	return
}

@(private = "file")
escape_offset_origin :: proc(escape: ^Escape, origin: Origin, extra: Path_Id) -> (result: Origin, err: runtime.Allocator_Error) {
	value := escape_origin_value(escape, {}, origin) or_return
	value = escape_pointer_offset(escape, {}, value, extra) or_return
	facts := escape_facts(escape, value)
	if len(facts) == 0 { return origin, nil }
	return facts[0].origin, nil
}

@(private = "file")
escape_report_store :: proc(escape: ^Escape, node: syntax.Node_Index, origin: Origin) -> runtime.Allocator_Error {
	if escape.muted { return nil }
	for reported in escape.reported { if reported == node { return nil } }
	append(&escape.reported, node) or_return
	expression := check.Expression_Ref{escape.view, node}
	text := escape_expression_text(escape, expression)
	ast := escape_ast(escape)
	kind := ast.nodes[node].kind
	call := kind == .Call_Expr || kind == .Selector_Call_Expr
	description := escape_origin_text(escape, origin)
	reason: string
	if call {
		reason = fmt.aprintf(
			"'%s' may keep a reference to %s after the procedure returns\n\tSuggestion: If this is intended, make it explicit with a conversion to 'rawptr' or 'uintptr', or a 'transmute'",
			text,
			description,
			allocator = escape.allocator,
		)
	} else {
		info := check.expression_info(escape.run.program, escape.view, node)
		reason = fmt.aprintf(
			"'%s' may still refer to %s after the procedure returns\n\tSuggestion: Clear it before the procedure returns, e.g. 'defer %s = %s'",
			text,
			description,
			text,
			escape_zero_text(escape, info.type),
			allocator = escape.allocator,
		)
	}
	append(escape_report_list(escape), Diagnostic{severity = .Warning, source = escape_expression_span(escape, expression), reason = reason}) or_return
	return nil
}

@(private = "file")
escape_origin_text :: proc(escape: ^Escape, origin: Origin) -> string {
	program := escape.run.program
	object := escape.graph.objects[origin.object]
	switch origin.kind {
	case .Local:
		kind := "parameter" if escape_parameter(escape, object.entity) else "local variable"
		return fmt.aprintf("the stack memory of the %s '%s'", kind, program.entities[object.entity].name, allocator = escape.allocator)
	case .Temporary:
		ast := program.files[program.typed_views[object.temporary.view].file].ast
		kind := "a compound literal" if object.temporary.node != 0 && ast.nodes[object.temporary.node].kind == .Comp_Lit else "a temporary value"
		return fmt.aprintf("the stack memory of %s", kind, allocator = escape.allocator)
	case .Variadic:
		return fmt.aprintf(
			"the variadic parameter '%s', which only lives for the duration of the call",
			program.entities[object.entity].name,
			allocator = escape.allocator,
		)
	case .Invalid, .Parameter, .Parameter_Load, .Parameter_Deep, .Outer, .Owned:
		return ""
	}
	return ""
}

@(private = "file")
escape_zero_text :: proc(escape: ^Escape, type: types.Type_Id) -> string {
	descriptor := escape_type(escape, type)
	#partial switch descriptor.kind {
	case .Struct, .Array, .Enumerated_Array, .Fixed_Capacity_Array, .Union, .Bit_Field, .Matrix, .Simd_Vector:
		return "{}"
	case .Integer, .Float, .Complex, .Quaternion, .Enum, .Bit_Set:
		return "0"
	case .Bool, .Untyped_Bool:
		return "false"
	case .String, .String16:
		return "\"\""
	}
	return "nil"
}

@(private = "package")
escape_invoke :: proc(escape: ^Escape, expression: check.Expression_Ref) -> (result: Value_Id, err: runtime.Allocator_Error) {
	program := escape.run.program
	file := &program.files[program.typed_views[expression.view].file]
	ast := file.ast
	payload, is_call := ast.nodes[expression.node].payload.(syntax.Call_Expr)
	if !is_call { return }
	for pending in escape.applying { if pending == expression { return } }
	append(&escape.applying, expression) or_return
	defer pop(&escape.applying)
	arguments := syntax.node_list(ast, payload.args)
	callee := check.expression_info(program, expression.view, payload.expr)
	info := check.expression_info(program, expression.view, expression.node)
	if callee.mode == .Type && len(arguments) == 1 {
		value := escape_expression(escape, {expression.view, arguments[0]}) or_return
		kind := escape_type(escape, info.type).kind
		if kind == .Raw_Pointer || kind == .Integer && types.get(program.type_data, info.type).name == "uintptr" { return }
		return escape_convert(escape, {expression.view, arguments[0]}, value, info.type)
	}
	if callee.entity != 0 && program.entities[callee.entity].kind == .Builtin {
		name := program.entities[callee.entity].name
		if name == "raw_data" && len(arguments) > 0 { return escape_elements(escape, {expression.view, arguments[0]}) }
		if name == "ptr_offset" && len(arguments) > 0 {
			if len(arguments) > 1 { escape_expression(escape, {expression.view, arguments[1]}) or_return }
			return escape_expression(escape, {expression.view, arguments[0]})
		}
		if (name == "mem_copy" || name == "mem_copy_non_overlapping") && len(arguments) == 3 {
			dst := escape_expression(escape, {expression.view, arguments[0]}) or_return
			src := escape_expression(escape, {expression.view, arguments[1]}) or_return
			escape_expression(escape, {expression.view, arguments[2]}) or_return
			pointee := escape_pointee_type(escape, check.expression_info(program, expression.view, arguments[1]).type)
			if pointee == 0 || escape_has_pointers(escape, pointee) {
				dst = escape_pointer_offset(escape, expression, dst, 0) or_return
				src = escape_pointer_offset(escape, expression, src, 0) or_return
				loaded := escape_load(escape, expression, src, 0) or_return
				escape_store_at(escape, expression.node, dst, loaded, false) or_return
			}
			return
		}
	}
	_ = escape_expression(escape, {expression.view, payload.expr}) or_return
	target: Procedure_Id
	plan := check.plan(program, info.plan)
	call: check.Call_Plan
	if plan != nil { call, _ = plan^.(check.Call_Plan) }
	resolved := call.entity if call.entity != 0 else callee.entity
	if resolved != 0 && program.entities[resolved].kind == .Procedure { target = escape_procedure_target(escape, resolved) }
	flows: []Flow
	if target != 0 && int(target) < len(escape.summaries) && !escape.calls_unknown { flows = escape.summaries[target] }
	if len(flows) == 0 {
		for argument in arguments { escape_expression(escape, {expression.view, argument}) or_return }
		return
	}
	if len(call.arguments) == 0 {
		for argument in arguments { escape_expression(escape, {expression.view, argument}) or_return }
		return
	}
	return escape_apply_call(escape, expression, target, flows, call)
}

@(private = "file")
escape_apply_call :: proc(
	escape: ^Escape,
	expression: check.Expression_Ref,
	target: Procedure_Id,
	flows: []Flow,
	call: check.Call_Plan,
) -> (
	result: Value_Id,
	err: runtime.Allocator_Error,
) {
	checked := escape.run.program.procedure_list[escape.run.procedures[target].checked_index]
	count := len(checked.parameters)
	args := make([]Value_Id, count, escape.allocator) or_return
	arg_types := make([]types.Type_Id, count, escape.allocator) or_return
	given := make([]bool, count, escape.allocator) or_return
	for argument in call.arguments {
		index := -1
		for parameter, position in checked.parameters {
			if parameter == argument.parameter { index = position; break }
		}
		if index < 0 {
			escape_visit_argument(escape, argument) or_return
			continue
		}
		involved := false
		for flow in flows {
			if flow.param == index { involved = true }
			switch flow.target {
			case .Pointee, .Loaded, .Deep:
				involved |= flow.target_index == index
			case .Result, .Outer:
			}
		}
		if !involved {
			escape_visit_argument(escape, argument) or_return
			continue
		}
		given[index] = true
		arg_types[index] = escape.run.program.entities[argument.parameter].type
		if argument.variadic_pack {
			args[index] = escape_pack_variadic(escape, expression, argument) or_return
			continue
		}
		value := escape_operand(escape, argument.value) or_return
		source: check.Expression_Ref
		if operand, is_expression := argument.value.(check.Expression_Ref); is_expression { source = operand }
		if argument.conversion != 0 { value = escape_conversion(escape, argument.conversion, value, source) or_return }
		if source.node != 0 { arg_types[index] = check.expression_info(escape.run.program, source.view, source.node).type }
		args[index] = value
	}
	results := make([]Value_Id, len(checked.results), escape.allocator) or_return
	for flow in flows {
		if flow.param < 0 || flow.param >= count || !given[flow.param] { continue }
		value, value_type := escape_flow_source(escape, flow, args[flow.param], arg_types[flow.param]) or_return
		switch flow.target {
		case .Result:
			if flow.target_index < 0 || flow.target_index >= len(results) { continue }
			result_type: types.Type_Id
			if flow.target_index < len(checked.results) { result_type = escape.run.program.entities[checked.results[flow.target_index]].type }
			steps := escape_path_steps(escape, flow.target_path) or_return
			result_type = escape_type_follow(escape, result_type, steps[:])
			if value_type != 0 && result_type != 0 && !types.are_identical(escape.run.program.type_data, value_type, result_type) {
				value = escape_pointer_offset(escape, expression, value, 0) or_return
			}
			results[flow.target_index] = escape_place_facts(escape, results[flow.target_index], flow.target_path, value) or_return
		case .Pointee, .Loaded, .Deep:
			if flow.target_index < 0 || flow.target_index >= count || !given[flow.target_index] { continue }
			pointer, pointee := escape_arg_pointers(escape, expression, args[flow.target_index], arg_types[flow.target_index], flow.target_path) or_return
			if flow.target != .Pointee {
				pointer = escape_load_once(escape, expression, pointer) or_return
				pointer = escape_pointer_offset(escape, expression, pointer, 0) or_return
			} else if value_type != 0 && pointee != 0 && !types.are_identical(escape.run.program.type_data, value_type, pointee) {
				value = escape_pointer_offset(escape, expression, value, 0) or_return
			}
			if flow.target == .Deep { pointer = escape_reachable(escape, expression, pointer) or_return }
			if flow.value_path != 0 {
				escape_store_loaded(escape, expression.node, pointer, value, flow.value_path) or_return
			} else {
				escape_store_at(escape, expression.node, pointer, value, false) or_return
			}
		case .Outer:
			outer := escape_origin_value(escape, expression, {kind = .Outer}) or_return
			escape_store_at(escape, expression.node, outer, value, false) or_return
		}
	}
	if len(results) == 1 { result = results[0] } else if len(results) > 1 { result = escape_tuple_results(escape, expression, results) or_return }
	result_type := check.expression_info(escape.run.program, expression.view, expression.node).type
	if result_type == 0 || result != 0 && escape_plain(escape, result_type) { return 0, nil }
	return
}

@(private = "file")
escape_visit_argument :: proc(escape: ^Escape, argument: check.Call_Argument) -> runtime.Allocator_Error {
	if argument.variadic_pack {
		for element in argument.variadic_elements { escape_operand(escape, element) or_return }
		return nil
	}
	escape_operand(escape, argument.value) or_return
	return nil
}

@(private = "file")
escape_pack_variadic :: proc(
	escape: ^Escape,
	expression: check.Expression_Ref,
	argument: check.Call_Argument,
) -> (
	result: Value_Id,
	err: runtime.Allocator_Error,
) {
	object := escape_object(escape, 0, expression) or_return
	path := escape_path(escape, 0, {kind = .Element}) or_return
	for element, index in argument.variadic_elements {
		value := escape_operand(escape, element) or_return
		source: check.Expression_Ref
		if operand, is_expression := element.(check.Expression_Ref); is_expression { source = operand }
		if index < len(argument.variadic_conversions) && argument.variadic_conversions[index] != 0 {
			value = escape_conversion(escape, argument.variadic_conversions[index], value, source) or_return
		}
		escape_store_memory(escape, object, path, value, false) or_return
	}
	return escape_origin_value(escape, expression, {kind = .Temporary, object = object, path = path})
}

@(private = "file")
escape_flow_source :: proc(
	escape: ^Escape,
	flow: Flow,
	arg: Value_Id,
	arg_type: types.Type_Id,
) -> (
	value: Value_Id,
	value_type: types.Type_Id,
	err: runtime.Allocator_Error,
) {
	steps := escape_path_steps(escape, flow.param_path) or_return
	deref := len(steps)
	for step, index in steps {
		if step.kind == .Dereference { deref = index; break }
	}
	if flow.kind == .Value && deref == len(steps) {
		value = escape_project(escape, {}, arg, flow.param_path) or_return
		value_type = escape_type_follow(escape, arg_type, steps[:])
		return
	}
	pointee: types.Type_Id
	value, pointee = escape_arg_pointers(escape, {}, arg, arg_type, flow.param_path) or_return
	if flow.kind == .Value { return value, pointee, nil }
	if pointee != 0 && !escape_has_pointers(escape, pointee) { return 0, 0, nil }
	value = escape_load_once(escape, {}, value) or_return
	value_type = pointee
	if pointee == 0 { value = escape_pointer_offset(escape, {}, value, 0) or_return }
	return
}

@(private = "file")
escape_arg_pointers :: proc(
	escape: ^Escape,
	expression: check.Expression_Ref,
	arg: Value_Id,
	arg_type: types.Type_Id,
	path: Path_Id,
) -> (
	result: Value_Id,
	pointee: types.Type_Id,
	err: runtime.Allocator_Error,
) {
	steps := escape_path_steps(escape, path) or_return
	deref := len(steps)
	for step, index in steps {
		if step.kind == .Dereference { deref = index; break }
	}
	value_path := escape_path_from(escape, steps[:deref]) or_return
	offset: Path_Id
	offset_steps: []Path_Step
	if deref < len(steps) { offset_steps = steps[deref + 1:] }
	offset = escape_path_from(escape, offset_steps) or_return
	inner := escape_type_follow(escape, arg_type, steps[:deref])
	pointee = escape_pointee_type(escape, inner)
	if len(offset_steps) > 0 {
		followed := escape_type_follow(escape, pointee, offset_steps)
		if followed == 0 { offset = 0 } else { pointee = followed }
	}
	projected := escape_project(escape, expression, arg, value_path) or_return
	projected = escape_pointer_offset(escape, expression, projected, 0) or_return
	result = escape_pointer_offset(escape, expression, projected, offset) or_return
	return
}

@(private = "file")
escape_pointee_type :: proc(escape: ^Escape, type: types.Type_Id) -> types.Type_Id {
	if type == 0 { return 0 }
	descriptor := escape_type(escape, type)
	#partial switch descriptor.kind {
	case .Pointer, .Multi_Pointer, .Soa_Pointer, .Slice:
		return descriptor.elem
	}
	return 0
}

@(private = "package")
escape_type_follow :: proc(escape: ^Escape, type: types.Type_Id, steps: []Path_Step) -> types.Type_Id {
	current := type
	for step in steps {
		if current == 0 { return 0 }
		descriptor := escape_type(escape, current)
		switch step.kind {
		case .Field:
			if descriptor.kind != .Struct || int(step.field_index) >= len(descriptor.fields) { return 0 }
			current = descriptor.fields[step.field_index].type
		case .Element:
			#partial switch descriptor.kind {
			case .Array, .Enumerated_Array, .Fixed_Capacity_Array, .Slice, .Dynamic_Array, .Multi_Pointer, .Map:
				current = descriptor.elem
			case:
				return 0
			}
		case .Dereference:
			#partial switch descriptor.kind {
			case .Pointer, .Multi_Pointer, .Soa_Pointer:
				current = descriptor.elem
			case:
				return 0
			}
		}
	}
	return current
}

@(private = "file")
escape_load_once :: proc(escape: ^Escape, expression: check.Expression_Ref, pointer: Value_Id) -> (result: Value_Id, err: runtime.Allocator_Error) {
	facts := make([dynamic]Value_Fact, 0, escape.allocator) or_return
	element := escape_path(escape, 0, {kind = .Element}) or_return
	for fact in escape_facts(escape, pointer) {
		origin := fact.origin
		#partial switch origin.kind {
		case .Local, .Temporary, .Owned:
			steps := escape_path_steps(escape, origin.path) or_return
			at := escape_type_follow(escape, escape.graph.objects[origin.object].type, steps[:])
			kind: types.Kind
			if at != 0 { kind = escape_type(escape, at).kind }
			parameter :=
				origin.kind == .Local &&
				escape.graph.objects[origin.object].entity != 0 &&
				escape_parameter(escape, escape.graph.objects[origin.object].entity)
			if (kind == .Dynamic_Array || kind == .Map) && !parameter {
				origin.kind = .Owned
				origin.path = escape_path_concat(escape, origin.path, element) or_return
				escape_add_fact(&facts, {origin = origin}) or_return
				continue
			}
		}
		single := escape_value(escape, .Copy, expression, []Value_Fact{fact}) or_return
		for loaded in escape_facts(escape, escape_load(escape, expression, single, 0) or_return) { escape_add_fact(&facts, loaded) or_return }
	}
	return escape_value(escape, .Load, expression, facts[:], []Value_Id{pointer})
}

@(private = "file")
escape_reachable :: proc(escape: ^Escape, expression: check.Expression_Ref, pointer: Value_Id) -> (result: Value_Id, err: runtime.Allocator_Error) {
	reached := make([dynamic]Value_Fact, 0, escape.allocator) or_return
	frontier := escape_pointer_offset(escape, expression, pointer, 0) or_return
	for len(escape_facts(escape, frontier)) > 0 {
		next := make([dynamic]Value_Fact, 0, escape.allocator) or_return
		loaded := escape_load_once(escape, expression, frontier) or_return
		for fact in escape_facts(escape, loaded) {
			before := len(reached)
			escape_add_fact(&reached, {origin = fact.origin}) or_return
			if len(reached) != before { escape_add_fact(&next, {origin = fact.origin}) or_return }
		}
		frontier = escape_value(escape, .Load, expression, next[:]) or_return
	}
	return escape_value(escape, .Load, expression, reached[:], []Value_Id{pointer})
}

@(private = "file")
escape_store_loaded :: proc(escape: ^Escape, node: syntax.Node_Index, pointer, value: Value_Id, value_path: Path_Id) -> runtime.Allocator_Error {
	within := make([dynamic]Value_Fact, 0, escape.allocator) or_return
	for fact in escape_facts(escape, value) {
		fact := fact
		fact.path = escape_path_concat(escape, value_path, fact.path) or_return
		escape_add_fact(&within, fact) or_return
	}
	stored := escape_value(escape, .Copy, {}, within[:]) or_return
	steps := escape_path_steps(escape, value_path) or_return
	for fact in escape_facts(escape, pointer) {
		fits := true
		#partial switch fact.origin.kind {
		case .Local, .Temporary, .Owned:
			at_steps := escape_path_steps(escape, fact.origin.path) or_return
			at := escape_type_follow(escape, escape.graph.objects[fact.origin.object].type, at_steps[:])
			fits = escape_type_follow(escape, at, steps[:]) != 0
		}
		single := escape_value(escape, .Copy, {}, []Value_Fact{fact}) or_return
		escape_store_at(escape, node, single, stored if fits else value, false) or_return
	}
	return nil
}

@(private = "file")
escape_place_facts :: proc(escape: ^Escape, existing: Value_Id, path: Path_Id, value: Value_Id) -> (result: Value_Id, err: runtime.Allocator_Error) {
	facts := make([dynamic]Value_Fact, 0, escape.allocator) or_return
	if existing != 0 { append(&facts, ..escape_facts(escape, existing)) or_return }
	for fact in escape_facts(escape, value) {
		fact := fact
		fact.path = escape_path_concat(escape, path, fact.path) or_return
		escape_add_fact(&facts, fact) or_return
	}
	return escape_value(escape, .Call_Result, {}, facts[:])
}

@(private = "file")
escape_tuple_results :: proc(escape: ^Escape, expression: check.Expression_Ref, results: []Value_Id) -> (result: Value_Id, err: runtime.Allocator_Error) {
	info := check.expression_info(escape.run.program, expression.view, expression.node)
	if info.type == 0 { return }
	owner := types.resolve_named(escape.run.program.type_data, info.type)
	facts := make([dynamic]Value_Fact, 0, escape.allocator) or_return
	for value, index in results {
		path := escape_path(escape, 0, {kind = .Field, owner_type = owner, field_index = u32(index)}) or_return
		for fact in escape_facts(escape, value) {
			fact := fact
			fact.path = escape_path_concat(escape, path, fact.path) or_return
			escape_add_fact(&facts, fact) or_return
		}
	}
	return escape_value(escape, .Call_Result, expression, facts[:])
}

@(private = "file")
escape_procedure_target :: proc(escape: ^Escape, entity: check.Entity_Id) -> Procedure_Id {
	entity := entity
	program := escape.run.program
	for _ in 0 ..< 8 {
		if entity == 0 || int(entity) >= len(escape.call_graph.procedure_of_entity) { return 0 }
		if target := escape.call_graph.procedure_of_entity[entity]; target != 0 { return target }
		alias := program.entities[entity].alias
		if alias == 0 || alias == entity { return 0 }
		entity = alias
	}
	return 0
}

@(private = "package")
escape_analyse_program :: proc(escape: ^Escape, options: Options) -> runtime.Allocator_Error {
	summaries := make([][]Flow, len(escape.run.procedures), escape.run.allocator) or_return
	escape.summaries = summaries
	order := escape.call_graph.order
	component := escape.call_graph.component
	index := 0
	for index < len(order) {
		id := order[index]
		if id == 0 { index += 1; continue }
		end := index + 1
		for end < len(order) && component[order[end]] == component[id] { end += 1 }
		members := order[index:end]
		recursive := len(members) > 1
		if !recursive {
			for callee in adjacent(escape.call_graph.calls, id) {
				if callee == id { recursive = true }
			}
		}
		if !recursive {
			escape_analyse_one(escape, id, options) or_return
			summaries[id] = escape_flow_slice(escape) or_return
		} else {
			escape_analyse_group(escape, members, options) or_return
		}
		index = end
	}
	return nil
}

@(private = "file")
escape_analyse_one :: proc(escape: ^Escape, id: Procedure_Id, options: Options) -> runtime.Allocator_Error {
	reports := escape_report_list(escape)
	first_report := len(reports^)
	escape.calls_unknown = false
	escape_analyse_procedure(escape, id, options) or_return
	if escape.too_large {
		resize(reports, first_report) or_return
		escape.calls_unknown = true
		escape_analyse_procedure(escape, id, options) or_return
	}
	for &report in (reports^)[first_report:] {
		report.reason = strings.clone(report.reason, escape.run.allocator) or_return
	}
	return nil
}

@(private = "file")
escape_analyse_procedure :: proc(escape: ^Escape, id: Procedure_Id, options: Options) -> runtime.Allocator_Error {
	escape_reset_graph(escape) or_return
	checked := escape.run.program.procedure_list[escape.run.procedures[id].checked_index]
	file := &escape.run.program.files[checked.body.file]
	enabled := file.ast != nil && .Escape in file.ast.analysis
	entry := !options.no_entry_point && !options.test && checked.entity == options.entry_point
	escape.muted = !enabled || entry
	escape.nil_deref = enabled && .Nil_Deref in file.ast.vet
	escape.uninit_vet = enabled && .Uninitialized in file.ast.vet
	escape_reset_control(escape)
	escape.procedure = id
	escape.view = checked.view
	escape.variadic = 0
	descriptor := escape_type(escape, checked.signature)
	if descriptor.variadic && !descriptor.c_vararg {
		if data, ok := escape.run.program.entities[checked.entity].data.(check.Procedure_Data); ok {
			if data.variadic_index >= 0 && data.variadic_index < len(checked.parameters) { escape.variadic = checked.parameters[data.variadic_index] }
		}
	}
	escape_statement(escape, checked.body.node) or_return
	escape_finish_procedure(escape, checked.body.node) or_return
	return nil
}

@(private = "file")
escape_flow_slice :: proc(escape: ^Escape) -> (flows: []Flow, err: runtime.Allocator_Error) {
	flows = make([]Flow, len(escape.flows), escape.run.allocator) or_return
	copy(flows, escape.flows[:])
	return
}

@(private = "file")
escape_flows_same :: proc(left, right: []Flow) -> bool {
	if len(left) != len(right) { return false }
	for flow in left {
		found := false
		for other in right { if flow == other { found = true; break } }
		if !found { return false }
	}
	return true
}

@(private = "file")
escape_analyse_group :: proc(escape: ^Escape, members: []Procedure_Id, options: Options) -> runtime.Allocator_Error {
	stale := make([]bool, len(members), escape.run.allocator) or_return
	fresh := make([][]Flow, len(members), escape.run.allocator) or_return
	buffers := make([][dynamic]Diagnostic, len(members), escape.run.allocator) or_return
	for index in 0 ..< len(members) {
		stale[index] = true
		buffers[index] = make([dynamic]Diagnostic, 0, escape.run.allocator) or_return
	}
	for _ in 0 ..< 3 {
		ran := make([]bool, len(members), escape.run.allocator) or_return
		for member, index in members {
			if !stale[index] { continue }
			clear(&buffers[index])
			escape.reports = &buffers[index]
			escape_analyse_one(escape, member, options) or_return
			fresh[index] = escape_flow_slice(escape) or_return
			ran[index] = true
		}
		escape.reports = nil
		for index in 0 ..< len(stale) { stale[index] = false }
		for member, index in members {
			if !ran[index] || escape_flows_same(escape.summaries[member], fresh[index]) { continue }
			escape.summaries[member] = fresh[index]
			for caller in adjacent(escape.call_graph.callers, member) {
				for other, other_index in members {
					if other == caller { stale[other_index] = true }
				}
			}
		}
		settled := true
		for pending in stale { settled &&= !pending }
		if settled { break }
	}
	for buffer in buffers { append(&escape.run.diagnostics, ..buffer[:]) or_return }
	return nil
}
