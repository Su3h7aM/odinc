package check

import "core:os"
import "core:path/filepath"
import "oc:syntax"
import "oc:types"

@(private)
load_safe_type :: proc(store: ^types.Store, type: types.Type_Id) -> bool {
	descriptor := types.get(store, types.resolve_named(store, type))
	#partial switch descriptor.kind {
	case .Bool, .Integer, .Rune, .Float, .Complex, .Quaternion, .Bit_Set, .Bit_Field:
		return true
	case .Enum:
		return load_safe_type(store, descriptor.backing)
	case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
		return load_safe_type(store, descriptor.elem)
	case .Struct, .Union:
		size, _, error := types.layout(store, type)
		if error != .None || size <= 0 { return false }
		for field in descriptor.fields { if !load_safe_type(store, field.type) { return false } }
		for variant in descriptor.variants { if !load_safe_type(store, variant) { return false } }
		return true
	}
	return false
}

@(private)
load_result_type :: proc(store: ^types.Store, type: types.Type_Id) -> bool {
	if type == 0 { return false }
	descriptor := types.get(store, types.resolve_named(store, type))
	return descriptor.kind == .String || (descriptor.kind == .Slice && load_safe_type(store, descriptor.elem))
}

@(private = "package")
expression_load :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 &&
	   len(arguments) != 2 { return expression_failure(checker, view, scope, node, .Invalid_Operand, "'#load' expects 1 or 2 arguments") }
	argument := check_expression(checker, view, scope, arguments[0]) or_return
	if argument.state == .Invalid { return expression_poison(scope), nil }
	if argument.mode != .Constant { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, "'#load' expects a constant string path") }
	path, is_string := constant_pool_get(checker.constants, argument.constant).value.(string)
	if !is_string { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, "'#load' expects a constant string path") }
	store := checker.type_checker.store
	byte_type := types.intern(store, types.Type{kind = .Integer, name = "u8", count = 1})
	result := types.intern(store, types.Type{kind = .Slice, elem = byte_type})
	if len(arguments) == 2 {
		result = type_expression(checker.type_checker, file_id, scope, arguments[1], true) or_return
		if !load_result_type(
			store,
			result,
		) { return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand, "'#load' expects a string or slice of simple types") }
	} else if load_result_type(store, hint) { result = hint }
	if !filepath.is_abs(path) {
		directory := filepath.dir(checker.type_checker.files[file_id].path)
		joined, join_error := filepath.join({directory, path}, context.temp_allocator)
		if join_error != nil { return {}, join_error }
		path = joined
	}
	contents, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil { return expression_failure(checker, view, scope, node, .Invalid_Operand, "'#load' could not read file") }
	constant, constant_error := constant_pool_intern_string(checker.constants, string(contents), result)
	if constant_error != nil {
		expression_constant_failure(checker, file_id, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = result, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}
