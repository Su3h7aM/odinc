package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A complex-to-quaternion conversion keeps the real and imaginary parts and zeroes the jmag and kmag
// lanes. Each case builds a complex value, converts it, and compares against the expected quaternion, so
// a swapped lane mapping fails: converting 1+2i must read back as 1+2i+0j+0k, never 2+1i+0j+0k.
@(private)
complex_to_quaternion_case :: proc(t: ^testing.T, source_bytes, target_bytes: i64, real, imag: f64) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	source_float := types.intern(&store, types.Type{kind = .Float, count = source_bytes})
	target_float := types.intern(&store, types.Type{kind = .Float, count = target_bytes})
	complex_type := types.intern(&store, types.Type{kind = .Complex, count = 2 * source_bytes})
	quaternion_type := types.intern(&store, types.Type{kind = .Quaternion, count = 4 * target_bytes})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	real_part := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	imaginary := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	build := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {real_part, imaginary})})
	conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {build})})
	// Expected components in memory order imag, jmag, kmag, real.
	lanes := [4]f64{imag, 0, 0, real}
	parts: [4]syntax.Node_Index
	for lane in 0 ..< 4 { parts[lane] = syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{}) }
	expected := syntax.ast_add_node(
		&ast,
		.Call_Expr,
		0,
		1,
		syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {parts[0], parts[1], parts[2], parts[3]})},
	)
	comparison := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = conversion, op = {kind = .Cmp_Eq}, right = expected})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {comparison})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(real_part) - 1] = {
		type     = source_float,
		constant = 1,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(imaginary) - 1] = {
		type     = source_float,
		constant = 2,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(build) - 1] = {
		type  = complex_type,
		plan  = 1,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(conversion) - 1] = {
		type  = quaternion_type,
		plan  = 2,
		mode  = .Value,
		state = .Checked,
	}
	for lane in 0 ..< 4 {
		facts[int(parts[lane]) - 1] = {
			type     = target_float,
			constant = check.Const_Id(3 + lane),
			mode     = .Constant,
			state    = .Checked,
		}
	}
	facts[int(expected) - 1] = {
		type  = quaternion_type,
		plan  = 3,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(comparison) - 1] = {
		type  = boolean,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	constants := make([dynamic]check.Constant, allocator)
	append(&constants, check.Constant{})
	append(
		&constants,
		check.Constant{type = source_float, value = check.Float_Value{bits = test_float_bits(real, source_bytes), width = u8(source_bytes * 8)}},
	)
	append(
		&constants,
		check.Constant{type = source_float, value = check.Float_Value{bits = test_float_bits(imag, source_bytes), width = u8(source_bytes * 8)}},
	)
	for lane in 0 ..< 4 {
		append(
			&constants,
			check.Constant{type = target_float, value = check.Float_Value{bits = test_float_bits(lanes[lane], target_bytes), width = u8(target_bytes * 8)}},
		)
	}
	program.constant_table = fixture_clone(constants[:], allocator)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{{}, .Complex, .Quaternion}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Builtin_Plan {
				builtin = check.Builtin_Id(1),
				arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, real_part}, check.Expression_Ref{1, imaginary}}, allocator),
			},
			check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, build}, target = quaternion_type},
			check.Builtin_Plan {
				builtin = check.Builtin_Id(2),
				arguments = fixture_clone(
					[]check.Operand {
						check.Expression_Ref{1, parts[0]},
						check.Expression_Ref{1, parts[1]},
						check.Expression_Ref{1, parts[2]},
						check.Expression_Ref{1, parts[3]},
					},
					allocator,
				),
			},
		},
		allocator,
	)
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(1))
}

// The demo case: complex128 converts to quaternion256 with the imaginary part in the imag lane.
@(test)
complex128_to_quaternion256_keeps_imaginary_lane :: proc(t: ^testing.T) {
	complex_to_quaternion_case(t, 8, 8, 1, 2)
}

// A narrower complex widens into the quaternion: complex64 converts to quaternion256.
@(test)
complex64_to_quaternion256_widens_components :: proc(t: ^testing.T) {
	complex_to_quaternion_case(t, 4, 8, 3, 4)
}

// The f16 width converts through the F32 arithmetic scalar like scalar f16 operations.
@(test)
complex32_to_quaternion64_keeps_imaginary_lane :: proc(t: ^testing.T) {
	complex_to_quaternion_case(t, 2, 2, 1, 2)
}
