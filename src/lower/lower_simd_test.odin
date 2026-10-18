package lower

import "base:runtime"
import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// One builtin call of a test expression; `arguments` index earlier calls. `Unaligned_Load` also reads the global guard.
Simd_Call :: struct {
	kind:      check.Builtin_Kind,
	type:      types.Type_Id,
	arguments: []int,
	indices:   []i64,
}

// Procedure `() -> result` returning the last call of `calls`. The global `guard` of type `guard` is initialized
// from the decimal integer `initial`, whose 16 little-endian bytes are its lanes.
@(private)
run_simd_expression :: proc(
	t: ^testing.T,
	store: ^types.Store,
	allocator: runtime.Allocator,
	guard, result: types.Type_Id,
	initial: string,
	calls: []Simd_Call,
) -> (
	value: u64,
	ok: bool,
) {
	results := make([]types.Type_Id, 1, allocator)
	results[0] = result
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless, results = results})
	pointer := types.intern(store, types.Type{kind = .Pointer, elem = guard})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	global := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = global})
	nodes := make([]syntax.Node_Index, len(calls), allocator)
	kinds := make([]check.Builtin_Kind, len(calls) + 1, allocator)
	plans := make([]check.Plan, len(calls) + 1, allocator)
	index_constants: [dynamic]check.Constant
	defer delete(index_constants)
	for call, index in calls {
		arguments: [dynamic]syntax.Node_Index
		operands: [dynamic]check.Operand
		if call.kind == .Unaligned_Load {
			append(&arguments, address)
			append(&operands, check.Expression_Ref{1, address})
		}
		for argument in call.arguments {
			append(&arguments, nodes[argument])
			append(&operands, check.Expression_Ref{1, nodes[argument]})
		}
		for value in call.indices {
			index_value: big.Int
			testing.expect_value(t, big.int_set_from_integer(&index_value, value, allocator = allocator), big.Error.None)
			append(&arguments, syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{}))
			append(&operands, check.Const_Id(2 + len(index_constants)))
			append(
				&index_constants,
				check.Constant{type = types.intern(store, types.Type{kind = .Integer, name = "int", count = 8, signed = true}), value = index_value},
			)
		}
		callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		nodes[index] = syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, arguments[:])})
		kinds[index + 1] = call.kind
		plans[index + 1] = check.Builtin_Plan {
			builtin   = check.Builtin_Id(index + 1),
			arguments = fixture_clone(operands[:], allocator),
		}
		delete(arguments)
		delete(operands)
	}
	returned := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {nodes[len(nodes) - 1]})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {returned})})

	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	for &fact in facts {
		fact.state = .Checked
	}
	facts[int(global) - 1] = {
		type   = guard,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(address) - 1] = {
		type  = pointer,
		mode  = .Value,
		state = .Checked,
	}
	for call, index in calls {
		facts[int(nodes[index]) - 1] = {
			type  = call.type,
			mode  = .Value,
			plan  = check.Plan_Id(index + 1),
			state = .Checked,
		}
	}
	initial_value: big.Int
	if !testing.expect_value(t, big.int_atoi(&initial_value, initial, allocator = allocator), big.Error.None) { return 0, false }
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = guard}}, allocator)
	program := expression_fixture(&ast, store, allocator, body, signature, entities, facts, nil)
	program.builtin_kinds = fixture_clone(kinds, allocator)
	program.plan_table = plans
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "expression", type = signature},
			{entity = 2, kind = .Global, name = "guard", type = guard, alignment = 16},
		},
		allocator,
	)
	program.entity_symbols = fixture_clone([]check.Symbol_Id{0, 1, 2}, allocator)
	program.global_list = fixture_clone([]check.Global{{entity = 2, symbol = 2, type = guard, alignment = 16, initializer = 1}}, allocator)
	constants := make([dynamic]check.Constant, 0, 2 + len(index_constants), allocator)
	append(&constants, check.Constant{}, check.Constant{type = guard, value = initial_value})
	for constant in index_constants { append(&constants, constant) }
	program.constant_table = constants[:]
	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return 0, false }
	defer ir.module_destroy(&module)
	outcome, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	if !testing.expect_value(t, run_error, nil) || !testing.expect_value(t, outcome.outcome, ir.Interp_Outcome.Value) { return 0, false }
	return outcome.value, true
}

// Lanes 1 to 16 of bytes, as the 16 little-endian bytes of the guard.
@(private)
BYTE_LANES_1_TO_16 :: "21345817372864405881847059188222722561"

// f32 lanes 4.0, 2.0, 8.0 and 1.5, as the 16 little-endian bytes of the guard.
@(private)
FLOAT_LANES :: "84738284751404912540616815579492253696"

// f32 quiet NaN in all four lanes, as the 16 little-endian bytes of the guard.
@(private)
NAN_LANES :: "169808876501059712777343542120893382656"

@(private)
F32_NEGATIVE_ZEROS :: "170141183500083312998042844551658340352"

@(private)
F32_POSITIVE_THEN_NEGATIVE_ZERO :: "170141183460469231740910675752738881536"

@(private)
F32_NEGATIVE_THEN_POSITIVE_ZERO :: "39614081257132168798919458816"

@(private)
F64_NEGATIVE_ZEROS :: "170141183460469231740910675752738881536"

@(private)
F64_POSITIVE_THEN_NEGATIVE_ZERO :: "170141183460469231731687303715884105728"

@(private)
F64_NEGATIVE_THEN_POSITIVE_ZERO :: "9223372036854775808"

@(private)
simd_test_types :: proc(store: ^types.Store) -> (byte, vector: types.Type_Id) {
	byte = types.intern(store, types.Type{kind = .Integer, count = 1})
	vector = types.intern(store, types.Type{kind = .Simd_Vector, elem = byte, count = 16})
	return byte, vector
}

@(private)
expect_simd_reduce_min :: proc(
	t: ^testing.T,
	store: ^types.Store,
	allocator: runtime.Allocator,
	vector, float: types.Type_Id,
	initial: string,
	expected: u64,
) {
	calls := [?]Simd_Call{{kind = .Unaligned_Load, type = vector}, {kind = .Simd_Reduce_Min, type = float, arguments = []int{0}}}
	value, ok := run_simd_expression(t, store, allocator, vector, float, initial, calls[:])
	if ok { testing.expect_value(t, value, expected) }
}

@(test)
simd_indices_lanes_reduce_or :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call{{kind = .Simd_Indices, type = vector}, {kind = .Simd_Reduce_Or, type = byte, arguments = []int{0}}}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(15)) }
}

@(test)
unaligned_load_feeds_lanes_ne :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call {
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Indices, type = vector},
		{kind = .Simd_Lanes_Ne, type = vector, arguments = []int{0, 1}},
		{kind = .Simd_Reduce_Or, type = byte, arguments = []int{2}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(0xff)) }
}

@(test)
simd_select_picks_lanes_by_mask :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call {
		{kind = .Simd_Indices, type = vector},
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Lanes_Ne, type = vector, arguments = []int{0, 1}},
		{kind = .Simd_Select, type = vector, arguments = []int{2, 0, 1}},
		{kind = .Simd_Reduce_Or, type = byte, arguments = []int{3}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(15)) }
}

// The guard holds lanes 1 to 16, so the minimum lane is 1: a zero result would mean the copy was not made.
@(test)
unaligned_load_reduce_min_reads_guard_lanes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call{{kind = .Unaligned_Load, type = vector}, {kind = .Simd_Reduce_Min, type = byte, arguments = []int{0}}}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(1)) }
}

// Floating reduce_min of the guard lanes 4.0, 2.0, 8.0, 1.5 yields 1.5, whose bits are 0x3fc00000.
@(test)
simd_reduce_min_float_lanes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	float := types.intern(&store, types.Type{kind = .Float, count = 4})
	vector := types.intern(&store, types.Type{kind = .Simd_Vector, elem = float, count = 4})
	calls := [?]Simd_Call{{kind = .Unaligned_Load, type = vector}, {kind = .Simd_Reduce_Min, type = float, arguments = []int{0}}}
	value, ok := run_simd_expression(t, &store, allocator, vector, float, FLOAT_LANES, calls[:])
	if ok { testing.expect_value(t, value, u64(0x3fc00000)) }
}

@(test)
simd_reduce_min_preserves_negative_zero :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	f32 := types.intern(&store, types.Type{kind = .Float, count = 4})
	f32_vector := types.intern(&store, types.Type{kind = .Simd_Vector, elem = f32, count = 4})
	expect_simd_reduce_min(t, &store, allocator, f32_vector, f32, "0", 0)
	expect_simd_reduce_min(t, &store, allocator, f32_vector, f32, F32_NEGATIVE_ZEROS, 0x80000000)
	expect_simd_reduce_min(t, &store, allocator, f32_vector, f32, F32_POSITIVE_THEN_NEGATIVE_ZERO, 0x80000000)
	expect_simd_reduce_min(t, &store, allocator, f32_vector, f32, F32_NEGATIVE_THEN_POSITIVE_ZERO, 0x80000000)
	f64 := types.intern(&store, types.Type{kind = .Float, count = 8})
	f64_vector := types.intern(&store, types.Type{kind = .Simd_Vector, elem = f64, count = 2})
	expect_simd_reduce_min(t, &store, allocator, f64_vector, f64, "0", 0)
	expect_simd_reduce_min(t, &store, allocator, f64_vector, f64, F64_NEGATIVE_ZEROS, 0x8000000000000000)
	expect_simd_reduce_min(t, &store, allocator, f64_vector, f64, F64_POSITIVE_THEN_NEGATIVE_ZERO, 0x8000000000000000)
	expect_simd_reduce_min(t, &store, allocator, f64_vector, f64, F64_NEGATIVE_THEN_POSITIVE_ZERO, 0x8000000000000000)
}

// Float indices are the lane numbers as floats, so their minimum is 0.0.
@(test)
simd_indices_float_lanes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	float := types.intern(&store, types.Type{kind = .Float, count = 4})
	vector := types.intern(&store, types.Type{kind = .Simd_Vector, elem = float, count = 4})
	calls := [?]Simd_Call{{kind = .Simd_Indices, type = vector}, {kind = .Simd_Reduce_Min, type = float, arguments = []int{0}}}
	value, ok := run_simd_expression(t, &store, allocator, vector, float, FLOAT_LANES, calls[:])
	if ok { testing.expect_value(t, value, u64(0)) }
}

// NaN differs from every lane, as Odin's `!=` on floats: all lanes compare unequal.
@(test)
simd_lanes_ne_nan_lanes_differ :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	float := types.intern(&store, types.Type{kind = .Float, count = 4})
	vector := types.intern(&store, types.Type{kind = .Simd_Vector, elem = float, count = 4})
	word := types.intern(&store, types.Type{kind = .Integer, count = 4})
	mask := types.intern(&store, types.Type{kind = .Simd_Vector, elem = word, count = 4})
	calls := [?]Simd_Call {
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Indices, type = vector},
		{kind = .Simd_Lanes_Ne, type = mask, arguments = []int{1, 0}},
		{kind = .Simd_Reduce_Or, type = word, arguments = []int{2}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, word, NAN_LANES, calls[:])
	if ok { testing.expect_value(t, value, u64(0xffffffff)) }
}

@(test)
simd_extract_loads_dynamic_integer_and_float_lanes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, bytes := simd_test_types(&store)
	float := types.intern(&store, types.Type{kind = .Float, count = 4})
	floats := types.intern(&store, types.Type{kind = .Simd_Vector, elem = float, count = 4})
	index_pair := types.intern(&store, types.Type{kind = .Simd_Vector, elem = byte, count = 2})
	for example in ([?]struct {
			vector, element, indices: types.Type_Id,
			initial:                  string,
			expected:                 u64,
		}{{bytes, byte, bytes, BYTE_LANES_1_TO_16, 16}, {floats, float, index_pair, FLOAT_LANES, 0x40000000}}) {
		calls := [?]Simd_Call {
			{kind = .Unaligned_Load, type = example.vector},
			{kind = .Simd_Indices, type = example.indices},
			{kind = .Simd_Reduce_Or, type = byte, arguments = []int{1}},
			{kind = .Simd_Extract, type = example.element, arguments = []int{0, 2}},
		}
		value, ok := run_simd_expression(t, &store, allocator, example.vector, example.element, example.initial, calls[:])
		if ok { testing.expect_value(t, value, example.expected) }
	}
}

@(test)
simd_replace_writes_one_lane_of_a_copy :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, bytes := simd_test_types(&store)
	calls := [?]Simd_Call {
		{kind = .Unaligned_Load, type = bytes},
		{kind = .Simd_Indices, type = bytes},
		{kind = .Simd_Reduce_Or, type = byte, arguments = []int{1}},
		{kind = .Simd_Extract, type = byte, arguments = []int{0, 2}},
		{kind = .Simd_Reduce_Min, type = byte, arguments = []int{1}},
		{kind = .Simd_Replace, type = bytes, arguments = []int{0, 4, 3}},
		{kind = .Simd_Extract, type = byte, arguments = []int{5, 4}},
	}
	value, ok := run_simd_expression(t, &store, allocator, bytes, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(16)) }
}

// Guard lanes 1..16 doubled: their minimum is 2.
@(test)
simd_add_doubles_lanes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call {
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Add, type = vector, arguments = []int{0, 0}},
		{kind = .Simd_Reduce_Min, type = byte, arguments = []int{1}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(2)) }
}

// Lanes 1..16 doubled are 2..32. Result lane 2 takes index 15 of the second operand, which is 32.
@(test)
simd_shuffle_selects_lanes_from_both_operands :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	pair := types.intern(&store, types.Type{kind = .Simd_Vector, elem = byte, count = 4})
	calls := [?]Simd_Call {
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Add, type = vector, arguments = []int{0, 0}},
		{kind = .Simd_Shuffle, type = pair, arguments = []int{0, 1}, indices = []i64{17, 2, 31, 0}},
		{kind = .Simd_Extract, type = byte, arguments = []int{2}, indices = []i64{2}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(32)) }
}

// Minimum of the indices 0..15 and the guard lanes 1..16 is 0..15, whose bitwise or is 15.
@(test)
simd_min_takes_smaller_lanes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call {
		{kind = .Simd_Indices, type = vector},
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Min, type = vector, arguments = []int{0, 1}},
		{kind = .Simd_Reduce_Or, type = byte, arguments = []int{2}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(15)) }
}

// Lane i of guard & ~index is (i+1) & ~i; the or over all lanes is 1|2|4|8|16 = 31.
@(test)
simd_bit_and_not_clears_index_bits :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call {
		{kind = .Simd_Indices, type = vector},
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Bit_And_Not, type = vector, arguments = []int{1, 0}},
		{kind = .Simd_Reduce_Or, type = byte, arguments = []int{2}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(31)) }
}

// Every guard lane (i+1) is greater than its index i, so the all-ones mask covers each lane.
@(test)
simd_lanes_gt_compares_left_to_right :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call {
		{kind = .Simd_Indices, type = vector},
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Lanes_Gt, type = vector, arguments = []int{1, 0}},
		{kind = .Simd_Reduce_Or, type = byte, arguments = []int{2}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(0xff)) }
}

// Counts 2i give lanes (i+1) << 2i, zero for counts of 8 or more: their or is 1|8|48 = 57.
@(test)
simd_shl_zeroes_counts_past_the_width :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call {
		{kind = .Simd_Indices, type = vector},
		{kind = .Simd_Add, type = vector, arguments = []int{0, 0}},
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Shl, type = vector, arguments = []int{2, 1}},
		{kind = .Simd_Reduce_Or, type = byte, arguments = []int{3}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(57)) }
}

// The same counts masked to the width: the lanes (i+1) << (2i & 7) have or 253.
@(test)
simd_shl_masked_wraps_counts :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte, vector := simd_test_types(&store)
	calls := [?]Simd_Call {
		{kind = .Simd_Indices, type = vector},
		{kind = .Simd_Add, type = vector, arguments = []int{0, 0}},
		{kind = .Unaligned_Load, type = vector},
		{kind = .Simd_Shl_Masked, type = vector, arguments = []int{2, 1}},
		{kind = .Simd_Reduce_Or, type = byte, arguments = []int{3}},
	}
	value, ok := run_simd_expression(t, &store, allocator, vector, byte, BYTE_LANES_1_TO_16, calls[:])
	if ok { testing.expect_value(t, value, u64(253)) }
}

// Float16 index lane 2 is 2.0, whose half-precision bits are 0x4000.
@(test)
simd_indices_float16_lanes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	float := types.intern(&store, types.Type{kind = .Float, count = 2})
	vector := types.intern(&store, types.Type{kind = .Simd_Vector, elem = float, count = 4})
	calls := [?]Simd_Call{{kind = .Simd_Indices, type = vector}, {kind = .Simd_Extract, type = float, arguments = []int{0}, indices = []i64{2}}}
	value, ok := run_simd_expression(t, &store, allocator, vector, float, "0", calls[:])
	if ok { testing.expect_value(t, value, u64(0x4000)) }
}
