package lower

import "core:math/big"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// #soa element access. A field element lives at `field_ptr + i * size_of(field)`,
// as the official lb_soa_field_elem_ptr computes it (llvm_backend_general.cpp).
// The container operand always evaluates to the address of the #soa struct:
// an aggregate slot for a value, the pointer itself for a ^soa base.

@(private)
lower_soa_store_types :: proc(store: ^types.Store, soa: types.Type_Id) -> (descriptor: ^types.Type, elem: types.Type_Id, spread: int) {
	descriptor = types.get(store, types.resolve_named(store, soa))
	core := types.get(store, types.core_type(store, descriptor.soa_elem))
	elem = types.core_type(store, descriptor.soa_elem)
	spread = len(core.fields) if core.kind == .Struct else int(core.count)
	return descriptor, elem, spread
}

@(private)
lower_soa_container_address :: proc(state: ^Procedure_State, container: check.Operand) -> ir.Node_Id {
	return lower_operand(state, container)
}

// The element count: the constant N for a fixed #soa, the hidden length after
// the field pointers for a slice or dynamic array (lb_soa_struct_len).
@(private)
lower_soa_length :: proc(state: ^Procedure_State, node: syntax.Node_Index, soa: types.Type_Id, address: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, soa))
	if descriptor.soa == .Fixed { return ir.const_int(function, .I64, descriptor.count) }
	_, _, spread := lower_soa_store_types(store, soa)
	offset, offset_error := types.field_offset(store, soa, spread)
	if offset_error != .None { return lower_fail(state, node, .Bounds) }
	return lower_load_word(state, ir.ptr_offset(function, address, offset), .I64)
}

@(private)
lower_soa_check_bounds :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Soa_Plan, address, index: ir.Node_Id) {
	if plan.policy != .Enabled { return }
	length := lower_soa_length(state, node, plan.soa, address)
	if state.failed || state.job.function.error != nil { return }
	lower_check(state, ir.compare(state.job.function, .ULt, index, length))
}

// The index as an I64 value, converting from narrower integers like an array index does.
@(private)
lower_soa_index_value :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Soa_Plan) -> ir.Node_Id {
	function := state.job.function
	index := lower_operand(state, plan.index)
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[index] != .I64 {
		index = ir.convert(function, .Sext if signed_type(state, operand_type(state, plan.index)) else .Zext, index, .I64)
	}
	return index
}

// One spread field: a constant field selects its base directly, a runtime
// component chains selects over the component pointers (lb_soa_array_component_elem_ptr).
@(private)
lower_soa_component_base :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	soa: types.Type_Id,
	address, index: ir.Node_Id,
	field: check.Operand,
	spread: int,
) -> ir.Node_Id {
	function := state.job.function
	if id, is_const := field.(check.Const_Id); is_const {
		constant := check.constant(state.job.program, id)
		if constant != nil {
			if integer, is_integer := constant.value.(big.Int); is_integer {
				if value, value_error := big.int_get_i64(&integer); value_error == nil {
					return lower_soa_component_ptr(state, node, soa, address, index, int(value))
				}
			}
		}
		return lower_fail(state, node, .Expression)
	}
	component := lower_operand(state, field)
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[component] != .I64 {
		component = ir.convert(function, .Sext if signed_type(state, operand_type(state, field)) else .Zext, component, .I64)
	}
	base := lower_soa_component_ptr(state, node, soa, address, index, 0)
	if state.failed || function.error != nil { return 0 }
	for candidate in 1 ..< spread {
		other := lower_soa_component_ptr(state, node, soa, address, index, candidate)
		if state.failed || function.error != nil { return 0 }
		selected := ir.compare(function, .Eq, component, ir.const_int(function, .I64, i64(candidate)))
		base = ir.select(function, selected, other, base)
	}
	return base
}

// The address of one component's element: the fixed array's slot offset, or
// the loaded slice pointer offset, advanced by the element size.
@(private)
lower_soa_component_ptr :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	soa: types.Type_Id,
	address, index: ir.Node_Id,
	component: int,
) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, soa))
	field_type := types.get(store, types.resolve_named(store, descriptor.fields[component].type))
	layout := state.job.layouts[field_type.elem]
	if layout.error != .None || layout.size <= 0 || layout.size > i64(max(u32)) { return lower_fail(state, node, .Place) }
	offset, offset_error := types.field_offset(store, soa, component)
	if offset_error != .None { return lower_fail(state, node, .Place) }
	field_address := ir.ptr_offset(function, address, offset)
	if descriptor.soa != .Fixed {
		field_address = lower_load_word(state, field_address, .Ptr)
		if state.failed || function.error != nil { return 0 }
	}
	return ir.ptr_index(function, field_address, index, u32(layout.size))
}

// The address of a field element, bounds-checked by the plan policy. A whole
// element has no address: it is scattered, like the official lbAddr_SoaVariable
// which the generic lb_addr_get_ptr deliberately panics on.
@(private)
lower_soa_field_address :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Soa_Plan) -> ir.Node_Id {
	if plan.field == nil { return lower_fail(state, node, .Place) }
	address := lower_soa_container_address(state, plan.container)
	if state.failed || state.job.function.error != nil { return 0 }
	index := lower_soa_index_value(state, node, plan)
	if state.failed || state.job.function.error != nil { return 0 }
	lower_soa_check_bounds(state, node, plan, address, index)
	if state.failed || state.job.function.error != nil { return 0 }
	store := check.type_store(state.job.program)
	_, _, spread := lower_soa_store_types(store, plan.soa)
	return lower_soa_component_base(state, node, plan.soa, address, index, plan.field, spread)
}

// A field loads like any lvalue; a whole element gathers field by field into a slot.
@(private)
lower_soa_value :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Soa_Plan) -> ir.Node_Id {
	if plan.field != nil {
		address := lower_soa_field_address(state, node, plan)
		if state.failed || state.job.function.error != nil { return 0 }
		return lower_load(state, address, lower_info(state, node).type)
	}
	function := state.job.function
	store := check.type_store(state.job.program)
	_, elem, spread := lower_soa_store_types(store, plan.soa)
	layout := state.job.layouts[elem]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Expression) }
	address := lower_soa_container_address(state, plan.container)
	if state.failed || function.error != nil { return 0 }
	index := lower_soa_index_value(state, node, plan)
	if state.failed || function.error != nil { return 0 }
	lower_soa_check_bounds(state, node, plan, address, index)
	if state.failed || function.error != nil { return 0 }
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	core := types.get(store, types.core_type(store, elem))
	for component in 0 ..< spread {
		field_type := core.fields[component].type if core.kind == .Struct else core.elem
		source := lower_soa_component_ptr(state, node, plan.soa, address, index, component)
		if state.failed || function.error != nil { return 0 }
		offset, offset_error := types.field_offset(store, elem, component)
		if offset_error != .None { return lower_fail(state, node, .Expression) }
		lower_store(state, ir.ptr_offset(function, slot, offset), lower_load(state, source, field_type), field_type)
		if state.failed { return 0 }
	}
	return slot
}

// A whole element scatters field by field; a field stores like any lvalue.
@(private)
lower_soa_whole_address :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Soa_Plan) -> (address, index: ir.Node_Id) {
	address = lower_soa_container_address(state, plan.container)
	if state.failed || state.job.function.error != nil { return 0, 0 }
	index = lower_soa_index_value(state, node, plan)
	if state.failed || state.job.function.error != nil { return 0, 0 }
	lower_soa_check_bounds(state, node, plan, address, index)
	if state.failed || state.job.function.error != nil { return 0, 0 }
	return address, index
}

// Scatters a gathered element value into the addressed whole element.
@(private)
lower_soa_whole_scatter :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Soa_Plan, address, index, value: ir.Node_Id) {
	function := state.job.function
	store := check.type_store(state.job.program)
	_, elem, spread := lower_soa_store_types(store, plan.soa)
	core := types.get(store, types.core_type(store, elem))
	for component in 0 ..< spread {
		field_type := core.fields[component].type if core.kind == .Struct else core.elem
		destination := lower_soa_component_ptr(state, node, plan.soa, address, index, component)
		if state.failed || function.error != nil { return }
		offset, offset_error := types.field_offset(store, elem, component)
		if offset_error != .None { lower_fail(state, node, .Local); return }
		lower_store(state, destination, lower_load(state, ir.ptr_offset(function, value, offset), field_type), field_type)
		if state.failed { return }
	}
}

// A whole element scatters field by field; a field stores like any lvalue.
@(private)
lower_soa_store :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Soa_Plan, value: ir.Node_Id) {
	if plan.field != nil {
		address := lower_soa_field_address(state, node, plan)
		if state.failed || state.job.function.error != nil { return }
		lower_store(state, address, value, lower_info(state, node).type)
		return
	}
	address, index := lower_soa_whole_address(state, node, plan)
	if state.failed || state.job.function.error != nil { return }
	lower_soa_whole_scatter(state, node, plan, address, index, value)
}

// One address per swizzle lane: the spread column of the named component at
// the element index. The element index keeps the plan bounds check; the lanes
// themselves were proven in range by the checker.
@(private)
lower_soa_swizzle_destination :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	soa: check.Soa_Plan,
	swizzle: check.Swizzle_Plan,
	type: types.Type_Id,
) -> Assignment_Destination {
	function := state.job.function
	lanes, allocation_error := make([]ir.Node_Id, swizzle.count, virtual.arena_allocator(&function.arena))
	if allocation_error != nil { state.failed = true; return {} }
	result := Assignment_Destination {
		lanes      = lanes,
		type       = type,
		lane_count = swizzle.count,
	}
	address, index := lower_soa_whole_address(state, node, soa)
	if state.failed || function.error != nil { return {} }
	for lane in 0 ..< swizzle.count {
		lanes[lane] = lower_soa_component_ptr(state, node, soa.soa, address, index, int(swizzle.indices[lane]))
		if state.failed || function.error != nil { return {} }
	}
	return result
}

// Whether an assignment destination is a swizzle over a direct #soa element,
// rather than over a contiguous array or an #soa pointer value owned elsewhere.
@(private)
lower_soa_swizzle_plans :: proc(state: ^Procedure_State, operand: check.Operand) -> (soa: check.Soa_Plan, swizzle: check.Swizzle_Plan, found: bool) {
	reference, is_reference := operand.(check.Expression_Ref)
	if !is_reference { return {}, {}, false }
	info, ok := check.expression_info(state.job.program, reference.view, reference.node)
	if !ok || info.state != .Checked || info.plan == 0 { return {}, {}, false }
	plan := check.plan(state.job.program, info.plan)
	if plan == nil { return {}, {}, false }
	swizzle_plan, is_swizzle := plan^.(check.Swizzle_Plan)
	if !is_swizzle { return {}, {}, false }
	root, is_root := swizzle_plan.root.(check.Expression_Ref)
	if is_root {
		root_info, root_ok := check.expression_info(state.job.program, root.view, root.node)
		if root_ok && root_info.state == .Checked && root_info.plan != 0 {
			root_plan := check.plan(state.job.program, root_info.plan)
			if root_plan != nil {
				if soa_plan, is_soa := root_plan^.(check.Soa_Plan); is_soa && soa_plan.field == nil {
					if lower_type(state, operand_type(state, soa_plan.container)).kind != .Soa_Pointer {
						return soa_plan, swizzle_plan, true
					}
				}
			}
		}
	}
	return {}, {}, false
}

// Compound assignment to an #soa swizzle stores each distinct lane once, on
// its first occurrence, as the official backend does (llvm_backend_stmt.cpp):
// `v.xx += rhs` keeps the lane-0 result and drops the lane-1 one. Reports
// whether the destination was an #soa swizzle owned here.
@(private)
lower_soa_swizzle_compound :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	operand: check.Operand,
	destination: Assignment_Destination,
	value: ir.Node_Id,
) -> bool {
	_, swizzle, found := lower_soa_swizzle_plans(state, operand)
	if !found { return false }
	function := state.job.function
	previous := lower_swizzle_read(state, destination)
	if state.failed || function.error != nil { return true }
	result := lower_compound_operator(state, node, operator, previous, value, destination.type)
	if state.failed || function.error != nil { return true }
	descriptor := lower_type(state, destination.type)
	stride := state.job.layouts[descriptor.elem].size
	results, allocation_error := make([]ir.Node_Id, destination.lane_count, virtual.arena_allocator(&function.arena))
	if allocation_error != nil { state.failed = true; return true }
	for lane in 0 ..< destination.lane_count {
		results[lane] = lower_load(state, ir.ptr_offset(function, result, i64(lane) * stride), descriptor.elem)
	}
	handled := [4]bool{}
	for lane in 0 ..< destination.lane_count {
		component := swizzle.indices[lane]
		if component < 0 || component >= 4 || handled[component] { continue }
		handled[component] = true
		lower_store(state, destination.lanes[lane], results[lane], descriptor.elem)
	}
	return true
}

// Slicing offsets each field pointer by the low bound and adjusts the hidden
// length, as the official soa slice backend does (llvm_backend_expr.cpp).
@(private)
lower_soa_slice :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Bounds_Plan) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	container_type := operand_type(state, plan.operands[0])
	descriptor := lower_type(state, container_type)
	if descriptor.kind == .Pointer { descriptor = lower_type(state, descriptor.elem) }
	if descriptor.kind != .Struct || descriptor.soa == .None { return lower_fail(state, node, .Bounds) }
	address := lower_operand(state, plan.operands[0])
	if state.failed || function.error != nil { return 0 }
	base_soa := types.resolve_named(store, container_type)
	if lower_type(state, container_type).kind == .Pointer {
		base_soa = types.resolve_named(store, lower_type(state, container_type).elem)
	}
	length := lower_soa_length(state, node, base_soa, address)
	if state.failed || function.error != nil { return 0 }
	low := lower_bound(state, plan.operands[1], ir.const_int(function, .I64, 0))
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[low] != .I64 { return lower_fail(state, node, .Bounds) }
	high := lower_bound(state, plan.operands[2], length)
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[high] != .I64 { return lower_fail(state, node, .Bounds) }
	if plan.policy == .Enabled {
		lower_check(state, ir.compare(function, .ULe, high, length))
		lower_check(state, ir.compare(function, .ULe, low, high))
	}
	result := lower_info(state, node).type
	layout := state.job.layouts[result]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Bounds) }
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	_, _, spread := lower_soa_store_types(store, base_soa)
	for component in 0 ..< spread {
		component_type := types.get(store, types.resolve_named(store, descriptor.fields[component].type))
		component_layout := state.job.layouts[component_type.elem]
		if component_layout.error != .None || component_layout.size <= 0 || component_layout.size > i64(max(u32)) {
			return lower_fail(state, node, .Bounds)
		}
		offset, offset_error := types.field_offset(store, base_soa, component)
		if offset_error != .None { return lower_fail(state, node, .Bounds) }
		source := ir.ptr_offset(function, address, offset)
		if descriptor.soa == .Fixed {
			source = ir.ptr_index(function, source, low, u32(component_layout.size))
		} else {
			source = ir.ptr_index(function, lower_load_word(state, source, .Ptr), low, u32(component_layout.size))
		}
		if state.failed || function.error != nil { return 0 }
		destination_offset, destination_error := types.field_offset(store, result, component)
		if destination_error != .None { return lower_fail(state, node, .Bounds) }
		lower_store_word(state, ir.ptr_offset(function, slot, destination_offset), source)
	}
	length_offset, length_error := types.field_offset(store, result, spread)
	if length_error != .None { return lower_fail(state, node, .Bounds) }
	lower_store_word(state, ir.ptr_offset(function, slot, length_offset), ir.binary(function, .Sub, high, low))
	return slot
}

// len and cap read the hidden fields of an #soa slice or dynamic array.
// Fixed arrays answer at compile time and never reach here.
@(private)
lower_soa_len_cap :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	capacity: bool,
) -> (
	value: ir.Node_Id,
	handled: bool,
) {
	argument_type := operand_type(state, plan.arguments[0])
	descriptor := lower_type(state, argument_type)
	if descriptor.kind == .Pointer { descriptor = lower_type(state, descriptor.elem) }
	if descriptor.kind != .Struct || descriptor.soa == .None { return 0, false }
	_ = info
	store := check.type_store(state.job.program)
	soa := types.resolve_named(store, argument_type)
	if lower_type(state, argument_type).kind == .Pointer {
		soa = types.resolve_named(store, lower_type(state, argument_type).elem)
	}
	_, _, spread := lower_soa_store_types(store, soa)
	field := spread if !capacity else spread + 1
	header := lower_operand(state, plan.arguments[0])
	if state.failed || state.job.function.error != nil { return 0, true }
	offset, offset_error := types.field_offset(store, soa, field)
	if offset_error != .None {
		failed := lower_fail(state, node, .Builtin)
		return failed, true
	}
	return lower_load_word(state, ir.ptr_offset(state.job.function, header, offset), .I64), true
}

// `for v[, i] in soa`: the container was snapshotted into a hidden entity at
// check time; each iteration advances a counter over the snapshot, and value
// uses lower through the recorded Soa_Plan. Mirrors lower_range_container.
@(private)
lower_range_soa :: proc(state: ^Procedure_State, node: syntax.Node_Index, parts: Range_Parts) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	lower_statement(state, parts.init)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	function := state.job.function
	info := lower_info(state, parts.expr)
	container_id := lower_type(state, info.type)
	is_pointer := container_id.kind == .Pointer
	if is_pointer { container_id = lower_type(state, container_id.elem) }
	if container_id.kind != .Struct || container_id.soa == .None { lower_fail(state, node, .Range); return }
	store := check.type_store(state.job.program)
	soa := types.resolve_named(store, info.type)
	if lower_type(state, info.type).kind == .Pointer {
		soa = types.resolve_named(store, lower_type(state, info.type).elem)
	}
	value_entity: check.Entity_Id
	plan: check.Soa_Plan
	has_plan := false
	// A `&v` value writes through the snapshot, so a fixed container must
	// snapshot the address of the variable's storage, not a gathered copy.
	// Slice and dynamic headers share their columns through any copy, and a
	// pointer already evaluates to the container address.
	value_reference := false
	if len(parts.names) >= 1 {
		_, value_reference = range_name_node(state, parts.names[0])
		value_entity = range_entity(state, parts.names[0])
		if state.failed { return }
		if value_entity != 0 {
			value_node, _ := range_name_node(state, parts.names[0])
			use := lower_info(state, value_node)
			if state.failed { return }
			if use.plan != 0 {
				if loop, is_loop := check.plan(state.job.program, use.plan)^.(check.Soa_Plan); is_loop {
					plan, has_plan = loop, true
				}
			}
			if !has_plan { lower_fail(state, node, .Range); return }
		}
	}
	snapshot: ir.Node_Id
	if has_plan {
		container_entity, is_entity := plan.container.(check.Entity_Id)
		if !is_entity { lower_fail(state, node, .Range); return }
		if value_reference && !is_pointer && container_id.soa == .Fixed && info.mode == .Variable {
			// Fixed columns live inline: bind the variable's storage address
			// itself, so reference writes scatter into the container.
			bind_reference_local(state, container_entity, lower_address(state, parts.expr))
		} else {
			bind_local(state, container_entity, lower_value(state, parts.expr), true)
		}
		if state.failed || function.error != nil { return }
		snapshot = lower_operand(state, plan.container)
	} else {
		snapshot = lower_value(state, parts.expr)
	}
	if state.failed || function.error != nil { return }
	length := lower_soa_length(state, node, soa, snapshot)
	if state.failed || function.error != nil { return }
	length_variable := ir.Variable(0)
	length_is_variable := false
	if function.nodes.kind[length] != .Const_Int {
		length_variable = ir.variable_declare(state.builder, length)
		length_is_variable = true
	}
	index_entity: check.Entity_Id
	if has_plan {
		entity, is_entity := plan.index.(check.Entity_Id)
		if !is_entity { lower_fail(state, node, .Range); return }
		index_entity = entity
	} else if len(parts.names) == 2 {
		index_entity = range_entity(state, parts.names[1])
		if state.failed { return }
	}
	if index_entity != 0 {
		bind_local(state, index_entity, ir.const_int(function, .I64, 0), true)
		if state.failed { return }
	}
	counter := ir.Variable(0)
	if index_entity != 0 && state.locals[index_entity].kind == .Variable {
		counter = state.locals[index_entity].variable
	} else {
		counter = ir.variable_declare(state.builder, ir.const_int(function, .I64, 0))
	}
	variables, variables_ok := range_loop_variables(state, parts.body, counter)
	if !variables_ok { return }
	end := ir.jump_target_make(state.builder)
	loop := ir.loop_begin(state.builder, variables)
	continuation := ir.jump_target_make(state.builder)
	if !push_control_target(
		state,
		{node = {state.job.procedure.body.file, node}, break_target = end, continue_target = continuation, is_loop = true},
	) { return }
	defer pop(&state.control_targets)
	current := ir.variable_get(state.builder, counter)
	count := length
	if length_is_variable { count = ir.variable_get(state.builder, length_variable) }
	branch := ir.branch_if(state.builder, ir.compare(function, .ULt, current, count))
	ir.enter_arm(state.builder, branch, 1)
	ir.jump_to(state.builder, end)
	ir.enter_arm(state.builder, branch, 0)
	position := current
	if parts.reverse {
		position = ir.binary(function, .Sub, count, ir.binary(function, .Add, current, ir.const_int(function, .I64, 1)))
	}
	iteration := local_scope(state)
	if index_entity != 0 {
		ir.variable_set(state.builder, state.locals[index_entity].variable, position)
	}
	lower_statement(state, parts.body)
	leave_local_scope(state, iteration)
	if state.failed || function.error != nil { return }
	ir.jump_to(state.builder, continuation)
	if ir.seal_target(state.builder, continuation) {
		next := ir.binary(function, .Add, ir.variable_get(state.builder, counter), ir.const_int(function, .I64, 1))
		ir.variable_set(state.builder, counter, next)
	}
	ir.loop_end(state.builder, loop)
	ir.seal_target(state.builder, end)
}

// Whole-element #soa destinations have no address, so the generic assignment
// loop cannot route them. When at least one destination is a scattered
// element, this evaluates every destination and value in the generic order
// and scatters the soa ones at write time. Returns false when there is
// nothing soa to do and the generic loop owns the plan.
@(private)
lower_soa_assignment_plan :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Assignment_Plan) -> bool {
	soa_plans := make([dynamic]check.Soa_Plan, len(plan.destinations), context.temp_allocator)
	soa_present := false
	for destination, index in plan.destinations {
		reference, is_reference := destination.(check.Expression_Ref)
		if !is_reference { continue }
		info, info_ok := check.expression_info(state.job.program, reference.view, reference.node)
		if !info_ok || info.state != .Checked || info.plan == 0 { continue }
		if whole, is_soa := check.plan(state.job.program, info.plan)^.(check.Soa_Plan); is_soa && whole.field == nil {
			soa_plans[index] = whole
			soa_present = true
		}
	}
	if !soa_present { return false }
	allocator := context.temp_allocator
	addresses := make([]ir.Node_Id, len(plan.destinations), allocator)
	indices := make([]ir.Node_Id, len(plan.destinations), allocator)
	generic := make([]Assignment_Destination, len(plan.destinations), allocator)
	destination_types := make([]types.Type_Id, len(plan.destinations), allocator)
	for destination, index in plan.destinations {
		if soa_plans[index].soa != 0 {
			addresses[index], indices[index] = lower_soa_whole_address(state, node, soa_plans[index])
			if state.failed || state.job.function.error != nil { return true }
		} else {
			generic[index] = lower_destination(state, destination)
			if state.failed || state.job.function.error != nil { return true }
			destination_types[index] = generic[index].type
		}
	}
	values := make([]ir.Node_Id, len(plan.values), allocator)
	projected_until := 0
	for value, index in plan.values {
		if index < projected_until { continue }
		if projection, projected := value.(check.Projection); projected {
			projected_until = lower_assignment_results(state, node, plan, projection, index, values)
			if state.failed || state.job.function.error != nil { return true }
			continue
		}
		if len(plan.conversions) != 0 && plan.conversions[index] != 0 {
			conversion := check.plan(state.job.program, plan.conversions[index])
			if conversion == nil { lower_fail(state, node, .Conversion); return true }
			if converted, ok := conversion^.(check.Conversion_Plan); ok {
				values[index] = lower_conversion(state, converted, node)
			} else {
				lower_fail(state, node, .Conversion)
				return true
			}
		} else {
			values[index] = lower_operand(state, value, destination_types[index])
			if !state.failed && state.job.function.error == nil && destination_types[index] != 0 && scalar_type(state, destination_types[index]) == .None {
				values[index] = lower_same_layout_conversion(
					state,
					node,
					check.Conversion_Plan{target = destination_types[index]},
					destination_types[index],
					values[index],
				)
			}
		}
		if state.failed || state.job.function.error != nil { return true }
	}
	for index in 0 ..< len(plan.destinations) {
		if soa_plans[index].soa != 0 {
			lower_soa_whole_scatter(state, node, soa_plans[index], addresses[index], indices[index], values[index])
		} else {
			write_destination(state, generic[index], values[index], node)
		}
		if state.failed || state.job.function.error != nil { return true }
	}
	return true
}

// A fixed `#soa[N]T` literal lists rows; the plan carries one row operand per
// index. Scatter each row's fields into the spread columns, leaving missing
// rows zeroed like a sparse array literal does.
@(private)
lower_soa_fixed_literal :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Aggregate_Plan, address: ir.Node_Id, size: i64) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	function := state.job.function
	store := check.type_store(state.job.program)
	owner := types.resolve_named(store, plan.type)
	descriptor := types.get(store, owner)
	elem := descriptor.soa_elem
	resolved_elem := types.resolve_named(store, elem)
	core := types.get(store, types.core_type(store, elem))
	spread := len(core.fields) if core.kind == .Struct else int(core.count)
	memory := ir.add_node(
		function,
		.Mem_Set,
		.Memory,
		{
			state.builder.control,
			ir.variable_get(state.builder, ir.MEMORY_VARIABLE),
			address,
			ir.const_int(function, .I8, 0),
			ir.const_int(function, .I64, size),
		},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	for value, position in plan.values {
		row := i64(plan.field_indices[position])
		row_address: ir.Node_Id
		if position < len(plan.conversions) && plan.conversions[position] != 0 {
			row_address = lower_declared_conversion(state, node, plan.conversions[position])
		} else {
			row_address = lower_operand(state, value, elem)
		}
		if state.failed { return 0 }
		for component in 0 ..< spread {
			field_type := core.fields[component].type if core.kind == .Struct else core.elem
			field_layout := state.job.layouts[field_type]
			if field_layout.error != .None || field_layout.size <= 0 { return lower_fail(state, node, .Expression) }
			source_offset: i64
			if core.kind == .Struct {
				offset, offset_error := types.field_offset(store, resolved_elem, component)
				if offset_error != .None { return lower_fail(state, node, .Expression) }
				source_offset = offset
			} else {
				source_offset = i64(component) * field_layout.size
			}
			column_offset, column_error := types.field_offset(store, owner, component)
			if column_error != .None { return lower_fail(state, node, .Expression) }
			destination := ir.ptr_offset(function, address, column_offset + row * field_layout.size)
			lower_store(state, destination, lower_load(state, ir.ptr_offset(function, row_address, source_offset), field_type), field_type)
			if state.failed { return 0 }
		}
	}
	return address
}
