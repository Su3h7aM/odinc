package check

import "oc:syntax"
import "oc:types"

@(private = "file")
Range_Parts :: struct {
	label, init, expr, body: syntax.Node_Index,
	names:                   []syntax.Node_Index,
	constant_bounds:         bool,
	barrier:                 bool,
	reverse:                 bool,
}

// Runtime procedures that string range loops call to decode one rune.
range_helper_names := [?]string{"string_decode_rune", "string_decode_last_rune", "string16_decode_rune", "string16_decode_last_rune"}

@(private = "package")
expression_range :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.Range_Stmt)
	parts := Range_Parts {
		label   = statement.label,
		init    = statement.init,
		expr    = statement.expr,
		body    = statement.body,
		names   = syntax.node_list(file.ast, statement.vals),
		reverse = statement.reverse,
	}
	return expression_range_loop(checker, view, file_id, scope, node, parts)
}

// `#unroll` bodies may not break or continue to their own loop: the barrier frame stops unlabeled branches.
@(private = "package")
expression_unroll_range :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.Unroll_Range_Stmt)
	arguments := syntax.node_list(file.ast, statement.args)
	if len(arguments) > 1 {
		expression_unsupported(checker, view, scope, node, "Unroll_Argument") or_return
		return nil
	}
	if len(arguments) == 1 {
		argument := check_expression(checker, view, scope, arguments[0]) or_return
		if argument.state == .Invalid { return nil }
		store := checker.type_checker.store
		if argument.mode != .Constant || !conversion_integer(types.get(store, types.resolve_named(store, argument.type)).kind) {
			expression_unsupported(checker, view, scope, arguments[0], "Unroll_Argument") or_return
			return nil
		}
	}
	names_buffer: [2]syntax.Node_Index
	count := 0
	if statement.val0 != 0 {
		names_buffer[count] = statement.val0
		count += 1
	}
	if statement.val1 != 0 {
		names_buffer[count] = statement.val1
		count += 1
	}
	parts := Range_Parts {
		label           = statement.label,
		expr            = statement.expr,
		body            = statement.body,
		names           = names_buffer[:count],
		constant_bounds = true,
		barrier         = true,
	}
	return expression_range_loop(checker, view, file_id, scope, node, parts)
}

@(private = "file")
range_unparen :: proc(file: ^File, node: syntax.Node_Index) -> syntax.Node_Index {
	expression := node
	for file.ast.nodes[expression].kind == .Paren_Expr {
		expression = syntax.node_payload(file.ast, expression, syntax.Paren_Expr).expr
	}
	return expression
}

@(private = "file")
range_interval :: proc(file: ^File, node: syntax.Node_Index) -> (interval: syntax.Binary_Expr, is_interval: bool) {
	expression := range_unparen(file, node)
	if file.ast.nodes[expression].kind != .Binary_Expr { return {}, false }
	interval = syntax.node_payload(file.ast, expression, syntax.Binary_Expr)
	is_interval = interval.op.kind == .Range_Half || interval.op.kind == .Range_Full || interval.op.kind == .Ellipsis
	return interval, is_interval
}

// A `&name` loop variable binds the element by reference.
@(private = "file")
range_name :: proc(file: ^File, node: syntax.Node_Index) -> (ident: syntax.Node_Index, by_reference: bool) {
	if file.ast.nodes[node].kind == .Unary_Expr {
		unary := syntax.node_payload(file.ast, node, syntax.Unary_Expr)
		if unary.op.kind == .And { return unary.expr, true }
	}
	return node, false
}

@(private = "file")
range_declare :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file: ^File,
	scope: Scope_Id,
	ident: syntax.Node_Index,
	type: types.Type_Id,
) -> Resolve_Error {
	name := expression_text(file, ident)
	if name == "_" {
		expression_store(checker, view, ident, Expression_Info{state = .Checked})
		return nil
	}
	variable, create_error := entity_create(
		checker.type_checker.resolver.scopes,
		Entity{name = name, kind = .Variable, scope = scope, state = .Resolved, type = type, data = Variable_Data{storage = .Local}},
	)
	if create_error != nil { return binding_resolve_error(create_error) }
	_, insert_error := scope_insert(checker.type_checker.resolver.scopes, scope, variable)
	if insert_error != nil { return binding_resolve_error(insert_error) }
	expression_store(checker, view, ident, Expression_Info{type = type, mode = .Variable, entity = variable, scope = scope, state = .Checked})
	return nil
}

@(private = "file")
expression_range_loop :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	parts: Range_Parts,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	if len(parts.names) > 2 {
		expression_unsupported(checker, view, scope, node, "Range_Form") or_return
		return nil
	}
	range_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	if parts.init != 0 { expression_statement(checker, view, file_id, range_scope, parts.init) or_return }
	if interval, is_interval := range_interval(file, parts.expr); is_interval {
		return expression_range_interval(checker, view, file_id, scope, range_scope, node, parts, interval)
	}
	return expression_range_container(checker, view, file_id, scope, range_scope, node, parts)
}

@(private = "file")
expression_range_body :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	node: syntax.Node_Index,
	range_scope: Scope_Id,
	parts: Range_Parts,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	label := ""
	if parts.label != 0 { label = expression_text(file, parts.label) }
	frame := Control_Frame {
		node       = node,
		label      = label,
		is_loop    = !parts.barrier,
		is_barrier = parts.barrier,
	}
	append(&checker.control, frame) or_return
	defer pop(&checker.control)
	return expression_statement(checker, view, file_id, range_scope, parts.body)
}

@(private = "file")
range_bound_kind :: proc(kind: types.Kind) -> bool {
	return conversion_integer(kind) || conversion_float(kind) || kind == .Enum
}

@(private = "file")
expression_range_interval :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	range_scope: Scope_Id,
	node: syntax.Node_Index,
	parts: Range_Parts,
	interval: syntax.Binary_Expr,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	if interval.op.kind == .Ellipsis {
		expression_failure(checker, view, scope, parts.expr, .Invalid_Range_Operator) or_return
		return nil
	}
	if parts.reverse {
		expression_failure(checker, view, scope, parts.expr, .Invalid_Reverse_Range) or_return
		return nil
	}
	for name in parts.names {
		if _, by_reference := range_name(file, name); by_reference {
			expression_unsupported(checker, view, scope, name, "Range_Form") or_return
			return nil
		}
	}
	low := check_expression(checker, view, range_scope, interval.left) or_return
	if low.state == .Invalid { return nil }
	high := check_expression(checker, view, range_scope, interval.right) or_return
	if high.state == .Invalid { return nil }
	store := checker.type_checker.store
	range_type := low.type
	if types.is_untyped(store, range_type) { range_type = high.type }
	if types.is_untyped(store, range_type) { range_type = types.default_type_of_untyped(store, range_type) }
	low = check_expression(checker, view, range_scope, interval.left, range_type) or_return
	high = check_expression(checker, view, range_scope, interval.right, range_type) or_return
	if low.state == .Invalid || high.state == .Invalid { return nil }
	if !range_bound_kind(types.get(store, types.resolve_named(store, low.type)).kind) {
		expression_unsupported(checker, view, scope, parts.expr, "Range_Type") or_return
		return nil
	}
	if parts.constant_bounds && (low.mode != .Constant || high.mode != .Constant) {
		expression_unsupported(checker, view, scope, parts.expr, "Unroll_Bounds") or_return
		return nil
	}
	if len(parts.names) >= 1 { range_declare(checker, view, file, range_scope, parts.names[0], low.type) or_return }
	if len(parts.names) == 2 { range_declare(checker, view, file, range_scope, parts.names[1], checker.default_integer) or_return }
	expression_range_body(checker, view, file_id, node, range_scope, parts) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

// Declares the value and index names. It reports false when a name was rejected as unsupported.
@(private = "file")
range_declare_names :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file: ^File,
	scope: Scope_Id,
	range_scope: Scope_Id,
	parts: Range_Parts,
	element, index: types.Type_Id,
	addressable: bool,
) -> (
	declared: bool,
	err: Resolve_Error,
) {
	if len(parts.names) >= 1 {
		ident, by_reference := range_name(file, parts.names[0])
		if by_reference && !addressable {
			expression_unsupported(checker, view, scope, parts.names[0], "Range_Reference") or_return
			return false, nil
		}
		range_declare(checker, view, file, range_scope, ident, element) or_return
	}
	if len(parts.names) == 2 {
		ident, by_reference := range_name(file, parts.names[1])
		if by_reference {
			expression_unsupported(checker, view, scope, parts.names[1], "Range_Form") or_return
			return false, nil
		}
		range_declare(checker, view, file, range_scope, ident, index) or_return
	}
	return true, nil
}

@(private = "file")
expression_range_container :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	range_scope: Scope_Id,
	node: syntax.Node_Index,
	parts: Range_Parts,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	container := check_expression(checker, view, range_scope, parts.expr) or_return
	if container.state == .Invalid { return nil }
	if container.mode == .Type {
		return expression_range_enum(checker, view, file_id, scope, range_scope, node, parts, container.type)
	}
	store := checker.type_checker.store
	type := types.get(store, types.resolve_named(store, container.type))
	#partial switch type.kind {
	case .Array, .Enumerated_Array, .Slice, .Dynamic_Array, .Fixed_Capacity_Array, .Bit_Set:
	case .String, .String16:
	case:
		expression_unsupported(checker, view, scope, parts.expr, "Range_Type") or_return
		return nil
	}
	if type.kind == .Bit_Set && len(parts.names) == 2 {
		expression_unsupported(checker, view, scope, parts.names[1], "Range_Form") or_return
		return nil
	}
	element := type.elem
	if type.kind == .String || type.kind == .String16 {
		helpers_resolved, helper_error := expression_resolve_range_helpers(checker)
		if helper_error != nil { return helper_error }
		if !helpers_resolved {
			expression_unsupported(checker, view, scope, parts.expr, "Range_Helpers") or_return
			return nil
		}
		element = types.intern(store, types.Type{kind = .Rune, count = 4, signed = true})
	}
	index := checker.default_integer
	if type.kind == .Enumerated_Array { index = type.index }
	addressable :=
		type.kind == .Slice ||
		type.kind == .Dynamic_Array ||
		(type.kind != .Bit_Set && type.kind != .String && type.kind != .String16 && container.mode == .Variable)
	declared := range_declare_names(checker, view, file, scope, range_scope, parts, element, index, addressable) or_return
	if !declared { return nil }
	expression_range_body(checker, view, file_id, node, range_scope, parts) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

@(private = "file")
expression_resolve_range_helpers :: proc(checker: ^Expression_Checker) -> (resolved: bool, err: Resolve_Error) {
	collection := checker.type_checker.collection
	if collection == nil || collection.runtime_scope == 0 { return false, nil }
	scopes := checker.type_checker.resolver.scopes
	for name in range_helper_names {
		helper := scope_lookup_current(scopes, collection.runtime_scope, name)
		if helper == 0 { return false, nil }
		_, resolve_error := resolve_entity(checker.type_checker.resolver, helper)
		if resolve_error != nil { return false, resolve_error }
		if entity_get(scopes, helper).state != .Resolved { return false, nil }
	}
	return true, nil
}

// `for value, index in EnumType`: the value is a member of the enum and the index is its position.
// The enum's runtime members are recorded, as the official compiler's `add_type_info_type` does.
@(private = "file")
expression_range_enum :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	range_scope: Scope_Id,
	node: syntax.Node_Index,
	parts: Range_Parts,
	enum_type: types.Type_Id,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	store := checker.type_checker.store
	if parts.reverse {
		expression_failure(checker, view, scope, parts.expr, .Invalid_Reverse_Range) or_return
		return nil
	}
	if types.get(store, types.resolve_named(store, enum_type)).kind != .Enum {
		expression_unsupported(checker, view, scope, parts.expr, "Range_Type") or_return
		return nil
	}
	expression_record_type_info(checker, enum_type) or_return
	declared := range_declare_names(checker, view, file, scope, range_scope, parts, enum_type, checker.default_integer, false) or_return
	if !declared { return nil }
	expression_range_body(checker, view, file_id, node, range_scope, parts) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}
