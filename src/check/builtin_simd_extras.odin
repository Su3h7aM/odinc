package check

import "core:mem"
import "core:strings"
import "oc:syntax"
import "oc:types"

@(private = "package")
simd_extra_kind :: proc(kind: Builtin_Kind) -> bool {
	#partial switch kind {
	case .Simd_Clamp,
	     .Simd_To_Bits,
	     .Simd_To_Bits_Signed,
	     .Simd_Lanes_Reverse,
	     .Simd_Lanes_Rotate_Left,
	     .Simd_Lanes_Rotate_Right,
	     .Simd_Odd_Even,
	     .Simd_Sums_Of_N,
	     .Simd_Pairwise_Add,
	     .Simd_Pairwise_Sub,
	     .Simd_Interleave,
	     .Simd_Deinterleave,
	     .Simd_Reduce_Any,
	     .Simd_Reduce_All,
	     .Simd_Extract_Lsbs:
		return true
	}
	return false
}

// The `#simd` intrinsics that only rearrange, combine or summarize lanes, with the operand rules and messages of check_builtin.cpp.
// `Simd_Deinterleave` is the one with several results: n vectors, or the vector itself for n = 1.
@(private = "package")
expression_simd_extra :: proc(
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
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	expected := 1
	#partial switch kind {
	case .Simd_Clamp:
		expected = 3
	case .Simd_Lanes_Rotate_Left, .Simd_Lanes_Rotate_Right, .Simd_Odd_Even, .Simd_Sums_Of_N, .Simd_Pairwise_Add, .Simd_Pairwise_Sub, .Simd_Deinterleave:
		expected = 2
	}
	if ellipsis || len(arguments) < expected || len(arguments) != expected && kind != .Simd_Interleave {
		return expression_failure(checker, view, scope, node, .Invalid_Operand, extra_message(checker, "'", name, "' has the wrong number of arguments"))
	}
	x := check_expression(checker, view, scope, arguments[0]) or_return
	if x.state == .Invalid { return expression_poison(scope), nil }
	vector := types.get(store, types.resolve_named(store, x.type))^
	if x.mode == .Type || vector.kind != .Simd_Vector {
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, extra_message(checker, "'", name, "' expected a simd vector type"))
	}
	element := types.get(store, types.resolve_named(store, vector.elem))^
	operands := make([]Operand, len(arguments), allocator) or_return
	operands[0] = Expression_Ref{view, arguments[0]}
	result := x.type
	results: []types.Type_Id
	#partial switch kind {
	case .Simd_Clamp, .Simd_Odd_Even, .Simd_Pairwise_Add, .Simd_Pairwise_Sub, .Simd_Interleave:
		for argument, index in arguments[1:] {
			other := check_expression(checker, view, scope, argument, x.type) or_return
			if other.state == .Invalid { return expression_poison(scope), nil }
			if types.get(store, types.resolve_named(store, other.type)).kind != .Simd_Vector || other.mode == .Type {
				return expression_failure(checker, view, scope, argument, .Invalid_Operand, extra_message(checker, "'", name, "' expected a simd vector type"))
			}
			if other.type != x.type {
				message := strings.concatenate(
					{
						"'",
						name,
						"' all argument types must match, expected ",
						types.type_text(store, x.type, allocator),
						", got ",
						types.type_text(store, other.type, allocator),
					},
					allocator,
				)
				return expression_failure(checker, view, scope, argument, .Mismatched_Types, message)
			}
			operands[index + 1] = Expression_Ref{view, argument}
		}
		if kind == .Simd_Clamp || kind == .Simd_Pairwise_Add || kind == .Simd_Pairwise_Sub {
			if element.kind != .Integer && element.kind != .Float {
				message := type_message(checker, "'", name, "' expected a #simd type with an integer or floating point element, got ", x.type)
				return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
			}
		}
		if (kind == .Simd_Pairwise_Add || kind == .Simd_Pairwise_Sub) && vector.count % 2 != 0 {
			message := type_message(checker, "'", name, "' expected a #simd type with an even lane count, got ", x.type)
			return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
		}
		if kind == .Simd_Interleave {
			count := vector.count * i64(len(arguments))
			if count > SIMD_ELEMENT_COUNT_MAX || count & (count - 1) != 0 {
				message := extra_message(checker, "'", name, "' must produce a power of two #simd count within the maximum")
				return expression_failure(checker, view, scope, node, .Invalid_Operand, message)
			}
			result = types.intern(store, types.Type{kind = .Simd_Vector, elem = vector.elem, count = count})
		}
	case .Simd_To_Bits, .Simd_To_Bits_Signed:
		size, _, layout_error := types.layout(store, vector.elem)
		if layout_error != .None || size < 1 || size > 8 {
			return expression_failure(
				checker,
				view,
				scope,
				arguments[0],
				.Invalid_Operand,
				extra_message(checker, "'", name, "' expected a simd vector of scalars"),
			)
		}
		bits := types.sized_integer(store, size, kind == .Simd_To_Bits_Signed)
		result = types.intern(store, types.Type{kind = .Simd_Vector, elem = bits, count = vector.count})
	case .Simd_Lanes_Rotate_Left, .Simd_Lanes_Rotate_Right:
		message := extra_message(checker, "'", name, "' expected a constant integer offset")
		_, offset, valid := constant_integer_operand(checker, view, scope, arguments[1], message) or_return
		if !valid { return expression_poison(scope), nil }
		operands[1] = offset
	case .Simd_Sums_Of_N:
		message := extra_message(checker, "Indices to '", name, "' must be constant integers")
		n, count, valid := constant_integer_operand(checker, view, scope, arguments[1], message) or_return
		if !valid { return expression_poison(scope), nil }
		if n < 0 { return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand, extra_message(checker, "Negative '", name, "' index")) }
		if n < 2 || n & (n - 1) != 0 {
			return expression_failure(
				checker,
				view,
				scope,
				arguments[1],
				.Invalid_Operand,
				extra_message(checker, "'", name, "' requires a power of two 'n' parameter >= 2"),
			)
		}
		if n > vector.count {
			message = extra_message(checker, "'", name, "' requires that the 'n' parameter is <= than the #simd length")
			return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand, message)
		}
		if vector.count % n != 0 {
			message = extra_message(checker, "'", name, "' requires the #simd length to be a multiple of the 'n' parameter")
			return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand, message)
		}
		operands[1] = count
		result = vector.elem if vector.count == n else types.intern(store, types.Type{kind = .Simd_Vector, elem = vector.elem, count = vector.count / n})
	case .Simd_Deinterleave:
		message := extra_message(checker, "'", name, "' expected a constant integer divisible by the count of the #simd vector")
		n, count, valid := constant_integer_operand(checker, view, scope, arguments[1], message) or_return
		if !valid { return expression_poison(scope), nil }
		if n < 1 || n > vector.count || vector.count % n != 0 { return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand, message) }
		operands[1] = count
		part := types.intern(store, types.Type{kind = .Simd_Vector, elem = vector.elem, count = vector.count / n})
		if n == 1 {
			result = part
		} else {
			results = make([]types.Type_Id, int(n), allocator) or_return
			for &member in results { member = part }
		}
	case .Simd_Reduce_Any, .Simd_Reduce_All:
		if element.kind != .Bool && element.kind != .Integer {
			message := type_message(checker, "'", name, "' expected a #simd type with a boolean or an integer element, got ", x.type)
			return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
		}
		result = types.TYPE_UNTYPED_BOOL
	case .Simd_Extract_Lsbs:
		if element.kind != .Bool && element.kind != .Integer && element.kind != .Rune {
			message := type_message(checker, "'", name, "' expected a #simd type with integer or boolean elements, got ", x.type)
			return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
		}
		if vector.count > 128 {
			message := type_message(checker, "'", name, "' would produce a bit_set of more than 128 bits, got ", x.type)
			return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand, message)
		}
		result = types.intern(
			store,
			types.Type {
				kind = .Bit_Set,
				elem = checker.default_integer,
				lower_bound = 0,
				upper_bound = vector.count - 1,
				enum_lower_bound = 0,
				enum_upper_bound = i128(vector.count - 1),
			},
		)
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands, results = results})) or_return
	if results != nil { return Expression_Info{mode = .No_Value, plan = plan, scope = scope, state = .Checked}, nil }
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}
