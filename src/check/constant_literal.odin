package check

import "oc:syntax"
import "oc:types"

// Whether the official checker gives an expression the mode Addressing_Constant: a constant, a constant compound literal,
// or a cast of such an operand that stays constant (check_cast_internal, check_expr.cpp:4191-4228: a cast to `any`, a
// union that can be constant or a non-array type keeps it; a string to a slice or a union that cannot be constant does not).
// Published modes keep literals and boxed casts as values, so analysis asks here; lowering is unaffected.
addressing_constant :: proc(program: ^Checked_Program, view: View_Id, node: syntax.Node_Index) -> bool {
	if node == 0 || view <= 0 || int(view) >= len(program.typed_views) { return false }
	ast := program.files[program.typed_views[view].file].ast
	current := node
	for ast.nodes[current].kind == .Paren_Expr { current = syntax.node_payload(ast, current, syntax.Paren_Expr).expr }
	info := expression_info(program, view, current)
	if info.state != .Checked { return false }
	if info.mode == .Constant { return true }
	if (info.mode == .Immutable_Value || info.mode == .Variable) &&
	   info.entity != 0 &&
	   .Demoted_Constant in program.entities[info.entity].flags { return true }
	operand: syntax.Node_Index
	#partial switch payload in ast.nodes[current].payload {
	case syntax.Comp_Lit:
		return constant_compound_literal(program, view, current)
	case syntax.Auto_Cast:
		operand = payload.expr
	case syntax.Type_Cast:
		if payload.token.kind == .Transmute { return false }
		operand = payload.expr
	case syntax.Call_Expr:
		arguments := syntax.node_list(ast, payload.args)
		if len(arguments) != 1 || expression_info(program, view, payload.expr).mode != .Type { return false }
		operand = arguments[0]
	case:
		return false
	}
	if !addressing_constant(program, view, operand) || info.type == types.TYPE_NONE { return false }
	store := program.type_data
	source := expression_info(program, view, operand)
	target := types.get(store, conversion_core_type(store, info.type))
	if source.mode == .Constant && constant_plain_type(program, info.type) {
		#partial switch target.kind {
		case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
			source_kind := types.get(store, conversion_core_type(store, source.type)).kind
			return source_kind != .Array && source_kind != .Enumerated_Array && source_kind != .Simd_Vector && source_kind != .Matrix
		}
		return true
	}
	#partial switch target.kind {
	case .Slice:
		return types.get(store, conversion_core_type(store, source.type)).kind != .String
	case .Union:
		return constant_union(program, target)
	}
	return true
}

// Whether the official checker gives a compound literal, or a parenthesized one, the mode Addressing_Constant: every
// element is a constant, nil, a procedure or a constant literal itself (check_expr.cpp:11391-11540, 12687-12752). Published
// modes keep such literals as values, so analysis asks here; lowering is unaffected.
@(private = "file")
constant_compound_literal :: proc(program: ^Checked_Program, view: View_Id, node: syntax.Node_Index) -> bool {
	if node == 0 || view <= 0 || int(view) >= len(program.typed_views) { return false }
	ast := program.files[program.typed_views[view].file].ast
	current := node
	for ast.nodes[current].kind == .Paren_Expr { current = syntax.node_payload(ast, current, syntax.Paren_Expr).expr }
	if ast.nodes[current].kind != .Comp_Lit { return false }
	info := expression_info(program, view, current)
	if info.state != .Checked || info.type == types.TYPE_NONE { return false }
	literal_type := types.get(program.type_data, types.resolve_named(program.type_data, info.type))
	#partial switch literal_type.kind {
	case .Slice, .Array, .Enumerated_Array, .Fixed_Capacity_Array, .Matrix, .Simd_Vector, .Bit_Set:
	case .Struct:
		if literal_type.raw_union || literal_type.soa != .None { return false }
	case:
		return false
	}
	if literal_type.kind != .Struct && literal_type.elem != types.TYPE_NONE && !constant_element_type(program, literal_type.elem) { return false }
	for element, position in syntax.node_list(ast, syntax.node_payload(ast, current, syntax.Comp_Lit).elems) {
		value := element
		field_name := ""
		if ast.nodes[element].kind == .Field_Value {
			field := syntax.node_payload(ast, element, syntax.Field_Value)
			value = field.value
			field_name = string(program.files[program.typed_views[view].file].source[ast.nodes[field.field].start:ast.nodes[field.field].end])
		}
		if literal_type.kind == .Struct && !constant_field_type(program, literal_type, position, field_name) { return false }
		if !constant_literal_element(program, view, ast, value) { return false }
	}
	return true
}

// The official elem_type_can_be_constant: not `any`, not a raw union, and a union only when all variants are constant types.
@(private = "file")
constant_element_type :: proc(program: ^Checked_Program, id: types.Type_Id) -> bool {
	element := types.get(program.type_data, types.resolve_named(program.type_data, id))
	#partial switch element.kind {
	case .Any, .Invalid:
		return false
	case .Struct:
		return !element.raw_union
	case .Union:
		return constant_union(program, element)
	}
	return true
}

@(private = "file")
constant_field_type :: proc(program: ^Checked_Program, record: ^types.Type, position: int, name: string) -> bool {
	for field, index in record.fields {
		if name == "" && index == position || name != "" && field.name == name { return constant_element_type(program, field.type) }
	}
	return true
}

@(private = "file")
constant_union :: proc(program: ^Checked_Program, union_type: ^types.Type) -> bool {
	for variant in union_type.variants {
		if !constant_variant_type(program, variant) { return false }
	}
	return true
}

// The official is_type_constant_type_for_unions.
@(private = "file")
constant_variant_type :: proc(program: ^Checked_Program, id: types.Type_Id) -> bool {
	store := program.type_data
	core := types.get(store, conversion_core_type(store, id))
	#partial switch core.kind {
	case .Bool, .Integer, .Float, .Rune, .Complex, .Quaternion, .String, .String16, .CString, .CString16, .Raw_Pointer, .Type_Id, .Bit_Set, .Procedure:
		return true
	case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
		return constant_plain_type(program, core.elem)
	case .Fixed_Capacity_Array:
		return constant_variant_type(program, core.elem)
	case .Struct:
		for field in core.fields {
			if !constant_variant_type(program, field.type) { return false }
		}
		return true
	case .Union:
		return constant_union(program, core)
	}
	return false
}

// The official is_type_constant_type.
@(private = "file")
constant_plain_type :: proc(program: ^Checked_Program, id: types.Type_Id) -> bool {
	store := program.type_data
	core := types.get(store, conversion_core_type(store, id))
	#partial switch core.kind {
	case .Bool, .Integer, .Float, .Rune, .Complex, .Quaternion, .String, .String16, .CString, .CString16, .Raw_Pointer, .Type_Id, .Bit_Set, .Procedure:
		return true
	case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
		return constant_plain_type(program, core.elem)
	}
	return false
}

@(private = "file")
constant_literal_element :: proc(program: ^Checked_Program, view: View_Id, ast: ^syntax.Ast, node: syntax.Node_Index) -> bool {
	current := node
	for ast.nodes[current].kind == .Paren_Expr { current = syntax.node_payload(ast, current, syntax.Paren_Expr).expr }
	if ast.nodes[current].kind == .Proc_Lit || ast.nodes[current].kind == .Comp_Lit && constant_compound_literal(program, view, current) { return true }
	info := expression_info(program, view, current)
	if info.state != .Checked { return false }
	if info.type == types.TYPE_UNTYPED_NIL || info.mode == .Type { return true }
	if info.entity != 0 && int(info.entity) < len(program.entities) && program.entities[info.entity].kind == .Procedure { return true }
	return info.mode == .Constant
}
