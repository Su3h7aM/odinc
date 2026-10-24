package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// abs of a complex value is its magnitude: the square root of the sum of its squared components.
@(test)
complex_abs_matches_magnitude :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	float := types.intern(&store, types.Type{kind = .Float, count = 8})
	complex_type := types.intern(&store, types.Type{kind = .Complex, count = 16})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {float}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	real_part := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	imaginary := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	build := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {real_part, imaginary})})
	magnitude := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {build})})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {magnitude})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(real_part) - 1] = {
		type     = float,
		constant = 1,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(imaginary) - 1] = {
		type     = float,
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
	facts[int(magnitude) - 1] = {
		type  = float,
		plan  = 2,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.constant_table = fixture_clone(
		[]check.Constant {
			{},
			{type = float, value = check.Float_Value{bits = 0x4008000000000000, width = 64}},
			{type = float, value = check.Float_Value{bits = 0x4010000000000000, width = 64}},
		},
		allocator,
	)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{{}, .Complex, .Abs}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Builtin_Plan {
				builtin = check.Builtin_Id(1),
				arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, real_part}, check.Expression_Ref{1, imaginary}}, allocator),
			},
			check.Builtin_Plan{builtin = check.Builtin_Id(2), arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, build}}, allocator)},
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
	testing.expect_value(t, actual.value, u64(0x4014000000000000))
}

// conj of a quaternion keeps the real part stored last and negates the three imaginary parts stored first.
@(test)
quaternion_conj_keeps_real_part :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	float := types.intern(&store, types.Type{kind = .Float, count = 4})
	quaternion_type := types.intern(&store, types.Type{kind = .Quaternion, count = 16})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {float}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	x := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	y := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	z := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	w := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	build := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {x, y, z, w})})
	conjugate := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {build})})
	real_part := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {conjugate})})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {real_part})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(x) - 1] = {
		type     = float,
		constant = 1,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(y) - 1] = {
		type     = float,
		constant = 2,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(z) - 1] = {
		type     = float,
		constant = 3,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(w) - 1] = {
		type     = float,
		constant = 4,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(build) - 1] = {
		type  = quaternion_type,
		plan  = 1,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(conjugate) - 1] = {
		type  = quaternion_type,
		plan  = 2,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(real_part) - 1] = {
		type  = float,
		plan  = 3,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.constant_table = fixture_clone(
		[]check.Constant {
			{},
			{type = float, value = check.Float_Value{bits = 0x3f800000, width = 32}},
			{type = float, value = check.Float_Value{bits = 0x40000000, width = 32}},
			{type = float, value = check.Float_Value{bits = 0x40400000, width = 32}},
			{type = float, value = check.Float_Value{bits = 0x40800000, width = 32}},
		},
		allocator,
	)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{{}, .Quaternion, .Conj, .Real}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Builtin_Plan {
				builtin = check.Builtin_Id(1),
				arguments = fixture_clone(
					[]check.Operand{check.Expression_Ref{1, x}, check.Expression_Ref{1, y}, check.Expression_Ref{1, z}, check.Expression_Ref{1, w}},
					allocator,
				),
			},
			check.Builtin_Plan{builtin = check.Builtin_Id(2), arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, build}}, allocator)},
			check.Builtin_Plan{builtin = check.Builtin_Id(3), arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, conjugate}}, allocator)},
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
	testing.expect_value(t, actual.value, u64(0x40800000))
}

// abs of a complex32 has no official runtime value (the official compiler exits 132 for a missing
// `abs_complex32`), so lowering reports unsupported instead of inventing one.
@(test)
complex32_abs_reports_unsupported :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	half := types.intern(&store, types.Type{kind = .Float, count = 2})
	complex_type := types.intern(&store, types.Type{kind = .Complex, count = 4})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {half}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	real_part := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	imaginary := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	build := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {real_part, imaginary})})
	magnitude := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {build})})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {magnitude})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(real_part) - 1] = {
		type     = half,
		constant = 1,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(imaginary) - 1] = {
		type     = half,
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
	facts[int(magnitude) - 1] = {
		type  = half,
		plan  = 2,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.constant_table = fixture_clone(
		[]check.Constant {
			{},
			{type = half, value = check.Float_Value{bits = 0x4200, width = 16}},
			{type = half, value = check.Float_Value{bits = 0x4400, width = 16}},
		},
		allocator,
	)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{{}, .Complex, .Abs}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Builtin_Plan {
				builtin = check.Builtin_Id(1),
				arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, real_part}, check.Expression_Ref{1, imaginary}}, allocator),
			},
			check.Builtin_Plan{builtin = check.Builtin_Id(2), arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, build}}, allocator)},
		},
		allocator,
	)
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, err, nil) { return }
	if !testing.expect_value(t, len(errors), 1) { return }
	testing.expect_value(t, errors[0].code, Lower_Code.Unsupported)
	testing.expect_value(t, errors[0].feature, Lower_Feature.Builtin)
}
