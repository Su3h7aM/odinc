package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

Float_Edge_Case :: struct {
	name:      string,
	operation: syntax.Token_Kind,
	left:      u16,
	right:     u16,
	expected:  u16,
}

// Expected bits follow IEEE 754 binary16 with round-to-nearest-even.
FLOAT_EDGE_CASES := [?]Float_Edge_Case {
	{name = "smallest subnormal", operation = .Add, left = 0x0001, right = 0x0000, expected = 0x0001},
	{name = "subnormal plus zero", operation = .Add, left = 0x0003, right = 0x0000, expected = 0x0003},
	{name = "subnormal sum stays subnormal", operation = .Add, left = 0x0003, right = 0x0003, expected = 0x0006},
	{name = "subnormal doubling", operation = .Add, left = 0x0001, right = 0x0001, expected = 0x0002},
	{name = "overflow to infinity", operation = .Mul, left = 0x7bff, right = 0x4000, expected = 0x7c00},
	{name = "maximum finite", operation = .Add, left = 0x7bff, right = 0x0000, expected = 0x7bff},
	{name = "zero minus zero", operation = .Sub, left = 0x0000, right = 0x0000, expected = 0x0000},
	{name = "negative subnormal", operation = .Sub, left = 0x0000, right = 0x0001, expected = 0x8001},
}

@(test)
float16_edge_operations_round_like_binary16 :: proc(t: ^testing.T) {
	for test_case in FLOAT_EDGE_CASES {
		run_float16_edge(t, test_case)
	}
}

@(private)
run_float16_edge :: proc(t: ^testing.T, test_case: Float_Edge_Case) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	half := types.intern(&store, types.Type{kind = .Float, count = 2})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {half}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	left := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	right := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	operation := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = left, op = {kind = test_case.operation}, right = right})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {operation})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(left) - 1] = {
		type     = half,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(right) - 1] = {
		type     = half,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	facts[int(operation) - 1] = {
		type  = half,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.constant_table = fixture_clone(
		[]check.Constant {
			{},
			{type = half, value = check.Float_Value{bits = u64(test_case.left), width = 16}},
			{type = half, value = check.Float_Value{bits = u64(test_case.right), width = 16}},
		},
		allocator,
	)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expectf(t, u16(actual.value) == test_case.expected, "%s: got %04x, want %04x", test_case.name, u16(actual.value), test_case.expected)
}

@(test)
float16_negative_zero_round_trips :: proc(t: ^testing.T) {
	assert(transmute(f16)u16(0x8000) == 0.0)
	assert(transmute(f16)u16(0x0000) == 0.0)
	zero: f16 = 0
	negative_zero := -zero
	testing.expect_value(t, transmute(u16)negative_zero, u16(0x8000))
}

@(test)
float16_nan_quiet_bit_round_trips :: proc(t: ^testing.T) {
	nan := transmute(f16)u16(0x7e00)
	assert(nan != nan)
	assert(transmute(u16)nan == 0x7e00)
	assert(transmute(f16)u16(0xfe00) != transmute(f16)u16(0xfe00))
}

// Official-equivalent rounding: 65520 is the tie between 65504 (odd mantissa) and 65536, so it rounds to infinity.
@(test)
float16_from_f32_rounds_subnormal_and_overflow :: proc(t: ^testing.T) {
	tiny: f64 = 5.96e-8
	huge: f64 = 70000.0
	boundary: f64 = 65520.0
	below_boundary: f64 = 65519.0
	testing.expect_value(t, transmute(u16)f16(tiny), u16(0x0001))
	testing.expect_value(t, transmute(u16)f16(huge), u16(0x7c00))
	testing.expect_value(t, transmute(u16)f16(boundary), u16(0x7c00))
	testing.expect_value(t, transmute(u16)f16(below_boundary), u16(0x7bff))
}

@(test)
float16_f32_conversion_round_trip :: proc(t: ^testing.T) {
	value := f16(123.25)
	round_trip := f16(f32(value))
	testing.expect_value(t, transmute(u16)round_trip, u16(0x57b4))
}
