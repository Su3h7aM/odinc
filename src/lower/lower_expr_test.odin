package lower

import "base:runtime"
import "core:math/big"
import "core:mem/virtual"
import "core:slice"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
expression_fixture :: proc(
	ast: ^syntax.Ast,
	store: ^types.Store,
	allocator: runtime.Allocator,
	body: syntax.Node_Index,
	signature: types.Type_Id,
	entities: []check.Entity,
	facts: []check.Expression_Info,
	parameters: []check.Entity_Id,
) -> check.Checked_Program {
	nodes := check.Typed_Nodes {
		types     = make([]types.Type_Id, len(facts), allocator),
		constants = make([]check.Const_Id, len(facts), allocator),
		modes     = make([]check.Addressing_Mode, len(facts), allocator),
		entities  = make([]check.Entity_Id, len(facts), allocator),
		plans     = make([]check.Plan_Id, len(facts), allocator),
		scopes    = make([]check.Scope_Id, len(facts), allocator),
		states    = make([]check.Node_State, len(facts), allocator),
	}
	for fact, index in facts {
		nodes.types[index] = fact.type
		nodes.constants[index] = fact.constant
		nodes.modes[index] = fact.mode
		nodes.entities[index] = fact.entity
		nodes.plans[index] = fact.plan
		nodes.states[index] = fact.state
	}
	return check.Checked_Program {
		type_data = store,
		files = fixture_clone([]check.File{{}, {ast = ast, policy = {bounds_check = .Disabled, division_by_zero = .Trap}}}, allocator),
		entities = entities,
		typed_views = fixture_clone([]check.Typed_View{{}, {file = 1, first_node = 1, nodes = nodes}}, allocator),
		symbol_table = fixture_clone([]check.Symbol{{}, {entity = 1, kind = .Procedure, name = "expression", type = signature}}, allocator),
		entity_symbols = make([]check.Symbol_Id, len(entities), allocator),
		procedure_list = fixture_clone(
			[]check.Checked_Procedure {
				{entity = 1, symbol = 1, signature = signature, convention = .Contextless, body = {1, body}, view = 1, parameters = parameters},
			},
			allocator,
		),
	}
}

@(test)
expressions_preserve_division_modes_and_local_addresses :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer, integer}, results = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	left := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	right := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	expression := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = left, op = {kind = .Quo}, right = right})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {expression})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone(
		[]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = integer}, {kind = .Variable, type = integer}},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(left) - 1] = {
		type   = integer,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	facts[int(right) - 1] = {
		type   = integer,
		mode   = .Value,
		entity = 3,
		state  = .Checked,
	}
	facts[int(expression) - 1] = {
		type  = integer,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2, 3})
	for operator in ([]syntax.Token_Kind{.Quo, .Mod, .Mod_Mod}) {
		ast.nodes[expression].payload = syntax.Binary_Expr {
			left = left,
			op = {kind = operator},
			right = right,
		}
		for mode in ([]check.Division_By_Zero{.Trap, .Zero, .Self, .All_Bits}) {
			program.files[1].policy.division_by_zero = mode
			module: ir.Module
			errors, err := lower_program(&program, &module)
			defer delete(errors)
			if !testing.expect_value(t, err, nil) { continue }
			defer ir.module_destroy(&module)
			if !testing.expect_value(t, len(errors), 0) { continue }
			cases := [?][2]i64{{7, 0}, {-7, 3}, {min(i64), -1}}
			for arguments in cases {

				actual, run_error := ir.interp_run(&module, module.functions[0], {u64(arguments[0]), u64(arguments[1])}, 1000, context.allocator)
				testing.expect_value(t, run_error, nil)
				if operator == .Quo && arguments[0] == min(i64) { testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Arith_Trap); continue }
				if arguments[1] == 0 && mode == .Trap { testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Trap); continue }
				expected: i64
				if arguments[1] == 0 {
					if operator !=
					   .Quo { expected = 0 if mode == .Self else arguments[0] } else { expected = 0 if mode == .Zero else (arguments[0] if mode == .Self else -1) }
				} else if arguments[1] ==
				   -1 { expected = 0 } else if operator == .Quo { expected = -2 } else if operator == .Mod { expected = -1 } else { expected = 2 }
				testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
				testing.expect_value(t, actual.value, u64(expected))
			}
		}
	}
	local_array_aliasing(t, &store, allocator)
}

@(private)
local_array_aliasing :: proc(t: ^testing.T, store: ^types.Store, allocator: runtime.Allocator) {
	byte := types.intern(store, types.Type{kind = .Integer, count = 1})
	integer := types.intern(store, types.Type{kind = .Integer, count = 8, signed = true})
	array := types.intern(store, types.Type{kind = .Array, elem = byte, count = 6})
	pointer := types.intern(store, types.Type{kind = .Pointer, elem = byte})
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless, results = fixture_clone([]types.Type_Id{byte}, allocator)})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	declaration := syntax.ast_add_node(&ast, .Value_Decl, 0, 1, syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {name})})
	index_value := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	index := syntax.ast_add_node(&ast, .Index_Expr, 0, 1, syntax.Index_Expr{expr = name, index = index_value})
	scalar_name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	scalar_decl := syntax.ast_add_node(&ast, .Value_Decl, 0, 1, syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {scalar_name})})
	address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = scalar_name})
	pointer_name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	pointer_decl := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {pointer_name}), values = syntax.ast_add_list(&ast, {address})},
	)
	dereference := syntax.ast_add_node(&ast, .Deref_Expr, 0, 1, syntax.Deref_Expr{expr = pointer_name})
	value := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	conversion_node := syntax.ast_add_node(&ast, .Type_Cast, 0, 1, syntax.Type_Cast{expr = value})
	assignment := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Eq}, lhs = syntax.ast_add_list(&ast, {dereference}), rhs = syntax.ast_add_list(&ast, {conversion_node})},
	)
	array_assignment := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Eq}, lhs = syntax.ast_add_list(&ast, {index}), rhs = syntax.ast_add_list(&ast, {scalar_name})},
	)
	parenthesized := syntax.ast_add_node(&ast, .Paren_Expr, 0, 1, syntax.Paren_Expr{expr = index})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {parenthesized})})
	body := syntax.ast_add_node(
		&ast,
		.Block_Stmt,
		0,
		1,
		syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {declaration, scalar_decl, pointer_decl, assignment, array_assignment, result})},
	)
	entities := fixture_clone(
		[]check.Entity {
			{},
			{kind = .Procedure, type = signature},
			{kind = .Variable, type = array},
			{kind = .Variable, type = pointer},
			{kind = .Variable, type = byte},
		},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(scalar_name) - 1] = {
		type   = byte,
		entity = 4,
		mode   = .Variable,
		state  = .Checked,
	}
	facts[int(name) - 1] = {
		type   = array,
		entity = 2,
		mode   = .Variable,
		state  = .Checked,
	}
	facts[int(pointer_name) - 1] = {
		type   = pointer,
		entity = 3,
		mode   = .Variable,
		state  = .Checked,
	}
	facts[int(index_value) - 1] = {
		type     = integer,
		constant = 1,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(value) - 1] = {
		type     = integer,
		constant = 2,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(conversion_node) - 1] = {
		type  = byte,
		plan  = 2,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(index) - 1] = {
		type  = byte,
		plan  = 3,
		mode  = .Variable,
		state = .Checked,
	}
	facts[int(parenthesized) - 1] = {
		type  = byte,
		plan  = 3,
		mode  = .Variable,
		state = .Checked,
	}
	facts[int(dereference) - 1] = {
		type  = byte,
		mode  = .Variable,
		state = .Checked,
	}
	facts[int(address) - 1] = {
		type  = pointer,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, store, allocator, body, signature, entities, facts, nil)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Assignment_Plan {
				destinations = fixture_clone([]check.Operand{check.Expression_Ref{1, index}}, allocator),
				values = fixture_clone([]check.Operand{check.Entity_Id(4)}, allocator),
			},
			check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, value}, target = byte},
			check.Bounds_Plan{kind = .Index, policy = .Disabled},
		},
		allocator,
	)
	program.typed_views[1].nodes.plans[int(array_assignment) - 1] = 1
	program.typed_views[1].nodes.states[int(array_assignment) - 1] = .Checked
	five := big.Int{}
	letter := big.Int{}
	big.int_set_from_integer(&five, i64(5), allocator = allocator)
	big.int_set_from_integer(&letter, i64(97), allocator = allocator)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = integer, value = five}, {type = integer, value = letter}}, allocator)
	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(97))
}

@(private)
fixture_clone :: proc(values: []$T, allocator: runtime.Allocator) -> []T {
	return slice.clone(values, allocator) or_else panic("fixture allocation failed")
}
