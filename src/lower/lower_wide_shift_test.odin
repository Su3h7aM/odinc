package lower

import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Procedure `(u64) -> int` shifting the constant by a `u128` count through a `_WORD` conversion.
// Lowering must narrow the wide count to its low word instead of feeding the slot address to `Shl`.
@(test)
scalar_shift_by_wide_count_reads_low_word :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	wide := types.intern(&store, types.Type{kind = .Integer, count = 16})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer}, results = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	count := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	amount := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {count})})
	shift := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{op = {kind = .Shl}, left = amount, right = conversion})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {shift})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = integer}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(count) - 1] = {
		type   = integer,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	facts[int(amount) - 1] = {
		type     = integer,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(callee) - 1] = {
		state = .Checked,
	}
	facts[int(conversion) - 1] = {
		type  = wide,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(shift) - 1] = {
		type  = integer,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, count}, target = wide}},
		allocator,
	)
	program.symbol_table = fixture_clone([]check.Symbol{{}, {entity = 1, kind = .Procedure, name = "expression", type = signature}}, allocator)
	program.entity_symbols = fixture_clone([]check.Symbol_Id{0, 1}, allocator)
	one, many: big.Int
	testing.expect_value(t, big.int_set_from_integer(&one, 1, allocator = allocator), big.Error.None)
	testing.expect_value(t, big.int_set_from_integer(&many, 256, allocator = allocator), big.Error.None)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = integer, value = one}, {type = integer, value = many}}, allocator)

	for variant in ([?]struct {
			operator: syntax.Token_Kind,
			constant: check.Const_Id,
			argument: u64,
			expected: u64,
		}{{.Shl, 1, 3, 8}, {.Shr, 2, 2, 64}}) {
		ast.nodes[shift].payload = syntax.Binary_Expr {
			op = {kind = variant.operator},
			left = amount,
			right = conversion,
		}
		program.typed_views[1].nodes.constants[int(amount) - 1] = variant.constant
		module: ir.Module
		errors, err := lower_program(&program, &module)
		defer delete(errors)
		if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { continue }
		defer ir.module_destroy(&module)
		actual, run_error := ir.interp_run(&module, module.functions[0], {variant.argument}, 100000, context.allocator)
		testing.expect_value(t, run_error, nil)
		testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
		testing.expect_value(t, actual.value, variant.expected)
	}
}

// Procedure `(u64) -> bool` returning whether the argument is nonzero, as `value != 0`.
@(test)
scalar_int_to_bool_compares_against_zero :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	word := types.intern(&store, types.Type{kind = .Integer, count = 8})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {word}, results = {boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	argument := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {argument})})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {conversion})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = word}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(argument) - 1] = {
		type   = word,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	facts[int(callee) - 1] = {
		state = .Checked,
	}
	facts[int(conversion) - 1] = {
		type  = boolean,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, argument}, target = boolean}},
		allocator,
	)
	program.symbol_table = fixture_clone([]check.Symbol{{}, {entity = 1, kind = .Procedure, name = "expression", type = signature}}, allocator)
	program.entity_symbols = fixture_clone([]check.Symbol_Id{0, 1}, allocator)

	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	for variant in ([?]struct {
			argument, expected: u64,
		}{{7, 1}, {0, 0}}) {
		actual, run_error := ir.interp_run(&module, module.functions[0], {variant.argument}, 100000, context.allocator)
		testing.expect_value(t, run_error, nil)
		testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
		testing.expect_value(t, actual.value, variant.expected)
	}
}

// Procedure `() -> bool` returning whether the zero global `guard: u128` with `2^64` added is nonzero.
// Only the high word is set, so the conversion must compare both words against zero.
@(test)
wide_int_to_bool_true_when_only_high_word_set :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	wide := types.intern(&store, types.Type{kind = .Integer, count = 16})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	addend := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	target := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	statement := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Add_Eq}, lhs = syntax.ast_add_list(&ast, {target}), rhs = syntax.ast_add_list(&ast, {addend})},
	)
	read := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {read})})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {conversion})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {statement, result})})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = wide}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	for node in ([?]syntax.Node_Index{target, read}) {
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
	for node in ([?]syntax.Node_Index{statement, callee}) {
		facts[int(node) - 1] = {
			state = .Checked,
		}
	}
	facts[int(conversion) - 1] = {
		type  = boolean,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, read}, target = boolean}},
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
	high: big.Int
	testing.expect_value(t, big.int_pow_int(&high, 2, 64, allocator), big.Error.None)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = wide, value = high}}, allocator)

	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 100000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(1))
}

// Procedure `() -> bool` returning whether the zero global `guard: u128` is nonzero.
@(test)
wide_int_to_bool_false_when_zero :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	wide := types.intern(&store, types.Type{kind = .Integer, count = 16})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	read := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {read})})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {conversion})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = wide}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(read) - 1] = {
		type   = wide,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(callee) - 1] = {
		state = .Checked,
	}
	facts[int(conversion) - 1] = {
		type  = boolean,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, read}, target = boolean}},
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

	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 100000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(0))
}
