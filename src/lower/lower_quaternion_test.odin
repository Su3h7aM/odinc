package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Quaternion binary operators lower to the Hamilton product and the conjugate-over-norm-squared
// quotient, matching base/runtime/internal.odin. Each case builds both operands and the expected
// value with the quaternion builtin, applies the operator, and compares against the expectation,
// so one run pins all four components including the non-commutative imaginary parts.
@(private)
quaternion_binary_case :: proc(t: ^testing.T, operator: syntax.Token_Kind, component_bytes: i64, left, right, expected: [4]f64) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	float := types.intern(&store, types.Type{kind = .Float, count = component_bytes})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	quaternion_type := types.intern(&store, types.Type{kind = .Quaternion, count = 4 * component_bytes})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	values := [3][4]f64{left, right, expected}
	arguments: [3][4]syntax.Node_Index
	builds: [3]syntax.Node_Index
	constants := make([dynamic]check.Constant, allocator)
	append(&constants, check.Constant{})
	for operand in 0 ..< 3 {
		callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		for component in 0 ..< 4 {
			literal := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
			// Plan arguments arrive in memory order imag, jmag, kmag, real,
			// while the case values list real, imag, jmag, kmag.
			append(
				&constants,
				check.Constant {
					type = float,
					value = check.Float_Value{bits = test_float_bits(values[operand][(component + 1) % 4], component_bytes), width = u8(component_bytes * 8)},
				},
			)
			arguments[operand][component] = literal
		}
		builds[operand] = syntax.ast_add_node(
			&ast,
			.Call_Expr,
			0,
			1,
			syntax.Call_Expr {
				expr = callee,
				args = syntax.ast_add_list(&ast, {arguments[operand][0], arguments[operand][1], arguments[operand][2], arguments[operand][3]}),
			},
		)
	}
	operation := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = builds[0], op = {kind = operator}, right = builds[1]})
	comparison := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = operation, op = {kind = .Cmp_Eq}, right = builds[2]})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {comparison})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	constant_id := 1
	for operand in 0 ..< 3 {
		for component in 0 ..< 4 {
			facts[int(arguments[operand][component]) - 1] = {
				type     = float,
				constant = check.Const_Id(constant_id),
				mode     = .Constant,
				state    = .Checked,
			}
			constant_id += 1
		}
		facts[int(builds[operand]) - 1] = {
			type  = quaternion_type,
			plan  = check.Plan_Id(operand + 1),
			mode  = .Value,
			state = .Checked,
		}
	}
	facts[int(operation) - 1] = {
		type  = quaternion_type,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(comparison) - 1] = {
		type  = boolean,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.constant_table = fixture_clone(constants[:], allocator)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{{}, .Quaternion}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Builtin_Plan {
				builtin = check.Builtin_Id(1),
				arguments = fixture_clone(
					[]check.Operand {
						check.Expression_Ref{1, arguments[0][0]},
						check.Expression_Ref{1, arguments[0][1]},
						check.Expression_Ref{1, arguments[0][2]},
						check.Expression_Ref{1, arguments[0][3]},
					},
					allocator,
				),
			},
			check.Builtin_Plan {
				builtin = check.Builtin_Id(1),
				arguments = fixture_clone(
					[]check.Operand {
						check.Expression_Ref{1, arguments[1][0]},
						check.Expression_Ref{1, arguments[1][1]},
						check.Expression_Ref{1, arguments[1][2]},
						check.Expression_Ref{1, arguments[1][3]},
					},
					allocator,
				),
			},
			check.Builtin_Plan {
				builtin = check.Builtin_Id(1),
				arguments = fixture_clone(
					[]check.Operand {
						check.Expression_Ref{1, arguments[2][0]},
						check.Expression_Ref{1, arguments[2][1]},
						check.Expression_Ref{1, arguments[2][2]},
						check.Expression_Ref{1, arguments[2][3]},
					},
					allocator,
				),
			},
		},
		allocator,
	)
	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(1))
}

@(private)
test_float_bits :: proc(value: f64, component_bytes: i64) -> u64 {
	if component_bytes == 8 { return transmute(u64)value }
	if component_bytes == 4 { return u64(transmute(u32)f32(value)) }
	return u64(transmute(u16)f16(value))
}

// The asymmetric pair distinguishes the Hamilton product from component-wise multiplication:
// (1+2i+3j+4k)*(5+6i+7j+8k) is -60+12i+30j+24k, while component-wise would be 5+12i+21j+32k.
@(test)
quaternion256_multiply_is_hamilton_product :: proc(t: ^testing.T) {
	quaternion_binary_case(t, .Mul, 8, {1, 2, 3, 4}, {5, 6, 7, 8}, {-60, 12, 30, 24})
}

// The reverse order differs in every imaginary part, proving `*` is not commutative.
@(test)
quaternion256_multiply_is_not_commutative :: proc(t: ^testing.T) {
	quaternion_binary_case(t, .Mul, 8, {5, 6, 7, 8}, {1, 2, 3, 4}, {-60, 20, 14, 32})
}

// Division multiplies by the conjugate over the norm squared: (70+8i+0j+16k)/174.
@(test)
quaternion256_divide_multiplies_conjugate_over_norm_squared :: proc(t: ^testing.T) {
	// Typed so every operation rounds to f64 exactly like the lowered quotient: the reciprocal
	// rounds once, then each component product rounds again. An untyped constant would fold the
	// whole expression in exact rational arithmetic and round only once, a different value.
	inverse_norm: f64 = 1.0 / (25.0 + 36.0 + 49.0 + 64.0)
	expected := [4]f64 {
		(((5.0 * 1.0 + 6.0 * 2.0) + 7.0 * 3.0) + 8.0 * 4.0) * inverse_norm,
		(((5.0 * 2.0 - 6.0 * 1.0) + 7.0 * 4.0) - 8.0 * 3.0) * inverse_norm,
		(((5.0 * 3.0 - 6.0 * 4.0) - 7.0 * 1.0) + 8.0 * 2.0) * inverse_norm,
		(((5.0 * 4.0 + 6.0 * 3.0) - 7.0 * 2.0) - 8.0 * 1.0) * inverse_norm,
	}
	quaternion_binary_case(t, .Quo, 8, {1, 2, 3, 4}, {5, 6, 7, 8}, expected)
}

// The f32 width computes the same Hamilton product as f64.
@(test)
quaternion128_multiply_is_hamilton_product :: proc(t: ^testing.T) {
	quaternion_binary_case(t, .Mul, 4, {1, 2, 3, 4}, {5, 6, 7, 8}, {-60, 12, 30, 24})
}

// The f16 width computes the Hamilton product in F32 like scalar f16 operations.
@(test)
quaternion64_multiply_is_hamilton_product :: proc(t: ^testing.T) {
	quaternion_binary_case(t, .Mul, 2, {1, 2, 3, 4}, {5, 6, 7, 8}, {-60, 12, 30, 24})
}

// The f16 width adds componentwise; the widened load is what keeps every lane exact.
@(test)
quaternion64_add_is_componentwise :: proc(t: ^testing.T) {
	quaternion_binary_case(t, .Add, 2, {1, 2, 3, 4}, {5, 6, 7, 8}, {6, 8, 10, 12})
}
