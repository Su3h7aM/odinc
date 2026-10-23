package analysis

import "base:runtime"
import "oc:check"
import "oc:syntax"
import "oc:types"

@(private = "package")
escape_operand :: proc(escape: ^Escape, operand: check.Operand) -> (result: Value_Id, err: runtime.Allocator_Error) {
	switch value in operand {
	case check.Expression_Ref:
		return escape_expression(escape, value)
	case check.Entity_Id:
		return escape_ident_value(escape, {}, value)
	case check.Projection:
		if value.index == 0 { return escape_expression(escape, value.expression) }
	case check.Const_Id:
	}
	return
}

@(private = "package")
escape_store_operand :: proc(escape: ^Escape, operand: check.Operand, value: Value_Id) -> runtime.Allocator_Error {
	entity: check.Entity_Id
	switch destination in operand {
	case check.Entity_Id:
		entity = destination
	case check.Expression_Ref:
		file := escape.run.program.files[escape.run.program.typed_views[destination.view].file]
		if file.ast.nodes[destination.node].kind == .Ident {
			info := check.expression_info(escape.run.program, destination.view, destination.node)
			if info.plan == 0 { entity = info.entity }
		}
	case check.Projection, check.Const_Id:
	}
	if escape_local(escape, entity) {
		if value == 0 && escape_plain(escape, escape.run.program.entities[entity].type) { return nil }
		object := escape_object(escape, entity) or_return
		escape_store_memory(escape, object, 0, value) or_return
		return nil
	}
	address := escape_operand_address(escape, operand) or_return
	return escape_store_through(escape, address, value)
}

@(private = "package")
escape_operand_address :: proc(escape: ^Escape, operand: check.Operand) -> (result: Value_Id, err: runtime.Allocator_Error) {
	switch value in operand {
	case check.Expression_Ref:
		return escape_address(escape, value)
	case check.Entity_Id:
		return escape_ident_address(escape, {}, value)
	case check.Projection, check.Const_Id:
	}
	return
}

@(private = "package")
escape_operand_type :: proc(escape: ^Escape, operand: check.Operand) -> types.Type_Id {
	switch value in operand {
	case check.Expression_Ref:
		return check.expression_info(escape.run.program, value.view, value.node).type
	case check.Entity_Id:
		return escape.run.program.entities[value].type
	case check.Const_Id:
		if constant := check.constant(escape.run.program, value); constant != nil { return constant.type }
	case check.Projection:
		info := check.expression_info(escape.run.program, value.expression.view, value.expression.node)
		type := escape_type(escape, info.type)
		if type.kind == .Tuple && int(value.index) < len(type.params) { return type.params[value.index] }
	}
	return 0
}

@(private = "package")
escape_box :: proc(
	escape: ^Escape,
	expression: check.Expression_Ref,
	value: Value_Id,
	addressable: bool,
	source_type: types.Type_Id = 0,
) -> (
	result: Value_Id,
	err: runtime.Allocator_Error,
) {
	if expression.node == 0 { return }
	info := check.expression_info(escape.run.program, expression.view, expression.node)
	kind := escape_type(escape, source_type if source_type != 0 else info.type).kind
	if kind == .Any || kind == .Untyped_Nil { return value, nil }
	if addressable && (info.entity == 0 || !escape_parameter(escape, info.entity)) { return escape_address(escape, expression) }
	object := escape_object(escape, 0, expression) or_return
	if source_type != 0 { escape.graph.objects[object].type = source_type }
	escape_store_memory(escape, object, 0, value) or_return
	return escape_origin_value(escape, expression, {kind = .Temporary, object = object})
}

@(private = "package")
escape_conversion :: proc(
	escape: ^Escape,
	plan: check.Plan_Id,
	value: Value_Id,
	expression: check.Expression_Ref = {},
) -> (
	result: Value_Id,
	err: runtime.Allocator_Error,
) {
	if plan == 0 { return value, nil }
	conversion, ok := check.plan(escape.run.program, plan)^.(check.Conversion_Plan)
	if !ok { return value, nil }
	if conversion.kind == .Transmute { return }
	if conversion.kind != .Box { return value, nil }
	if conversion.explicit_box { return value, nil }
	source_type := conversion.source_type
	if source_type == 0 { source_type = escape_operand_type(escape, conversion.source) }
	if source, is_expression := conversion.source.(check.Expression_Ref); is_expression {
		return escape_box(escape, source, value, conversion.source_addressable, source_type)
	}
	if expression.node != 0 { return escape_box(escape, expression, value, conversion.source_addressable, source_type) }
	return value, nil
}

@(private = "package")
escape_convert :: proc(
	escape: ^Escape,
	expression: check.Expression_Ref,
	value: Value_Id,
	target: types.Type_Id,
) -> (
	result: Value_Id,
	err: runtime.Allocator_Error,
) {
	if escape_type(escape, target).kind != .Any { return value, nil }
	info := check.expression_info(escape.run.program, expression.view, expression.node)
	return escape_box(escape, expression, value, info.mode == .Variable)
}

@(private = "package")
escape_member_address :: proc(escape: ^Escape, expression: check.Expression_Ref, place: check.Place_Plan) -> (result: Value_Id, err: runtime.Allocator_Error) {
	if len(place.path) == 0 { return escape_operand_address(escape, place.root) }
	root_type := escape_operand_type(escape, place.root)
	if escape_type(escape, root_type).kind ==
	   .Pointer { result = escape_operand(escape, place.root) or_return } else { result = escape_operand_address(escape, place.root) or_return }
	for step, index in place.path {
		if index != 0 && step.indirect { result = escape_load(escape, expression, result, 0) or_return }
		path: Path_Id
		if !escape_type(escape, step.type).raw_union { path = escape_path(escape, 0, {kind = .Field, owner_type = types.resolve_named(escape.run.program.type_data, step.type), field_index = step.field_index}) or_return }
		result = escape_pointer_offset(escape, expression, result, path) or_return
	}
	return
}

@(private = "package")
escape_member_value :: proc(escape: ^Escape, expression: check.Expression_Ref, place: check.Place_Plan) -> (result: Value_Id, err: runtime.Allocator_Error) {
	result = escape_operand(escape, place.root) or_return
	root_pointer := escape_type(escape, escape_operand_type(escape, place.root)).kind == .Pointer
	for step, index in place.path {
		descriptor := escape_type(escape, step.type)
		path: Path_Id
		if !descriptor.raw_union { path = escape_path(escape, 0, {kind = .Field, owner_type = types.resolve_named(escape.run.program.type_data, step.type), field_index = step.field_index}) or_return }
		if index == 0 && root_pointer || index != 0 && step.indirect {
			result = escape_pointer_offset(escape, expression, result, path) or_return
			field_type: types.Type_Id
			if int(step.field_index) < len(descriptor.fields) { field_type = descriptor.fields[step.field_index].type }
			result = escape_load(escape, expression, result, field_type) or_return
		} else { result = escape_project(escape, expression, result, path) or_return }
	}
	return
}

@(private = "package")
escape_address :: proc(escape: ^Escape, expression: check.Expression_Ref) -> (result: Value_Id, err: runtime.Allocator_Error) {
	if expression.node == 0 { return }
	file := &escape.run.program.files[escape.run.program.typed_views[expression.view].file]
	ast := file.ast
	info := check.expression_info(escape.run.program, expression.view, expression.node)
	if info.plan != 0 {
		if place, ok := check.plan(escape.run.program, info.plan)^.(check.Place_Plan); ok { return escape_member_address(escape, expression, place) }
	}
	#partial switch payload in ast.nodes[expression.node].payload {
	case syntax.Paren_Expr:
		return escape_address(escape, {expression.view, payload.expr})
	case syntax.Ident:
		return escape_ident_address(escape, expression, info.entity)
	case syntax.Selector_Expr:
		return escape_ident_address(escape, expression, info.entity)
	case syntax.Index_Expr:
		return escape_elements(escape, {expression.view, payload.expr})
	case syntax.Matrix_Index_Expr:
		base := escape_address(escape, {expression.view, payload.expr}) or_return
		path := escape_path(escape, 0, {kind = .Element}) or_return
		return escape_pointer_offset(escape, expression, base, path)
	case syntax.Deref_Expr:
		base := escape_expression(escape, {expression.view, payload.expr}) or_return
		return escape_pointer_offset(escape, expression, base, 0)
	case syntax.Comp_Lit:
		value := escape_expression(escape, expression) or_return
		object := escape_object(escape, 0, expression) or_return
		escape_store_memory(escape, object, 0, value) or_return
		return escape_origin_value(escape, expression, {kind = .Temporary, object = object})
	}
	return
}

@(private = "package")
escape_elements :: proc(escape: ^Escape, expression: check.Expression_Ref) -> (result: Value_Id, err: runtime.Allocator_Error) {
	info := check.expression_info(escape.run.program, expression.view, expression.node)
	descriptor := escape_type(escape, info.type)
	if descriptor.kind == .Slice ||
	   descriptor.kind == .Multi_Pointer ||
	   descriptor.kind == .String ||
	   descriptor.kind == .String16 ||
	   descriptor.kind == .CString ||
	   descriptor.kind == .CString16 {
		value := escape_expression(escape, expression) or_return
		return escape_pointer_offset(escape, expression, value, 0)
	}
	if descriptor.kind ==
	   .Pointer { result = escape_expression(escape, expression) or_return; descriptor = escape_type(escape, descriptor.elem) } else { result = escape_address(escape, expression) or_return }
	path := escape_path(escape, 0, {kind = .Element}) or_return
	#partial switch descriptor.kind {
	case .Array, .Enumerated_Array, .Fixed_Capacity_Array, .Matrix:
		return escape_pointer_offset(escape, expression, result, path)
	case .Slice, .Multi_Pointer, .String, .String16, .CString, .CString16:
		loaded := escape_load(escape, expression, result, info.type) or_return
		return escape_pointer_offset(escape, expression, loaded, 0)
	case .Dynamic_Array, .Map:
		facts := make([dynamic]Value_Fact, 0, escape.run.allocator) or_return
		for fact in escape_facts(escape, result) {
			fact := fact
			fact.path = 0
			#partial switch fact.origin.kind {
			case .Local, .Temporary, .Owned:
				object := escape.graph.objects[fact.origin.object]
				if object.entity != 0 && escape_parameter(escape, object.entity) { fact.origin.kind = .Parameter } else {
					fact.origin.kind = .Owned
					fact.origin.path = escape_path_concat(escape, fact.origin.path, path) or_return
				}
			case .Parameter, .Parameter_Load, .Parameter_Deep:
				fact.origin.kind = .Parameter_Load if fact.origin.kind == .Parameter else .Parameter_Deep
				fact.origin.offset_lost = false
			}
			escape_add_fact(&facts, fact) or_return
		}
		return escape_value(escape, .Project, expression, facts[:], []Value_Id{result})
	}
	return 0, nil
}

@(private = "file")
escape_aggregate :: proc(escape: ^Escape, expression: check.Expression_Ref, info: check.Expression_Info) -> (result: Value_Id, err: runtime.Allocator_Error) {
	if info.plan == 0 { return }
	descriptor := escape_type(escape, info.type)
	plan := check.plan(escape.run.program, info.plan)^
	aggregate: check.Aggregate_Plan
	#partial switch value in plan {
	case check.Aggregate_Plan:
		aggregate = value
	case check.Slice_Literal_Plan:
		aggregate = value.backing
	case check.Dynamic_Array_Literal_Plan:
		aggregate = value.backing
	case check.Map_Literal_Plan:
		aggregate = {
			type        = value.type,
			values      = value.values,
			conversions = value.value_conversions,
		}
	}
	facts := make([dynamic]Value_Fact, 0, escape.run.allocator) or_return
	inputs := make([dynamic]Value_Id, 0, escape.run.allocator) or_return
	ast := escape.run.program.files[escape.run.program.typed_views[expression.view].file].ast
	literal := syntax.node_payload(ast, expression.node, syntax.Comp_Lit)
	elements := syntax.node_list(ast, literal.elems)
	for operand, index in aggregate.values {
		value := escape_operand(escape, operand) or_return
		source: check.Expression_Ref
		if expression_operand, is_expression := operand.(check.Expression_Ref); is_expression {
			source = expression_operand
		} else if index < len(elements) {
			source = {expression.view, elements[index]}
			if ast.nodes[source.node].kind == .Field_Value { source.node = syntax.node_payload(ast, source.node, syntax.Field_Value).value }
		}
		if index < len(aggregate.conversions) { value = escape_conversion(escape, aggregate.conversions[index], value, source) or_return }
		append(&inputs, value) or_return
		path: Path_Id
		if descriptor.kind == .Struct && !descriptor.raw_union {
			if index < len(aggregate.field_paths) && len(aggregate.field_paths[index]) != 0 {
				for step in aggregate.field_paths[index] { path = escape_path(escape, path, {kind = .Field, owner_type = types.resolve_named(escape.run.program.type_data, step.type), field_index = step.field_index}) or_return }
			} else if index <
			   len(
				   aggregate.field_indices,
			   ) { path = escape_path(escape, 0, {kind = .Field, owner_type = types.resolve_named(escape.run.program.type_data, info.type), field_index = aggregate.field_indices[index]}) or_return }
		} else if descriptor.kind == .Array ||
		   descriptor.kind == .Enumerated_Array ||
		   descriptor.kind == .Fixed_Capacity_Array ||
		   descriptor.kind == .Slice ||
		   descriptor.kind == .Dynamic_Array ||
		   descriptor.kind == .Map { path = escape_path(escape, 0, {kind = .Element}) or_return }
		for fact in escape_facts(escape, value) {
			fact := fact
			fact.path = escape_path_concat(escape, path, fact.path) or_return
			escape_add_fact(&facts, fact) or_return
		}
	}
	result = escape_value(escape, .Aggregate, expression, facts[:], inputs[:]) or_return
	if descriptor.kind == .Slice {
		if len(aggregate.values) == 0 { return 0, nil }
		object := escape_object(escape, 0, expression) or_return
		escape_store_memory(escape, object, 0, result) or_return
		path := escape_path(escape, 0, {kind = .Element}) or_return
		return escape_origin_value(escape, expression, {kind = .Temporary, object = object, path = path})
	}
	return
}

@(private = "package")
escape_expression :: proc(escape: ^Escape, expression: check.Expression_Ref) -> (result: Value_Id, err: runtime.Allocator_Error) {
	if expression.node == 0 { return }
	program := escape.run.program
	file := &program.files[program.typed_views[expression.view].file]
	ast := file.ast
	info := check.expression_info(program, expression.view, expression.node)
	if info.state == .Inactive || info.state == .Invalid { return }
	escape_note_expression(escape, expression) or_return
	#partial switch early in ast.nodes[expression.node].payload {
	case syntax.Or_Return_Expr:
		value := escape_expression(escape, {expression.view, early.expr}) or_return
		escape_or_return(escape, expression.node) or_return
		return value, nil
	case syntax.Or_Branch_Expr:
		value := escape_expression(escape, {expression.view, early.expr}) or_return
		saved := escape_capture(escape) or_return
		kind: syntax.Token_Kind = .Break if early.token.kind == .Or_Break else .Continue
		escape_branch(escape, early.label, kind) or_return
		escape_restore(escape, saved) or_return
		return value, nil
	case syntax.Ternary_Expr:
		escape_expression(escape, {expression.view, early.cond}) or_return
		left := escape_expression(escape, {expression.view, early.x}) or_return
		right := escape_expression(escape, {expression.view, early.y}) or_return
		merged, _ := escape_union_values(escape, left, right) or_return
		return merged, nil
	case syntax.Or_Else_Expr:
		left := escape_expression(escape, {expression.view, early.x}) or_return
		right := escape_expression(escape, {expression.view, early.y}) or_return
		merged, _ := escape_union_values(escape, left, right) or_return
		return merged, nil
	}
	if info.type == 0 { return }
	if upstream_constant(program, expression, info) {
		if escape_type(escape, info.type).kind != .Slice { return }
		#partial switch payload in ast.nodes[expression.node].payload {
		case syntax.Comp_Lit:
			if payload.elems.count == 0 { return }
		case syntax.Call_Expr:
			if ast.nodes[payload.expr].kind == .Basic_Directive {
				span := ast.nodes[payload.expr]
				if string(file.source[span.start:span.end]) == "#load" { return }
			}
		}
		object := escape_object(escape, 0, expression) or_return
		path := escape_path(escape, 0, {kind = .Element}) or_return
		return escape_origin_value(escape, expression, {kind = .Temporary, object = object, path = path})
	}
	if escape_plain(escape, info.type) { return }
	#partial switch payload in ast.nodes[expression.node].payload {
	case syntax.Paren_Expr:
		return escape_expression(escape, {expression.view, payload.expr})
	case syntax.Ident:
		return escape_ident_value(escape, expression, info.entity)
	case syntax.Comp_Lit:
		return escape_aggregate(escape, expression, info)
	case syntax.Unary_Expr:
		if payload.op.kind == .And { return escape_address(escape, {expression.view, payload.expr}) }
	case syntax.Selector_Expr:
		if info.entity != 0 && .Field not_in program.entities[info.entity].flags { return escape_ident_value(escape, expression, info.entity) }
		if info.plan != 0 {
			if place, ok := check.plan(program, info.plan)^.(check.Place_Plan); ok { return escape_member_value(escape, expression, place) }
		}
	case syntax.Deref_Expr:
		pointer := escape_expression(escape, {expression.view, payload.expr}) or_return
		return escape_load(escape, expression, pointer, info.type)
	case syntax.Slice_Expr:
		return escape_elements(escape, {expression.view, payload.expr})
	case syntax.Index_Expr:
		base := check.Expression_Ref{expression.view, payload.expr}
		base_info := check.expression_info(program, base.view, base.node)
		kind := escape_type(escape, base_info.type).kind
		if kind == .Array || kind == .Enumerated_Array || kind == .Fixed_Capacity_Array || kind == .Dynamic_Array || kind == .Map {
			value := escape_expression(escape, base) or_return
			path := escape_path(escape, 0, {kind = .Element}) or_return
			return escape_project(escape, expression, value, path)
		}
		pointer := escape_elements(escape, base) or_return
		return escape_load(escape, expression, pointer, info.type)
	case syntax.Call_Expr:
		arguments := syntax.node_list(ast, payload.args)
		callee := check.expression_info(program, expression.view, payload.expr)
		if callee.mode == .Type && len(arguments) == 1 {
			value := escape_expression(escape, {expression.view, arguments[0]}) or_return
			kind := escape_type(escape, info.type).kind
			if kind == .Raw_Pointer || kind == .Integer && types.get(program.type_data, info.type).name == "uintptr" { return }
			return escape_convert(escape, {expression.view, arguments[0]}, value, info.type)
		}
		if callee.entity != 0 && program.entities[callee.entity].kind == .Builtin && len(arguments) > 0 {
			name := program.entities[callee.entity].name
			if name == "raw_data" { return escape_elements(escape, {expression.view, arguments[0]}) }
			if name == "ptr_offset" { return escape_expression(escape, {expression.view, arguments[0]}) }
		}
		return escape_value(escape, .Call_Result, expression)
	case syntax.Selector_Call_Expr:
		return escape_expression(escape, {expression.view, payload.call})
	case syntax.Type_Cast:
		kind := escape_type(escape, info.type).kind
		if payload.token.kind == .Transmute || kind == .Raw_Pointer || kind == .Integer && types.get(program.type_data, info.type).name == "uintptr" { return }
		value := escape_expression(escape, {expression.view, payload.expr}) or_return
		return escape_convert(escape, {expression.view, payload.expr}, value, info.type)
	case syntax.Auto_Cast:
		value := escape_expression(escape, {expression.view, payload.expr}) or_return
		return escape_convert(escape, {expression.view, payload.expr}, value, info.type)
	case syntax.Field_Value:
		return escape_expression(escape, {expression.view, payload.value})
	case syntax.Tag_Expr:
		return escape_expression(escape, {expression.view, payload.expr})
	}
	return
}
