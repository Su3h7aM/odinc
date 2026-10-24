package lower

import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Procedure `() -> u64` returning `u64((guard + k + k) >> 64) + u64((guard + k + k) / 3)` for the zero global
// `guard: u128` and `k = 2^63 + 5`. The result is 1 + floor((2^64 + 10) / 3) only if the carry, the wide shift,
// the wide division and both conversions are correct.
@(test)
wide_arithmetic_carries_into_high_word :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	wide := types.intern(&store, types.Type{kind = .Integer, count = 16})
	word := types.intern(&store, types.Type{kind = .Integer, count = 8})
	length := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {word}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	guard := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_constant := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_sum := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{op = {kind = .Add}, left = guard, right = first_constant})
	second_constant := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_sum := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{op = {kind = .Add}, left = first_sum, right = second_constant})
	sixty_four := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	shifted := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{op = {kind = .Shr}, left = second_sum, right = sixty_four})
	three := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	quotient := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{op = {kind = .Quo}, left = second_sum, right = three})
	first_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = first_callee, args = syntax.ast_add_list(&ast, {shifted})})
	second_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = second_callee, args = syntax.ast_add_list(&ast, {quotient})})
	total := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{op = {kind = .Add}, left = first_conversion, right = second_conversion})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {total})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = wide}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(guard) - 1] = {
		type   = wide,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	for node in ([?]syntax.Node_Index{first_sum, second_sum, shifted, quotient}) {
		facts[int(node) - 1] = {
			type  = wide,
			mode  = .Value,
			state = .Checked,
		}
	}
	for node in ([?]syntax.Node_Index{first_constant, second_constant}) {
		facts[int(node) - 1] = {
			type     = wide,
			mode     = .Constant,
			constant = 1,
			state    = .Checked,
		}
	}
	facts[int(sixty_four) - 1] = {
		type     = length,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	facts[int(three) - 1] = {
		type     = wide,
		mode     = .Constant,
		constant = 3,
		state    = .Checked,
	}
	facts[int(first_conversion) - 1] = {
		type  = word,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(second_conversion) - 1] = {
		type  = word,
		mode  = .Value,
		plan  = 2,
		state = .Checked,
	}
	facts[int(total) - 1] = {
		type  = word,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, shifted}, target = word},
			check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, quotient}, target = word},
		},
		allocator,
	)
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "expression", type = signature},
			{entity = 2, kind = .Global, name = "guard", type = wide, alignment = 16},
		},
		allocator,
	)
	program.entity_symbols = fixture_clone([]check.Symbol_Id{0, 1, 2}, allocator)
	program.global_list = fixture_clone([]check.Global{{entity = 2, symbol = 2, type = wide, alignment = 16}}, allocator)
	addend, sixty, divisor: big.Int
	testing.expect_value(t, big.int_set_from_integer(&addend, (u64(1) << 63) + 5, allocator = allocator), big.Error.None)
	testing.expect_value(t, big.int_set_from_integer(&sixty, 64, allocator = allocator), big.Error.None)
	testing.expect_value(t, big.int_set_from_integer(&divisor, 3, allocator = allocator), big.Error.None)
	program.constant_table = fixture_clone(
		[]check.Constant{{}, {type = wide, value = addend}, {type = length, value = sixty}, {type = wide, value = divisor}},
		allocator,
	)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 100000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(6148914691236517209))
}

// Procedure `() -> u64` running `guard += k` and `guard /= 3` on the zero global `guard: u128`, then returning `u64(guard)`.
// The result is floor((2^63 + 5) / 3) = 3074457345618258604.
@(test)
wide_compound_assignment_updates_global :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	wide := types.intern(&store, types.Type{kind = .Integer, count = 16})
	word := types.intern(&store, types.Type{kind = .Integer, count = 8})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {word}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	addend := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	add_target := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	add_statement := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Add_Eq}, lhs = syntax.ast_add_list(&ast, {add_target}), rhs = syntax.ast_add_list(&ast, {addend})},
	)
	three := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	quo_target := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	quo_statement := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Quo_Eq}, lhs = syntax.ast_add_list(&ast, {quo_target}), rhs = syntax.ast_add_list(&ast, {three})},
	)
	read := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {read})})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {conversion})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {add_statement, quo_statement, result})})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = wide}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	for node in ([?]syntax.Node_Index{add_target, quo_target, read}) {
		facts[int(node) - 1] = {
			type   = wide,
			mode   = .Variable,
			entity = 2,
			state  = .Checked,
		}
	}
	facts[int(addend) - 1] = {
		type     = wide,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(three) - 1] = {
		type     = wide,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	for node in ([?]syntax.Node_Index{add_statement, quo_statement, callee}) {
		facts[int(node) - 1] = {
			state = .Checked,
		}
	}
	facts[int(conversion) - 1] = {
		type  = word,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.plan_table = fixture_clone([]check.Plan{{}, check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, read}, target = word}}, allocator)
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "expression", type = signature},
			{entity = 2, kind = .Global, name = "guard", type = wide, alignment = 16},
		},
		allocator,
	)
	program.entity_symbols = fixture_clone([]check.Symbol_Id{0, 1, 2}, allocator)
	program.global_list = fixture_clone([]check.Global{{entity = 2, symbol = 2, type = wide, alignment = 16}}, allocator)
	addend_value, divisor: big.Int
	testing.expect_value(t, big.int_set_from_integer(&addend_value, (u64(1) << 63) + 5, allocator = allocator), big.Error.None)
	testing.expect_value(t, big.int_set_from_integer(&divisor, 3, allocator = allocator), big.Error.None)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = wide, value = addend_value}, {type = wide, value = divisor}}, allocator)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 100000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(3074457345618258604))
}

// Procedure `() -> u64` returning `u64(minimum / -1)` for the signed 128-bit minimum: the scalar `SDiv` traps the same way.
@(test)
wide_minimum_quotient_by_minus_one_traps :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	signed_wide := types.intern(&store, types.Type{kind = .Integer, count = 16, signed = true})
	word := types.intern(&store, types.Type{kind = .Integer, count = 8})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {word}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	minimum := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	minus_one := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	division := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{op = {kind = .Quo}, left = minimum, right = minus_one})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {division})})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {conversion})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(minimum) - 1] = {
		type     = signed_wide,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(minus_one) - 1] = {
		type     = signed_wide,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	facts[int(division) - 1] = {
		type  = signed_wide,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(callee) - 1] = {
		state = .Checked,
	}
	facts[int(conversion) - 1] = {
		type  = word,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, division}, target = word}},
		allocator,
	)
	program.symbol_table = fixture_clone([]check.Symbol{{}, {entity = 1, kind = .Procedure, name = "expression", type = signature}}, allocator)
	program.entity_symbols = fixture_clone([]check.Symbol_Id{0, 1}, allocator)
	minimum_value, minus_one_value: big.Int
	testing.expect_value(t, big.int_pow_int(&minimum_value, 2, 127, allocator), big.Error.None)
	testing.expect_value(t, big.int_neg(&minimum_value, &minimum_value, allocator), big.Error.None)
	testing.expect_value(t, big.int_set_from_integer(&minus_one_value, -1, allocator = allocator), big.Error.None)
	program.constant_table = fixture_clone(
		[]check.Constant{{}, {type = signed_wide, value = minimum_value}, {type = signed_wide, value = minus_one_value}},
		allocator,
	)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Arith_Trap)
}
