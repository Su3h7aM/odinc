package check

import "core:math/big"
import "core:mem"
import "core:strings"
import "oc:syntax"
import "oc:types"

@(private = "package")
scalar_extra_kind :: proc(kind: Builtin_Kind) -> bool {
	#partial switch kind {
	case .Fused_Mul_Add,
	     .Fixed_Point_Mul,
	     .Fixed_Point_Div,
	     .Fixed_Point_Mul_Sat,
	     .Fixed_Point_Div_Sat,
	     .Prefetch_Read_Instruction,
	     .Prefetch_Read_Data,
	     .Prefetch_Write_Instruction,
	     .Prefetch_Write_Data,
	     .Return_Address,
	     .Frame_Address,
	     .Stack_Pointer,
	     .Address_Of_Return_Address,
	     .Read_Cycle_Counter_Frequency:
		return true
	}
	return false
}

// `fused_mul_add`, the `fixed_point_*` family, `prefetch_*`, `return_address`, `frame_address`, `stack_pointer`,
// `address_of_return_address` and `read_cycle_counter_frequency`, with the operand rules and messages of check_builtin.cpp.
@(private = "package")
expression_scalar_extra :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	name: string,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if ellipsis { return expression_failure(checker, view, scope, node, .Invalid_Operand, extra_message(checker, "Invalid use of '..' in '", name, "'")) }
	#partial switch kind {
	case .Fused_Mul_Add:
		return expression_fused_mul_add(checker, view, scope, node, builtin, name, arguments)
	case .Fixed_Point_Mul, .Fixed_Point_Div, .Fixed_Point_Mul_Sat, .Fixed_Point_Div_Sat:
		return expression_fixed_point(checker, view, scope, node, builtin, name, arguments)
	case .Prefetch_Read_Instruction, .Prefetch_Read_Data, .Prefetch_Write_Instruction, .Prefetch_Write_Data:
		return expression_prefetch(checker, view, scope, node, builtin, name, arguments)
	case .Return_Address, .Frame_Address:
		return expression_frame_query(checker, view, scope, node, builtin, name, arguments)
	case .Stack_Pointer, .Address_Of_Return_Address:
		return expression_stack_query(checker, view, scope, node, builtin, kind, name, arguments)
	}
	return expression_failure(checker, view, scope, node, .Invalid_Operand, extra_message(checker, "'", name, "' is only allowed on arm64 targets"))
}

@(private = "package")
extra_message :: proc(checker: ^Expression_Checker, parts: ..string) -> string {
	return strings.concatenate(parts, mem.dynamic_arena_allocator(&checker.arena))
}

@(private = "package")
type_message :: proc(checker: ^Expression_Checker, prefix: string, name: string, middle: string, type: types.Type_Id) -> string {
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	return strings.concatenate({prefix, name, middle, types.type_text(checker.type_checker.store, type, allocator)}, allocator)
}

@(private = "package")
extra_plan :: proc(
	checker: ^Expression_Checker,
	scope: Scope_Id,
	builtin: Builtin_Id,
	operands: []Operand,
	type: types.Type_Id,
	mode: Addressing_Mode,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = type, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
expression_fused_mul_add :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	name: string,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) !=
	   3 { return expression_failure(checker, view, scope, node, .Invalid_Operand, extra_message(checker, "'", name, "' expects 3 arguments")) }
	store := checker.type_checker.store
	values: [3]Expression_Info
	result_type: types.Type_Id
	for argument, index in arguments {
		values[index] = check_expression(checker, view, scope, argument) or_return
		if values[index].state == .Invalid { return expression_poison(scope), nil }
		if result_type == 0 || types.is_untyped(store, result_type) && !types.is_untyped(store, values[index].type) { result_type = values[index].type }
	}
	for argument, index in arguments {
		values[index] = check_expression(checker, view, scope, argument, result_type) or_return
		if values[index].state == .Invalid { return expression_poison(scope), nil }
	}
	x := values[0]
	if types.is_untyped(store, x.type) {
		message := type_message(checker, "Expected a typed floating point value or #simd vector for '", name, "', got ", x.type)
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
	}
	descriptor := types.get(store, types.resolve_named(store, x.type))
	element := descriptor
	if descriptor.kind == .Simd_Vector { element = types.get(store, types.resolve_named(store, descriptor.elem)) }
	if x.mode == .Type || element.kind != .Float {
		message := type_message(checker, "Expected a floating point or #simd vector value for '", name, "', got ", x.type)
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
	}
	if element.endianness == .Big {
		message := type_message(checker, "Expected a float type of the same platform endianness for '", name, "', got ", x.type)
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
	}
	if values[1].type != x.type || values[2].type != x.type {
		allocator := mem.dynamic_arena_allocator(&checker.arena)
		message := strings.concatenate(
			{
				"Mismatched types for '",
				name,
				"', got ",
				types.type_text(store, x.type, allocator),
				" vs ",
				types.type_text(store, values[1].type, allocator),
				" vs ",
				types.type_text(store, values[2].type, allocator),
			},
			allocator,
		)
		return expression_failure(checker, view, scope, arguments[0], .Mismatched_Types, message)
	}
	operands := make([]Operand, 3, mem.dynamic_arena_allocator(&checker.arena)) or_return
	for argument, index in arguments { operands[index] = Expression_Ref{view, argument} }
	return extra_plan(checker, scope, builtin, operands, x.type, .Value)
}

// Reads a constant integer operand as an `i64`; a value outside the range saturates, which every caller then rejects.
@(private = "package")
constant_integer_operand :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	argument: syntax.Node_Index,
	message: string,
) -> (
	value: i64,
	operand: Operand,
	valid: bool,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	info := check_expression(checker, view, scope, argument, checker.default_integer) or_return
	if info.state == .Invalid { return 0, nil, false, nil }
	kind := types.get(store, types.resolve_named(store, info.type)).kind
	if info.mode != .Constant || info.mode == .Type || !conversion_integer(kind) {
		expression_failure(checker, view, scope, argument, .Expected_Integer_Constant, message) or_return
		return 0, nil, false, nil
	}
	integer, is_integer := constant_pool_get(checker.constants, info.constant).value.(big.Int)
	if !is_integer { return 0, nil, false, nil }
	converted, conversion_error := big.int_get_i64(&integer)
	if conversion_error != nil {
		negative, _ := big.int_is_negative(&integer)
		converted = -1 if negative else max(i64)
	}
	return converted, Operand(info.constant), true, nil
}

@(private = "file")
expression_fixed_point :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	name: string,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) !=
	   3 { return expression_failure(checker, view, scope, node, .Invalid_Operand, extra_message(checker, "'", name, "' expects 3 arguments")) }
	store := checker.type_checker.store
	x := check_expression(checker, view, scope, arguments[0]) or_return
	if x.state == .Invalid { return expression_poison(scope), nil }
	y := check_expression(checker, view, scope, arguments[1], x.type if !types.is_untyped(store, x.type) else 0) or_return
	if y.state == .Invalid { return expression_poison(scope), nil }
	if types.is_untyped(store, x.type) && !types.is_untyped(store, y.type) {
		x = check_expression(checker, view, scope, arguments[0], y.type) or_return
		if x.state == .Invalid { return expression_poison(scope), nil }
	}
	if x.type != y.type {
		allocator := mem.dynamic_arena_allocator(&checker.arena)
		message := strings.concatenate(
			{"Mismatched types for '", name, "', ", types.type_text(store, x.type, allocator), " vs ", types.type_text(store, y.type, allocator)},
			allocator,
		)
		return expression_failure(checker, view, scope, arguments[0], .Mismatched_Types, message)
	}
	descriptor := types.get(store, types.resolve_named(store, x.type))
	if x.mode == .Type || descriptor.kind != .Integer {
		message := type_message(checker, "Expected an integer type for '", name, "', got ", x.type)
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
	}
	scale, scale_operand, valid := constant_integer_operand(
		checker,
		view,
		scope,
		arguments[2],
		extra_message(checker, "Expected a constant integer for the scale in '", name, "'"),
	) or_return
	if !valid { return expression_poison(scope), nil }
	bits := descriptor.count * 8
	if scale <= 0 {
		return expression_failure(
			checker,
			view,
			scope,
			arguments[2],
			.Invalid_Operand,
			extra_message(checker, "Scale parameter in '", name, "' must be positive"),
		)
	}
	if scale > bits {
		message := extra_message(checker, "Scale parameter in '", name, "' is larger than the base integer bit width")
		return expression_failure(checker, view, scope, arguments[2], .Invalid_Operand, message)
	}
	if scale == bits && descriptor.signed {
		message := extra_message(checker, "Scale parameter in '", name, "' must be less than the bit width of a signed integer")
		return expression_failure(checker, view, scope, arguments[2], .Invalid_Operand, message)
	}
	operands := make([]Operand, 3, mem.dynamic_arena_allocator(&checker.arena)) or_return
	operands[0], operands[1], operands[2] = Expression_Ref{view, arguments[0]}, Expression_Ref{view, arguments[1]}, scale_operand
	return extra_plan(checker, scope, builtin, operands, x.type, .Value)
}

@(private = "file")
expression_prefetch :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	name: string,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) !=
	   2 { return expression_failure(checker, view, scope, node, .Invalid_Operand, extra_message(checker, "'", name, "' expects 2 arguments")) }
	store := checker.type_checker.store
	pointer := check_expression(checker, view, scope, arguments[0], types.intern(store, types.Type{kind = .Raw_Pointer})) or_return
	if pointer.state == .Invalid { return expression_poison(scope), nil }
	kind := types.get(store, types.resolve_named(store, pointer.type)).kind
	if pointer.mode == .Type || !(conversion_pointer(kind) || kind == .Untyped_Nil) {
		allocator := mem.dynamic_arena_allocator(&checker.arena)
		message := strings.concatenate(
			{"Cannot assign a value of type ", types.type_text(store, pointer.type, allocator), " to 'rawptr' in '", name, "'"},
			allocator,
		)
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
	}
	message := extra_message(checker, "Second argument to '", name, "' representing the locality must be an integer in the range 0..=3")
	locality, locality_operand, valid := constant_integer_operand(checker, view, scope, arguments[1], message) or_return
	if !valid { return expression_poison(scope), nil }
	if locality < 0 || locality > 3 { return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand, message) }
	operands := make([]Operand, 2, mem.dynamic_arena_allocator(&checker.arena)) or_return
	operands[0], operands[1] = Expression_Ref{view, arguments[0]}, locality_operand
	return extra_plan(checker, scope, builtin, operands, 0, .No_Value)
}

@(private = "file")
expression_frame_query :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	name: string,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) > 1 {
		return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand, extra_message(checker, "'", name, "' expects either 0 or 1 arguments"))
	}
	operands := make([]Operand, len(arguments), mem.dynamic_arena_allocator(&checker.arena)) or_return
	if len(arguments) == 1 {
		message := extra_message(checker, "'", name, "' expects a constant integer level")
		level, level_operand, valid := constant_integer_operand(checker, view, scope, arguments[0], message) or_return
		if !valid { return expression_poison(scope), nil }
		if level < 0 || level > i64(max(u32)) {
			return expression_failure(
				checker,
				view,
				scope,
				arguments[0],
				.Invalid_Operand,
				extra_message(checker, "'", name, "' expects a level in the range 0..=4294967295"),
			)
		}
		operands[0] = level_operand
	}
	return extra_plan(checker, scope, builtin, operands, types.intern(checker.type_checker.store, types.Type{kind = .Raw_Pointer}), .Value)
}

@(private = "file")
expression_stack_query :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	name: string,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) !=
	   0 { return expression_failure(checker, view, scope, node, .Invalid_Operand, extra_message(checker, "'", name, "' expects no arguments")) }
	store := checker.type_checker.store
	pointer := types.intern(store, types.Type{kind = .Raw_Pointer})
	if kind == .Address_Of_Return_Address { pointer = types.intern(store, types.Type{kind = .Pointer, elem = pointer}) }
	return extra_plan(checker, scope, builtin, nil, pointer, .Value)
}
