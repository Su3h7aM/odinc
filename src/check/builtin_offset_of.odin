package check

import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

// offset_of(value.field) and offset_of(Type, field) fold to the field's byte offset, a uintptr constant.
// offset_of_by_string(Type, "field") does the same with the field name given as a constant string.
@(private = "package")
expression_offset_of :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if ellipsis { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	file := checker.type_checker.files[file_id]
	store := checker.type_checker.store
	owner: types.Type_Id
	field_name: string
	field_node := node
	if kind == .Offset_Of && len(arguments) == 1 {
		if file.ast.nodes[arguments[0]].kind != .Selector_Expr { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
		selector := syntax.node_payload(file.ast, arguments[0], syntax.Selector_Expr)
		if file.ast.nodes[selector.expr].kind == .Selector_Expr { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
		base := check_expression(checker, view, scope, selector.expr) or_return
		if base.state == .Invalid { return expression_poison(scope), nil }
		owner = types.resolve_named(store, base.type)
		if types.get(store, owner).kind == .Pointer { owner = types.resolve_named(store, types.get(store, owner).elem) }
		field_name = expression_text(file, selector.field)
		field_node = selector.field
	} else if len(arguments) == 2 {
		type_info := check_expression(checker, view, scope, arguments[0]) or_return
		if type_info.state == .Invalid { return expression_poison(scope), nil }
		owner = types.resolve_named(store, type_info.type)
		field_node = arguments[1]
		if kind == .Offset_Of_By_String {
			name_info := check_expression(checker, view, scope, arguments[1]) or_return
			if name_info.state == .Invalid { return expression_poison(scope), nil }
			name, is_string := constant_pool_get(checker.constants, name_info.constant).value.(string)
			if name_info.mode != .Constant || !is_string { return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand) }
			field_name = name
		} else {
			if file.ast.nodes[arguments[1]].kind != .Ident { return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand) }
			field_name = expression_text(file, arguments[1])
		}
	} else {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	if types.get(store, owner).kind != .Struct { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	path := make([dynamic]Member_Step, 0, allocator) or_return
	if _, found := field_path(checker, owner, false, field_name, &path); !found {
		return expression_failure(checker, view, scope, field_node, .Undeclared_Name)
	}
	offset: i64
	for step in path {
		step_offset, layout_error := types.field_offset(store, step.type, int(step.field_index))
		if layout_error != .None { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		offset += step_offset
	}
	value: big.Int
	defer big.destroy(&value)
	if set_error := big.set(&value, offset); set_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, set_error) or_return
		return expression_poison(scope), nil
	}
	constant, constant_error := constant_pool_intern_integer(checker.constants, &value, checker.config.uintptr)
	if constant_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = checker.config.uintptr, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}
