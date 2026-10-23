package analysis

import "oc:check"
import "oc:syntax"
import "oc:types"

atomic_array_like :: proc(a: ^Atomics, id: types.Type_Id) -> bool {
	kind := types_kind(a, id)
	return kind == .Array || kind == .Enumerated_Array || kind == .Fixed_Capacity_Array
}

atomic_is_pointer :: proc(a: ^Atomics, id: types.Type_Id) -> bool {
	return types_kind(a, id) == .Pointer
}

atomic_variable :: proc(a: ^Atomics, entity: check.Entity_Id) -> (variable: ^check.Entity, ok: bool) {
	if entity == 0 || int(entity) >= len(a.program.entities) { return nil, false }
	variable = &a.program.entities[entity]
	return variable, variable.kind == .Variable
}

atomic_global :: proc(a: ^Atomics, entity: check.Entity_Id) -> Location {
	variable, ok := atomic_variable(a, entity)
	if !ok { return {} }
	data, is_variable := variable.data.(check.Variable_Data)
	if !is_variable || data.storage != .Global && data.storage != .Thread_Local { return {} }
	return Location{entity = entity}
}

// What an atomic operation on `&expr` is on, if anything.
atomic_location :: proc(a: ^Atomics, view: check.View_Id, expr: syntax.Node_Index) -> (location: Location, ok: bool) {
	ast := atomic_ast(a, view)
	node := atomic_unparen(ast, expr)
	#partial switch ast.nodes[node].kind {
	case .Ident:
		location = atomic_global(a, atomic_info(a, view, node).entity)
		return location, location != {}
	case .Selector_Expr:
		info := atomic_info(a, view, node)
		if plan := check.plan(a.program, info.plan); plan != nil {
			#partial switch place in plan^ {
			case check.Place_Plan:
				if place.bit_size != 0 || len(place.path) == 0 { return {}, false }
				last := place.path[len(place.path) - 1]
				return Location{type = last.type, field = last.field_index}, true
			case check.Swizzle_Plan:
				return {}, false
			}
		}
		location = atomic_global(a, info.entity)
		return location, location != {}
	case .Index_Expr:
		index := syntax.node_payload(ast, node, syntax.Index_Expr)
		if !atomic_array_like(a, atomic_info(a, view, index.expr).type) { return {}, false }
		return atomic_location(a, view, index.expr)
	}
	return {}, false
}

// The local variable an expression is within without going through a pointer.
atomic_local :: proc(a: ^Atomics, view: check.View_Id, node: syntax.Node_Index) -> check.Entity_Id {
	ast := atomic_ast(a, view)
	node := node
	for {
		node = atomic_unparen(ast, node)
		#partial switch ast.nodes[node].kind {
		case .Ident:
			entity := atomic_info(a, view, node).entity
			variable, ok := atomic_variable(a, entity)
			if !ok || .Parameter in variable.flags { return 0 }
			data, is_variable := variable.data.(check.Variable_Data)
			if !is_variable || data.storage != .Local { return 0 }
			return entity
		case .Selector_Expr:
			base := syntax.node_payload(ast, node, syntax.Selector_Expr).expr
			if atomic_is_pointer(a, atomic_info(a, view, base).type) { return 0 }
			node = base
		case .Index_Expr:
			base := syntax.node_payload(ast, node, syntax.Index_Expr).expr
			if !atomic_array_like(a, atomic_info(a, view, base).type) { return 0 }
			node = base
		case:
			return 0
		}
	}
}

atomic_object :: proc(a: ^Atomics, view: check.View_Id, expr: syntax.Node_Index) -> Atomic_Object {
	ast := atomic_ast(a, view)
	node := atomic_unparen(ast, expr)
	#partial switch ast.nodes[node].kind {
	case .Unary_Expr:
		unary := syntax.node_payload(ast, node, syntax.Unary_Expr)
		if unary.op.kind == .And { return atomic_object(a, view, unary.expr) }
	case .Deref_Expr:
		return atomic_object(a, view, syntax.node_payload(ast, node, syntax.Deref_Expr).expr)
	case .Ident:
		entity := atomic_info(a, view, node).entity
		if _, ok := atomic_variable(a, entity); ok { return {entity, ""} }
	case .Selector_Expr:
		selector := syntax.node_payload(ast, node, syntax.Selector_Expr)
		info := atomic_info(a, view, node)
		if _, ok := atomic_variable(a, info.entity); ok && check.plan(a.program, info.plan) == nil { return {info.entity, ""} }
		object := atomic_object(a, view, selector.expr)
		if object.root != 0 && ast.nodes[selector.field].kind == .Ident {
			field := atomic_text(a, {view, selector.field})
			object.path = slice_join(a, {object.path, ".", field})
			return object
		}
	case .Index_Expr:
		index := syntax.node_payload(ast, node, syntax.Index_Expr)
		object := atomic_object(a, view, index.expr)
		if object.root != 0 {
			object.path = slice_join(a, {object.path, "[", atomic_text(a, {view, index.index}), "]"})
			return object
		}
	}
	return {}
}

slice_join :: proc(a: ^Atomics, parts: []string) -> string {
	size := 0
	for part in parts { size += len(part) }
	joined := make([]byte, size, a.allocator)
	size = 0
	for part in parts { size += copy(joined[size:], part) }
	return string(joined)
}

atomic_same_object :: proc(x, y: Atomic_Object) -> bool {
	if x.root == 0 || y.root == 0 { return x.root == y.root }
	if x.root != y.root { return false }
	outer, inner := x.path, y.path
	if len(outer) > len(inner) { outer, inner = inner, outer }
	if len(inner) < len(outer) || inner[:len(outer)] != outer { return false }
	return len(inner) == len(outer) || inner[len(outer)] == '.' || inner[len(outer)] == '['
}

atomic_may_be_same_object :: proc(x, y: Atomic_Object) -> bool {
	return x.root == 0 || y.root == 0 || atomic_same_object(x, y)
}

// The callee entity a call node resolves to, and what it is called with.
atomic_callee :: proc(a: ^Atomics, view: check.View_Id, call: syntax.Node_Index) -> (entity: check.Entity_Id, plan: check.Call_Plan) {
	info := atomic_info(a, view, call)
	if p := check.plan(a.program, info.plan); p != nil {
		if call_plan, ok := p^.(check.Call_Plan); ok { return call_plan.entity, call_plan }
	}
	return 0, {}
}

atomic_callee_procedure :: proc(a: ^Atomics, entity: check.Entity_Id) -> Procedure_Id {
	if entity == 0 || int(entity) >= len(a.graph.procedure_of_entity) { return 0 }
	return a.graph.procedure_of_entity[entity]
}

atomic_procedure_data :: proc(a: ^Atomics, entity: check.Entity_Id) -> (data: check.Procedure_Data, ok: bool) {
	if entity == 0 || int(entity) >= len(a.program.entities) { return {}, false }
	data, ok = a.program.entities[entity].data.(check.Procedure_Data)
	return
}

atomic_call_arguments :: proc(a: ^Atomics, view: check.View_Id, call: syntax.Node_Index) -> []syntax.Node_Index {
	ast := atomic_ast(a, view)
	node := call
	if ast.nodes[node].kind == .Selector_Call_Expr { node = syntax.node_payload(ast, node, syntax.Selector_Call_Expr).call }
	if ast.nodes[node].kind != .Call_Expr { return nil }
	return syntax.node_list(ast, syntax.node_payload(ast, node, syntax.Call_Expr).args)
}

// The argument of `call` for the parameter at `index` of `callee`, by name or by position.
atomic_call_argument :: proc(a: ^Atomics, view: check.View_Id, call: syntax.Node_Index, callee: check.Entity_Id, index: int) -> syntax.Node_Index {
	ast := atomic_ast(a, view)
	data, ok := atomic_procedure_data(a, callee)
	if !ok { return 0 }
	signature := types.get(a.program.type_data, data.signature)
	if signature.kind != .Procedure || index >= len(signature.param_names) { return 0 }
	arguments := atomic_call_arguments(a, view, call)
	for argument in arguments {
		if ast.nodes[argument].kind != .Field_Value { continue }
		field := syntax.node_payload(ast, argument, syntax.Field_Value)
		if ast.nodes[field.field].kind == .Ident && atomic_text(a, {view, field.field}) == signature.param_names[index] { return field.value }
	}
	if index < len(arguments) && ast.nodes[arguments[index]].kind != .Field_Value { return arguments[index] }
	return 0
}

// The word an atomic call operates on: a futex procedure's named parameter, or the first argument.
atomic_call_pointer :: proc(a: ^Atomics, call: Atomic_Call) -> syntax.Node_Index {
	if call.futex != .None {
		callee, _ := atomic_callee(a, call.call.view, call.call.node)
		data, _ := atomic_procedure_data(a, callee)
		return atomic_call_argument(a, call.call.view, call.call.node, callee, data.atomic.futex_parameter)
	}
	arguments := atomic_call_arguments(a, call.call.view, call.call.node)
	return arguments[0] if len(arguments) > 0 else 0
}

// The `&x` an atomic pointer is, through conversions of it.
atomic_address_of :: proc(a: ^Atomics, view: check.View_Id, node: syntax.Node_Index) -> syntax.Node_Index {
	ast := atomic_ast(a, view)
	current := atomic_unparen(ast, node)
	for current != 0 {
		#partial switch ast.nodes[current].kind {
		case .Call_Expr:
			call := syntax.node_payload(ast, current, syntax.Call_Expr)
			arguments := syntax.node_list(ast, call.args)
			if len(arguments) != 1 || atomic_info(a, view, call.expr).mode != .Type { return 0 }
			current = atomic_unparen(ast, arguments[0])
		case .Type_Cast:
			current = atomic_unparen(ast, syntax.node_payload(ast, current, syntax.Type_Cast).expr)
		case .Auto_Cast:
			current = atomic_unparen(ast, syntax.node_payload(ast, current, syntax.Auto_Cast).expr)
		case .Unary_Expr:
			if syntax.node_payload(ast, current, syntax.Unary_Expr).op.kind == .And { return current }
			return 0
		case:
			return 0
		}
	}
	return 0
}

// The operand of the `&` an atomic call takes the address of; 0 for a pointer from elsewhere.
atomic_call_target :: proc(a: ^Atomics, call: Atomic_Call) -> syntax.Node_Index {
	pointer := atomic_call_pointer(a, call)
	if pointer == 0 { return 0 }
	address := atomic_address_of(a, call.call.view, pointer)
	if address == 0 { return 0 }
	return syntax.node_payload(atomic_ast(a, call.call.view), address, syntax.Unary_Expr).expr
}

atomic_call_size :: proc(a: ^Atomics, call: Atomic_Call) -> i64 {
	pointer := atomic_call_pointer(a, call)
	if pointer == 0 { return 0 }
	info := atomic_info(a, call.call.view, pointer)
	if types_kind(a, info.type) != .Pointer { return 0 }
	descriptor := types.get(a.program.type_data, types.resolve_named(a.program.type_data, info.type))
	size, _, _ := types.layout(a.program.type_data, descriptor.elem)
	return size
}
