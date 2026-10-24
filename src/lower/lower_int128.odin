package lower

import "core:math/big"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A 128-bit integer is an aggregate: its value is the address of a 16-byte slot holding the low and high 64-bit words.
WIDE_BYTES :: 16

Wide_Words :: struct {
	low, high: ir.Node_Id,
}

@(private)
is_wide_integer :: proc(state: ^Procedure_State, id: types.Type_Id) -> bool {
	if id == 0 { return false }
	type := lower_type(state, id)
	if type.kind == .Bit_Set { return state.job.layouts[id].size == WIDE_BYTES }
	return type.kind == .Integer && state.job.layouts[id].size == WIDE_BYTES
}

@(private)
wide_load :: proc(state: ^Procedure_State, address: ir.Node_Id) -> Wide_Words {
	return Wide_Words{low = lower_load_word(state, address, .I64), high = lower_load_word(state, ir.ptr_offset(state.job.function, address, 8), .I64)}
}

@(private)
wide_store :: proc(state: ^Procedure_State, words: Wide_Words) -> ir.Node_Id {
	address := ir.stack_slot(state.job.function, state.entry_control, WIDE_BYTES, WIDE_BYTES)
	lower_store_word(state, address, words.low)
	lower_store_word(state, ir.ptr_offset(state.job.function, address, 8), words.high)
	return address
}

@(private)
wide_add :: proc(function: ^ir.Function, a, b: Wide_Words) -> Wide_Words {
	low := ir.binary(function, .Add, a.low, b.low)
	carry := ir.select(function, ir.compare(function, .ULt, low, a.low), ir.const_int(function, .I64, 1), ir.const_int(function, .I64, 0))
	high := ir.binary(function, .Add, ir.binary(function, .Add, a.high, b.high), carry)
	return Wide_Words{low = low, high = high}
}

@(private)
wide_sub :: proc(function: ^ir.Function, a, b: Wide_Words) -> Wide_Words {
	low := ir.binary(function, .Sub, a.low, b.low)
	borrow := ir.select(function, ir.compare(function, .ULt, a.low, b.low), ir.const_int(function, .I64, 1), ir.const_int(function, .I64, 0))
	high := ir.binary(function, .Sub, ir.binary(function, .Sub, a.high, b.high), borrow)
	return Wide_Words{low = low, high = high}
}

@(private)
wide_mul :: proc(function: ^ir.Function, a, b: Wide_Words) -> Wide_Words {
	cross := ir.binary(function, .Add, ir.binary(function, .Mul, a.low, b.high), ir.binary(function, .Mul, a.high, b.low))
	high := ir.binary(function, .Add, ir.binary(function, .Mul_Hi_U, a.low, b.low), cross)
	return Wide_Words{low = ir.binary(function, .Mul, a.low, b.low), high = high}
}

@(private)
wide_bitwise :: proc(function: ^ir.Function, kind: ir.Node_Kind, a, b: Wide_Words) -> Wide_Words {
	return Wide_Words{low = ir.binary(function, kind, a.low, b.low), high = ir.binary(function, kind, a.high, b.high)}
}

@(private)
wide_not :: proc(function: ^ir.Function, a: Wide_Words) -> Wide_Words {
	ones := ir.const_int(function, .I64, -1)
	return Wide_Words{low = ir.binary(function, .Xor, a.low, ones), high = ir.binary(function, .Xor, a.high, ones)}
}

// Counts at or above 64 are total in the IR: `Shl`, `Shr` give 0 and `Sar` gives sign fill, so each branch is built without a guard and `small` selects.
@(private)
wide_shift :: proc(function: ^ir.Function, kind: ir.Node_Kind, a: Wide_Words, count: ir.Node_Id) -> Wide_Words {
	zero := ir.const_int(function, .I64, 0)
	sixty_four := ir.const_int(function, .I64, 64)
	inverse := ir.binary(function, .Sub, sixty_four, count)
	excess := ir.binary(function, .Sub, count, sixty_four)
	small := ir.compare(function, .ULt, count, sixty_four)
	#partial switch kind {
	case .Shl:
		high_small := ir.binary(function, .Or, ir.binary(function, .Shl, a.high, count), ir.binary(function, .Shr, a.low, inverse))
		high_big := ir.binary(function, .Shl, a.low, excess)
		return Wide_Words {
			low = ir.select(function, small, ir.binary(function, .Shl, a.low, count), zero),
			high = ir.select(function, small, high_small, high_big),
		}
	case .Shr:
		low_small := ir.binary(function, .Or, ir.binary(function, .Shr, a.low, count), ir.binary(function, .Shl, a.high, inverse))
		low_big := ir.binary(function, .Shr, a.high, excess)
		return Wide_Words {
			low = ir.select(function, small, low_small, low_big),
			high = ir.select(function, small, ir.binary(function, .Shr, a.high, count), zero),
		}
	}
	low_small := ir.binary(function, .Or, ir.binary(function, .Shr, a.low, count), ir.binary(function, .Shl, a.high, inverse))
	low_big := ir.binary(function, .Sar, a.high, excess)
	high_big := ir.binary(function, .Sar, a.high, ir.const_int(function, .I64, 63))
	return Wide_Words {
		low = ir.select(function, small, low_small, low_big),
		high = ir.select(function, small, ir.binary(function, .Sar, a.high, count), high_big),
	}
}

@(private)
wide_equal :: proc(function: ^ir.Function, a, b: Wide_Words) -> ir.Node_Id {
	return ir.binary(function, .And, ir.compare(function, .Eq, a.low, b.low), ir.compare(function, .Eq, a.high, b.high))
}

@(private)
wide_less :: proc(function: ^ir.Function, a, b: Wide_Words, signed: bool) -> ir.Node_Id {
	high_kind := ir.Node_Kind.SLt if signed else ir.Node_Kind.ULt
	high_less := ir.compare(function, high_kind, a.high, b.high)
	high_equal := ir.compare(function, .Eq, a.high, b.high)
	low_less := ir.compare(function, .ULt, a.low, b.low)
	return ir.binary(function, .Or, high_less, ir.binary(function, .And, high_equal, low_less))
}

@(private)
bool_not :: proc(function: ^ir.Function, value: ir.Node_Id) -> ir.Node_Id {
	return ir.binary(function, .Xor, value, ir.const_int(function, .Bool, 1))
}

@(private)
wide_negate :: proc(function: ^ir.Function, value: Wide_Words) -> Wide_Words {
	zero := Wide_Words {
		low  = ir.const_int(function, .I64, 0),
		high = ir.const_int(function, .I64, 0),
	}
	return wide_sub(function, zero, value)
}

@(private)
wide_select :: proc(function: ^ir.Function, condition: ir.Node_Id, if_true, if_false: Wide_Words) -> Wide_Words {
	return Wide_Words{low = ir.select(function, condition, if_true.low, if_false.low), high = ir.select(function, condition, if_true.high, if_false.high)}
}

@(private)
wide_pick :: proc(function: ^ir.Function, a, b: Wide_Words, signed, want_min: bool) -> Wide_Words {
	less := wide_less(function, a, b, signed)
	if want_min { return wide_select(function, less, a, b) }
	return wide_select(function, less, b, a)
}

// Abs, min, max and clamp compare and select whole 128-bit words; the operands are addresses. Clamp is min(max(x, lo), hi).
@(private)
lower_wide_numeric_builtin :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Builtin_Plan, kind: check.Builtin_Kind) -> ir.Node_Id {
	function := state.job.function
	count := len(plan.arguments)
	signed := signed_type(state, operand_type(state, plan.arguments[0]))
	first := lower_operand(state, plan.arguments[0])
	if state.failed { return 0 }
	value := wide_load(state, first)
	if kind == .Abs {
		if count != 1 { return lower_fail(state, node, .Builtin) }
		if !signed { return first }
		zero := Wide_Words {
			low  = ir.const_int(function, .I64, 0),
			high = ir.const_int(function, .I64, 0),
		}
		negative := wide_less(function, value, zero, true)
		value = wide_select(function, negative, wide_negate(function, value), value)
		return wide_store(state, value)
	}
	if kind == .Clamp && count != 3 { return lower_fail(state, node, .Builtin) }
	for argument, index in plan.arguments[1:] {
		if !call_operand_valid(state, argument) { return lower_fail(state, node, .Builtin) }
		address := lower_operand(state, argument)
		if state.failed { return 0 }
		want_min := kind == .Min || (kind == .Clamp && index == 1)
		value = wide_pick(function, value, wide_load(state, address), signed, want_min)
	}
	return wide_store(state, value)
}

// Each bit intrinsic works on the 64-bit words: counts add or select the word that is nonzero, swaps exchange the halves.
@(private)
lower_wide_bit_intrinsic :: proc(state: ^Procedure_State, node: syntax.Node_Index, requested: check.Builtin_Kind, address: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	words := wide_load(state, address)
	kind := requested
	if kind == .Count_Leading_Ones || kind == .Count_Trailing_Ones {
		words = wide_not(function, words)
		kind = .Count_Leading_Zeros if kind == .Count_Leading_Ones else .Count_Trailing_Zeros
	}
	zero := ir.const_int(function, .I64, 0)
	sixty_four := ir.const_int(function, .I64, 64)
	#partial switch kind {
	case .Count_Ones:
		ones := ir.binary(function, .Add, ir.unary(function, .Popcnt, words.low), ir.unary(function, .Popcnt, words.high))
		return wide_store(state, Wide_Words{low = ones, high = zero})
	case .Count_Zeros:
		ones := ir.binary(function, .Add, ir.unary(function, .Popcnt, words.low), ir.unary(function, .Popcnt, words.high))
		return wide_store(state, Wide_Words{low = ir.binary(function, .Sub, ir.const_int(function, .I64, 128), ones), high = zero})
	case .Count_Leading_Zeros:
		high_count := ir.unary(function, .Clz, words.high)
		low_count := ir.binary(function, .Add, sixty_four, ir.unary(function, .Clz, words.low))
		count := ir.select(function, ir.compare(function, .Eq, words.high, zero), low_count, high_count)
		return wide_store(state, Wide_Words{low = count, high = zero})
	case .Count_Trailing_Zeros:
		low_count := ir.unary(function, .Ctz, words.low)
		high_count := ir.binary(function, .Add, sixty_four, ir.unary(function, .Ctz, words.high))
		count := ir.select(function, ir.compare(function, .Eq, words.low, zero), high_count, low_count)
		return wide_store(state, Wide_Words{low = count, high = zero})
	case .Byte_Swap:
		return wide_store(state, Wide_Words{low = ir.unary(function, .Bswap, words.high), high = ir.unary(function, .Bswap, words.low)})
	case .Reverse_Bits:
		return wide_store(state, Wide_Words{low = lower_reverse_bits(state, words.high), high = lower_reverse_bits(state, words.low)})
	}
	return lower_fail(state, node, .Builtin)
}

// Tests bit `offset` of a 128-bit set; offsets outside 0..<128 are not members.
@(private)
wide_bit_test :: proc(function: ^ir.Function, words: Wide_Words, offset: ir.Node_Id) -> ir.Node_Id {
	zero := ir.const_int(function, .I64, 0)
	word := ir.select(function, ir.compare(function, .ULt, offset, ir.const_int(function, .I64, 64)), words.low, words.high)
	shift := ir.binary(function, .And, offset, ir.const_int(function, .I64, 63))
	bit := ir.binary(function, .And, ir.binary(function, .Shr, word, shift), ir.const_int(function, .I64, 1))
	return ir.compare(function, .Ne, bit, zero)
}

// Bit sets combine as sets: `+` and `|` union, `-` and `&~` difference, `&` intersection, `~` symmetric difference.
@(private)
lower_wide_bit_set_operator :: proc(state: ^Procedure_State, node: syntax.Node_Index, operator: syntax.Token_Kind, left, right: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	a := wide_load(state, left)
	b := wide_load(state, right)
	zero := Wide_Words {
		low  = ir.const_int(function, .I64, 0),
		high = ir.const_int(function, .I64, 0),
	}
	#partial switch operator {
	case .Add, .Or:
		return wide_store(state, wide_bitwise(function, .Or, a, b))
	case .Sub, .And_Not:
		return wide_store(state, wide_bitwise(function, .And, a, wide_not(function, b)))
	case .And:
		return wide_store(state, wide_bitwise(function, .And, a, b))
	case .Xor:
		return wide_store(state, wide_bitwise(function, .Xor, a, b))
	case .Cmp_Eq:
		return wide_equal(function, a, b)
	case .Not_Eq:
		return bool_not(function, wide_equal(function, a, b))
	case .Lt_Eq:
		return wide_equal(function, wide_bitwise(function, .And, a, wide_not(function, b)), zero)
	case .Gt_Eq:
		return wide_equal(function, wide_bitwise(function, .And, b, wide_not(function, a)), zero)
	case .Lt:
		subset := wide_equal(function, wide_bitwise(function, .And, a, wide_not(function, b)), zero)
		return ir.binary(function, .And, subset, bool_not(function, wide_equal(function, a, b)))
	case .Gt:
		subset := wide_equal(function, wide_bitwise(function, .And, b, wide_not(function, a)), zero)
		return ir.binary(function, .And, subset, bool_not(function, wide_equal(function, a, b)))
	}
	return lower_fail(state, node, .Operator)
}

// Matches the scalar `SDiv`: the minimum divided by -1 is an arithmetic trap, whatever the division-by-zero policy.
@(private)
lower_minimum_quotient_trap :: proc(state: ^Procedure_State, dividend, divisor: Wide_Words) {
	function := state.job.function
	zero_words := Wide_Words {
		low  = ir.const_int(function, .I64, 0),
		high = ir.const_int(function, .I64, 0),
	}
	minimum := Wide_Words {
		low  = zero_words.low,
		high = ir.const_int(function, .I64, min(i64)),
	}
	minus_one := Wide_Words {
		low  = ir.const_int(function, .I64, -1),
		high = ir.const_int(function, .I64, -1),
	}
	overflow := ir.binary(function, .And, wide_equal(function, dividend, minimum), wide_equal(function, divisor, minus_one))
	one := ir.const_int(function, .I64, 1)
	ir.divide(
		function,
		.SDiv,
		state.builder.control,
		ir.select(function, overflow, ir.const_int(function, .I64, min(i64)), one),
		ir.select(function, overflow, ir.const_int(function, .I64, -1), one),
	)
}

// Restoring shift-subtract division over magnitudes, one quotient bit per iteration. Signs are applied afterwards.
@(private)
wide_divide :: proc(state: ^Procedure_State, operator: syntax.Token_Kind, signed: bool, dividend, divisor: Wide_Words) -> Wide_Words {
	function := state.job.function
	builder := state.builder
	zero := ir.const_int(function, .I64, 0)
	one := ir.const_int(function, .I64, 1)
	zero_words := Wide_Words {
		low  = zero,
		high = zero,
	}
	negative_dividend := ir.const_int(function, .Bool, 0)
	negative_divisor := negative_dividend
	if signed {
		negative_dividend = ir.compare(function, .SLt, dividend.high, zero)
		negative_divisor = ir.compare(function, .SLt, divisor.high, zero)
	}
	magnitude_dividend := wide_select(function, negative_dividend, wide_negate(function, dividend), dividend)
	magnitude_divisor := wide_select(function, negative_divisor, wide_negate(function, divisor), divisor)

	zero_divisor := wide_equal(function, divisor, zero_words)
	mode := check.sources(state.job.program)[int(state.job.procedure.body.file) - 1].policy.division_by_zero
	assert(mode != .Unspecified, "checker must resolve integer division policy")
	if mode == .Trap { lower_check(state, bool_not(function, zero_divisor)) }
	if signed && operator == .Quo { lower_minimum_quotient_trap(state, dividend, divisor) }

	count := len(builder.values)
	remainder_low := ir.variable_declare(builder, zero)
	remainder_high := ir.variable_declare(builder, zero)
	quotient_low := ir.variable_declare(builder, zero)
	quotient_high := ir.variable_declare(builder, zero)
	index := ir.variable_declare(builder, zero)
	end := ir.jump_target_make(builder)
	loop := ir.loop_begin(builder, []ir.Variable{remainder_low, remainder_high, quotient_low, quotient_high, index})
	branch := ir.branch_if(builder, ir.compare(function, .ULt, ir.variable_get(builder, index), ir.const_int(function, .I64, 128)))
	ir.enter_arm(builder, branch, 1)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 0)

	current := Wide_Words {
		low  = ir.variable_get(builder, remainder_low),
		high = ir.variable_get(builder, remainder_high),
	}
	quotient := Wide_Words {
		low  = ir.variable_get(builder, quotient_low),
		high = ir.variable_get(builder, quotient_high),
	}
	position := ir.binary(function, .Sub, ir.const_int(function, .I64, 127), ir.variable_get(builder, index))
	bit := ir.binary(function, .And, wide_shift(function, .Shr, magnitude_dividend, position).low, one)
	shifted := wide_shift(function, .Shl, current, one)
	shifted.low = ir.binary(function, .Or, shifted.low, bit)
	overflow := ir.compare(function, .Ne, ir.binary(function, .Shr, current.high, ir.const_int(function, .I64, 63)), zero)
	take := ir.binary(function, .Or, overflow, bool_not(function, wide_less(function, shifted, magnitude_divisor, false)))
	next := wide_select(function, take, wide_sub(function, shifted, magnitude_divisor), shifted)
	taken := ir.select(function, take, one, zero)
	next_quotient := Wide_Words {
		low  = ir.binary(function, .Or, quotient.low, ir.binary(function, .Shl, taken, position)),
		high = ir.binary(
			function,
			.Or,
			quotient.high,
			ir.binary(function, .Shl, taken, ir.binary(function, .Sub, position, ir.const_int(function, .I64, 64))),
		),
	}
	ir.variable_set(builder, remainder_low, next.low)
	ir.variable_set(builder, remainder_high, next.high)
	ir.variable_set(builder, quotient_low, next_quotient.low)
	ir.variable_set(builder, quotient_high, next_quotient.high)
	ir.variable_set(builder, index, ir.binary(function, .Add, ir.variable_get(builder, index), one))
	ir.loop_end(builder, loop)
	ir.seal_target(builder, end)

	result_quotient := Wide_Words {
		low  = ir.variable_get(builder, quotient_low),
		high = ir.variable_get(builder, quotient_high),
	}
	result_remainder := Wide_Words {
		low  = ir.variable_get(builder, remainder_low),
		high = ir.variable_get(builder, remainder_high),
	}
	ir.variables_truncate(builder, count)

	quotient_negative := ir.binary(function, .Xor, negative_dividend, negative_divisor)
	result_quotient = wide_select(function, quotient_negative, wide_negate(function, result_quotient), result_quotient)
	result_remainder = wide_select(function, negative_dividend, wide_negate(function, result_remainder), result_remainder)
	if operator == .Mod_Mod {
		nonzero := bool_not(function, wide_equal(function, result_remainder, zero_words))
		adjust := ir.binary(function, .And, ir.binary(function, .Xor, negative_dividend, negative_divisor), nonzero)
		result_remainder = wide_select(function, adjust, wide_add(function, result_remainder, divisor), result_remainder)
	}

	result := result_remainder if operator != .Quo else result_quotient
	if mode != .Trap {
		fallback := zero_words
		if operator == .Quo {
			#partial switch mode {
			case .Self:
				fallback = dividend
			case .All_Bits:
				fallback = Wide_Words {
					low  = ir.const_int(function, .I64, -1),
					high = ir.const_int(function, .I64, -1),
				}
			}
		} else if mode != .Self {
			fallback = dividend
		}
		result = wide_select(function, zero_divisor, fallback, result)
	}
	return result
}

// Converts an integer value to the 64-bit count or word, sign- or zero-extending by its type.
@(private)
widen_to_word :: proc(state: ^Procedure_State, value: ir.Node_Id, type: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	if function.nodes.type[value] == .I64 { return value }
	kind := ir.Node_Kind.Sext if signed_type(state, type) else ir.Node_Kind.Zext
	return ir.convert(function, kind, value, .I64)
}

@(private)
wide_count_word :: proc(state: ^Procedure_State, value: ir.Node_Id, signed_count: bool) -> ir.Node_Id {
	function := state.job.function
	#partial switch function.nodes.type[value] {
	case .Ptr:
		return lower_load_word(state, value, .I64)
	case .I64:
		return value
	}
	kind := ir.Node_Kind.Sext if signed_count else ir.Node_Kind.Zext
	return ir.convert(function, kind, value, .I64)
}

@(private)
lower_wide_binary :: proc(state: ^Procedure_State, node: syntax.Node_Index, expression: syntax.Binary_Expr, left, right: ir.Node_Id) -> ir.Node_Id {
	if lower_type(state, lower_info(state, expression.left).type).kind == .Bit_Set {
		return lower_wide_bit_set_operator(state, node, expression.op.kind, left, right)
	}
	signed := signed_type(state, lower_info(state, expression.left).type)
	count_signed := signed_type(state, lower_info(state, expression.right).type)
	return lower_wide_operator(state, node, expression.op.kind, signed, count_signed, left, right)
}

@(private)
lower_wide_operator :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	signed, count_signed: bool,
	left, right: ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	a := wide_load(state, left)
	#partial switch operator {
	case .Shl:
		return wide_store(state, wide_shift(function, .Shl, a, wide_count_word(state, right, count_signed)))
	case .Shr:
		kind := ir.Node_Kind.Sar if signed else ir.Node_Kind.Shr
		return wide_store(state, wide_shift(function, kind, a, wide_count_word(state, right, count_signed)))
	}
	b := wide_load(state, right)
	#partial switch operator {
	case .Add:
		return wide_store(state, wide_add(function, a, b))
	case .Sub:
		return wide_store(state, wide_sub(function, a, b))
	case .Mul:
		return wide_store(state, wide_mul(function, a, b))
	case .And:
		return wide_store(state, wide_bitwise(function, .And, a, b))
	case .Or:
		return wide_store(state, wide_bitwise(function, .Or, a, b))
	case .Xor:
		return wide_store(state, wide_bitwise(function, .Xor, a, b))
	case .And_Not:
		return wide_store(state, wide_bitwise(function, .And, a, wide_not(function, b)))
	case .Quo, .Mod, .Mod_Mod:
		return wide_store(state, wide_divide(state, operator, signed, a, b))
	case .Cmp_Eq:
		return wide_equal(function, a, b)
	case .Not_Eq:
		return bool_not(function, wide_equal(function, a, b))
	case .Lt:
		return wide_less(function, a, b, signed)
	case .Gt:
		return wide_less(function, b, a, signed)
	case .Lt_Eq:
		return bool_not(function, wide_less(function, b, a, signed))
	case .Gt_Eq:
		return bool_not(function, wide_less(function, a, b, signed))
	}
	return lower_fail(state, node, .Operator)
}

@(private)
compound_binary_operator :: proc(operator: syntax.Token_Kind) -> syntax.Token_Kind {
	#partial switch operator {
	case .Add_Eq:
		return .Add
	case .Sub_Eq:
		return .Sub
	case .Mul_Eq:
		return .Mul
	case .Quo_Eq:
		return .Quo
	case .Mod_Eq:
		return .Mod
	case .Mod_Mod_Eq:
		return .Mod_Mod
	case .And_Eq:
		return .And
	case .Or_Eq:
		return .Or
	case .Xor_Eq:
		return .Xor
	case .And_Not_Eq:
		return .And_Not
	case .Shl_Eq:
		return .Shl
	case .Shr_Eq:
		return .Shr
	}
	return operator
}

@(private)
lower_wide_unary :: proc(state: ^Procedure_State, node: syntax.Node_Index, operator: syntax.Token_Kind, operand: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	#partial switch operator {
	case .Add:
		return operand
	case .Sub:
		zero := Wide_Words {
			low  = ir.const_int(function, .I64, 0),
			high = ir.const_int(function, .I64, 0),
		}
		return wide_store(state, wide_sub(function, zero, wide_load(state, operand)))
	case .Xor:
		return wide_store(state, wide_not(function, wide_load(state, operand)))
	}
	return lower_fail(state, node, .Operator)
}

@(private)
lower_wide_constant :: proc(state: ^Procedure_State, value: big.Int) -> ir.Node_Id {
	function := state.job.function
	integer := value
	allocator := virtual.arena_allocator(&function.arena)
	negative, sign_error := big.int_is_negative(&integer, allocator)
	if sign_error != .None { return lower_constant_error(state, sign_error) }
	low, low_error := big.int_bitfield_extract(&integer, 0, 64, allocator)
	if low_error != .None { return lower_constant_error(state, low_error) }
	high, high_error := big.int_bitfield_extract(&integer, 64, 64, allocator)
	if high_error != .None { return lower_constant_error(state, high_error) }
	low_word, high_word := u64(low), u64(high)
	if negative {
		borrow: u64 = 1 if low_word != 0 else 0
		low_word, high_word = 0 - low_word, 0 - high_word - borrow
	}
	return wide_store(state, Wide_Words{low = ir.const_int(function, .I64, i64(low_word)), high = ir.const_int(function, .I64, i64(high_word))})
}

@(private)
lower_wide_conversion :: proc(state: ^Procedure_State, node: syntax.Node_Index, source, target: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	if is_wide_integer(state, target) {
		if is_wide_integer(state, source) || types.is_untyped(check.type_store(state.job.program), source) { return value }
		if float_source := scalar_type(state, source); float_source == .F32 || float_source == .F64 {
			float_value := value
			if float_source == .F32 { float_value = ir.convert(function, .Float_Ext, value, .F64) }
			declaration, found := lower_runtime_procedure(state, "fixdfti" if signed_type(state, target) else "fixunsdfti")
			if !found { return lower_fail(state, node, .Conversion) }
			low, high := lower_runtime_two_word_call(state, declaration, []ir.Node_Id{float_value})
			return wide_store(state, Wide_Words{low = low, high = high})
		}
		scalar := scalar_type(state, source)
		if (scalar < .I8 || scalar > .I64) && scalar != .Bool { return lower_fail(state, node, .Conversion) }
		low := widen_to_word(state, value, source)
		high := ir.const_int(function, .I64, 0)
		if signed_type(state, source) { high = ir.binary(function, .Sar, low, ir.const_int(function, .I64, 63)) }
		return wide_store(state, Wide_Words{low = low, high = high})
	}
	if scalar_type(state, target) == .F32 || scalar_type(state, target) == .F64 {
		declaration, found := lower_runtime_procedure(state, "floattidf" if signed_type(state, source) else "floattidf_unsigned")
		if !found { return lower_fail(state, node, .Conversion) }
		words := wide_load(state, value)
		result := lower_runtime_scalar_call(state, declaration, []ir.Node_Id{words.low, words.high})
		if scalar_type(state, target) == .F32 { return ir.convert(function, .Float_Trunc, result, .F32) }
		return result
	}
	scalar := scalar_type(state, target)
	if scalar < .I8 || scalar > .I64 { return lower_fail(state, node, .Conversion) }
	low := lower_load_word(state, value, .I64)
	if scalar == .I64 { return low }
	return ir.convert(function, .Trunc, low, scalar)
}

@(private)
lower_runtime_scalar_call :: proc(state: ^Procedure_State, declaration: Procedure_Declaration, arguments: []ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	callee := ir.symbol_addr(function, declaration.symbol)
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, call_signature(state, declaration), arguments)
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	return ir.add_node(function, .Proj, declaration.signature.results[0].type, {call}, {index = 1})
}
