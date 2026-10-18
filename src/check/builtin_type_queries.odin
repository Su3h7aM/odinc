package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

// Resolves the operand of a type query. A poison type comes back as an invalid expression for the caller to report.
@(private = "package")
type_query_operand :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	argument: syntax.Node_Index,
) -> (
	operand: Expression_Info,
	err: Resolve_Error,
) {
	file_id := checker.views[view].file
	file := checker.type_checker.files[file_id]
	type_argument := argument
	for file.ast.nodes[type_argument].kind == .Paren_Expr { type_argument = syntax.node_payload(file.ast, type_argument, syntax.Paren_Expr).expr }
	if syntax_kind := file.ast.nodes[type_argument].kind; .Typeid_Type <= syntax_kind && syntax_kind <= .Bit_Field_Type {
		type := type_expression(checker.type_checker, file_id, scope, type_argument, true) or_return
		if type == types.TYPE_POISON { return expression_poison(scope), nil }
		return Expression_Info{type = type, mode = .Type, scope = scope, state = .Checked}, nil
	}
	return check_expression(checker, view, scope, argument)
}

@(private = "package")
expression_type_query :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	count := 2 if kind == .Type_Has_Field || kind == .Type_Field_Type else 1
	if len(arguments) != count || ellipsis { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	operand := type_query_operand(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if operand.mode != .Type { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	store := checker.type_checker.store
	owner := types.resolve_named(store, operand.type)
	descriptor := types.get(store, owner)^
	result_type: types.Type_Id
	result := false
	#partial switch kind {
	case .Type_Array:
		result = descriptor.kind == .Array
	case .Type_Pointer:
		result = descriptor.kind == .Pointer || descriptor.kind == .Raw_Pointer
	case .Type_Struct:
		result = descriptor.kind == .Struct
	case .Type_Slice:
		result = descriptor.kind == .Slice
	case .Type_Integer:
		result = descriptor.kind == .Integer || descriptor.kind == .Rune
	case .Type_Float:
		result = descriptor.kind == .Float
	case .Type_Numeric:
		base := descriptor
		for base.kind == .Enum || base.kind == .Array {
			element := base.backing if base.kind == .Enum else base.elem
			base = types.get(store, types.resolve_named(store, element))^
		}
		result = base.kind == .Integer || base.kind == .Rune || base.kind == .Float || base.kind == .Complex || base.kind == .Quaternion
	case .Type_Unsigned:
		base := descriptor
		if base.kind == .Enum { base = types.get(store, types.resolve_named(store, base.backing))^ }
		result = base.kind == .Integer && !base.signed
	case .Type_Proc:
		result = descriptor.kind == .Procedure
	case .Type_Internally_Pointer_Like:
		result =
			descriptor.kind == .Pointer ||
			descriptor.kind == .Raw_Pointer ||
			descriptor.kind == .Multi_Pointer ||
			descriptor.kind == .CString ||
			descriptor.kind == .CString16 ||
			descriptor.kind == .Procedure
	case .Type_Boolean:
		result = descriptor.kind == .Bool
	case .Type_Multi_Pointer:
		result = descriptor.kind == .Multi_Pointer
	case .Type_Dynamic_Array:
		result = descriptor.kind == .Dynamic_Array
	case .Type_Map:
		result = descriptor.kind == .Map
	case .Type_Union:
		result = descriptor.kind == .Union
	case .Type_Enum:
		result = descriptor.kind == .Enum
	case .Type_Bit_Set:
		result = descriptor.kind == .Bit_Set
	case .Type_Has_Field, .Type_Field_Type:
		field := check_expression(checker, view, scope, arguments[1]) or_return
		if field.state == .Invalid { return expression_poison(scope), nil }
		constant := constant_pool_get(checker.constants, field.constant)
		if field.mode != .Constant || constant == nil { return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand) }
		name, is_string := constant.value.(string)
		if !is_string { return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand) }
		path: [dynamic]Member_Step
		defer delete(path)
		result_type, result = field_path(checker, owner, false, name, &path)
		if kind == .Type_Field_Type && !result { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		if kind == .Type_Has_Field { result_type = 0 }
	case .Type_Struct_Field_Count:
		if descriptor.kind != .Struct { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		integer: big.Int
		defer big.destroy(&integer)
		failure: Constant_Error
		failure = big.set(&integer, len(descriptor.fields))
		constant: Const_Id
		if failure == nil { constant, failure = constant_pool_intern_integer(checker.constants, &integer, types.TYPE_UNTYPED_INTEGER) }
		if failure != nil {
			expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = types.TYPE_UNTYPED_INTEGER, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
	case .Type_Bit_Set_Underlying_Type:
		if descriptor.kind != .Bit_Set { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		result_type = descriptor.backing
		if result_type == 0 {
			size, _, failure := types.layout(store, owner)
			if failure != .None { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
			if size <= 16 {result_type = types.sized_integer(store, size, false)
			} else {
				byte := types.sized_integer(store, 1, false)
				result_type = types.intern(store, types.Type{kind = .Array, elem = byte, count = size})
			}
		}
	case .Type_Elem_Type:
		result_type = operand.type
		#partial switch descriptor.kind {
		case .Pointer, .Array, .Enumerated_Array, .Slice, .Dynamic_Array, .Fixed_Capacity_Array, .Simd_Vector:
			result_type = descriptor.elem
		case .Complex, .Quaternion:
			divisor := i64(2) if descriptor.kind == .Complex else 4
			result_type = types.intern(store, types.Type{kind = .Float, count = descriptor.count / divisor})
		}
	}
	if result_type != 0 { return Expression_Info{type = result_type, mode = .Type, scope = scope, state = .Checked}, nil }
	constant, failure := constant_pool_intern_bool(checker.constants, result, types.TYPE_UNTYPED_BOOL)
	if failure != nil {
		expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_BOOL, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}
