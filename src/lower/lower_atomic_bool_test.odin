package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Procedure `() -> bool` storing `true` into `guard: bool`, loading it back, exchanging it back to
// `false` with a strong compare-exchange, then failing a second exchange against the new value: it
// returns whether every observed value matched, so a wrong old value, flag or stored bit fails it.
@(test)
bool_atomics_store_load_and_compare_exchange_in_order :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	boolean := types.intern(&store, types.Type{kind = .Bool})
	pointer := types.intern(&store, types.Type{kind = .Pointer, elem = boolean})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	store_guard := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	store_address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = store_guard})
	store_true := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	store_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	store_call := syntax.ast_add_node(
		&ast,
		.Call_Expr,
		0,
		1,
		syntax.Call_Expr{expr = store_callee, args = syntax.ast_add_list(&ast, {store_address, store_true})},
	)
	store_statement := syntax.ast_add_node(&ast, .Expr_Stmt, 0, 1, syntax.Expr_Stmt{expr = store_call})

	load_guard := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	load_address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = load_guard})
	load_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	load_call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = load_callee, args = syntax.ast_add_list(&ast, {load_address})})
	first := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {first}), values = syntax.ast_add_list(&ast, {load_call})},
	)

	cas_guard := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	cas_address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = cas_guard})
	cas_expected := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	cas_desired := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	cas_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	cas_call := syntax.ast_add_node(
		&ast,
		.Call_Expr,
		0,
		1,
		syntax.Call_Expr{expr = cas_callee, args = syntax.ast_add_list(&ast, {cas_address, cas_expected, cas_desired})},
	)
	old := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	flag := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	cas_declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {old, flag}), values = syntax.ast_add_list(&ast, {cas_call})},
	)

	reload_guard := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	reload_address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = reload_guard})
	reload_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	reload_call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = reload_callee, args = syntax.ast_add_list(&ast, {reload_address})})
	second := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	reload_declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {second}), values = syntax.ast_add_list(&ast, {reload_call})},
	)

	fail_guard := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	fail_address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = fail_guard})
	fail_expected := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	fail_desired := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	fail_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	fail_call := syntax.ast_add_node(
		&ast,
		.Call_Expr,
		0,
		1,
		syntax.Call_Expr{expr = fail_callee, args = syntax.ast_add_list(&ast, {fail_address, fail_expected, fail_desired})},
	)
	failed_old := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	failed_flag := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	fail_declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {failed_old, failed_flag}), values = syntax.ast_add_list(&ast, {fail_call})},
	)

	check_guard := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	check_address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = check_guard})
	check_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	check_call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = check_callee, args = syntax.ast_add_list(&ast, {check_address})})
	third := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	check_declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {third}), values = syntax.ast_add_list(&ast, {check_call})},
	)

	first_ref := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	flag_ref := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	old_ref := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_ref := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_not := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .Not}, expr = second_ref})
	failed_old_ref := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	failed_old_not := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .Not}, expr = failed_old_ref})
	failed_flag_ref := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	failed_flag_not := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .Not}, expr = failed_flag_ref})
	third_ref := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	third_not := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .Not}, expr = third_ref})
	and_first := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = first_ref, op = {kind = .And}, right = flag_ref})
	and_old := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = and_first, op = {kind = .And}, right = old_ref})
	and_second := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = and_old, op = {kind = .And}, right = second_not})
	and_failed_old := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = and_second, op = {kind = .And}, right = failed_old_not})
	and_failed_flag := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = and_failed_old, op = {kind = .And}, right = failed_flag_not})
	and_third := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = and_failed_flag, op = {kind = .And}, right = third_not})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {and_third})})
	body := syntax.ast_add_node(
		&ast,
		.Block_Stmt,
		0,
		1,
		syntax.Block_Stmt {
			stmts = syntax.ast_add_list(
				&ast,
				{store_statement, first_declaration, cas_declaration, reload_declaration, fail_declaration, check_declaration, result},
			),
		},
	)

	// Entities: 1 procedure, 2 guard, 3 first, 4 old, 5 flag, 6 second, 7 failed old, 8 failed flag, 9 third.
	entities := fixture_clone(
		[]check.Entity {
			{},
			{kind = .Procedure, type = signature},
			{kind = .Variable, type = boolean},
			{kind = .Variable, type = boolean},
			{kind = .Variable, type = boolean},
			{kind = .Variable, type = boolean},
			{kind = .Variable, type = boolean},
			{kind = .Variable, type = boolean},
			{kind = .Variable, type = boolean},
			{kind = .Variable, type = boolean},
		},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	guards := []syntax.Node_Index{store_guard, load_guard, cas_guard, reload_guard, fail_guard, check_guard}
	for guard in guards {
		facts[int(guard) - 1] = {
			type   = boolean,
			mode   = .Variable,
			entity = 2,
			state  = .Checked,
		}
	}
	addresses := []syntax.Node_Index{store_address, load_address, cas_address, reload_address, fail_address, check_address}
	for address in addresses {
		facts[int(address) - 1] = {
			type  = pointer,
			mode  = .Value,
			state = .Checked,
		}
	}
	truths := []syntax.Node_Index{store_true, cas_expected, fail_expected}
	for word in truths {
		facts[int(word) - 1] = {
			type     = boolean,
			mode     = .Constant,
			constant = 1,
			state    = .Checked,
		}
	}
	falsities := []syntax.Node_Index{cas_desired, fail_desired}
	for word in falsities {
		facts[int(word) - 1] = {
			type     = boolean,
			mode     = .Constant,
			constant = 2,
			state    = .Checked,
		}
	}
	callees := []syntax.Node_Index{store_callee, load_callee, cas_callee, reload_callee, fail_callee, check_callee}
	for callee in callees {
		facts[int(callee) - 1] = {
			state = .Checked,
		}
	}
	facts[int(store_call) - 1] = {
		mode  = .No_Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(load_call) - 1] = {
		type  = boolean,
		mode  = .Value,
		plan  = 2,
		state = .Checked,
	}
	facts[int(cas_call) - 1] = {
		mode  = .No_Value,
		plan  = 3,
		state = .Checked,
	}
	facts[int(reload_call) - 1] = {
		type  = boolean,
		mode  = .Value,
		plan  = 4,
		state = .Checked,
	}
	facts[int(fail_call) - 1] = {
		mode  = .No_Value,
		plan  = 5,
		state = .Checked,
	}
	facts[int(check_call) - 1] = {
		type  = boolean,
		mode  = .Value,
		plan  = 6,
		state = .Checked,
	}
	names := []syntax.Node_Index{first, old, flag, second, failed_old, failed_flag, third}
	for name, index in names {
		facts[int(name) - 1] = {
			type   = boolean,
			mode   = .Variable,
			entity = check.Entity_Id(index + 3),
			state  = .Checked,
		}
	}
	statements := []syntax.Node_Index{store_statement, first_declaration, cas_declaration, reload_declaration, fail_declaration, check_declaration}
	for declaration in statements {
		facts[int(declaration) - 1] = {
			state = .Checked,
		}
	}
	refs := []syntax.Node_Index{first_ref, old_ref, flag_ref, second_ref, failed_old_ref, failed_flag_ref, third_ref}
	for ref, index in refs {
		facts[int(ref) - 1] = {
			type   = boolean,
			mode   = .Variable,
			entity = check.Entity_Id(index + 3),
			state  = .Checked,
		}
	}
	// The reference order matches the declaration order: first, old, flag, second, failed old, failed flag, third.
	negations := []syntax.Node_Index{second_not, failed_old_not, failed_flag_not, third_not}
	for negated in negations {
		facts[int(negated) - 1] = {
			type  = boolean,
			mode  = .Value,
			state = .Checked,
		}
	}
	conjunctions := []syntax.Node_Index{and_first, and_old, and_second, and_failed_old, and_failed_flag, and_third}
	for conjunction in conjunctions {
		facts[int(conjunction) - 1] = {
			type  = boolean,
			mode  = .Value,
			state = .Checked,
		}
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.builtin_kinds = fixture_clone(
		[]check.Builtin_Kind{.None, .Atomic_Store, .Atomic_Load, .Atomic_Compare_Exchange_Strong, .Atomic_Load, .Atomic_Compare_Exchange_Strong, .Atomic_Load},
		allocator,
	)
	results := fixture_clone([]types.Type_Id{boolean, boolean}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Builtin_Plan {
				builtin = 1,
				arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, store_address}, check.Expression_Ref{1, store_true}}, allocator),
			},
			check.Builtin_Plan{builtin = 2, arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, load_address}}, allocator)},
			check.Builtin_Plan {
				builtin = 3,
				arguments = fixture_clone(
					[]check.Operand{check.Expression_Ref{1, cas_address}, check.Expression_Ref{1, cas_expected}, check.Expression_Ref{1, cas_desired}},
					allocator,
				),
				results = results,
			},
			check.Builtin_Plan{builtin = 4, arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, reload_address}}, allocator)},
			check.Builtin_Plan {
				builtin = 5,
				arguments = fixture_clone(
					[]check.Operand{check.Expression_Ref{1, fail_address}, check.Expression_Ref{1, fail_expected}, check.Expression_Ref{1, fail_desired}},
					allocator,
				),
				results = results,
			},
			check.Builtin_Plan{builtin = 6, arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, check_address}}, allocator)},
		},
		allocator,
	)
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "expression", type = signature},
			{entity = 2, kind = .Global, name = "guard", type = boolean, alignment = 1},
		},
		allocator,
	)
	program.entity_symbols = fixture_clone([]check.Symbol_Id{0, 1, 2}, allocator)
	program.global_list = fixture_clone([]check.Global{{entity = 2, symbol = 2, type = boolean, alignment = 1}}, allocator)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = boolean, value = true}, {type = boolean, value = false}}, allocator)
	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(1))
}
