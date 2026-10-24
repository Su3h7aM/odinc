package lower

import "base:runtime"
import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
broadcast_scalar_fills_array_lanes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1, signed = false})
	array := types.intern(&store, types.Type{kind = .Array, elem = byte_type, count = 4})
	eight: big.Int
	big.int_set_from_integer(&eight, i64(8), allocator = allocator)
	broadcast_read_check(t, allocator, &store, array, byte_type, eight, {3}, u64(8))
}

@(test)
broadcast_scalar_fills_nested_array_lanes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	row := types.intern(&store, types.Type{kind = .Array, elem = integer, count = 3})
	grid := types.intern(&store, types.Type{kind = .Array, elem = row, count = 2})
	minus_seven: big.Int
	big.int_set_from_integer(&minus_seven, i64(-7), allocator = allocator)
	broadcast_read_check(t, allocator, &store, grid, integer, minus_seven, {1, 2}, u64(max(u32)) + 1 - 7)
}

@(private)
broadcast_read_check :: proc(
	t: ^testing.T,
	allocator: runtime.Allocator,
	store: ^types.Store,
	array, element: types.Type_Id,
	scalar: big.Int,
	indexes: []i64,
	expected: u64,
) {
	index_integer := types.intern(store, types.Type{kind = .Integer, count = 8, signed = true})
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless, results = {element}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	literal := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {name}), values = syntax.ast_add_list(&ast, {literal})},
	)
	access := name
	chain := make([]syntax.Node_Index, len(indexes), allocator)
	offsets := make([]syntax.Node_Index, len(indexes), allocator)
	for _, depth in indexes {
		offsets[depth] = syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
		access = syntax.ast_add_node(&ast, .Index_Expr, 0, 1, syntax.Index_Expr{expr = access, index = offsets[depth]})
		chain[depth] = access
	}
	outcome := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {access})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {declaration, outcome})})

	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(literal) - 1] = {
		type  = array,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(name) - 1] = {
		type   = array,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(declaration) - 1] = {
		state = .Checked,
	}
	facts[int(outcome) - 1] = {
		state = .Checked,
	}
	facts[int(body) - 1] = {
		state = .Checked,
	}
	constants := make([]check.Constant, 2 + len(indexes), allocator)
	constants[1] = {
		type  = element,
		value = scalar,
	}
	current := array
	for offset, depth in offsets {
		current = types.get(store, current).elem
		position: big.Int
		big.int_set_from_integer(&position, indexes[depth], allocator = allocator)
		constants[2 + depth] = {
			type  = index_integer,
			value = position,
		}
		facts[int(offset) - 1] = {
			type     = index_integer,
			mode     = .Constant,
			constant = check.Const_Id(2 + depth),
			state    = .Checked,
		}
		facts[int(chain[depth]) - 1] = {
			type  = current,
			mode  = .Variable,
			plan  = 2,
			state = .Checked,
		}
	}

	entities := make([]check.Entity, 3, allocator)
	entities[1] = {
		kind = .Procedure,
		type = signature,
	}
	entities[2] = {
		kind = .Variable,
		type = array,
	}
	program := expression_fixture(&ast, store, allocator, body, signature, entities, facts, nil)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Conversion_Plan{kind = .Broadcast, source = check.Operand(check.Const_Id(1)), target = array},
			check.Bounds_Plan{kind = .Index, policy = .Disabled},
		},
		allocator,
	)
	program.constant_table = fixture_clone(constants, allocator)
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, expected)
}
