package check

import "oc:syntax"
import "oc:types"

@(private = "package")
expression_atomic_type_is_lock_free :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	operand := type_query_operand(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	if operand.type == types.TYPE_NONE || types.is_untyped(store, operand.type) {
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
	}
	core := types.core_type(store, operand.type)
	descriptor := types.get(store, core)
	atomic := false
	#partial switch descriptor.kind {
	case .Bool, .Integer, .Rune, .Float, .Bit_Set, .Pointer, .Multi_Pointer, .Raw_Pointer, .CString, .CString16, .Procedure, .Type_Id:
		atomic = true
	}
	size, alignment, failure := types.layout(store, core, checker.config.layout)
	if failure != .None { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	// Linux x64: types.cpp is_type_lock_free and target_max_atomic_size.
	maximum: i64 = 16 if target_feature_enabled(checker.target_features, "cx16") else 8
	lock_free := size <= checker.config.layout.max_align
	if atomic { lock_free = size <= maximum && size & (size - 1) == 0 && alignment >= size }
	constant, constant_error := constant_pool_intern_bool(checker.constants, lock_free, types.TYPE_UNTYPED_BOOL)
	if constant_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_BOOL, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}
