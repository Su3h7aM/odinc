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
	immutable: bool,
) -> Resolve_Error {
	name := expression_text(file, ident)
	if name == "_" {
		expression_store(checker, view, ident, Expression_Info{state = .Checked})
		return nil
	}
	flags: Entity_Flags
	mode := Addressing_Mode.Variable
	if immutable {
		flags += {.Immutable}
		mode = .Immutable_Value
	}
	variable, create_error := entity_create(
		checker.type_checker.resolver.scopes,
		Entity{name = name, kind = .Variable, scope = scope, state = .Resolved, flags = flags, type = type, data = Variable_Data{storage = .Local}},
	)
	if create_error != nil { return binding_resolve_error(create_error) }
	_, insert_error := scope_insert(checker.type_checker.resolver.scopes, scope, variable)
	if insert_error != nil { return binding_resolve_error(insert_error) }
	expression_store(checker, view, ident, Expression_Info{type = type, mode = mode, entity = variable, scope = scope, state = .Checked})
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
	range_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	if parts.init != 0 { expression_statement(checker, view, file_id, range_scope, parts.init) or_return }
	if interval, is_interval := range_interval(file, parts.expr); is_interval {
		if len(parts.names) > 2 {
			expression_unsupported(checker, view, scope, node, "Range_Form") or_return
			return nil
		}
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
	if len(parts.names) >= 1 { range_declare(checker, view, file, range_scope, parts.names[0], low.type, true) or_return }
	if len(parts.names) == 2 {
		range_declare(checker, view, file, range_scope, parts.names[1], checker.default_integer, true) or_return
	}
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
		range_declare(checker, view, file, range_scope, ident, element, !by_reference) or_return
	}
	if len(parts.names) == 2 {
		ident, by_reference := range_name(file, parts.names[1])
		if by_reference {
			expression_unsupported(checker, view, scope, parts.names[1], "Range_Form") or_return
			return false, nil
		}
		range_declare(checker, view, file, range_scope, ident, index, !by_reference) or_return
	}
	return true, nil
}

@(private = "file")
range_declare_map_names :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file: ^File,
	scope, range_scope: Scope_Id,
	parts: Range_Parts,
	key, value: types.Type_Id,
) -> (
	declared: bool,
	err: Resolve_Error,
) {
	if len(parts.names) >= 1 {
		ident, by_reference := range_name(file, parts.names[0])
		if by_reference {
			expression_unsupported(checker, view, scope, parts.names[0], "Range_Reference") or_return
			return false, nil
		}
		range_declare(checker, view, file, range_scope, ident, key, true) or_return
	}
	if len(parts.names) == 2 {
		ident, _ := range_name(file, parts.names[1])
		range_declare(checker, view, file, range_scope, ident, value, true) or_return
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
	if container.plan != 0 {
		if call, is_call := checker.plans[container.plan].(Call_Plan); is_call && len(call.results) > 1 {
			return expression_range_call(checker, view, file_id, scope, range_scope, node, parts, call)
		}
	}
	if len(parts.names) > 2 {
		expression_unsupported(checker, view, scope, node, "Range_Form") or_return
		return nil
	}
	if container.type == types.TYPE_NONE {
		expression_missing_operand_type(checker, view, scope, parts.expr, container.mode) or_return
		return nil
	}
	if container.mode == .Type {
		return expression_range_enum(checker, view, file_id, scope, range_scope, node, parts, container.type)
	}
	store := checker.type_checker.store
	container_type := types.resolve_named(store, container.type)
	type := types.get(store, container_type)
	if type.kind == .Pointer {
		container_type = types.resolve_named(store, type.elem)
		type = types.get(store, container_type)
	}
	if type.kind == .Struct && type.soa != .None {
		return expression_range_soa(checker, view, file_id, scope, range_scope, node, parts, container, container_type)
	}
	if len(parts.names) >= 1 {
		if _, by_reference := range_name(file, parts.names[0]); by_reference {
			if element, ok := range_soa_element_plan(checker, container); ok {
				return expression_range_soa_element(checker, view, file_id, scope, range_scope, node, parts, element)
			}
		}
	}
	#partial switch type.kind {
	case .Array, .Enumerated_Array, .Slice, .Dynamic_Array, .Fixed_Capacity_Array, .Bit_Set:
	case .String, .String16:
	case .Map:
		if parts.reverse {
			expression_failure(checker, view, scope, node, .Invalid_Reverse_Range) or_return
			return nil
		}
		declared := range_declare_map_names(checker, view, file, scope, range_scope, parts, type.index, type.elem) or_return
		if !declared { return nil }
		helpers_resolved, helper_error := expression_resolve_map_helpers(checker)
		if helper_error != nil { return helper_error }
		if !helpers_resolved {
			expression_unsupported(checker, view, scope, parts.expr, "Range_Helpers") or_return
			return nil
		}
		append(&checker.plans, Plan(Map_Info_Plan{type = container_type})) or_return
		expression_range_body(checker, view, file_id, node, range_scope, parts) or_return
		expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
		return nil
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
		element = types.default_type_of_untyped(store, types.TYPE_UNTYPED_RUNE)
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

@(private = "file")
expression_range_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope, range_scope: Scope_Id,
	node: syntax.Node_Index,
	parts: Range_Parts,
	call: Call_Plan,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	if parts.reverse || parts.constant_bounds {
		expression_unsupported(checker, view, scope, node, "Range_Call_Form") or_return
		return nil
	}
	if len(call.results) > 20 || len(parts.names) >= len(call.results) {
		expression_unsupported(checker, view, scope, node, "Range_Call_Results") or_return
		return nil
	}
	condition_index := len(call.results) - 1
	store := checker.type_checker.store
	condition_type := call.results[condition_index]
	if condition_type == types.TYPE_NONE {
		expression_missing_operand_type(checker, view, scope, parts.expr, .No_Value) or_return
		return nil
	}
	if types.get(store, types.resolve_named(store, condition_type)).kind != .Bool {
		expression_failure(checker, view, scope, parts.expr, .Invalid_Operand, "The final type of a multiple-valued expression must be a boolean") or_return
		return nil
	}
	for name, index in parts.names {
		ident, by_reference := range_name(file, name)
		if by_reference {
			expression_unsupported(checker, view, scope, name, "Range_Reference") or_return
			return nil
		}
		range_declare(checker, view, file, range_scope, ident, call.results[index], true) or_return
	}
	expression_range_body(checker, view, file_id, node, range_scope, parts) or_return
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(
			Range_Call_Plan {
				call = {view, parts.expr},
				value_types = call.results[:condition_index],
				value_count = u32(len(parts.names)),
				condition_index = u32(condition_index),
			},
		),
	) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
	return nil
}

// Declares a hidden snapshot or counter entity for an #soa range. Hidden
// entities are never inserted in a scope, so later lookups cannot reach them.
@(private = "file")
soa_range_hidden :: proc(checker: ^Expression_Checker, range_scope: Scope_Id, type: types.Type_Id) -> (entity: Entity_Id, err: Resolve_Error) {
	hidden, create_error := entity_create(
		checker.type_checker.resolver.scopes,
		Entity{name = "", kind = .Variable, scope = range_scope, state = .Resolved, type = type, data = Variable_Data{storage = .Local}},
	)
	if create_error != nil { return 0, binding_resolve_error(create_error) }
	return hidden, nil
}

// `for v[, i] in soa`: v names each scattered element and i its position.
// The container is snapshotted once into a hidden entity, the way slice
// ranges snapshot their header, and v resolves to a Soa_Plan over that
// snapshot plus a hidden or user-named counter. A `&v` value binds the same
// plan without the immutable flag, so writes scatter into the container,
// as the official check_stmt.cpp SoaPtrField entity does.
@(private = "file")
expression_range_soa :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope, range_scope: Scope_Id,
	node: syntax.Node_Index,
	parts: Range_Parts,
	container: Expression_Info,
	container_type: types.Type_Id,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	store := checker.type_checker.store
	descriptor := types.get(store, container_type)
	// A `&v` value needs the container to stay addressable. Fixed #soa
	// requires a variable container, as check_stmt.cpp requires; slice and
	// dynamic kinds always are.
	addressable := descriptor.soa == .Slice || descriptor.soa == .Dynamic
	if !addressable {
		addressable = container.mode == .Variable
	}
	value_reference := false
	if len(parts.names) >= 1 {
		ident, by_reference := range_name(file, parts.names[0])
		value_reference = by_reference && expression_text(file, ident) != "_"
		if value_reference && !addressable {
			expression_unsupported(checker, view, scope, parts.names[0], "Range_Reference") or_return
			return nil
		}
	}
	if len(parts.names) == 2 {
		_, by_reference := range_name(file, parts.names[1])
		if by_reference {
			expression_unsupported(checker, view, scope, parts.names[1], "Range_Form") or_return
			return nil
		}
	}
	snapshot := soa_range_hidden(checker, range_scope, container.type) or_return
	index_entity: Entity_Id
	if len(parts.names) == 2 {
		range_declare(checker, view, file, range_scope, parts.names[1], checker.default_integer, true) or_return
		index_entity = scope_lookup_current(checker.type_checker.resolver.scopes, range_scope, expression_text(file, parts.names[1]))
	} else {
		index_entity = soa_range_hidden(checker, range_scope, checker.default_integer) or_return
	}
	if len(parts.names) >= 1 {
		ident, by_reference := range_name(file, parts.names[0])
		value_flags: Entity_Flags
		if !by_reference { value_flags += {.Immutable} }
		loop := Soa_Plan {
			container = Operand(snapshot),
			index     = Operand(index_entity),
			soa       = container_type,
			policy    = .Disabled,
		}
		if expression_text(file, ident) == "_" {
			expression_store(checker, view, ident, Expression_Info{state = .Checked})
		} else {
			value_entity, create_error := entity_create(
				checker.type_checker.resolver.scopes,
				Entity {
					name = expression_text(file, ident),
					kind = .Variable,
					scope = range_scope,
					state = .Resolved,
					flags = value_flags,
					type = descriptor.soa_elem,
					data = Variable_Data{storage = .Local},
				},
			)
			if create_error != nil { return binding_resolve_error(create_error) }
			if previous, insert_error := scope_insert(checker.type_checker.resolver.scopes, range_scope, value_entity); insert_error != nil {
				return binding_resolve_error(insert_error)
			} else if previous != 0 {
				expression_unsupported(checker, view, scope, ident, "Range_Redeclaration") or_return
				return nil
			}
			plan := Plan_Id(len(checker.plans))
			append(&checker.plans, Plan(loop)) or_return
			expression_store(
				checker,
				view,
				ident,
				Expression_Info{type = descriptor.soa_elem, mode = .Soa_Variable, entity = value_entity, plan = plan, scope = range_scope, state = .Checked},
			)
			checker.soa_loop_vars[value_entity] = loop
		}
	}
	_ = container
	expression_range_body(checker, view, file_id, node, range_scope, parts) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

// The Soa_Plan behind `soa[i]` when it names a whole scattered element: the
// container plus the element index and no field. Only lanes of an
// array-typed element are iterable by reference.
@(private = "file")
range_soa_element_plan :: proc(checker: ^Expression_Checker, container: Expression_Info) -> (element: Soa_Plan, ok: bool) {
	if container.plan == 0 || container.mode != .Soa_Variable { return {}, false }
	plan, is_soa := checker.plans[container.plan].(Soa_Plan)
	if !is_soa || plan.field != nil { return {}, false }
	store := checker.type_checker.store
	elem := types.get(store, types.resolve_named(store, types.get(store, plan.soa).soa_elem))
	if elem.kind != .Array { return {}, false }
	return plan, true
}

// `for &v[, j] in soa[i]`: v binds one lane of the scattered element at a
// time and j its lane index. The element itself has no address, but each
// lane does, as the official check_stmt.cpp notes for its Array case, so
// lowering addresses lane after lane through the element's Soa_Plan. The
// by-value form keeps the generic container path.
@(private = "file")
expression_range_soa_element :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope, range_scope: Scope_Id,
	node: syntax.Node_Index,
	parts: Range_Parts,
	element: Soa_Plan,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	store := checker.type_checker.store
	elem := types.get(store, types.resolve_named(store, types.get(store, element.soa).soa_elem))
	ident, _ := range_name(file, parts.names[0])
	range_declare(checker, view, file, range_scope, ident, elem.elem, false) or_return
	if len(parts.names) == 2 {
		index, by_reference := range_name(file, parts.names[1])
		if by_reference {
			expression_unsupported(checker, view, scope, parts.names[1], "Range_Form") or_return
			return nil
		}
		range_declare(checker, view, file, range_scope, index, checker.default_integer, true) or_return
	}
	expression_range_body(checker, view, file_id, node, range_scope, parts) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}
